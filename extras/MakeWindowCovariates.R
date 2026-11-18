# Reduces a task input to one row per concept per observation window.
#
#   Rscript extras/MakeWindowCovariates.R <output folder> [databaseId] [key=value ...]
#
# A post-processing step over what execute() already wrote. It reads
# taskInput/<extraction>/input.csv.gz, which holds one row per record per day,
# and writes taskInput/<extraction>/windows/<window>.csv.gz, which holds one
# row per (row_id, concept) that has any record inside that window.
#
# The output columns are the input's, minus time_id:
#
#   row_id, person_id, domain, concept_id, record_date, value_as_number,
#   unit_concept_id
#
# so the file reads exactly like allrecords and the task input do. There is no
# covariate id and no analysis id: this project keys a record on
# (domain, concept_id, unit_concept_id), and the window is the file it is in.
#
#   presence     a concept with at least one record in the window has a row.
#                One with none has no row, which is the 0 - the file is sparse.
#   the row      the most recent record of that concept in the window, so
#                record_date says how recent the evidence is. For a
#                measurement, the most recent record WITH a numeric value when
#                the window holds one, so that value, unit and date all come
#                from the same record. FeatureExtraction's MeasurementValue
#                rule is the same: a later record with no value does not hide
#                an earlier value.
#
# Nothing is read from the database and nothing is re-extracted. time_id is
# already the number of days before the task index date, so the windows need no
# dates and no join to the labels. (The index date is recoverable from the
# input as record_date + time_id, if it is ever wanted.)

# The windows, in FeatureExtraction's convention: days relative to the index
# date, both ends inclusive, endDay 0 being the index day itself. The defaults
# are createCovariateSettings()'s longTermStartDays, mediumTermStartDays and
# shortTermStartDays with endDays = 0. The name is the file name.
windows <- list(
  list(name = "longTerm", startDay = -365, endDay = 0),
  list(name = "mediumTerm", startDay = -180, endDay = 0),
  list(name = "shortTerm", startDay = -30, endDay = 0)
)

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

names <- vapply(windows, function(w) w$name, "")
if (anyDuplicated(names)) {
  stop("Two windows share the name ", names[duplicated(names)][1],
       ", and the name is the file name.", call. = FALSE)
}
for (w in windows) {
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
      "row(s), into windows-sample/\n")
}

inputColumns <- c("row_id", "person_id", "domain", "concept_id", "record_date",
                  "time_id", "value_as_number", "unit_concept_id")
inputClasses <- c("character", "character", "character", "character",
                  "character", "integer", "numeric", "character")
outputColumns <- setdiff(inputColumns, "time_id")

# time_id counts days BACKWARDS from the index date, so a window given in
# FeatureExtraction's negative-day convention maps to [-endDay, -startDay].
for (i in seq_along(windows)) {
  windows[[i]]$lower <- -windows[[i]]$endDay
  windows[[i]]$upper <- -windows[[i]]$startDay
}

# The rows of one block of complete row_ids that survive one window. The block
# is ordered by row_id then time_id ascending, which is the order
# .writeTaskInput() wrote: time_id 0 is the index day, so ascending time_id is
# most recent first and the first row of a key is the most recent one.
windowRows <- function(block, key, valued, w) {
  inWindow <- block$time_id >= w$lower & block$time_id <= w$upper
  if (!any(inWindow)) {
    return(integer(0))
  }
  # The most recent record with a value, and the most recent record of any
  # kind. A concept that has both keeps the valued one, so the value, the unit
  # and record_date all come from one record.
  withValue <- which(inWindow & valued)
  withValue <- withValue[!duplicated(key[withValue])]
  any_ <- which(inWindow)
  any_ <- any_[!duplicated(key[any_])]
  any_ <- any_[!key[any_] %in% key[withValue]]
  # Sorted back into file order, so the output stays grouped by row_id with
  # the most recent record of each concept first.
  sort(c(withValue, any_))
}

