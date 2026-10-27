# Render and translate every SQL file in the package, without a database.
#
#   Rscript extras/CheckSqlRendering.R [dialect ...]
#
# Needs only SqlRender, so it runs anywhere, and it is the check to run after
# editing any SQL. For each file and each dialect it reports:
#
#   * parameters left unresolved, which is a typo or a missing default
#   * conditional blocks left unresolved
#   * constructs SqlRender v1.9.0 does not translate: DATEPART, DATEDIFF(HOUR),
#     TRY_CAST, ISNUMERIC and LIKE character classes. On SQL Server they are
#     fine; anywhere else they would fail at run time, which is why
#     R/Dialects.R supplies the hour of day per dialect
#
# It also renders the SparseArray target cohort both ways, to confirm that the
# WHERE EXISTS appears only when a restriction table is given, and that the
# definition is otherwise untouched.
#
# The rendered SQL is written to extras/rendered/<dialect>/ for reading.

root <- Sys.getenv("TABEHR_ROOT", unset = getwd())
sqlFolder <- file.path(root, "inst", "sql", "sql_server")
stopifnot(dir.exists(sqlFolder))
source(file.path(root, "R", "Dialects.R"))
source(file.path(root, "R", "MeasurementQuantiles.R"))

dialects <- commandArgs(trailingOnly = TRUE)
if (length(dialects) == 0) {
  dialects <- c("sql server", "postgresql")
}
quantileCount <- 10
flat <- function(x) gsub("[[:space:]]+", " ", x)

# A superset of every parameter the SQL files take, with values that make each
# conditional block render in its active form, so both branches are covered.
parameters <- function(dialect) {
  c(
    list(
      cdm_database_schema = "cdm",
      vocabulary_database_schema = "vocab",
      cohort_database_schema = "work",
      cohort_table = "cohort_v3",
      records_table = "work.tabehr_records",
      measurements_table = "work.tabehr_measurements",
      concept_unit_table = "work.tabehr_concept_unit",
      record_counts_table = "work.tabehr_record_counts",
      admission_history_table = "work.tabehr_admission_history",
      study_population_table = "work.tabehr_study_population",
      person_split_table = "work.tabehr_person_split",
      downstream_person_table = "work.tabehr_downstream_person",
      quantile_basis_person_table = "work.tabehr_quantile_basis_person",
      meas_quantiles_table = "work.tabehr_meas_quantiles",
      allrecords_cohort_table = "work.tabehr_allrecords_cohort",
      cohort_id = 1100,
      staging_table = "work.tabehr_staging",
      person_sample_table = "work.tabehr_person_sample",
      restrict_person_table = "work.tabehr_quantile_basis_person",
      drop_table = "work.tabehr_staging",
      date_min = "1900-01-01",
      date_max = "2260-12-31 00:00:00",
      adult_age_min = 18,
      min_record_count = 10,
      min_concept_unit_count = 10,
      sample_person_count = 1000,
      inpatient_concept_ids = "9201, 262",
      include_descendant_visit_concepts = 1,
      length_of_stay_operator = ">=",
      min_length_of_stay = 2,
      # The admission criterion is off by default, so the inactive branch is
      # the one the pipeline renders. Both are rendered below.
      require_qualifying_admission = 0,
      tie_break_column = "measurement_id",
      downstream_stage = "downstream",
      quantile_basis = "pretrain",
      quantile_basis_stage = "pretrain",
      quantile_cast_columns = "       CAST(S.quantile_0 AS FLOAT) AS quantile_0,",
      hour_of_day = hourOfDaySql(dialect, "M.measurement_datetime"),
      # The measurement covariate SQL, which FeatureExtraction calls with its
      # own row id field, and with a cohort id clause only when it was given
      # cohort ids. 998 and 999 are this project's own analysis ids.
      row_id_field = "row_id",
      cohort_id_clause = "\t\tAND cohort.cohort_definition_id IN (1000)",
      analysis_id = 998,
      no_value_analysis_id = 999,
      time_part = "DAY",
      time_interval = 1,
      sequence_start_day = -99999,
      sequence_end_day = 0
    ),
    .quantileSqlParameters(list(quantileCount = quantileCount))
  )
}

untranslated <- c(
  "DATEPART" = "DATEPART[[:space:]]*\\(",
  "DATEDIFF(HOUR)" = "DATEDIFF[[:space:]]*\\([[:space:]]*HOUR",
  "TRY_CAST" = "TRY_CAST[[:space:]]*\\(",
  "ISNUMERIC" = "ISNUMERIC[[:space:]]*\\(",
  "LIKE character class" = "LIKE[[:space:]]*'[^']*\\[\\^"
)

