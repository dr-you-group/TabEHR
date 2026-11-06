# Turns a task input into FeatureExtraction-style window covariates.
#
#   Rscript extras/MakeWindowCovariates.R <output folder> [databaseId] [key=value ...]
#
# A post-processing step over what execute() already wrote: it reads
# taskInput/<extraction>/input.csv.gz, which holds one row per record per day,
# and collapses each observation window into one covariate per concept, the way
# FeatureExtraction's non-temporal settings do.
#
#   binary      a concept with at least one record inside the window gets 1.
#               A concept with none gets no row at all - the file is sparse, so
#               "no row" is the 0.
#   measurement the value of the most recent valued record inside the window,
#               one per (row, concept).
#
# Nothing is read from the database and nothing is re-extracted. The daily
# records stay where they are; this only writes a second, aggregated view next
# to them.
#
# ---------------------------------------------------------------------------
# The analysis ids are FeatureExtraction's own, from
# inst/csv/PrespecAnalyses.csv of v3.2.0, so the output can be read by anything
# that already knows them:
#
#            AnyTimePrior  LongTerm  MediumTerm  ShortTerm
#   Condition        101       102         103        104
#   Drug             301       302         303        304
#   Procedure        501       502         503        504
#   Measurement      701       702         703        704   a measurement was taken
#   MeasurementValue 705       706         707        708   and this was its value
#
# and so are the covariate ids:
#
#   DomainConcept.sql      covariate_id = concept_id * 1000 + analysis_id
#   MeasurementValue.sql   covariate_id = concept_id * 1000000
#                                       + (unit_concept_id % 1000) * 1000
#                                       + analysis_id
#
# Note that these are NOT the ids of the daily extraction, which uses this
# project's own analyses 998 and 999 (see R/AllRecords.R). The two id spaces
# describe different things - one record versus one window - and mixing them
# would be a mistake, so the window output carries concept_id and
# unit_concept_id as columns of its own reference file.
#
# A valued measurement contributes two covariates per window, 70x and 70y, as
# it does in FeatureExtraction when both flags are on: the fact that the
# measurement was taken, and its value. Set measurementBinary to FALSE for the
# value alone.
#
# ---------------------------------------------------------------------------
# Options, as key=value arguments:
#
#   extraction=NAME  only this extraction (default: every folder under taskInput)
#   rows=N           read only the first N rows of the input, and write to
#                    window*_sample files. Use this for a test run.
#   chunk=N          rows per chunk (default 2,000,000)
#   compression=N    gzip level of the output (default 6; 1 is faster)

# The windows, in FeatureExtraction's convention: days relative to the index
# date, both ends inclusive, endDay 0 being the index day itself. The defaults
# are createCovariateSettings()'s longTermStartDays, mediumTermStartDays and
# shortTermStartDays with endDays = 0. Add
#   list(name = "anyTimePrior", startDay = -99999, endDay = 0)
# for the whole history, which is what the task input holds anyway.
windows <- list(
  list(name = "longTerm", startDay = -365, endDay = 0),
  list(name = "mediumTerm", startDay = -180, endDay = 0),
  list(name = "shortTerm", startDay = -30, endDay = 0)
)
measurementBinary <- TRUE

# FeatureExtraction's analysis ids, by domain and window name.
analysisIds <- list(
  cond = c(anyTimePrior = 101, longTerm = 102, mediumTerm = 103, shortTerm = 104),
  drug = c(anyTimePrior = 301, longTerm = 302, mediumTerm = 303, shortTerm = 304),
  proc = c(anyTimePrior = 501, longTerm = 502, mediumTerm = 503, shortTerm = 504),
  meas = c(anyTimePrior = 701, longTerm = 702, mediumTerm = 703, shortTerm = 704),
  measValue = c(anyTimePrior = 705, longTerm = 706, mediumTerm = 707,
                shortTerm = 708)
)
analysisNames <- list(
  cond = "ConditionOccurrence", drug = "DrugExposure",
  proc = "ProcedureOccurrence", meas = "Measurement",
  measValue = "MeasurementValue"
)
domainNames <- c(cond = "Condition", drug = "Drug", proc = "Procedure",
                 meas = "Measurement", measValue = "Measurement")

arguments <- commandArgs(trailingOnly = TRUE)
outputFolder <- if (length(arguments) >= 1) arguments[1] else
  Sys.getenv("TABEHR_OUTPUT_FOLDER", unset = "output")
databaseId <- Sys.getenv("TABEHR_DATABASE_ID", unset = "")
settings <- list(extraction = "", rows = NA_real_, chunk = 2e6,
                 compression = 6L)
