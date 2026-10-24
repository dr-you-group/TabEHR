# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The reference data of this project. Everything else is derived from it: the
# downstream task inputs, the MedRep comparison files, and any later model
# input. It is extracted the same way the downstream inputs are, through
# SparseArray and FeatureExtraction, so that the two can never disagree about
# what a record is.
#
# The analysis id says which domain a covariate belongs to and which id formula
# it follows, so the conversion back to concept ids is a lookup in covariateRef
# plus one division. See
# SparseArray::createMeasurementValueUnitCovariateSettings() for 998 and 999.
.allRecordsDomains <- c(
  "101" = "cond",   # ConditionOccurrence, FeatureExtraction's DomainConcept.sql
  "301" = "drug",   # DrugExposure
  "501" = "proc",   # ProcedureOccurrence
  "998" = "meas",   # MeasurementValueUnit, this project's
  "999" = "meas"    # MeasurementNoValue, this project's
)

# Only the value analysis carries a number and a unit. A no-value measurement,
# and every condition, drug or procedure covariate, carries 1, which is a flag
# rather than a value, so allrecords leaves those two columns empty for them.
.allRecordsValueAnalysisIds <- 998

#' Settings for the whole-history extraction
#'
#' @param cohortId Cohort definition id of the one-row-per-patient cohort the
#'   extraction runs on. Keep it clear of the study's own cohort ids.
#' @param timeInterval Days per time interval. The window is always the whole
#'   history, so this only sets the resolution of `record_date`.
#' @param useConditionOccurrence,useDrugExposure,useProcedureOccurrence Extract
#'   those domains?
#' @param useMeasurementValueUnit Extract the measurements with
#'   [SparseArray::createMeasurementValueUnitCovariateSettings()].
#'   FeatureExtraction's own `useMeasurement` cannot be combined with it, see
#'   [SparseArray::buildCovariateSettings()].
#'
#' @return An object of class `tabehrAllRecordsSettings`.
#' @export
createAllRecordsSettings <- function(cohortId = 1100,
                                     timeInterval = 1,
                                     useConditionOccurrence = TRUE,
                                     useDrugExposure = TRUE,
                                     useProcedureOccurrence = TRUE,
                                     useMeasurementValueUnit = TRUE) {
  checkmate::assertInt(cohortId, lower = 1)
  checkmate::assertInt(timeInterval, lower = 1)
  checkmate::assertFlag(useConditionOccurrence)
  checkmate::assertFlag(useDrugExposure)
  checkmate::assertFlag(useProcedureOccurrence)
  checkmate::assertFlag(useMeasurementValueUnit)
  settings <- list(
    cohortId = as.numeric(cohortId),
    timeInterval = as.numeric(timeInterval),
    useConditionOccurrence = useConditionOccurrence,
    useDrugExposure = useDrugExposure,
    useProcedureOccurrence = useProcedureOccurrence,
    useMeasurementValueUnit = useMeasurementValueUnit
  )
  class(settings) <- "tabehrAllRecordsSettings"
  settings
}

# The flat argument list SparseArray::buildCovariateSettings() takes. The
# window is the whole history: the index date is the patient's last record and
# -99999 is how far back FeatureExtraction's own SQL reaches.
#' @noRd
.allRecordsCovariateSettingsArgs <- function(settings) {
  list(
    settingsType = "temporalSequence",
    timePart = "day",
    timeInterval = settings$timeInterval,
    sequenceStartDay = -99999,
    sequenceEndDay = 0,
    useConditionOccurrence = settings$useConditionOccurrence,
    useDrugExposure = settings$useDrugExposure,
    useProcedureOccurrence = settings$useProcedureOccurrence,
    useMeasurementValueUnit = settings$useMeasurementValueUnit
  )
}

# covariateRef plus the unit crosswalk, in the shape resolveCovariateId()
# reads: one row per covariate, two for a covariate id that two units share.
#' @noRd
.unitReference <- function(map, crosswalkFile) {
  crosswalk <- utils::read.csv(crosswalkFile,
                               colClasses = c(covariateId = "character"))
  reference <- map[, c("covariateId", "analysisId", "conceptId")]
  key <- as.character(reference$covariateId)
  reference$unitConceptId <- crosswalk$unitConceptId[
    match(key, crosswalk$covariateId)
  ]
  shared <- crosswalk[crosswalk$covariateId %in% key, ]
  shared <- shared[duplicated(shared$covariateId), ]
  if (nrow(shared) > 0) {
    extra <- reference[match(shared$covariateId, key), , drop = FALSE]
    extra$unitConceptId <- shared$unitConceptId
    reference <- rbind(reference, extra)
  }
  reference
}

