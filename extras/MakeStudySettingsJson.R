# Writes inst/settings/studySettings.json: for every target and outcome pair,
# which covariate settings the features come from and which study population
# settings the labels come from. Read back by SparseArray::loadStudySettings().
#
# One-off script, not part of the package. Run from the repository root.
#
# The tasks, both indexed on the discharge date:
#
#   readmit    30-day readmission discharge  covariates .. 0   TAR day 1 .. 30
#   newDx      new diagnoses      discharge  covariates .. 0   TAR day 1 .. 365
#
# Both cut their features at the end of the discharge day, which is
# sequenceEndDay = 0, since FeatureExtraction counts whole days. They need
# covariates up to discharge and time at risk starting the day after it, and a
# single fixed sequenceEndDay cannot express that against an admission-indexed
# target because the stay length differs per patient - hence
# Inpatient_visit_discharge rather than Inpatient_visit as the target.
#
# 2026-11-05: the previous set also held death7, death30, longStay and 27
# phenotype tasks, all indexed on admission. They were dropped with their
# cohort definitions, which are kept in SparseArray/extras/retired_cohort_sql/.
# The newDx outcomes changed with them: 21 diseases defined by the reference
# table's ICD-10 codes, mapped to SNOMED and expanded over descendants, built
# by SparseArray/extras/MakeNewDxCohortSql.R. The task settings are unchanged -
# first diagnosis in the year after discharge.

# Works either against the installed package or straight from the sources.
if (requireNamespace("SparseArray", quietly = TRUE)) {
  saveStudySettings <- SparseArray::saveStudySettings
} else {
  source("R/Settings.R")
  source("R/StudySettings.R")
}

# The cohort definitions stay in SparseArray; only the task definitions moved
# here, so this reads across to that copy. Run from the TabEHR root.
cohortsFile      <- "SparseArray/inst/settings/CohortsToCreate.csv"
outFile          <- "inst/settings/studySettings.json"
admissionTarget  <- 1000L   # Inpatient_visit, the readmission outcome
dischargeTarget  <- 1003L   # Inpatient_visit_discharge, the only target left

cohorts <- utils::read.csv(cohortsFile, stringsAsFactors = FALSE)
stopifnot(all(c("cohortId", "atlasName", "type") %in% names(cohorts)))
idsOfType <- function(type) {
  keep <- vapply(strsplit(cohorts$type, ";"), function(t) type %in% trimws(t),
                 logical(1))
  as.integer(cohorts$cohortId[keep])
}
newDiagnosisIds <- idsOfType("new_diagnoses")
if (length(newDiagnosisIds) == 0) {
  stop(cohortsFile, " registers no cohort of type new_diagnoses. Run ",
       "SparseArray/extras/AddSnomedToNewDxCsv.R and then ",
       "SparseArray/extras/MakeNewDxCohortSql.R first.", call. = FALSE)
}

# ---------------------------------------------------------------------------
# Covariate settings. One day per time position, a year of lookback.
# ---------------------------------------------------------------------------
# sequenceStartDay = -99999 is FeatureExtraction's way of saying "no lower
# bound": its SQL turns it into a single date predicate,
#   @domain_start_date >= DATEADD(DAY, -99999, cohort_start_date),
# so each subject contributes every record they have rather than a fixed year.
# The sparse array stage then has to be run with timeAxis = "observed", or its
# day axis would span the whole requested window instead of the history the
# data actually holds.
baseWindow <- list(
  settingsType = "temporalSequence",
  timePart = "day",
  timeInterval = 1,
  sequenceStartDay = -99999
)
# useMeasurementValueUnit is this package's measurement value analysis, not
# FeatureExtraction's useMeasurementValue: the temporal sequence branch of
# FeatureExtraction's MeasurementValue.sql does not render to valid SQL, see
# createMeasurementValueUnitCovariateSettings(). The covariate ids are the same
# either way. Note that this is the value of a measurement, so a measurement
# with no numeric value contributes nothing; FeatureExtraction's useMeasurement
# (analysis 701) is the covariate that only says the measurement was taken.
# measurementValueAggregate has to match the one in analysisSettings.json:
# allrecords is built with that setting and the task input is cut out of
# allrecords, so a different aggregate here would make
# featureExtractionLong.csv disagree with the input it is meant to describe.
allDomains <- list(
  useConditionOccurrence = TRUE,
  useDrugExposure = TRUE,
  useProcedureOccurrence = TRUE,
  useMeasurementValueUnit = TRUE,
  measurementValueAggregate = "min"
)

