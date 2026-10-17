# Copyright 2026 SparseArray Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The measurement covariates of this package, and the unit crosswalk that makes
# them decodable. Two separate problems, two separate pieces.
#
# The first is that FeatureExtraction 3.2.0 cannot extract measurement values
# in a temporal sequence at all. The temporal sequence branch of its
# MeasurementValue.sql reads
#
#   FLOOR(DATEDIFF(@time_part, measurement_date, cohort.cohort_start_date)*1.0/@time_interval ) as time_id
#   ROW_NUMBER() OVER (...) AS rn,
#
# with no comma after `as time_id`, so the rendered SQL does not parse. The
# analysis is isDefault = FALSE in PrespecTemporalAnalyses.csv, which is
# presumably why the defect survived. So this package extracts measurements
# itself, through the extension point FeatureExtraction documents: a settings
# object of class covariateSettings carrying a `fun` attribute, with
# getDbCovariateData() accepting a list of them.
#
# Two analyses, 998 and 999, which partition the measurements rather than
# overlapping: 998 is a measurement with a numeric value, 999 one without. The
# id arithmetic is FeatureExtraction's own, so nothing downstream needs a new
# decoding rule, but the analysis ids are this package's, because the content
# differs from FeatureExtraction's 702 (the unit is read as
# COALESCE(unit_concept_id, 0), so a numeric measurement with no unit is kept
# rather than dropped) and because 702 cannot run here anyway. 998 and 999 are
# free in both of FeatureExtraction's prespecified analysis sets, which stop at
# 926. FeatureExtraction's own useMeasurement (701) must stay off: it covers
# every measurement, so it would emit a second covariate for records 998
# already has.
#
# The second problem is that a measurement value covariate id carries the unit
# only as `unit_concept_id % 1000`, and covariateRef has no column for the
# unit, so the (concept, unit) pair cannot be read back from an extraction.
# That pair is what a quantile table is keyed on. The column cannot be added to
# this builder's covariateRef either: FeatureExtraction merges the results of
# several settings objects with Andromeda::appendToTable(), which selects the
# columns of the table it is appending TO, select(data, all_of(colnames(tbl))),
# so a fifth column would be dropped on the way in. The pair is therefore
# recovered where it came from, the CDM: the id is a function of the pair, so
# MeasurementValueUnitRef.sql reproduces the same arithmetic over the
# measurement table and writes the crosswalk next to the extraction.
# createLongFormat() joins its unitConceptId into covariateRef.csv.

# One file per output folder: the crosswalk depends on the database and the
# analysis id, not on the cohort, so every extraction in a folder shares it.
.measurementValueUnitRefFile <- "measurementValueUnitRef.csv"

