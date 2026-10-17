# Copyright 2026 SparseArray Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# One extraction is one target cohort and one covariate settings block. This
# package extracts; which extractions a study needs, and what they are called,
# belongs to the study definition and is decided by the caller.
#' @noRd
.extractionFolder <- function(outputFolder, extractionName) {
  file.path(outputFolder, "plpData", extractionName)
}

#' @noRd
.listExtractionFolders <- function(outputFolder) {
  root <- file.path(outputFolder, "plpData")
  if (!dir.exists(root)) {
    return(character(0))
  }
  dirs <- list.dirs(root, full.names = TRUE, recursive = FALSE)
  dirs[dir.exists(dirs)]
}

# The covariateData the downstream stages read. getPlpData() keeps the
# FeatureExtraction object intact inside plpData$covariateData, timeRef
# included, and savePlpData() writes it with Andromeda::saveAndromeda(), so the
# table this package builds its time axis from survives the round trip.
#' @noRd
.loadCovariateDataFrom <- function(outputFolder, extraction = NULL) {
  folders <- .listExtractionFolders(outputFolder)
  if (!is.null(extraction)) {
    folder <- .extractionFolder(outputFolder, extraction)
    if (!dir.exists(folder)) {
      stop("Cannot find the extraction ", extraction, " in ", outputFolder,
           ". Available: ", paste(basename(folders), collapse = ", "),
           call. = FALSE)
    }
    return(PatientLevelPrediction::loadPlpData(folder)$covariateData)
  }
  if (length(folders) == 1) {
    return(PatientLevelPrediction::loadPlpData(folders)$covariateData)
  }
  if (length(folders) > 1) {
    stop(
      "There are ", length(folders), " extractions in ", outputFolder,
      ", so one has to be named: ",
      paste(basename(folders), collapse = ", "), ".",
      call. = FALSE
    )
  }
  # Output written before the study settings existed.
  covariateFile <- file.path(outputFolder, "covariateData")
  if (file.exists(covariateFile)) {
    return(FeatureExtraction::loadCovariateData(covariateFile))
  }
  stop("Cannot find a saved plpData under ", file.path(outputFolder, "plpData"),
       ". Run extractPlpData() first.", call. = FALSE)
}

