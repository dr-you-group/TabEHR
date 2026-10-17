# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' Assign the study population to the stages
#'
#' The assignment itself, without a database, so it can be tested and re-run.
#' Three things are pinned to make it reproducible:
#'
#' \itemize{
#'   \item the patient list is sorted before anything random happens, because a
#'     database returns rows in no particular order
#'   \item the sort is `method = "radix"`, because the default string collation
#'     depends on the locale
#'   \item `RNGkind()` is set explicitly, `sample.kind` included, because R
#'     changed the default sampling algorithm in 3.6.0 and a split must not
#'     depend on which default the container happens to have
#' }
#'
#' An external site has no split: every patient is marked `external` so the
#' later stages have one table to read.
#'
#' @param personIds Character vector of `person_id` values. They are character
#'   because a 19 digit id cannot be a double without losing its last digits.
#' @param analysisSettings An object of type `tabehrAnalysisSettings` as created
#'   by [createAnalysisSettings()].
#'
#' @return A data frame with `person_id`, `stage`, `split` and `split_seed`.
#' @export
assignPersonSplit <- function(personIds,
                              analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  personIds <- unique(as.character(personIds))
  if (length(personIds) == 0) {
    stop("The study population is empty, so there is nothing to split.",
         call. = FALSE)
  }
  settings <- analysisSettings$personSplitSettings

  if (identical(analysisSettings$siteRole, "external")) {
    return(data.frame(
      person_id = sort(personIds, method = "radix"),
      stage = "external",
      split = "",
      split_seed = settings$seed,
      stringsAsFactors = FALSE
    ))
  }

  ordered <- sort(personIds, method = "radix")
  n <- length(ordered)

  RNGkind(kind = "Mersenne-Twister", normal.kind = "Inversion",
          sample.kind = "Rejection")
  set.seed(settings$seed)
  permutation <- sample.int(n)

  trainEnd <- floor(n * settings$pretrainTrainFraction)
  validEnd <- floor(n * (settings$pretrainTrainFraction +
                           settings$pretrainValidFraction))
  if (trainEnd < 1 || validEnd <= trainEnd || validEnd >= n) {
    stop("The split fractions leave an empty group for ", n, " patient(s): ",
         "train ", trainEnd, ", valid ", validEnd - trainEnd,
         ", downstream ", n - validEnd, ".", call. = FALSE)
  }

  stage <- character(n)
  split <- character(n)
  stage[permutation[seq_len(trainEnd)]] <- "pretrain"
  split[permutation[seq_len(trainEnd)]] <- "train"
  stage[permutation[(trainEnd + 1):validEnd]] <- "pretrain"
  split[permutation[(trainEnd + 1):validEnd]] <- "valid"
  stage[permutation[(validEnd + 1):n]] <- "downstream"
  split[permutation[(validEnd + 1):n]] <- ""

  data.frame(
    person_id = ordered,
    stage = stage,
    split = split,
    split_seed = settings$seed,
    stringsAsFactors = FALSE
  )
}

#' Summarise a split
#'
#' @param personSplit A data frame as [assignPersonSplit()] returns.
#'
#' @return A data frame with one row per group, the total, and the count of
#'   patients that ended up in two groups, which must be zero.
#' @export
summarisePersonSplit <- function(personSplit) {
  groups <- stats::aggregate(
    list(n_person = personSplit$person_id),
    by = list(stage = personSplit$stage, split = personSplit$split),
    FUN = length
  )
  groups <- groups[order(groups$stage, groups$split), ]
  total <- sum(groups$n_person)
  groups$fraction <- round(groups$n_person / total, 6)
  rbind(
    groups,
    data.frame(stage = "TOTAL", split = "", n_person = total, fraction = 1),
    data.frame(stage = "CHECK_person_in_two_groups", split = "",
               n_person = sum(duplicated(personSplit$person_id)),
               fraction = NA_real_)
  )
}

#' Split the study population into pretraining and downstream patients
#'
#' Made once, and then used by everything: pretraining, the SparseArray stages,
#' and the later Python stages all read `person_split.csv`. The downstream
#' patients are never pretrained on. Their own train, validation and test split
#' is out of scope here and happens later, per training seed.
#'
#' Writes `person_split.csv` and `split_summary.csv`, loads the split into the
#' `person_split` table, and derives `downstream_person`, the table the
#' SparseArray target cohort is restricted with.
#'
#' @template databaseArgs
#' @template analysisArgs
#'
#' @return Invisibly, the split as a data frame.
#' @export
createPersonSplit <- function(connectionDetails,
                              cohortDatabaseSchema,
                              tablePrefix = "tabehr_",
                              tempEmulationSchema = NULL,
                              outputFolder,
                              analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(outputFolder, min.chars = 1)
  .ensureFolder(outputFolder)
  tableNames <- getTabehrTableNames(tablePrefix)

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))
  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)

  patients <- .queryTabehrSql(
    connection, "ExportStudyPopulation.sql",
    tempEmulationSchema = tempEmulationSchema,
    study_population_table = qualified(tableNames$studyPopulation),
    snakeCaseToCamelCase = FALSE
  )
  patients <- .assertCharacterIds(patients, "person_id")

  personSplit <- assignPersonSplit(patients$person_id, analysisSettings)
  ParallelLogger::logInfo("Split ", nrow(personSplit), " patient(s) with seed ",
                          analysisSettings$personSplitSettings$seed)
  writeTabehrCsv(personSplit, file.path(outputFolder, "person_split.csv"))
  writeTabehrCsv(summarisePersonSplit(personSplit),
                 file.path(outputFolder, "split_summary.csv"))

  # Sent as text and cast to BIGINT in SQL, so no id is rounded on the way in.
  .insertAsText(connection, cohortDatabaseSchema, tableNames$staging,
                personSplit)
  .executeTabehrSql(
    connection, "PersonSplitTable.sql",
    tempEmulationSchema = tempEmulationSchema,
    person_split_table = qualified(tableNames$personSplit),
    staging_table = qualified(tableNames$staging)
  )
  .dropTableIfExists(connection, cohortDatabaseSchema, tableNames$staging,
                     tempEmulationSchema)
  .executeTabehrSql(
    connection, "DownstreamPerson.sql",
    tempEmulationSchema = tempEmulationSchema,
    downstream_person_table = qualified(tableNames$downstreamPerson),
    person_split_table = qualified(tableNames$personSplit),
    downstream_stage = .downstreamStage(analysisSettings)
  )

  invisible(personSplit)
}
