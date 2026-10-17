# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The downstream tasks. Three things happen here, in this order, and only the
# third is new:
#
#   1. the cohorts, restricted to the downstream patients
#   2. the extractions and the labels: PatientLevelPrediction decides which
#      cohort entries each task is allowed to use, from the task's time at
#      risk, prior outcome and washout settings, and SparseArray writes the
#      baseline featureExtractionLong next to them
#   3. the task input, which is allrecords filtered to each task row's
#      observation window
#
# The window filters records; the task settings filter rows. Time at risk is a
# row criterion, never a record filter: it describes the period AFTER the index
# date, so using it to select input would leak the outcome.

# Where the labels put a task's extraction, and the name this package gives it.
#' @noRd
.extractionName <- function(targetId, covariateSettingsId) {
  paste0("target", targetId, "_", covariateSettingsId)
}

#' The extractions a study settings file implies
#'
#' Read from the settings rather than listed anywhere, so the two cannot drift
#' apart. Many tasks share one extraction: the observation window comes from
#' the covariate settings block and the index date from the target cohort, so
#' only their distinct combinations are extracted.
#'
#' @param studySettingsFile The study settings JSON.
#'
#' @return A character vector of extraction names, each the name of a folder
#'   under `outputFolder/plpData`.
#' @export
studyExtractionNames <- function(studySettingsFile = system.file(
                                   "settings", "studySettings.json",
                                   package = "TabEHR"
                                 )) {
  spec <- loadStudySettings(studySettingsFile)
  vapply(
    studyExtractionGroups(spec),
    function(group) .extractionName(group$targetId, group$covariateSettingsId),
    ""
  )
}

# createLongFormat() writes featureExtractionLong.csv and its reference tables
# under one fixed name, so each extraction's files are moved aside before the
# next call overwrites them.
#' @noRd
.collectLongFormatFiles <- function(outputFolder, extraction) {
  target <- .ensureFolder(file.path(outputFolder, "longFormat", extraction))
  moved <- character(0)
  for (name in c("featureExtractionLong.csv", "covariateRef.csv",
                 "timeRef.csv", "analysisRef.csv")) {
    from <- file.path(outputFolder, name)
    if (!file.exists(from)) {
      next
    }
    to <- file.path(target, name)
    if (file.exists(to)) {
      unlink(to, force = TRUE)
    }
    if (!file.rename(from, to)) {
      stop("Could not move ", from, " to ", to, call. = FALSE)
    }
    moved <- c(moved, to)
  }
  moved
}

# The rows one extraction's input is built for, and how to line them up with
# allrecords.
#
# The labels carry PatientLevelPrediction's subjectId, which arrives in R as a
# double and so cannot be trusted to hold a 19-digit person_id exactly. It is
# only used as a join key here, and only after checking that no two study
# population patients share the same double: if that holds, the rounded value
# identifies a patient unambiguously even when it is not the patient's id. The
# join itself then runs on the allrecords row id, a dense integer, so no
# person_id arithmetic reaches the data.
#' @noRd
.taskRowsForExtraction <- function(labels, cohort, extraction) {
  rows <- labels[labels$extraction == extraction,
                 c("rowId", "subjectId", "targetCohortStartDate")]
  rows <- unique(rows)
  if (nrow(rows) == 0) {
    return(rows)
  }
  key <- as.numeric(cohort$personId)
  if (anyDuplicated(key)) {
    stop("Two study population patients round to the same double, so a ",
         "label row cannot be matched to a patient by subjectId. ",
         "checkDatabase() reports this as n_colliding_groups; the labels ",
         "would have to carry person_id as text instead.", call. = FALSE)
  }
  patient <- match(rows$subjectId, key)
  if (anyNA(patient)) {
    stop(sum(is.na(patient)), " of ", nrow(rows), " label row(s) in ",
         extraction, " name a patient that allrecords does not hold. The two ",
         "stages were run on different study populations.", call. = FALSE)
  }
  data.frame(
    taskRowId = rows$rowId,
    arRowId = cohort$rowId[patient],
    personId = cohort$personId[patient],
    indexDate = as.Date(rows$targetCohortStartDate),
    # Days between the whole-history index date and this task's index date, so
    # that a record's timeId can be shifted from one to the other with no date
    # arithmetic inside the join.
    shift = as.integer(cohort$indexDate[patient] -
                         as.Date(rows$targetCohortStartDate)),
    stringsAsFactors = FALSE
  )
}