for (extraction in extractions) {
  folder <- file.path(databaseFolder, "taskInput", extraction)
  inputFile <- file.path(folder, "input.csv.gz")
  if (!file.exists(inputFile)) {
    cat("skipping", extraction, "- no input.csv.gz\n")
    next
  }
  windowFolder <- file.path(folder, if (sampleRun) "windows-sample" else
                                      "windows")
  dir.create(windowFolder, recursive = TRUE, showWarnings = FALSE)
  cat("\n", extraction, " -> ", windowFolder, "\n", sep = "")

  input <- gzfile(inputFile, open = "rt")
  header <- strsplit(readLines(input, n = 1), ",", fixed = TRUE)[[1]]
  if (!identical(header, inputColumns)) {
    close(input)
    stop(inputFile, " has the columns ", paste(header, collapse = ", "),
         ", not the ", paste(inputColumns, collapse = ", "),
         " this step reads.", call. = FALSE)
  }

  # One staging file per window, renamed at the end, so an interrupted run
  # cannot leave a truncated file that looks finished.
  staging <- vapply(windows, function(w)
    tempfile(paste0(w$name, "-"), tmpdir = windowFolder, fileext = ".csv.gz"),
    "")
  outputs <- lapply(staging, function(file)
    gzfile(file, open = "wt", compression = settings$compression))
  written <- stats::setNames(numeric(length(windows)), names)
  rowIds <- lapply(windows, function(w) new.env(parent = emptyenv()))
  read <- 0
  started <- Sys.time()
  done <- FALSE

  tryCatch(
    {
      for (out in outputs) {
        writeLines(paste(outputColumns, collapse = ","), out)
      }
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
        # A row_id can straddle a chunk boundary, and a window is taken per
        # row_id, so the last one is held back until its rows are all in.
        last <- block$row_id[nrow(block)]
        complete <- block$row_id != last
        carry <- block[!complete, , drop = FALSE]
        if (any(complete)) {
          block <- block[complete, , drop = FALSE]
          key <- paste(block$row_id, block$concept_id, sep = "\r")
          valued <- !is.na(block$value_as_number)
          for (i in seq_along(windows)) {
            take <- windowRows(block, key, valued, windows[[i]])
            if (length(take) == 0) {
              next
            }
            utils::write.table(block[take, outputColumns], file = outputs[[i]],
                               sep = ",", row.names = FALSE, col.names = FALSE,
                               quote = FALSE, na = "")
            written[i] <- written[i] + length(take)
            for (id in unique(block$row_id[take])) {
              assign(id, TRUE, envir = rowIds[[i]])
            }
          }
        }
        elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
        cat(sprintf("\r  read %s row(s) in %.0f s (%.0f rows/s)",
                    format(read, big.mark = ","), elapsed,
                    read / max(elapsed, 1)))
      }
      if (!is.null(carry) && nrow(carry) > 0) {
        key <- paste(carry$row_id, carry$concept_id, sep = "\r")
        valued <- !is.na(carry$value_as_number)
        for (i in seq_along(windows)) {
          take <- windowRows(carry, key, valued, windows[[i]])
          if (length(take) == 0) {
            next
          }
          utils::write.table(carry[take, outputColumns], file = outputs[[i]],
                             sep = ",", row.names = FALSE, col.names = FALSE,
                             quote = FALSE, na = "")
          written[i] <- written[i] + length(take)
          for (id in unique(carry$row_id[take])) {
            assign(id, TRUE, envir = rowIds[[i]])
          }
        }
      }
      done <- TRUE
    },
    finally = {
      for (out in outputs) {
        close(out)
      }
      if (!done) {
        unlink(staging, force = TRUE)
      }
    }
  )
  cat("\n")

  for (i in seq_along(windows)) {
    file <- file.path(windowFolder, paste0(windows[[i]]$name, ".csv.gz"))
    if (file.exists(file)) {
      unlink(file, force = TRUE)
    }
    if (!file.rename(staging[i], file)) {
      unlink(staging, force = TRUE)
      stop("Failed to save ", basename(file), ".", call. = FALSE)
    }
  }

  reference <- data.frame(
    window = vapply(windows, function(w) w$name, ""),
    start_day = vapply(windows, function(w) w$startDay, 0),
    end_day = vapply(windows, function(w) w$endDay, 0),
    file = paste0(vapply(windows, function(w) w$name, ""), ".csv.gz"),
    n_row = as.numeric(written),
    n_row_id = vapply(rowIds, function(env) length(ls(env)), 0),
    stringsAsFactors = FALSE
  )
  reference$n_input_row <- read
  utils::write.csv(reference, file.path(windowFolder, "ref.csv"),
                   row.names = FALSE)
  print(reference[, c("window", "start_day", "end_day", "n_row", "n_row_id")],
        row.names = FALSE)
  cat("wrote", nrow(reference), "window file(s) and ref.csv\n")
}

if (sampleRun) {
  cat("\nThis was a test run: windows-sample/ holds only what the first",
      format(settings$rows, big.mark = ","), "input row(s) produced.\n")
}
