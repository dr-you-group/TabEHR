# Build a CovariateData object straight from Andromeda.
#
# FeatureExtraction::createEmptyCovariateData() is not exported by every
# supported FeatureExtraction version, and its signature has changed, so the
# tests assemble the object the same way FeatureExtraction itself does: an
# Andromeda with the expected tables, relabelled as CovariateData.
newTestCovariateData <- function(covariates,
                                 covariateRef,
                                 timeRef = NULL,
                                 analysisRef = NULL) {
  loadNamespace("FeatureExtraction")
  if (is.null(analysisRef)) {
    analysisRef <- data.frame(
      analysisId = 1L,
      analysisName = "test",
      domainId = "test",
      isBinary = "Y",
      missingMeansZero = "Y",
      stringsAsFactors = FALSE
    )
  }
  tables <- list(
    covariates = covariates,
    covariateRef = covariateRef,
    analysisRef = analysisRef
  )
  if (!is.null(timeRef)) {
    tables$timeRef <- timeRef
  }
  covariateData <- do.call(Andromeda::andromeda, tables)
  attr(covariateData, "metaData") <- list(cohortId = -1)
  class(covariateData) <- "CovariateData"
  attr(class(covariateData), "package") <- "FeatureExtraction"
  covariateData
}

saveTestCovariateData <- function(outputFolder, ...) {
  covariateData <- newTestCovariateData(...)
  FeatureExtraction::saveCovariateData(
    covariateData,
    file.path(outputFolder, "covariateData")
  )
  Andromeda::close(covariateData)
  invisible(NULL)
}

testCovariateRef <- function() {
  data.frame(
    covariateId = c(300, 100, 200, 8507),
    covariateName = c("three hundred", "one hundred", "two hundred", "male"),
    analysisId = c(1L, 1L, 1L, 1L),
    conceptId = c(300, 100, 200, 8507),
    stringsAsFactors = FALSE
  )
}

# Five observations over three patients, two covariates sharing a cell so that
# duplicate coordinates have to be summed, plus an optional covariate without a
# timeId. `timeIds` supplies the timeId of each of the five rows.
testCovariates <- function(timeIds, includeStatic = FALSE) {
  covariates <- data.frame(
    cohortDefinitionId = rep(1L, 5),
    rowId = c(20, 10, 20, 10, 30),
    covariateId = c(300, 200, 100, 200, 300),
    covariateValue = c(1.5, 2, 3, 4, 5),
    timeId = as.integer(timeIds)
  )
  if (includeStatic) {
    covariates <- rbind(covariates, data.frame(
      cohortDefinitionId = 1L,
      rowId = 10,
      covariateId = 8507,
      covariateValue = 1,
      timeId = NA_integer_
    ))
  }
  covariates
}