# One batch of the joined query, written as task input rows.
#' @noRd
.taskInputBatch <- function(batch, map, connection) {
  if (nrow(batch) == 0) {
    return(0L)
  }
  covariate <- match(batch$covariateId, map$covariateId)
  if (anyNA(covariate)) {
    stop("The extraction holds ", sum(is.na(covariate)), " covariate id(s) ",
         "that covariateRef does not name.", call. = FALSE)
  }
  isValue <- map$analysisId[covariate] %in% .allRecordsValueAnalysisIds
  rows <- data.frame(
    row_id = batch$taskRowId,
    person_id = batch$personId,
    domain = map$domain[covariate],
    concept_id = format(map$conceptId[covariate], scientific = FALSE,
                        trim = TRUE),
    record_date = format(as.Date(batch$indexDate, origin = "1970-01-01") -
                           batch$taskTimeId, "%Y-%m-%d"),
    time_id = batch$taskTimeId,
    value_as_number = ifelse(isValue, batch$covariateValue, NA_real_),
    unit_concept_id = ifelse(isValue, map$unitConceptId[covariate], NA_real_),
    stringsAsFactors = FALSE
  )
  utils::write.table(rows, file = connection, sep = ",", row.names = FALSE,
                     col.names = FALSE, quote = FALSE, na = "")
  nrow(rows)
}

# allrecords, filtered to one extraction's rows and observation window.
#' @noRd
.writeTaskInput <- function(covariateData, map, taskRows, window, file,
                            batchSize) {
  covariateData$taskRows <- taskRows
  on.exit(try(covariateData$taskRows <- NULL, silent = TRUE), add = TRUE)
  # The window in FeatureExtraction's own sign convention: timeId counts days
  # backwards from the index date, so sequenceEndDay = 0 keeps the index day
  # and sequenceStartDay = -99999 keeps everything before it.
  lower <- -as.integer(window[["end"]])
  upper <- -as.integer(window[["start"]])

  rows <- covariateData$covariates %>%
    dplyr::inner_join(covariateData$taskRows,
                      by = c("rowId" = "arRowId")) %>%
    dplyr::mutate(taskTimeId = .data$timeId - .data$shift) %>%
    dplyr::filter(.data$taskTimeId >= !!lower,
                  .data$taskTimeId <= !!upper) %>%
    dplyr::select(dplyr::all_of(c("taskRowId", "personId", "indexDate",
                                  "covariateId", "covariateValue",
                                  "taskTimeId"))) %>%
    dplyr::arrange(.data$taskRowId, .data$taskTimeId, .data$covariateId)

  out <- gzfile(file, open = "wt")
  writeLines(
    paste(c("row_id", "person_id", "domain", "concept_id", "record_date",
            "time_id", "value_as_number", "unit_concept_id"), collapse = ","),
    out
  )
  written <- 0
  tryCatch(
    Andromeda::batchApply(
      rows,
      function(batch) {
        written <<- written + .taskInputBatch(batch, map, out)
      },
      batchSize = batchSize,
      progressBar = FALSE,
      safe = FALSE
    ),
    finally = close(out)
  )
  written
}

