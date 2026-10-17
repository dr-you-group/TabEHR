# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' Extract the records the trajectories are built from
#'
#' Ports the record extraction of the MedRep study, `create_trajectory.py`, to
#' SQL. Condition, drug and procedure records go into one table; measurements
#' go into another, because they carry a value and a unit and are reduced to one
#' record per hour before their values are binned.
#'
#' Several steps of the original silently drop records, and the SQL reproduces
#' them on purpose, since the aim is the same records rather than tidier ones: a
#' numeric measurement with no mapped unit disappears, a missing
#' `measurement_datetime` is not filled from `measurement_date`, and a drug
#' exposure with no end date is dropped. The SQL files name each case, and the
#' project's `OPEN_QUESTIONS.md` records how each was confirmed against
#' pandas.
#'
#' The measurement side is deliberately aligned to FeatureExtraction so that a
#' `featureExtractionLong.csv` row can be turned back into an `allrecords`
#' token by [covariateToToken()]: the concept filter is `concept_id <> 0` and
#' nothing else, the value comes from `value_as_number`, and the unit is grouped
#' by `unit_concept_id`. The SQL files say where each decision comes from.
#'
#' The measurement quantiles are not applied here: [createAllRecords()] applies
#' them at the end, once the quantile table exists.
#'
#' @template databaseArgs
#' @param analysisSettings An object of type `tabehrAnalysisSettings` as created
#'   by [createAnalysisSettings()].
#'
#' @return Invisibly, the names of the tables that were created.
#' @export
extractRecords <- function(connectionDetails,
                           cdmDatabaseSchema,
                           vocabularyDatabaseSchema = cdmDatabaseSchema,
                           cohortDatabaseSchema,
                           tablePrefix = "tabehr_",
                           tempEmulationSchema = NULL,
                           analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  tableNames <- getTabehrTableNames(tablePrefix)
  preprocess <- analysisSettings$preprocessSettings

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))

  sampleTable <- .personSampleTable(analysisSettings, cohortDatabaseSchema,
                                    tableNames)
  if (nzchar(sampleTable)) {
    ParallelLogger::logInfo(
      "Creating a person sample of ",
      analysisSettings$personSampleSettings$samplePersonCount, " patient(s)"
    )
    .executeTabehrSql(
      connection, "CreatePersonSample.sql",
      tempEmulationSchema = tempEmulationSchema,
      cdm_database_schema = cdmDatabaseSchema,
      person_sample_table = sampleTable,
      sample_person_count = analysisSettings$personSampleSettings$samplePersonCount
    )
  } else {
    ParallelLogger::logInfo("No person sample: every patient is in scope")
  }

  ParallelLogger::logInfo("Extracting condition, drug and procedure records")
  .executeTabehrSql(
    connection, "ExtractRecords.sql",
    tempEmulationSchema = tempEmulationSchema,
    cdm_database_schema = cdmDatabaseSchema,
    records_table = paste0(cohortDatabaseSchema, ".", tableNames$records),
    person_sample_table = sampleTable,
    date_min = preprocess$dateMin,
    date_max = .dateMaxBound(preprocess),
    adult_age_min = preprocess$adultAgeMin
  )

  ParallelLogger::logInfo("Extracting measurement records")
  .executeTabehrSql(
    connection, "ExtractMeasurements.sql",
    tempEmulationSchema = tempEmulationSchema,
    cdm_database_schema = cdmDatabaseSchema,
    measurements_table = paste0(cohortDatabaseSchema, ".",
                                tableNames$measurements),
    concept_unit_table = paste0(cohortDatabaseSchema, ".",
                                tableNames$conceptUnit),
    person_sample_table = sampleTable,
    date_min = preprocess$dateMin,
    date_max = .dateMaxBound(preprocess),
    adult_age_min = preprocess$adultAgeMin,
    min_concept_unit_count = preprocess$minConceptUnitCount,
    tie_break_column = preprocess$measurementTieBreakColumn,
    hour_of_day = hourOfDaySql(.dbms(connection), "M.measurement_datetime")
  )

  ParallelLogger::logInfo("Counting records per patient")
  .executeTabehrSql(
    connection, "CountRecords.sql",
    tempEmulationSchema = tempEmulationSchema,
    records_table = paste0(cohortDatabaseSchema, ".", tableNames$records),
    measurements_table = paste0(cohortDatabaseSchema, ".",
                                tableNames$measurements),
    record_counts_table = paste0(cohortDatabaseSchema, ".",
                                 tableNames$recordCounts)
  )

  invisible(unlist(tableNames[c("records", "measurements", "conceptUnit",
                                "recordCounts")], use.names = FALSE))
}
