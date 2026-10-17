# The MedRep comparison files.
#
#   Rscript extras/CreateMedRepFiles.R <output folder> [quantileCount]
#
# MedRep is the comparison embedding, so its preprocessing has to be
# reproducible from this project's data. It is not part of the pipeline: the
# pipeline's own output keeps raw values (see R/AllRecords.R), and everything
# MedRep-specific happens here.
#
# What this applies, and nothing else does:
#
#   * the (concept, unit) pair threshold and the unit_concept_id <> 0 rule,
#     which are MedRep's filters for a measurement worth binning
#   * the quantile boundaries, computed over every patient in allrecords, as
#     MedRep computes them over every patient before splitting
#   * the <concept_id>_<bin> suffix
#
# How it differs from the original, on purpose:
#
#   * record_date is a date, not a timestamp, and a measurement is the last
#     value of its day rather than one per hour. That is FeatureExtraction's
#     rule, which this project adopted so that allrecords and the downstream
#     task inputs cannot disagree
#   * a numeric measurement with no mapped unit survives as a record here,
#     with no suffix, where the original dropped it
#
# Both of those are written into MedRep/README.md next to the output.

arguments <- commandArgs(trailingOnly = TRUE)
outputFolder <- if (length(arguments) >= 1) arguments[1] else
  Sys.getenv("TABEHR_OUTPUT_FOLDER", unset = "output")
quantileCount <- if (length(arguments) >= 2) as.integer(arguments[2]) else 10L
stopifnot(dir.exists(outputFolder), quantileCount >= 1)

library(TabEHR)
andromedaFile <- file.path(outputFolder, "allRecordsCovariates.zip")
cohortFile <- file.path(outputFolder, "allrecords_cohort.csv")
splitFile <- file.path(outputFolder, "person_split.csv")
for (file in c(andromedaFile, cohortFile, splitFile)) {
  if (!file.exists(file)) {
    stop("Run createAllRecords() and createPersonSplit() first: ", file,
         " is missing.", call. = FALSE)
  }
}
medRepFolder <- file.path(outputFolder, "MedRep")
dir.create(medRepFolder, recursive = TRUE, showWarnings = FALSE)

# ---------------------------------------------------------------------------
# 1. The split, in MedRep's three files. 70:15:15 was chosen to line up with
#    its own split: pretraining trains on train, validates on valid, and the
#    downstream patients are the ones it never saw.
# ---------------------------------------------------------------------------
split <- read.csv(splitFile, colClasses = c(person_id = "character"))
groups <- list(
  train_id = split$person_id[split$stage == "pretrain" &
                               split$split == "train"],
  valid_id = split$person_id[split$stage == "pretrain" &
                               split$split == "valid"],
  test_id = split$person_id[split$stage == "downstream"]
)
for (name in names(groups)) {
  file <- file.path(medRepFolder, paste0(name, ".csv"))
  write.csv(data.frame(person_id = groups[[name]]), file, row.names = FALSE,
            quote = FALSE)
  cat(sprintf("%-12s %8d patient(s) -> %s\n", name, length(groups[[name]]),
              file))
}

# ---------------------------------------------------------------------------
# 2. The quantile table, from allrecords.
# ---------------------------------------------------------------------------
covariateData <- Andromeda::loadAndromeda(andromedaFile)
on.exit(Andromeda::close(covariateData), add = TRUE)
cohort <- read.csv(cohortFile, colClasses = c(person_id = "character"))
names(cohort) <- SqlRender::snakeCaseToCamelCase(names(cohort))
cohort$indexDate <- as.Date(cohort$indexDate)

reference <- dplyr::collect(covariateData$covariateRef)
crosswalk <- read.csv(file.path(outputFolder, "measurementValueUnitRef.csv"))
valueAnalysisId <- 998
measurement <- reference[reference$analysisId == valueAnalysisId, ]
unit <- resolveCovariateUnit(
  measurement$covariateId,
  data.frame(
    covariateId = crosswalk$covariateId,
    analysisId = valueAnalysisId,
    conceptId = crosswalk$conceptId,
    unitConceptId = crosswalk$unitConceptId
  )
)
measurement$unitConceptId <- unit$unitConceptId
measurement$unitAmbiguous <- unit$unitAmbiguous

Andromeda::createIndex(covariateData$covariates, "covariateId")
counts <- covariateData$covariates %>%
  dplyr::filter(.data$covariateId %in% !!measurement$covariateId) %>%
  dplyr::group_by(.data$covariateId) %>%
  dplyr::summarise(n = dplyr::n()) %>%
  dplyr::collect()
measurement$n <- counts$n[match(measurement$covariateId, counts$covariateId)]
measurement$n[is.na(measurement$n)] <- 0

# MedRep's filters: a pair needs enough numeric records to be worth binning,
# and an unmapped unit is not a pair at all.
minConceptUnitCount <- 10
keep <- measurement$n >= minConceptUnitCount &
  !is.na(measurement$unitConceptId) &
  measurement$unitConceptId != 0 &
  !measurement$unitAmbiguous
cat(sprintf("quantiles for %d of %d (concept, unit) pair(s): n >= %d, unit mapped\n",
            sum(keep), nrow(measurement), minConceptUnitCount))

