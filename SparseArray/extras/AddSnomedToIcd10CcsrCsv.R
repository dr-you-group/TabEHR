# Adds a SNOMED column to codes/icd10ccsr.csv: the standard SNOMED concepts the
# phenotype's ICD-10-CM codes map to directly ('Maps to').
#
# Descendants are deliberately NOT expanded here - the ATLAS-style cohort SQL in
# extras/OutcomeCohortTemplate.sql expands them itself through CONCEPT_ANCESTOR,
# so these are the seed concepts to hand it.
#
# One-off script, not part of the package. Run from the repository root, and run
# MakeIcd10CcsrCsv.R first - that rebuilds icd10ccsr.csv without the SNOMED
# column, so this script has to run after it.

library(data.table)

# Reuses the environment variables from extras/CodeToRun.R.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server",
  server = Sys.getenv("SPARSE_ARRAY_DB_SERVER"),
  user = Sys.getenv("SPARSE_ARRAY_DB_USER"),
  password = Sys.getenv("SPARSE_ARRAY_DB_PASSWORD"),
  port = Sys.getenv("SPARSE_ARRAY_DB_PORT")
)
vocabularyDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_VOCABULARY_DATABASE_SCHEMA",
                                       unset = Sys.getenv("SPARSE_ARRAY_CDM_DATABASE_SCHEMA"))
csvFile <- "codes/icd10ccsr.csv"

sqlTemplate <- "
SELECT DISTINCT
  s.concept_code AS icd10_code,
  c.concept_id AS concept_id
FROM @vocabulary_database_schema.concept s
INNER JOIN @vocabulary_database_schema.concept_relationship cr
  ON cr.concept_id_1 = s.concept_id
  AND cr.relationship_id = 'Maps to'
  AND cr.invalid_reason IS NULL
INNER JOIN @vocabulary_database_schema.concept c
  ON c.concept_id = cr.concept_id_2
WHERE s.vocabulary_id = 'ICD10CM'
  AND s.concept_code IN (@icd10_codes)
  AND c.standard_concept = 'S'
  AND c.vocabulary_id = 'SNOMED'
  AND c.invalid_reason IS NULL
;"

# OMOP stores ICD10CM codes dotted ('N17.0'); our CSV is undotted. ICD-10-CM
# dotting is positional: 3-character category, then the remainder.
dotIcd10 <- function(x) ifelse(nchar(x) > 3L,
                               paste0(substr(x, 1L, 3L), ".", substring(x, 4L)),
                               x)

pheno <- fread(csvFile, colClasses = "character")
src <- pheno[, .(icd10 = strsplit(ICD10, " ")[[1]]), by = .(Phenotype)]
codes <- unique(c(dotIcd10(src$icd10), src$icd10))

connection <- DatabaseConnector::connect(connectionDetails)
on.exit(DatabaseConnector::disconnect(connection))

# Chunked: Oracle caps an IN list at 1000 expressions.
chunks <- split(codes, ceiling(seq_along(codes) / 500L))
map <- rbindlist(lapply(chunks, function(chunk) {
  sql <- SqlRender::translate(
    SqlRender::render(sqlTemplate,
                      vocabulary_database_schema = vocabularyDatabaseSchema,
                      icd10_codes = paste0("'", chunk, "'", collapse = ",")),
    targetDialect = attr(connection, "dbms")
  )
  as.data.table(DatabaseConnector::querySql(connection, sql))
}))
setnames(map, SqlRender::snakeCaseToCamelCase(names(map)))
map[, icd10 := gsub(".", "", icd10Code, fixed = TRUE)]

snomed <- merge(src, map[, .(icd10, conceptId)], by = "icd10", allow.cartesian = TRUE)[
  , .(SNOMED = paste(sort(unique(conceptId)), collapse = " ")), by = Phenotype]

out <- merge(pheno, snomed, by = "Phenotype", all.x = TRUE)
out[is.na(SNOMED), SNOMED := ""]
setorder(out, Phenotype)

fwrite(out[, .(Phenotype, type, CCSR, ICD10, SNOMED)], csvFile, quote = TRUE)