# Readmission and new diagnoses: indexed on the discharge date, so day 0 is the
# discharge itself and the whole stay is in the lookback. One block, so the
# pipeline extracts once - the admission-indexed blocks went with the tasks
# that used them.
covariateSettings <- list(
  discharge = c(baseWindow, list(sequenceEndDay = 0), allDomains)
)

# ---------------------------------------------------------------------------
# Study population settings
# ---------------------------------------------------------------------------
defaultPopulationSettings <- list(
  binary = TRUE,
  includeAllOutcomes = TRUE,
  firstExposureOnly = FALSE,
  washoutPeriod = 0,
  removeSubjectsWithPriorOutcome = FALSE,
  priorOutcomeLookback = 99999,
  requireTimeAtRisk = FALSE,
  minTimeAtRisk = 0,
  riskWindowStart = 0,
  startAnchor = "cohort start",
  riskWindowEnd = 0,
  endAnchor = "cohort end",
  restrictTarToCohortEnd = FALSE
)

# 30 days from the index date, which is already the discharge for this
# target. The target is itself an inpatient visit, so every subject has a prior
# outcome and removeSubjectsWithPriorOutcome has to stay FALSE. minTimeAtRisk is
# riskWindowEnd - riskWindowStart, which requires the full window.
readmission <- list(
  requireTimeAtRisk = TRUE, minTimeAtRisk = 29,
  riskWindowStart = 1, startAnchor = "cohort start",
  riskWindowEnd = 30, endAnchor = "cohort start"
)

# First-ever diagnosis in the year after discharge, so prior cases go.
newDiagnosis <- list(
  removeSubjectsWithPriorOutcome = TRUE,
  requireTimeAtRisk = TRUE, minTimeAtRisk = 364,
  riskWindowStart = 1, startAnchor = "cohort start",
  riskWindowEnd = 365, endAnchor = "cohort start"
)

# ---------------------------------------------------------------------------
task <- function(taskId, targetId, outcomeId, covariateSettingsId,
                 populationSettings, note) {
  list(taskId = taskId, targetId = targetId, outcomeId = outcomeId,
       covariateSettingsId = covariateSettingsId,
       populationSettings = populationSettings, note = note)
}

# The outcome name goes into the note, so a label file says which disease it
# holds without a lookup in CohortsToCreate.csv.
outcomeName <- function(id) {
  name <- cohorts$atlasName[as.integer(cohorts$cohortId) == id]
  if (length(name) == 1) name else as.character(id)
}

settings <- c(
  list(
    task("readmit", dischargeTarget, admissionTarget, "discharge",
         readmission, "30-day readmission after discharge")
  ),
  lapply(newDiagnosisIds, function(id) {
    task(paste0("newDx", id), dischargeTarget, id, "discharge",
         newDiagnosis,
         paste0("First ", outcomeName(id),
                " diagnosis within 365 days of discharge"))
  })
)

saveStudySettings(
  covariateSettings = covariateSettings,
  defaultPopulationSettings = defaultPopulationSettings,
  settings = settings,
  file = outFile
)

cat("wrote", outFile, "-", length(settings), "tasks

")
cat(sprintf("%-14s %-5s %-5s %-21s %-5s %-12s %-5s %-12s %-6s %-6s %s
",
            "taskId", "tgt", "out", "covSettings", "tarS", "startAnchor",
            "tarE", "endAnchor", "reqTAR", "minTAR", "rmPrior"))
shown <- character(0)
for (s in settings) {
  # The new-diagnosis tasks are identical apart from the outcome, so only the
  # first of them is printed.
  family <- if (grepl("^newDx", s$taskId)) {
    sub("[0-9]+$", "", s$taskId)
  } else {
    s$taskId
  }
  if (family %in% shown) next
  shown <- c(shown, family)
  p <- modifyList(defaultPopulationSettings, s$populationSettings)
  cat(sprintf("%-14s %-5d %-5d %-21s %-5d %-12s %-5d %-12s %-6s %-6d %s
",
              s$taskId, s$targetId, s$outcomeId, s$covariateSettingsId,
              p$riskWindowStart, p$startAnchor, p$riskWindowEnd, p$endAnchor,
              p$requireTimeAtRisk, p$minTimeAtRisk,
              p$removeSubjectsWithPriorOutcome))
}
