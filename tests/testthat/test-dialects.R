test_that("every supported dialect has an hour expression, fully substituted", {
  for (dialect in supportedDialects()) {
    hour <- hourOfDaySql(dialect, "M.measurement_datetime")
    expect_true(nzchar(hour), info = dialect)
    expect_false(grepl("%s", hour, fixed = TRUE), info = dialect)
    expect_match(hour, "measurement_datetime", fixed = TRUE)
  }
})

test_that("sql server gets the native function", {
  expect_identical(hourOfDaySql("sql server", "M.x"), "DATEPART(HOUR, M.x)")
  expect_identical(hourOfDaySql("postgresql", "M.x"), "EXTRACT(HOUR FROM M.x)")
})

test_that("an unsupported dialect fails loudly", {
  # Silence would mean shipping SQL the engine cannot run: SqlRender leaves
  # DATEPART untranslated rather than erroring.
  expect_error(hourOfDaySql("db2", "M.x"), "Dialects.R")
})

test_that("the hour of day is the only dialect specific expression left", {
  # The measurement value now comes from value_as_number, so the TRY_CAST
  # stand-in this package used to carry is gone.
  expect_false(exists("numericValueSql", mode = "function"))
})
