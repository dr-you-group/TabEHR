# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Turning a FeatureExtraction covariate back into an allrecords token.
#
# The two sides of this project identify a record differently:
#
#   allrecords.csv            concept_id, and "<concept_id>_<bin>" for a
#                             measurement, which is what the pretrained
#                             embedding is keyed on
#   featureExtractionLong.csv covariateId, which FeatureExtraction builds from
#                             the concept, the analysis and, for a measurement
#                             value, the unit
#
# FeatureExtraction v3.2.0 builds the id in two ways, and SparseArray's
# measurement value builder reproduces the second one exactly:
#
#   DomainConcept.sql     covariate_id = concept_id * 1000 + analysis_id
#   MeasurementValue.sql  covariate_id = measurement_concept_id * 1000000
#                                      + (unit_concept_id % 1000) * 1000
#                                      + analysis_id
#
# The concept is recoverable from either formula, but the unit survives only
# modulo 1000, and a quantile table is keyed on the whole unit. So the
# conversion does not invert the id at all. It looks the covariate up:
#
#   featureExtractionLong.csv  covariateId, covariateValue
#            |  covariateRef.csv, on covariateId
#            v
#   conceptId, unitConceptId          <- named, not computed. unitConceptId is
#            |                           the column SparseArray joins in from
#            |  meas_quantiles.csv,      measurementValueUnitRef.csv
#            |  on (measurement_concept_id, unit_concept_id)
#            v
#   quantile_0 .. quantile_n -> bin -> "<conceptId>_<bin>"
#
# Two joins, and `unit_concept_id % 1000` appears in neither of them. Which
# analysis an id belongs to does not come up either: a covariate gets a bin if
# and only if its (concept, unit) pair has a quantile row, and only a
# measurement value covariate has a unit to begin with.
#
# decodeCovariateId() keeps the arithmetic for reading an id on its own, where
# the analysis does matter: the same analysisId means different things in the
# temporal and the non-temporal set. In the temporal set this package uses, 702
# is MeasurementValue; in the non-temporal set, 702 is MeasurementLongTerm, a
# plain DomainConcept analysis, and MeasurementValue is 705-708.

#' Decode a FeatureExtraction covariate id
#'
#' The id arithmetic on its own, for when there is no reference table to hand:
#' inspecting a covariate id, or checking one. The conversion to a token does
#' not use it, see [resolveCovariateId()], because the unit it yields is only
#' `unit_concept_id` modulo 1000.
#'
#' @param covariateId Numeric vector of covariate ids.
#' @param measurementValueAnalysisIds Analysis ids built by
#'   `MeasurementValue.sql`. The default, 702, is the temporal analysis set this
#'   package extracts with; the non-temporal set uses 705 to 708.
#'
#' @return A data frame with `covariateId`, `analysisId`, `conceptId` and
#'   `unitConceptIdMod1000`, the last being `NA` for anything that is not a
#'   measurement value covariate.
#' @export
decodeCovariateId <- function(covariateId,
                              measurementValueAnalysisIds = 702) {
  checkmate::assertNumeric(covariateId, any.missing = FALSE)
  checkmate::assertNumeric(measurementValueAnalysisIds, any.missing = FALSE)
  if (any(abs(covariateId) > 2^53)) {
    stop("A covariate id beyond 2^53 cannot be decoded exactly as a double.",
         call. = FALSE)
  }
  analysisId <- covariateId %% 1000
  isMeasurementValue <- analysisId %in% measurementValueAnalysisIds
  conceptId <- ifelse(
    isMeasurementValue,
    covariateId %/% 1e6,
    (covariateId - analysisId) / 1000
  )
  data.frame(
    covariateId = covariateId,
    analysisId = analysisId,
    conceptId = conceptId,
    unitConceptIdMod1000 = ifelse(
      isMeasurementValue,
      (covariateId %% 1e6) %/% 1000,
      NA_real_
    )
  )
}

