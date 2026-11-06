# The MedRep comparison files.
#
#   Rscript extras/CreateMedRepFiles.R <output folder> [databaseId] [quantileCount] [key=value ...]
#
# MedRep is the comparison embedding, so its preprocessing has to be
# reproducible from this project's data. It is not part of the pipeline: the
# pipeline's own output keeps raw values (see R/AllRecords.R), and everything
# MedRep-specific happens here.
#
# The record stream is read from output/<databaseId>/allrecords.csv.gz rather
# than from the saved FeatureExtraction extraction it came out of. The CSV
# already holds what the conversion needs - person_id as text, concept_id,
# record_date, value_as_number and unit_concept_id - because
# createAllRecords() resolved all of it through the covariate map when it wrote
# the file. Reading it is a sequential scan, so this path does no ORDER BY over
# the whole covariate table (an external sort of every record in SQLite), no
# covariate-to-concept join and no per-row format(Date). What the MedRep
# conversion adds on top is the quantile suffix, and that needs only
# concept_id, unit_concept_id and value_as_number.
#
# What this applies, and nothing else does:
#
#   * the (concept, unit) pair threshold and the unit_concept_id <> 0 rule,
#     which are MedRep's filters for a measurement worth binning
#   * the quantile boundaries, computed over every patient in allrecords, as
#     MedRep computes them over every patient before splitting
#   * the <concept_id>_<bin> suffix
#
# The quantile table is still computed from the extraction when it is missing:
# a quantile needs every value of a (concept, unit) pair at once, which a
# sequential pass over the CSV cannot give without holding hundreds of millions
# of numbers in memory. An existing MedRep/meas_quantiles.csv is reused, which
# is also what makes a test run cheap.
#
# Options, as key=value arguments:
#
#   rows=N          convert only the first N rows, and write
#                   MedRep/allrecords-sample.csv.gz instead of the real file.
#                   Use this for a test run.
#   chunk=N         rows per chunk (default 1,000,000)
#   compression=N   gzip level of the output (default 6; 1 is about 2.6x
#                   faster and some 13% larger)
#   quantiles=path  quantile table to apply (default MedRep/meas_quantiles.csv)
#   recompute=TRUE  recompute the quantile table even if one is already there
#   split=FALSE     do not rewrite train/valid/test_id.csv
#
# How it differs from MedRep's original output is unchanged from the other
# script, and is written into MedRep/README.md next to the files.

arguments <- commandArgs(trailingOnly = TRUE)
outputFolder <- if (length(arguments) >= 1) arguments[1] else
  Sys.getenv("TABEHR_OUTPUT_FOLDER", unset = "output")
databaseId <- Sys.getenv("TABEHR_DATABASE_ID", unset = "")
quantileCount <- 10L
settings <- list(rows = NA_real_, chunk = 1e6, compression = 6L,
                 quantiles = "", recompute = FALSE, split = TRUE)
for (argument in utils::tail(arguments, -1)) {
  if (grepl("^[A-Za-z]+=", argument)) {
    name <- sub("=.*$", "", argument)
    value <- sub("^[^=]*=", "", argument)
    if (!name %in% names(settings)) {
      stop("Unknown option ", name, ". Known: ",
           paste(names(settings), collapse = ", "), ".", call. = FALSE)
    }
    settings[[name]] <- switch(
      name,
      rows = as.numeric(value),
      chunk = as.numeric(value),
      compression = as.integer(value),
      quantiles = value,
      recompute = as.logical(value),
      split = as.logical(value)
    )
  } else if (grepl("^[0-9]+$", argument)) {
    quantileCount <- as.integer(argument)
  } else {
    databaseId <- argument
  }
}
stopifnot(dir.exists(outputFolder), quantileCount >= 1,
          settings$chunk >= 1, !is.na(settings$compression),
          settings$compression >= 0, settings$compression <= 9,
          !is.na(settings$recompute), !is.na(settings$split))

library(TabEHR)

