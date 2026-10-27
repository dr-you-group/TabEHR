# Copyright 2026 TabEHR Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

#' Select the study population
#'
#' The criteria of the study, all of which must hold:
#'
#' \describe{
#'   \item{adult}{applied per record while the records were extracted, so a
#'     patient reaches this stage only if an adult record survived.}
#'   \item{records}{at least `minRecordCount` de-duplicated records.}
#'   \item{admission}{at least one inpatient visit whose length of stay reaches
#'     `minAdmissionLengthOfStay`, with the patient an adult at admission. Only
#'     applied when `requireQualifyingAdmission` is `TRUE`, which it is not by
#'     default, see [createPopulationSettings()].}
#' }
#'
#' The qualifying admissions are counted for every patient either way, into
#' `n_admissions` of the study population table and into the flow table, so
#' turning the criterion on afterwards needs no new query. Being a patient level
#' inclusion criterion, it would not restrict which of that patient's records
#' are used afterwards, and it does not change the SparseArray target cohort,
#' which keeps its own one day minimum.
#'
#' Writes `study_population.csv` and `study_population_flow.csv`, the counts for
#' the flow diagram.
#'
#' @template databaseArgs
#' @template analysisArgs
#'
#' @return Invisibly, a list with the `flow` counts and the number of patients.
#' @export
createStudyPopulation <- function(connectionDetails,
                                  cdmDatabaseSchema,
                                  vocabularyDatabaseSchema = cdmDatabaseSchema,
                                  cohortDatabaseSchema,
                                  tablePrefix = "tabehr_",
                                  tempEmulationSchema = NULL,
                                  outputFolder,
                                  analysisSettings = loadAnalysisSettings()) {
  checkmate::assertClass(analysisSettings, "tabehrAnalysisSettings")
  checkmate::assertString(outputFolder, min.chars = 1)
  .ensureFolder(outputFolder)
  tableNames <- getTabehrTableNames(tablePrefix)
  population <- analysisSettings$populationSettings

  connection <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(connection))

  qualified <- function(name) paste0(cohortDatabaseSchema, ".", name)
  sampleTable <- .personSampleTable(analysisSettings, cohortDatabaseSchema,
                                    tableNames)

  ParallelLogger::logInfo(
    "Counting inpatient admissions of ", population$lengthOfStayOperator, " ",
    population$minAdmissionLengthOfStay, " day(s), which are ",
    if (population$requireQualifyingAdmission) "required" else
      "reported but not required"
  )
  .executeTabehrSql(
    connection, "AdmissionHistory.sql",
    tempEmulationSchema = tempEmulationSchema,
    cdm_database_schema = cdmDatabaseSchema,
    vocabulary_database_schema = vocabularyDatabaseSchema,
    admission_history_table = qualified(tableNames$admissionHistory),
    person_sample_table = sampleTable,
    inpatient_concept_ids = paste(population$inpatientConceptIds,
                                  collapse = ", "),
    include_descendant_visit_concepts =
      as.integer(population$includeDescendantVisitConcepts),
    length_of_stay_operator = population$lengthOfStayOperator,
    min_length_of_stay = population$minAdmissionLengthOfStay,
    adult_age_min = analysisSettings$preprocessSettings$adultAgeMin
  )

  ParallelLogger::logInfo("Applying the study population criteria")
  .executeTabehrSql(
    connection, "StudyPopulation.sql",
    tempEmulationSchema = tempEmulationSchema,
    study_population_table = qualified(tableNames$studyPopulation),
    record_counts_table = qualified(tableNames$recordCounts),
    admission_history_table = qualified(tableNames$admissionHistory),
    min_record_count = population$minRecordCount,
    require_qualifying_admission =
      as.integer(population$requireQualifyingAdmission)
  )

  flow <- .queryTabehrSql(
    connection, "StudyPopulationFlow.sql",
    tempEmulationSchema = tempEmulationSchema,
    cdm_database_schema = cdmDatabaseSchema,
    record_counts_table = qualified(tableNames$recordCounts),
    admission_history_table = qualified(tableNames$admissionHistory),
    study_population_table = qualified(tableNames$studyPopulation),
    person_sample_table = sampleTable,
    min_record_count = population$minRecordCount,
    require_qualifying_admission =
      as.integer(population$requireQualifyingAdmission)
  )
  flow <- .describeFlow(flow, population$requireQualifyingAdmission)
  writeTabehrCsv(flow, file.path(outputFolder, "study_population_flow.csv"))

  patients <- .queryTabehrSql(
    connection, "ExportStudyPopulation.sql",
    tempEmulationSchema = tempEmulationSchema,
    study_population_table = qualified(tableNames$studyPopulation),
    snakeCaseToCamelCase = FALSE
  )
  patients <- .assertCharacterIds(patients, "person_id")
  writeTabehrCsv(patients, file.path(outputFolder, "study_population.csv"))

  ParallelLogger::logInfo("Study population: ", nrow(patients), " patient(s)")
  invisible(list(flow = flow, personCount = nrow(patients)))
}

# Readable labels for the flow table, in the order of the criteria. The
# admission step is absent from the query result when the criterion is off, and
# then the marginal rows report what it would have cost.
#' @noRd
.describeFlow <- function(flow, requireQualifyingAdmission = FALSE) {
  labels <- c(
    all_persons = "all patients in the CDM",
    with_adult_record = "and with an adult record after the preprocessing",
    with_qualifying_admission = "and with a qualifying inpatient admission",
    with_min_records = "and with enough records (study population)",
    only_record_count_criterion = "marginal: enough records, any admission",
    lost_to_admission_only = if (requireQualifyingAdmission)
      "marginal: lost to the admission criterion alone" else
      "marginal: would be lost to the admission criterion alone",
    lost_to_record_count_only = "marginal: lost to the record count alone"
  )
  flow <- flow[order(flow$stepOrder), ]
  data.frame(
    step_order = flow$stepOrder,
    step = flow$step,
    description = ifelse(flow$step %in% names(labels), labels[flow$step],
                         flow$step),
    n_person = flow$nPerson,
    stringsAsFactors = FALSE
  )
}