#' Resolve covariates through the reference table
#'
#' What a covariate stands for is looked up, not computed: `covariateRef.csv`,
#' as [SparseArray::createLongFormat()] writes it, already names the
#' `conceptId` of every covariate, and carries the `unitConceptId` joined from
#' `measurementValueUnitRef.csv`. So the path from a covariate to an
#' `allrecords` token is two joins and no arithmetic, which matters because one
#' of the two arithmetic routes is lossy: the id keeps `unit_concept_id` only
#' modulo 1000.
#'
#' A covariate id whose id is not in the reference table is an error: the long
#' file and the reference table have to be from one extraction.
#'
#' A covariate id that two units share, which is what happens when their
#' concept ids agree modulo 1000, has two rows in the reference table. Such an
#' id is genuinely ambiguous: the covariate's values mix both units, and no
#' table can undo that. It comes back with `unitConceptId` `NA` and
#' `unitAmbiguous` `TRUE` rather than with one unit picked for it.
#'
#' @param covariateId Numeric vector of covariate ids.
#' @param covariateRef The reference table, with `covariateId`, `analysisId`,
#'   `conceptId` and `unitConceptId`. Snake case column names are accepted as
#'   well.
#'
#' @return A data frame with `covariateId`, `analysisId`, `conceptId`,
#'   `unitConceptId` and `unitAmbiguous`, one row per input id, in the input
#'   order.
#' @export
resolveCovariateId <- function(covariateId, covariateRef) {
  checkmate::assertNumeric(covariateId, any.missing = FALSE)
  checkmate::assertDataFrame(covariateRef)
  # Only the names that are actually snake case: snakeCaseToCamelCase()
  # lower-cases its input first, so it would turn covariateId into
  # covariateid.
  snake <- grepl("_", names(covariateRef))
  names(covariateRef)[snake] <- SqlRender::snakeCaseToCamelCase(
    names(covariateRef)[snake]
  )
  required <- c("covariateId", "analysisId", "conceptId", "unitConceptId")
  absent <- required[!required %in% names(covariateRef)]
  if (length(absent) > 0) {
    stop("covariateRef is missing the column(s) ",
         paste(absent, collapse = ", "),
         ". Use the covariateRef.csv SparseArray::createLongFormat() writes, ",
         "which joins the unit from measurementValueUnitRef.csv.",
         call. = FALSE)
  }
  rows <- unique(covariateRef[, required])

  # One id with two units is ambiguous, and no row of it can be trusted to
  # name the unit. Everything else about it still can.
  withUnit <- rows[!is.na(rows$unitConceptId), ]
  ambiguous <- unique(withUnit$covariateId[duplicated(withUnit$covariateId)])
  single <- withUnit[!withUnit$covariateId %in% ambiguous, ]

  row <- match(covariateId, rows$covariateId)
  if (anyNA(row)) {
    stop(sum(is.na(row)), " covariate id(s) have no row in covariateRef, so ",
         "the two are not from one extraction. First: ",
         paste(utils::head(unique(covariateId[is.na(row)]), 5),
               collapse = ", "),
         ".", call. = FALSE)
  }
  data.frame(
    covariateId = covariateId,
    analysisId = rows$analysisId[row],
    conceptId = rows$conceptId[row],
    unitConceptId = single$unitConceptId[match(covariateId,
                                               single$covariateId)],
    unitAmbiguous = covariateId %in% ambiguous
  )
}

#' Assign the quantile bin of a measurement value
#'
#' The same rule the SQL applies, which is the rule the original MedRep code
#' applies: `max(0, bisect_left(boundaries, value) - 1)`, which is the number of
#' boundaries strictly below the value, less one, clamped at zero.
#'
#' @param value Numeric vector of measurement values.
#' @param boundaries Numeric matrix of quantile boundaries, one row per value,
#'   ascending across columns. A row of `NA` yields `NA`.
#'
#' @return An integer vector of bins, or `NA` where no boundaries were given.
#' @export
assignQuantileBin <- function(value, boundaries) {
  checkmate::assertNumeric(value)
  boundaries <- as.matrix(boundaries)
  if (nrow(boundaries) != length(value)) {
    stop("boundaries must have one row per value: ", nrow(boundaries),
         " rows for ", length(value), " value(s).", call. = FALSE)
  }
  below <- rowSums(boundaries < value, na.rm = TRUE)
  known <- rowSums(!is.na(boundaries)) > 0 & !is.na(value)
  bin <- pmax(0, below - 1)
  bin[!known] <- NA_integer_
  as.integer(bin)
}