# allrecords is one file, or the parts streamQueryToCsv() names when a run was
# split per patient. Both are read in order.
recordFiles <- function(folder) {
  single <- file.path(folder, "allrecords.csv.gz")
  if (file.exists(single)) {
    return(single)
  }
  sort(Sys.glob(file.path(folder, "allrecords-[0-9]*.csv.gz")))
}

databaseFolder <- outputFolder
if (length(recordFiles(outputFolder)) == 0) {
  candidates <- if (nzchar(databaseId)) {
    file.path(outputFolder, databaseId)
  } else {
    list.dirs(outputFolder, recursive = FALSE)
  }
  candidates <- candidates[vapply(candidates,
                                  function(folder)
                                    length(recordFiles(folder)) > 0,
                                  logical(1))]
  if (length(candidates) != 1) {
    stop("No single site folder with an allrecords.csv.gz under ", outputFolder,
         ": found ", length(candidates),
         ". Give the site folder itself, or its databaseId as an argument.",
         call. = FALSE)
  }
  databaseFolder <- candidates[1]
}
if (!nzchar(databaseId)) {
  databaseId <- basename(databaseFolder)
}
inputFiles <- recordFiles(databaseFolder)
medRepFolder <- file.path(databaseFolder, "MedRep")
dir.create(medRepFolder, recursive = TRUE, showWarnings = FALSE)
sampleRun <- !is.na(settings$rows)
cat("database:     ", databaseId, "\n")
cat("allrecords:   ", paste(basename(inputFiles), collapse = ", "), "\n")
cat("output folder:", medRepFolder, "\n")
if (sampleRun) {
  cat("test run:      first", format(settings$rows, big.mark = ","),
      "row(s) only\n")
}

# The columns allrecords.csv.gz has, in order. Read as text except the value,
# so that no identifier passes through a double: a 19 digit person_id would
# lose its last digits, and a concept id would come back in scientific
# notation. The value is the only column arithmetic is done on.
recordColumns <- c("person_id", "domain", "concept_id", "record_date",
                   "value_as_number", "unit_concept_id")
recordClasses <- c("character", "character", "character", "character",
                   "numeric", "character")

# ---------------------------------------------------------------------------
# 1. The split, in MedRep's three files.
# ---------------------------------------------------------------------------
groups <- list(train_id = character(0), valid_id = character(0),
               test_id = character(0))
splitFile <- file.path(databaseFolder, "person_split.csv")
if (!file.exists(splitFile)) {
  cat("no person_split.csv, so train/valid/test_id.csv are left alone\n")
} else {
  split <- read.csv(splitFile, colClasses = c(person_id = "character"))
  groups <- list(
    train_id = split$person_id[split$stage == "pretrain" &
                                 split$split == "train"],
    valid_id = split$person_id[split$stage == "pretrain" &
                                 split$split == "valid"],
    test_id = split$person_id[split$stage == "downstream"]
  )
  if (settings$split) {
    for (name in names(groups)) {
      file <- file.path(medRepFolder, paste0(name, ".csv"))
      write.csv(data.frame(person_id = groups[[name]]), file,
                row.names = FALSE, quote = FALSE)
      cat(sprintf("%-12s %8d patient(s) -> %s\n", name,
                  length(groups[[name]]), file))
    }
  }
}