#' @noRd
.logCovariateSettings <- function(covariateSettings) {
  # The first object is FeatureExtraction's own, which is the one that carries
  # the time axis. See buildCovariateSettings().
  settings <- if (inherits(covariateSettings, "covariateSettings")) {
    covariateSettings
  } else {
    covariateSettings[[1]]
  }
  if (.isTemporalSequenceSettings(settings)) {
    ParallelLogger::logInfo(
      "Extracting a temporal sequence of ", settings$timeInterval, " ",
      tolower(settings$timePart), "(s) per position, covering days ",
      settings$sequenceStartDay, " to ", settings$sequenceEndDay,
      " relative to the index date"
    )
  } else if (.isTemporalWindowSettings(settings)) {
    ParallelLogger::logInfo(
      "Extracting ",
      length(settings$temporalStartDays),
      " time windows spanning days ",
      min(settings$temporalStartDays),
      " to ",
      max(settings$temporalEndDays)
    )
  } else {
    stop(
      "The covariate settings are neither temporal sequence nor temporal ",
      "window settings. Use the arguments of ",
      "FeatureExtraction::createTemporalSequenceCovariateSettings() or ",
      "FeatureExtraction::createTemporalCovariateSettings().",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Extract one plpData
#'
#' Runs [PatientLevelPrediction::getPlpData()] for one target cohort and one
#' set of covariate settings, and saves the result under
#' `outputFolder/plpData/<extractionName>`. Many outcomes and many tasks share
#' one extraction, so the caller decides how few of these are needed.
#'
#' PLP builds the at risk cohort, assigns a `rowId` that is unique per cohort
#' entry rather than per subject, extracts the covariates through
#' FeatureExtraction, and fetches the outcomes, so nothing here reimplements
#' that SQL. Because `rowId` is one cohort entry, a target cohort with several
#' entries per subject is handled natively.
#'
#' `plpData$timeRef` is only populated by PLP for
#' [FeatureExtraction::createTemporalCovariateSettings()], so this package reads
#' the time axis from `plpData$covariateData$timeRef`, the table
#' FeatureExtraction itself writes, which is populated for both settings
#' families.
#'
#' @param connectionDetails A DatabaseConnector connection-details object.
#' @param cdmDatabaseSchema Schema containing the OMOP CDM.
#' @param cdmDatabaseName Human readable database name, passed through to
#'   [PatientLevelPrediction::createDatabaseDetails()].
#' @param cohortDatabaseSchema Schema containing the cohort table.
#' @param cohortTable Name of the cohort table.
#' @param oracleTempSchema Schema used to emulate temporary tables.
#' @param outputFolder Folder for the saved extractions.
#' @param extractionName Name of this extraction, used as the folder name.
#' @param targetId Cohort definition id of the target cohort.
#' @param outcomeIds Cohort definition ids of the outcomes to fetch.
#' @param covariateSettings One `covariateSettings` object or a list of them,
#'   as [buildCovariateSettings()] returns.
#' @param restrictPlpDataSettings Object from
#'   [PatientLevelPrediction::createRestrictPlpDataSettings()]. Note that
#'   `firstExposureOnly` and `washoutPeriod` exist here and in the study
#'   population settings; applying them here drops the rows before the
#'   covariates are extracted.
#' @param overwrite Overwrite an extraction that is already saved?
#'
#' @return Invisibly, the folder written.
#' @export
extractPlpData <- function(connectionDetails,
                           cdmDatabaseSchema,
                           cdmDatabaseName = cdmDatabaseSchema,
                           cohortDatabaseSchema = cdmDatabaseSchema,
                           cohortTable = "cohort",
                           oracleTempSchema = cohortDatabaseSchema,
                           outputFolder,
                           extractionName,
                           targetId,
                           outcomeIds,
                           covariateSettings,
                           restrictPlpDataSettings =
                             PatientLevelPrediction::createRestrictPlpDataSettings(),
                           overwrite = FALSE) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertString(extractionName, min.chars = 1)
  checkmate::assertNumeric(targetId, len = 1)
  checkmate::assertNumeric(outcomeIds, min.len = 1)
  folder <- .extractionFolder(outputFolder, extractionName)
  if (dir.exists(folder)) {
    if (!overwrite) {
      ParallelLogger::logInfo("Keeping the extraction already in ", folder)
      return(invisible(folder))
    }
    unlink(folder, recursive = TRUE, force = TRUE)
  }

  ParallelLogger::logInfo(
    "Extracting ", extractionName, " for target ", targetId, " and ",
    length(outcomeIds), " outcome(s)"
  )
  .logCovariateSettings(covariateSettings)

  databaseDetails <- PatientLevelPrediction::createDatabaseDetails(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    cdmDatabaseName = cdmDatabaseName,
    cdmDatabaseId = cdmDatabaseName,
    tempEmulationSchema = oracleTempSchema,
    cohortDatabaseSchema = cohortDatabaseSchema,
    cohortTable = cohortTable,
    outcomeDatabaseSchema = cohortDatabaseSchema,
    outcomeTable = cohortTable,
    targetId = targetId,
    outcomeIds = outcomeIds
  )
  plpData <- PatientLevelPrediction::getPlpData(
    databaseDetails = databaseDetails,
    covariateSettings = covariateSettings,
    restrictPlpDataSettings = restrictPlpDataSettings
  )
  PatientLevelPrediction::savePlpData(plpData, folder)
  ParallelLogger::logInfo("Saved the extraction to ", folder)
  invisible(folder)
}