#' Turn FeatureExtraction covariates into allrecords tokens
#'
#' Resolves each covariate to the token the model vocabulary uses: the bare
#' `concept_id` for a condition, drug or procedure covariate, and
#' `"<concept_id>_<bin>"` for a measurement value covariate, binned with the
#' quantile table this package wrote.
#'
#' Two joins and no arithmetic: [resolveCovariateId()] reads the concept and
#' the unit out of `covariateRef`, and the `(measurement_concept_id,
#' unit_concept_id)` pair it returns is the key of the quantile table. The
#' `unit_concept_id % 1000` the covariate id carries is never used as a key,
#' because it would be one that is right only while no two units in use agree
#' in their last three digits.
#'
#' A measurement covariate whose pair has no row in the quantile table gets the
#' bare `concept_id`, which is the same fallback `AllRecords.sql` applies, and
#' `hasBin` says which rows those are. So does a covariate whose unit is
#' ambiguous, see [resolveCovariateId()].
#'
#' @param covariateId Numeric vector of covariate ids.
#' @param covariateValue Numeric vector of covariate values, the same length.
#'   Only read for measurement value covariates.
#' @param measQuantiles The quantile table, as `meas_quantiles.csv` holds it:
#'   `measurement_concept_id`, `unit_concept_id`, and `quantile_0` to
#'   `quantile_<quantileCount>`.
#' @param covariateRef The reference table, see [resolveCovariateId()].
#'
#' @return A data frame with `covariateId`, `analysisId`, `conceptId`,
#'   `unitConceptId`, `unitAmbiguous`, `covariateValue`, `bin`, `hasBin` and
#'   `token`.
#' @export
covariateToToken <- function(covariateId,
                             covariateValue,
                             measQuantiles,
                             covariateRef) {
  checkmate::assertNumeric(covariateValue, len = length(covariateId))
  checkmate::assertDataFrame(measQuantiles)
  quantileColumns <- grep("^quantile_[0-9]+$", names(measQuantiles),
                          value = TRUE)
  if (length(quantileColumns) == 0) {
    stop("measQuantiles has no quantile_<n> columns.", call. = FALSE)
  }
  quantileColumns <- quantileColumns[order(as.integer(
    sub("^quantile_", "", quantileColumns)
  ))]

  resolved <- resolveCovariateId(covariateId, covariateRef)
  resolved$covariateValue <- covariateValue

  required <- c("measurement_concept_id", "unit_concept_id")
  absent <- required[!required %in% names(measQuantiles)]
  if (length(absent) > 0) {
    stop("measQuantiles is missing the column(s) ",
         paste(absent, collapse = ", "),
         ". Use the meas_quantiles.csv this package writes.", call. = FALSE)
  }

  key <- paste(measQuantiles$measurement_concept_id,
               measQuantiles$unit_concept_id, sep = "|")
  if (anyDuplicated(key)) {
    stop("measQuantiles has more than one row for a (concept, unit) pair, ",
         "which is its primary key, so it was not written by this package.",
         call. = FALSE)
  }
  row <- match(
    paste(resolved$conceptId, resolved$unitConceptId, sep = "|"), key
  )
  boundaries <- matrix(NA_real_, nrow = nrow(resolved),
                       ncol = length(quantileColumns))
  found <- !is.na(row)
  if (any(found)) {
    boundaries[found, ] <- as.matrix(
      measQuantiles[row[found], quantileColumns, drop = FALSE]
    )
  }

  resolved$bin <- assignQuantileBin(resolved$covariateValue, boundaries)
  resolved$hasBin <- !is.na(resolved$bin)
  resolved$token <- ifelse(
    resolved$hasBin,
    paste0(format(resolved$conceptId, scientific = FALSE, trim = TRUE), "_",
           resolved$bin),
    format(resolved$conceptId, scientific = FALSE, trim = TRUE)
  )
  resolved
}
