# One extraction, end to end. This package extracts; which extractions a study
# needs, with which covariate settings and which outcomes, belongs to the study
# definition. In this project that definition lives in TabEHR
# (inst/settings/studySettings.json) and TabEHR calls the functions below in a
# loop, so this script is the single-extraction example rather than the entry
# point.
library(SparseArray)

# Use a local disk with enough capacity for Andromeda temporary files.
options(
  andromedaTempFolder = Sys.getenv("SPARSE_ARRAY_ANDROMEDA_TEMP_FOLDER")
)

# Folder for study artifacts.
outputFolder <- Sys.getenv("SPARSE_ARRAY_OUTPUT_FOLDER")

# SQL Server connection details. Keep credentials in environment variables.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server",
  server = Sys.getenv("SPARSE_ARRAY_DB_SERVER"),
  user = Sys.getenv("SPARSE_ARRAY_DB_USER"),
  password = Sys.getenv("SPARSE_ARRAY_DB_PASSWORD"),
  port = Sys.getenv("SPARSE_ARRAY_DB_PORT")
)

# OMOP CDM and study cohort locations.
cdmDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_CDM_DATABASE_SCHEMA")
cohortDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_COHORT_DATABASE_SCHEMA")
cohortTable <- Sys.getenv("SPARSE_ARRAY_COHORT_TABLE", unset = "cohort")
oracleTempSchema <- NULL

batchSize <- as.numeric(
  Sys.getenv("SPARSE_ARRAY_BATCH_SIZE", unset = "1000000")
)

# The cohorts: 38 outcome phenotypes and the target cohorts they are predicted
# from. restrictPersonTable limits the target cohorts to the patients in a
# table of person_id, which is how TabEHR runs this on its downstream patients
# only; leave it NULL to use everyone.
createCohorts(
  connectionDetails = connectionDetails,
  cdmDatabaseSchema = cdmDatabaseSchema,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTable = cohortTable,
  oracleTempSchema = oracleTempSchema,
  outputFolder = outputFolder,
  restrictPersonTable = NULL
)

# What to extract. A flat argument list rather than a constructor call, because
# that is the shape a settings file stores and buildCovariateSettings() is what
# turns it into the list of settings objects an extraction needs: this package's
# measurement covariates are asked for with useMeasurementValueUnit, alongside
# FeatureExtraction's own use* flags.
covariateSettings <- buildCovariateSettings(list(
  settingsType = "temporalSequence",
  timePart = "day",
  timeInterval = 1,
  sequenceStartDay = -99999,
  sequenceEndDay = 0,
  useConditionOccurrence = TRUE,
  useDrugExposure = TRUE,
  useProcedureOccurrence = TRUE,
  useMeasurementValueUnit = TRUE
))

extractPlpData(
  connectionDetails = connectionDetails,
  cdmDatabaseSchema = cdmDatabaseSchema,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTable = cohortTable,
  oracleTempSchema = oracleTempSchema,
  outputFolder = outputFolder,
  extractionName = "target1000_admission",
  targetId = 1000,
  outcomeIds = c(1001, 1002),
  covariateSettings = covariateSettings
)

# A measurement value covariate id keeps the unit only as
# unit_concept_id % 1000, so the (concept, unit) pair is read back from the CDM
# into one crosswalk per output folder, which createLongFormat() joins into
# covariateRef.csv.
exportMeasurementValueUnitRef(
  connectionDetails = connectionDetails,
  cdmDatabaseSchema = cdmDatabaseSchema,
  oracleTempSchema = oracleTempSchema,
  outputFolder = outputFolder
)

createLongFormat(
  outputFolder = outputFolder,
  extraction = "target1000_admission",
  batchSize = batchSize
)

# The three-dimensional sparse array is optional and lives outside the package.
# featureExtractionLong.csv, covariateRef.csv and timeRef.csv are written by the
# pipeline above, and the labels come from the study package.
#
# source("extras/CreateSparseArray.R")
# array <- createSparseArray(
#   outputFolder,
#   extraction = "target1000_admission",
#   timeAxis = "observed"   # the settings ask for every record a subject has
# )
