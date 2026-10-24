test_that("allrecords maps measurement units through the reference resolver", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("dplyr")
  oldOptions <- options(andromedaTempFolder = tempdir())
  on.exit(options(oldOptions), add = TRUE)
  reference <- data.frame(
    covariateId = c(100101, 200001998, 300002998, 400999),
    analysisId = c(101, 998, 998, 999),
    conceptId = c(100, 200, 300, 400)
  )
  data <- Andromeda::andromeda(covariateRef = reference)
  on.exit(Andromeda::close(data), add = TRUE)
  folder <- tempfile("unit-map-")
  dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  utils::write.csv(
    data.frame(covariateId = c(200001998, 300002998, 300002998),
               conceptId = c(200, 300, 300),
               unitConceptId = c(1001, 1002, 2002)),
    file.path(folder, "measurementValueUnitRef.csv"), row.names = FALSE
  )
  map <- .allRecordsCovariateMap(data, folder)
  expect_equal(map$covariateId, reference$covariateId)
  expect_identical(map$domain, c("cond", "meas", "meas", "meas"))
  expect_equal(map$unitConceptId, c(NA, 1001, NA, NA))
})

test_that("allrecords joins numeric and integer64 row ids without losing person ids", {
  skip_if_not_installed("bit64")
  batch <- data.frame(rowId = 1, covariateId = 100101,
                      covariateValue = 1, timeId = 0)
  map <- data.frame(covariateId = 100101, analysisId = 101,
                    conceptId = 100, domain = "cond", unitConceptId = NA_real_)
  cohort <- data.frame(rowId = bit64::as.integer64("1"),
                       personId = "9007199254740993",
                       indexDate = as.Date("2020-01-10"))
  path <- tempfile(fileext = ".csv")
  on.exit(unlink(path), add = TRUE)
  out <- file(path, "wt")
  written <- tryCatch(.allRecordsBatch(batch, map, cohort, out),
                      finally = close(out))
  rows <- utils::read.csv(path, header = FALSE, colClasses = "character")
  expect_equal(written, 1)
  expect_identical(rows$V1, "9007199254740993")
  expect_identical(rows$V4, "2020-01-10")
})

test_that("large integer64 covariate ids retain known and ambiguous units", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("bit64")
  old <- options(andromedaTempFolder = tempdir())
  on.exit(options(old), add = TRUE)
  ids <- c("100000101", "200000001998", "300000002998", "400000999")
  ref <- data.frame(covariateId = bit64::as.integer64(ids),
                     analysisId = c(101, 998, 998, 999),
                     conceptId = c(100000, 200000, 300000, 400000))
  data <- Andromeda::andromeda(covariateRef = ref)
  on.exit(Andromeda::close(data), add = TRUE)
  folder <- tempfile("integer64-units-")
  dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  utils::write.csv(data.frame(
    covariateId = c(200000001998, 300000002998, 300000002998),
    conceptId = c(200000, 300000, 300000),
    unitConceptId = c(1001, 1002, 2002)
  ), file.path(folder, "measurementValueUnitRef.csv"), row.names = FALSE)
  map <- .allRecordsCovariateMap(data, folder)
  expect_s3_class(map$covariateId, "integer64")
  expect_identical(as.character(map$covariateId), ids)
  expect_equal(map$unitConceptId, c(NA, 1001, NA, NA))
})
