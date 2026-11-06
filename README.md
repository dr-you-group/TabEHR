# TabEHR

Builds the pretraining records and the downstream task inputs and labels for an
EHR foundation model from an OMOP CDM. 
Every output goes to `output/<databaseId>/`.

## Requirements

- Write access to one schema (`cohortDatabaseSchema`). CDM tables are only read.
- The R environment in [DockerImage/Dockerfile](DockerImage/Dockerfile)
  (R 4.1.2, DatabaseConnector 5.0.2, FeatureExtraction 3.2.0,
  PatientLevelPrediction 6.0.0). Build it from the project root:

  ```bash
  docker build -f DockerImage/Dockerfile -t tabehr .
  ```

## Setup

```bash
cp .env.example .env        # fill in the connection and the schema names
set -a; . ./.env; set +a
R CMD INSTALL SparseArray   # install this copy, not the original repository
R CMD INSTALL .
```

## Run

```bash
Rscript extras/CodeToRun.R
```

[extras/CodeToRun.R](extras/CodeToRun.R) is the only file with site-specific
values (`databaseId`, connection, schemas). Edit it there. After the run,
check `output/<databaseId>/validation_report.md`.

The MedRep comparison files are optional. They are written to
`<output folder>/<databaseId>/MedRep`, so either form of the call below puts
them in the same place:

```bash
Rscript extras/CreateMedRepFiles.R output/mimic 10
Rscript extras/CreateMedRepFiles.R output mimic 10
```

To resume, set the flags of the stages already done to `FALSE` in `execute()`.
Each stage is also an exported function that takes the same arguments.

| Flag | What it does |
|---|---|
| `checkDatabase` | checks the database assumptions |
| `extractRecords` | records for the study population criteria |
| `createStudyPopulation` | adults with 10+ records. The 2+ day admission rule is counted and reported, and applied only with `createPopulationSettings(requireQualifyingAdmission = TRUE)` |
| `createPersonSplit` | 70:15:15 split into pretrain train / valid / downstream |
| `createAllRecords` | every record of the study population → `allrecords.csv.gz` |
| `createTaskInput` | downstream task inputs (`taskInput/`) and labels |
| `runDiagnostics` | checks the output |

### External validation sites

Change `databaseId` and the connection details, and use
`createAnalysisSettings(siteRole = "external")`. The patients are not split;
everyone is `stage = external`.

## Downstream tasks

22 tasks, all indexed on the **discharge date** of an inpatient stay
(cohort 1003), so one extraction serves them all.

| Task | Outcome | Time at risk |
|---|---|---|
| `readmit` | any inpatient admission (cohort 1000) | day 1–30 after discharge |
| `newDx3101`…`newDx3121` | first diagnosis of one of 21 diseases | day 1–365 after discharge |

The 21 diseases are listed in
[SparseArray/codes/newdx_icd10.csv](SparseArray/codes/newdx_icd10.csv) with the
ICD-10 codes that define them. Each outcome cohort is built by mapping those
codes to standard SNOMED concepts (`Maps to`) and expanding their
`CONCEPT_ANCESTOR` descendants, over the condition, observation and procedure
tables. A `newDx` task drops patients who already had that diagnosis, so the
label is the *first* occurrence.

```bash
cd SparseArray
Rscript extras/AddSnomedToNewDxCsv.R    # ICD-10 -> SNOMED, needs the database
Rscript extras/MakeNewDxCohortSql.R     # writes the cohort SQL and registers it
cd ..
Rscript extras/MakeStudySettingsJson.R  # regenerates inst/settings/studySettings.json
```

Read `SparseArray/codes/newdx_icd10_report.csv` before building the cohorts: it
names every ICD-10 code that contributed no SNOMED concept, and every mapping
target whose domain the cohort SQL does not read.

The previous task set (7- and 30-day mortality, long length of stay, 27 CCSR
phenotypes, an older 7-disease `newDx` set) was retired on 2026-11-05. Its
cohort definitions are kept in
[SparseArray/extras/retired_cohort_sql/](SparseArray/extras/retired_cohort_sql/).

## Measurement values

A concept measured several times on one day becomes one value in `allrecords`.
Which one is a setting:

```r
createAnalysisSettings(
  allRecordsSettings = createAllRecordsSettings(
    measurementValueAggregate = "median"   # min (default), max, mean, median
  )
)
```

The aggregate is taken **within a unit**, never across two, and the lowest unit
of the day is the one kept - so one concept still contributes one record per
day, which is what the no-value analysis and everything downstream rely on.
`"min"` is the default because that is what FeatureExtraction's own rule
reduces to inside a day: its `ORDER BY measurement_date DESC, unit_concept_id,
value_as_number` cannot discriminate on the first key when the column is a
date.

Changing it changes `allrecords` itself, so stage 4 onwards has to be rerun -
task inputs, measurement quantiles and MedRep tokens included. Keep
`measurementValueAggregate` in `inst/settings/studySettings.json` equal to this
one, or `featureExtractionLong.csv` will disagree with the input it describes.

This is the **day** aggregate. The window covariates below take the most recent
value in the window, which is a separate rule.

## Window covariates (optional)

`taskInput/<extraction>/input.csv.gz` holds one row per record per day. To get
the shape FeatureExtraction's non-temporal settings produce - one covariate per
concept per observation window - run the post-processing step:

```bash
Rscript extras/MakeWindowCovariates.R output mimic            # all extractions
Rscript extras/MakeWindowCovariates.R output mimic rows=2000000   # test run
```

It needs no database and re-extracts nothing. Default windows are
FeatureExtraction's `longTerm` (-365..0), `mediumTerm` (-180..0) and
`shortTerm` (-30..0); edit the `windows` list at the top of the script to change
them, or add `anyTimePrior`.

| Written next to the input | Contents |
|---|---|
| `windowCovariates.csv.gz` | `row_id`, `covariate_id`, `covariate_value`, sparse: a concept with no record in the window has no row, which is the 0 |
| `windowCovariateRef.csv` | what each covariate id means: analysis, concept, unit, domain, window |
| `windowAnalysisRef.csv` | the analyses used, with their window days |
| `windowCovariates_report.csv` | rows and distinct covariates per analysis |

A concept with at least one record in the window gets 1. A measurement also
gets the value of its **most recent valued record** in that window, which is
FeatureExtraction's rule: a later record with no numeric value does not hide an
earlier value. The analysis and covariate ids are FeatureExtraction's own
(`ConditionOccurrenceLongTerm` 102 … `MeasurementValueShortTerm` 708,
`concept_id * 1000 + analysis_id`, and `concept_id * 1000000 +
(unit_concept_id %% 1000) * 1000 + analysis_id` for a value), not the daily
extraction's 998/999.

`row_id` joins to `outcomeLabels.csv`, so one window file serves every task that
shares the extraction.

## Main outputs

| File | Contents |
|---|---|
| `person_split.csv` | `person_id`, `stage`, `split`: used by every later stage |
| `allrecords.csv.gz` | `person_id`, `domain`, `concept_id`, `record_date`, `value_as_number`, `unit_concept_id` |
| `taskInput/<extraction>/input.csv.gz` | `allrecords` cut to each task's observation window |
| `outcomeLabels.csv` | the task labels |
| `validation_report.md` | the results of the checks |
| `run_info.json` | settings, seed, vocabulary version, package versions |

`person_id` is always text, not a number. When reading the files, read it as a
string (`colClasses = c(person_id = "character")` in R, `dtype={"person_id": str}`
in pandas), because a 19-digit id loses digits as a double.