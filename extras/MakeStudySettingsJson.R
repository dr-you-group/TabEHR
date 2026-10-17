# Writes inst/settings/studySettings.json: for every target and outcome pair,
# which covariate settings the features come from and which study population
# settings the labels come from. Read back by SparseArray::loadStudySettings().
#
# One-off script, not part of the package. Run from the repository root.
#
# The tasks and the two index dates they need:
#
#   death7      7-day mortality   admission  covariates .. 0   TAR day 1 .. 7
#   death30    30-day mortality   admission  covariates .. 0   TAR day 1 .. 30
#   longStay   length of stay     admission  covariates .. 0   TAR day 0
#   phenotype  phenotyping        admission  covariates .. 0   TAR day 0 .. discharge
#   readmit    30-day readmission discharge  covariates .. 0   TAR day 1 .. 30
#   newDx      new diagnoses      discharge  covariates .. 0   TAR day 1 .. 365
#
# Every task cuts its features at the end of its own index day: admission day
# 23:59 for the admission-anchored tasks, discharge day for the other two. That
# is sequenceEndDay = 0 throughout, since FeatureExtraction counts whole days.
#
# The two mortality tasks share the death cohort and differ only in the length
# of the risk window, which is why the settings are keyed by taskId.
#
# R1 and A need covariates up to discharge and time at risk starting the day
# after it. A single fixed sequenceEndDay cannot express that against an
# admission-indexed target, because the stay length differs per patient, so
# those two use Inpatient_visit_discharge as their target instead.

# Works either against the installed package or straight from the sources.
if (requireNamespace("SparseArray", quietly = TRUE)) {
  saveStudySettings <- SparseArray::saveStudySettings
} else {
  source("R/Settings.R")
  source("R/StudySettings.R")
}

cohortsFile      <- "inst/settings/CohortsToCreate.csv"
outFile          <- "inst/settings/studySettings.json"
admissionTarget  <- 1000L   # Inpatient_visit
dischargeTarget  <- 1003L   # Inpatient_visit_discharge

cohorts <- utils::read.csv(cohortsFile, stringsAsFactors = FALSE)
stopifnot(all(c("cohortId", "atlasName", "type") %in% names(cohorts)))
idsOfType <- function(type) {
  keep <- vapply(strsplit(cohorts$type, ";"), function(t) type %in% trimws(t),
                 logical(1))
  as.integer(cohorts$cohortId[keep])
}
phenotypeIds    <- idsOfType("phenotype")
newDiagnosisIds <- idsOfType("new_diagnoses")

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
allDomains <- list(
  useConditionOccurrence = TRUE,
  useDrugExposure = TRUE,
  useProcedureOccurrence = TRUE,
  useMeasurementValueUnit = TRUE
)

covariateSettings <- list(
  # Mortality and length of stay: everything known by admission day 23:59.
  admission = c(baseWindow, list(sequenceEndDay = 0), allDomains),
  # Phenotyping: the outcome is the conditions recorded during this stay, so
  # condition_occurrence is dropped from the features.
  admissionNoCondition = c(baseWindow, list(sequenceEndDay = 0), list(
    useConditionOccurrence = FALSE,
    useDrugExposure = TRUE,
    useProcedureOccurrence = TRUE,
    useMeasurementValueUnit = TRUE
  )),
  # Readmission and new diagnoses: indexed on the discharge date, so day 0 is
  # the discharge itself and the whole stay is in the lookback.
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

# Mortality, in and out of hospital, from the day after admission. minTimeAtRisk
# is riskWindowEnd - riskWindowStart, which requires the full window.
# removeSubjectsWithPriorOutcome drops anyone who died on the admission day.
mortality <- function(days) {
  list(
    removeSubjectsWithPriorOutcome = TRUE,
    requireTimeAtRisk = TRUE, minTimeAtRisk = days - 1,
    riskWindowStart = 1, startAnchor = "cohort start",
    riskWindowEnd = days, endAnchor = "cohort start"
  )
}

# The index admission itself lasted >= 7 days. The cohort shares the
# target's codeset and index date and only adds DATEDIFF >= 7, so the event
# lands exactly on day 0; collapsing the window to day 0 labels that admission
# and nothing else, where anchoring the end on "cohort end" would also catch a
# separate admission that started during the index stay.
longStay <- list(
  riskWindowStart = 0, startAnchor = "cohort start",
  riskWindowEnd = 0, endAnchor = "cohort start"
)

# Conditions recorded between admission and discharge.
phenotype <- list(
  riskWindowStart = 0, startAnchor = "cohort start",
  riskWindowEnd = 0, endAnchor = "cohort end"
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

settings <- c(
  list(
    task("death7", admissionTarget, 1001L, "admission", mortality(7L),
         "7-day mortality, in and out of hospital, from the day after admission"),
    task("death30", admissionTarget, 1001L, "admission", mortality(30L),
         "30-day mortality, in and out of hospital, from the day after admission"),
    task("longStay", admissionTarget, 1002L, "admission", longStay,
         "Long length of stay, index admission >= 7 days")
  ),
  lapply(phenotypeIds, function(id) {
    task(paste0("phenotype", id), admissionTarget, id, "admissionNoCondition",
         phenotype, "Phenotyping, condition during the index stay")
  }),
  list(
    task("readmit", dischargeTarget, admissionTarget, "discharge",
         readmission, "30-day readmission after discharge")
  ),
  lapply(newDiagnosisIds, function(id) {
    task(paste0("newDx", id), dischargeTarget, id, "discharge",
         newDiagnosis, "New diagnosis within 365 days of discharge")
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
  # The 27 phenotype tasks and the 7 new-diagnosis tasks are identical apart
  # from the outcome, so only the first of each is printed.
  family <- if (grepl("^(phenotype|newDx)", s$taskId)) {
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
