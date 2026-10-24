# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The checks. Nobody can reach the study database from a development machine,
# so every check is something the person running the study executes, and every
# result lands in validation_report.md next to the CSV files, where it can be
# read or pasted back without further digging.

#' @noRd
.newReport <- function(title, databaseId, dbms) {
  list(title = title, databaseId = databaseId, dbms = dbms,
       startedAt = Sys.time(), sections = list())
}

#' @noRd
.addSection <- function(report, title, data = NULL, notes = NULL,
                        status = "info") {
  report$sections[[length(report$sections) + 1]] <- list(
    title = title, data = data, notes = notes, status = status
  )
  report
}

#' @noRd
.checkStatus <- function(condition, failStatus = "fail") {
  if (isTRUE(condition)) "ok" else failStatus
}

#' @noRd
.markdownTable <- function(data) {
  if (is.null(data) || nrow(data) == 0) {
    return("_(no rows)_")
  }
  data <- .formatForCsv(data)
  cells <- lapply(data, function(column) {
    value <- as.character(column)
    value[is.na(value)] <- ""
    value
  })
  rows <- vapply(seq_len(nrow(data)), function(i) {
    paste0("| ", paste(vapply(cells, function(column) column[i], ""),
                       collapse = " | "), " |")
  }, "")
  paste(c(
    paste0("| ", paste(names(data), collapse = " | "), " |"),
    paste0("| ", paste(rep("---", length(data)), collapse = " | "), " |"),
    rows
  ), collapse = "\n")
}

# Appended, not overwritten, so a run of several stages builds up one file.
#' @noRd
.writeReport <- function(report, outputFolder) {
  path <- file.path(.ensureFolder(outputFolder), "validation_report.md")
  lines <- c(
    "",
    paste0("## ", report$title),
    "",
    paste0("- databaseId: `", report$databaseId, "`"),
    paste0("- dbms: `", report$dbms, "`"),
    paste0("- run at: ", format(report$startedAt, "%Y-%m-%d %H:%M:%S")),
    ""
  )
  for (section in report$sections) {
    mark <- switch(section$status, ok = "OK", warn = "WARNING",
                   fail = "FAILED", "info")
    lines <- c(lines, paste0("### ", section$title, " — ", mark), "")
    if (!is.null(section$notes)) {
      lines <- c(lines, paste0("- ", section$notes), "")
    }
    if (!is.null(section$data)) {
      lines <- c(lines, .markdownTable(section$data), "")
    }
  }
  if (!file.exists(path)) {
    lines <- c(
      "# TabEHR validation report",
      "",
      "Each run appends a section; the newest is at the bottom.",
      lines
    )
    writeLines(lines, path)
  } else {
    writeLines(c(readLines(path, warn = FALSE), lines), path)
  }
  ParallelLogger::logInfo("Appended \"", report$title, "\" to ", path)
  invisible(path)
}