# covariateId -> concept, domain, unit. Both inputs are one row per covariate
# rather than per record, so they fit in memory where the records do not.
#' @noRd
.allRecordsCovariateMap <- function(covariateData, outputFolder) {
  map <- dplyr::collect(covariateData$covariateRef)
  map <- unique(map[, c("covariateId", "analysisId", "conceptId")])
  unknown <- setdiff(as.character(map$analysisId), names(.allRecordsDomains))
  if (length(unknown) > 0) {
    stop("The extraction contains analysis id(s) this stage cannot place in a ",
         "domain: ", paste(unknown, collapse = ", "),
         ". Add them to .allRecordsDomains or leave them out of the settings.",
         call. = FALSE)
  }
  map$domain <- unname(.allRecordsDomains[as.character(map$analysisId)])

  crosswalkFile <- file.path(outputFolder, "measurementValueUnitRef.csv")
  map$unitConceptId <- NA_real_
  if (file.exists(crosswalkFile)) {
    unit <- resolveCovariateId(map$covariateId,
                               .unitReference(map, crosswalkFile))
    map$unitConceptId <- unit$unitConceptId
    ParallelLogger::logInfo(
      "Resolved the unit of ", sum(!is.na(map$unitConceptId)), " of ",
      sum(map$analysisId %in% .allRecordsValueAnalysisIds),
      " measurement value covariate(s)"
    )
  } else {
    ParallelLogger::logWarn(
      "No measurementValueUnitRef.csv in ", outputFolder, ", so allrecords ",
      "cannot say which unit a measurement was taken in."
    )
  }
  map
}

# One batch of extracted covariates, written as allrecords rows.
#' @noRd
.allRecordsBatch <- function(batch, map, cohort, connection) {
  if (nrow(batch) == 0) {
    return(0L)
  }
  covariate <- match(batch$covariateId, map$covariateId)
  patient <- match(as.character(batch$rowId), as.character(cohort$rowId))
  if (anyNA(covariate) || anyNA(patient)) {
    stop("The extraction holds ", sum(is.na(covariate)), " covariate id(s) ",
         "that covariateRef does not name and ", sum(is.na(patient)),
         " row id(s) the cohort does not hold.", call. = FALSE)
  }
  isValue <- map$analysisId[covariate] %in% .allRecordsValueAnalysisIds
  rows <- data.frame(
    person_id = cohort$personId[patient],
    domain = map$domain[covariate],
    concept_id = format(map$conceptId[covariate], scientific = FALSE,
                        trim = TRUE),
    record_date = format(cohort$indexDate[patient] - batch$timeId,
                         "%Y-%m-%d"),
    value_as_number = ifelse(isValue, batch$covariateValue, NA_real_),
    unit_concept_id = ifelse(isValue, map$unitConceptId[covariate], NA_real_),
    stringsAsFactors = FALSE
  )
  utils::write.table(rows, file = connection, sep = ",", row.names = FALSE,
                     col.names = FALSE, quote = FALSE, na = "")
  nrow(rows)
}

