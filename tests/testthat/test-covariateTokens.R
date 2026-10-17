# Can a featureExtractionLong row be turned back into an allrecords token?
#
# The embedding the model uses is keyed on concept_id, and the measurement
# tokens are "<concept_id>_<bin>", so this conversion is what lets the
# FeatureExtraction side of the project reach the model side. The id arithmetic
# below is FeatureExtraction v3.2.0's, read from its own SQL:
#
#   DomainConcept.sql     covariate_id = concept_id * 1000 + analysis_id
#   MeasurementValue.sql  covariate_id = measurement_concept_id * 1000000
#                                      + (unit_concept_id % 1000) * 1000
#                                      + analysis_id

quantileTable <- function() {
  # Glucose in mg/dL (unit 8840) and in mmol/L (unit 8753), with ten boundaries
  # each, plus a concept whose unit shares no last three digits.
  data.frame(
    measurement_concept_id = c(3004501, 3004501, 3013429),
    unit_concept_id = c(8840, 8753, 8840),
    quantile_0 = c(50, 2.7, 10),
    quantile_1 = c(70, 3.9, 20),
    quantile_2 = c(80, 4.4, 30),
    quantile_3 = c(90, 5.0, 40),
    quantile_4 = c(100, 5.6, 50),
    quantile_5 = c(110, 6.1, 60),
    quantile_6 = c(125, 6.9, 70),
    quantile_7 = c(140, 7.8, 80),
    quantile_8 = c(170, 9.4, 90),
    quantile_9 = c(220, 12.2, 100),
    quantile_10 = c(600, 33.3, 110),
    stringsAsFactors = FALSE
  )
}

# covariateRef.csv, as SparseArray::createLongFormat() writes it: the four
# columns FeatureExtraction's reference table has, plus the unitConceptId
# joined from measurementValueUnitRef.csv. The unit of a measurement value
# covariate is only here: its id keeps unit_concept_id modulo 1000.
covariateRefTable <- function(...) {
  table <- data.frame(
    covariateId = c(3004501840702, 3004501753702, 3013429840702,
                    9999999840702, 40481087840702, 316139101),
    covariateName = c("measurement value: Glucose (mg/dL)",
                      "measurement value: Glucose (mmol/L)",
                      "measurement value: Creatinine (mg/dL)",
                      "measurement value: Unknown concept (mg/dL)",
                      "measurement value: Potassium (mg/dL)",
                      "Atrial fibrillation"),
    analysisId = c(702, 702, 702, 702, 702, 101),
    conceptId = c(3004501, 3004501, 3013429, 9999999, 40481087, 316139),
    unitConceptId = c(8840, 8753, 8840, 8840, 8840, NA),
    stringsAsFactors = FALSE
  )
  rbind(table, ...)
}

test_that("a DomainConcept covariate id decodes to its concept", {
  decoded <- decodeCovariateId(c(316139101, 1125315301, 4163872501))

  expect_identical(decoded$analysisId, c(101, 301, 501))
  expect_identical(decoded$conceptId, c(316139, 1125315, 4163872))
  expect_true(all(is.na(decoded$unitConceptIdMod1000)))
})

test_that("a MeasurementValue covariate id decodes to concept and unit", {
  # 3004501 * 1e6 + 840 * 1000 + 702
  decoded <- decodeCovariateId(3004501840702)

  expect_identical(decoded$analysisId, 702)
  expect_identical(decoded$conceptId, 3004501)
  expect_identical(decoded$unitConceptIdMod1000, 840)
})

test_that("the analysis set has to be named, because 702 is overloaded", {
  # In the temporal set 702 is MeasurementValue; in the non-temporal set it is
  # MeasurementLongTerm, a plain DomainConcept analysis, and MeasurementValue is
  # 705 to 708.
  asTemporal <- decodeCovariateId(3004501840702)
  asPrespec <- decodeCovariateId(3004501840702,
                                 measurementValueAnalysisIds = 705:708)

  expect_identical(asTemporal$conceptId, 3004501)
  expect_identical(asPrespec$conceptId, (3004501840702 - 702) / 1000)
  expect_true(is.na(asPrespec$unitConceptIdMod1000))
})

