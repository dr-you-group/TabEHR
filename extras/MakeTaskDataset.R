# Split outcomeLabels.csv into one task's dataset.
#
#   Rscript extras/MakeTaskDataset.R <output folder> [databaseId] [key=value ...]
#
# The folder is either the site folder or the base folder with the databaseId
# beside it, as in the other extras scripts:
#
#   Rscript extras/MakeTaskDataset.R output/mimic
#   Rscript extras/MakeTaskDataset.R output mimic task=newDx3101 records=TRUE
#
#   task=<taskId>|all   which task (default all)
#   source=input        which record file to join: input, or a window name
#          |<window>    such as longTerm (windows/<window>.csv.gz)
#   records=TRUE        also write the records, off by default: 22 tasks share
#                       one extraction, so only the labels differ
#   chunk=N             rows per chunk while the records are filtered
#
# Writes taskDataset/<taskId>/labels.csv and, with records=TRUE,
# taskDataset/<taskId>/records.csv.gz. The join key is row_id - one target
# cohort entry, one discharge - never person_id.

arguments <- commandArgs(trailingOnly = TRUE)
outputFolder <- if (length(arguments) >= 1) arguments[1] else
  Sys.getenv("TABEHR_OUTPUT_FOLDER", unset = "output")
databaseId <- Sys.getenv("TABEHR_DATABASE_ID", unset = "")
settings <- list(task = "all", source = "input", records = FALSE, chunk = 2e6)
for (argument in utils::tail(arguments, -1)) {
  if (grepl("^[A-Za-z]+=", argument)) {
    name <- sub("=.*$", "", argument)
    value <- sub("^[^=]*=", "", argument)
    if (!name %in% names(settings)) {
      stop("Unknown option ", name, ". Known: ",
           paste(names(settings), collapse = ", "), ".", call. = FALSE)
    }
    settings[[name]] <- switch(name,
                               task = value,
                               source = value,
                               records = as.logical(value),
                               chunk = as.numeric(value))
  } else {
    databaseId <- argument
  }
}
stopifnot(dir.exists(outputFolder), !is.na(settings$records),
          settings$chunk >= 1)

# The site folder, the way the other extras scripts resolve it: the folder
# itself, or the base folder with the databaseId beside it.
hasLabels <- function(folder) file.exists(file.path(folder,
                                                    "outcomeLabels.csv"))
databaseFolder <- outputFolder
if (!hasLabels(outputFolder)) {
  candidates <- if (nzchar(databaseId)) {
    file.path(outputFolder, databaseId)
  } else {
    list.dirs(outputFolder, recursive = FALSE)
  }
  candidates <- candidates[vapply(candidates, hasLabels, logical(1))]
  if (length(candidates) != 1) {
    stop("No single site folder with an outcomeLabels.csv under ",
         outputFolder, ": found ", length(candidates),
         ". Give the site folder itself, or its databaseId as an argument.",
         call. = FALSE)
  }
  databaseFolder <- candidates[1]
}

# row_id and person_id are read as text on both sides of the join: a 19 digit
# person id loses its last digits as a double, and a row id that is text in one
# file and a number in the other does not match.
labels <- utils::read.csv(file.path(databaseFolder, "outcomeLabels.csv"),
                          colClasses = c(taskId = "character",
                                         extraction = "character",
                                         rowId = "character",
                                         subjectId = "character"))
tasks <- if (identical(settings$task, "all")) {
  sort(unique(labels$taskId))
} else {
  settings$task
}

# The label columns a model needs, in this project's snake case so that they
# join to input.csv.gz and the window files without renaming.
labelColumns <- c(task_id = "taskId", extraction = "extraction",
                  row_id = "rowId", person_id = "subjectId",
                  index_date = "targetCohortStartDate",
                  tar_start_date = "tarStartDate",
                  tar_end_date = "tarEndDate",
                  time_at_risk = "timeAtRisk",
                  outcome_label = "outcomeLabel",
                  outcome_start_date = "outcomeStartDate",
                  days_to_event = "daysToEvent")

for (taskId in tasks) {
  rows <- labels[labels$taskId == taskId, ]
  stopifnot(nrow(rows) > 0)
  extraction <- unique(rows$extraction)
  # row_id is unique within an extraction, not across them.
  stopifnot(length(extraction) == 1)
  folder <- file.path(databaseFolder, "taskDataset", taskId)
  dir.create(folder, recursive = TRUE, showWarnings = FALSE)

  labelTable <- rows[, labelColumns]
  names(labelTable) <- names(labelColumns)
  utils::write.csv(labelTable[order(labelTable$row_id), ],
                   file.path(folder, "labels.csv"), row.names = FALSE, na = "")

  if (!settings$records) next

  input <- if (identical(settings$source, "input")) {
    file.path(databaseFolder, "taskInput", extraction, "input.csv.gz")
  } else {
    file.path(databaseFolder, "taskInput", extraction, "windows",
              paste0(settings$source, ".csv.gz"))
  }
  # One file name per source, so a window run does not overwrite the daily one.
  outputFile <- file.path(folder, if (identical(settings$source, "input")) {
    "records.csv.gz"
  } else {
    paste0("records-", settings$source, ".csv.gz")
  })
  wanted <- unique(labelTable$row_id)

  connection <- gzfile(input, open = "rt")
  out <- gzfile(outputFile, open = "wt")
  header <- readLines(connection, n = 1)
  columns <- strsplit(header, ",", fixed = TRUE)[[1]]
  classes <- ifelse(columns %in% c("row_id", "person_id", "concept_id",
                                   "unit_concept_id"), "character", NA)
  writeLines(header, out)
  repeat {
    chunk <- utils::read.csv(connection, header = FALSE, nrows = settings$chunk,
                             col.names = columns, colClasses = classes,
                             na.strings = c("", "NA"))
    if (nrow(chunk) == 0) break
    chunk <- chunk[chunk$row_id %in% wanted, ]
    utils::write.table(chunk, out, sep = ",", row.names = FALSE,
                       col.names = FALSE, quote = FALSE, na = "")
  }
  close(connection)
  close(out)
}

cat("wrote", file.path(databaseFolder, "taskDataset"), "-", length(tasks),
    "task(s),", if (settings$records) {
      paste0("labels.csv and the records from ", settings$source)
    } else {
      "labels.csv only - add records=TRUE for the records"
    }, "\n")
