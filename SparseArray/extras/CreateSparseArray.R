# Copyright 2026 SparseArray Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Builds the three-dimensional sparse array of patient by time position by
# covariate from a saved extraction.
#
# This is optional: the study pipeline stops at featureExtractionLong.csv, which
# together with covariateRef.csv, timeRef.csv and outcomeLabels.csv is enough to
# build whatever shape a model needs. Source this file and call
# createSparseArray() when the array itself is wanted.
#
#   source("extras/CreateSparseArray.R")
#   array <- createSparseArray(outputFolder, extraction = "target1000_admission")
#
# Needs the slam package, which the study pipeline itself does not.

stopifnot(requireNamespace("slam", quietly = TRUE))

# Self-contained: the two things this used to borrow from the package.
.timePartNames <- c("day", "month", "year")

# The covariateData of a saved extraction. Mirrors the loader in
# R/extractPlpData.R so this script runs without the package attached.
.loadCovariateDataFrom <- function(outputFolder, extraction = NULL) {
  root <- file.path(outputFolder, "plpData")
  folders <- if (dir.exists(root)) {
    list.dirs(root, full.names = TRUE, recursive = FALSE)
  } else {
    character(0)
  }
  if (!is.null(extraction)) {
    folder <- file.path(root, extraction)
    if (!dir.exists(folder)) {
      stop("Cannot find the extraction ", extraction, " in ", outputFolder,
           ". Available: ", paste(basename(folders), collapse = ", "),
           call. = FALSE)
    }
    return(PatientLevelPrediction::loadPlpData(folder)$covariateData)
  }
  if (length(folders) == 1) {
    return(PatientLevelPrediction::loadPlpData(folders)$covariateData)
  }
  if (length(folders) > 1) {
    stop("There are ", length(folders), " extractions in ", outputFolder,
         ", so one has to be named: ",
         paste(basename(folders), collapse = ", "), ".", call. = FALSE)
  }
  covariateFile <- file.path(outputFolder, "covariateData")
  if (file.exists(covariateFile)) {
    return(FeatureExtraction::loadCovariateData(covariateFile))
  }
  stop("Cannot find a saved plpData under ", root, ".", call. = FALSE)
}

#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# Time axis construction.
#
# FeatureExtraction describes the time dimension in the saved covariateData
# `timeRef` table, and it describes it differently per settings family:
#
# * createTemporalCovariateSettings() writes one row per requested window, with
#   the columns timeId, startDay, and endDay. The axis is read straight off that
#   table.
# * createTemporalSequenceCovariateSettings() writes a single row describing the
#   parameterization instead: timePart, timeInterval, sequenceStartDay, and
#   sequenceEndDay. The covariate timeId values are computed on the server as
#
#       timeId = FLOOR(DATEDIFF(timePart, eventDate, indexDate) / timeInterval)
#
#   so timeId 0 is the interval ending on the index date and timeId grows going
#   back in time. The axis therefore has to be derived from those four values.

# .timePartNames lives in Settings.R, which validates the settings themselves.

# Shortest and longest possible length in days of one unit of timePart.
.timePartDayBounds <- function(timePart) {
  bounds <- switch(
    tolower(timePart),
    day = c(min = 1, max = 1),
    month = c(min = 28, max = 31),
    year = c(min = 365, max = 366),
    NULL
  )
  if (is.null(bounds)) {
    stop(
      "Unsupported timePart ", sQuote(timePart), ". Use ",
      paste(sQuote(.timePartNames), collapse = ", "), ".",
      call. = FALSE
    )
  }
  bounds
}