#' Settings for the measurement covariates
#'
#' A custom FeatureExtraction covariate builder for the measurements of a
#' temporal sequence extraction, because the temporal sequence branch of
#' FeatureExtraction's own `MeasurementValue.sql` does not render to valid SQL
#' in version 3.2.0.
#'
#' Two analyses that partition the measurements: `analysisId` for a measurement
#' with a numeric value, built with FeatureExtraction's `MeasurementValue.sql`
#' arithmetic, and `noValueAnalysisId` for one without, built with its
#' `DomainConcept.sql` arithmetic and emitted only where the same row, concept
#' and interval produced no value covariate. One record is one covariate.
#'
#' In the study settings these covariates are asked for with
#' `useMeasurementValueUnit`. FeatureExtraction's own `useMeasurement` must
#' stay off, which [buildCovariateSettings()] enforces.
#'
#' @param timePart Time unit of the sequence. Only `"day"` is supported, which
#'   is the only unit SqlRender translates `DATEDIFF` for.
#' @param timeInterval Days per interval, as in
#'   [FeatureExtraction::createTemporalSequenceCovariateSettings()].
#' @param sequenceStartDay,sequenceEndDay The covariate window, in days
#'   relative to the index date.
#' @param analysisId Analysis id of the measurements with a numeric value.
#' @param noValueAnalysisId Analysis id of the measurements without one. Both
#'   default into the 99x block, which is free in both of FeatureExtraction's
#'   prespecified analysis sets.
#'
#' @return An object of class `covariateSettings` carrying the `fun` attribute
#'   FeatureExtraction dispatches on.
#' @export
createMeasurementValueUnitCovariateSettings <- function(timePart = "day",
                                                        timeInterval = 1,
                                                        sequenceStartDay = -99999,
                                                        sequenceEndDay = 0,
                                                        analysisId = 998,
                                                        noValueAnalysisId = 999) {
  checkmate::assertString(timePart, min.chars = 1)
  checkmate::assertInt(timeInterval, lower = 1)
  checkmate::assertInt(sequenceStartDay)
  checkmate::assertInt(sequenceEndDay)
  checkmate::assertInt(analysisId, lower = 1, upper = 999)
  checkmate::assertInt(noValueAnalysisId, lower = 1, upper = 999)
  if (!identical(tolower(timePart), "day")) {
    stop("Only timePart = 'day' is supported: SqlRender translates DATEDIFF ",
         "for the day unit only.", call. = FALSE)
  }
  if (sequenceStartDay > sequenceEndDay) {
    stop("sequenceStartDay (", sequenceStartDay, ") must not be after ",
         "sequenceEndDay (", sequenceEndDay, ").", call. = FALSE)
  }
  if (identical(analysisId, noValueAnalysisId)) {
    stop("analysisId and noValueAnalysisId must differ: the analysis id is ",
         "what says which id formula a covariate follows.", call. = FALSE)
  }

  settings <- list(
    timePart = tolower(timePart),
    timeInterval = timeInterval,
    sequenceStartDay = sequenceStartDay,
    sequenceEndDay = sequenceEndDay,
    analysisId = analysisId,
    noValueAnalysisId = noValueAnalysisId
  )
  attr(settings, "fun") <- "SparseArray::getDbMeasurementValueUnitCovariateData"
  class(settings) <- "covariateSettings"
  settings
}

