# The split is the one thing in this package that has to be reproducible
# forever: pretraining and every downstream task read it.

test_that("the split is identical across runs and covers everyone once", {
  personIds <- testPersonIds()
  settings <- createAnalysisSettings()
  first <- assignPersonSplit(personIds, settings)
  second <- assignPersonSplit(personIds, settings)

  expect_identical(first, second)
  expect_equal(nrow(first), length(personIds))
  expect_false(any(duplicated(first$person_id)))
  expect_setequal(first$person_id, personIds)
})

test_that("no person_id loses a digit", {
  personIds <- testPersonIds()
  split <- assignPersonSplit(personIds, createAnalysisSettings())
  expect_type(split$person_id, "character")
  expect_identical(sort(split$person_id, method = "radix"),
                   sort(personIds, method = "radix"))
})

test_that("a downstream patient is never a pretraining patient", {
  split <- assignPersonSplit(testPersonIds(), createAnalysisSettings())
  expect_length(
    intersect(split$person_id[split$stage == "downstream"],
              split$person_id[split$stage == "pretrain"]),
    0
  )
})

test_that("the groups have the configured sizes", {
  personIds <- testPersonIds()
  settings <- createAnalysisSettings()
  split <- assignPersonSplit(personIds, settings)
  n <- nrow(split)
  sizes <- table(paste(split$stage, split$split))

  expect_length(sizes, 3)
  expect_equal(sizes[["pretrain train"]], floor(n * 0.70))
  expect_equal(sizes[["pretrain valid"]], floor(n * 0.85) - floor(n * 0.70))
  expect_equal(sizes[["downstream "]], n - floor(n * 0.85))
})

test_that("the seed is actually wired in", {
  personIds <- testPersonIds()
  other <- createAnalysisSettings(
    personSplitSettings = createPersonSplitSettings(seed = 51)
  )
  expect_false(identical(
    assignPersonSplit(personIds, createAnalysisSettings())$stage,
    assignPersonSplit(personIds, other)$stage
  ))
})

test_that("the sort is locale independent", {
  # sort() on character respects the locale by default, which would make the
  # split depend on the machine. assignPersonSplit() uses method = "radix".
  personIds <- c("10", "-2", "9007199254740993", "-7819202826128270750", "3")
  split <- assignPersonSplit(personIds, createAnalysisSettings())
  expect_identical(split$person_id, sort(personIds, method = "radix"))
})

test_that("an external site gets no split", {
  settings <- createAnalysisSettings(
    quantileSettings = createQuantileSettings(basis = "file",
                                              quantileFile = "q.csv"),
    siteRole = "external"
  )
  split <- assignPersonSplit(testPersonIds(), settings)
  expect_true(all(split$stage == "external"))
  expect_true(all(split$split == ""))
})

test_that("an empty population is an error, not an empty split", {
  expect_error(assignPersonSplit(character(0), createAnalysisSettings()),
               "nothing to split")
})

test_that("the summary counts the groups and finds no overlap", {
  split <- assignPersonSplit(testPersonIds(), createAnalysisSettings())
  summary <- summarisePersonSplit(split)

  expect_equal(nrow(summary), 5)
  expect_equal(summary$n_person[summary$stage == "TOTAL"], nrow(split))
  expect_equal(
    summary$n_person[summary$stage == "CHECK_person_in_two_groups"], 0
  )
  expect_equal(sum(summary$fraction[1:3]), 1, tolerance = 1e-6)
})
