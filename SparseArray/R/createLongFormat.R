# Copyright 2026 SparseArray Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

.writeLongFormatBatch <- function(batch, connection) {
  if (nrow(batch) == 0L) {
    return(invisible(NULL))
  }
  utils::write.table(
    batch,
    file = connection,
    sep = ",",
    row.names = FALSE,
    col.names = FALSE,
    quote = FALSE,
    na = ""
  )
  invisible(NULL)
}

# covariateRef says which concept a covariate stands for, but not which unit a
# measurement value covariate was measured in: the covariate id keeps the unit
# only modulo 1000 and FeatureExtraction's reference table has no column for
# it. The column is joined on here rather than produced inside the extraction,
# because FeatureExtraction merges the results of several covariate settings
# objects with Andromeda::appendToTable(), which selects the columns of the
# table being appended to and so drops any extra column a builder emits. By
# this point nothing appends to these tables any more.
#
# exportMeasurementValueUnitRef() leaves the crosswalk in the output folder.
# A covariate id
# that stands for two units, which is what happens when two unit concept ids
# agree modulo 1000, gets one row per unit, exactly as FeatureExtraction's own
# reference table does: the values of such a covariate really do mix units, and
# saying so is more useful than picking one.
#' @noRd
.addUnitConceptId <- function(covariateRef, covariateData, outputFolder) {
  analysisIds <- numeric(0)
  if ("analysisRef" %in% names(covariateData)) {
    analyses <- dplyr::collect(covariateData$analysisRef)
    analysisIds <- analyses$analysisId[analyses$analysisName ==
                                         "MeasurementValueUnit"]
  }
  affected <- covariateRef$analysisId %in% analysisIds
  file <- file.path(outputFolder, .measurementValueUnitRefFile)
  if (!file.exists(file)) {
    if (any(affected)) {
      ParallelLogger::logWarn(
        sum(affected), " measurement value covariate(s) are in this ",
        "extraction, but ", file, " is not, so covariateRef.csv cannot say ",
        "which unit each was measured in. Run ",
        "exportMeasurementValueUnitRef() to write it."
      )
    }
    return(covariateRef)
  }
  crosswalk <- utils::read.csv(file, colClasses = c(covariateId = "character"))
  required <- c("covariateId", "unitConceptId")
  absent <- required[!required %in% names(crosswalk)]
  if (length(absent) > 0) {
    stop(file, " is missing the column(s) ", paste(absent, collapse = ", "),
         ".", call. = FALSE)
  }
  # JDBC and Andromeda may return integer64 while CSV infers double. Join on
  # exact text without changing the original reference column's type.
  covariateRef$.unitJoinKey <- as.character(covariateRef$covariateId)
  crosswalk$.unitJoinKey <- crosswalk$covariateId
  joined <- dplyr::left_join(
    covariateRef,
    crosswalk[, c(".unitJoinKey", "unitConceptId")],
    by = ".unitJoinKey"
  )
  joined$.unitJoinKey <- NULL
  unresolved <- is.na(joined$unitConceptId) &
    joined$analysisId %in% analysisIds
  if (any(unresolved)) {
    ParallelLogger::logWarn(
      sum(unresolved), " measurement value covariate(s) have no row in ",
      file, ", so their unit is unknown. That means the measurement table ",
      "changed between the extraction and the crosswalk."
    )
  }
  ParallelLogger::logInfo(
    "Resolved the unit of ", sum(!is.na(joined$unitConceptId)),
    " measurement value covariate(s)"
  )
  joined
}

