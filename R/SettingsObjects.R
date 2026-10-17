# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

# The analysis settings, as HADES packages carry them: one create*Settings()
# function per group of arguments, validated where it is constructed, and one
# container that can be written to and read from JSON so a run can be
# reproduced. Nothing site specific lives here; the schemas, the connection and
# the output folder are arguments of execute(), as in every other HADES study
# package.

#' Settings for the record preprocessing
#'
#' The defaults reproduce `create_trajectory.py`, apart from the measurement
#' decisions described below, which follow FeatureExtraction so the two sides of
#' the project can be matched up.
#'
#' @param dateMin Earliest record date to keep.
#' @param dateMax Latest record date to keep. The original compares the
#'   datetime as a string, so a time of day on this date is excluded; the SQL
#'   reproduces that by comparing against midnight.
#' @param adultAgeMin Keep a record only from this age onwards, computed per
#'   record as `YEAR(record date) - year_of_birth`.
#' @param minConceptUnitCount A (measurement concept, unit) pair needs at least
#'   this many numeric records before its values are binned.
#' @param quantileCount Number of measurement bins, so `quantileCount + 1`
#'   boundaries.
#' @param quantileMethod `"rank"` reproduces the pandas interpolation with
#'   `ROW_NUMBER` arithmetic, which SqlRender translates on every dialect.
#'   `"percentileCont"` uses `PERCENTILE_CONT` instead, which SqlRender passes
#'   through untranslated.
#' @param measurementTieBreakColumn Column that breaks the tie when one
#'   measurement per hour is kept, where pandas takes the first row in file
#'   order. `""` orders by the datetime alone, which is not deterministic.
#'
#' The concept filter is not a setting: it is `concept_id <> 0` and nothing
#' else, which is exactly what FeatureExtraction's `DomainConcept.sql` applies,
#' so that `allrecords` and `featureExtractionLong` admit the same concepts. The
#' measurement value comes from `value_as_number`, the column
#' `MeasurementValue.sql` reads, and the measurement unit is grouped by
#' `unit_concept_id`, which is what the FeatureExtraction covariate id carries.
#'
#' @return An object of class `tabehrPreprocessSettings`.
#' @export
createPreprocessSettings <- function(dateMin = "1900-01-01",
                                     dateMax = "2260-12-31",
                                     adultAgeMin = 18,
                                     minConceptUnitCount = 10,
                                     quantileCount = 10,
                                     quantileMethod = "rank",
                                     measurementTieBreakColumn = "measurement_id") {
  checkmate::assertString(dateMin, pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  checkmate::assertString(dateMax, pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  checkmate::assertInt(adultAgeMin, lower = 0)
  checkmate::assertInt(minConceptUnitCount, lower = 1)
  checkmate::assertInt(quantileCount, lower = 1)
  checkmate::assertChoice(quantileMethod, c("rank", "percentileCont"))
  checkmate::assertString(measurementTieBreakColumn)

  # Coerced so the settings survive a JSON round trip unchanged: jsonlite reads
  # a whole number back as an integer, and these are doubles here.
  settings <- list(
    dateMin = dateMin,
    dateMax = dateMax,
    adultAgeMin = as.numeric(adultAgeMin),
    minConceptUnitCount = as.numeric(minConceptUnitCount),
    quantileCount = as.numeric(quantileCount),
    quantileMethod = quantileMethod,
    measurementTieBreakColumn = measurementTieBreakColumn
  )
  class(settings) <- "tabehrPreprocessSettings"
  settings
}

#' Settings for the study population
#'
#' The three criteria of the study, all of which must hold. They are applied in
#' the order adult, qualifying admission, record count, which is the order the
#' flow table reports.
#'
#' @param minRecordCount Minimum number of de-duplicated records per patient,
#'   counted after the preprocessing.
#' @param inpatientConceptIds Visit concepts that count as an admission.
#' @param includeDescendantVisitConcepts Also count their descendants, as the
#'   SparseArray target cohort does.
#' @param minAdmissionLengthOfStay Length of stay in days that an admission
#'   must reach, as `DATEDIFF(DAY, visit_start_date, visit_end_date)`.
#' @param lengthOfStayOperator `">="` matches MedRep `labeling.py`. `">"` is the
#'   strict reading of the paper sentence "more than 2 days".
#'
#' @return An object of class `tabehrPopulationSettings`.
#' @export
createPopulationSettings <- function(minRecordCount = 10,
                                     inpatientConceptIds = c(9201, 262),
                                     includeDescendantVisitConcepts = TRUE,
                                     minAdmissionLengthOfStay = 2,
                                     lengthOfStayOperator = ">=") {
  checkmate::assertInt(minRecordCount, lower = 1)
  checkmate::assertNumeric(inpatientConceptIds, min.len = 1, any.missing = FALSE)
  checkmate::assertFlag(includeDescendantVisitConcepts)
  checkmate::assertInt(minAdmissionLengthOfStay, lower = 0)
  checkmate::assertChoice(lengthOfStayOperator, c(">=", ">"))

  settings <- list(
    minRecordCount = as.numeric(minRecordCount),
    inpatientConceptIds = as.numeric(inpatientConceptIds),
    includeDescendantVisitConcepts = includeDescendantVisitConcepts,
    minAdmissionLengthOfStay = as.numeric(minAdmissionLengthOfStay),
    lengthOfStayOperator = lengthOfStayOperator
  )
  class(settings) <- "tabehrPopulationSettings"
  settings
}

#' Settings for the patient split
#'
#' One split, made once, by patient. The downstream group is never pretrained
#' on; its own train, validation and test split happens later, per training
#' seed, outside this package.
#'
#' @param seed The only seed this package uses.
#' @param pretrainTrainFraction Fraction of patients used to pretrain.
#' @param pretrainValidFraction Fraction held out of pretraining as its
#'   validation set.
#' @param downstreamFraction Fraction reserved for the downstream tasks.
#'
#' @return An object of class `tabehrPersonSplitSettings`.
#' @export
createPersonSplitSettings <- function(seed = 50,
                                      pretrainTrainFraction = 0.70,
                                      pretrainValidFraction = 0.15,
                                      downstreamFraction = 0.15) {
  checkmate::assertInt(seed)
  fractions <- c(pretrainTrainFraction, pretrainValidFraction,
                 downstreamFraction)
  checkmate::assertNumeric(fractions, lower = 0, upper = 1, any.missing = FALSE)
  if (any(fractions <= 0) || abs(sum(fractions) - 1) > 1e-9) {
    stop("The three fractions must be positive and sum to 1, not ",
         paste(fractions, collapse = " + "), " = ", sum(fractions), ".",
         call. = FALSE)
  }

  settings <- list(
    seed = as.numeric(seed),
    pretrainTrainFraction = as.numeric(pretrainTrainFraction),
    pretrainValidFraction = as.numeric(pretrainValidFraction),
    downstreamFraction = as.numeric(downstreamFraction)
  )
  class(settings) <- "tabehrPersonSplitSettings"
  settings
}

#' Settings for the measurement quantiles
#'
#' @param basis Which patients the boundaries are computed from. `"all"` is
#'   the default and is what MedRep does: it computes the quantiles before it
#'   splits the patients, so the basis and the rows being binned are the same
#'   set, which is also why the top bin cannot occur and the token space stays
#'   `_0` to `_9`. `"pretrain"` restricts the basis to the pretraining
#'   patients, which keeps the downstream value distribution out of the bins but
#'   does let the top bin occur. `"file"` applies a table computed elsewhere.
#' @param quantileFile The table to apply when `basis` is `"file"`, normally
#'   another site's `meas_quantiles.csv`. MedRep recomputes per site rather than
#'   sharing one table, which is the default here too.
#'
#' @return An object of class `tabehrQuantileSettings`.
#' @export
createQuantileSettings <- function(basis = "all",
                                   quantileFile = NULL) {
  checkmate::assertChoice(basis, c("pretrain", "all", "file"))
  if (identical(basis, "file")) {
    checkmate::assertString(quantileFile, min.chars = 1)
  } else {
    checkmate::assertString(quantileFile, null.ok = TRUE)
  }

  settings <- list(basis = basis, quantileFile = quantileFile)
  class(settings) <- "tabehrQuantileSettings"
  settings
}

#' Settings for the patient sample
#'
#' Every stage is meant to be run on a small sample first.
#'
#' @param samplePersonCount Number of patients to keep, or `NULL` for all of
#'   them. The sample is the first ids in ascending order, so it is
#'   reproducible; the MIMIC person_id is a hash, which makes that an arbitrary
#'   but fixed selection.
#'
#' @return An object of class `tabehrPersonSampleSettings`.
#' @export
createPersonSampleSettings <- function(samplePersonCount = NULL) {
  checkmate::assertInt(samplePersonCount, lower = 1, null.ok = TRUE)
  settings <- list(samplePersonCount = if (is.null(samplePersonCount)) NULL else as.numeric(samplePersonCount))
  class(settings) <- "tabehrPersonSampleSettings"
  settings
}

#' Combine the settings of one analysis
#'
#' @param preprocessSettings From [createPreprocessSettings()].
#' @param populationSettings From [createPopulationSettings()].
#' @param personSplitSettings From [createPersonSplitSettings()].
#' @param allRecordsSettings From [createAllRecordsSettings()].
#' @param quantileSettings From [createQuantileSettings()].
#' @param personSampleSettings From [createPersonSampleSettings()].
#' @param siteRole `"primary"` runs the whole analysis including the split.
#'   `"external"` marks every patient `external` and makes no split. Its
#'   quantile table is its own by default, as MedRep computes one per site; set
#'   `createQuantileSettings(basis = "file")` to apply another site's instead.
#'
#' @return An object of class `tabehrAnalysisSettings`.
#' @export
createAnalysisSettings <- function(preprocessSettings = createPreprocessSettings(),
                                   populationSettings = createPopulationSettings(),
                                   personSplitSettings = createPersonSplitSettings(),
                                   allRecordsSettings = createAllRecordsSettings(),
                                   quantileSettings = createQuantileSettings(),
                                   personSampleSettings = createPersonSampleSettings(),
                                   siteRole = "primary") {
  checkmate::assertClass(preprocessSettings, "tabehrPreprocessSettings")
  checkmate::assertClass(populationSettings, "tabehrPopulationSettings")
  checkmate::assertClass(personSplitSettings, "tabehrPersonSplitSettings")
  checkmate::assertClass(allRecordsSettings, "tabehrAllRecordsSettings")
  checkmate::assertClass(quantileSettings, "tabehrQuantileSettings")
  checkmate::assertClass(personSampleSettings, "tabehrPersonSampleSettings")
  checkmate::assertChoice(siteRole, c("primary", "external"))
  if (identical(siteRole, "external") &&
      identical(quantileSettings$basis, "pretrain")) {
    stop("An external site has no pretraining patients, so the quantile basis ",
         "cannot be \"pretrain\". Use \"all\" to compute its own, as MedRep ",
         "does per site, or \"file\" to apply another site's table.",
         call. = FALSE)
  }

  settings <- list(
    siteRole = siteRole,
    preprocessSettings = preprocessSettings,
    populationSettings = populationSettings,
    personSplitSettings = personSplitSettings,
    allRecordsSettings = allRecordsSettings,
    quantileSettings = quantileSettings,
    personSampleSettings = personSampleSettings
  )
  class(settings) <- "tabehrAnalysisSettings"
  settings
}

#' Save analysis settings as JSON
#'
#' @param analysisSettings From [createAnalysisSettings()].
#' @param file Destination file.
#'
#' @return Invisibly, `file`.
#' @export
saveAnalysisSettings <- function(analysisSettings, file) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(file, min.chars = 1)
  if (!dir.exists(dirname(file))) {
    dir.create(dirname(file), recursive = TRUE)
  }
  plain <- lapply(analysisSettings, function(part) {
    if (is.list(part)) {
      class(part) <- NULL
    }
    part
  })
  jsonlite::write_json(plain, path = file, auto_unbox = TRUE, pretty = TRUE,
                       null = "null")
  invisible(file)
}

#' Load analysis settings from JSON
#'
#' Every value goes back through its `create*Settings()` function, so a file
#' that is out of date with the code fails here rather than halfway through a
#' run.
#'
#' @param file JSON file written by [saveAnalysisSettings()]. Defaults to the
#'   settings installed with the package.
#'
#' @return An object of class `tabehrAnalysisSettings`.
#' @export
loadAnalysisSettings <- function(file = system.file("settings",
                                                    "analysisSettings.json",
                                                    package = "TabEHR")) {
  checkmate::assertFileExists(file)
  spec <- jsonlite::fromJSON(file, simplifyVector = TRUE,
                             simplifyDataFrame = FALSE)
  build <- function(constructor, arguments) {
    if (is.null(arguments)) {
      return(constructor())
    }
    arguments <- lapply(arguments, function(value) {
      if (is.list(value)) unlist(value, use.names = FALSE) else value
    })
    do.call(constructor, arguments)
  }
  createAnalysisSettings(
    preprocessSettings = build(createPreprocessSettings,
                               spec$preprocessSettings),
    populationSettings = build(createPopulationSettings,
                               spec$populationSettings),
    personSplitSettings = build(createPersonSplitSettings,
                                spec$personSplitSettings),
    allRecordsSettings = build(createAllRecordsSettings,
                               spec$allRecordsSettings),
    quantileSettings = build(createQuantileSettings, spec$quantileSettings),
    personSampleSettings = build(createPersonSampleSettings,
                                 spec$personSampleSettings),
    siteRole = if (is.null(spec$siteRole)) "primary" else spec$siteRole
  )
}