# Bounds on DATEDIFF(timePart, eventDate, indexDate) for an event that falls
# exactly nDays before the index date. DATEDIFF counts calendar boundaries, so
# for months and years the count depends on where in the calendar the dates land
# and only a range can be given. Days are exact.
.timePartUnitRange <- function(nDays, timePart) {
  bounds <- .timePartDayBounds(timePart)
  if (bounds[["min"]] == bounds[["max"]] && bounds[["min"]] == 1) {
    return(c(lower = nDays, upper = nDays))
  }
  if (nDays >= 0) {
    c(
      lower = floor(nDays / bounds[["max"]]),
      upper = floor(nDays / bounds[["min"]]) + 1
    )
  } else {
    c(
      lower = -(floor(-nDays / bounds[["min"]]) + 1),
      upper = -floor(-nDays / bounds[["max"]])
    )
  }
}

# The timeId values a temporalSequence extraction can produce. Exact for
# timePart "day"; a conservative superset for "month" and "year".
.sequenceTimeIdRange <- function(timePart,
                                 timeInterval,
                                 sequenceStartDay,
                                 sequenceEndDay) {
  # The extraction keeps events whose date offset from the index date lies in
  # [sequenceStartDay, sequenceEndDay], so the number of days before the index
  # date lies in [-sequenceEndDay, -sequenceStartDay].
  daysBeforeIndex <- c(-sequenceEndDay, -sequenceStartDay)
  lower <- .timePartUnitRange(min(daysBeforeIndex), timePart)[["lower"]]
  upper <- .timePartUnitRange(max(daysBeforeIndex), timePart)[["upper"]]
  c(
    lower = floor(lower / timeInterval),
    upper = floor(upper / timeInterval)
  )
}

.assertSequenceTimeRef <- function(timeRef) {
  required <- c(
    "timePart",
    "timeInterval",
    "sequenceStartDay",
    "sequenceEndDay"
  )
  absent <- required[!required %in% names(timeRef)]
  if (length(absent) > 0) {
    stop(
      "The timeRef table of a temporal sequence extraction must have the ",
      "columns ", paste(required, collapse = ", "), ". Missing: ",
      paste(absent, collapse = ", "), ".",
      call. = FALSE
    )
  }
  if (nrow(timeRef) != 1L) {
    stop(
      "The timeRef table of a temporal sequence extraction must have exactly ",
      "one row, not ", nrow(timeRef), ".",
      call. = FALSE
    )
  }
  invisible(NULL)
}

