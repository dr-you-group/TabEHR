# Generates one outcome-cohort SQL file per row of codes/newdx_icd10_snomed.csv
# from extras/NewDxCohortTemplate.sql, and registers the cohorts in
# inst/settings/CohortsToCreate.csv.
#
#   Rscript extras/AddSnomedToNewDxCsv.R     # needs the database
#   Rscript extras/MakeNewDxCohortSql.R      # this one does not
#
# The SNOMED column holds direct 'Maps to' targets; the template expands their
# descendants itself through CONCEPT_ANCESTOR, which is the rule this outcome
# set is defined by: ICD-10 -> SNOMED -> descendants.
#
# Cohort ids come from the CohortId column of codes/newdx_icd10.csv rather than
# from the row order, so a reordered or extended file cannot silently renumber
# cohorts that are already built in a database.

csvFile <- "codes/newdx_icd10_snomed.csv"
templateFile <- "extras/NewDxCohortTemplate.sql"
sqlFolder <- "inst/sql/sql_server"
cohortsFile <- "inst/settings/CohortsToCreate.csv"
cohortType <- "new_diagnoses"

if (!file.exists(csvFile)) {
  stop(csvFile, " is missing. Run extras/AddSnomedToNewDxCsv.R first: it reads",
       " the ICD-10 to SNOMED mapping out of the site's own vocabulary.",
       call. = FALSE)
}
outcomes <- utils::read.csv(csvFile, colClasses = "character")
stopifnot(all(c("CohortId", "Outcome", "SNOMED") %in% names(outcomes)))

empty <- outcomes[!nzchar(trimws(outcomes$SNOMED)), ]
if (nrow(empty) > 0) {
  cat("skipping", nrow(empty), "outcome(s) with no SNOMED seed:",
      paste(empty$Outcome, collapse = ", "), "\n")
  cat("see codes/newdx_icd10_report.csv for which codes went missing\n")
}
outcomes <- outcomes[nzchar(trimws(outcomes$SNOMED)), ]
stopifnot(nrow(outcomes) > 0, !anyDuplicated(outcomes$CohortId),
          !anyDuplicated(outcomes$Outcome))

# The Outcome column is already a file-safe name (CamelCase, no spaces), which
# also keeps the generated files apart from the retired cohorts of the previous
# task set, whose names are snake_case.
outcomes$cohortName <- gsub("_+", "_", gsub("[^A-Za-z0-9]+", "_",
                                            outcomes$Outcome))
template <- paste(readLines(templateFile, warn = FALSE), collapse = "\n")

for (i in seq_len(nrow(outcomes))) {
  conceptIds <- paste(strsplit(trimws(outcomes$SNOMED[i]),
                               "[[:space:]]+")[[1]], collapse = ",")
  sql <- gsub("@concept_ids", conceptIds, template, fixed = TRUE)
  file <- file.path(sqlFolder, paste0(outcomes$cohortName[i], ".sql"))
  writeLines(sql, file)
  cat(sprintf("%-28s %4s  %3d seed concept(s) -> %s\n", outcomes$Outcome[i],
              outcomes$CohortId[i],
              length(strsplit(conceptIds, ",")[[1]]), file))
}

# Keep every hand-made cohort, replace any row this script wrote before.
cohorts <- utils::read.csv(cohortsFile, colClasses = "character")
cohorts <- cohorts[!cohorts$cohortId %in% outcomes$CohortId &
                     !cohorts$name %in% outcomes$cohortName, ]
cohorts <- rbind(cohorts, data.frame(
  atlasId = outcomes$CohortId,
  atlasName = outcomes$Outcome,
  cohortId = outcomes$CohortId,
  name = outcomes$cohortName,
  type = cohortType,
  stringsAsFactors = FALSE
))
cohorts <- cohorts[order(as.integer(cohorts$cohortId)), ]
utils::write.csv(cohorts, cohortsFile, row.names = FALSE, quote = FALSE)
cat("\nregistered", nrow(outcomes), "cohort(s) in", cohortsFile, "\n")
cat("next: regenerate the task definitions with",
    "Rscript extras/MakeStudySettingsJson.R from the TabEHR root\n")