for (argument in utils::tail(arguments, -1)) {
  if (grepl("^[A-Za-z]+=", argument)) {
    name <- sub("=.*$", "", argument)
    value <- sub("^[^=]*=", "", argument)
    if (!name %in% names(settings)) {
      stop("Unknown option ", name, ". Known: ",
           paste(names(settings), collapse = ", "), ".", call. = FALSE)
    }
    settings[[name]] <- switch(name,
                               extraction = value,
                               rows = as.numeric(value),
                               chunk = as.numeric(value),
                               compression = as.integer(value))
  } else {
    databaseId <- argument
  }
}
stopifnot(dir.exists(outputFolder), settings$chunk >= 1,
          settings$compression >= 0, settings$compression <= 9)

for (w in windows) {
  if (!w$name %in% names(analysisIds$cond)) {
    stop("Window ", w$name, " has no FeatureExtraction analysis id. Known: ",
         paste(names(analysisIds$cond), collapse = ", "),
         ". Add it to analysisIds to use another name.", call. = FALSE)
  }
  if (w$endDay > 0) {
    stop("Window ", w$name, " ends at day ", w$endDay,
         ", after the index date. The task input holds nothing after it, by ",
         "design: a feature taken after the index would leak the outcome.",
         call. = FALSE)
  }
  if (w$startDay > w$endDay) {
    stop("Window ", w$name, " starts after it ends.", call. = FALSE)
  }
}

# The site folder, the way the other extras scripts resolve it.
hasTaskInput <- function(folder) dir.exists(file.path(folder, "taskInput"))
databaseFolder <- outputFolder
if (!hasTaskInput(outputFolder)) {
  candidates <- if (nzchar(databaseId)) {
    file.path(outputFolder, databaseId)
  } else {
    list.dirs(outputFolder, recursive = FALSE)
  }
  candidates <- candidates[vapply(candidates, hasTaskInput, logical(1))]
  if (length(candidates) != 1) {
    stop("No single site folder with a taskInput/ under ", outputFolder,
         ": found ", length(candidates),
         ". Give the site folder itself, or its databaseId as an argument.",
         call. = FALSE)
  }
  databaseFolder <- candidates[1]
}
if (!nzchar(databaseId)) {
  databaseId <- basename(databaseFolder)
}
extractions <- list.dirs(file.path(databaseFolder, "taskInput"),
                         recursive = FALSE, full.names = FALSE)
if (nzchar(settings$extraction)) {
  if (!settings$extraction %in% extractions) {
    stop("No extraction ", settings$extraction, " under ",
         file.path(databaseFolder, "taskInput"), ". Available: ",
         paste(extractions, collapse = ", "), ".", call. = FALSE)
  }
  extractions <- settings$extraction
}
stopifnot(length(extractions) > 0)
sampleRun <- !is.na(settings$rows)
cat("database:  ", databaseId, "\n")
cat("extraction:", paste(extractions, collapse = ", "), "\n")
cat("windows:   ",
    paste(vapply(windows, function(w)
      sprintf("%s [%d, %d]", w$name, w$startDay, w$endDay), ""),
      collapse = "  "), "\n")
if (sampleRun) {
  cat("test run:   first", format(settings$rows, big.mark = ","),
      "row(s), writing window*_sample files\n")
}

inputColumns <- c("row_id", "person_id", "domain", "concept_id", "record_date",
                  "time_id", "value_as_number", "unit_concept_id")
inputClasses <- c("character", "character", "character", "character",
                  "character", "integer", "numeric", "numeric")

# time_id counts days BACKWARDS from the index date, so a window given in
# FeatureExtraction's negative-day convention maps to [-endDay, -startDay].
for (i in seq_along(windows)) {
  windows[[i]]$lower <- -windows[[i]]$endDay
  windows[[i]]$upper <- -windows[[i]]$startDay
}

idText <- function(x) format(x, scientific = FALSE, trim = TRUE)

