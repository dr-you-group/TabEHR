sequenceArgs <- function(...) {
  args <- list(
    useConditionOccurrence = TRUE,
    useDrugExposure = TRUE,
    timePart = "day",
    timeInterval = 30,
    sequenceStartDay = -359,
    sequenceEndDay = -1,
    includedCovariateConceptIds = c(),
    addDescendantsToInclude = FALSE,
    excludedCovariateConceptIds = c(),
    addDescendantsToExclude = FALSE,
    includedCovariateIds = c()
  )
  utils::modifyList(args, list(...))
}

temporalArgs <- function() {
  list(
    useConditionOccurrence = TRUE,
    useDrugExposure = TRUE,
    temporalStartDays = seq(from = -360, to = -30, by = 30),
    temporalEndDays = seq(from = -331, to = -1, by = 30)
  )
}

test_that("temporal sequence settings round-trip through JSON", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  saveCovariateSettings(sequenceArgs(), file)
  expect_identical(
    jsonlite::fromJSON(file, simplifyDataFrame = FALSE)$settingsType,
    "temporalSequence"
  )

  settings <- loadCovariateSettings(file)
  expect_true(isTRUE(settings$temporalSequence))
  expect_false(isTRUE(settings$temporal))
  expect_identical(settings$timePart, "day")
  expect_equal(settings$timeInterval, 30)
  expect_equal(settings$sequenceStartDay, -359)
  expect_equal(settings$sequenceEndDay, -1)
  expect_true(settings$ConditionOccurrence)
  expect_true(settings$DrugExposure)
})

test_that("temporal window settings round-trip through JSON", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  saveCovariateSettings(temporalArgs(), file, settingsType = "temporal")
  expect_identical(
    jsonlite::fromJSON(file, simplifyDataFrame = FALSE)$settingsType,
    "temporal"
  )

  settings <- loadCovariateSettings(file)
  expect_true(isTRUE(settings$temporal))
  expect_false(isTRUE(settings$temporalSequence))
  expect_equal(settings$temporalStartDays, seq(from = -360, to = -30, by = 30))
  expect_equal(settings$temporalEndDays, seq(from = -331, to = -1, by = 30))
})

test_that("the settings type is inferred from the arguments", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  saveCovariateSettings(temporalArgs(), file)
  expect_true(isTRUE(loadCovariateSettings(file)$temporal))

  saveCovariateSettings(sequenceArgs(), file, settingsType = "temporalSequence")
  expect_true(isTRUE(loadCovariateSettings(file)$temporalSequence))

  expect_error(
    saveCovariateSettings(list(useConditionOccurrence = TRUE), file),
    "Cannot tell which settings are meant"
  )
})

test_that("settings files without a settingsType still load", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  writeLines(
    jsonlite::toJSON(temporalArgs(), auto_unbox = TRUE, pretty = TRUE),
    file
  )
  expect_true(isTRUE(loadCovariateSettings(file)$temporal))

  writeLines(
    jsonlite::toJSON(sequenceArgs(), auto_unbox = TRUE, pretty = TRUE),
    file
  )
  expect_true(isTRUE(loadCovariateSettings(file)$temporalSequence))
})

test_that("saveCovariateSettings validates the sequence arguments", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  expect_error(
    saveCovariateSettings(
      sequenceArgs(timeInterval = NULL),
      file,
      settingsType = "temporalSequence"
    ),
    "Missing: timeInterval"
  )
  expect_error(
    saveCovariateSettings(sequenceArgs(timePart = "week"), file),
    "timePart must be one of"
  )
  expect_error(
    saveCovariateSettings(sequenceArgs(timeInterval = 0), file),
    ">= 1"
  )
  expect_error(
    saveCovariateSettings(sequenceArgs(sequenceStartDay = 1), file),
    "must not be after sequenceEndDay"
  )
  expect_false(file.exists(file))
})

test_that("saveCovariateSettings requires matching temporal windows", {
  skip_if_not_installed("FeatureExtraction")

  file <- tempfile("covariateSettings-", fileext = ".json")
  on.exit(unlink(file, force = TRUE), add = TRUE)

  expect_error(
    saveCovariateSettings(
      list(useConditionOccurrence = TRUE),
      file,
      settingsType = "temporal"
    ),
    "temporalStartDays and temporalEndDays are required"
  )
  expect_error(
    saveCovariateSettings(
      list(
        useConditionOccurrence = TRUE,
        temporalStartDays = c(-60, -30),
        temporalEndDays = -1
      ),
      file
    ),
    "must have the same length"
  )
})

test_that("loadCovariateSettings reports a missing file", {
  expect_error(
    loadCovariateSettings(file.path(tempdir(), "does-not-exist.json")),
    "Cannot find covariate settings file"
  )
})