# The measurement value covariates live in SparseArray, because that is the
# package whose extraction they join, but they are this project's SQL and the
# same checks apply to them.
sparseArrayFolder <- file.path(root, "SparseArray", "inst", "sql", "sql_server")
paths <- c(
  file.path(sqlFolder, sort(list.files(sqlFolder, pattern = "[.]sql$"))),
  Filter(file.exists, file.path(sparseArrayFolder,
                                c("MeasurementValueUnit.sql",
                                  "MeasurementValueUnitRef.sql")))
)
rows <- list()
for (path in paths) {
  file <- basename(path)
  template <- SqlRender::readSql(path)
  for (dialect in dialects) {
    available <- parameters(dialect)
    used <- available[vapply(
      names(available),
      function(name) grepl(paste0("@", name, "\\b"), template),
      logical(1)
    )]
    sql <- tryCatch(
      SqlRender::translate(
        do.call(SqlRender::render, c(list(sql = template), used)),
        targetDialect = dialect
      ),
      error = function(e) paste("ERROR:", conditionMessage(e))
    )
    failed <- startsWith(sql, "ERROR:")
    leftovers <- if (failed) character(0) else {
      unique(unlist(regmatches(sql, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", sql))))
    }
    conditionals <- if (failed) 0L else {
      length(unlist(regmatches(sql, gregexpr("\\{[^{}]*\\}[[:space:]]*[?]",
                                             sql))))
    }
    found <- if (failed) character(0) else {
      names(untranslated)[vapply(
        untranslated,
        function(pattern) grepl(pattern, sql, ignore.case = TRUE),
        logical(1)
      )]
    }
    rows[[length(rows) + 1]] <- data.frame(
      file = file,
      dialect = dialect,
      ok = !failed && length(leftovers) == 0 && conditionals == 0 &&
        (dialect == "sql server" || length(found) == 0),
      unresolved_parameters = paste(leftovers, collapse = " "),
      unresolved_conditionals = conditionals,
      untranslated = paste(found, collapse = ", "),
      error = if (failed) sql else "",
      stringsAsFactors = FALSE
    )
    if (!failed) {
      folder <- file.path(root, "extras", "rendered",
                          gsub("[^a-z]", "_", dialect))
      dir.create(folder, recursive = TRUE, showWarnings = FALSE)
      writeLines(sql, file.path(folder, file))
    }
  }
}
results <- do.call(rbind, rows)

cat("\n==== package SQL ====\n")
print(results[, c("file", "dialect", "ok", "unresolved_parameters",
                  "untranslated")], row.names = FALSE)

# The one change to a SparseArray cohort definition, rendered both ways.
cohortSql <- file.path(root, "SparseArray", "inst", "sql", "sql_server",
                       "Inpatient_visit.sql")
if (file.exists(cohortSql)) {
  template <- SqlRender::readSql(cohortSql)
  cohortRows <- lapply(c("", "tabehr_downstream_person"), function(restriction) {
    sql <- SqlRender::translate(
      SqlRender::render(
        template,
        cdm_database_schema = "cdm",
        vocabulary_database_schema = "vocab",
        target_database_schema = "work",
        target_cohort_table = "cohort_v3",
        target_cohort_id = 1000,
        restrict_person_table = restriction
      ),
      targetDialect = "sql server"
    )
    data.frame(
      restrict_person_table = if (nzchar(restriction)) restriction else "(none)",
      has_where_exists = grepl("EXISTS (SELECT 1 FROM", sql, fixed = TRUE),
      unresolved_parameters = paste(unique(unlist(regmatches(
        sql, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", sql)
      ))), collapse = " "),
      characters = nchar(sql),
      stringsAsFactors = FALSE
    )
  })
  cat("\n==== SparseArray Inpatient_visit.sql ====\n")
  print(do.call(rbind, cohortRows), row.names = FALSE)
}

# The cohort id clause of the measurement value SQL defaults to nothing, which
# is the path FeatureExtraction takes when it was given no cohort ids, so that
# branch is rendered on its own as well.
measurementValueSql <- file.path(sparseArrayFolder, "MeasurementValueUnit.sql")
if (file.exists(measurementValueSql)) {
  template <- SqlRender::readSql(measurementValueSql)
  withoutClause <- SqlRender::render(
    template,
    cdm_database_schema = "cdm",
    cohort_table = "#cohort_person",
    row_id_field = "row_id",
    analysis_id = 998,
    no_value_analysis_id = 999,
    time_part = "DAY",
    time_interval = 1,
    sequence_start_day = -99999,
    sequence_end_day = 0
  )
  cat("\n==== SparseArray MeasurementValueUnit.sql, default clause ====\n")
  print(data.frame(
    cohort_id_clause = "(default)",
    has_cohort_definition_id = grepl("cohort_definition_id", withoutClause,
                                     fixed = TRUE),
    unresolved_parameters = paste(unique(unlist(regmatches(
      withoutClause, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", withoutClause)
    ))), collapse = " "),
    characters = nchar(withoutClause),
    stringsAsFactors = FALSE
  ), row.names = FALSE)
}

# The study population and its flow counts render with and without the
# admission criterion, so both branches of the join are checked.
cat("
==== study population, both admission settings ====
")
admissionRows <- list()
for (file in c("StudyPopulation.sql", "StudyPopulationFlow.sql")) {
  template <- SqlRender::readSql(file.path(sqlFolder, file))
  for (required in c(0, 1)) {
    available <- parameters("sql server")
    available$require_qualifying_admission <- required
    used <- available[vapply(
      names(available),
      function(name) grepl(paste0("@", name, "\b"), template),
      logical(1)
    )]
    sql <- SqlRender::translate(
      do.call(SqlRender::render, c(list(sql = template), used)),
      targetDialect = "sql server"
    )
    admissionRows[[length(admissionRows) + 1]] <- data.frame(
      file = file,
      require_qualifying_admission = required,
      joins_admission_history = grepl("tabehr_admission_history", sql,
                                      fixed = TRUE),
      inner_join = grepl("INNER JOIN work.tabehr_admission_history", sql,
                         fixed = TRUE),
      unresolved_parameters = paste(unique(unlist(regmatches(
        sql, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", sql)
      ))), collapse = " "),
      stringsAsFactors = FALSE
    )
  }
}
print(do.call(rbind, admissionRows), row.names = FALSE)

failures <- results[!results$ok, , drop = FALSE]
cat("\n", nrow(results) - nrow(failures), "of", nrow(results), "ok\n")
if (nrow(failures) > 0) {
  cat("\n==== problems ====\n")
  print(failures, row.names = FALSE)
  quit(status = 1)
}