#' Build the downstream task inputs and labels
#'
#' Runs the cohorts, the extractions and the labels the study settings call
#' for, and then writes each extraction's input by filtering `allrecords` to
#' the rows and the observation window of that extraction.
#'
#' The input is written per extraction rather than per task, because the
#' observation window comes from the covariate settings block and the index
#' date from the target cohort: the 38 tasks of this study share three. The
#' labels stay per task, in `outcomeLabels.csv`, because the time at risk and
#' the prior outcome criteria differ.
#'
#' Time at risk never filters records. It describes the period after the index
#' date, so a record selected by it would leak the outcome; it decides which
#' rows exist, which is what [createOutcomeLabels()] applies through
#' [PatientLevelPrediction::createStudyPopulation()].
#'
#' @template databaseArgs
#' @param cdmDatabaseSchema Schema containing the OMOP CDM.
#' @param cohortTable Name of the SparseArray cohort table.
#' @param databaseId Identifier of this database, passed to PLP as the CDM
#'   database name.
#' @param studySettingsFile The study settings JSON.
#' @param restrictToDownstream Restrict the target cohorts to the downstream
#'   patients.
#' @param batchSize Rows per batch when a file is written.
#' @param createCohorts,extractData,createLabels,createLongFormat,createInput
#'   Run that step?
#'
#' @return Invisibly, a list with the cohort counts, the long format files and
#'   the input row counts.
#' @export
createTaskInput <- function(connectionDetails,
                            cdmDatabaseSchema,
                            vocabularyDatabaseSchema = cdmDatabaseSchema,
                            cohortDatabaseSchema,
                            cohortTable = "cohort",
                            tablePrefix = "tabehr_",
                            tempEmulationSchema = NULL,
                            outputFolder,
                            databaseId,
                            studySettingsFile = system.file(
                              "settings", "studySettings.json",
                              package = "TabEHR"
                            ),
                            restrictToDownstream = TRUE,
                            batchSize = 1e6,
                            createCohorts = TRUE,
                            extractData = TRUE,
                            createLabels = TRUE,
                            createLongFormat = TRUE,
                            createInput = TRUE) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertString(databaseId, min.chars = 1)
  checkmate::assertFlag(restrictToDownstream)
  checkmate::assertFileExists(studySettingsFile)
  .ensureFolder(outputFolder)
  tableNames <- getTabehrTableNames(tablePrefix)
  spec <- loadStudySettings(studySettingsFile)
  groups <- studyExtractionGroups(spec)

  restrictPersonTable <- if (restrictToDownstream) {
    tableNames$downstreamPerson
  } else {
    NULL
  }

  if (createCohorts) {
    ParallelLogger::logInfo(
      "Creating cohorts",
      if (is.null(restrictPersonTable)) "" else
        paste0(", restricted to ", restrictPersonTable)
    )
    SparseArray::createCohorts(
      connectionDetails = connectionDetails,
      cdmDatabaseSchema = cdmDatabaseSchema,
      vocabularyDatabaseSchema = vocabularyDatabaseSchema,
      cohortDatabaseSchema = cohortDatabaseSchema,
      cohortTable = cohortTable,
      oracleTempSchema = tempEmulationSchema,
      outputFolder = outputFolder,
      restrictPersonTable = restrictPersonTable
    )
  }

  if (extractData) {
    for (group in groups) {
      SparseArray::extractPlpData(
        connectionDetails = connectionDetails,
        cdmDatabaseSchema = cdmDatabaseSchema,
        cdmDatabaseName = databaseId,
        cohortDatabaseSchema = cohortDatabaseSchema,
        cohortTable = cohortTable,
        oracleTempSchema = tempEmulationSchema,
        outputFolder = outputFolder,
        extractionName = .extractionName(group$targetId,
                                         group$covariateSettingsId),
        targetId = group$targetId,
        outcomeIds = group$outcomeIds,
        covariateSettings = SparseArray::buildCovariateSettings(
          spec$covariateSettings[[group$covariateSettingsId]],
          paste0("covariateSettings$", group$covariateSettingsId)
        )
      )
    }
  }

  if (createLabels) {
    ParallelLogger::logInfo("Creating outcome labels")
    createOutcomeLabels(
      outputFolder = outputFolder,
      studySettingsFile = studySettingsFile
    )
  }

  longFormatFiles <- list()
  if (createLongFormat) {
    for (extraction in studyExtractionNames(studySettingsFile)) {
      ParallelLogger::logInfo("Writing the long format of ", extraction)
      SparseArray::createLongFormat(
        outputFolder = outputFolder,
        extraction = extraction,
        batchSize = batchSize
      )
      longFormatFiles[[extraction]] <- .collectLongFormatFiles(outputFolder,
                                                               extraction)
    }
  }

  inputRows <- list()
  if (createInput) {
    labelFile <- file.path(outputFolder, "outcomeLabels.csv")
    cohortFile <- file.path(outputFolder, "allrecords_cohort.csv")
    if (!file.exists(labelFile) || !file.exists(cohortFile)) {
      stop("The task input needs ", basename(labelFile), " and ",
           basename(cohortFile),
           ", so run createAllRecords() and the label step first.",
           call. = FALSE)
    }
    labels <- utils::read.csv(labelFile)
    cohort <- utils::read.csv(cohortFile, colClasses = c(person_id = "character"))
    names(cohort) <- SqlRender::snakeCaseToCamelCase(names(cohort))
    cohort$indexDate <- as.Date(cohort$indexDate)

    covariateData <- Andromeda::loadAndromeda(
      file.path(outputFolder, "allRecordsCovariates.zip")
    )
    on.exit({
      if (Andromeda::isValidAndromeda(covariateData)) {
        try(Andromeda::close(covariateData), silent = TRUE)
      }
    }, add = TRUE)
    Andromeda::createIndex(covariateData$covariates, "rowId")
    map <- .allRecordsCovariateMap(covariateData, outputFolder)

    for (group in groups) {
      extraction <- .extractionName(group$targetId, group$covariateSettingsId)
      taskRows <- .taskRowsForExtraction(labels, cohort, extraction)
      if (nrow(taskRows) == 0) {
        ParallelLogger::logWarn("No labelled rows for ", extraction,
                                ", so it has no input.")
        next
      }
      window <- .covariateWindowDays(
        SparseArray::buildCovariateSettings(
          spec$covariateSettings[[group$covariateSettingsId]],
          paste0("covariateSettings$", group$covariateSettingsId)
        )[[1]]
      )
      folder <- .ensureFolder(file.path(outputFolder, "taskInput", extraction))
      file <- file.path(folder, "input.csv.gz")
      ParallelLogger::logInfo(
        "Filtering allrecords to ", nrow(taskRows), " row(s) of ", extraction,
        ", days ", window[["start"]], " to ", window[["end"]]
      )
      inputRows[[extraction]] <- .writeTaskInput(
        covariateData, map, taskRows, window, file, batchSize
      )
      ParallelLogger::logInfo("Wrote ", inputRows[[extraction]],
                              " record(s) to ", file)
    }
  }

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  counts <- .queryTabehrSql(
    connection, "CohortCountsRestricted.sql",
    tempEmulationSchema = tempEmulationSchema,
    snakeCaseToCamelCase = FALSE,
    cohort_database_schema = cohortDatabaseSchema,
    cohort_table = cohortTable
  )
  writeTabehrCsv(counts,
                 file.path(outputFolder, "cohort_counts_restricted.csv"))

  invisible(list(cohortCounts = counts, longFormatFiles = longFormatFiles,
                 inputRows = inputRows))
}