#' @noRd
.asMetricTable <- function(row) {
  data.frame(
    metric = names(row),
    value = vapply(row, function(column) as.character(column[1]),
                   character(1), USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )
}

#' Check the assumptions this package makes about the database
#'
#' Run this first. It only reads, apart from one small table it creates and
#' drops to prove it may write, and it answers the questions the rest of the
#' package depends on:
#'
#' \itemize{
#'   \item are the packages installed, at the versions the image pins
#'   \item does a 19 digit BIGINT reach R intact, and does
#'     `databaseConnectorInteger64AsNumeric` change anything on this version
#'   \item how large are the `person_id` values here, and would rounding them to
#'     a double merge two patients
#'   \item may this account create tables in `cohortDatabaseSchema`
#'   \item do the measurement columns the port needs exist, and how often are
#'     they missing
#'   \item which vocabulary version is in use
#' }
#'
#' @template databaseArgs
#' @template analysisArgs
#' @param databaseId Identifier of the database this run reads.
#'
#' @return Invisibly, the path of the report.
#' @export
checkDatabase <- function(connectionDetails,
                          cdmDatabaseSchema,
                          vocabularyDatabaseSchema = cdmDatabaseSchema,
                          cohortDatabaseSchema,
                          tablePrefix = "tabehr_",
                          tempEmulationSchema = NULL,
                          outputFolder,
                          databaseId,
                          analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  tableNames <- getTabehrTableNames(tablePrefix)
  report <- .newReport("Database check", databaseId, connectionDetails$dbms)

  packages <- c("DatabaseConnector", "SqlRender", "FeatureExtraction",
                "PatientLevelPrediction", "Andromeda", "ParallelLogger",
                "SparseArray", "TabEHR", "jsonlite", "checkmate", "bit64")
  versions <- data.frame(
    package = packages,
    version = vapply(packages, function(name) {
      value <- .packageVersionOrNa(name)
      if (is.na(value)) "MISSING" else value
    }, ""),
    stringsAsFactors = FALSE
  )
  absent <- versions$package[versions$version == "MISSING"]
  report <- .addSection(
    report, "Installed packages", versions,
    notes = c(
      paste0("missing: ", if (length(absent) == 0) "none" else
        paste(absent, collapse = ", ")),
      paste0("R: ", R.version.string),
      if ("PatientLevelPrediction" %in% absent)
        "SparseArray Imports PatientLevelPrediction, so it cannot even be installed without it."
      else ""
    ),
    status = .checkStatus(length(absent) == 0)
  )

  report <- .addSection(
    report, "Dialect expression for this dbms",
    data.frame(
      what = "hour of day",
      expression = hourOfDaySql(connectionDetails$dbms,
                                "M.measurement_datetime"),
      stringsAsFactors = FALSE
    ),
    notes = paste0(
      "SqlRender v1.9.0 translates neither DATEPART nor DATEDIFF(HOUR), so ",
      "the hour of day is supplied per dialect. Dialects covered: ",
      paste(supportedDialects(), collapse = ", "), "."
    ),
    status = "info"
  )

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))

  # The option is read when a result is converted, so it is set, the query is
  # run, and the two columns of each row are compared.
  roundTrip <- function(asNumeric) {
    options(databaseConnectorInteger64AsNumeric = asNumeric)
    result <- tryCatch(
      .queryTabehrSql(connection, "CheckBigintRoundTrip.sql",
                      tempEmulationSchema = tempEmulationSchema),
      error = function(e) NULL
    )
    if (is.null(result) || !"asBigint" %in% names(result)) {
      return(data.frame(option_integer64AsNumeric = asNumeric,
                        label = "QUERY FAILED", bigint_class = NA_character_,
                        bigint_as_character = NA_character_,
                        text_from_sql = NA_character_, intact = NA,
                        stringsAsFactors = FALSE))
    }
    data.frame(
      option_integer64AsNumeric = asNumeric,
      label = result$label,
      bigint_class = class(result$asBigint)[1],
      bigint_as_character = as.character(result$asBigint),
      text_from_sql = result$asText,
      intact = as.character(result$asBigint) == result$asText,
      stringsAsFactors = FALSE
    )
  }
  withTrue <- roundTrip(TRUE)
  withFalse <- roundTrip(FALSE)
  options(databaseConnectorInteger64AsNumeric = FALSE)
  report <- .addSection(
    report, "Does a BIGINT reach R intact?", rbind(withTrue, withFalse),
    notes = c(
      "intact must be TRUE for every row of at least one option setting.",
      paste0("with the option FALSE, every digit survives: ",
             all(withFalse$intact %in% TRUE)),
      "This package never relies on it: every export casts to VARCHAR(20) in SQL."
    ),
    status = .checkStatus(all(withFalse$intact %in% TRUE), failStatus = "warn")
  )

  range <- tryCatch(
    .queryTabehrSql(connection, "CheckPersonIdRange.sql",
                    tempEmulationSchema = tempEmulationSchema,
                    cdm_database_schema = cdmDatabaseSchema,
                    person_sample_table = ""),
    error = function(e) {
      ParallelLogger::logError("CheckPersonIdRange.sql failed: ",
                               conditionMessage(e))
      NULL
    }
  )
  if (!is.null(range)) {
    report <- .addSection(
      report, "person_id range", .asMetricTable(range),
      notes = c(
        "n_beyond_double counts ids a double cannot hold exactly (|id| > 2^53).",
        "n_colliding_groups must be 0: it is the number of distinct ids that would collapse onto one double."
      ),
      status = .checkStatus(isTRUE(range$nCollidingGroups[1] == 0))
    )
  }

  writeCheck <- tryCatch({
    probe <- data.frame(
      person_id = c("9007199254740993", "-7819202826128270750"),
      stringsAsFactors = FALSE
    )
    .insertAsText(connection, cohortDatabaseSchema, tableNames$staging, probe)
    back <- DatabaseConnector::renderTranslateQuerySql(
      connection,
      "SELECT CAST(person_id AS VARCHAR(20)) AS person_id FROM @table ORDER BY person_id;",
      table = paste0(cohortDatabaseSchema, ".", tableNames$staging),
      snakeCaseToCamelCase = TRUE
    )
    .dropTableIfExists(connection, cohortDatabaseSchema, tableNames$staging,
                       tempEmulationSchema)
    data.frame(created_and_dropped = TRUE, rows_read_back = nrow(back),
               values_match = setequal(back$personId, probe$person_id),
               error = "", stringsAsFactors = FALSE)
  }, error = function(e) {
    data.frame(created_and_dropped = FALSE, rows_read_back = NA_integer_,
               values_match = NA, error = conditionMessage(e),
               stringsAsFactors = FALSE)
  })
  report <- .addSection(
    report, paste0("Write permission in ", cohortDatabaseSchema), writeCheck,
    notes = c(
      paste0("tables are created with the prefix ", tablePrefix),
      "values_match also confirms a text round trip of a 19 digit id."
    ),
    status = .checkStatus(isTRUE(writeCheck$created_and_dropped[1]) &&
                            isTRUE(writeCheck$values_match[1]))
  )

  sampleCount <- analysisSettings$personSampleSettings$samplePersonCount
  sampleTable <- .personSampleTable(analysisSettings, cohortDatabaseSchema,
                                    tableNames)
  if (nzchar(sampleTable)) {
    .executeTabehrSql(
      connection, "CreatePersonSample.sql",
      tempEmulationSchema = tempEmulationSchema,
      cdm_database_schema = cdmDatabaseSchema,
      person_sample_table = sampleTable,
      sample_person_count = sampleCount
    )
  }
  measurement <- tryCatch(
    .queryTabehrSql(
      connection, "CheckMeasurementColumns.sql",
      tempEmulationSchema = tempEmulationSchema,
      cdm_database_schema = cdmDatabaseSchema,
      person_sample_table = sampleTable
    ),
    error = function(e) {
      ParallelLogger::logError("CheckMeasurementColumns.sql failed: ",
                               conditionMessage(e))
      NULL
    }
  )
  if (!is.null(measurement)) {
    report <- .addSection(
      report, "Measurement columns the port depends on",
      .asMetricTable(measurement),
      notes = c(
        if (nzchar(sampleTable))
          paste0("counted over the person sample of ", sampleCount,
                 " patient(s)")
        else "counted over every row",
        "n_null_datetime rows are dropped: the original never falls back to measurement_date.",
        "n_numeric_unmapped_unit rows are dropped: a numeric value whose unit_concept_id is 0 or NULL.",
        "n_value_source_without_number rows are kept, but as a bare concept_id with no bin."
      ),
      status = "info"
    )
  }

  cdmSource <- tryCatch(
    .queryTabehrSql(connection, "CheckCdmSource.sql",
                    tempEmulationSchema = tempEmulationSchema,
                    cdm_database_schema = cdmDatabaseSchema),
    error = function(e) NULL
  )
  if (!is.null(cdmSource) && nrow(cdmSource) > 0) {
    report <- .addSection(report, "cdm_source", cdmSource, status = "info")
  }

  .writeReport(report, outputFolder)
}