test_that("a covariate id beyond 2^53 is refused rather than rounded", {
  expect_error(decodeCovariateId(2^53 + 2), "2\\^53")
})

test_that("the bin is the count of boundaries below the value, less one", {
  boundaries <- matrix(c(0, 1, 1, 2, 3, 3, 3, 5, 8, 13, 21), nrow = 1)
  bin <- function(value) {
    assignQuantileBin(value, boundaries)
  }

  expect_identical(bin(-5), 0L)      # below every boundary
  expect_identical(bin(0), 0L)       # on the lowest boundary
  expect_identical(bin(1.5), 2L)     # repeated boundaries counted twice
  expect_identical(bin(3.5), 6L)
  expect_identical(bin(21), 9L)      # on the highest boundary
  expect_identical(bin(100), 10L)    # above it
  expect_identical(assignQuantileBin(NA_real_, boundaries), NA_integer_)
})

test_that("a condition covariate becomes the bare concept id", {
  result <- covariateToToken(316139101, 1, quantileTable(),
                             covariateRefTable())

  expect_identical(result$token, "316139")
  expect_false(result$hasBin)
})

test_that("a measurement covariate becomes concept_id and bin", {
  # Glucose 3004501 in mg/dL. 155 sits between the 7th (140) and 8th (170)
  # boundary, so eight boundaries are below it and the bin is 7.
  result <- covariateToToken(3004501840702, 155, quantileTable(),
                             covariateRefTable())

  expect_identical(result$token, "3004501_7")
  expect_identical(result$bin, 7L)
  expect_true(result$hasBin)
})

test_that("the unit decides the bin", {
  # The same concept in mmol/L (unit 8753): 8.6 is between 7.8 and 9.4.
  result <- covariateToToken(c(3004501840702, 3004501753702),
                             c(155, 8.6), quantileTable(),
                             covariateRefTable())

  expect_identical(result$token, c("3004501_7", "3004501_7"))
  # Were the unit ignored, 8.6 would fall in the lowest bin of the mg/dL row.
  mgdl <- covariateToToken(3004501840702, 8.6, quantileTable(),
                           covariateRefTable())
  expect_identical(mgdl$token, "3004501_0")
})

test_that("a pair with no quantile row keeps the bare concept id", {
  # Same fallback AllRecords.sql applies, so a covariate below the record
  # threshold, or one with an unmapped unit, still yields a usable token.
  result <- covariateToToken(9999999840702, 5, quantileTable(),
                             covariateRefTable())

  expect_identical(result$token, "9999999")
  expect_false(result$hasBin)
  expect_true(is.na(result$bin))
})

test_that("large concept ids are not written in scientific notation", {
  # format() would otherwise turn 40481087 into 4.048109e+07 and the token
  # would not match any vocabulary key.
  table <- quantileTable()
  table$measurement_concept_id[1] <- 40481087
  result <- covariateToToken(40481087840702, 100, table,
                             covariateRefTable())

  # 100 is the fifth boundary itself, so four boundaries are strictly below it
  # and the bin is 3: bisect_left, not bisect_right.
  expect_identical(result$token, "40481087_3")
  expect_false(grepl("e+", result$token, fixed = TRUE))
})

test_that("a quantile table with a repeated key is refused", {
  # (measurement_concept_id, unit_concept_id) is its primary key.
  table <- rbind(quantileTable(), quantileTable()[1, ])

  expect_error(covariateToToken(3004501840702, 155, table,
                                covariateRefTable()),
               "primary key")
})

test_that("a quantile table without the expected columns is refused", {
  expect_error(
    covariateToToken(316139101, 1,
                     data.frame(measurement_concept_id = 1, quantile_0 = 1),
                     covariateRefTable()),
    "unit_concept_id"
  )
})

