# The tests that need no database and no OHDSI package can also be run from a
# checkout where SparseArray is not installed: R CMD check loads the package,
# and otherwise the files whose functions the tests reach are sourced. The
# tests that do need FeatureExtraction, Andromeda or ParallelLogger skip
# themselves.
if (!"SparseArray" %in% loadedNamespaces()) {
  for (file in c("Settings.R", "MeasurementValueUnit.R", "extractPlpData.R",
                 "createLongFormat.R")) {
    source(file.path("..", "..", "R", file))
  }
}

# The packaged SQL, from the checkout or from the installed package.
packagedSql <- function(name) {
  path <- file.path("..", "..", "inst", "sql", "sql_server", name)
  if (!file.exists(path)) {
    path <- system.file("sql", "sql_server", name, package = "SparseArray")
  }
  readChar(path, file.info(path)$size)
}
