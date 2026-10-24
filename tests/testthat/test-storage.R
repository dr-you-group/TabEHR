test_that("execute uses a separate working folder and restores options on error", {
  old <- options(andromedaTempFolder = "previous-working-folder")
  on.exit(options(old), add = TRUE)
  folder <- tempfile("storage-test-")
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  observed <- NULL
  run <- execute
  isolated <- new.env(parent = environment(run))
  environment(run) <- isolated
  isolated$exportRunInfo <- function(...) {
    observed <<- getOption("andromedaTempFolder")
    stop("storage probe reached", call. = FALSE)
  }
  working <- file.path(folder, "working")
  expect_error(run(
    connectionDetails = NULL, cdmDatabaseSchema = "cdm",
    cohortDatabaseSchema = "work", outputFolder = file.path(folder, "results"),
    databaseId = "test", analysisSettings = createAnalysisSettings(),
    checkDatabase = FALSE, extractRecords = FALSE,
    createStudyPopulation = FALSE, createPersonSplit = FALSE,
    createAllRecords = FALSE, createTaskInput = FALSE, runDiagnostics = FALSE,
    andromedaTempFolder = working
  ), "storage probe reached")
  expect_identical(observed, working)
  expect_true(dir.exists(working))
  expect_identical(getOption("andromedaTempFolder"), "previous-working-folder")
})