#' Write the FeatureExtraction output in long format
#'
#' Streams the saved temporal `covariateData` to
#' `featureExtractionLong.csv` with the columns `rowId`, `covariateId`,
#' `timeId`, and `covariateValue`, and writes `covariateRef.csv` and
#' `timeRef.csv` next to it so the identifiers in that file can be read without
#' opening the extraction again. Those three files, with `outcomeLabels.csv`,
#' are everything `extras/CreateSparseArray.R` needs, and enough to build
#' whatever other shape a model wants. The values are the unmodified
#' FeatureExtraction output: identifiers are not remapped and rows are not
#' aggregated, so `timeId` is the sequence position or window identifier
#' FeatureExtraction assigned, not the array time index. Covariates produced by
#' non-temporal analyses have an empty `timeId`.
#'
#' `covariateRef.csv` carries one column FeatureExtraction's own reference table
#' does not: `unitConceptId`, joined from the `measurementValueUnitRef.csv`
#' that [exportMeasurementValueUnitRef()] writes, and empty for anything that
#' is not a measurement value covariate. Without it a measurement value cannot
#' be looked up in a quantile table, because the covariate id keeps the unit
#' only modulo 1000.
#'
#' @param outputFolder Folder containing the saved `covariateData` artifact.
#' @param extraction Which saved extraction to read, as named by the folder
#'   under `outputFolder/plpData`. Only needed when there is more than one.
#' @param batchSize Maximum number of rows fetched from Andromeda per batch.
#'
#' @return Invisibly returns the paths of the files written.
#' @export
createLongFormat <- function(outputFolder,
                             extraction = NULL,
                             batchSize = 1e6) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertCount(batchSize, positive = TRUE)
  covariateData <- .loadCovariateDataFrom(outputFolder, extraction)
  on.exit({
    if (Andromeda::isValidAndromeda(covariateData)) {
      try(Andromeda::close(covariateData), silent = TRUE)
    }
  }, add = TRUE)
  # Both temporal sequence and temporal window extractions carry a timeId
  # column, which is what isTemporalCovariateData() tests.
  if (!FeatureExtraction::isTemporalCovariateData(covariateData)) {
    stop(
      "The saved covariateData has no timeId. Re-run the feature stage with ",
      "temporal sequence settings, see ",
      "FeatureExtraction::createTemporalSequenceCovariateSettings().",
      call. = FALSE
    )
  }

  outputFile <- file.path(outputFolder, "featureExtractionLong.csv")
  stagingFile <- tempfile("featureExtractionLong-", tmpdir = outputFolder)
  on.exit(unlink(stagingFile, force = TRUE), add = TRUE)

  connection <- file(stagingFile, open = "wt")
  writeLines("rowId,covariateId,timeId,covariateValue", connection)
  rows <- covariateData$covariates %>%
    dplyr::select(dplyr::all_of(c(
      "rowId",
      "covariateId",
      "timeId",
      "covariateValue"
    ))) %>%
    dplyr::arrange(
      .data$rowId,
      dplyr::desc(is.na(.data$timeId)),
      .data$timeId,
      .data$covariateId
    )
  tryCatch(
    Andromeda::batchApply(
      rows,
      .writeLongFormatBatch,
      connection = connection,
      batchSize = batchSize,
      progressBar = FALSE,
      safe = FALSE
    ),
    finally = close(connection)
  )

  Sys.chmod(stagingFile, mode = "600")
  if (file.exists(outputFile)) {
    unlink(outputFile, force = TRUE)
  }
  if (!file.rename(stagingFile, outputFile)) {
    stop("Failed to save featureExtractionLong.csv.", call. = FALSE)
  }
  ParallelLogger::logInfo("Wrote long-format features to ", outputFile)

  # The reference tables are small enough to collect, and without them the
  # covariateId and timeId columns of the long file mean nothing on their own.
  written <- c(outputFile)
  for (table in c("covariateRef", "timeRef", "analysisRef")) {
    if (!table %in% names(covariateData)) {
      next
    }
    contents <- dplyr::collect(covariateData[[table]])
    if (identical(table, "covariateRef")) {
      contents <- .addUnitConceptId(contents, covariateData, outputFolder)
    }
    file <- file.path(outputFolder, paste0(table, ".csv"))
    utils::write.csv(
      contents,
      file,
      row.names = FALSE
    )
    ParallelLogger::logInfo("Wrote ", table, " to ", file)
    written <- c(written, file)
  }
  invisible(written)
}
