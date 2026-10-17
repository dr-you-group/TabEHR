# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The arguments of PatientLevelPrediction::createStudyPopulationSettings() as of
# PLP 6.0.0. Note restrictTarToCohortEnd, not restrictTarDateToCohortEnd.
.populationSettingsArgs <- c(
  "binary",
  "includeAllOutcomes",
  "firstExposureOnly",
  "washoutPeriod",
  "removeSubjectsWithPriorOutcome",
  "priorOutcomeLookback",
  "requireTimeAtRisk",
  "minTimeAtRisk",
  "riskWindowStart",
  "startAnchor",
  "riskWindowEnd",
  "endAnchor",
  "restrictTarToCohortEnd"
)

#' @noRd
.assertPopulationSettingsArgs <- function(args, context) {
  unknown <- setdiff(names(args), .populationSettingsArgs)
  if (length(unknown) > 0) {
    stop(
      context, " has arguments that createStudyPopulationSettings() does not ",
      "accept: ", paste(unknown, collapse = ", "), ".",
      call. = FALSE
    )
  }
  invisible(NULL)
}

#' @noRd
.buildPopulationSettings <- function(args) {
  args <- args[names(args) %in% .populationSettingsArgs]
  do.call(PatientLevelPrediction::createStudyPopulationSettings, args)
}

# Which FeatureExtraction settings family an object belongs to. Temporal
# sequence settings carry temporalSequence = TRUE, temporal window settings
# carry temporal = TRUE.
#' @noRd
.isTemporalSequenceSettings <- function(covariateSettings) {
  isTRUE(covariateSettings$temporalSequence)
}

#' @noRd
.isTemporalWindowSettings <- function(covariateSettings) {
  isTRUE(covariateSettings$temporal)
}

