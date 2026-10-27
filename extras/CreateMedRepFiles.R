# The MedRep comparison files.
#
#   Rscript extras/CreateMedRepFiles.R <output folder> [databaseId] [quantileCount]
#
# The output folder may be the site folder the pipeline wrote, such as
# output/mimic, or the folder that holds the site folders, such as output, with
# the databaseId given as well or left to be discovered. Everything is written
# to <output folder>/<databaseId>/MedRep, next to the stage output it is built
# from, so an external site cannot overwrite the primary site's files.
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
#   * record_datetime is a date, not a timestamp, and a measurement is the last
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
# databaseId and quantileCount are told apart by shape rather than by position,
# so the call documented before this change, with the count second, still works.
databaseId <- Sys.getenv("TABEHR_DATABASE_ID", unset = "")
quantileCount <- 10L
for (argument in utils::tail(arguments, -1)) {
  if (grepl("^[0-9]+$", argument)) {
    quantileCount <- as.integer(argument)
  } else {
    databaseId <- argument
  }
}
stopifnot(dir.exists(outputFolder), quantileCount >= 1)

library(TabEHR)

# The site folder is the one that holds the extraction: given output/mimic it is
# that folder, and given output it is output/<databaseId>, or the only site
# folder there when no databaseId was given.
extractionFile <- function(folder) file.path(folder, "allRecordsCovariates.zip")
databaseFolder <- outputFolder
if (!file.exists(extractionFile(outputFolder))) {
  candidates <- if (nzchar(databaseId)) {
    file.path(outputFolder, databaseId)
  } else {
    list.dirs(outputFolder, recursive = FALSE)
  }
  candidates <- candidates[file.exists(extractionFile(candidates))]
  if (length(candidates) != 1) {
    stop("No single site folder with an extraction under ", outputFolder,
         ": found ", length(candidates),
         ". Give the site folder itself, or its databaseId as the second ",
         "argument.", call. = FALSE)
  }
  databaseFolder <- candidates[1]
}
if (!nzchar(databaseId)) {
  databaseId <- basename(databaseFolder)
}

andromedaFile <- extractionFile(databaseFolder)
cohortFile <- file.path(databaseFolder, "allrecords_cohort.csv")
splitFile <- file.path(databaseFolder, "person_split.csv")
crosswalkFile <- file.path(databaseFolder, "measurementValueUnitRef.csv")
for (file in c(andromedaFile, cohortFile, splitFile, crosswalkFile)) {
  if (!file.exists(file)) {
    stop("Run createAllRecords() and createPersonSplit() first: ", file,
         " is missing.", call. = FALSE)
  }
}
medRepFolder <- file.path(databaseFolder, "MedRep")
dir.create(medRepFolder, recursive = TRUE, showWarnings = FALSE)
cat("database:", databaseId, "\noutput folder:", medRepFolder, "\n")

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

# A covariate id is read, never computed: covariateRef names the concept and
# measurementValueUnitRef.csv names the unit, because the id itself keeps the
# unit only modulo 1000. This is the map createAllRecords() builds, reused here
# so that the two outputs cannot key a record differently. A covariate id that
# two units share comes back with no unit, which the pair filter below drops.
map <- TabEHR:::.allRecordsCovariateMap(covariateData, databaseFolder)
# Andromeda hands 64 bit ids back as bit64::integer64, while the crosswalk, the
# quantile table and the CSV output hold plain numbers, so every join between
# the two goes through the decimal text of an id rather than its bits.
idText <- function(x) format(x, scientific = FALSE, trim = TRUE)
valueAnalysisId <- 998
measurement <- map[map$analysisId == valueAnalysisId, ]
if (nrow(measurement) == 0) {
  stop("The extraction holds no analysis ", valueAnalysisId,
       " covariate, so there is nothing to bin.", call. = FALSE)
}

Andromeda::createIndex(covariateData$covariates, "covariateId")
# Namespaced rather than piped: TabEHR imports the pipe and the .data pronoun
# without exporting them, so a script that attached only TabEHR would not have
# them.
counts <- dplyr::collect(dplyr::summarise(
  dplyr::group_by(covariateData$covariates, rlang::.data$covariateId),
  n = dplyr::n()
))
measurement$n <- counts$n[match(idText(measurement$covariateId),
                                idText(counts$covariateId))]
