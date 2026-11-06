# Maps the ICD-10 codes of codes/newdx_icd10.csv to standard SNOMED concepts,
# the seeds extras/MakeNewDxCohortSql.R hands to the cohort template.
#
#   Rscript extras/AddSnomedToNewDxCsv.R
#
# Needs the database: the mapping is read from the site's own vocabulary, so it
# matches the vocabulary version the cohorts will be built against. Reuses the
# environment variables of extras/CodeToRun.R.
#
# What it does, and deliberately does not do:
#
#   * the codes are taken EXACTLY as the source table writes them. A three
#     character category ("J45") is looked up as "J45", not expanded to J45.0,
#     J45.1 and so on. Broadening happens later and on the SNOMED side: the
#     cohort SQL expands CONCEPT_ANCESTOR descendants of whatever this script
#     finds. Set expandChildCodes to TRUE to look up child ICD-10 codes as well,
#     which only matters for a category OMOP maps at the child level only.
#   * only vocabulary_id 'ICD10' (WHO) is read by default. sourceVocabularies
#     takes 'ICD10CM' as well, which a US-coded CDM such as MIMIC-IV may need.
#   * targets of any domain are kept and reported. The cohort template covers
#     Condition, Observation and Procedure; anything else is reported as
#     unusable rather than dropped silently.
#
# Writes three files next to the input:
#
#   codes/newdx_icd10_snomed.csv    the input plus SNOMED and Domains columns
#   codes/newdx_icd10_mapping.csv   one row per (outcome, ICD-10 code, target)
#   codes/newdx_icd10_report.csv    one row per outcome, with what went missing
#
# Read the report before generating cohorts: a code that is absent from the
# vocabulary, or present with no 'Maps to', contributes nothing to its outcome.

sourceVocabularies <- c("ICD10")
expandChildCodes <- FALSE
usableDomains <- c("Condition", "Observation", "Procedure")

csvFile <- "codes/newdx_icd10.csv"
snomedFile <- "codes/newdx_icd10_snomed.csv"
mappingFile <- "codes/newdx_icd10_mapping.csv"
reportFile <- "codes/newdx_icd10_report.csv"
stopifnot(file.exists(csvFile))

connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = Sys.getenv("SPARSE_ARRAY_DBMS", unset = "sql server"),
  server = Sys.getenv("SPARSE_ARRAY_DB_SERVER"),
  user = Sys.getenv("SPARSE_ARRAY_DB_USER"),
  password = Sys.getenv("SPARSE_ARRAY_DB_PASSWORD"),
  port = Sys.getenv("SPARSE_ARRAY_DB_PORT", unset = "1433"),
  extraSettings = Sys.getenv("SPARSE_ARRAY_DB_EXTRA_SETTINGS"),
  pathToDriver = Sys.getenv("SPARSE_ARRAY_JDBC_FOLDER",
                            unset = "/home/rstudio/jdbc")
)
vocabularyDatabaseSchema <- Sys.getenv(
  "SPARSE_ARRAY_VOCABULARY_DATABASE_SCHEMA",
  unset = Sys.getenv("SPARSE_ARRAY_CDM_DATABASE_SCHEMA")
)
stopifnot(nzchar(vocabularyDatabaseSchema))

outcomes <- utils::read.csv(csvFile, colClasses = "character")
stopifnot(all(c("CohortId", "Outcome", "ICD10") %in% names(outcomes)))
requested <- do.call(rbind, lapply(seq_len(nrow(outcomes)), function(i) {
  codes <- strsplit(trimws(outcomes$ICD10[i]), "[[:space:]]+")[[1]]
  data.frame(cohortId = outcomes$CohortId[i], outcome = outcomes$Outcome[i],
             icd10 = codes[nzchar(codes)], stringsAsFactors = FALSE)
}))
cat(nrow(outcomes), "outcome(s),", nrow(requested), "ICD-10 code(s), vocabulary",
    paste(sourceVocabularies, collapse = " + "), "\n")

# OMOP writes ICD-10 dotted ("I20.0"); the source table already does, but the
# undotted spelling is accepted too so the file can be edited either way.
undotted <- function(x) gsub(".", "", x, fixed = TRUE)
dotted <- function(x) ifelse(nchar(x) > 3L,
                             paste0(substr(x, 1L, 3L), ".", substring(x, 4L)),
                             x)
lookup <- unique(c(requested$icd10, dotted(undotted(requested$icd10))))

# Source concept, its 'Maps to' target, and what that target is. LEFT JOIN, so
# a code that exists with no mapping comes back with an empty target instead of
# disappearing.
sqlTemplate <- "
SELECT s.concept_code AS source_code,
  s.concept_id AS source_concept_id,
  s.concept_name AS source_name,
  s.vocabulary_id AS source_vocabulary,
  t.concept_id AS target_concept_id,
  t.concept_name AS target_name,
  t.domain_id AS target_domain,
  t.vocabulary_id AS target_vocabulary,
  t.standard_concept AS target_standard
FROM @vocabulary_database_schema.concept s
LEFT JOIN @vocabulary_database_schema.concept_relationship cr
  ON cr.concept_id_1 = s.concept_id
  AND cr.relationship_id = 'Maps to'
  AND cr.invalid_reason IS NULL
LEFT JOIN @vocabulary_database_schema.concept t
  ON t.concept_id = cr.concept_id_2
  AND t.standard_concept = 'S'
  AND t.invalid_reason IS NULL
WHERE s.vocabulary_id IN (@source_vocabularies)
  AND (@code_predicate)
;"

connection <- DatabaseConnector::connect(connectionDetails)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