# Build the time axis of a temporalSequence extraction.
#
# Returns a data frame with one row per position on the time axis, ordered by
# timeId ascending. The FeatureExtraction timeId is kept as it was extracted
# rather than reversed to run oldest first: timeIndex is then a plain offset of
# timeId, which keeps the array directly comparable with
# featureExtractionLong.csv. For a lookback window that means timeIndex 1 is the
# interval nearest the index date; reverse the second array dimension downstream
# if a model needs oldest-to-newest input.
.sequenceTimeMap <- function(timeRef, observedTimeIds, timeAxis = "settings") {
  .assertSequenceTimeRef(timeRef)
  timePart <- tolower(as.character(timeRef$timePart[[1]]))
  timeInterval <- as.integer(timeRef$timeInterval[[1]])
  sequenceStartDay <- as.integer(timeRef$sequenceStartDay[[1]])
  sequenceEndDay <- as.integer(timeRef$sequenceEndDay[[1]])
  if (!timePart %in% .timePartNames) {
    stop(
      "Unsupported timePart ", sQuote(timePart), " in timeRef. Use ",
      paste(sQuote(.timePartNames), collapse = ", "), ".",
      call. = FALSE
    )
  }
  if (is.na(timeInterval) || timeInterval < 1L) {
    stop("timeInterval in timeRef must be a positive whole number.", call. = FALSE)
  }
  if (sequenceStartDay > sequenceEndDay) {
    stop(
      "sequenceStartDay (", sequenceStartDay,
      ") in timeRef must not be after sequenceEndDay (", sequenceEndDay, ").",
      call. = FALSE
    )
  }

  observedTimeIds <- sort(unique(as.integer(observedTimeIds)))
  range <- .sequenceTimeIdRange(
    timePart = timePart,
    timeInterval = timeInterval,
    sequenceStartDay = sequenceStartDay,
    sequenceEndDay = sequenceEndDay
  )
  outside <- observedTimeIds[
    observedTimeIds < range[["lower"]] | observedTimeIds > range[["upper"]]
  ]
  if (length(outside) > 0) {
    stop(
      "Found ", length(outside), " observed timeId(s) outside the range the ",
      "sequence settings allow (", range[["lower"]], " to ", range[["upper"]],
      "), for example ", paste(utils::head(outside, 5), collapse = ", "),
      ". The saved covariateData and its timeRef do not agree.",
      call. = FALSE
    )
  }

  # For days the arithmetic is exact, so the axis can be fixed by the settings
  # alone and is then identical across cohorts and databases. That only pays off
  # while the requested window is close to the history the data actually holds:
  # an open-ended window such as sequenceStartDay = -99999, which asks for every
  # record a subject has, would otherwise pad the array with tens of thousands
  # of positions that can never hold data. timeAxis = "observed" clips the axis
  # to the timeId values the extraction produced, giving the shortest axis that
  # still holds every observation, at the cost of an axis that depends on the
  # data rather than on the settings alone.
  #
  # For months and years DATEDIFF counts calendar boundaries, so the settings
  # only bound the axis and the observed span is always used.
  exact <- timePart == "day" && timeAxis == "settings"
  if (exact) {
    timeIds <- seq(range[["lower"]], range[["upper"]])
  } else if (timePart == "day") {
    if (length(observedTimeIds) == 0L) {
      stop(
        "There are no observed timeId values, so the time axis cannot be ",
        "clipped to them. Use timeAxis = \"settings\".",
        call. = FALSE
      )
    }
    timeIds <- seq(
      max(range[["lower"]], min(observedTimeIds)),
      min(range[["upper"]], max(observedTimeIds))
    )
  } else {
    if (length(observedTimeIds) == 0L) {
      stop(
        "There are no observed timeId values, so the time axis of a ",
        sQuote(timePart), " sequence cannot be determined.",
        call. = FALSE
      )
    }
    timeIds <- seq(min(observedTimeIds), max(observedTimeIds))
  }

  timeIds <- sort(timeIds)
  unitsStart <- timeIds * timeInterval
  unitsEnd <- (timeIds + 1L) * timeInterval - 1L
  timeMap <- data.frame(
    timeId = as.integer(timeIds),
    timeIndex = seq_along(timeIds),
    startDay = NA_integer_,
    endDay = NA_integer_,
    unitsBeforeIndexStart = as.integer(unitsStart),
    unitsBeforeIndexEnd = as.integer(unitsEnd),
    timePart = timePart,
    timeInterval = timeInterval,
    stringsAsFactors = FALSE
  )
  if (exact) {
    # One unit is one day, so the unit counts are day counts before the index
    # date and can be reported as day offsets, clipped to the requested window.
    timeMap$startDay <- as.integer(pmax(-unitsEnd, sequenceStartDay))
    timeMap$endDay <- as.integer(pmin(-unitsStart, sequenceEndDay))
  }
  attr(timeMap, "timeAxis") <- list(
    type = "sequence",
    timePart = timePart,
    timeInterval = timeInterval,
    sequenceStartDay = sequenceStartDay,
    sequenceEndDay = sequenceEndDay,
    exact = exact,
    length = nrow(timeMap),
    # How timeIndex was assigned, so downstream code never has to guess which
    # end of the time dimension is nearest the index date.
    timeIndexOrder = "timeId",
    firstTimeId = timeMap$timeId[[1]],
    lastTimeId = timeMap$timeId[[nrow(timeMap)]]
  )
  timeMap
}

