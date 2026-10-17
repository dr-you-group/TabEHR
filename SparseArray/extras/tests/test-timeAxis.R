sequenceTimeRef <- function(timePart = "day",
                            timeInterval = 30L,
                            sequenceStartDay = -359L,
                            sequenceEndDay = -1L) {
  data.frame(
    timePart = timePart,
    timeInterval = as.integer(timeInterval),
    sequenceStartDay = as.integer(sequenceStartDay),
    sequenceEndDay = as.integer(sequenceEndDay),
    stringsAsFactors = FALSE
  )
}

test_that("a daily sequence axis follows from the settings alone", {
  timeMap <- .createTimeMap(
    sequenceTimeRef(),
    observedTimeIds = c(0L, 3L, 11L)
  )

  # timeId counts 30-day intervals back from the index date and is kept as
  # extracted, so the twelve positions run 0 (ending the day before the index
  # date) to 11 (oldest).
  expect_identical(timeMap$timeId, 0:11)
  expect_identical(timeMap$timeIndex, 1:12)
  expect_identical(timeMap$startDay[1], -29L)
  expect_identical(timeMap$endDay[1], -1L)
  expect_identical(timeMap$startDay[12], -359L)
  expect_identical(timeMap$endDay[12], -330L)
  expect_identical(timeMap$unitsBeforeIndexStart, as.integer(seq(0, 330, 30)))

  timeAxis <- attr(timeMap, "timeAxis")
  expect_identical(timeAxis$type, "sequence")
  expect_identical(timeAxis$timePart, "day")
  expect_identical(timeAxis$timeInterval, 30L)
  expect_true(timeAxis$exact)
  expect_identical(timeAxis$length, 12L)
  expect_identical(timeAxis$timeIndexOrder, "timeId")
  expect_identical(timeAxis$firstTimeId, 0L)
  expect_identical(timeAxis$lastTimeId, 11L)
})

test_that("a daily sequence axis is independent of the observed data", {
  withData <- .createTimeMap(
    sequenceTimeRef(timeInterval = 1L, sequenceStartDay = -14L),
    observedTimeIds = c(1L, 14L)
  )
  withoutData <- .createTimeMap(
    sequenceTimeRef(timeInterval = 1L, sequenceStartDay = -14L),
    observedTimeIds = integer()
  )

  expect_identical(withData$timeId, 1:14)
  expect_identical(withData$startDay, withData$endDay)
  expect_equal(withoutData, withData)
})

test_that("a sequence window reaching the index date keeps day 0", {
  timeMap <- .createTimeMap(
    sequenceTimeRef(sequenceStartDay = -29L, sequenceEndDay = 0L),
    observedTimeIds = 0L
  )

  expect_identical(nrow(timeMap), 1L)
  expect_identical(timeMap$timeId, 0L)
  expect_identical(timeMap$startDay, -29L)
  expect_identical(timeMap$endDay, 0L)
})

test_that("a monthly sequence axis spans the observed positions", {
  timeRef <- sequenceTimeRef(
    timePart = "month",
    timeInterval = 1L,
    sequenceStartDay = -730L
  )
  timeMap <- .createTimeMap(
    timeRef,
    observedTimeIds = c(0L, 5L, 23L)
  )

  # DATEDIFF counts calendar boundaries, so the settings only bound the axis.
  # The positions are the contiguous run of observed ones, and day offsets
  # cannot be reported.
  expect_identical(timeMap$timeId, 0:23)
  expect_identical(timeMap$timeIndex, 1:24)
  expect_true(all(is.na(timeMap$startDay)))
  expect_true(all(is.na(timeMap$endDay)))
  expect_false(attr(timeMap, "timeAxis")$exact)

  expect_error(
    .createTimeMap(timeRef, observedTimeIds = integer()),
    "no observed timeId"
  )
})

test_that("observed timeIds outside the settings are rejected", {
  expect_error(
    .createTimeMap(
      sequenceTimeRef(),
      observedTimeIds = c(0L, 12L)
    ),
    "outside the range the sequence settings allow \\(0 to 11\\)"
  )
  expect_error(
    .createTimeMap(
      sequenceTimeRef(timePart = "month", timeInterval = 1L),
      observedTimeIds = 999L
    ),
    "outside the range the sequence settings allow"
  )
})

test_that("malformed timeRef tables are reported", {
  expect_error(
    .createTimeMap(
      sequenceTimeRef(timePart = "week", timeInterval = 1L),
      observedTimeIds = 0L
    ),
    "Unsupported timePart"
  )
  expect_error(
    .createTimeMap(
      sequenceTimeRef(timeInterval = 0L),
      observedTimeIds = 0L
    ),
    "timeInterval in timeRef must be a positive whole number"
  )
  expect_error(
    .createTimeMap(
      sequenceTimeRef(sequenceStartDay = -1L, sequenceEndDay = -30L),
      observedTimeIds = 0L
    ),
    "must not be after sequenceEndDay"
  )
  expect_error(
    .createTimeMap(
      rbind(sequenceTimeRef(), sequenceTimeRef()),
      observedTimeIds = 0L
    ),
    "exactly one row"
  )
  expect_error(
    .createTimeMap(data.frame(nonsense = 1), observedTimeIds = 1L),
    "none of the expected columns"
  )
})

test_that("a window axis is ordered chronologically and covers every window", {
  timeMap <- .createTimeMap(
    data.frame(
      timeId = c(1L, 2L, 3L),
      startDay = c(-60, -30, -90),
      endDay = c(-31, -1, -61)
    ),
    observedTimeIds = c(1L, 2L)
  )

  expect_identical(timeMap$timeId, c(3L, 1L, 2L))
  expect_identical(timeMap$timeIndex, 1:3)
  expect_equal(timeMap$startDay, c(-90, -60, -30))
  expect_identical(names(timeMap)[1:2], c("timeId", "timeIndex"))
  expect_identical(attr(timeMap, "timeAxis")$type, "window")
  expect_identical(attr(timeMap, "timeAxis")$timeIndexOrder, "startDay")

  expect_error(
    .createTimeMap(
      data.frame(timeId = c(1L, 1L), startDay = c(-1, -2), endDay = c(-1, -2)),
      observedTimeIds = 1L
    ),
    "must be unique"
  )
  expect_error(
    .createTimeMap(
      data.frame(timeId = integer(), startDay = numeric(), endDay = numeric()),
      observedTimeIds = integer()
    ),
    "timeRef table is empty"
  )
})

test_that("the time axis is described for the log", {
  expect_match(
    .describeTimeAxis(
      attr(.createTimeMap(sequenceTimeRef(), 0L), "timeAxis")
    ),
    "^12 sequence position\\(s\\) of 30 day\\(s\\).*time index 1 is timeId 0"
  )
  expect_match(
    .describeTimeAxis(list(type = "window", length = 4L)),
    "^4 time window\\(s\\), ordered by startDay"
  )
})
