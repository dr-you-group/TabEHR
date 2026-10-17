library(SparseArray)

outputFolder <- Sys.getenv("SPARSE_ARRAY_OUTPUT_FOLDER")

longFile <- file.path(outputFolder, "featureExtractionLong.csv")
sparseArrayFile <- file.path(outputFolder, "sparseArray.rds")

# ---------------------------------------------------------------------------
# Long-format FeatureExtraction output
# ---------------------------------------------------------------------------
cat("\nFeatureExtraction long-format CSV:\n")
print(data.frame(
  file = normalizePath(longFile),
  sizeMb = round(file.size(longFile) / 1024^2, 1)
))
cat("\nFirst 10 patient-covariate-time rows:\n")
print(utils::read.csv(longFile, nrows = 10))

# ---------------------------------------------------------------------------
# Three-dimensional sparse array
# ---------------------------------------------------------------------------
result <- readRDS(sparseArrayFile)
dims <- dim(result$dataArray)

stopifnot(
  inherits(result$dataArray, "simple_sparse_array"),
  length(dims) == 3L,
  dims[1] == nrow(result$labels),
  dims[2] == nrow(result$timeMap),
  dims[3] == nrow(result$covariateMap),
  nrow(result$covariateRef) == nrow(result$covariateMap),
  identical(result$timeMap$timeIndex, seq_len(dims[2])),
  result$timeAxis$length == dims[2],
  all(is.finite(result$dataArray$v)),
  all(result$dataArray$i[, 1] >= 1L & result$dataArray$i[, 1] <= dims[1]),
  all(result$dataArray$i[, 2] >= 1L & result$dataArray$i[, 2] <= dims[2]),
  all(result$dataArray$i[, 3] >= 1L & result$dataArray$i[, 3] <= dims[3]),
  !anyDuplicated(result$dataArray$i)
)

cat("\nSparse array created successfully:\n")
print(data.frame(
  file = normalizePath(sparseArrayFile),
  patients = dims[1],
  timePositions = dims[2],
  covariates = dims[3],
  nonzero = length(result$dataArray$v),
  density = signif(length(result$dataArray$v) / prod(as.numeric(dims)), 3)
))

# ---------------------------------------------------------------------------
# Time axis
#
# Temporal sequence extractions describe the axis as a repeated interval counted
# back from the index date; temporal window extractions describe it as a list of
# requested windows. timeAxis$timeIndexOrder says which rule assigned timeIndex:
# "timeId" keeps the extracted order, so for a lookback window position 1 is
# nearest the index date; "startDay" puts the oldest window first.
# ---------------------------------------------------------------------------
cat("\nTime axis (", result$timeAxis$type, ", ordered by ",
    result$timeAxis$timeIndexOrder, "):\n", sep = "")
utils::str(result$timeAxis)
print(utils::head(result$timeMap, 20))

if (identical(result$timeAxis$type, "sequence") &&
    !isTRUE(result$timeAxis$exact)) {
  cat(
    "\nNote: timePart is '", result$timeAxis$timePart, "', so the server counts",
    " calendar boundaries and the axis spans the observed sequence positions",
    " rather than a grid fixed by the settings alone.\n",
    sep = ""
  )
}

if (!is.null(result$staticCovariateRef)) {
  cat("\nCovariates dropped because they have no timeId:\n")
  print(result$staticCovariateRef)
}

cat("\nNonzero entries per time position:\n")
print(data.frame(
  timeIndex = seq_len(dims[2]),
  timeId = result$timeMap$timeId,
  startDay = result$timeMap$startDay,
  endDay = result$timeMap$endDay,
  nonzero = tabulate(result$dataArray$i[, 2], nbins = dims[2])
))

# ---------------------------------------------------------------------------
# Feeding a sequence model
#
# The array is patient x time x covariate, which is the (samples, timesteps,
# features) layout Keras expects. Convert one batch of patients at a time; the
# full dense array is normally far too large to materialize.
# ---------------------------------------------------------------------------
denseBatch <- function(sparseArray, rowIndices) {
  dims <- dim(sparseArray)
  batch <- array(0, dim = c(length(rowIndices), dims[2], dims[3]))
  position <- match(sparseArray$i[, 1], rowIndices)
  keep <- !is.na(position)
  if (any(keep)) {
    batch[cbind(
      position[keep],
      sparseArray$i[keep, 2],
      sparseArray$i[keep, 3]
    )] <- sparseArray$v[keep]
  }
  batch
}

previewRows <- seq_len(min(5, dims[1]))
preview <- denseBatch(result$dataArray, previewRows)
previewCovariates <- seq_len(min(5, dims[3]))
cat("\nDense preview for the first", length(previewRows), "patients",
    "(time x covariate, first", length(previewCovariates), "covariates):\n")
for (i in seq_along(previewRows)) {
  cat("\npatient rowId ", result$labels$rowId[previewRows[i]],
      " (originalRowId ", result$labels$originalRowId[previewRows[i]], "):\n",
      sep = "")
  print(preview[i, , previewCovariates, drop = TRUE])
}