# Records per patient, as extractRecords() counted them against as the
# extraction holds them. The two do not use the same rules, so this reports the
# difference rather than asserting it away. The counts come from the Andromeda
# rather than the CSV because SQLite can group hundreds of millions of rows and
# R cannot.
#' @noRd
.allRecordsCountComparison <- function(outputFolder, selectionCounts,
                                       analysisSettings) {
  cohortFile <- file.path(outputFolder, "allrecords_cohort.csv")
  if (!file.exists(cohortFile)) {
    return(.asMetricTable(data.frame(nPerson = 0L)))
  }
  cohort <- utils::read.csv(cohortFile,
                            colClasses = c(person_id = "character"))
  names(cohort) <- SqlRender::snakeCaseToCamelCase(names(cohort))
  covariateData <- Andromeda::loadAndromeda(
    file.path(outputFolder, "allRecordsCovariates.zip")
  )
  on.exit({
    if (Andromeda::isValidAndromeda(covariateData)) {
      try(Andromeda::close(covariateData), silent = TRUE)
    }
  }, add = TRUE)
  perRow <- covariateData$covariates %>%
    dplyr::group_by(.data$rowId) %>%
    dplyr::summarise(nRecordsAllRecords = dplyr::n()) %>%
    dplyr::collect()

  cohort$nRecordsAllRecords <- perRow$nRecordsAllRecords[
    match(cohort$rowId, perRow$rowId)
  ]
  cohort$nRecordsAllRecords[is.na(cohort$nRecordsAllRecords)] <- 0
  cohort$nRecordsSelection <- selectionCounts$nRecordsSelection[
    match(cohort$personId, selectionCounts$personId)
  ]
  known <- !is.na(cohort$nRecordsSelection)
  difference <- cohort$nRecordsAllRecords[known] - cohort$nRecordsSelection[known]
  minimum <- analysisSettings$populationSettings$minRecordCount

  .asMetricTable(data.frame(
    nPerson = nrow(cohort),
    nPersonNotInSelection = sum(!known),
    nFewerInAllrecords = sum(difference < 0),
    nMoreInAllrecords = sum(difference > 0),
    medianDifference = stats::median(c(difference, NA_real_), na.rm = TRUE),
    nBelowMinRecordCount = sum(cohort$nRecordsAllRecords < minimum),
    minRecordCount = minimum
  ))
}

