# Copyright 2026 SparseArray Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The two FeatureExtraction settings families this package can build a time axis
# from. "temporalSequence" is the default: it uses
# FeatureExtraction::createTemporalSequenceCovariateSettings(), where one timeId
# is one fixed-length interval counted back from the index date.
.settingsTypes <- c("temporalSequence", "temporal")

# The time parts a temporal sequence extraction can count in.
.timePartNames <- c("day", "month", "year")

.sequenceArgNames <- c(
  "timePart",
  "timeInterval",
  "sequenceStartDay",
  "sequenceEndDay"
)

.temporalArgNames <- c("temporalStartDays", "temporalEndDays")

# Covariate analyses this package builds itself, asked for in a settings block
# the same way FeatureExtraction's own analyses are. They are not arguments of
# any FeatureExtraction constructor, so they are taken out of the argument list
# before the object is built, and buildCovariateSettings() adds the builder
# each one stands for.
#
#   useMeasurementValueUnit  createMeasurementValueUnitCovariateSettings(),
#                            which replaces FeatureExtraction's
#                            useMeasurementValue because the temporal sequence
#                            branch of its MeasurementValue.sql does not render
#                            to valid SQL, and which leaves behind the
#                            crosswalk that makes the unit recoverable
.customAnalysisArgNames <- c("useMeasurementValueUnit")

#' @noRd
.customAnalyses <- function(args) {
  named <- .customAnalysisArgNames[.customAnalysisArgNames %in% names(args)]
  named[vapply(named, function(name) isTRUE(args[[name]]), logical(1))]
}

#' @noRd
.stripCustomAnalysisArgs <- function(args) {
  args[!names(args) %in% .customAnalysisArgNames]
}