# Build the time axis of a temporal window extraction, covering every requested
# window in timeRef so that a window without data becomes an all-zero slice.
.windowTimeMap <- function(timeRef) {
  required <- c("timeId", "startDay", "endDay")
  absent <- required[!required %in% names(timeRef)]
  if (length(absent) > 0) {
    stop(
      "The timeRef table of a temporal window extraction must have the ",
      "columns ", paste(required, collapse = ", "), ". Missing: ",
      paste(absent, collapse = ", "), ".",
      call. = FALSE
    )
  }
  if (nrow(timeRef) == 0L) {
    stop(
      "The timeRef table is empty, so the time axis cannot be built.",
      call. = FALSE
    )
  }
  if (anyDuplicated(timeRef$timeId) > 0) {
    stop("Each timeId in timeRef must be unique.", call. = FALSE)
  }
  timeMap <- timeRef %>%
    dplyr::arrange(.data$startDay, .data$endDay, .data$timeId)
  timeMap$timeIndex <- seq_len(nrow(timeMap))
  timeMap <- timeMap[, c(
    "timeId",
    "timeIndex",
    setdiff(names(timeMap), c("timeId", "timeIndex"))
  )]
  attr(timeMap, "timeAxis") <- list(
    type = "window",
    length = nrow(timeMap),
    # Window timeId values are assigned in the order the settings list the
    # windows, which need not be chronological, so the axis is ordered by
    # startDay instead.
    timeIndexOrder = "startDay"
  )
  timeMap
}

# Dispatch on the shape of timeRef rather than on the covariate settings, so the
# axis always matches the data that was actually extracted.
.createTimeMap <- function(timeRef, observedTimeIds, timeAxis = "settings") {
  timeRef <- as.data.frame(timeRef, stringsAsFactors = FALSE)
  if ("timeId" %in% names(timeRef)) {
    return(.windowTimeMap(timeRef))
  }
  if ("timePart" %in% names(timeRef)) {
    return(.sequenceTimeMap(timeRef, observedTimeIds, timeAxis))
  }
  stop(
    "The timeRef table has none of the expected columns. Temporal window ",
    "extractions have timeId, startDay, and endDay; temporal sequence ",
    "extractions have timePart, timeInterval, sequenceStartDay, and ",
    "sequenceEndDay. Found: ",
    paste(names(timeRef), collapse = ", "), ".",
    call. = FALSE
  )
}

# A one-line human-readable description of the time axis, for the log.
.describeTimeAxis <- function(timeAxis) {
  if (identical(timeAxis$type, "sequence")) {
    return(paste0(
      timeAxis$length, " sequence position(s) of ", timeAxis$timeInterval, " ",
      timeAxis$timePart, "(s), covering days ", timeAxis$sequenceStartDay,
      " to ", timeAxis$sequenceEndDay, " relative to the index date",
      if (isTRUE(timeAxis$exact)) {
        ""
      } else {
        " (positions spanned by the observed data; calendar boundaries make a settings-only axis approximate)"
      },
      ". Ordered by timeId, so time index 1 is timeId ", timeAxis$firstTimeId,
      " and time index ", timeAxis$length, " is timeId ", timeAxis$lastTimeId
    ))
  }
  paste0(
    timeAxis$length,
    " time window(s), ordered by startDay so time index 1 is the oldest window"
  )
}


#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

.fillSparseArrayBatch <- function(batch, buffer) {
  if (nrow(batch) == 0L) {
    return(invisible(NULL))
  }
  values <- as.numeric(batch$covariateValue)
  if (any(!is.finite(values))) {
    stop("Covariate values must be finite and non-missing.", call. = FALSE)
  }
  index <- buffer$position + seq_len(nrow(batch))
  buffer$i[index] <- as.integer(batch$matrixRowId)
  buffer$j[index] <- as.integer(batch$timeIndex)
  buffer$k[index] <- as.integer(batch$columnId)
  buffer$x[index] <- values
  buffer$position <- buffer$position + nrow(batch)
  invisible(NULL)
}