#' Extract every record of every study population patient
#'
#' The reference data of this project: one row per de-duplicated record, with
#' the raw value, for every patient in the study population. Not by admission,
#' and not binned.
#'
#' It is extracted through SparseArray and FeatureExtraction, the same path the
#' downstream task inputs come from, so the two cannot disagree about what a
#' record is. FeatureExtraction only extracts relative to an index date, so
#' this builds its own one-row-per-patient cohort whose index date is that
#' patient's last record and reads the whole history back from there, see
#' `AllRecordsCohort.sql`. `record_date` is `index_date - timeId`, so its
#' resolution is the time interval, one day by default, and the hour of a
#' record is not kept.
#'
#' The measurements come from
#' [SparseArray::createMeasurementValueUnitCovariateSettings()]: analysis 998
#' for a measurement with a numeric value and 999 for one without, which
#' together cover each measurement exactly once. Quantile bins are not applied
#' here; `extras/CreateMedRepFiles.R` does that, for the MedRep comparison.
#'
#' @template databaseArgs
#' @template analysisArgs
#' @param cdmDatabaseSchema Schema containing the OMOP CDM.
#' @param batchSize Rows per batch when the CSV is written.
#' @param overwrite Re-extract even if the saved extraction is already there?
#'
#' @return Invisibly, a list with the file written, the row count and the
#'   patient count.
#' @export
createAllRecords <- function(connectionDetails,
                             cdmDatabaseSchema,
                             cohortDatabaseSchema,
                             tablePrefix = "tabehr_",
                             tempEmulationSchema = NULL,
                             outputFolder,
                             analysisSettings = loadAnalysisSettings(),
                             batchSize = 1e6,
                             overwrite = FALSE) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertCount(batchSize, positive = TRUE)
  .ensureFolder(outputFolder)
  tableNames <- getTabehrTableNames(tablePrefix)
  settings <- analysisSettings$allRecordsSettings
  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)
  andromedaFile <- file.path(outputFolder, "allRecordsCovariates.zip")

  if (!file.exists(andromedaFile) || overwrite) {
    connection <- DatabaseConnector::connect(connectionDetails)
    ParallelLogger::logInfo("Building the whole-history cohort")
    .executeTabehrSql(
      connection, "AllRecordsCohort.sql",
      tempEmulationSchema = tempEmulationSchema,
      cdm_database_schema = cdmDatabaseSchema,
      study_population_table = qualified(tableNames$studyPopulation),
      allrecords_cohort_table = qualified(tableNames$allRecordsCohort),
      cohort_id = settings$cohortId
    )
    covariateSettings <- SparseArray::buildCovariateSettings(
      .allRecordsCovariateSettingsArgs(settings), "allRecordsSettings"
    )
    ParallelLogger::logInfo(
      "Extracting every record of the study population with ",
      length(covariateSettings), " covariate settings object(s)"
    )
    covariateData <- FeatureExtraction::getDbCovariateData(
      connection = connection,
      oracleTempSchema = tempEmulationSchema,
      cdmDatabaseSchema = cdmDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTable = tableNames$allRecordsCohort,
      cohortTableIsTemp = FALSE,
      cohortId = settings$cohortId,
      rowIdField = "row_id",
      covariateSettings = covariateSettings,
      aggregated = FALSE
    )
    DatabaseConnector::disconnect(connection)
    Andromeda::saveAndromeda(covariateData, andromedaFile)
    ParallelLogger::logInfo("Saved the extraction to ", andromedaFile)
  } else {
    ParallelLogger::logInfo("Keeping the extraction already in ",
                            andromedaFile)
  }

  # The unit of a measurement value covariate is not in the extraction, so it
  # is read back from the CDM, once per output folder.
  SparseArray::exportMeasurementValueUnitRef(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    oracleTempSchema = tempEmulationSchema,
    outputFolder = outputFolder,
    overwrite = overwrite
  )

  connection <- DatabaseConnector::connect(connectionDetails)
  cohort <- .queryTabehrSql(
    connection, "ExportAllRecordsCohort.sql",
    tempEmulationSchema = tempEmulationSchema,
    snakeCaseToCamelCase = TRUE,
    allrecords_cohort_table = qualified(tableNames$allRecordsCohort)
  )
  DatabaseConnector::disconnect(connection)
  cohort <- .assertCharacterIds(cohort, "personId")
  cohort$indexDate <- as.Date(cohort$indexDate)
  exportedCohort <- cohort
  names(exportedCohort) <- SqlRender::camelCaseToSnakeCase(names(exportedCohort))
  writeTabehrCsv(exportedCohort, file.path(outputFolder, "allrecords_cohort.csv"))

  covariateData <- Andromeda::loadAndromeda(andromedaFile)
  on.exit({
    if (Andromeda::isValidAndromeda(covariateData)) {
      try(Andromeda::close(covariateData), silent = TRUE)
    }
  }, add = TRUE)
  map <- .allRecordsCovariateMap(covariateData, outputFolder)

  file <- file.path(outputFolder, "allrecords.csv.gz")
  stagingFile <- tempfile("allrecords-", tmpdir = outputFolder,
                          fileext = ".csv.gz")
  on.exit(unlink(stagingFile, force = TRUE), add = TRUE)
  out <- gzfile(stagingFile, open = "wt")
  writeLines(
    paste(c("person_id", "domain", "concept_id", "record_date",
            "value_as_number", "unit_concept_id"), collapse = ","),
    out
  )
  written <- 0
  # Ordered by rowId, which is one patient here, so a reader can stream one
  # patient at a time without holding the whole file.
  rows <- covariateData$covariates %>%
    dplyr::arrange(.data$rowId, .data$timeId, .data$covariateId)
  tryCatch(
    Andromeda::batchApply(
      rows,
      function(batch) {
        written <<- written + .allRecordsBatch(batch, map, cohort, out)
      },
      batchSize = batchSize,
      progressBar = FALSE,
      safe = FALSE
    ),
    finally = close(out)
  )
  if (file.exists(file)) {
    unlink(file, force = TRUE)
  }
  if (!file.rename(stagingFile, file)) {
    stop("Failed to save allrecords.csv.gz.", call. = FALSE)
  }
  ParallelLogger::logInfo("Wrote ", written, " record(s) to ", file)
  invisible(list(file = file, rows = written, patients = nrow(cohort)))
}
