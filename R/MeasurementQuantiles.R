# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The quantile table, and the SQL fragments whose width depends on how many bins
# were asked for (eleven columns for the default of ten).
#
# The probabilities are computed in R, reproducing both steps the original goes
# through, and written into the SQL as literals. Doing that arithmetic here
# rather than in SQL is what keeps the boundaries bit-identical to pandas; the
# tests check it against fixtures pandas itself produced.

#' The quantile probabilities, exactly as pandas ends up using them
#'
#' Two steps, both of which matter at the last bits:
#'
#' \itemize{
#'   \item `seq(0, 1, length.out = Q + 1)` is the same arithmetic as numpy's
#'     `linspace(0, 1, 11)`, so the fourth probability is 0.30000000000000004,
#'     not 0.3
#'   \item `Series.quantile(q)` then goes through `np.percentile(x, q * 100)`,
#'     and numpy divides by 100 again, which does not return the same double:
#'     0.7000000000000001 * 100 / 100 is 0.7
#' }
#' @noRd
quantileProbabilities <- function(quantileCount) {
  (seq(0, 1, length.out = quantileCount + 1) * 100) / 100
}

#' @noRd
.quantileColumnNames <- function(quantileCount) {
  paste0("quantile_", seq_len(quantileCount + 1) - 1)
}

# The CROSS JOIN source of (index, probability) rows. The probabilities are
# written with 17 significant digits, which round-trips a double exactly, and
# cast to FLOAT so the dialect does not read them as exact decimals.
#' @noRd
quantileIndexRows <- function(quantileCount) {
  probabilities <- quantileProbabilities(quantileCount)
  rows <- sprintf(
    "  SELECT %d AS j, CAST(%s AS FLOAT) AS p",
    seq_along(probabilities) - 1L,
    vapply(probabilities, function(p) sprintf("%.17g", p), "")
  )
  paste(rows, collapse = "\n  UNION ALL\n")
}

#' @noRd
quantileColumnDefinitions <- function(quantileCount) {
  paste0(
    paste(sprintf("  %s FLOAT NULL,", .quantileColumnNames(quantileCount)),
          collapse = "\n"),
    "\n"
  )
}

#' @noRd
quantileColumnNames <- function(quantileCount) {
  paste(.quantileColumnNames(quantileCount), collapse = ", ")
}

#' @noRd
quantilePivotExpressions <- function(quantileCount) {
  names <- .quantileColumnNames(quantileCount)
  paste0(
    paste(
      sprintf("       MAX(CASE WHEN P.j = %d THEN P.q_value END) AS %s,",
              seq_along(names) - 1L, names),
      collapse = "\n"
    ),
    "\n"
  )
}

# One PERCENTILE_CONT call per probability, because SQL Server only accepts a
# literal there.
#' @noRd
percentileExpressions <- function(quantileCount) {
  probabilities <- quantileProbabilities(quantileCount)
  names <- .quantileColumnNames(quantileCount)
  paste0(
    paste(
      sprintf(
        paste0("       PERCENTILE_CONT(%s) WITHIN GROUP (ORDER BY S.value_number) ",
               "OVER (PARTITION BY S.measurement_concept_id, S.unit_concept_id) AS %s,"),
        vapply(probabilities, function(p) sprintf("%.17g", p), ""),
        names
      ),
      collapse = "\n"
    ),
    "\n"
  )
}

# The bisect_left equivalent: `max(0, bisect_left(q, value) - 1)` is the
# original's bin, and bisect_left on a sorted array is the count of elements
# strictly below the value, so counting is the same thing and stays correct when
# boundaries repeat.
#' @noRd
quantileLessThanCount <- function(quantileCount) {
  parts <- sprintf("CASE WHEN Q.%s < H.value_number THEN 1 ELSE 0 END",
                   .quantileColumnNames(quantileCount))
  paste0("(", paste(parts, collapse = " + "), ")")
}

#' @noRd
.quantileSqlParameters <- function(preprocessSettings) {
  quantileCount <- preprocessSettings$quantileCount
  list(
    quantile_index_rows = quantileIndexRows(quantileCount),
    quantile_column_definitions = quantileColumnDefinitions(quantileCount),
    quantile_column_names = quantileColumnNames(quantileCount),
    quantile_pivot_expressions = quantilePivotExpressions(quantileCount),
    percentile_expressions = percentileExpressions(quantileCount),
    quantile_lt_count = quantileLessThanCount(quantileCount)
  )
}