test_that("the concept and the unit are looked up, not computed", {
  resolved <- resolveCovariateId(c(3004501840702, 316139101),
                                 covariateRefTable())

  expect_identical(resolved$conceptId, c(3004501, 316139))
  expect_identical(resolved$analysisId, c(702, 101))
  expect_identical(resolved$unitConceptId, c(8840, NA_real_))
  expect_identical(resolved$unitAmbiguous, c(FALSE, FALSE))
})

test_that("a covariate id missing from covariateRef is refused", {
  # The long file and the reference table have to be from one extraction.
  expect_error(
    resolveCovariateId(1125315301, covariateRefTable()),
    "not from one extraction"
  )
})

test_that("a covariateRef with snake case columns is accepted", {
  table <- covariateRefTable()
  names(table) <- c("covariate_id", "covariate_name", "analysis_id",
                    "concept_id", "unit_concept_id")

  resolved <- resolveCovariateId(3004501840702, table)

  expect_identical(resolved$unitConceptId, 8840)
})

test_that("two units that agree modulo 1000 are both usable", {
  # 8840 and 9840 share one covariate id, so the residue could never tell them
  # apart. The quantile table is keyed on the whole unit, so it holds both
  # rows without conflict, and the reference table says which one this
  # covariate is.
  quantiles <- rbind(quantileTable(), quantileTable()[1, ])
  quantiles$unit_concept_id[4] <- 9840
  quantiles$quantile_0[4] <- 1

  result <- covariateToToken(3004501840702, 155, quantiles,
                             covariateRef = covariateRefTable())

  expect_identical(result$unitConceptId, 8840)
  expect_false(result$unitAmbiguous)
  expect_identical(result$token, "3004501_7")
})

test_that("a covariate that really does mix two units is not guessed at", {
  # The same collision, but now both units were extracted, so the reference
  # table has two rows for the one covariate id. Its values mix mg/dL and the
  # other unit and nothing can undo that, so there is no bin and the token
  # falls back to the bare concept.
  ref <- covariateRefTable(data.frame(
    covariateId = 3004501840702,
    covariateName = "measurement value: Glucose (other unit)",
    analysisId = 702,
    conceptId = 3004501,
    unitConceptId = 9840,
    stringsAsFactors = FALSE
  ))

  result <- covariateToToken(3004501840702, 155, quantileTable(),
                             covariateRef = ref)

  expect_true(result$unitAmbiguous)
  expect_true(is.na(result$unitConceptId))
  expect_false(result$hasBin)
  expect_identical(result$token, "3004501")
})

test_that("a covariateRef without the unit column is refused", {
  table <- covariateRefTable()
  table$unitConceptId <- NULL

  expect_error(
    covariateToToken(3004501840702, 155, quantileTable(),
                     covariateRef = table),
    "unitConceptId"
  )
})

test_that("a condition covariate is untouched by the unit resolution", {
  result <- covariateToToken(316139101, 1, quantileTable(),
                             covariateRef = covariateRefTable())

  expect_identical(result$conceptId, 316139)
  expect_false(result$hasBin)
  expect_identical(result$token, "316139")
})

test_that("the reference table is not optional", {
  # The whole unit is only there. The residue the id carries is never used as
  # a key, so there is no fallback to fall back to.
  expect_error(covariateToToken(3004501840702, 155, quantileTable()),
               "covariateRef")
})

test_that("the unit the reference table names is the one that is used", {
  # 8753 and 8840 are both real units of this concept, and the id carries
  # neither of them: it carries 840. The reference table decides, so the value
  # bins against the mmol/L row.
  ref <- covariateRefTable()
  ref$unitConceptId[1] <- 8753

  result <- covariateToToken(3004501840702, 8.6, quantileTable(), ref)

  expect_identical(result$unitConceptId, 8753)
  expect_identical(result$token, "3004501_7")
})
