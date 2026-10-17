# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' The names of the tables this package creates
#'
#' Every table lives in `cohortDatabaseSchema` next to the cohort table, under
#' one prefix, the way CohortGenerator::getCohortTableNames() names the cohort
#' tables. CDM tables are only ever read.
#'
#' @param tablePrefix Prefix for every table name.
#'
#' @return A named list of table names.
#' @export
getTabehrTableNames <- function(tablePrefix = "tabehr_") {
  checkmate::assertString(tablePrefix)
  if (nzchar(tablePrefix) && !grepl("^[A-Za-z_][A-Za-z0-9_]*$", tablePrefix)) {
    stop("tablePrefix must be a plain SQL identifier prefix, not ",
         sQuote(tablePrefix), ".", call. = FALSE)
  }
  names <- c(
    personSample = "person_sample",
    records = "records",
    measurements = "measurements",
    conceptUnit = "concept_unit",
    recordCounts = "record_counts",
    admissionHistory = "admission_history",
    studyPopulation = "study_population",
    personSplit = "person_split",
    quantileBasisPerson = "quantile_basis_person",
    downstreamPerson = "downstream_person",
    measQuantiles = "meas_quantiles",
    allRecordsCohort = "allrecords_cohort",
    staging = "staging"
  )
  as.list(stats::setNames(paste0(tablePrefix, names), names(names)))
}

# The dbms of an open connection, as the sibling SparseArray package reads it.
#' @noRd
.dbms <- function(connection) {
  attr(connection, "dbms")
}

# Load one of this package's SQL files, render it, translate it, and run it.
#' @noRd
.executeTabehrSql <- function(connection,
                              sqlFilename,
                              tempEmulationSchema = NULL,
                              progressBar = FALSE,
                              ...) {
  sql <- SqlRender::loadRenderTranslateSql(
    sqlFilename = sqlFilename,
    packageName = "TabEHR",
    dbms = .dbms(connection),
    tempEmulationSchema = tempEmulationSchema,
    ...
  )
  DatabaseConnector::executeSql(
    connection,
    sql,
    progressBar = progressBar,
    reportOverallTime = FALSE
  )
  invisible(NULL)
}

# The same, for a query.
#' @noRd
.queryTabehrSql <- function(connection,
                            sqlFilename,
                            tempEmulationSchema = NULL,
                            snakeCaseToCamelCase = TRUE,
                            ...) {
  sql <- SqlRender::loadRenderTranslateSql(
    sqlFilename = sqlFilename,
    packageName = "TabEHR",
    dbms = .dbms(connection),
    tempEmulationSchema = tempEmulationSchema,
    ...
  )
  result <- DatabaseConnector::querySql(connection, sql)
  names(result) <- if (snakeCaseToCamelCase) {
    SqlRender::snakeCaseToCamelCase(names(result))
  } else {
    tolower(names(result))
  }
  result
}

#' @noRd
.dropTableIfExists <- function(connection, databaseSchema, tableName,
                               tempEmulationSchema = NULL) {
  .executeTabehrSql(
    connection, "DropTable.sql",
    tempEmulationSchema = tempEmulationSchema,
    drop_table = paste0(databaseSchema, ".", tableName)
  )
}

#' @noRd
.tableExists <- function(connection, databaseSchema, tableName) {
  tables <- DatabaseConnector::getTableNames(connection, databaseSchema)
  tolower(tableName) %in% tolower(tables)
}

# person_id is a BIGINT that can exceed 2^53: in MIMIC it is a 19 digit hash,
# sometimes negative. R has no 64 bit integer, so as a double it silently loses
# its last digits, which would merge two patients or break a later join. The
# rules this package follows:
#
#   * joins and filters stay in the database, where the type is BIGINT
#   * anything leaving the database is CAST(person_id AS VARCHAR(20)) in SQL and
#     is character in R
#   * anything going back in is inserted as text and cast to BIGINT in SQL
#
# checkDatabase() verifies the whole round trip, and this guard catches a query
# that forgot the cast.
#' @noRd
.assertCharacterIds <- function(data, columns) {
  for (column in intersect(columns, names(data))) {
    if (is.numeric(data[[column]])) {
      stop(
        "Column ", column, " came back as ", class(data[[column]])[1],
        ", which cannot hold a 19 digit person_id without losing digits. ",
        "The query has to CAST it to VARCHAR(20).",
        call. = FALSE
      )
    }
    data[[column]] <- as.character(data[[column]])
  }
  data
}

# Send a data frame to the database as text only, so nothing is rounded on the
# way in, and let SQL cast it.
#' @noRd
.insertAsText <- function(connection, databaseSchema, tableName, data) {
  stopifnot(is.data.frame(data))
  for (column in names(data)) {
    data[[column]] <- as.character(data[[column]])
  }
  DatabaseConnector::insertTable(
    connection = connection,
    databaseSchema = databaseSchema,
    tableName = tableName,
    data = data,
    dropTableIfExists = TRUE,
    createTable = TRUE,
    tempTable = FALSE,
    progressBar = FALSE,
    camelCaseToSnakeCase = FALSE
  )
  invisible(NULL)
}

#' @noRd
.ensureFolder <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }
  path
}

# The datetime upper bound equivalent to the original's string comparison:
# '2260-12-31 10:00:00' <= '2260-12-31' is FALSE as text, so a time of day on
# the last day is dropped.
#' @noRd
.dateMaxBound <- function(preprocessSettings) {
  paste0(preprocessSettings$dateMax, " 00:00:00")
}

# "downstream" at the primary site, "external" at a validation site: the stage
# whose patients the SparseArray stages are allowed to see.
#' @noRd
.downstreamStage <- function(analysisSettings) {
  if (identical(analysisSettings$siteRole, "external")) {
    "external"
  } else {
    "downstream"
  }
}

# The person sample table name, or "" when every patient is in scope. The SQL
# files take it as @person_sample_table and skip their restriction when it is
# empty.
#' @noRd
.personSampleTable <- function(analysisSettings, cohortDatabaseSchema,
                               tableNames) {
  if (is.null(analysisSettings$personSampleSettings$samplePersonCount)) {
    return("")
  }
  paste0(cohortDatabaseSchema, ".", tableNames$personSample)
}