probabilities <- (seq(0, 1, length.out = quantileCount + 1) * 100) / 100
columns <- paste0("quantile_", seq_len(quantileCount + 1) - 1)
quantiles <- vector("list", sum(keep))
kept <- measurement[keep, ]
for (i in seq_len(nrow(kept))) {
  id <- kept$covariateId[i]
  values <- covariateData$covariates %>%
    dplyr::filter(.data$covariateId == !!id) %>%
    dplyr::select("covariateValue") %>%
    dplyr::collect()
  # type = 7 is R's default and pandas' linear interpolation.
  boundaries <- stats::quantile(values$covariateValue, probs = probabilities,
                                type = 7, names = FALSE, na.rm = TRUE)
  row <- data.frame(
    measurement_concept_id = kept$conceptId[i],
    unit_concept_id = kept$unitConceptId[i],
    n = kept$n[i],
    basis = "all"
  )
  row[columns] <- as.list(boundaries)
  quantiles[[i]] <- row[c("measurement_concept_id", "unit_concept_id",
                          columns, "n", "basis")]
  if (i %% 500 == 0) {
    cat("  ", i, "of", nrow(kept), "\n")
  }
}
quantileTable <- do.call(rbind, quantiles)
write.csv(quantileTable, file.path(medRepFolder, "meas_quantiles.csv"),
          row.names = FALSE)
cat("wrote", nrow(quantileTable), "quantile row(s)\n")

# ---------------------------------------------------------------------------
# 3. allrecords in MedRep's shape: four columns, measurements suffixed with
#    their bin. A record whose pair has no quantile row keeps the bare concept
#    id, which is what the original does too.
# ---------------------------------------------------------------------------
map <- reference[, c("covariateId", "analysisId", "conceptId")]
domains <- c("101" = "cond", "301" = "drug", "501" = "proc", "998" = "meas",
             "999" = "meas")
map$domain <- unname(domains[as.character(map$analysisId)])
map$quantileRow <- match(
  paste(map$conceptId,
        measurement$unitConceptId[match(map$covariateId,
                                        measurement$covariateId)],
        sep = "|"),
  paste(quantileTable$measurement_concept_id, quantileTable$unit_concept_id,
        sep = "|")
)
boundaryMatrix <- as.matrix(quantileTable[, columns])

file <- file.path(medRepFolder, "allrecords.csv.gz")
out <- gzfile(file, open = "wt")
writeLines("person_id,domain,concept_id,record_datetime", out)
written <- 0
rows <- covariateData$covariates %>%
  dplyr::arrange(.data$rowId, .data$timeId, .data$covariateId)
tryCatch(
  Andromeda::batchApply(
    rows,
    function(batch) {
      covariate <- match(batch$covariateId, map$covariateId)
      patient <- match(batch$rowId, cohort$rowId)
      quantileRow <- map$quantileRow[covariate]
      bin <- rep(NA_integer_, nrow(batch))
      hasBin <- !is.na(quantileRow)
      if (any(hasBin)) {
        bin[hasBin] <- assignQuantileBin(
          batch$covariateValue[hasBin],
          boundaryMatrix[quantileRow[hasBin], , drop = FALSE]
        )
      }
      concept <- format(map$conceptId[covariate], scientific = FALSE,
                        trim = TRUE)
      out_rows <- data.frame(
        person_id = cohort$personId[patient],
        domain = map$domain[covariate],
        concept_id = ifelse(is.na(bin), concept,
                            paste0(concept, "_", bin)),
        record_datetime = format(cohort$indexDate[patient] - batch$timeId,
                                 "%Y-%m-%d"),
        stringsAsFactors = FALSE
      )
      write.table(out_rows, file = out, sep = ",", row.names = FALSE,
                  col.names = FALSE, quote = FALSE, na = "")
      written <<- written + nrow(out_rows)
    },
    batchSize = 1e6,
    progressBar = FALSE,
    safe = FALSE
  ),
  finally = close(out)
)
cat("wrote", written, "record(s) to", file, "\n")

writeLines(c(
  "# MedRep comparison files",
  "",
  "Written by `extras/CreateMedRepFiles.R` from this project's `allrecords`,",
  "in the column set of MedRep's own `create_trajectory.py` output. Two",
  "differences from the original are deliberate:",
  "",
  "- `record_datetime` holds a **date**, and a measurement is the last value",
  "  of its day. The original keeps one record per hour, with the time of day.",
  "  This project follows FeatureExtraction's rule so that `allrecords` and",
  "  the downstream task inputs cannot disagree about what a record is.",
  "- A numeric measurement whose unit is unmapped survives as a record, with",
  "  no bin suffix. The original drops it.",
  "",
  paste0("Quantiles: ", quantileCount, " bins over every patient in ",
         "allrecords, pairs with at least ", minConceptUnitCount,
         " numeric records and a mapped unit."),
  paste0("Patients: train ", length(groups$train_id), ", valid ",
         length(groups$valid_id), ", test ", length(groups$test_id), ".")
), file.path(medRepFolder, "README.md"))
cat("wrote", file.path(medRepFolder, "README.md"), "\n")
