test_that("the settings objects carry their class and defaults", {
  settings <- createAnalysisSettings()
  expect_s3_class(settings, "tabehrAnalysisSettings")
  expect_s3_class(settings$preprocessSettings, "tabehrPreprocessSettings")
  expect_s3_class(settings$populationSettings, "tabehrPopulationSettings")
  expect_s3_class(settings$personSplitSettings, "tabehrPersonSplitSettings")
  expect_s3_class(settings$quantileSettings, "tabehrQuantileSettings")
  expect_s3_class(settings$personSampleSettings, "tabehrPersonSampleSettings")

  expect_identical(settings$siteRole, "primary")
  # "all" is MedRep's basis: the quantiles are computed before the split, so the
  # basis and the rows being binned are the same set.
  expect_identical(settings$quantileSettings$basis, "all")
  expect_null(settings$personSampleSettings$samplePersonCount)
  expect_identical(settings$populationSettings$lengthOfStayOperator, ">=")
  expect_equal(settings$populationSettings$minAdmissionLengthOfStay, 2)
  # The admission criterion is counted but not applied: on MIMIC it cost most
  # of the study population, and nothing downstream of here depends on it.
  expect_false(settings$populationSettings$requireQualifyingAdmission)
})

test_that("bad settings are refused where they are made", {
  expect_error(createPreprocessSettings(quantileMethod = "median"))
  expect_error(createPreprocessSettings(dateMin = "1900/01/01"))
  expect_error(createPopulationSettings(lengthOfStayOperator = "<"))
  expect_error(createPopulationSettings(minRecordCount = 0))
  expect_error(createPopulationSettings(requireQualifyingAdmission = NA))
  expect_error(createPersonSplitSettings(pretrainTrainFraction = 0.9),
               "sum to 1")
  expect_error(createQuantileSettings(basis = "file"))
  expect_error(createQuantileSettings(basis = "everything"))
  expect_error(createPersonSampleSettings(samplePersonCount = 0))
})

test_that("an external site computes its own quantiles, or applies a file", {
  # MedRep recomputes per site, so an external site needs no file. What it
  # cannot do is use a pretraining basis, having no pretraining patients.
  expect_s3_class(createAnalysisSettings(siteRole = "external"),
                  "tabehrAnalysisSettings")
  expect_s3_class(
    createAnalysisSettings(
      quantileSettings = createQuantileSettings(
        basis = "file", quantileFile = "output/mimic/meas_quantiles.csv"
      ),
      siteRole = "external"
    ),
    "tabehrAnalysisSettings"
  )
  expect_error(
    createAnalysisSettings(
      quantileSettings = createQuantileSettings(basis = "pretrain"),
      siteRole = "external"
    ),
    "pretrain"
  )
})

test_that("settings survive a JSON round trip unchanged", {
  settings <- createAnalysisSettings(
    preprocessSettings = createPreprocessSettings(quantileCount = 4),
    populationSettings = createPopulationSettings(
      requireQualifyingAdmission = TRUE, lengthOfStayOperator = ">"
    ),
    personSplitSettings = createPersonSplitSettings(seed = 7),
    personSampleSettings = createPersonSampleSettings(samplePersonCount = 25)
  )
  file <- tempfile(fileext = ".json")
  on.exit(unlink(file), add = TRUE)
  saveAnalysisSettings(settings, file)

  expect_identical(loadAnalysisSettings(file), settings)
})

test_that("the packaged settings file matches the defaults", {
  # Keeps inst/settings/analysisSettings.json from drifting away from the
  # create*Settings() defaults without anyone noticing.
  file <- if (file.exists("../../inst/settings/analysisSettings.json")) {
    "../../inst/settings/analysisSettings.json"
  } else {
    system.file("settings", "analysisSettings.json", package = "TabEHR")
  }
  skip_if(!nzchar(file) || !file.exists(file))
  expect_identical(loadAnalysisSettings(file), createAnalysisSettings())
})

test_that("the table names are prefixed", {
  names <- getTabehrTableNames("tabehr_")
  # Exact lookups: $allRecords would partially match allRecordsCohort.
  expect_identical(names[["allRecordsCohort"]], "tabehr_allrecords_cohort")
  expect_identical(names[["personSplit"]], "tabehr_person_split")
  expect_true(all(startsWith(unlist(names), "tabehr_")))
  expect_false(any(duplicated(unlist(names))))

  expect_identical(getTabehrTableNames("")[["allRecordsCohort"]],
                   "allrecords_cohort")
  expect_error(getTabehrTableNames("my table "), "identifier")
})
