# Does a packaged cohort definition take a @restrict_person_table parameter?
#' @noRd
.declaresRestrictPersonTable <- function(sqlFilename) {
  path <- system.file("sql", "sql_server", sqlFilename,
                      package = "SparseArray")
  if (!nzchar(path) || !file.exists(path)) {
    return(FALSE)
  }
  any(grepl("@restrict_person_table", readLines(path, warn = FALSE),
            fixed = TRUE))
}

#' Create the study cohorts
#'
#' @param connectionDetails A DatabaseConnector connection-details object.
#' @param cdmDatabaseSchema Schema containing the OMOP CDM.
#' @param vocabularyDatabaseSchema Schema containing the OMOP vocabulary.
#' @param cohortDatabaseSchema Schema where cohorts will be created.
#' @param cohortTable Name of the cohort table.
#' @param oracleTempSchema Schema used to emulate temporary tables.
#' @param outputFolder Folder for cohort counts.
#' @param restrictPersonTable Optional name of a table in
#'   `cohortDatabaseSchema` with a `person_id` column. When given, the cohort
#'   definitions that declare a `@restrict_person_table` parameter admit only
#'   those persons, and the ones that do not declare it are rendered exactly as
#'   they would be without this argument. It restricts who a cohort is built
#'   from without changing what the cohort definition selects.
#'
#' @export
createCohorts <- function(connectionDetails,
                          cdmDatabaseSchema,
                          vocabularyDatabaseSchema = cdmDatabaseSchema,
                          cohortDatabaseSchema,
                          cohortTable,
                          oracleTempSchema,
                          outputFolder,
                          restrictPersonTable = NULL) {
  if (!file.exists(outputFolder)) {
    dir.create(outputFolder, recursive = TRUE)
  }

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))

  sql <- SqlRender::loadRenderTranslateSql(
    sqlFilename = "CreateCohortTable.sql",
    packageName = "SparseArray",
    dbms = attr(connection, "dbms"),
    tempEmulationSchema = oracleTempSchema,
    cohort_database_schema = cohortDatabaseSchema,
    cohort_table = cohortTable
  )
  DatabaseConnector::executeSql(
    connection,
    sql,
    progressBar = FALSE,
    reportOverallTime = FALSE
  )

  pathToCsv <- system.file(
    "settings",
    "CohortsToCreate.csv",
    package = "SparseArray"
  )
  cohortsToCreate <- read.csv(pathToCsv)
  for (i in seq_len(nrow(cohortsToCreate))) {
    ParallelLogger::logInfo("Creating cohort: ", cohortsToCreate$name[i])
    sqlFilename <- paste0(cohortsToCreate$name[i], ".sql")
    arguments <- list(
      sqlFilename = sqlFilename,
      packageName = "SparseArray",
      dbms = attr(connection, "dbms"),
      tempEmulationSchema = oracleTempSchema,
      cdm_database_schema = cdmDatabaseSchema,
      vocabulary_database_schema = vocabularyDatabaseSchema,
      target_database_schema = cohortDatabaseSchema,
      target_cohort_table = cohortTable,
      target_cohort_id = cohortsToCreate$cohortId[i]
    )
    # Only the definitions that declare the parameter are given it: SqlRender
    # warns about a parameter it cannot find, and the cohorts that are not
    # restricted should render byte for byte as they did before.
    if (!is.null(restrictPersonTable) &&
        .declaresRestrictPersonTable(sqlFilename)) {
      arguments$restrict_person_table <- restrictPersonTable
    }
    sql <- do.call(SqlRender::loadRenderTranslateSql, arguments)
    DatabaseConnector::executeSql(connection, sql)
  }

  sql <- paste(
    "SELECT cohort_definition_id, COUNT(*) AS count",
    "FROM @cohort_database_schema.@cohort_table",
    "GROUP BY cohort_definition_id"
  )
  sql <- SqlRender::render(
    sql,
    cohort_database_schema = cohortDatabaseSchema,
    cohort_table = cohortTable
  )
  sql <- SqlRender::translate(
    sql,
    targetDialect = attr(connection, "dbms")
  )
  counts <- DatabaseConnector::querySql(connection, sql)
  names(counts) <- SqlRender::snakeCaseToCamelCase(names(counts))
  counts <- merge(
    counts,
    data.frame(
      cohortDefinitionId = cohortsToCreate$cohortId,
      cohortName = cohortsToCreate$name
    )
  )
  write.csv(counts, file.path(outputFolder, "CohortCounts.csv"), row.names = FALSE)

  invisible(NULL)
}
