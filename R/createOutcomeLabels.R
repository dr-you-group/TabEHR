# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The covariate window as day offsets from the index date. Temporal sequence
# settings carry it directly; temporal window settings span their windows.
#' @noRd
.covariateWindowDays <- function(covariateSettings) {
  if (.isTemporalSequenceSettings(covariateSettings)) {
    return(c(start = as.integer(covariateSettings$sequenceStartDay),
             end = as.integer(covariateSettings$sequenceEndDay)))
  }
  c(start = as.integer(min(covariateSettings$temporalStartDays)),
    end = as.integer(max(covariateSettings$temporalEndDays)))
}

# The time at risk as day offsets from the index date. createStudyPopulation()
# applies this arithmetic internally but returns only its length, as
# timeAtRisk, so it is repeated here and then checked against that length.
#' @noRd
.timeAtRiskDays <- function(populationSettings, population) {
  start <- if (populationSettings$startAnchor == "cohort start") {
    rep(populationSettings$riskWindowStart, nrow(population))
  } else {
    populationSettings$riskWindowStart + population$daysToCohortEnd
  }
  end <- if (populationSettings$endAnchor == "cohort start") {
    rep(populationSettings$riskWindowEnd, nrow(population))
  } else {
    populationSettings$riskWindowEnd + population$daysToCohortEnd
  }
  end <- pmin(end, population$daysToObsEnd)
  if (isTRUE(populationSettings$restrictTarToCohortEnd)) {
    end <- pmin(end, population$daysToCohortEnd)
  }
  mismatch <- which(end - start + 1L != population$timeAtRisk)
  if (length(mismatch) > 0) {
    stop(
      "The recomputed time at risk disagrees with the one ",
      "createStudyPopulation() reported for ", length(mismatch), " row(s), ",
      "for example rowId ", population$rowId[mismatch[1]], ": ",
      end[mismatch[1]] - start[mismatch[1]] + 1L, " against ",
      population$timeAtRisk[mismatch[1]], ".",
      call. = FALSE
    )
  }
  list(start = start, end = end)
}

