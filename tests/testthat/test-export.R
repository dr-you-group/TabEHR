test_that("dates and timestamps are written in the agreed formats", {
  formatted <- .formatForCsv(data.frame(
    d = as.Date("2260-12-31"),
    t = as.POSIXct("2100-05-06 07:08:09", tz = "UTC"),
    stringsAsFactors = FALSE
  ))
  expect_identical(formatted$d, "2260-12-31")
  expect_identical(formatted$t, "2100-05-06 07:08:09")
})

test_that("a 19 digit id and a comma in a value both survive the CSV", {
  skip_if_not_installed("ParallelLogger")
  path <- file.path(tempdir(), "tabehr-test.csv")
  on.exit(unlink(path), add = TRUE)
  writeTabehrCsv(
    data.frame(person_id = "4672282447827634561",
               unit = "mg/dL, total", stringsAsFactors = FALSE),
    path
  )
  back <- utils::read.csv(path, colClasses = "character")

  expect_identical(back$person_id, "4672282447827634561")
  expect_identical(back$unit, "mg/dL, total")
})

test_that("a numeric person_id column is refused rather than written", {
  # A BIGINT that reached R as a double has already lost its last digits, so
  # the only safe thing is to fail where it is noticed.
  expect_error(
    .assertCharacterIds(data.frame(person_id = 4672282447827634561),
                        "person_id"),
    "CAST"
  )
  expect_identical(
    .assertCharacterIds(data.frame(person_id = "4672282447827634561",
                                   stringsAsFactors = FALSE),
                        "person_id")$person_id,
    "4672282447827634561"
  )
})

test_that("the report renders a markdown table", {
  markdown <- .markdownTable(
    data.frame(a = c(1, 2), b = c("x", NA), stringsAsFactors = FALSE)
  )
  lines <- strsplit(markdown, "\n")[[1]]

  expect_length(lines, 4)
  expect_identical(lines[1], "| a | b |")
  expect_identical(.markdownTable(NULL), "_(no rows)_")
})

test_that("report metrics preserve integer64 counts", {
  skip_if_not_installed("bit64")
  metrics <- data.frame(
    n_person = bit64::as.integer64("317878"),
    n_large = bit64::as.integer64("9007199254740993"),
    note = "checked",
    stringsAsFactors = FALSE
  )
  expect_identical(
    .asMetricTable(metrics),
    data.frame(
      metric = c("n_person", "n_large", "note"),
      value = c("317878", "9007199254740993", "checked"),
      stringsAsFactors = FALSE
    )
  )
})

test_that("a streamed file gets snake_case headers", {
  # The rows arrive from Andromeda in camelCase, but every file this project
  # writes uses the OMOP and MedRep column names.
  expect_identical(
    .csvHeader(c("personId", "domain", "conceptId", "recordDatetime")),
    "person_id,domain,concept_id,record_datetime"
  )
  expect_identical(.csvHeader("nRecords"), "n_records")
})
