# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' TabEHR: preprocessing and downstream task data for EHR foundation models
#'
#' The record preprocessing of the MedRep study, ported from pandas to OHDSI
#' SQL, with the patient split that pretraining and the downstream tasks share.
#'
#' [execute()] runs the stages in order:
#'
#' \describe{
#'   \item{[extractRecords()]}{condition, drug, procedure and measurement
#'     records, filtered the way `create_trajectory.py` filters them.}
#'   \item{[createStudyPopulation()]}{adults, with a qualifying inpatient
#'     admission, and with enough records.}
#'   \item{[createPersonSplit()]}{one split, by patient, into pretraining and
#'     downstream.}
#'   \item{[createMeasurementQuantiles()] and [createAllRecords()]}{the
#'     measurement bins, taken from the pretraining patients, and the finished
#'     record table.}
#'   \item{[runSparseArray()]}{the SparseArray study package, restricted to the
#'     downstream patients.}
#'   \item{[runDiagnostics()]}{the checks, written to `validation_report.md`.}
#' }
#'
#' Only [createPersonSplit()] is site specific: an external validation site
#' marks every patient `external` and applies the primary site's quantile
#' table, which [createAnalysisSettings()] expresses with
#' `siteRole = "external"`.
#'
#' @importFrom dplyr %>%
#' @importFrom rlang .data
#' @keywords internal
"_PACKAGE"
