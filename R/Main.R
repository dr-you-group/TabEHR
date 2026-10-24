# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' Execute the analysis
#'
#' Runs the stages in order. Each one can be switched off, so a run can be
#' resumed where it stopped, and each one is also an exported function that can
#' be called on its own with the same arguments.
#'
#' The order is forced by one dependency chain: the study population needs the
#' record counts of [extractRecords()], the patient split needs the study
#' population, and `allrecords` is extracted for the patients that survived.
#' Everything downstream is derived from `allrecords`: the task inputs here,
#' and the MedRep comparison files in `extras/CreateMedRepFiles.R`.
#'
#' [extractRecords()] and [createAllRecords()] do not produce the same
#' records, and they are not meant to. The first applies the original MedRep
#' rules because that is what the study population criteria were defined on;
#' the second applies FeatureExtraction's, because the downstream inputs come
#' from the same extraction. [runDiagnostics()] reports the difference per
#' patient rather than hiding it.
#'
#' Run it once with `createPersonSampleSettings(samplePersonCount = 1000)`,
#' read `validation_report.md`, then run it again with `NULL` for the real
#' thing. Every table is rebuilt from the patients it admits, so the sample
#' setting has to change before `extractRecords()`, not halfway through.
#'
#' @template databaseArgs
#' @template analysisArgs
#' @param cohortTable Name of the SparseArray cohort table, in
#'   `cohortDatabaseSchema`.
#' @param databaseId Identifier of this database. It names the output folder in
#'   the convention of this project, `output/<databaseId>`, and is recorded in
#'   `run_info.json`.
#' @param studySettingsFile The study settings, which define the tasks.
#'   Defaults to the file installed with this package.
#' @param checkDatabase Check the assumptions about the database first?
#' @param extractRecords Extract the condition, drug, procedure and measurement
#'   records?
#' @param createStudyPopulation Apply the three study population criteria?
#' @param createPersonSplit Split the patients into pretraining and downstream?
#' @param createAllRecords Extract every record of every study population
#'   patient, which is the reference data everything else is derived from?
#' @param createTaskInput Build the downstream task inputs and labels?
#' @param runDiagnostics Check the output?
#' @param batchSize Rows per batch when large files are written.
#' @param andromedaTempFolder Optional directory for Andromeda's working files.
#'   Created when needed. The previous R option is restored after the run.
#'
#' @return Invisibly, `NULL`.
#' @export
execute <- function(connectionDetails,
                    cdmDatabaseSchema,
                    vocabularyDatabaseSchema = cdmDatabaseSchema,
                    cohortDatabaseSchema,
                    cohortTable = "cohort",
                    tablePrefix = "tabehr_",
                    tempEmulationSchema = NULL,
                    outputFolder,
                    databaseId,
                    analysisSettings = loadAnalysisSettings(),
                    studySettingsFile = system.file(
                      "settings", "studySettings.json",
                      package = "TabEHR"
                    ),
                    checkDatabase = TRUE,
                    extractRecords = TRUE,
                    createStudyPopulation = TRUE,
                    createPersonSplit = TRUE,
                    createAllRecords = TRUE,
                    createTaskInput = TRUE,
                    runDiagnostics = TRUE,
                    batchSize = 1e6,
                    andromedaTempFolder = NULL) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertString(databaseId, min.chars = 1)
  .ensureFolder(outputFolder)
  if (!is.null(andromedaTempFolder)) {
    checkmate::assertString(andromedaTempFolder, min.chars = 1)
    .ensureFolder(andromedaTempFolder)
    previousOptions <- options(andromedaTempFolder = andromedaTempFolder)
    on.exit(options(previousOptions), add = TRUE)
  }

  ParallelLogger::addDefaultFileLogger(file.path(outputFolder, "log.txt"))
  ParallelLogger::addDefaultErrorReportLogger(
    file.path(outputFolder, "errorReportR.txt")
  )
  on.exit(ParallelLogger::unregisterLogger("DEFAULT_FILE_LOGGER",
                                           silent = TRUE), add = TRUE)
  on.exit(ParallelLogger::unregisterLogger("DEFAULT_ERRORREPORT_LOGGER",
                                           silent = TRUE), add = TRUE)
  ParallelLogger::logInfo("TabEHR on ", databaseId, " (",
                          analysisSettings$siteRole, " site), writing to ",
                          outputFolder)

  if (checkDatabase) {
    ParallelLogger::logInfo("Checking the database")
    checkDatabase(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      vocabularyDatabaseSchema = vocabularyDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      databaseId = databaseId,
      analysisSettings = analysisSettings
    )
  }

  if (extractRecords) {
    extractRecords(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      vocabularyDatabaseSchema = vocabularyDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      analysisSettings = analysisSettings
    )
  }

  if (createStudyPopulation) {
    createStudyPopulation(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      vocabularyDatabaseSchema = vocabularyDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      analysisSettings = analysisSettings
    )
  }

  if (createPersonSplit) {
    createPersonSplit(
      connectionDetails = connectionDetails,
      cohortDatabaseSchema = cohortDatabaseSchema,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      analysisSettings = analysisSettings
    )
  }

  if (createAllRecords) {
    createAllRecords(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      analysisSettings = analysisSettings,
      batchSize = batchSize
    )
  }

  if (createTaskInput) {
    createTaskInput(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      vocabularyDatabaseSchema = vocabularyDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTable = cohortTable,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      databaseId = databaseId,
      studySettingsFile = studySettingsFile,
      batchSize = batchSize
    )
  }

  exportRunInfo(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    vocabularyDatabaseSchema = vocabularyDatabaseSchema,
    cohortDatabaseSchema = cohortDatabaseSchema,
    cohortTable = cohortTable,
    tablePrefix = tablePrefix,
    tempEmulationSchema = tempEmulationSchema,
    outputFolder = outputFolder,
    databaseId = databaseId,
    analysisSettings = analysisSettings
  )

  if (runDiagnostics) {
    runDiagnostics(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTable = cohortTable,
      tablePrefix = tablePrefix,
      tempEmulationSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      databaseId = databaseId,
      analysisSettings = analysisSettings
    )
  }

  ParallelLogger::logInfo("Done. Read ",
                          file.path(outputFolder, "validation_report.md"))
  invisible(NULL)
}