#' Create a three-dimensional sparse array from saved FeatureExtraction data
#'
#' Maps observed row and covariate identifiers to deterministic one-based
#' indices, maps every position of the extracted time axis to a one-based time
#' index, then transfers the mapped coordinates from Andromeda in batches into a
#' `slam::simple_sparse_array` with dimensions patient by time by covariate. That
#' dimension order matches the `(samples, timesteps, features)` layout expected
#' by sequence models.
#'
#' The time axis is read from the saved `timeRef` table, which FeatureExtraction
#' shapes differently per settings family:
#'
#' * Temporal sequence settings, the main path of this package, store the
#'   parameterization `timePart`, `timeInterval`, `sequenceStartDay`, and
#'   `sequenceEndDay`. The server computes
#'   `timeId = FLOOR(DATEDIFF(timePart, eventDate, indexDate) / timeInterval)`,
#'   so the axis is the contiguous run of those interval positions. With
#'   `timePart = "day"` the axis follows from the settings alone and is
#'   identical across cohorts and databases; with `"month"` or `"year"` the
#'   `DATEDIFF` count depends on calendar boundaries, so the axis spans the
#'   observed positions instead of padding the array with positions that cannot
#'   hold data.
#' * Temporal window settings store one row per requested window, with
#'   `timeId`, `startDay`, and `endDay`. The axis covers every requested window,
#'   so a window without observed data becomes an all-zero slice.
#'
#' The `timeId` values are kept as FeatureExtraction assigned them rather than
#' reordered to a common direction, and `result$timeAxis$timeIndexOrder` records
#' which rule was used. Sequence positions are ordered by `timeId`, so for a
#' lookback window `timeIndex` 1 is the interval nearest the index date; windows
#' are ordered by `startDay`, so `timeIndex` 1 is the oldest window. Reverse the
#' second array dimension downstream if a model needs oldest-to-newest input.
#'
#' Only observed row and covariate identifiers are mapped. Duplicate
#' `(rowId, timeId, covariateId)` coordinates are summed.
#'
#' Covariates from non-temporal analyses, such as demographics, are returned by
#' FeatureExtraction with a missing `timeId` and have no place on the time axis.
#' They are an error by default; set `dropStaticCovariates = TRUE` to exclude
#' them and record them under `staticCovariateRef` in the result.
#'
#' @param outputFolder Folder containing the saved `covariateData` artifact.
#' @param batchSize Maximum number of mapped coordinates transferred per batch.
#' @param dropStaticCovariates Drop covariates that have no `timeId` instead of
#'   failing?
#'
#' @return Invisibly returns the path to `sparseArray.rds`.
createSparseArray <- function(outputFolder,
                              extraction = NULL,
                              timeAxis = c("observed", "settings"),
                              batchSize = 1e6,
                              dropStaticCovariates = FALSE) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertCount(batchSize, positive = TRUE)
  checkmate::assertFlag(dropStaticCovariates)
  timeAxis <- match.arg(timeAxis)
  covariateData <- .loadCovariateDataFrom(outputFolder, extraction)
  on.exit({
    if (Andromeda::isValidAndromeda(covariateData)) {
      try(Andromeda::close(covariateData), silent = TRUE)
    }
  }, add = TRUE)
  if (FeatureExtraction::isAggregatedCovariateData(covariateData)) {
    stop("Aggregated CovariateData is not supported.", call. = FALSE)
  }
  # Both temporal sequence and temporal window extractions carry a timeId
  # column, which is what isTemporalCovariateData() tests.
  if (!FeatureExtraction::isTemporalCovariateData(covariateData)) {
    stop(
      "CovariateData without a timeId is not supported. Re-run the feature ",
      "stage with temporal sequence settings, see ",
      "FeatureExtraction::createTemporalSequenceCovariateSettings().",
      call. = FALSE
    )
  }
  if (!"timeRef" %in% names(covariateData)) {
    stop(
      "The saved covariateData has no timeRef table, so the time axis cannot ",
      "be built.",
      call. = FALSE
    )
  }

  staticCovariateRef <- NULL
  temporalCovariates <- covariateData$covariates
  staticCovariateIds <- covariateData$covariates %>%
    dplyr::filter(is.na(.data$timeId)) %>%
    dplyr::distinct(.data$covariateId) %>%
    dplyr::arrange(.data$covariateId) %>%
    dplyr::collect()
  if (nrow(staticCovariateIds) > 0) {
    if (!dropStaticCovariates) {
      stop(
        "Found ",
        nrow(staticCovariateIds),
        " covariate(s) without a timeId, for example covariateId ",
        paste(utils::head(staticCovariateIds$covariateId, 5), collapse = ", "),
        ". Non-temporal analyses such as demographics cannot be placed on the ",
        "time axis. Remove them from the covariate settings, or set ",
        "dropStaticCovariates = TRUE.",
        call. = FALSE
      )
    }
    ParallelLogger::logWarn(
      "Dropping ",
      nrow(staticCovariateIds),
      " covariate(s) without a timeId from the sparse array."
    )
    staticCovariateRef <- staticCovariateIds %>%
      dplyr::inner_join(
        covariateData$covariateRef %>% dplyr::collect(),
        by = "covariateId"
      )
    temporalCovariates <- temporalCovariates %>%
      dplyr::filter(!is.na(.data$timeId))
  }

  rowMap <- temporalCovariates %>%
    dplyr::distinct(.data$rowId) %>%
    dplyr::arrange(.data$rowId) %>%
    dplyr::collect()
  if (nrow(rowMap) == 0L) {
    stop("There are no temporal covariates to map.", call. = FALSE)
  }
  if (nrow(rowMap) > .Machine$integer.max) {
    stop("There are too many rows for a sparse array.", call. = FALSE)
  }
  rowMap$matrixRowId <- seq_len(nrow(rowMap))
  labels <- data.frame(
    rowId = rowMap$matrixRowId,
    originalRowId = rowMap$rowId
  )
  covariateData$rowMap <- rowMap

  covariateMap <- temporalCovariates %>%
    dplyr::distinct(.data$covariateId) %>%
    dplyr::arrange(.data$covariateId) %>%
    dplyr::collect()
  if (nrow(covariateMap) > .Machine$integer.max) {
    stop("There are too many covariates for a sparse array.", call. = FALSE)
  }
  covariateMap$columnId <- seq_len(nrow(covariateMap))
  covariateData$covariateMap <- covariateMap

  # The number of distinct timeId values is bounded by the length of the time
  # axis, so collecting them is cheap even for very large extractions.
  observedTimeIds <- temporalCovariates %>%
    dplyr::distinct(.data$timeId) %>%
    dplyr::arrange(.data$timeId) %>%
    dplyr::collect()
  timeMap <- .createTimeMap(
    timeRef = covariateData$timeRef %>% dplyr::collect(),
    observedTimeIds = observedTimeIds$timeId,
    timeAxis = timeAxis
  )
  # Kept apart from the timeAxis argument above, which selects how the axis is
  # bounded; this is the description of the axis that was built.
  timeAxisInfo <- attr(timeMap, "timeAxis")
  unmappedTimeIds <- setdiff(
    as.integer(observedTimeIds$timeId),
    as.integer(timeMap$timeId)
  )
  if (length(unmappedTimeIds) > 0) {
    stop(
      "Found ",
      length(unmappedTimeIds),
      " observed timeId(s) that are missing from the time axis, for example ",
      paste(utils::head(unmappedTimeIds, 5), collapse = ", "),
      ".",
      call. = FALSE
    )
  }
  covariateData$timeMap <- timeMap[, c("timeId", "timeIndex")]

  covariateRef <- covariateData$covariateMap %>%
    dplyr::inner_join(covariateData$covariateRef, by = "covariateId") %>%
    dplyr::arrange(.data$columnId) %>%
    dplyr::collect()
  if (nrow(covariateRef) != nrow(covariateMap)) {
    stop("Each observed covariateId must have one reference row.", call. = FALSE)
  }
  covariateRef$columnId <- NULL

  coordinates <- temporalCovariates %>%
    dplyr::inner_join(covariateData$rowMap, by = "rowId") %>%
    dplyr::inner_join(covariateData$timeMap, by = "timeId") %>%
    dplyr::inner_join(covariateData$covariateMap, by = "covariateId") %>%
    dplyr::group_by(.data$matrixRowId, .data$timeIndex, .data$columnId) %>%
    dplyr::summarise(
      covariateValue = sum(.data$covariateValue, na.rm = TRUE),
      .groups = "drop"
    )
  coordinateCount <- coordinates %>%
    dplyr::summarise(n = dplyr::n()) %>%
    dplyr::collect()
  nCoordinates <- as.numeric(coordinateCount$n[[1]])
  if (nCoordinates > .Machine$integer.max) {
    stop("There are too many coordinates for a sparse array.", call. = FALSE)
  }
  ParallelLogger::logInfo("Time axis: ", .describeTimeAxis(timeAxisInfo))
  ParallelLogger::logInfo(
    "Sparse array dimensions: ",
    nrow(rowMap), " patients x ",
    nrow(timeMap), " time positions x ",
    nrow(covariateMap), " covariates"
  )
  ParallelLogger::logInfo(
    "Estimated peak sparse-array memory: ",
    round(nCoordinates * 40 / 1024^3, 1),
    " GB"
  )
  # Sort into the linear order of the array so that identical input produces an
  # identical saved object.
  coordinates <- coordinates %>%
    dplyr::arrange(.data$columnId, .data$timeIndex, .data$matrixRowId)

  buffer <- new.env(parent = emptyenv())
  buffer$i <- integer(nCoordinates)
  buffer$j <- integer(nCoordinates)
  buffer$k <- integer(nCoordinates)
  buffer$x <- numeric(nCoordinates)
  buffer$position <- 0
  if (nCoordinates != 0) {
    Andromeda::batchApply(
      coordinates,
      .fillSparseArrayBatch,
      buffer = buffer,
      batchSize = batchSize,
      progressBar = FALSE,
      safe = FALSE
    )
  }
  if (buffer$position != nCoordinates) {
    stop(
      "Transferred ", buffer$position, " of ", nCoordinates, " coordinates.",
      call. = FALSE
    )
  }
  dataArray <- slam::simple_sparse_array(
    i = matrix(c(buffer$i, buffer$j, buffer$k), ncol = 3L),
    v = buffer$x,
    dim = c(nrow(rowMap), nrow(timeMap), nrow(covariateMap)),
    dimnames = NULL
  )
  attr(timeMap, "timeAxis") <- NULL
  result <- list(
    dataArray = dataArray,
    labels = labels,
    covariateRef = as.data.frame(covariateRef),
    covariateMap = as.data.frame(covariateMap),
    timeMap = as.data.frame(timeMap),
    timeAxis = timeAxisInfo
  )
  if (!is.null(staticCovariateRef)) {
    result$staticCovariateRef <- as.data.frame(staticCovariateRef)
  }

  outputFile <- file.path(outputFolder, "sparseArray.rds")
  stagingFile <- tempfile("sparseArray-", tmpdir = outputFolder)
  on.exit(unlink(stagingFile, force = TRUE), add = TRUE)
  saveRDS(result, stagingFile, compress = FALSE)
  if (file.exists(outputFile)) {
    unlink(outputFile, force = TRUE)
  }
  if (!file.rename(stagingFile, outputFile)) {
    stop("Failed to save sparseArray.rds.", call. = FALSE)
  }
  invisible(outputFile)
}
