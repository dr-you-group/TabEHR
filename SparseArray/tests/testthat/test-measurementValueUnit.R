# The measurement covariates of this package. Two analyses that partition the
# measurements, 998 for a numeric value and 999 for none, both built with
# FeatureExtraction's id arithmetic. These tests pin the arithmetic and the
# inherited behaviour; the SQL itself is rendered and translated by
# extras/CheckSqlRendering.R in TabEHR.

# Copied from FeatureExtraction 3.2.0,
# inst/sql/sql_server/MeasurementValue.sql.
feCovariateId <- paste0(
  "CAST((CAST(measurement_concept_id AS BIGINT) * 1000000) + ",
  "((unit_concept_id - (FLOOR(unit_concept_id / 1000) * 1000)) * 1000) + ",
  "@analysis_id AS BIGINT) AS covariate_id"
)

test_that("the value covariate id is FeatureExtraction's expression, with one documented change", {
  # The only deviation is COALESCE(unit_concept_id, 0): FeatureExtraction's
  # join on unit_concept_id drops a numeric measurement whose unit is NULL,
  # and this package keeps it as an unknown-unit covariate instead. Deriving
  # the expected string from FeatureExtraction's own proves the deviation is
  # exactly that and nothing else. "unit_concept_id" is not a substring of
  # "measurement_concept_id", so the substitution cannot touch the concept.
  expected <- gsub("unit_concept_id", "COALESCE(unit_concept_id, 0)",
                   feCovariateId, fixed = TRUE)

  expect_true(grepl(expected, packagedSql("MeasurementValueUnit.sql"),
                    fixed = TRUE))
  # The crosswalk has to agree with it, or it would map ids that do not exist.
  expect_true(grepl(expected, packagedSql("MeasurementValueUnitRef.sql"),
                    fixed = TRUE))
})

test_that("the no-value covariate id is FeatureExtraction's DomainConcept expression", {
  expect_true(grepl(
    paste0("CAST(CAST(measurement.measurement_concept_id AS BIGINT) * 1000 + ",
           "@no_value_analysis_id AS BIGINT)"),
    packagedSql("MeasurementValueUnit.sql"), fixed = TRUE
  ))
})

test_that("the two analyses partition the measurements", {
  sql <- packagedSql("MeasurementValueUnit.sql")

  # The value analysis takes the rows with a number, the no-value analysis the
  # rows without one...
  expect_true(grepl("AND measurement.value_as_number IS NOT NULL", sql,
                    fixed = TRUE))
  expect_true(grepl("AND measurement.value_as_number IS NULL", sql,
                    fixed = TRUE))
  # ... and the no-value analysis stands down where the value analysis already
  # covered that row, concept and interval, so one record is never two
  # covariates.
  expect_true(grepl("AND NOT EXISTS (", sql, fixed = TRUE))
  expect_true(grepl("FROM #mvu_val taken", sql, fixed = TRUE))
  expect_true(grepl(
    "AND taken.measurement_concept_id = measurement.measurement_concept_id",
    sql, fixed = TRUE
  ))
})

test_that("the inherited join and tie-break are kept", {
  sql <- packagedSql("MeasurementValueUnit.sql")

  # The join reads the unit as 0 when it is missing, which is the one change.
  expect_true(grepl(
    paste0("AND meas_cov.unit_concept_id = ",
           "COALESCE(measurement.unit_concept_id, 0)"),
    sql, fixed = TRUE
  ))
  # The partition is by concept, not by covariate, so one concept measured in
  # two units inside one interval contributes one row.
  expect_true(grepl("PARTITION BY cohort.@row_id_field,", sql, fixed = TRUE))
  expect_true(grepl(
    paste0("ORDER BY measurement.measurement_date DESC,\n",
           "\t\t\t\tmeasurement.unit_concept_id,\n",
           "\t\t\t\tmeasurement.value_as_number"),
    sql, fixed = TRUE
  ))
  expect_true(grepl("WHERE rn = 1", sql, fixed = TRUE))
  # The covariate value is the measurement value, not a count or a flag.
  expect_true(grepl("measurement.value_as_number AS covariate_value", sql,
                    fixed = TRUE))
})