# ---------------------------------------------------------------------------
# 2. The quantile table. Reused when it is already there, because this is the
#    expensive half and it does not change between conversion runs.
# ---------------------------------------------------------------------------
# The same computation extras/CreateMedRepFiles.R does: MedRep's filters over
# the (concept, unit) pairs of the extraction, then one pass per pair.
computeQuantiles <- function(quantileFile) {
  andromedaFile <- file.path(databaseFolder, "allRecordsCovariates.zip")
  crosswalkFile <- file.path(databaseFolder, "measurementValueUnitRef.csv")
  for (file in c(andromedaFile, crosswalkFile)) {
    if (!file.exists(file)) {
      stop("A quantile table has to be computed from the extraction, and ",
           file, " is missing. Point quantiles= at an existing table instead.",
           call. = FALSE)
    }
  }
  covariateData <- Andromeda::loadAndromeda(andromedaFile)
  on.exit(Andromeda::close(covariateData), add = TRUE)

  # covariateRef names the concept, measurementValueUnitRef.csv names the unit:
  # the covariate id keeps the unit only modulo 1000, so neither is computed
  # from it. This is the map createAllRecords() used to write allrecords.csv.gz.
  map <- TabEHR:::.allRecordsCovariateMap(covariateData, databaseFolder)
  idText <- function(x) format(x, scientific = FALSE, trim = TRUE)
  valueAnalysisId <- 998
  measurement <- map[map$analysisId == valueAnalysisId, ]
  if (nrow(measurement) == 0) {
    stop("The extraction holds no analysis ", valueAnalysisId,
         " covariate, so there is nothing to bin.", call. = FALSE)
  }

  Andromeda::createIndex(covariateData$covariates, "covariateId")
  counts <- dplyr::collect(dplyr::summarise(
    dplyr::group_by(covariateData$covariates, rlang::.data$covariateId),
    n = dplyr::n()
  ))
  measurement$n <- counts$n[match(idText(measurement$covariateId),
                                  idText(counts$covariateId))]
  measurement$n[is.na(measurement$n)] <- 0

  # MedRep's filters: a pair needs enough numeric records to be worth binning,
  # and an unmapped unit is not a pair at all. unitConceptId is NA already for
  # a covariate id that two units share.
  minConceptUnitCount <- 10
  keep <- measurement$n >= minConceptUnitCount &
    !is.na(measurement$unitConceptId) &
    measurement$unitConceptId != 0
  cat(sprintf("quantiles for %d of %d (concept, unit) pair(s): n >= %d, unit mapped\n",
              sum(keep), nrow(measurement), minConceptUnitCount))
  if (sum(keep) == 0) {
    stop("No (concept, unit) pair passes MedRep's filters.", call. = FALSE)
  }

  probabilities <- (seq(0, 1, length.out = quantileCount + 1) * 100) / 100
  columns <- paste0("quantile_", seq_len(quantileCount + 1) - 1)
  kept <- measurement[keep, ]
  rows <- vector("list", nrow(kept))
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
    boundaries <- stats::quantile(values$covariateValue,
                                  probs = probabilities, type = 7,
                                  names = FALSE, na.rm = TRUE)
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
    rows[[i]] <- row[c("measurement_concept_id", "unit_concept_id", columns,
                       "n", "basis")]
    if (i %% 500 == 0) {
      cat("  ", i, "of", nrow(kept), "\n")
    }
  }
  write.csv(do.call(rbind, rows), quantileFile, row.names = FALSE)
  cat("wrote", nrow(kept), "quantile row(s) to", quantileFile, "\n")
}

quantileFile <- if (nzchar(settings$quantiles)) settings$quantiles else
  file.path(medRepFolder, "meas_quantiles.csv")
if (settings$recompute || !file.exists(quantileFile)) {
  computeQuantiles(quantileFile)
} else {
  cat("reusing the quantile table in", quantileFile, "\n")
}

quantiles <- read.csv(quantileFile)
quantileColumns <- grep("^quantile_[0-9]+$", names(quantiles), value = TRUE)
quantileColumns <- quantileColumns[order(as.integer(
  sub("^quantile_", "", quantileColumns)
))]
if (length(quantileColumns) != quantileCount + 1) {
  cat("note:", quantileFile, "has", length(quantileColumns) - 1,
      "bin(s), not", quantileCount, "- the table decides\n")
}
# The key of the quantile table, in the text allrecords holds. Both sides were
# written from R numbers, so the decimal text is the same; it is canonicalised
# through as.numeric() anyway so that a stray "8840.0" could not silently fail
# to match and leave every measurement unbinned.
idKey <- function(concept, unit) {
  paste(format(as.numeric(concept), scientific = FALSE, trim = TRUE),
        format(as.numeric(unit), scientific = FALSE, trim = TRUE), sep = "|")
}
quantileKey <- idKey(quantiles$measurement_concept_id,
                     quantiles$unit_concept_id)
