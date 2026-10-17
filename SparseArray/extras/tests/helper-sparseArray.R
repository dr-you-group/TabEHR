# createSparseArray() and the time axis helpers live in
# extras/CreateSparseArray.R rather than in the package, so the tests source
# them. Run from the repository root:
#
#   testthat::test_dir("extras/tests")
#
script <- file.path("..", "CreateSparseArray.R")
if (!file.exists(script)) {
  script <- file.path("extras", "CreateSparseArray.R")
}
if (file.exists(script)) {
  source(script, local = globalenv())
}