measurement$n[is.na(measurement$n)] <- 0

# MedRep's filters: a pair needs enough numeric records to be worth binning,
# and an unmapped unit is not a pair at all. unitConceptId is NA already for a
# covariate whose unit is ambiguous, see resolveCovariateId().
minConceptUnitCount <- 10
keep <- measurement$n >= minConceptUnitCount &
  !is.na(measurement$unitConceptId) &
  measurement$unitConceptId != 0
cat(sprintf("quantiles for %d of %d (concept, unit) pair(s): n >= %d, unit mapped\n",
            sum(keep), nrow(measurement), minConceptUnitCount))
if (sum(keep) == 0) {
  stop("No (concept, unit) pair passes MedRep's filters, so no measurement ",
       "could be binned. Check that ", basename(crosswalkFile),
       " belongs to this extraction.", call. = FALSE)
}

probabilities <- (seq(0, 1, length.out = quantileCount + 1) * 100) / 100
columns <- paste0("quantile_", seq_len(quantileCount + 1) - 1)
quantiles <- vector("list", sum(keep))
kept <- measurement[keep, ]
for (i in seq_len(nrow(kept))) {
  # The id goes into the SQL as decimal text: an integer64 cannot be passed
  # through dbplyr, and a double this large would be formatted in scientific
  # notation.
  values <- DBI::dbGetQuery(
    covariateData,
    paste0("SELECT covariateValue FROM covariates WHERE covariateId = ",
           idText(kept$covariateId[i]))
  )
  # type = 7 is R's default and pandas linear interpolation.
  boundaries <- stats::quantile(values$covariateValue, probs = probabilities,
                                type = 7, names = FALSE, na.rm = TRUE)
  # Plain numbers, not integer64: a concept id, a unit id and a count all fit
  # in a double exactly, and rbind() over 64 bit integer columns is where the
  # class is easiest to lose.
  row <- data.frame(
    measurement_concept_id = as.numeric(kept$conceptId[i]),
    unit_concept_id = as.numeric(kept$unitConceptId[i]),
    n = as.numeric(kept$n[i]),
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
map$quantileRow <- match(
  paste(idText(map$conceptId), idText(map$unitConceptId), sep = "|"),
  paste(idText(quantileTable$measurement_concept_id),
        idText(quantileTable$unit_concept_id), sep = "|")
)
boundaryMatrix <- as.matrix(quantileTable[, columns])

file <- file.path(medRepFolder, "allrecords.csv.gz")
out <- gzfile(file, open = "wt")
writeLines("person_id,domain,concept_id,record_datetime", out)
written <- 0
rows <- dplyr::arrange(covariateData$covariates, rlang::.data$rowId,
                       rlang::.data$timeId, rlang::.data$covariateId)
tryCatch(
  Andromeda::batchApply(
    rows,
    function(batch) {
      covariate <- match(batch$covariateId, map$covariateId)
      # The row ids are small, so their text is the same whether or not
      # Andromeda and the CSV agree on the type.
      patient <- match(as.character(batch$rowId), as.character(cohort$rowId))
      if (anyNA(covariate) || anyNA(patient)) {
        stop("The extraction holds ", sum(is.na(covariate)), " covariate ",
             "id(s) that covariateRef does not name and ", sum(is.na(patient)),
             " row id(s) the cohort does not hold.", call. = FALSE)
      }
      quantileRow <- map$quantileRow[covariate]
      bin <- rep(NA_integer_, nrow(batch))
      hasBin <- !is.na(quantileRow)
      if (any(hasBin)) {
        bin[hasBin] <- assignQuantileBin(
          batch$covariateValue[hasBin],
          boundaryMatrix[quantileRow[hasBin], , drop = FALSE]
        )
      }
      concept <- idText(map$conceptId[covariate])
      out_rows <- data.frame(
        person_id = cohort$personId[patient],
        domain = map$domain[covariate],
        concept_id = ifelse(is.na(bin), concept, paste0(concept, "_", bin)),
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
  paste0("Written by `extras/CreateMedRepFiles.R` from the `allrecords` of ",
         databaseId, ", in the column set of"),
  "MedRep's own `create_trajectory.py` output. Two differences from the",
  "original are deliberate:",
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