#' Save the study settings
#'
#' Writes one JSON file holding, for every target and outcome pair, which
#' covariate settings the features are extracted with and which study population
#' settings the labels are built with.
#'
#' Covariate settings are stored once under a name and referenced by
#' `covariateSettingsId`, because extracting features is expensive and many
#' pairs share one extraction. [studyExtractionGroups()] turns the pairs back
#' into the distinct `targetId` and `covariateSettingsId` combinations that
#' [createPlpData()] has to run.
#'
#' @param covariateSettings A named list of flat FeatureExtraction argument
#'   lists, as [saveCovariateSettings()] writes them. The names are the
#'   `covariateSettingsId` values the pairs refer to.
#' @param defaultPopulationSettings A named list of
#'   [PatientLevelPrediction::createStudyPopulationSettings()] arguments, used
#'   for anything a pair leaves out.
#' @param settings A list of named lists, each with `taskId`, `targetId`,
#'   `outcomeId`, `covariateSettingsId`, and a `populationSettings` list of the
#'   arguments that differ from `defaultPopulationSettings`. An optional `note`
#'   is kept as documentation. `taskId` is the key, not the target and outcome
#'   pair, because one outcome cohort can serve several tasks: 7-day and 30-day
#'   mortality share a death cohort and differ only in their risk window.
#' @param file Destination JSON file.
#'
#' @return Invisibly returns `file`.
#' @export
saveStudySettings <- function(covariateSettings,
                              defaultPopulationSettings,
                              settings,
                              file) {
  checkmate::assertList(covariateSettings, names = "named", min.len = 1)
  checkmate::assertList(defaultPopulationSettings, names = "named")
  checkmate::assertList(settings, min.len = 1)
  .assertPopulationSettingsArgs(
    defaultPopulationSettings, "defaultPopulationSettings"
  )
  # Constructing each object validates it, which is cheaper to find out here
  # than halfway through an extraction.
  for (id in names(covariateSettings)) {
    SparseArray::buildCovariateSettings(
      covariateSettings[[id]], paste0("covariateSettings$", id)
    )
  }
  .buildPopulationSettings(defaultPopulationSettings)

  for (i in seq_along(settings)) {
    entry <- settings[[i]]
    context <- paste0("settings[[", i, "]]")
    checkmate::assertList(entry, names = "named")
    required <- c("taskId", "targetId", "outcomeId", "covariateSettingsId")
    absent <- required[!required %in% names(entry)]
    if (length(absent) > 0) {
      stop(context, " is missing ", paste(absent, collapse = ", "), ".",
           call. = FALSE)
    }
    if (!entry$covariateSettingsId %in% names(covariateSettings)) {
      stop(context, " refers to an unknown covariateSettingsId: ",
           entry$covariateSettingsId, ".", call. = FALSE)
    }
    unknown <- setdiff(names(entry),
                       c(required, "populationSettings", "note"))
    if (length(unknown) > 0) {
      stop(context, " has unexpected entries: ",
           paste(unknown, collapse = ", "), ".", call. = FALSE)
    }
    population <- entry$populationSettings
    if (!is.null(population)) {
      .assertPopulationSettingsArgs(population, paste0(context, "$populationSettings"))
      merged <- defaultPopulationSettings
      merged[names(population)] <- population
      .buildPopulationSettings(merged)
    }
  }
  keys <- vapply(settings, function(e) as.character(e$taskId), "")
  if (anyDuplicated(keys)) {
    stop("Duplicate taskId values: ",
         paste(unique(keys[duplicated(keys)]), collapse = ", "), ".",
         call. = FALSE)
  }

  dir.create(dirname(file), showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(
    list(
      covariateSettings = covariateSettings,
      defaultPopulationSettings = defaultPopulationSettings,
      settings = settings
    ),
    path = file,
    auto_unbox = TRUE,
    pretty = TRUE
  )
  invisible(file)
}

#' Load the study settings
#'
#' @param file JSON file written by [saveStudySettings()].
#'
#' @return A list with `covariateSettings`, `defaultPopulationSettings` and
#'   `settings`.
#' @export
loadStudySettings <- function(file) {
  checkmate::assertFileExists(file)
  spec <- jsonlite::fromJSON(file, simplifyDataFrame = FALSE,
                             simplifyVector = TRUE)
  required <- c("covariateSettings", "defaultPopulationSettings", "settings")
  absent <- required[!required %in% names(spec)]
  if (length(absent) > 0) {
    stop("The study settings file is missing ",
         paste(absent, collapse = ", "), ": ", file, call. = FALSE)
  }
  spec
}

#' Resolve the settings for one task
#'
#' @param spec The list returned by [loadStudySettings()].
#' @param taskId The task to resolve.
#'
#' @return A list with `taskId`, `targetId`, `outcomeId`, `covariateSettingsId`,
#'   the built `covariateSettings`, and the built `populationSettings`.
#' @export
resolveStudySettings <- function(spec, taskId) {
  match <- vapply(spec$settings, function(e) identical(
    as.character(e$taskId), as.character(taskId)), logical(1))
  if (!any(match)) {
    stop("No study settings for task ", taskId, ". Available: ",
         paste(vapply(spec$settings, function(e) as.character(e$taskId), ""),
               collapse = ", "), ".", call. = FALSE)
  }
  entry <- spec$settings[[which(match)[1]]]
  population <- spec$defaultPopulationSettings
  if (!is.null(entry$populationSettings)) {
    population[names(entry$populationSettings)] <- entry$populationSettings
  }
  list(
    taskId = entry$taskId,
    targetId = as.integer(entry$targetId),
    outcomeId = as.integer(entry$outcomeId),
    covariateSettingsId = entry$covariateSettingsId,
    covariateSettings = SparseArray::buildCovariateSettings(
      spec$covariateSettings[[entry$covariateSettingsId]],
      paste0("covariateSettings$", entry$covariateSettingsId)
    ),
    populationSettings = .buildPopulationSettings(population)
  )
}

#' The distinct feature extractions the study settings imply
#'
#' Collapses the target and outcome pairs onto the `targetId` and
#' `covariateSettingsId` combinations that actually have to be extracted, so a
#' covariate settings block shared by many outcomes is only extracted once.
#'
#' @param spec The list returned by [loadStudySettings()].
#'
#' @return A list of lists, each with `targetId`, `covariateSettingsId`, the
#'   `outcomeIds` that extraction serves, and the `taskIds` it serves. Both are
#'   needed: `createPlpData()` fetches outcomes, which are per outcome cohort,
#'   while `createOutcomeLabels()` labels per task, because two tasks can share
#'   an outcome cohort and differ only in their risk window.
#' @export
studyExtractionGroups <- function(spec) {
  targetIds <- vapply(spec$settings, function(e) as.integer(e$targetId), 1L)
  covariateIds <- vapply(spec$settings, function(e) e$covariateSettingsId, "")
  outcomeIds <- vapply(spec$settings, function(e) as.integer(e$outcomeId), 1L)
  taskIds <- vapply(spec$settings, function(e) as.character(e$taskId), "")
  keys <- paste(targetIds, covariateIds, sep = "\r")
  lapply(unique(keys), function(key) {
    rows <- keys == key
    list(
      targetId = targetIds[rows][1],
      covariateSettingsId = covariateIds[rows][1],
      outcomeIds = sort(unique(outcomeIds[rows])),
      taskIds = taskIds[rows]
    )
  })
}
