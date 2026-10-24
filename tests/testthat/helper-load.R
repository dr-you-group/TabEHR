# The tests here need no database and no OHDSI packages, so they can also be
# run from a checkout where TabEHR is not installed: R CMD check loads the
# package, and otherwise the few files the tests touch are sourced.
if (!"TabEHR" %in% loadedNamespaces()) {
  for (file in c("SettingsObjects.R", "Dialects.R", "HelperFunctions.R",
                 "MeasurementQuantiles.R", "PersonSplit.R", "Export.R",
                 "Diagnostics.R", "CovariateTokens.R", "AllRecords.R",
                 "TaskInput.R", "Main.R")) {
    source(file.path("..", "..", "R", file))
  }
}

# 17 significant digits round-trips a double exactly, so comparing the text is
# comparing the bits.
digits17 <- function(x) vapply(x, function(v) sprintf("%.17g", v), "")

# Ids that a double cannot hold: the last digits are what would be lost.
testPersonIds <- function() {
  c("4672282447827634561", "4672282447827634562", "-7819202826128270750",
    "-7819202826128270751", "9007199254740993", "9007199254740994",
    sprintf("12345678901234567%02d", 10:99))
}
