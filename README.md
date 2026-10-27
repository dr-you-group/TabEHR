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