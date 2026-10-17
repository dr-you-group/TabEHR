saveSequenceCovariateData <- function(outputFolder, includeStatic = FALSE) {
  saveTestCovariateData(
    outputFolder,
    # timeId counts 30-day intervals back from the index date: 0 is the interval
    # ending the day before index, 2 is the oldest. Interval 0 has no observed
    # data, so the time axis has to be padded from the settings.
    covariates = testCovariates(
      timeIds = c(1L, 2L, 1L, 2L, 2L),
      includeStatic = includeStatic
    ),
    covariateRef = testCovariateRef(),
    timeRef = data.frame(
      timePart = "day",
      timeInterval = 30L,
      sequenceStartDay = -89L,
      sequenceEndDay = -1L,
      stringsAsFactors = FALSE
    )
  )
}

saveWindowCovariateData <- function(outputFolder, includeStatic = FALSE) {
  saveTestCovariateData(
    outputFolder,
    covariates = testCovariates(
      timeIds = c(1L, 2L, 1L, 2L, 2L),
      includeStatic = includeStatic
    ),
    covariateRef = testCovariateRef(),
    # Deliberately unsorted, and with a window that has no observed data, so
    # that the time axis has to be ordered by startDay and padded.
    timeRef = data.frame(
      timeId = c(1L, 2L, 3L),
      startDay = c(-60, -30, -90),
      endDay = c(-31, -1, -61)
    )
  )
}

# Both fixtures are chosen to put the five observations of testCovariates() in
# the same cells, even though the axes are built by different rules: the sequence
# axis is ordered by timeId (0, 1, 2) and the window axis by startDay (timeId 3,
# 1, 2). In each the first position holds no data.
expectedArray <- function() {
  expected <- array(0, dim = c(3L, 3L, 3L))
  expected[2, 2, 3] <- 1.5   # rowId 20, second time position, covariateId 300
  expected[2, 2, 1] <- 3     # rowId 20, second time position, covariateId 100
  expected[1, 3, 2] <- 6     # rowId 10, third time position, covariateId 200
  expected[3, 3, 3] <- 5     # rowId 30, third time position, covariateId 300
  expected
}

test_that("createSparseArray maps a temporal sequence into patient x time x covariate", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")
  skip_if_not_installed("slam")

  outputFolder <- tempfile("sparse-array-sequence-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)
  saveSequenceCovariateData(outputFolder)

  originalBatchApply <- Andromeda::batchApply
  batchCount <- 0L
  localMockedBindings(
    batchApply = function(tbl, fun, ..., batchSize = 1e6) {
      countBatches <- function(batch, ...) {
        batchCount <<- batchCount + 1L
        fun(batch, ...)
      }
      originalBatchApply(
        tbl,
        countBatches,
        ...,
        batchSize = batchSize
      )
    },
    .package = "Andromeda"
  )

  createSparseArray(outputFolder = outputFolder, batchSize = 2)
  result <- readRDS(file.path(outputFolder, "sparseArray.rds"))

  expect_gt(batchCount, 1L)
  expect_named(
    result,
    c(
      "dataArray",
      "labels",
      "covariateRef",
      "covariateMap",
      "timeMap",
      "timeAxis"
    ),
    ignore.order = FALSE
  )
  expect_s3_class(result$dataArray, "simple_sparse_array")
  expect_identical(dim(result$dataArray), c(3L, 3L, 3L))
  expect_null(dimnames(result$dataArray))

  # Days -89 to -1 in 30-day intervals give the three positions 0, 1, 2, kept in
  # that order. Interval 0 has no data and stays all zero.
  expect_identical(result$timeMap$timeId, 0:2)
  expect_identical(result$timeMap$timeIndex, 1:3)
  expect_identical(result$timeMap$startDay, c(-29L, -59L, -89L))
  expect_identical(result$timeMap$endDay, c(-1L, -30L, -60L))
  expect_identical(result$timeAxis$type, "sequence")
  expect_identical(result$timeAxis$timePart, "day")
  expect_identical(result$timeAxis$timeInterval, 30L)
  expect_identical(result$timeAxis$timeIndexOrder, "timeId")
  expect_true(result$timeAxis$exact)

  expect_equal(as.array(result$dataArray), expectedArray())

  expect_identical(names(result$labels), c("rowId", "originalRowId"))
  expect_equal(result$labels$rowId, 1:3)
  expect_equal(result$labels$originalRowId, c(10, 20, 30))
  expect_equal(result$covariateMap$covariateId, c(100, 200, 300))
  expect_equal(result$covariateMap$columnId, 1:3)
  expect_equal(result$covariateRef$covariateId, c(100, 200, 300))
  expect_false("staticCovariateRef" %in% names(result))
})