test_that("the crosswalk keeps only pairs an extraction can produce", {
  sql <- packagedSql("MeasurementValueUnitRef.sql")

  expect_true(grepl("WHERE value_as_number IS NOT NULL", sql, fixed = TRUE))
  expect_true(grepl("AND measurement_concept_id != 0", sql, fixed = TRUE))
  expect_true(grepl("COUNT(*) AS record_count", sql, fixed = TRUE))
  # A missing unit is a covariate with unit 0 here too, not a dropped row.
  expect_false(grepl("unit_concept_id IS NOT NULL", sql, fixed = TRUE))
  expect_true(grepl("COALESCE(unit_concept_id, 0) AS unit_concept_id", sql,
                    fixed = TRUE))
})

test_that("the settings object is what FeatureExtraction dispatches on", {
  settings <- createMeasurementValueUnitCovariateSettings()

  expect_s3_class(settings, "covariateSettings")
  expect_identical(
    attr(settings, "fun"),
    "SparseArray::getDbMeasurementValueUnitCovariateData"
  )
  # 99x is this package's block: FeatureExtraction's two prespecified analysis
  # sets both stop at 926, so neither id can collide with one of its own.
  expect_identical(settings$analysisId, 998)
  expect_identical(settings$noValueAnalysisId, 999)
  expect_identical(settings$timePart, "day")
  expect_null(settings$timeRef)
})

test_that("settings that cannot work are refused", {
  expect_error(
    createMeasurementValueUnitCovariateSettings(timePart = "month"),
    "day"
  )
  expect_error(
    createMeasurementValueUnitCovariateSettings(sequenceStartDay = 5,
                                                sequenceEndDay = 0),
    "must not be after"
  )
  expect_error(
    createMeasurementValueUnitCovariateSettings(analysisId = 1000),
    "analysisId"
  )
  expect_error(
    createMeasurementValueUnitCovariateSettings(analysisId = 999),
    "must differ"
  )
})

test_that("the window comes from the settings block, not from a default", {
  settings <- .measurementValueUnitSettings(list(
    timePart = "day",
    timeInterval = 7,
    sequenceStartDay = -90,
    sequenceEndDay = -1
  ))

  expect_identical(settings$timeInterval, 7)
  expect_identical(settings$sequenceStartDay, -90)
  expect_identical(settings$sequenceEndDay, -1)
})

test_that("a custom analysis is recognised and kept out of FeatureExtraction's arguments", {
  args <- list(
    timePart = "day",
    timeInterval = 1,
    sequenceStartDay = -99999,
    sequenceEndDay = 0,
    useConditionOccurrence = TRUE,
    useMeasurementValueUnit = TRUE
  )

  expect_identical(.customAnalyses(args), "useMeasurementValueUnit")
  expect_false("useMeasurementValueUnit" %in%
                 names(.stripCustomAnalysisArgs(args)))
  expect_true("useConditionOccurrence" %in%
                names(.stripCustomAnalysisArgs(args)))
  # Not set, or set to FALSE, is not asking for it.
  expect_identical(.customAnalyses(args["useConditionOccurrence"]),
                   character(0))
  expect_identical(
    .customAnalyses(list(useMeasurementValueUnit = FALSE)),
    character(0)
  )
})

test_that("the analyses that would double count a measurement are refused", {
  # 701 covers every measurement, so one record would get both a 701 and a 998
  # covariate.
  expect_error(
    .assertCustomAnalysisArgs(
      list(useMeasurement = TRUE, useMeasurementValueUnit = TRUE),
      "covariateSettings$admission"
    ),
    "two covariates"
  )
  # 702 is the broken FeatureExtraction analysis this one replaces.
  expect_error(
    .assertCustomAnalysisArgs(
      list(useMeasurementValue = TRUE, useMeasurementValueUnit = TRUE),
      "covariateSettings$admission"
    ),
    "useMeasurementValueUnit alone"
  )
  expect_silent(
    .assertCustomAnalysisArgs(list(useMeasurementValueUnit = TRUE), "x")
  )
  # Without the custom analysis there is nothing to conflict with.
  expect_silent(
    .assertCustomAnalysisArgs(list(useMeasurement = TRUE), "x")
  )
})