# One block of complete row_ids, already ordered by row_id then time_id
# ascending, which is the order .writeTaskInput() wrote: time_id 0 is the index
# day, so ascending time_id is most recent first. The first row of a key is
# therefore the most recent one, which is the record FeatureExtraction keeps.
windowRows <- function(block) {
  key <- paste(block$row_id, block$concept_id, sep = "\r")
  valued <- !is.na(block$value_as_number)
  pieces <- list()
  for (w in windows) {
    inWindow <- block$time_id >= w$lower & block$time_id <= w$upper
    # Binary: the most recent record of each concept in the window, by domain.
    idx <- which(inWindow)
    if (length(idx) > 0) {
      idx <- idx[!duplicated(key[idx])]
      domain <- block$domain[idx]
      keep <- if (measurementBinary) {
        domain %in% names(analysisIds)
      } else {
        domain %in% c("cond", "drug", "proc")
      }
      idx <- idx[keep]
      domain <- domain[keep]
      if (length(idx) > 0) {
        analysis <- vapply(domain, function(d) analysisIds[[d]][[w$name]], 0)
        pieces[[length(pieces) + 1]] <- data.frame(
          row_id = block$row_id[idx],
          covariate_id = as.numeric(block$concept_id[idx]) * 1000 + analysis,
          covariate_value = 1,
          analysis_id = analysis,
          concept_id = block$concept_id[idx],
          unit_concept_id = NA_real_,
          stringsAsFactors = FALSE
        )
      }
    }
    # Value: the most recent VALUED record of each concept in the window.
    # FeatureExtraction's MeasurementValue.sql only looks at rows with a
    # numeric value, so a no-value record does not hide an older value.
    idx <- which(inWindow & valued)
    if (length(idx) > 0) {
      idx <- idx[!duplicated(key[idx])]
      analysis <- analysisIds$measValue[[w$name]]
      unit <- block$unit_concept_id[idx]
      unit[is.na(unit)] <- 0
      pieces[[length(pieces) + 1]] <- data.frame(
        row_id = block$row_id[idx],
        covariate_id = as.numeric(block$concept_id[idx]) * 1e6 +
          (unit %% 1000) * 1000 + analysis,
        covariate_value = block$value_as_number[idx],
        analysis_id = analysis,
        concept_id = block$concept_id[idx],
        unit_concept_id = unit,
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(pieces) == 0) {
    return(NULL)
  }
  do.call(rbind, pieces)
}

for (extraction in extractions) {
  folder <- file.path(databaseFolder, "taskInput", extraction)
  inputFile <- file.path(folder, "input.csv.gz")
  if (!file.exists(inputFile)) {
    cat("skipping", extraction, "- no input.csv.gz\n")
    next
  }
  suffix <- if (sampleRun) "_sample" else ""
  outputFile <- file.path(folder, paste0("windowCovariates", suffix, ".csv.gz"))
  refFile <- file.path(folder, paste0("windowCovariateRef", suffix, ".csv"))
  analysisFile <- file.path(folder, paste0("windowAnalysisRef", suffix, ".csv"))
  reportFile <- file.path(folder, paste0("windowCovariates", suffix,
                                         "_report.csv"))
  stagingFile <- tempfile("window-", tmpdir = folder, fileext = ".csv.gz")

  cat("\n", extraction, "\n", sep = "")
  input <- gzfile(inputFile, open = "rt")
  header <- strsplit(readLines(input, n = 1), ",", fixed = TRUE)[[1]]
  if (!identical(header, inputColumns)) {
    close(input)
    stop(inputFile, " has the columns ", paste(header, collapse = ", "),
         ", not the ", paste(inputColumns, collapse = ", "),
         " this step reads.", call. = FALSE)
  }
  out <- gzfile(stagingFile, open = "wt", compression = settings$compression)
  # Built while streaming: one entry per covariate id, and the per-window
  # counts of the report.
  reference <- new.env(parent = emptyenv())
  counts <- new.env(parent = emptyenv())
  read <- 0
  written <- 0
  rowIds <- new.env(parent = emptyenv())
  started <- Sys.time()
  converted <- FALSE

  collect <- function(rows) {
    if (is.null(rows) || nrow(rows) == 0) {
      return(invisible(NULL))
    }
    utils::write.table(
      data.frame(row_id = rows$row_id,
                 covariate_id = idText(rows$covariate_id),
                 covariate_value = rows$covariate_value,
                 stringsAsFactors = FALSE),
      file = out, sep = ",", row.names = FALSE, col.names = FALSE,
      quote = FALSE, na = ""
    )
    written <<- written + nrow(rows)
    new <- !duplicated(rows$covariate_id)
    for (i in which(new)) {
      id <- idText(rows$covariate_id[i])
      if (!exists(id, envir = reference, inherits = FALSE)) {
        assign(id, c(analysisId = rows$analysis_id[i],
                     conceptId = as.numeric(rows$concept_id[i]),
                     unitConceptId = rows$unit_concept_id[i]),
               envir = reference)
      }
    }
    for (a in unique(rows$analysis_id)) {
      name <- as.character(a)
      n <- sum(rows$analysis_id == a)
      assign(name,
             (if (exists(name, envir = counts, inherits = FALSE))
               get(name, envir = counts) else 0) + n,
             envir = counts)
    }
    for (id in unique(rows$row_id)) {
      assign(id, TRUE, envir = rowIds)
    }
    invisible(NULL)
  }

  tryCatch(
    {
      writeLines("row_id,covariate_id,covariate_value", out)
      carry <- NULL
      repeat {
        wanted <- settings$chunk
        if (sampleRun) {
          wanted <- min(wanted, settings$rows - read)
          if (wanted <= 0) break
        }
        chunk <- utils::read.csv(input, header = FALSE, nrows = wanted,
                                 col.names = inputColumns,
                                 colClasses = inputClasses,
                                 na.strings = c("", "NA"))
        if (nrow(chunk) == 0) break
        read <- read + nrow(chunk)
        block <- if (is.null(carry)) chunk else rbind(carry, chunk)
        # A row_id can straddle a chunk boundary, and the aggregation is per
        # row_id, so the last one is held back until its rows are all in.
        last <- block$row_id[nrow(block)]
        complete <- block$row_id != last
        carry <- block[!complete, , drop = FALSE]
        if (any(complete)) {
          collect(windowRows(block[complete, , drop = FALSE]))
        }
        elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
        cat(sprintf("\r  read %s row(s), wrote %s covariate(s) in %.0f s",
                    format(read, big.mark = ","),
                    format(written, big.mark = ","), elapsed))
      }
      if (!is.null(carry) && nrow(carry) > 0) {
        collect(windowRows(carry))
      }
      converted <- TRUE
    },
    finally = {
      close(input)
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

  # The reference files, which are what make the ids readable.
  ids <- ls(reference)
  if (length(ids) == 0) {
    cat("no covariate fell inside any window - check the window days\n")
    next
  }
  values <- do.call(rbind, lapply(ids, function(id) get(id, envir = reference)))
  analysisOf <- stats::setNames(
    unlist(lapply(names(analysisIds), function(d) analysisIds[[d]])),
    unlist(lapply(names(analysisIds), function(d)
      paste(d, names(analysisIds[[d]]), sep = "|")))
  )
  nameOf <- function(analysisId) {
    hit <- names(analysisOf)[match(analysisId, analysisOf)]
    parts <- strsplit(hit, "|", fixed = TRUE)[[1]]
    list(domain = parts[1], window = parts[2])
  }
  covariateRef <- data.frame(
    covariate_id = ids,
    analysis_id = values[, "analysisId"],
    concept_id = idText(values[, "conceptId"]),
    unit_concept_id = ifelse(is.na(values[, "unitConceptId"]), "",
                             idText(values[, "unitConceptId"])),
    stringsAsFactors = FALSE
  )
  described <- lapply(covariateRef$analysis_id, nameOf)
  covariateRef$domain <- vapply(described, `[[`, "", "domain")
  covariateRef$window <- vapply(described, `[[`, "", "window")
  covariateRef$covariate_name <- paste0(
    vapply(covariateRef$domain, function(d) analysisNames[[d]], ""), " ",
    covariateRef$window, ": concept ", covariateRef$concept_id,
    ifelse(nzchar(covariateRef$unit_concept_id),
           paste0(" (unit ", covariateRef$unit_concept_id, ")"), "")
  )
  covariateRef <- covariateRef[order(as.numeric(covariateRef$covariate_id)), ]
  utils::write.csv(covariateRef[, c("covariate_id", "covariate_name",
                                    "analysis_id", "concept_id",
                                    "unit_concept_id", "domain", "window")],
                   refFile, row.names = FALSE)

  analysisRef <- do.call(rbind, lapply(windows, function(w) {
    do.call(rbind, lapply(names(analysisIds), function(d) {
      data.frame(
        analysis_id = analysisIds[[d]][[w$name]],
        analysis_name = paste0(analysisNames[[d]],
                               toupper(substring(w$name, 1, 1)),
                               substring(w$name, 2)),
        domain_id = domainNames[[d]],
        start_day = w$startDay, end_day = w$endDay,
        is_binary = d != "measValue",
        stringsAsFactors = FALSE
      )
    }))
  }))
  analysisRef <- analysisRef[analysisRef$analysis_id %in%
                               covariateRef$analysis_id, ]
  utils::write.csv(analysisRef, analysisFile, row.names = FALSE)

  report <- analysisRef
  report$n_covariate_row <- vapply(as.character(report$analysis_id),
                                   function(a) {
                                     if (exists(a, envir = counts,
                                                inherits = FALSE))
                                       get(a, envir = counts) else 0
                                   }, 0)
  report$n_distinct_covariate <- vapply(report$analysis_id, function(a)
    sum(covariateRef$analysis_id == a), 0)
  report$n_input_row <- read
  report$n_row_id <- length(ls(rowIds))
  utils::write.csv(report, reportFile, row.names = FALSE)

  cat("wrote", outputFile, "\n")
  cat("     ", format(written, big.mark = ","), "covariate row(s) over",
      length(ls(rowIds)), "prediction row(s),", nrow(covariateRef),
      "distinct covariate(s)\n")
  print(report[, c("analysis_name", "start_day", "end_day", "is_binary",
                   "n_covariate_row", "n_distinct_covariate")],
        row.names = FALSE)
}

if (sampleRun) {
  cat("\nThis was a test run: the window*_sample files hold only the first",
      format(settings$rows, big.mark = ","), "input row(s).\n")
}