test_that("createSparseArray maps temporal windows into patient x time x covariate", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")
  skip_if_not_installed("slam")

  outputFolder <- tempfile("sparse-array-window-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)
  saveWindowCovariateData(outputFolder)

  createSparseArray(outputFolder = outputFolder, batchSize = 2)
  result <- readRDS(file.path(outputFolder, "sparseArray.rds"))

  expect_identical(dim(result$dataArray), c(3L, 3L, 3L))
  # timeRef is ordered by startDay, so timeId 3 (-90) is the first position,
  # timeId 1 (-60) the second, and timeId 2 (-30) the third. The first position
  # has no data and stays all zero.
  expect_equal(result$timeMap$timeId, c(3L, 1L, 2L))
  expect_equal(result$timeMap$startDay, c(-90, -60, -30))
  expect_equal(result$timeMap$timeIndex, 1:3)
  expect_identical(result$timeAxis$type, "window")
  expect_equal(as.array(result$dataArray), expectedArray())
})

test_that("createSparseArray rejects covariates without a timeId unless told to drop them", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")
  skip_if_not_installed("slam")

  outputFolder <- tempfile("sparse-array-static-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)
  saveSequenceCovariateData(outputFolder, includeStatic = TRUE)

  expect_error(
    createSparseArray(outputFolder = outputFolder),
    "without a timeId"
  )
  expect_false(file.exists(file.path(outputFolder, "sparseArray.rds")))

  createSparseArray(outputFolder = outputFolder, dropStaticCovariates = TRUE)
  result <- readRDS(file.path(outputFolder, "sparseArray.rds"))

  expect_identical(dim(result$dataArray), c(3L, 3L, 3L))
  expect_equal(result$covariateMap$covariateId, c(100, 200, 300))
  expect_equal(result$staticCovariateRef$covariateId, 8507)
})

test_that("createSparseArray rejects a sequence timeId the settings cannot produce", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")
  skip_if_not_installed("slam")

  outputFolder <- tempfile("sparse-array-mismatch-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)
  saveTestCovariateData(
    outputFolder,
    covariates = testCovariates(timeIds = c(1L, 2L, 1L, 2L, 9L)),
    covariateRef = testCovariateRef(),
    timeRef = data.frame(
      timePart = "day",
      timeInterval = 30L,
      sequenceStartDay = -89L,
      sequenceEndDay = -1L,
      stringsAsFactors = FALSE
    )
  )

  expect_error(
    createSparseArray(outputFolder = outputFolder),
    "outside the range the sequence settings allow"
  )
})

test_that("createSparseArray rejects covariate data without a timeId column", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")

  outputFolder <- tempfile("sparse-array-nontemporal-")
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
    createSparseArray(outputFolder = outputFolder),
    "CovariateData without a timeId is not supported"
  )
})

test_that("createSparseArray needs a timeRef table", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("FeatureExtraction")

  outputFolder <- tempfile("sparse-array-no-timeref-")
  dir.create(outputFolder)
  on.exit(unlink(outputFolder, recursive = TRUE), add = TRUE)
  saveTestCovariateData(
    outputFolder,
    covariates = testCovariates(timeIds = c(1L, 2L, 1L, 2L, 2L)),
    covariateRef = testCovariateRef()
  )

  expect_error(
    createSparseArray(outputFolder = outputFolder),
    "no timeRef table"
  )
})