#' Build the measurement quantile table
#'
#' Reproduces `x.quantile(np.linspace(0, 1, 11))` per (measurement concept,
#' unit) with `ROW_NUMBER` arithmetic, which SqlRender translates on every
#' dialect, or with `PERCENTILE_CONT` when `quantileMethod` asks for it.
#'
#' The grouping is (measurement concept, `unit_concept_id`), which is what the
#' FeatureExtraction covariate id carries, so one covariate id resolves to
#' exactly one row and [covariateToToken()] can turn a `featureExtractionLong`
#' value back into an `allrecords` token.
#'
#' By default the boundaries come from every patient, as MedRep computes them:
#' the basis and the rows being binned are then the same set, so the top bin
#' cannot occur and the token space stays `_0` to `_9`. See
#' [createQuantileSettings()] for the alternatives.
#'
#' Writes `meas_quantiles.csv` in the column set of the original MedRep file
#' plus `n` and `basis`.
#'
#' @template databaseArgs
#' @template analysisArgs
#'
#' @return Invisibly, the quantile table as a data frame.
#' @export
createMeasurementQuantiles <- function(connectionDetails,
                                       cohortDatabaseSchema,
                                       tablePrefix = "tabehr_",
                                       tempEmulationSchema = NULL,
                                       outputFolder,
                                       analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(outputFolder, min.chars = 1)
  .ensureFolder(outputFolder)
  tableNames <- getTabehrTableNames(tablePrefix)
  preprocess <- analysisSettings$preprocessSettings
  basis <- analysisSettings$quantileSettings$basis
  parameters <- .quantileSqlParameters(preprocess)

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))
  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)

  if (identical(basis, "file")) {
    file <- analysisSettings$quantileSettings$quantileFile
    ParallelLogger::logInfo("Applying the quantile table from ", file)
    .uploadMeasurementQuantiles(connection, cohortDatabaseSchema, tableNames,
                                tempEmulationSchema, preprocess, file)
  } else {
    ParallelLogger::logInfo("Computing the measurement quantiles from the ",
                            basis, " patients")
    .executeTabehrSql(
      connection, "QuantileBasisPerson.sql",
      tempEmulationSchema = tempEmulationSchema,
      quantile_basis_person_table = qualified(tableNames$quantileBasisPerson),
      person_split_table = qualified(tableNames$personSplit),
      study_population_table = qualified(tableNames$studyPopulation),
      quantile_basis_stage = if (identical(basis, "pretrain")) "pretrain" else ""
    )
    sqlFilename <- if (identical(preprocess$quantileMethod, "percentileCont")) {
      "MeasurementQuantilesPercentileCont.sql"
    } else {
      "MeasurementQuantiles.sql"
    }
    do.call(
      .executeTabehrSql,
      c(
        list(connection = connection, sqlFilename = sqlFilename,
             tempEmulationSchema = tempEmulationSchema),
        parameters,
        list(
          meas_quantiles_table = qualified(tableNames$measQuantiles),
          measurements_table = qualified(tableNames$measurements),
          concept_unit_table = qualified(tableNames$conceptUnit),
          restrict_person_table = if (identical(basis, "all")) "" else
            qualified(tableNames$quantileBasisPerson),
          quantile_basis = basis
        )
      )
    )
  }

  quantiles <- .queryTabehrSql(
    connection, "ExportMeasurementQuantiles.sql",
    tempEmulationSchema = tempEmulationSchema,
    snakeCaseToCamelCase = FALSE,
    meas_quantiles_table = qualified(tableNames$measQuantiles),
    quantile_column_names = parameters$quantile_column_names
  )
  writeTabehrCsv(quantiles, file.path(outputFolder, "meas_quantiles.csv"))
  invisible(quantiles)
}

# Load a quantile table computed elsewhere, which is how an external site
# applies the primary site's boundaries.
#' @noRd
.uploadMeasurementQuantiles <- function(connection, cohortDatabaseSchema,
                                        tableNames, tempEmulationSchema,
                                        preprocessSettings, file) {
  if (!file.exists(file)) {
    stop("Cannot find the quantile table: ", file, call. = FALSE)
  }
  quantiles <- utils::read.csv(file, colClasses = "character",
                               check.names = FALSE)
  columns <- .quantileColumnNames(preprocessSettings$quantileCount)
  expected <- c("measurement_concept_id", "unit_concept_id",
                "unit_source_value", "n_unit_source_value", columns)
  absent <- expected[!expected %in% names(quantiles)]
  if (length(absent) > 0) {
    stop("The quantile table is missing the column(s) ",
         paste(absent, collapse = ", "), ": ", file, call. = FALSE)
  }
  if (!"n" %in% names(quantiles)) {
    quantiles$n <- "0"
  }
  quantiles <- quantiles[, c(expected, "n")]

  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)
  .insertAsText(connection, cohortDatabaseSchema, tableNames$staging,
                quantiles)
  .executeTabehrSql(
    connection, "MeasurementQuantilesFromFile.sql",
    tempEmulationSchema = tempEmulationSchema,
    meas_quantiles_table = qualified(tableNames$measQuantiles),
    staging_table = qualified(tableNames$staging),
    quantile_column_definitions =
      quantileColumnDefinitions(preprocessSettings$quantileCount),
    quantile_column_names =
      quantileColumnNames(preprocessSettings$quantileCount),
    quantile_cast_columns = paste(
      sprintf("       CAST(S.%s AS FLOAT) AS %s,", columns, columns),
      collapse = "\n"
    )
  )
  .dropTableIfExists(connection, cohortDatabaseSchema, tableNames$staging,
                     tempEmulationSchema)
  invisible(NULL)
}
