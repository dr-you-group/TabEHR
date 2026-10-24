test_that("condition-free task input respects domains, dates and exact ids", {
  skip_if_not_installed("Andromeda")
  skip_if_not_installed("dplyr")
  oldOptions <- options(andromedaTempFolder = tempdir())
  on.exit(options(oldOptions), add = TRUE)
  data <- Andromeda::andromeda(covariates = data.frame(
    rowId = c(1, 1, 1), covariateId = c(101, 301, 301),
    covariateValue = c(1, 1, 1), timeId = c(0, 1, -1)
  ))
  on.exit(Andromeda::close(data), add = TRUE)
  map <- data.frame(
    covariateId = c(101, 301), analysisId = c(101, 301),
    conceptId = c(100, 300), domain = c("cond", "drug"),
    unitConceptId = c(NA, NA)
  )
  rows <- data.frame(
    taskRowId = 7, arRowId = 1, personId = "9007199254740993",
    indexDate = as.Date("2020-01-10"), shift = 0
  )
  settings <- list(useConditionOccurrence = FALSE, useDrugExposure = TRUE,
                   useProcedureOccurrence = FALSE,
                   useMeasurementValueUnit = FALSE)
  path <- tempfile(fileext = ".csv.gz")
  on.exit(unlink(path), add = TRUE)
  written <- .writeTaskInput(data, map, rows, c(start = -99999, end = 0),
                             path, 100, domains = .taskInputDomains(settings))
  result <- utils::read.csv(path, colClasses = c(person_id = "character"))
  expect_equal(written, 1)
  expect_identical(result$domain, "drug")
  expect_identical(result$person_id, "9007199254740993")
  expect_identical(result$record_date, "2020-01-09")
  expect_equal(result$time_id, 1)
})