#' Build the measurement covariates
#'
#' Called by [FeatureExtraction::getDbCovariateData()], and so by
#' [PatientLevelPrediction::getPlpData()], for settings made by
#' [createMeasurementValueUnitCovariateSettings()]. Not meant to be called
#' directly.
#'
#' The argument list is the one FeatureExtraction documents for a custom
#' builder. `oracleTempSchema` and `cohortId` are accepted as well, because
#' different versions of the caller pass one or the other name.
#'
#' @param connection An open DatabaseConnector connection.
#' @param tempEmulationSchema,oracleTempSchema Schema used to emulate temporary
#'   tables.
#' @param cdmDatabaseSchema Schema holding the OMOP CDM.
#' @param cdmVersion Ignored.
#' @param cohortTable Table holding the cohort FeatureExtraction has restricted.
#' @param cohortIds,cohortId Cohort definition ids to keep, or `-1` for all.
#' @param rowIdField Column of `cohortTable` carrying the row id.
#' @param covariateSettings From
#'   [createMeasurementValueUnitCovariateSettings()].
#' @param targetCovariateTable,targetCovariateContinuousTable,targetCovariateRefTable,targetAnalysisRefTable,targetTimeRefTable
#'   Ignored: this builder returns a `CovariateData` object rather than writing
#'   to target tables.
#' @param aggregated Not supported.
#' @param minCharacterizationMean,minCharacterizationCount Ignored.
#' @param ... Swallowed, so a caller that passes more arguments still works.
#'
#' @return A FeatureExtraction `CovariateData` object with `covariates`,
#'   `covariateRef` and `analysisRef`. Deliberately no `timeRef`: a temporal
#'   sequence `timeRef` is exactly one row describing the parameterization, and
#'   the settings these covariates run alongside already provide it.
#' @export
getDbMeasurementValueUnitCovariateData <- function(connection,
                                                   tempEmulationSchema = NULL,
                                                   cdmDatabaseSchema,
                                                   cdmVersion = "5",
                                                   cohortTable = "#cohort_person",
                                                   cohortIds = c(-1),
                                                   cohortId = NULL,
                                                   rowIdField = "subject_id",
                                                   covariateSettings,
                                                   targetCovariateTable = NULL,
                                                   targetCovariateContinuousTable = NULL,
                                                   targetCovariateRefTable = NULL,
                                                   targetAnalysisRefTable = NULL,
                                                   targetTimeRefTable = NULL,
                                                   aggregated = FALSE,
                                                   minCharacterizationMean = 0,
                                                   minCharacterizationCount = 0,
                                                   oracleTempSchema = NULL,
                                                   ...) {
  if (isTRUE(aggregated)) {
    stop("getDbMeasurementValueUnitCovariateData() does not support ",
         "aggregated covariates. getPlpData() does not ask for them.",
         call. = FALSE)
  }
  if (is.null(tempEmulationSchema)) {
    tempEmulationSchema <- oracleTempSchema
  }
  if (!is.null(cohortId)) {
    cohortIds <- cohortId
  }
  settings <- covariateSettings
  dbms <- attr(connection, "dbms")
  ParallelLogger::logInfo(
    "Building measurement covariates, analyses ", settings$analysisId, " and ",
    settings$noValueAnalysisId, ", for rowIdField = ", rowIdField, " in ",
    cohortTable
  )

  # -1 means every cohort in the table, which is what FeatureExtraction's own
  # SQL takes it to mean.
  cohortIdClause <- if (length(cohortIds) == 1 && cohortIds[1] == -1) {
    ""
  } else {
    paste0("\t\tAND cohort.cohort_definition_id IN (",
           paste(cohortIds, collapse = ", "), ")")
  }

  sql <- SqlRender::loadRenderTranslateSql(
    sqlFilename = "MeasurementValueUnit.sql",
    packageName = "SparseArray",
    dbms = dbms,
    tempEmulationSchema = tempEmulationSchema,
    cdm_database_schema = cdmDatabaseSchema,
    cohort_table = cohortTable,
    row_id_field = rowIdField,
    cohort_id_clause = cohortIdClause,
    analysis_id = settings$analysisId,
    no_value_analysis_id = settings$noValueAnalysisId,
    time_part = toupper(settings$timePart),
    time_interval = settings$timeInterval,
    sequence_start_day = settings$sequenceStartDay,
    sequence_end_day = settings$sequenceEndDay
  )
  DatabaseConnector::executeSql(connection, sql, progressBar = FALSE,
                                reportOverallTime = FALSE)

  covariateData <- Andromeda::andromeda()
  sources <- c(covariates = "#mvu_data", covariateRef = "#mvu_ref")
  for (table in names(sources)) {
    DatabaseConnector::querySqlToAndromeda(
      connection = connection,
      sql = SqlRender::translate(
        paste0("SELECT * FROM ", sources[[table]], ";"),
        targetDialect = dbms,
        tempEmulationSchema = tempEmulationSchema
      ),
      andromeda = covariateData,
      andromedaTableName = table,
      snakeCaseToCamelCase = TRUE
    )
  }
  for (source in sources) {
    DatabaseConnector::executeSql(
      connection,
      SqlRender::translate(
        paste0("TRUNCATE TABLE ", source, "; DROP TABLE ", source, ";"),
        targetDialect = dbms,
        tempEmulationSchema = tempEmulationSchema
      ),
      progressBar = FALSE, reportOverallTime = FALSE
    )
  }

  # The columns and the values FeatureExtraction's own analysis_ref insert
  # writes: start_day and end_day are present but NULL whenever the extraction
  # is not a temporal window extraction, because the window is described by
  # timeRef instead. The no-value analysis is binary with missing meaning zero,
  # as every DomainConcept analysis is.
  covariateData$analysisRef <- data.frame(
    analysisId = c(settings$analysisId, settings$noValueAnalysisId),
    analysisName = c("MeasurementValueUnit", "MeasurementNoValue"),
    domainId = c("Measurement", "Measurement"),
    startDay = c(NA_integer_, NA_integer_),
    endDay = c(NA_integer_, NA_integer_),
    isBinary = c("N", "Y"),
    missingMeansZero = c("N", "Y"),
    stringsAsFactors = FALSE
  )

  attr(covariateData, "metaData") <- list(sql = sql, call = match.call())
  class(covariateData) <- "CovariateData"
  attr(class(covariateData), "package") <- "FeatureExtraction"
  covariateData
}

