SparseArray
===========

SparseArray is an OHDSI study package that creates a configured OMOP cohort,
extracts **temporal sequence** patient-level covariates with FeatureExtraction,
and converts the persisted covariates into a deterministic three-dimensional
sparse array of patient by time position by covariate.

It produces two artifacts: the FeatureExtraction output in long format, and the
sparse array. The array dimension order is `patient x time x covariate`, which
is the `(samples, timesteps, features)` layout that sequence models such as
CNN, RNN, and CIReNN expect.

The main path uses
[`createTemporalSequenceCovariateSettings()`](https://ohdsi.github.io/FeatureExtraction/reference/createTemporalSequenceCovariateSettings.html),
where the time axis is one repeated fixed-length interval counted back from the
index date rather than a hand-written list of windows. FeatureExtraction
computes the position of every covariate on the server as

```text
timeId = FLOOR(DATEDIFF(timePart, eventDate, indexDate) / timeInterval)
```

so `timeId` 0 is the interval ending on the index date and `timeId` grows going
back in time. `extras/CreateSparseArray.R` keeps that order rather than reversing it, so
for a lookback window time index 1 of the array is the interval **nearest** the
index date. Reverse the time dimension downstream if a model needs
oldest-to-newest input.
[`createTemporalCovariateSettings()`](https://ohdsi.github.io/FeatureExtraction/reference/createTemporalCovariateSettings.html)
window settings remain supported for comparison runs; those are ordered by
`startDay`, so their time index 1 is the oldest window. The two settings families
are deliberately not forced to agree — `timeAxis$timeIndexOrder` in the result
records which rule was used.

Requirements
============

- An [OMOP Common Data Model version 5](https://github.com/OHDSI/CommonDataModel)
  database on Microsoft SQL Server.
- Read access to the CDM and vocabulary tables, plus permission to create and
  drop the configured study cohort table.
- R 4.0.0 or newer and Java with a compatible Microsoft SQL Server JDBC driver.
  R package dependencies are declared in `DESCRIPTION`.
- Docker with Docker Compose when using the included Web RStudio environment.
  `DockerImage/Dockerfile` builds the pinned stack described below, matching the
  sibling [SparseMatrix](https://github.com/dr-you-group/SparseMatrix/blob/main/DockerImage/Dockerfile)
  study package and adding `slam`, `checkmate`, and this package.
- Enough local disk space for Andromeda temporary data and study artifacts, and
  enough memory for the final sparse array.

The pinned environment is:

- Microsoft SQL Server `16.0.1000.6` (64-bit).
- `rocker/rstudio:4.1.2`, so R `4.1.2` and a CRAN snapshot from that release.
- OpenJDK (Debian `default-jdk`) and the Microsoft JDBC Driver for SQL Server
  downloaded by `DatabaseConnector::downloadJdbcDrivers()`.
- Andromeda `0.6.0`
- SqlRender `1.9.0`
- DatabaseConnector `5.0.2`
- CohortGenerator `0.4.0`
- ParallelLogger `2.0.2`
- FeatureExtraction `3.2.0`, which is the version
  `createTemporalSequenceCovariateSettings()` is used from here.
- `slam` and `checkmate` from the same CRAN snapshot.

The project has been exercised in an Ubuntu virtual environment with 12 CPU
cores and 128 GB of RAM. The included Web RStudio service uses port `48787`.

How to run
==========

1. Copy the environment template and enter the RStudio password, database
   connection, schema, cohort-table, and batch-size settings. Keep `.env`
   private:

   ```sh
   cp .env.example .env
   chmod 600 .env
   ```

   Use site-specific values following this structure:

   ```dotenv
   FEATURE_EXTRACTION_V3_RSTUDIO_PASSWORD='change-me'
   SPARSE_ARRAY_ANDROMEDA_TEMP_FOLDER='/home/rstudio/feature_extraction_v3/data/andromeda'
   SPARSE_ARRAY_OUTPUT_FOLDER='/home/rstudio/feature_extraction_v3/output'
   SPARSE_ARRAY_COVARIATE_SETTINGS_FILE=''
   SPARSE_ARRAY_JDBC_FOLDER=''
   SPARSE_ARRAY_DB_SERVER='sql server'
   SPARSE_ARRAY_DB_PORT='1433'
   SPARSE_ARRAY_DB_USER='database-user'
   SPARSE_ARRAY_DB_PASSWORD='change-me'
   SPARSE_ARRAY_CDM_DATABASE_SCHEMA='database.schema'
   SPARSE_ARRAY_COHORT_DATABASE_SCHEMA='database.schema'
   SPARSE_ARRAY_COHORT_TABLE='cohort_v3'
   SPARSE_ARRAY_BATCH_SIZE='1000000'
   ```

   Create the local runtime folders with `mkdir -p data/andromeda output jdbc`.
   The image already contains a Microsoft SQL Server JDBC driver, and compose
   points `DATABASECONNECTOR_JAR_FOLDER` at it. To use a site-specific driver
   instead, place it in `jdbc/` and set
   `SPARSE_ARRAY_JDBC_FOLDER='/home/rstudio/feature_extraction_v3/jdbc'`.
   For arguments used in createConnectionDetails(), see the (https://ohdsi.github.io/DatabaseConnector/reference/createConnectionDetails.html).
   If `.env` is changed after the container has been created, recreate the service so the
   new values are injected:

   ```sh
   docker compose up -d --force-recreate rstudio
   ```

2. Build and start Web RStudio:

   ```sh
   BUILDX_CONFIG=/tmp/feature-extraction-v3-buildx docker compose up -d --build rstudio
   ```

   Open `http://localhost:48787` and sign in as `rstudio` using
   `FEATURE_EXTRACTION_V3_RSTUDIO_PASSWORD`. When Docker runs on the configured
   remote host, the included relay can be managed with:

   ```sh
   scripts/rstudio-48787-proxy-control.sh start
   scripts/rstudio-48787-proxy-control.sh status
   ```

3. Open the project in RStudio. If the covariates or the time axis need to be
   changed, edit and run `extras/CreateCovariateSettings.R`. Then select
   **Build** and **Install and Restart** so the current R functions, SQL, and
   settings are installed.

   **Temporal sequence covariate settings**

   The settings define both the covariates and the time axis of the array. Edit
   and run `extras/CreateCovariateSettings.R`.

   ```r
   covariateSettingsArgs <- list(
     useConditionOccurrence = TRUE,
     useDrugExposure = TRUE,
     useProcedureOccurrence = TRUE,
     useMeasurement = TRUE,
     timePart = "day",
     timeInterval = 30,
     sequenceStartDay = -359,
     sequenceEndDay = -1,
     includedCovariateConceptIds = c(),
     addDescendantsToInclude = FALSE,
     excludedCovariateConceptIds = c(),
     addDescendantsToExclude = FALSE,
     includedCovariateIds = c()
   )

   settingsFolder <- file.path(getwd(), "inst/settings")
   if (!file.exists(settingsFolder)) {
     dir.create(settingsFolder, recursive = TRUE, showWarnings = FALSE)
   }

   covariateSettingsFile <- file.path(settingsFolder, "covariateSettings.json")
   saveCovariateSettings(
     covariateSettingsArgs = covariateSettingsArgs,
     file = covariateSettingsFile,
     settingsType = "temporalSequence"
   )
   ```

   `timePart` (`"day"`, `"month"`, or `"year"`), `timeInterval`,
   `sequenceStartDay`, and `sequenceEndDay` are required. One interval of
   `timeInterval` units of `timePart` is one position on the time axis. The
   default is thirty-day intervals covering the year before the index date, with
   the index date itself excluded: because the earliest included day is `-359`,
   `FLOOR(daysBeforeIndex / 30)` yields exactly the twelve positions 0 to 11, so
   the time axis has length 12.

   Keep `timePart = "day"` when a reproducible time axis matters. Day arithmetic
   is exact, so the axis follows from the settings alone and is identical across
   cohorts and databases, and `timeMap` can report each position as a
   `startDay`/`endDay` pair. With `"month"` or `"year"` the server counts
   calendar boundaries, so the number of positions depends on where the dates
   fall in the calendar; `extras/CreateSparseArray.R` then derives the axis from the
   observed positions and leaves `startDay` and `endDay` empty.

   The settings are saved to `inst/settings/covariateSettings.json` and included
   with the package.

   For the available covariate arguments, see the
   [FeatureExtraction `createTemporalSequenceCovariateSettings()` reference](https://ohdsi.github.io/FeatureExtraction/reference/createTemporalSequenceCovariateSettings.html).

   **Temporal window settings**

   Window settings stay supported for comparison runs. Pass
   `temporalStartDays` and `temporalEndDays` of equal length with
   `settingsType = "temporal"`; each pair is one position on the time axis. A
   commented example is included in `extras/CreateCovariateSettings.R`. See the
   [`createTemporalCovariateSettings()` reference](https://ohdsi.github.io/FeatureExtraction/reference/createTemporalCovariateSettings.html).

   **Covariates without a time position**

   Non-temporal analyses such as `useDemographicsGender` are returned by
   FeatureExtraction with an empty `time_id`, so they have no place on the time
   axis. They are an error by default. Either leave them out of the settings, or
   set `dropStaticCovariates = TRUE` to exclude them from the array; the
   excluded covariates are then listed under `staticCovariateRef` in the result,
   and they are still present in the long-format CSV.

4. Run the study using `extras/CodeToRun.R`. Its essential configuration and
   stage call are shown below:

   ```r
   library(SparseArray)

   # Local folders used for Andromeda and study artifacts:
   options(
     andromedaTempFolder = Sys.getenv("SPARSE_ARRAY_ANDROMEDA_TEMP_FOLDER")
   )
   outputFolder <- Sys.getenv("SPARSE_ARRAY_OUTPUT_FOLDER")

   # SQL Server connection details:
   connectionDetails <- DatabaseConnector::createConnectionDetails(
     dbms = "sql server",
     server = Sys.getenv("SPARSE_ARRAY_DB_SERVER"),
     user = Sys.getenv("SPARSE_ARRAY_DB_USER"),
     password = Sys.getenv("SPARSE_ARRAY_DB_PASSWORD"),
     port = Sys.getenv("SPARSE_ARRAY_DB_PORT")
   )

   # OMOP CDM and study cohort locations:
   cdmDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_CDM_DATABASE_SCHEMA")
   cohortDatabaseSchema <- Sys.getenv("SPARSE_ARRAY_COHORT_DATABASE_SCHEMA")
   cohortTable <- Sys.getenv("SPARSE_ARRAY_COHORT_TABLE", unset = "cohort")
   oracleTempSchema <- NULL

   # Empty means the temporal sequence settings installed with the package:
   covariateSettingsFile <- Sys.getenv("SPARSE_ARRAY_COVARIATE_SETTINGS_FILE")
   if (covariateSettingsFile == "") {
     covariateSettingsFile <- system.file(
       "settings",
       "covariateSettings.json",
       package = "SparseArray"
     )
   }

   batchSize <- as.numeric(
     Sys.getenv("SPARSE_ARRAY_BATCH_SIZE", unset = "1000000")
   )

   createCohorts(...)                  # the cohorts, optionally restricted
   covariateSettings <- buildCovariateSettings(settingsBlock)
   extractPlpData(..., extractionName = "target1000_admission",
                  targetId = 1000, outcomeIds = outcomeIds,
                  covariateSettings = covariateSettings)
   exportMeasurementValueUnitRef(...)  # the measurement unit crosswalk
   createLongFormat(outputFolder, extraction = "target1000_admission")
   ```

   `extras/CodeToRun.R` is that sequence with every argument filled in. This
   package extracts one target cohort at a time; which extractions a study
   needs, and the task definitions and labels that go with them, belong to the
   study package that drives it (here `TabEHR`).

   The cohort stage drops and recreates the entire configured cohort table.
   Always use a study-specific writable table.

5. Optionally print a validated sparse-array summary and a dense preview:

   ```r
   source("extras/PostprocessSparseArray.R")
   ```

   The long-format CSV and the sparse-array labels contain patient row
   identifiers and must be handled as sensitive derived data.

Output
======

The main runner writes these files under `SPARSE_ARRAY_OUTPUT_FOLDER`:

- `CohortCounts.csv`: number of rows in each configured cohort.
- `plpData/<extraction>`: persisted PatientLevelPrediction plpData, one folder
  per target and covariate settings combination. Its `covariates` file is the
  FeatureExtraction CovariateData, `timeRef` included.
- `covariateRef.csv`, `timeRef.csv`, `analysisRef.csv`: the reference tables
  that name the identifiers in `featureExtractionLong.csv`. `covariateRef.csv`
  carries one column FeatureExtraction's own table does not, `unitConceptId`,
  joined from `measurementValueUnitRef.csv`.
- `measurementValueUnitRef.csv`: for every measurement value covariate the
  database can produce, its `covariateId`, `conceptId`, `unitConceptId` and
  `recordCount`. A covariate id keeps the unit only as
  `unit_concept_id % 1000`, so without this file the unit cannot be read back;
  two units that agree modulo 1000 share one covariate id and appear here as
  two rows. Written when a covariate settings block asks for
  `useMeasurementValueUnit`, which is this package's measurement value
  analysis: FeatureExtraction's own `useMeasurementValue` cannot be used in a
  temporal sequence extraction, because the temporal sequence branch of its
  `MeasurementValue.sql` is missing a comma and does not render to valid SQL.
  See `createMeasurementValueUnitCovariateSettings()`.
- `studyPopulation/<extraction>_outcome<id>.rds`: each
  `PatientLevelPrediction::createStudyPopulation()` result as it came back,
  `metaData` attribute included.
- `outcomeLabels.csv`: one row per `rowId` and outcome that survived that
  outcome's study population criteria. Columns: `targetId`, `outcomeId`,
  `outcomeName`, `rowId`, `subjectId`, `targetCohortStartDate`,
  `targetCohortEndDate`, `outcomeLabel` (0/1), `outcomeCount`,
  `outcomeStartDate`, `daysToEvent`, `timeAtRisk`, `survivalTime`. Joins to
  `featureExtractionLong.csv` and to the sparse array row dimension on `rowId`.
- `outcomeLabelsAttrition.csv`: PLP's attrition table per outcome.
- `covariateData`: persisted FeatureExtraction CovariateData backed by
  Andromeda.
- `featureExtractionLong.csv`: the FeatureExtraction output in long format, with
  the columns `rowId`, `covariateId`, `timeId`, and `covariateValue`.
  Identifiers are not remapped and rows are not aggregated, so it is the raw
  extraction result and `timeId` is the sequence position FeatureExtraction
  assigned, not the array time index. Covariates from non-temporal analyses have
  an empty `timeId`.
- `sparseArray.rds`: the mapped sparse-array result. Only written when
  `extras/CreateSparseArray.R` is run; the pipeline itself stops at the long
  format.
- `log.txt` and `errorReportR.txt`: execution and error logs.

`sparseArray.rds` is a plain R list, not a PatientLevelPrediction object. It
contains:

- `dataArray`: a `slam::simple_sparse_array` with dimensions
  `patient x time position x covariate` and without dimension names.
- `labels`: the one-based array `rowId` and its source cohort `subject_id` as
  `originalRowId`.
- `covariateRef`: FeatureExtraction metadata for the observed covariates,
  ordered by `columnId`.
- `covariateMap`: the deterministic `covariateId` to `columnId` mapping.
- `timeMap`: one row per position on the time axis, with the FeatureExtraction
  `timeId`, the array `timeIndex`, and `startDay` and `endDay`. Temporal sequence
  axes add `unitsBeforeIndexStart`, `unitsBeforeIndexEnd`, `timePart`, and
  `timeInterval`; `startDay` and `endDay` are empty unless `timePart` is
  `"day"`.
- `timeAxis`: how the axis was built. `type` is `"sequence"` or `"window"`, and
  `timeIndexOrder` is `"timeId"` or `"startDay"`. Sequence axes also carry
  `timePart`, `timeInterval`, `sequenceStartDay`, `sequenceEndDay`,
  `firstTimeId`, `lastTimeId`, and `exact`, which is `TRUE` when the axis follows
  from the settings alone.
- `staticCovariateRef`: present only when `dropStaticCovariates = TRUE` excluded
  covariates that have no `timeId`.

Mapping rules
=============

- Only observed row and covariate identifiers are mapped, so the first and third
  dimensions contain no empty slices.
- The time axis is read from the saved `timeRef` table, so it always matches the
  data that was actually extracted:
  - **Temporal sequence, `timePart = "day"`**: the axis is the full run of
    interval positions the settings allow. A position without data becomes an
    all-zero slice, so the grid stays regular and comparable across runs and
    databases.
  - **Temporal sequence, `"month"` or `"year"`**: `DATEDIFF` counts calendar
    boundaries, so the settings only bound the axis. The axis is the contiguous
    run of observed positions, and a `timeId` outside the range the settings
    allow is an error.
  - **Temporal window**: the axis covers **every** window in `timeRef`, ordered
    by `startDay`, then `endDay`, then `timeId`.
- The `timeId` values are kept as FeatureExtraction assigned them rather than
  reordered to a common direction. Sequence positions are ordered by `timeId`
  (`timeIndexOrder = "timeId"`), so for a lookback window `timeIndex` 1 is
  nearest the index date; windows are ordered by `startDay`
  (`timeIndexOrder = "startDay"`), so `timeIndex` 1 is the oldest window.
- Covariate values are preserved, and duplicate `(rowId, timeId, covariateId)`
  coordinates are summed.
- Aggregated CovariateData is not supported, and CovariateData without a
  `timeId` column is rejected.
- Andromeda is used for mapping and batched coordinate transfer; the complete
  coordinate buffers and the final sparse array are still materialized in
  memory.

Using the array
===============

`slam` stores only the nonzero coordinates, so the array itself is small, but
`as.array()` on the whole object materializes
`patients x positions x covariates` doubles and is normally far too large.
Convert one batch of patients at a time instead:

```r
result <- readRDS(file.path(outputFolder, "sparseArray.rds"))

denseBatch <- function(sparseArray, rowIndices) {
  dims <- dim(sparseArray)
  batch <- array(0, dim = c(length(rowIndices), dims[2], dims[3]))
  position <- match(sparseArray$i[, 1], rowIndices)
  keep <- !is.na(position)
  if (any(keep)) {
    batch[cbind(
      position[keep],
      sparseArray$i[keep, 2],
      sparseArray$i[keep, 3]
    )] <- sparseArray$v[keep]
  }
  batch
}

# (samples, timesteps, features) for a sequence model:
x <- denseBatch(result$dataArray, 1:256)
dim(x)
```

The same helper is demonstrated in `extras/PostprocessSparseArray.R`.

Project structure
=================

Runtime-only entries such as `.env`, `jdbc/`, `data/`, and `output/` are shown
because the study uses them, but they are excluded from Git.

```text
SparseArray/
├── R/
│   ├── Settings.R                      # Covariate-settings JSON, and buildCovariateSettings()
│   ├── createCohort.R                  # Creates configured cohorts and cohort counts
│   ├── extractPlpData.R                # Wraps PatientLevelPrediction::getPlpData() for one extraction
│   ├── MeasurementValueUnit.R          # This package's measurement covariates (998/999) and the unit crosswalk
│   └── createLongFormat.R              # Streams the extraction result to a long CSV
├── inst/
│   ├── settings/
│   │   └── CohortsToCreate.csv         # Cohort IDs and packaged SQL resource names
│   └── sql/sql_server/
│       ├── CreateCohortTable.sql       # Recreates the SQL Server cohort table
│       └── LLT_HTE_moderate_intensity_statin_with_ezetimibe_v2.sql  # ATLAS cohort SQL
└── extras/
    ├── CodeToRun.R                     # Environment-driven end-to-end runner
    ├── CreateCovariateSettings.R       # Regenerates packaged temporal sequence covariate settings
    └── PostprocessSparseArray.R        # Validates the array and previews a dense batch
```

License
========

The SparseArray package is licensed under the Apache License 2.0.

Development
===========

SparseArray was developed as an OHDSI R study package using ATLAS-generated
cohort SQL, FeatureExtraction temporal sequence covariates, Andromeda, slam, and
RStudio.
The three-dimensional layout follows the approach used by
[CIReNN](https://github.com/ABMI/PatientLevelPrediction/blob/CIReNN/R/CIReNN.R)
and the OHDSI
[Building deep learning models](https://ohdsi.github.io/PatientLevelPrediction/articles/BuildingDeepLearningModels.html)
vignette, but builds the array in a single pass from the mapped coordinates
instead of binding one slice per time window.

### Development status

Experimental (version 0.0.1).
