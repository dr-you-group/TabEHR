# Does the ported quantile logic agree with the pandas original?
#
# The fixtures come from extras/MakePandasFixtures.py, which runs the actual
# pandas and bisect code of MedRep create_trajectory.py, so these tests compare
# the port against the original's behaviour rather than against a reading of it.

quantileCount <- 10
values <- utils::read.csv("quantile_values.csv", colClasses = "character")
bins <- utils::read.csv("quantile_bins.csv", colClasses = "character")

test_that("the probabilities are the doubles pandas ends up using", {
  # Two steps have to be reproduced: numpy's linspace, and the q * 100 / 100
  # round trip inside Series.quantile(). Leaving out the second one shifts a
  # boundary in its last bits.
  fixture <- as.numeric(values$probability[values$group == values$group[1]])
  expect_identical(digits17(quantileProbabilities(quantileCount)),
                   digits17(fixture))
})

test_that("the rank interpolation reproduces Series.quantile() exactly", {
  # The same arithmetic MeasurementQuantiles.sql does: ROW_NUMBER gives 1 based
  # ranks, the position is (n - 1) * p, and the value is interpolated between
  # the ranks either side of it.
  rankQuantile <- function(sortedValues, probability) {
    n <- length(sortedValues)
    h <- (n - 1) * probability
    low <- floor(h) + 1
    high <- min(floor(h) + 2, n)
    sortedValues[low] +
      (h - floor(h)) * (sortedValues[high] - sortedValues[low])
  }
  mismatches <- character(0)
  for (group in unique(values$group)) {
    rows <- values[values$group == group, ]
    sorted <- as.numeric(strsplit(rows$values[1], " ", fixed = TRUE)[[1]])
    for (i in seq_len(nrow(rows))) {
      expected <- as.numeric(rows$boundary[i])
      actual <- rankQuantile(sorted, as.numeric(rows$probability[i]))
      if (!identical(digits17(expected), digits17(actual))) {
        mismatches <- c(mismatches, sprintf("%s j=%s: %s vs %s", group,
                                            rows$j[i], digits17(expected),
                                            digits17(actual)))
      }
    }
  }
  expect_identical(mismatches, character(0))
  expect_gt(nrow(values), 0)
})

test_that("the bin formula reproduces bisect_left, repeated boundaries included", {
  # AllRecords.sql counts the boundaries strictly below the value and subtracts
  # one, clamped at zero, which is what quantileLessThanCount() builds.
  assignBin <- function(boundaries, value) max(0, sum(boundaries < value) - 1)
  mismatches <- character(0)
  for (group in unique(bins$group)) {
    rows <- values[values$group == group, ]
    boundaries <- as.numeric(rows$boundary[order(as.integer(rows$j))])
    probes <- bins[bins$group == group, ]
    for (i in seq_len(nrow(probes))) {
      expected <- as.integer(probes$expected_bin[i])
      actual <- as.integer(assignBin(boundaries,
                                     as.numeric(probes$value[i])))
      if (!identical(expected, actual)) {
        mismatches <- c(mismatches, sprintf("%s value=%s: %d vs %d", group,
                                            probes$value[i], expected, actual))
      }
    }
  }
  expect_identical(mismatches, character(0))
  expect_true(all(as.integer(bins$expected_bin) >= 0 &
                    as.integer(bins$expected_bin) <= quantileCount))
})

test_that("the generated SQL fragments have one term per boundary", {
  expect_length(
    gregexpr("CASE WHEN", quantileLessThanCount(quantileCount))[[1]],
    quantileCount + 1
  )
  expect_length(
    strsplit(quantileColumnNames(quantileCount), ", ")[[1]],
    quantileCount + 1
  )
  expect_length(
    gregexpr("UNION ALL", quantileIndexRows(quantileCount))[[1]],
    quantileCount
  )
  expect_length(
    gregexpr("PERCENTILE_CONT", percentileExpressions(quantileCount))[[1]],
    quantileCount + 1
  )
  expect_match(quantileColumnDefinitions(quantileCount),
               "quantile_10 FLOAT NULL", fixed = TRUE)
})

test_that("the probability literals survive the trip into SQL", {
  # The CROSS JOIN rows carry the probabilities as text, so a lost digit there
  # would silently move every boundary.
  rendered <- quantileIndexRows(quantileCount)
  literals <- regmatches(rendered,
                         gregexpr("CAST\\([^ ]+ AS FLOAT\\)", rendered))[[1]]
  literals <- gsub("CAST\\(|\\s*AS FLOAT\\)", "", literals)
  expect_identical(digits17(as.numeric(literals)),
                   digits17(quantileProbabilities(quantileCount)))
})