if (anyDuplicated(quantileKey)) {
  stop(quantileFile, " has more than one row for a (concept, unit) pair, ",
       "which is its primary key.", call. = FALSE)
}
boundaryMatrix <- as.matrix(quantiles[, quantileColumns])
cat("quantile table:", nrow(quantiles), "pair(s),",
    length(quantileColumns) - 1, "bin(s)\n")

# ---------------------------------------------------------------------------
# 3. allrecords in MedRep's shape: four columns, measurements suffixed with
#    their bin. A record whose pair has no quantile row keeps the bare concept
#    id, which is what the original does too, and which is how a numeric
#    measurement with an unmapped unit (unit_concept_id 0, kept by this
#    project) comes out.
# ---------------------------------------------------------------------------
outputFile <- file.path(medRepFolder,
                        if (sampleRun) "allrecords-sample.csv.gz" else
                          "allrecords.csv.gz")
# Written to a staging file and renamed, so an interrupted run cannot leave a
# truncated file that looks finished.
stagingFile <- tempfile("medrep-allrecords-", tmpdir = medRepFolder,
                        fileext = ".csv.gz")
counters <- list(read = 0, valued = 0, binned = 0, unbinned = 0,
                 unbinnedUnitZero = 0)
missed <- new.env(parent = emptyenv())

convertChunk <- function(chunk, out) {
  counters$read <<- counters$read + nrow(chunk)
  token <- chunk$concept_id
  # Only a numeric measurement can be binned, and in allrecords only analysis
  # 998 rows carry a value, so this one test replaces any domain check.
  valued <- !is.na(chunk$value_as_number)
  if (any(valued)) {
    counters$valued <<- counters$valued + sum(valued)
    key <- idKey(chunk$concept_id[valued], chunk$unit_concept_id[valued])
    row <- match(key, quantileKey)
    hit <- !is.na(row)
    if (any(hit)) {
      bin <- assignQuantileBin(chunk$value_as_number[valued][hit],
                              boundaryMatrix[row[hit], , drop = FALSE])
      binned <- which(valued)[hit]
      keep <- !is.na(bin)
      token[binned[keep]] <- paste0(token[binned[keep]], "_", bin[keep])
      counters$binned <<- counters$binned + sum(keep)
    }
    if (any(!hit)) {
      counters$unbinned <<- counters$unbinned + sum(!hit)
      zero <- chunk$unit_concept_id[valued][!hit] %in% c("0", "")
      counters$unbinnedUnitZero <<- counters$unbinnedUnitZero + sum(zero)
      # Which pairs went unbinned, for the report. There are only as many
      # distinct pairs as the measurement table has, so this stays small.
      tally <- table(key[!hit][!zero])
      for (name in names(tally)) {
        assign(name,
               (if (exists(name, envir = missed, inherits = FALSE))
                 get(name, envir = missed) else 0) + as.integer(tally[[name]]),
               envir = missed)
      }
    }
  }
  utils::write.table(
    data.frame(person_id = chunk$person_id, domain = chunk$domain,
               concept_id = token, record_datetime = chunk$record_date,
               stringsAsFactors = FALSE),
    file = out, sep = ",", row.names = FALSE, col.names = FALSE,
    quote = FALSE, na = ""
  )
  invisible(NULL)
}