#' Check the output of a run
#'
#' Every cross-stage check in one place: run it before trusting an output
#' folder, and paste its section back when something looks wrong. Each check
#' states what must hold, so a failure is self explanatory.
#'
#' @template databaseArgs
#' @template analysisArgs
#' @param cohortTable Name of the SparseArray cohort table.
#' @param databaseId Identifier of the database this run read.
#'
#' @return Invisibly, the path of the report.
#' @export
runDiagnostics <- function(connectionDetails,
                           cdmDatabaseSchema,
                           cohortDatabaseSchema,
                           cohortTable = "cohort",
                           tablePrefix = "tabehr_",
                           tempEmulationSchema = NULL,
                           outputFolder,
                           databaseId,
                           analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  tableNames <- getTabehrTableNames(tablePrefix)
  report <- .newReport("Diagnostics", databaseId, connectionDetails$dbms)

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))
  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)

  expected <- c("records", "measurements", "conceptUnit", "recordCounts",
                "admissionHistory", "studyPopulation", "personSplit",
                "downstreamPerson")
  present <- vapply(
    expected,
    function(name) .tableExists(connection, cohortDatabaseSchema,
                                tableNames[[name]]),
    logical(1)
  )
  report <- .addSection(
    report, "Tables in place",
    data.frame(table = unlist(tableNames[expected], use.names = FALSE),
               exists = as.logical(present), stringsAsFactors = FALSE),
    notes = "A missing table means the stage that builds it has not run yet.",
    status = .checkStatus(all(present), failStatus = "warn")
  )

  # allrecords is an Andromeda file and a CSV, not a database table, so its
  # checks read the extraction rather than the schema. Two questions matter,
  # and the answer to the first is deliberately not "they agree":
  # extractRecords() applies the original MedRep rules because the study
  # population criteria were defined on them, and createAllRecords() applies
  # FeatureExtraction's. See R/Main.R.
  andromedaFile <- file.path(outputFolder, "allRecordsCovariates.zip")
  if (file.exists(andromedaFile) && present[["recordCounts"]]) {
    selectionCounts <- .queryTabehrSql(
      connection, "ExportRecordCounts.sql",
      tempEmulationSchema = tempEmulationSchema, snakeCaseToCamelCase = TRUE,
      record_counts_table = qualified(tableNames$recordCounts),
      study_population_table = qualified(tableNames$studyPopulation)
    )
    report <- .addSection(
      report, "Records per patient: selection against allrecords",
      .allRecordsCountComparison(outputFolder, selectionCounts,
                                 analysisSettings),
      notes = c(
        "extractRecords() and createAllRecords() do not apply the same rules, and are not meant to.",
        "n_fewer_in_allrecords counts patients with fewer records in allrecords than they were selected on.",
        "n_below_min_record_count is how many study population patients have fewer than the selection threshold in allrecords."
      ),
      status = "info"
    )
  }

  # Quantiles belong to the optional MedRep workflow, not execute(). Check
  # them when available without requiring them for the main task outputs.
  quantilesPresent <- .tableExists(connection, cohortDatabaseSchema,
                                    tableNames$measQuantiles)
  if (quantilesPresent && present[["measurements"]]) {
    coverage <- .queryTabehrSql(
      connection, "ValidateQuantileCoverage.sql",
      tempEmulationSchema = tempEmulationSchema,
      measurements_table = qualified(tableNames$measurements),
      study_population_table = qualified(tableNames$studyPopulation),
      meas_quantiles_table = qualified(tableNames$measQuantiles)
    )
    share <- coverage$nRowWithoutQuantile[1] /
      max(coverage$nNumericRow[1], 1)
    report <- .addSection(
      report, "Numeric rows without a quantile row",
      .asMetricTable(coverage),
      notes = c(
        paste0("share without a bin: ", round(100 * share, 3), "%"),
        "Those records keep the bare concept_id, see AllRecords.sql.",
        "With the pretrain basis a few pairs appearing only in downstream patients are expected."
      ),
      status = if (share > 0.01) "warn" else "ok"
    )
  }

  if (present[["personSplit"]]) {
    stage <- .downstreamStage(analysisSettings)
    checks <- .queryTabehrSql(
      connection, "ValidateSplit.sql",
      tempEmulationSchema = tempEmulationSchema,
      person_split_table = qualified(tableNames$personSplit),
      study_population_table = qualified(tableNames$studyPopulation),
      downstream_person_table = qualified(tableNames$downstreamPerson),
      downstream_stage = stage
    )
    ok <- isTRUE(checks$nPersonInTwoGroups[1] == 0) &&
      isTRUE(checks$nPopulationWithoutSplit[1] == 0) &&
      isTRUE(checks$nSplitOutsidePopulation[1] == 0) &&
      isTRUE(checks$nDownstreamFromWrongStage[1] == 0)
    report <- .addSection(
      report, "Split invariants", .asMetricTable(checks),
      notes = c(
        "n_person_in_two_groups must be 0: no patient may be in two groups.",
        "n_population_without_split and n_split_outside_population must both be 0.",
        "n_downstream_from_wrong_stage must be 0: downstream_person comes only from that stage."
      ),
      status = .checkStatus(ok)
    )
    groups <- .queryTabehrSql(
      connection, "ValidateSplitGroups.sql",
      tempEmulationSchema = tempEmulationSchema, snakeCaseToCamelCase = FALSE,
      person_split_table = qualified(tableNames$personSplit)
    )
    report <- .addSection(report, "Split group sizes", groups, status = "info")

    # The CSV and the table must agree row for row, which is the end to end
    # proof that no person_id lost a digit on the way through R.
    splitFile <- file.path(outputFolder, "person_split.csv")
    if (file.exists(splitFile)) {
      fromFile <- utils::read.csv(splitFile, colClasses = "character")
      fromDatabase <- .queryTabehrSql(
        connection, "ExportPersonSplit.sql",
        tempEmulationSchema = tempEmulationSchema,
        snakeCaseToCamelCase = FALSE,
        person_split_table = qualified(tableNames$personSplit)
      )
      comparison <- merge(
        data.frame(person_id = fromFile$person_id,
                   file_stage = fromFile$stage, stringsAsFactors = FALSE),
        data.frame(person_id = fromDatabase$person_id,
                   db_stage = fromDatabase$stage, stringsAsFactors = FALSE),
        by = "person_id", all = TRUE
      )
      mismatch <- comparison[is.na(comparison$file_stage) |
                               is.na(comparison$db_stage) |
                               comparison$file_stage != comparison$db_stage, ,
                             drop = FALSE]
      report <- .addSection(
        report, "person_split.csv against the database table",
        data.frame(rows_in_file = nrow(fromFile),
                   rows_in_database = nrow(fromDatabase),
                   mismatching_person_ids = nrow(mismatch),
                   stringsAsFactors = FALSE),
        notes = "0 mismatches proves the person_id text round trip: R wrote it, SQL cast it to BIGINT and back.",
        status = .checkStatus(nrow(mismatch) == 0 &&
                                nrow(fromFile) == nrow(fromDatabase))
      )
    }
  }

  cohortRows <- tryCatch(
    DatabaseConnector::renderTranslateQuerySql(
      connection, "SELECT COUNT(*) AS n_row FROM @table;",
      table = qualified(cohortTable), snakeCaseToCamelCase = TRUE
    )$nRow[1],
    error = function(e) 0
  )
  if (cohortRows > 0 && present[["downstreamPerson"]]) {
    restriction <- .queryTabehrSql(
      connection, "ValidateCohortRestriction.sql",
      tempEmulationSchema = tempEmulationSchema, snakeCaseToCamelCase = FALSE,
      cohort_database_schema = cohortDatabaseSchema,
      cohort_table = cohortTable,
      downstream_person_table = qualified(tableNames$downstreamPerson)
    )
    targets <- restriction[restriction$cohort_definition_id %in% c(1000, 1003), ,
                           drop = FALSE]
    report <- .addSection(
      report, "Cohort rows against the downstream set", restriction,
      notes = c(
        "n_row_outside_downstream must be 0 for the target cohorts 1000 and 1003.",
        "The outcome cohorts are not restricted, so a non-zero value there is expected."
      ),
      status = .checkStatus(nrow(targets) > 0 &&
                              all(targets$n_row_outside_downstream == 0))
    )
    writeTabehrCsv(restriction,
                   file.path(outputFolder, "validation_cohorts.csv"))
  }

  labelFile <- file.path(outputFolder, "outcomeLabels.csv")
  if (file.exists(labelFile)) {
    labels <- utils::read.csv(labelFile,
                              colClasses = c(subjectId = "character"))
    byTask <- stats::aggregate(
      cbind(n_row, n_positive) ~ taskId + extraction,
      data = data.frame(taskId = labels$taskId,
                        extraction = labels$extraction,
                        n_row = 1L,
                        n_positive = labels$outcomeLabel,
                        stringsAsFactors = FALSE),
      FUN = sum
    )
    patients <- stats::aggregate(subjectId ~ taskId, data = labels,
                                 FUN = function(x) length(unique(x)))
    names(patients)[2] <- "n_person"
    byTask <- merge(byTask, patients, by = "taskId")
    byTask$positive_rate <- round(byTask$n_positive / byTask$n_row, 5)
    byTask <- byTask[order(byTask$extraction, byTask$taskId), ]
    report <- .addSection(
      report, "Labels per task", byTask,
      notes = c(
        "One row per target cohort entry (rowId), not per patient, so n_row > n_person is expected.",
        "A task missing here produced no labels: see outcomeLabelsAttrition.csv."
      ),
      status = .checkStatus(length(unique(labels$taskId)) > 0)
    )

    if (present[["downstreamPerson"]]) {
      downstream <- DatabaseConnector::renderTranslateQuerySql(
        connection,
        "SELECT CAST(person_id AS VARCHAR(20)) AS person_id FROM @table;",
        table = qualified(tableNames$downstreamPerson),
        snakeCaseToCamelCase = TRUE
      )
      outside <- setdiff(unique(labels$subjectId), downstream$personId)
      report <- .addSection(
        report, "Labelled patients against the downstream set",
        data.frame(n_labelled_person = length(unique(labels$subjectId)),
                   n_downstream_person = nrow(downstream),
                   n_labelled_outside_downstream = length(outside),
                   stringsAsFactors = FALSE),
        notes = c(
          "n_labelled_outside_downstream must be 0.",
          "A non-zero value here, with 0 for the cohort check above, would mean a person_id lost digits inside PLP.",
          if (length(outside) > 0)
            paste0("examples: ", paste(utils::head(outside, 5),
                                       collapse = ", "))
          else ""
        ),
        status = .checkStatus(length(outside) == 0)
      )
    }
  }

  required <- c("study_population_flow.csv", "study_population.csv",
                "person_split.csv", "split_summary.csv")
  optional <- c("allrecords.csv", "allrecords.csv.gz", "outcomeLabels.csv",
                "outcomeLabelsAttrition.csv", "CohortCounts.csv",
                "cohort_counts_restricted.csv", "run_info.json",
                "meas_quantiles.csv")
  files <- data.frame(
    file = c(required, optional),
    required = c(rep(TRUE, length(required)), rep(FALSE, length(optional))),
    exists = file.exists(file.path(outputFolder, c(required, optional))),
    stringsAsFactors = FALSE
  )
  files$size_bytes <- ifelse(files$exists,
                             file.size(file.path(outputFolder, files$file)),
                             NA_real_)
  report <- .addSection(
    report, "Output files", files,
    notes = paste0("output folder: ", outputFolder),
    status = .checkStatus(all(files$exists[files$required]))
  )

  .writeReport(report, outputFolder)
}
