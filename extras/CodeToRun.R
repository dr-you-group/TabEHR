# The runner. Copy it, fill in the site's details, and run it.
#
# Everything site specific lives here, not in the package: the connection, the
# schema names, and where the output goes. The analysis settings, which are the
# same at every site, come from the package and can be overridden below.
#
# SparseArray has to be installed from the copy in this project, because
# createCohorts() reads its cohort SQL from the installed package:
#
#   R CMD INSTALL SparseArray
#   R CMD INSTALL .

library(TabEHR)

# Credentials and schema names from the environment, so nothing secret is in a
# tracked file. The variable names are the ones SparseArray already uses, so
# one .env serves both.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server",
  server = Sys.getenv("SPARSE_ARRAY_DB_SERVER"),
  user = Sys.getenv("SPARSE_ARRAY_DB_USER"),
  password = Sys.getenv("SPARSE_ARRAY_DB_PASSWORD"),
  port = Sys.getenv("SPARSE_ARRAY_DB_PORT", unset = "1433"),
  pathToDriver = Sys.getenv("SPARSE_ARRAY_JDBC_FOLDER",
                            unset = "/home/rstudio/jdbc")
)

databaseId <- "mimic"
cdmDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_CDM_DATABASE_SCHEMA")
vocabularyDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_VOCABULARY_DATABASE_SCHEMA",
                                       unset = cdmDatabaseSchema)
# Needs create and drop rights: the cohort table and every table this package
# creates live here.
cohortDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_COHORT_DATABASE_SCHEMA")
cohortTable <- Sys.getenv("SPARSE_ARRAY_COHORT_TABLE", unset = "cohort_v3")

# One folder per database, so an external site cannot overwrite the primary
# site's results.
outputFolder <- file.path(Sys.getenv("TABEHR_OUTPUT_FOLDER", unset = "output"),
                          databaseId)

# A local disk with room for the Andromeda temporary files.
options(andromedaTempFolder = Sys.getenv("SPARSE_ARRAY_ANDROMEDA_TEMP_FOLDER"))

# ---------------------------------------------------------------------------
# The full run.
# ---------------------------------------------------------------------------
analysisSettings <- createAnalysisSettings()

execute(
  connectionDetails = connectionDetails,
  cdmDatabaseSchema = cdmDatabaseSchema,
  vocabularyDatabaseSchema = vocabularyDatabaseSchema,
  cohortDatabaseSchema = cohortDatabaseSchema,
  cohortTable = cohortTable,
  outputFolder = outputFolder,
  databaseId = databaseId,
  analysisSettings = analysisSettings,
  checkDatabase = TRUE,
  extractRecords = TRUE,
  createStudyPopulation = TRUE,
  createPersonSplit = TRUE,
  createAllRecords = TRUE,
  createTaskInput = TRUE,
  runDiagnostics = TRUE
)

# ---------------------------------------------------------------------------
# A trial run on 1,000 patients. Use these settings in the call above instead,
# and run from extractRecords on: every table is rebuilt from the sample.
# ---------------------------------------------------------------------------
# analysisSettings <- createAnalysisSettings(
#   personSampleSettings = createPersonSampleSettings(samplePersonCount = 1000)
# )

# ---------------------------------------------------------------------------
# An external validation site: no split of its own.
# ---------------------------------------------------------------------------
# execute(
#   connectionDetails = connectionDetails,
#   cdmDatabaseSchema = cdmDatabaseSchema,
#   vocabularyDatabaseSchema = vocabularyDatabaseSchema,
#   cohortDatabaseSchema = cohortDatabaseSchema,
#   cohortTable = cohortTable,
#   outputFolder = file.path("output", "yuhs"),
#   databaseId = "yuhs",
#   analysisSettings = createAnalysisSettings(siteRole = "external")
# )

# ---------------------------------------------------------------------------
# Stages on their own, when a run has to be resumed. Every stage takes the same
# arguments as execute().
# ---------------------------------------------------------------------------
# createAllRecords(
#   connectionDetails = connectionDetails,
#   cdmDatabaseSchema = cdmDatabaseSchema,
#   cohortDatabaseSchema = cohortDatabaseSchema,
#   outputFolder = outputFolder,
#   analysisSettings = analysisSettings
# )
#
# createTaskInput(
#   connectionDetails = connectionDetails,
#   cdmDatabaseSchema = cdmDatabaseSchema,
#   vocabularyDatabaseSchema = vocabularyDatabaseSchema,
#   cohortDatabaseSchema = cohortDatabaseSchema,
#   cohortTable = cohortTable,
#   outputFolder = outputFolder,
#   databaseId = databaseId
# )

# ---------------------------------------------------------------------------
# The MedRep comparison files, which are not part of the pipeline.
# ---------------------------------------------------------------------------
# Rscript extras/CreateMedRepFiles.R output/mimic 10