quoted <- function(x) paste0("'", x, "'", collapse = ", ")
# Chunked: Oracle caps an IN list at 1000 expressions.
chunks <- split(lookup, ceiling(seq_along(lookup) / 400L))
found <- do.call(rbind, lapply(chunks, function(chunk) {
  predicate <- if (expandChildCodes) {
    paste0("s.concept_code IN (", quoted(chunk), ") OR ",
           paste0("s.concept_code LIKE '", chunk, "%'", collapse = " OR "))
  } else {
    paste0("s.concept_code IN (", quoted(chunk), ")")
  }
  DatabaseConnector::querySql(
    connection,
    SqlRender::translate(
      SqlRender::render(sqlTemplate,
                        vocabulary_database_schema = vocabularyDatabaseSchema,
                        source_vocabularies = quoted(sourceVocabularies),
                        code_predicate = predicate),
      targetDialect = attr(connection, "dbms")
    ),
    snakeCaseToCamelCase = TRUE
  )
}))
if (is.null(found) || nrow(found) == 0) {
  stop("No ICD-10 code of ", csvFile, " exists in ", vocabularyDatabaseSchema,
       ".concept under vocabulary_id ",
       paste(sourceVocabularies, collapse = "/"),
       ". Check the vocabulary schema and sourceVocabularies.", call. = FALSE)
}

# A requested code matches itself, and with expandChildCodes also its children.
found$requestedCode <- NA_character_
for (code in unique(requested$icd10)) {
  hit <- found$sourceCode == code |
    (expandChildCodes & startsWith(found$sourceCode, code))
  found$requestedCode[hit & is.na(found$requestedCode)] <- code
}
found <- found[!is.na(found$requestedCode), ]

mapping <- merge(requested, found, by.x = "icd10", by.y = "requestedCode",
                 all.x = TRUE)
mapping <- mapping[order(mapping$cohortId, mapping$icd10,
                         mapping$targetConceptId), ]
mapping$usable <- !is.na(mapping$targetDomain) &
  mapping$targetDomain %in% usableDomains
utils::write.csv(mapping, mappingFile, row.names = FALSE, na = "")
cat("wrote", mappingFile, "-", nrow(mapping), "row(s)\n")

# One row per outcome: the seeds, and everything that did not become one.
perOutcome <- lapply(seq_len(nrow(outcomes)), function(i) {
  id <- outcomes$CohortId[i]
  rows <- mapping[mapping$cohortId == id, ]
  codes <- requested$icd10[requested$cohortId == id]
  absent <- setdiff(codes, rows$icd10[!is.na(rows$sourceConceptId)])
  unmapped <- setdiff(
    rows$icd10[!is.na(rows$sourceConceptId) & is.na(rows$targetConceptId)],
    rows$icd10[!is.na(rows$targetConceptId)]
  )
  unusable <- rows[!is.na(rows$targetConceptId) & !rows$usable, ]
  seeds <- sort(unique(rows$targetConceptId[rows$usable]))
  list(
    snomed = data.frame(
      CohortId = id, Outcome = outcomes$Outcome[i], ICD10 = outcomes$ICD10[i],
      SNOMED = paste(seeds, collapse = " "),
      Domains = paste(sort(unique(rows$targetDomain[rows$usable])),
                      collapse = " "),
      stringsAsFactors = FALSE
    ),
    report = data.frame(
      CohortId = id, Outcome = outcomes$Outcome[i],
      n_code = length(codes),
      n_code_absent_from_vocabulary = length(absent),
      n_code_without_maps_to = length(unmapped),
      n_snomed_seed = length(seeds),
      n_target_outside_domains = nrow(unusable),
      codes_absent = paste(absent, collapse = " "),
      codes_without_maps_to = paste(unmapped, collapse = " "),
      targets_outside_domains = paste(
        unique(paste0(unusable$icd10, ":", unusable$targetDomain)),
        collapse = " "
      ),
      stringsAsFactors = FALSE
    )
  )
})
snomed <- do.call(rbind, lapply(perOutcome, `[[`, "snomed"))
report <- do.call(rbind, lapply(perOutcome, `[[`, "report"))
utils::write.csv(snomed, snomedFile, row.names = FALSE, na = "")
utils::write.csv(report, reportFile, row.names = FALSE, na = "")
cat("wrote", snomedFile, "and", reportFile, "\n\n")

print(report[, c("CohortId", "Outcome", "n_code", "n_snomed_seed",
                 "n_code_absent_from_vocabulary", "n_code_without_maps_to",
                 "n_target_outside_domains")], row.names = FALSE)

empty <- report[report$n_snomed_seed == 0, ]
if (nrow(empty) > 0) {
  cat("\nNO USABLE SEED, so these outcomes cannot become a cohort:\n  ",
      paste(empty$Outcome, collapse = "\n  "), "\n", sep = "")
}
lost <- report[report$n_code_absent_from_vocabulary > 0 |
                 report$n_code_without_maps_to > 0 |
                 report$n_target_outside_domains > 0, ]
if (nrow(lost) > 0) {
  cat("\nCodes that contributed nothing, by outcome:\n")
  for (i in seq_len(nrow(lost))) {
    cat("  ", lost$Outcome[i], ": ", sep = "")
    parts <- c(
      if (nzchar(lost$codes_absent[i]))
        paste0("not in vocabulary [", lost$codes_absent[i], "]"),
      if (nzchar(lost$codes_without_maps_to[i]))
        paste0("no 'Maps to' [", lost$codes_without_maps_to[i], "]"),
      if (nzchar(lost$targets_outside_domains[i]))
        paste0("target domain not covered [",
               lost$targets_outside_domains[i], "]")
    )
    cat(paste(parts, collapse = "; "), "\n")
  }
  cat("\nexpandChildCodes = TRUE looks up child codes as well, which recovers ",
      "a category OMOP maps only at the child level.\n", sep = "")
}