# Built from the temporal arguments of the settings block that asked for it, so
# the window of these covariates is the window of the rest of the extraction by
# construction rather than by agreement.
#' @noRd
.measurementValueUnitSettings <- function(args) {
  createMeasurementValueUnitCovariateSettings(
    timePart = args[["timePart"]],
    timeInterval = args[["timeInterval"]],
    sequenceStartDay = args[["sequenceStartDay"]],
    sequenceEndDay = args[["sequenceEndDay"]]
  )
}

#' Write the measurement unit crosswalk
#'
#' The `(covariateId, conceptId, unitConceptId, recordCount)` table of every
#' measurement value covariate the database can produce, which is what makes
#' such a covariate decodable: the id keeps the unit only as
#' `unit_concept_id % 1000`, and `covariateRef` has no column for the unit.
#'
#' One file per output folder, because it depends on the database and the
#' analysis id rather than on the cohort. [createLongFormat()] joins its
#' `unitConceptId` into `covariateRef.csv`.
#'
#' @param connectionDetails A DatabaseConnector connection-details object.
#' @param cdmDatabaseSchema Schema containing the OMOP CDM.
#' @param oracleTempSchema Schema used to emulate temporary tables.
#' @param outputFolder Folder the file is written to.
#' @param analysisId Analysis id the ids were built with, see
#'   [createMeasurementValueUnitCovariateSettings()].
#' @param overwrite Rewrite the file if it is already there?
#'
#' @return Invisibly, the path written.
#' @export
exportMeasurementValueUnitRef <- function(connectionDetails,
                                          cdmDatabaseSchema,
                                          oracleTempSchema = NULL,
                                          outputFolder,
                                          analysisId = 998,
                                          overwrite = FALSE) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertInt(analysisId, lower = 1, upper = 999)
  if (!file.exists(outputFolder)) {
    dir.create(outputFolder, recursive = TRUE)
  }
  file <- file.path(outputFolder, .measurementValueUnitRefFile)
  if (file.exists(file) && !overwrite) {
    ParallelLogger::logInfo("Keeping the unit crosswalk already in ", file)
    return(invisible(file))
  }
  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))
  ParallelLogger::logInfo(
    "Reading the measurement value unit crosswalk from ", cdmDatabaseSchema,
    ".measurement"
  )
  crosswalk <- DatabaseConnector::querySql(
    connection,
    SqlRender::loadRenderTranslateSql(
      sqlFilename = "MeasurementValueUnitRef.sql",
      packageName = "SparseArray",
      dbms = attr(connection, "dbms"),
      tempEmulationSchema = oracleTempSchema,
      cdm_database_schema = cdmDatabaseSchema,
      analysis_id = analysisId
    ),
    snakeCaseToCamelCase = TRUE
  )
  collisions <- unique(crosswalk$covariateId[duplicated(crosswalk$covariateId)])
  if (length(collisions) > 0) {
    ParallelLogger::logWarn(
      length(collisions), " measurement value covariate id(s) stand for more ",
      "than one unit, because the id keeps the unit only modulo 1000. Their ",
      "values mix units, and ", .measurementValueUnitRefFile, " has one row ",
      "per unit for them. First: ",
      paste(utils::head(collisions, 5), collapse = ", ")
    )
  }
  utils::write.csv(crosswalk, file, row.names = FALSE)
  ParallelLogger::logInfo("Wrote the unit crosswalk of ", nrow(crosswalk),
                          " (concept, unit) pair(s) to ", file)
  invisible(file)
}