out <- gzfile(stagingFile, open = "wt", compression = settings$compression)
started <- Sys.time()
# A top-level on.exit() does nothing in a script, so the staging file is
# removed by hand on the way out of a failed run. The connection is closed
# first: Windows refuses to unlink a file this process still holds open.
converted <- FALSE
tryCatch(
  {
    writeLines("person_id,domain,concept_id,record_datetime", out)
    for (inputFile in inputFiles) {
      input <- gzfile(inputFile, open = "rt")
      header <- strsplit(readLines(input, n = 1), ",", fixed = TRUE)[[1]]
      if (!identical(header, recordColumns)) {
        close(input)
        stop(inputFile, " has the columns ", paste(header, collapse = ", "),
             ", not the ", paste(recordColumns, collapse = ", "),
             " this conversion reads.", call. = FALSE)
      }
      tryCatch(
        repeat {
          wanted <- settings$chunk
          if (sampleRun) {
            wanted <- min(wanted, settings$rows - counters$read)
            if (wanted <= 0) break
          }
          chunk <- utils::read.csv(input, header = FALSE, nrows = wanted,
                                   col.names = recordColumns,
                                   colClasses = recordClasses,
                                   na.strings = c("", "NA"))
          if (nrow(chunk) == 0) break
          convertChunk(chunk, out)
          elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
          cat(sprintf("\r  %s row(s) in %.0f s (%.0f rows/s)",
                      format(counters$read, big.mark = ","), elapsed,
                      counters$read / max(elapsed, 1)))
        },
        finally = close(input)
      )
      if (sampleRun && counters$read >= settings$rows) break
    }
    converted <- TRUE
  },
  finally = {
    close(out)
    if (!converted) {
      unlink(stagingFile, force = TRUE)
    }
  }
)
cat("\n")
if (file.exists(outputFile)) {
  unlink(outputFile, force = TRUE)
}
if (!file.rename(stagingFile, outputFile)) {
  unlink(stagingFile, force = TRUE)
  stop("Failed to save ", basename(outputFile), ".", call. = FALSE)
}
cat("wrote", format(counters$read, big.mark = ","), "record(s) to", outputFile,
    sprintf("(%.1f MB)\n", file.size(outputFile) / 1024^2))

# ---------------------------------------------------------------------------
# 4. What the conversion did, which is what a test run is read for.
# ---------------------------------------------------------------------------
report <- data.frame(
  measure = c("rows read", "rows with a numeric value",
              "rows given a bin", "rows with a value but no bin",
              "  of those, unit_concept_id 0 or empty",
              "  of those, a mapped unit below the pair threshold",
              "distinct unbinned (concept, unit) pairs with a mapped unit"),
  n = c(counters$read, counters$valued, counters$binned, counters$unbinned,
        counters$unbinnedUnitZero,
        counters$unbinned - counters$unbinnedUnitZero,
        length(ls(missed))),
  stringsAsFactors = FALSE
)
print(report, row.names = FALSE)
if (length(ls(missed)) > 0) {
  tally <- vapply(ls(missed), function(name) get(name, envir = missed),
                  numeric(1))
  tally <- sort(tally, decreasing = TRUE)
  cat("unbinned pairs with a mapped unit, most frequent first ",
      "(concept|unit = rows):\n  ",
      paste(utils::head(paste0(names(tally), " = ",
                               format(tally, big.mark = ",", trim = TRUE)),
                        10),
            collapse = "\n  "), "\n", sep = "")
}
reportFile <- file.path(medRepFolder,
                        if (sampleRun) "conversion_report_sample.csv" else
                          "conversion_report.csv")
write.csv(report, reportFile, row.names = FALSE)
cat("wrote", reportFile, "\n")

if (sampleRun) {
  cat("\nThis was a test run:", basename(outputFile),
      "holds only the first rows of allrecords, and README.md was not",
      "rewritten.\n")
} else {
  writeLines(c(
    "# MedRep comparison files",
    "",
    paste0("Written by `extras/CreateMedRepFiles.R` from the ",
           "`allrecords.csv.gz` of ", databaseId, ", in the column set of"),
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
    paste0("Quantiles: ", length(quantileColumns) - 1, " bins over ",
           nrow(quantiles), " (concept, unit) pair(s), from ",
           basename(quantileFile), "."),
    paste0("Rows: ", format(counters$read, big.mark = ","), ", of which ",
           format(counters$binned, big.mark = ","), " carry a bin."),
    paste0("Patients: train ", length(groups$train_id), ", valid ",
           length(groups$valid_id), ", test ", length(groups$test_id), ".")
  ), file.path(medRepFolder, "README.md"))
  cat("wrote", file.path(medRepFolder, "README.md"), "\n")
}