#' Create outcome labels from the saved extractions
#'
#' Calls [PatientLevelPrediction::createStudyPopulation()] once per task in the
#' study settings, with the population settings [resolveStudySettings()] looks
#' up for that task, and writes the labels in
#' long format. All of the inclusion and exclusion logic, the time at risk, and
#' the attrition table are PLP's; this function only resolves the per-pair
#' settings and reshapes the result.
#'
#' Each pair is labelled against the extraction its `covariateSettingsId` names,
#' so the labels carry the `rowId` of that extraction and join to its covariate
#' rows directly. `rowId` is one target cohort entry, not one subject, so a
#' subject with several index dates keeps one labelled row per index date.
#' `rowId` is only comparable inside one extraction, which is why every label
#' row also carries `extraction`, `subjectId` and the target cohort dates.
#'
#' An outcome left with no rows by its criteria contributes no label rows, which
#' is what `createStudyPopulation()` signals by returning `NULL`.
#'
#' The columns are:
#' \describe{
#'   \item{taskId}{Which prediction task the row describes. Two tasks can share
#'     an outcome cohort and differ only in their risk window, as 7-day and
#'     30-day mortality do, so this is the key, not `outcomeId`.}
#'   \item{extraction}{Which saved extraction the `rowId` belongs to.}
#'   \item{targetId, outcomeId, outcomeName}{The cohorts behind the task.}
#'   \item{rowId, subjectId}{The covariate row and the person it belongs to.}
#'   \item{targetCohortStartDate, targetCohortEndDate}{The target cohort entry.}
#'   \item{covariateStartDate, covariateEndDate}{The span the features were
#'     taken from, clipped at the start to the observation period, so a request
#'     for more history than a subject has reports what was actually available.}
#'   \item{tarStartDate, tarEndDate}{The time at risk, recomputed from the
#'     population settings and checked against the `timeAtRisk` PLP reported.}
#'   \item{outcomeLabel}{1 when the outcome occurred inside the risk window,
#'     0 otherwise. This is the label.}
#'   \item{outcomeCount}{PLP's count, which `binary = TRUE` caps at 1.}
#'   \item{outcomeStartDate, daysToEvent}{The first outcome occurrence inside
#'     the risk window, as a date and as an offset from the index date. Both are
#'     `NA` when `outcomeLabel` is 0.}
#'   \item{timeAtRisk, survivalTime}{The risk window length and the time to the
#'     event or to the end of the window.}
#' }
#'
#' @param outputFolder Folder holding the extractions saved by [createPlpData()],
#'   and where the label files are written.
#' @param studySettingsFile JSON file written by [saveStudySettings()].
#' @param cohortsToCreateFile CSV listing the cohorts, used to name the outcomes.
#' @param savePopulations Also save each `createStudyPopulation()` result as it
#'   came back, under `outputFolder/studyPopulation`? The CSV keeps the columns
#'   this package needs; the saved object additionally keeps `ageYear`,
#'   `gender`, `daysFromObsStart`, `daysToObsEnd` and the `metaData` attribute
#'   that carries the attrition table and the settings, which is what the rest
#'   of PatientLevelPrediction expects to be handed.
#'
#' @return Invisibly, a list with the `labels` and `attrition` data frames, and
#'   `populationFiles`, the saved study population objects.
#' @export
createOutcomeLabels <- function(outputFolder,
                                studySettingsFile = system.file(
                                  "settings",
                                  "studySettings.json",
                                  package = "TabEHR"
                                ),
                                cohortsToCreateFile = system.file(
                                  "settings",
                                  "CohortsToCreate.csv",
                                  package = "TabEHR"
                                ),
                                savePopulations = TRUE) {
  checkmate::assertString(outputFolder, min.chars = 1)
  checkmate::assertFlag(savePopulations)
  spec <- loadStudySettings(studySettingsFile)
  populationFolder <- file.path(outputFolder, "studyPopulation")
  if (savePopulations && !dir.exists(populationFolder)) {
    dir.create(populationFolder, recursive = TRUE)
  }

  outcomeNames <- character(0)
  if (nzchar(cohortsToCreateFile) && file.exists(cohortsToCreateFile)) {
    cohortsToCreate <- utils::read.csv(cohortsToCreateFile)
    outcomeNames <- stats::setNames(
      as.character(cohortsToCreate$atlasName),
      as.character(cohortsToCreate$cohortId)
    )
  }

  labels <- list()
  attrition <- list()
  for (group in studyExtractionGroups(spec)) {
    extraction <- basename(
      file.path(outputFolder, "plpData",
                paste0("target", group$targetId, "_",
                       group$covariateSettingsId))
    )
    folder <- file.path(outputFolder, "plpData", extraction)
    if (!dir.exists(folder)) {
      stop("Cannot find the extraction ", extraction,
           ". Run createPlpData() first.", call. = FALSE)
    }
    plpData <- PatientLevelPrediction::loadPlpData(folder)
    on.exit({
      if (Andromeda::isValidAndromeda(plpData$covariateData)) {
        try(Andromeda::close(plpData$covariateData), silent = TRUE)
      }
    }, add = TRUE)

    for (taskId in group$taskIds) {
      resolved <- resolveStudySettings(spec, taskId)
      outcomeId <- resolved$outcomeId
      key <- as.character(outcomeId)
      name <- if (key %in% names(outcomeNames)) outcomeNames[[key]] else key
      ParallelLogger::logInfo("Labelling task ", taskId, " (outcome ",
                              outcomeId, ", ", name, ") against ", extraction)
      population <- PatientLevelPrediction::createStudyPopulation(
        plpData = plpData,
        outcomeId = outcomeId,
        populationSettings = resolved$populationSettings
      )
      if (is.null(population) || nrow(population) == 0) {
        ParallelLogger::logWarn(
          "Task ", taskId, " has no rows left after the inclusion and ",
          "exclusion criteria."
        )
        next
      }
      # PLP reports the target cohort end and the outcome event as day offsets
      # from the index date, so the dates are recovered rather than re-queried.
      # daysToEvent is the first occurrence inside the risk window, and is NA
      # for a row without the outcome, which leaves outcomeStartDate NA too.
      if (savePopulations) {
        # saveRDS keeps the metaData attribute, so the object can be handed
        # straight back to PatientLevelPrediction.
        saveRDS(
          population,
          file.path(populationFolder, paste0(taskId, ".rds"))
        )
      }
      targetStart <- as.Date(population$cohortStartDate)
      covariateDays <- .covariateWindowDays(resolved$covariateSettings[[1]])
      tar <- .timeAtRiskDays(resolved$populationSettings, population)
      labels[[taskId]] <- data.frame(
        taskId = taskId,
        extraction = extraction,
        targetId = group$targetId,
        outcomeId = outcomeId,
        outcomeName = name,
        rowId = population$rowId,
        subjectId = population$subjectId,
        targetCohortStartDate = targetStart,
        targetCohortEndDate = targetStart + population$daysToCohortEnd,
        covariateStartDate = targetStart +
          pmax(covariateDays[["start"]], -population$daysFromObsStart),
        covariateEndDate = targetStart + covariateDays[["end"]],
        tarStartDate = targetStart + tar$start,
        tarEndDate = targetStart + tar$end,
        outcomeLabel = as.integer(population$outcomeCount > 0),
        outcomeCount = population$outcomeCount,
        outcomeStartDate = targetStart + population$daysToEvent,
        daysToEvent = population$daysToEvent,
        timeAtRisk = population$timeAtRisk,
        survivalTime = population$survivalTime,
        stringsAsFactors = FALSE
      )
      rows <- attr(population, "metaData")$attrition
      if (!is.null(rows)) {
        rows$taskId <- taskId
        rows$extraction <- extraction
        rows$targetId <- group$targetId
        rows$outcomeName <- name
        attrition[[taskId]] <- rows
      }
    }
  }

  if (length(labels) == 0) {
    stop("No outcome produced any labels.", call. = FALSE)
  }
  labels <- do.call(rbind, labels)
  rownames(labels) <- NULL
  if (length(attrition) > 0) {
    attrition <- do.call(rbind, attrition)
    rownames(attrition) <- NULL
  } else {
    attrition <- NULL
  }

  labelFile <- file.path(outputFolder, "outcomeLabels.csv")
  utils::write.csv(labels, labelFile, row.names = FALSE)
  ParallelLogger::logInfo("Wrote ", nrow(labels), " label rows for ",
                          length(unique(labels$taskId)), " tasks to ",
                          labelFile)
  if (!is.null(attrition)) {
    utils::write.csv(
      attrition,
      file.path(outputFolder, "outcomeLabelsAttrition.csv"),
      row.names = FALSE
    )
  }

  invisible(list(
    labels = labels,
    attrition = attrition,
    populationFiles = if (savePopulations) {
      list.files(populationFolder, pattern = "[.]rds$", full.names = TRUE)
    } else {
      character(0)
    }
  ))
}