#' @noRd
.assertCustomAnalysisArgs <- function(args, context) {
  # Exact lookups: list$useMeasurementValue would partially match
  # useMeasurementValueUnit and fire on a block that only asks for the one.
  if (!isTRUE(args[["useMeasurementValueUnit"]])) {
    return(invisible(NULL))
  }
  if (isTRUE(args[["useMeasurementValue"]])) {
    stop(
      context, " asks for both useMeasurementValue and ",
      "useMeasurementValueUnit. They are two ways to extract the same thing, ",
      "and FeatureExtraction's own temporal sequence SQL for ",
      "useMeasurementValue does not render, so ask for ",
      "useMeasurementValueUnit alone.",
      call. = FALSE
    )
  }
  if (isTRUE(args[["useMeasurement"]])) {
    stop(
      context, " asks for both useMeasurement and useMeasurementValueUnit. ",
      "FeatureExtraction's useMeasurement (analysis 701) covers every ",
      "measurement, so one record would get two covariates. ",
      "useMeasurementValueUnit already covers the measurements with no ",
      "numeric value, with its own analysis id, so ask for it alone.",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Build the covariate settings a flat argument list asks for
#'
#' The seam between a study definition and this package. A settings block is a
#' flat list of arguments, as `saveCovariateSettings()` stores them, holding
#' FeatureExtraction's own `use*` flags and the analyses this package builds
#' itself. This turns it into the list of settings objects an extraction needs:
#' FeatureExtraction's own object first, then one object per custom analysis.
#'
#' FeatureExtraction's own object has to come first.
#' [FeatureExtraction::getDbCovariateData()] merges the results of several
#' settings objects into the tables of whichever came first, selecting by the
#' column names of those tables, so a custom builder that comes second can only
#' be held to FeatureExtraction's shape and never silently impose its own.
#'
#' @param covariateSettingsArgs A named list of arguments. `settingsType`
#'   selects the FeatureExtraction constructor; `useMeasurementValueUnit` asks
#'   for [createMeasurementValueUnitCovariateSettings()]. At least one
#'   FeatureExtraction analysis is still required, which its constructor
#'   enforces.
#' @param context Where the arguments came from, used in error messages.
#'
#' @return A list of `covariateSettings` objects.
#' @export
buildCovariateSettings <- function(covariateSettingsArgs,
                                   context = "covariateSettings") {
  checkmate::assertList(covariateSettingsArgs, names = "named")
  checkmate::assertString(context, min.chars = 1)
  args <- covariateSettingsArgs
  settingsType <- args$settingsType
  args$settingsType <- NULL
  # JSON arrays come back as lists; FeatureExtraction expects atomic vectors,
  # and an empty JSON object is the equivalent of c().
  args <- lapply(args, function(value) {
    if (is.list(value)) unlist(value, use.names = FALSE) else value
  })
  if (is.null(settingsType)) {
    settingsType <- .inferSettingsType(args)
    if (is.null(settingsType)) {
      stop(
        context, " has no settingsType and no recognizable temporal arguments.",
        call. = FALSE
      )
    }
  }
  settingsType <- match.arg(settingsType, .settingsTypes)
  if (settingsType == "temporalSequence") {
    .assertSequenceArgs(args)
  } else {
    .assertTemporalArgs(args)
  }
  .assertCustomAnalysisArgs(args, context)

  settings <- list(do.call(
    getExportedValue("FeatureExtraction", .settingsTypeFunctions[[settingsType]]),
    .stripCustomAnalysisArgs(args)
  ))
  if ("useMeasurementValueUnit" %in% .customAnalyses(args)) {
    settings <- c(settings, list(.measurementValueUnitSettings(args)))
  }
  settings
}

.settingsTypeFunctions <- list(
  temporalSequence = "createTemporalSequenceCovariateSettings",
  temporal = "createTemporalCovariateSettings"
)

#' @noRd
.inferSettingsType <- function(args) {
  if (any(.sequenceArgNames %in% names(args))) {
    return("temporalSequence")
  }
  if (any(.temporalArgNames %in% names(args))) {
    return("temporal")
  }
  NULL
}

#' @noRd
.assertSequenceArgs <- function(args) {
  absent <- .sequenceArgNames[!.sequenceArgNames %in% names(args)]
  if (length(absent) > 0) {
    stop(
      "Temporal sequence settings require ",
      paste(.sequenceArgNames, collapse = ", "),
      ". Missing: ",
      paste(absent, collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  checkmate::assertString(args$timePart, min.chars = 1)
  if (!tolower(args$timePart) %in% .timePartNames) {
    stop(
      "timePart must be one of ",
      paste(sQuote(.timePartNames), collapse = ", "),
      ", not ",
      sQuote(args$timePart),
      ".",
      call. = FALSE
    )
  }
  checkmate::assertInt(args$timeInterval, lower = 1)
  checkmate::assertInt(args$sequenceStartDay)
  checkmate::assertInt(args$sequenceEndDay)
  if (args$sequenceStartDay > args$sequenceEndDay) {
    stop(
      "sequenceStartDay (", args$sequenceStartDay,
      ") must not be after sequenceEndDay (", args$sequenceEndDay, ").",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' @noRd
.assertTemporalArgs <- function(args) {
  if (is.null(args$temporalStartDays) || is.null(args$temporalEndDays)) {
    stop(
      "temporalStartDays and temporalEndDays are required for temporal window ",
      "settings: this package only builds three-dimensional covariate data.",
      call. = FALSE
    )
  }
  if (length(args$temporalStartDays) != length(args$temporalEndDays)) {
    stop(
      "temporalStartDays and temporalEndDays must have the same length.",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' Save temporal FeatureExtraction settings
#'
#' The arguments are validated by constructing the settings object, then stored
#' as a flat JSON argument list so that the packaged settings stay readable and
#' editable. The stored `settingsType` records which FeatureExtraction
#' constructor the arguments belong to.
#'
#' @param covariateSettingsArgs Arguments for the FeatureExtraction constructor
#'   selected by `settingsType`. For `"temporalSequence"`, `timePart`,
#'   `timeInterval`, `sequenceStartDay`, and `sequenceEndDay` are required. For
#'   `"temporal"`, `temporalStartDays` and `temporalEndDays` of equal length are
#'   required. `useMeasurementValueUnit` may be set alongside
#'   FeatureExtraction's own `use*` flags: it asks for
#'   [createMeasurementValueUnitCovariateSettings()], which
#'   [buildCovariateSettings()] adds to the extraction.
#' @param file Destination JSON file.
#' @param settingsType Either `"temporalSequence"` for
#'   [FeatureExtraction::createTemporalSequenceCovariateSettings()], the default
#'   and main path of this package, or `"temporal"` for
#'   [FeatureExtraction::createTemporalCovariateSettings()]. When `NULL`, the
#'   type is inferred from the supplied arguments.
#'
#' @export
saveCovariateSettings <- function(covariateSettingsArgs,
                                  file,
                                  settingsType = NULL) {
  checkmate::assertList(covariateSettingsArgs, names = "named")
  checkmate::assertString(file, min.chars = 1)
  if (is.null(settingsType)) {
    settingsType <- .inferSettingsType(covariateSettingsArgs)
    if (is.null(settingsType)) {
      stop(
        "Cannot tell which settings are meant. Supply the temporal sequence ",
        "arguments (", paste(.sequenceArgNames, collapse = ", "),
        "), the temporal window arguments (",
        paste(.temporalArgNames, collapse = ", "),
        "), or pass settingsType explicitly.",
        call. = FALSE
      )
    }
  }
  settingsType <- match.arg(settingsType, .settingsTypes)

  args <- covariateSettingsArgs
  args$settingsType <- NULL
  if (settingsType == "temporalSequence") {
    .assertSequenceArgs(args)
  } else {
    .assertTemporalArgs(args)
  }
  .assertCustomAnalysisArgs(args, "covariateSettingsArgs")
  # Constructing the object validates the covariate selection itself, including
  # the FeatureExtraction requirement that at least one analysis is selected.
  # The analyses this package builds itself are not arguments of that
  # constructor, so they are left out here and kept in the file.
  do.call(
    getExportedValue("FeatureExtraction", .settingsTypeFunctions[[settingsType]]),
    .stripCustomAnalysisArgs(args)
  )

  if (!file.exists(dirname(file))) {
    dir.create(dirname(file), recursive = TRUE)
  }
  writeLines(
    jsonlite::toJSON(
      c(list(settingsType = settingsType), args),
      auto_unbox = TRUE,
      pretty = TRUE
    ),
    file
  )
  invisible(NULL)
}

#' Load temporal FeatureExtraction settings
#'
#' Settings files without a `settingsType` entry are read as the type implied by
#' their arguments, so files written by earlier versions still load.
#'
#' @param file JSON file created by [saveCovariateSettings()].
#'
#' @return A FeatureExtraction `covariateSettings` object. Temporal sequence
#'   settings carry `temporalSequence = TRUE`, temporal window settings carry
#'   `temporal = TRUE`.
#' @export
loadCovariateSettings <- function(file) {
  checkmate::assertString(file, min.chars = 1)
  if (!file.exists(file)) {
    stop("Cannot find covariate settings file: ", file, call. = FALSE)
  }
  args <- jsonlite::fromJSON(file, simplifyDataFrame = FALSE)
  settingsType <- args$settingsType
  args$settingsType <- NULL
  # JSON arrays come back as lists; FeatureExtraction expects atomic vectors,
  # and an empty JSON object is the equivalent of c().
  args <- lapply(args, function(value) {
    if (is.list(value)) unlist(value, use.names = FALSE) else value
  })
  if (is.null(settingsType)) {
    settingsType <- .inferSettingsType(args)
    if (is.null(settingsType)) {
      stop(
        "The settings file has no settingsType and no recognizable temporal ",
        "arguments: ", file,
        call. = FALSE
      )
    }
  }
  settingsType <- match.arg(settingsType, .settingsTypes)
  if (settingsType == "temporalSequence") {
    .assertSequenceArgs(args)
  } else {
    .assertTemporalArgs(args)
  }
  .assertCustomAnalysisArgs(args, file)
  custom <- .customAnalyses(args)
  if (length(custom) > 0) {
    warning(
      file, " asks for ", paste(custom, collapse = ", "),
      ", which this package builds itself rather than through a ",
      "FeatureExtraction constructor, so it is not part of the object ",
      "returned here. buildCovariateSettings() returns it alongside ",
      "FeatureExtraction's own object.",
      call. = FALSE
    )
  }
  do.call(
    getExportedValue("FeatureExtraction", .settingsTypeFunctions[[settingsType]]),
    .stripCustomAnalysisArgs(args)
  )
}

#' @noRd
.isTemporalSequenceSettings <- function(covariateSettings) {
  isTRUE(covariateSettings$temporalSequence)
}

#' @noRd
.isTemporalWindowSettings <- function(covariateSettings) {
  isTRUE(covariateSettings$temporal)
}
