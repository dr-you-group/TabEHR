# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The one expression SqlRender cannot translate, supplied per dialect instead.
#
# Checked against SqlRender v1.9.0, the version pinned in the Docker image, by
# extras/CheckSqlRendering.R. Translating SQL Server syntax to PostgreSQL leaves
# these untouched, which would fail at run time on any non-SQL Server site:
#
#   DATEPART(HOUR, x)        -> DATEPART(HOUR, x)        (no such function)
#   DATEDIFF(HOUR, a, b)     -> DATEDIFF(HOUR, a, b)     (only DAY translates)
#
# So the hour of day is a parameter, @hour_of_day, that this file fills in for
# the site's dbms. Everything else is plain OHDSI SQL left to SqlRender.
#
# There used to be a second expression here, a per-dialect stand-in for
# TRY_CAST, because the measurement value was parsed out of
# value_source_value. The port now reads value_as_number, the column
# FeatureExtraction reads, so no cast is needed at all.

# Hour of day as an integer 0-23, used to keep one measurement per hour.
.hourOfDayExpressions <- list(
  "sql server" = "DATEPART(HOUR, %s)",
  "pdw"        = "DATEPART(HOUR, %s)",
  "postgresql" = "EXTRACT(HOUR FROM %s)",
  "redshift"   = "EXTRACT(HOUR FROM %s)",
  "oracle"     = "EXTRACT(HOUR FROM CAST(%s AS TIMESTAMP))",
  "snowflake"  = "HOUR(%s)",
  "spark"      = "HOUR(%s)",
  "bigquery"   = "EXTRACT(HOUR FROM %s)",
  "sqlite"     = "CAST(STRFTIME('%%H', %s) AS INTEGER)"
)

#' The hour-of-day expression for a dbms
#'
#' @param dbms The DatabaseConnector dbms string.
#' @param column The column to read, for example `"M.measurement_datetime"`.
#' @noRd
hourOfDaySql <- function(dbms, column) {
  key <- tolower(dbms)
  if (!key %in% names(.hourOfDayExpressions)) {
    stop(
      "No hour of day expression for dbms ", sQuote(dbms),
      ". Add one to R/Dialects.R; SqlRender does not translate this construct ",
      "on its own.",
      call. = FALSE
    )
  }
  sprintf(.hourOfDayExpressions[[key]], column)
}

#' The dialects this package has expressions for
#'
#' SqlRender translates almost everything this package needs, but not
#' `DATEPART` or `DATEDIFF(HOUR)`, so the hour of day is supplied per dialect. A
#' dbms missing from this list fails loudly rather than running SQL its engine
#' does not understand.
#'
#' @return A character vector of dbms names.
#' @export
supportedDialects <- function() {
  sort(names(.hourOfDayExpressions))
}
