# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Writing the output files. Two rules apply to all of them:
#
#   * person_id is text, never a number, so a 19 digit id keeps every digit
#   * dates are YYYY-MM-DD and timestamps YYYY-MM-DD HH:MM:SS

# The header of a streamed file. The result arrives from Andromeda in
# camelCase, because that is what the person boundary logic and the rest of R
# work with, but every file this project writes uses the snake_case column
# names of the OMOP CDM and of the original MedRep files, so the header is
# converted back on the way out.
#' @noRd
.csvHeader <- function(columnNames) {
  paste(SqlRender::camelCaseToSnakeCase(columnNames), collapse = ",")
}

#' @noRd
.formatForCsv <- function(data) {
  for (column in names(data)) {
    value <- data[[column]]
    if (inherits(value, "POSIXt")) {
      data[[column]] <- format(value, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    } else if (inherits(value, "Date")) {
      data[[column]] <- format(value, "%Y-%m-%d")
    } else if (inherits(value, "integer64")) {
      data[[column]] <- as.character(value)
    }
  }
  data
}

#' Write one of this package's CSV files
#'
#' @param data A data frame.
#' @param path Destination. A path ending in `.gz` is written compressed.
#'
#' @return Invisibly, `path`.
#' @export
writeTabehrCsv <- function(data, path) {
  checkmate::assertDataFrame(data)
  checkmate::assertString(path, min.chars = 1)
  data <- .formatForCsv(data)
  .ensureFolder(dirname(path))
  connection <- if (grepl("[.]gz$", path)) {
    gzfile(path, open = "wt")
  } else {
    file(path, open = "wt")
  }
  on.exit(close(connection), add = TRUE)
  utils::write.csv(data, connection, row.names = FALSE, na = "")
  ParallelLogger::logInfo("Wrote ", nrow(data), " row(s) to ", path)
  invisible(path)
}

#' Stream a query to CSV
#'
#' Goes through Andromeda rather than a data frame, the same way
#' [SparseArray::createLongFormat()] streams its long file, so a table far
#' larger than memory can be written.
#'
#' @param connection An open DatabaseConnector connection.
#' @param sql Rendered and translated SQL.
#' @param path Destination path. When `maxRowsPerFile` is set and the result is
#'   larger, the files are numbered `<base>-001.csv`, and a new file only starts
#'   when `personColumn` changes, so a patient is never split across files.
#' @param maxRowsPerFile Rows after which to start a new file, or `NULL`.
#' @param personColumn Column to keep whole, or `NULL` to split anywhere.
#' @param batchSize Rows fetched from Andromeda per batch.
#'
#' @return Invisibly, the paths written.
#' @export
streamQueryToCsv <- function(connection,
                             sql,
                             path,
                             maxRowsPerFile = NULL,
                             personColumn = "personId",
                             batchSize = 1e6) {
  checkmate::assertString(sql, min.chars = 1)
  checkmate::assertString(path, min.chars = 1)
  streaming <- "querySqlToAndromeda" %in%
    getNamespaceExports("DatabaseConnector")
  if (streaming) {
    andromeda <- Andromeda::andromeda()
    on.exit(Andromeda::close(andromeda), add = TRUE)
    DatabaseConnector::querySqlToAndromeda(
      connection = connection,
      sql = sql,
      andromeda = andromeda,
      andromedaTableName = "result",
      snakeCaseToCamelCase = TRUE
    )
  } else {
    # Older DatabaseConnector: the result has to be collected. Fine for a
    # sample run, not for the full table.
    ParallelLogger::logWarn(
      "This DatabaseConnector has no querySqlToAndromeda(), so the whole ",
      "result is collected in memory."
    )
    collected <- DatabaseConnector::querySql(connection, sql)
    names(collected) <- SqlRender::snakeCaseToCamelCase(names(collected))
  }

  compressed <- grepl("[.]gz$", path)
  base <- sub("([.]csv)?([.]gz)?$", "", path)
  extension <- if (compressed) ".csv.gz" else ".csv"
  state <- list(index = 0L, paths = character(0), connection = NULL,
                rows = 0L, lastPerson = NULL, header = NULL)

  openNext <- function() {
    state$index <<- state$index + 1L
    target <- if (is.null(maxRowsPerFile) && state$index == 1L) {
      path
    } else {
      sprintf("%s-%03d%s", base, state$index, extension)
    }
    .ensureFolder(dirname(target))
    state$connection <<- if (compressed) {
      gzfile(target, open = "wt")
    } else {
      file(target, open = "wt")
    }
    state$paths <<- c(state$paths, target)
    state$rows <<- 0L
    if (!is.null(state$header)) {
      writeLines(state$header, state$connection)
    }
    invisible(NULL)
  }

  writeBatch <- function(batch) {
    batch <- .formatForCsv(batch)
    if (is.null(state$header)) {
      state$header <<- .csvHeader(names(batch))
    }
    if (is.null(state$connection)) {
      openNext()
    }
    if (!is.null(maxRowsPerFile) && state$rows >= maxRowsPerFile) {
      newPatient <- is.null(personColumn) ||
        !personColumn %in% names(batch) ||
        is.null(state$lastPerson) ||
        !identical(batch[[personColumn]][1], state$lastPerson)
      if (newPatient) {
        close(state$connection)
        openNext()
      }
    }
    utils::write.table(
      batch,
      file = state$connection,
      sep = ",",
      row.names = FALSE,
      col.names = FALSE,
      # The streamed columns are a digit string, a four letter domain, a
      # concept token and a timestamp: none can contain a comma, so the file
      # stays byte compatible with the original pandas output.
      quote = FALSE,
      na = ""
    )
    state$rows <<- state$rows + nrow(batch)
    if (!is.null(personColumn) && personColumn %in% names(batch)) {
      state$lastPerson <<- batch[[personColumn]][nrow(batch)]
    }
    invisible(NULL)
  }

  if (streaming) {
    Andromeda::batchApply(andromeda$result, writeBatch, batchSize = batchSize,
                          progressBar = FALSE, safe = FALSE)
  } else if (nrow(collected) > 0) {
    writeBatch(collected)
  }
  if (!is.null(state$connection)) {
    close(state$connection)
  }
  if (length(state$paths) == 0) {
    # An empty result still gets a file, so the next stage fails on content
    # rather than on a missing file.
    empty <- if (compressed) gzfile(path, open = "wt") else
      file(path, open = "wt")
    writeLines("", empty)
    close(empty)
    state$paths <- path
  }
  ParallelLogger::logInfo("Wrote ", paste(state$paths, collapse = ", "))
  invisible(state$paths)
}

#' @noRd
.packageVersionOrNa <- function(name) {
  tryCatch(as.character(utils::packageVersion(name)),
           error = function(e) NA_character_)
}

#' Write run_info.json
#'
#' Everything needed to tie an output folder to the run that produced it. The
#' credentials are never written: only the schema names and the settings.
#'
#' @template databaseArgs
#' @template analysisArgs
#' @param databaseId Identifier of the database this run read.
#' @param cohortTable Name of the SparseArray cohort table.
#' @param extra A named list of anything else worth recording.
#'
#' @return Invisibly, the path written.
#' @export
exportRunInfo <- function(connectionDetails,
                          cdmDatabaseSchema,
                          vocabularyDatabaseSchema = cdmDatabaseSchema,
                          cohortDatabaseSchema,
                          cohortTable = "cohort",
                          tablePrefix = "tabehr_",
                          tempEmulationSchema = NULL,
                          outputFolder,
                          databaseId,
                          analysisSettings = loadAnalysisSettings(),
                          extra = list()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(databaseId, min.chars = 1)
  .ensureFolder(outputFolder)

  vocabularyVersion <- tryCatch({
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
    result <- .queryTabehrSql(
      connection, "CheckVocabularyVersion.sql",
      tempEmulationSchema = tempEmulationSchema,
      vocabulary_database_schema = vocabularyDatabaseSchema
    )
    if (nrow(result) == 0) NA_character_ else as.character(result[[1]][1])
  }, error = function(e) {
    ParallelLogger::logWarn("Could not read the vocabulary version: ",
                            conditionMessage(e))
    NA_character_
  })

  settings <- lapply(analysisSettings, function(part) {
    if (is.list(part)) {
      class(part) <- NULL
    }
    part
  })
  info <- c(
    list(
      databaseId = databaseId,
      dbms = connectionDetails$dbms,
      runAt = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
      schemas = list(
        cdmDatabaseSchema = cdmDatabaseSchema,
        vocabularyDatabaseSchema = vocabularyDatabaseSchema,
        cohortDatabaseSchema = cohortDatabaseSchema,
        cohortTable = cohortTable,
        tablePrefix = tablePrefix
      ),
      vocabularyVersion = vocabularyVersion,
      rVersion = R.version.string,
      packageVersions = list(
        TabEHR = .packageVersionOrNa("TabEHR"),
        SparseArray = .packageVersionOrNa("SparseArray"),
        DatabaseConnector = .packageVersionOrNa("DatabaseConnector"),
        SqlRender = .packageVersionOrNa("SqlRender"),
        FeatureExtraction = .packageVersionOrNa("FeatureExtraction"),
        PatientLevelPrediction = .packageVersionOrNa("PatientLevelPrediction"),
        Andromeda = .packageVersionOrNa("Andromeda"),
        ParallelLogger = .packageVersionOrNa("ParallelLogger")
      ),
      analysisSettings = settings
    ),
    extra
  )
  path <- file.path(outputFolder, "run_info.json")
  writeLines(
    jsonlite::toJSON(info, auto_unbox = TRUE, pretty = TRUE, null = "null",
                     na = "null"),
    path
  )
  ParallelLogger::logInfo("Wrote ", path)
  invisible(path)
}
