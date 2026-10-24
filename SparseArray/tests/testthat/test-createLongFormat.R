test_that("createLongFormat writes the unmodified FeatureExtraction output", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")

  outputFolder <- tempfile("long-format-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)

  saveTestCovariateData(
    outputFolder,
    covariates = data.frame(
      cohortDefinitionId = rep(1L, 4),
      rowId = c(20, 10, 10, 10),
      covariateId = c(300, 200, 100, 8507),
      covariateValue = c(1.5, 2, 3, 1),
      # Temporal sequence positions, plus a demographics covariate that has no
      # position on the time axis.
      timeId = c(0L, 1L, 0L, NA_integer_)
    ),
    covariateRef = testCovariateRef(),
    timeRef = data.frame(
      timePart = "day",
      timeInterval = 30L,
      sequenceStartDay = -59L,
      sequenceEndDay = -1L,
      stringsAsFactors = FALSE
    )
  )

  createLongFormat(outputFolder = outputFolder, batchSize = 2)
  longFile <- file.path(outputFolder, "featureExtractionLong.csv")
  expect_true(file.exists(longFile))

  long <- utils::read.csv(longFile)
  expect_identical(
    names(long),
    c("rowId", "covariateId", "timeId", "covariateValue")
  )
  expect_equal(nrow(long), 4)
  # Sorted by rowId, then timeId, then covariateId. A missing timeId sorts
  # first in SQLite.
  expect_equal(long$rowId, c(10, 10, 10, 20))
  expect_equal(long$timeId, c(NA, 0L, 1L, 0L))
  expect_equal(long$covariateId, c(8507, 100, 200, 300))
  expect_equal(long$covariateValue, c(1, 3, 2, 1.5))
})

test_that("createLongFormat rejects covariate data without a timeId", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")

  outputFolder <- tempfile("long-format-nontemporal-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)

  saveTestCovariateData(
    outputFolder,
    covariates = data.frame(
      cohortDefinitionId = 1L,
      rowId = 10,
      covariateId = 100,
      covariateValue = 1
    ),
    covariateRef = testCovariateRef()
  )

  expect_error(
    createLongFormat(outputFolder = outputFolder),
    "has no timeId"
  )
})

test_that("createLongFormat reports a missing covariateData folder", {
  outputFolder <- tempfile("long-format-missing-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)

  expect_error(
    createLongFormat(outputFolder = outputFolder),
    "Cannot find a saved plpData"
  )
})

test_that("unit crosswalk joins integer64 ids without losing digits", {
  skip_if_not_installed("bit64")
  folder <- tempfile("unit-crosswalk-")
  dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  ids <- c("9007199254740992", "9007199254740993")
  ref <- data.frame(covariateId = bit64::as.integer64(ids), analysisId = 998)
  write.csv(data.frame(covariateId = ids, unitConceptId = c(1001, 2002)),
            file.path(folder, .measurementValueUnitRefFile), row.names = FALSE)
  result <- .addUnitConceptId(ref, list(), folder)
  expect_identical(as.character(result$covariateId), ids)
  expect_s3_class(result$covariateId, "integer64")
  expect_equal(result$unitConceptId, c(1001, 2002))
  expect_named(result, c("covariateId", "analysisId", "unitConceptId"))
})
