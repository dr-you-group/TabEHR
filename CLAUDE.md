# 작업 지시: MedRep 전처리 SQL화 + SparseArray downstream 연결

이 문서는 작업 배경과 이미 정해진 사항을 모두 담고 있다. 여기 적힌 결정은 논의를 거쳐 확정된 것이긴 하지만 너무 이상하면 물어봐 줘. 당장 답을 못 받을 수 있으니, 질문은 `OPEN_QUESTIONS.md`에 기록하고 기본 결정으로 진행한다.

**DB 접근에 대해**: Claude Code는 DB에 접속할 수 없다. 코드 작성은 Claude가 하고, **실행은 사용자가 DB가 있는 환경에서** 한다. 그래서

- 모든 검증은 **실행 가능한 검증 스크립트**(R 또는 SQL)로 만들어 둔다. 스크립트는 결과를 `validation_report.md`와 CSV로 남기게 한다.
- 실행 결과나 오류는 사용자가 붙여 넣어 주고, 그걸 보고 원인을 해석하고 코드를 고친다.
- DB의 실제 값(테이블 구조, concept 분포, DatabaseConnector 동작 등)을 가정해야 하는 부분은 가정을 명시하고, 그 가정을 확인하는 짧은 확인용 쿼리·스크립트를 함께 만든다.
- 코드는 실행 전에 SqlRender로 렌더링·번역만 해 보는 등, DB 없이 할 수 있는 점검(문법, 파라미터 누락, 방언 변환)은 Claude가 직접 해 둔다.

- MedRep: `C:\git\MedRep\codes` (참고용, 수정하지 않음)
- SparseArray 원본: `C:\git\SparseArray`
- 이번 작업 산출물: `C:\git\TabEHR`

---

## 1. 배경

EHR foundation model 연구를 하고 있다.

- **Pretraining**: OMOP CDM으로 변환된 MIMIC-IV에서 환자의 진단·약물·검사·시술 기록 시퀀스로 모델을 새로 pretraining한다. 전처리는 MedRep의 `create_trajectory.py` 로직을 기반으로 한다.
- **Downstream 평가**: 사망, 장기 재원, 재입원, 입원 진단군(phenotype), 퇴원 후 1년 이내 신규 진단 같은 예측 task로 평가한다. task 정의(index date, 관찰 구간, TAR, outcome)는 SparseArray의 정의를 쓰고, input은 `allrecords`를 그 정의대로 걸러 만든다.
- **외부 검증**: 실제로 중요한 성능은 원내 CDM(YUHS 등)이다. MIMIC은 개발 편의를 위한 데이터라, 모든 코드가 **원내 CDM에서도 스키마만 바꿔서 그대로 돌아가야** 한다.

## 2. 현재 상황과 문제

| 구성 | 현재 상태 | 문제 |
|---|---|---|
| MedRep `create_trajectory.py` | Python(modin)으로 `person.csv`, `condition_occurrence.csv` 등 **CSV 파일**을 읽음 | MIMIC과 원내 CDM 모두 이제 **SQL Server DB에만** 있어서 CSV로 읽을 수 없음 |
| MedRep 환자 분할 | `create_trajectory.py` 끝에서 sklearn으로 70:15:15 분할, `train_id.csv` 등 저장. train+valid는 pretraining, test 15%가 downstream 풀 | SparseArray와 공유되지 않음 |
| SparseArray | R 패키지. DatabaseConnector(JDBC)로 SQL Server에 직접 붙어 cohort 생성 → FeatureExtraction temporal sequence → PLP population으로 task별 label 생성 | 환자 분할 개념이 없음. 전체 환자로 돌아감. task 정의(`studySettings.json`)는 연구 정의이므로 **TabEHR로 옮긴다**(아래 "SparseArray" 절) |

그래서 다음을 하려고 한다.

1. **기록 추출을 한 경로로 통일한다.** pretraining용 `allrecords`도 downstream task input도 모두 SparseArray(FeatureExtraction) 추출에서 나온다. 전처리 로직을 Python에서 SQL로 옮기는 것은 그 추출을 둘러싼 환자 선정·분할·후처리 부분이다.
2. **환자 분할을 R에서 한 번만** 만들고, pretraining과 downstream이 같은 분할 파일을 쓰게 한다.
3. **downstream task input을 `allrecords`에서 걸러 만든다.** task별 index date·관찰 구간으로 자르고, label은 SparseArray의 cohort·outcome 정의를 따른다.
4. **MedRep 재현(분위수·`<concept>_<bin>` 토큰)은 비교 임베딩 검증용으로 `extras/`에 분리한다.** 본 파이프라인의 출력은 원값 그대로다.

## 3. 작업 범위

- **포함**: 환자 선정·분할, `allrecords`(SparseArray 추출 기반), task별 input·label, MedRep 재현 파일(extras), 검증.
- **제외**: Python 토큰화, 모델 학습, 평가용 instance 선택. 다만 이후 단계가 가능하도록 출력 형식 요구 사항(5절)은 지킨다.

## 4. 확정된 사항 (바꾸지 말 것)

### 처리 흐름 (단계 정의)

각 단계는 하나의 export된 함수(또는 `extras/`의 스크립트)이고, `execute()`가 플래그로 순서대로 돌린다.

| # | 단계 | 읽는 것 | 만드는 것 |
|---|---|---|---|
| 0 | `checkDatabase()` | CDM | 검증 리포트 |
| 1 | `extractRecords()` | CDM | `records`, `measurements`, `record_counts`. **2단계의 "기록 10건 이상" 판정 전용** |
| 2 | `createStudyPopulation()` | 1단계 | `study_population`, `study_population_flow.csv`. 순서: 성인 → 2일 이상 입원 → 기록 10건 이상 |
| 3 | `createPersonSplit()` | 2단계 | `person_split` 70:15:15 (pretrain train / pretrain valid / downstream) |
| 4 | `createAllRecords()` | 3단계 + CDM | study population **전원**의 **전 기간** 기록을 SparseArray 추출로 뽑고 covariateId를 concept_id로 바꾼다 → `allrecords.csv.gz` |
| 5 | `createTaskInput()` | 4단계 + `studySettings.json` | downstream 환자 대상 task별 input(`taskInput/`)과 label(`taskLabels/`) |
| 6 | `extras/CreateMedRepFiles.R` | 4단계 | MedRep 형식 전처리 파일 → `output/<databaseId>/MedRep/` |
| check | `runDiagnostics()` | 전부 | `validation_*.csv`와 리포트 |

- **1단계와 4단계의 기록은 같지 않다.** 1단계는 환자 선정 기준(원본 MedRep 규칙)을 위한 것이고 4단계는 FeatureExtraction 규칙이다. **일치시키려 하지 않는다.** 대신 1단계가 무엇을 어떤 규칙으로 세는지 `README.md`에 적고, 검증 리포트에 **환자별 기록 수 차이 요약**과 **4단계 기록이 10건 미만인 study population 환자 수**를 남긴다.
- 4단계가 1·2단계 뒤에 오는 이유는 "기록 10건 이상" 기준이 1단계 결과를 쓰기 때문이고, 3단계 뒤에 오는 이유는 분할이 먼저 정해져야 하기 때문이다. 4단계 자체는 분할과 무관하게 **전원**을 뽑는다.

### 데이터

- MIMIC-IV OMOP과 원내 CDM 모두 SQL Server DB에 있다. 원본 CSV는 없다.
- 환자 정보는 OMOP `person` 테이블만 쓴다. MedRep 원본은 MIMIC 나이를 보정하려고 `person.trace_id`(JSON)로 원본 MIMIC `patients`(`anchor_age`)를 연결했지만, **현재 MIMIC OMOP 버전에서는 이 문제가 해결되어 `person.year_of_birth`를 그대로 쓰면 된다.** `trace_id`와 원본 MIMIC 테이블은 쓰지 않는다(이 단계를 없앤다). 날짜는 MIMIC의 date shift로 미래 연도(예: 2100년대)지만 환자 안에서 일관되므로 나이 계산에는 문제없다.

### person_id 처리 (중요)

- 현재 MIMIC OMOP의 `person_id`는 해시된 **BIGINT**라 매우 크고 음수도 있다(예: `4672282447827634561`, `-7819202826128270750`). 원내 CDM 등 다른 기관도 비슷할 수 있다고 가정한다.
- DB 안에서는 BIGINT 그대로 조인한다. 문제는 **DB 밖으로 나올 때**다.
  - **R**에는 기본 64비트 정수가 없어서, BIGINT가 double로 바뀌면 2^53(약 9×10^15)을 넘는 값의 **끝자리가 조용히 바뀐다.** 서로 다른 환자가 같은 ID가 되거나, 다시 DB와 조인할 때 매칭이 안 될 수 있다.
  - pandas도 결측이 섞인 열은 float로 읽혀 같은 문제가 생기고, Excel·JSON도 마찬가지다.
- 그래서 다음 중 하나로 처리한다(DatabaseConnector 버전에서 어느 쪽이 되는지 확인하는 짧은 스크립트를 먼저 만든다. 실행은 사용자가 한다).
  1. DB에서 내보낼 때 `CAST(person_id AS VARCHAR(20))`로 **문자열**로 내보내고, R·CSV에서는 항상 문자열로 다룬다(가장 안전).
  2. R에서 `bit64::integer64`로 받도록 설정한다(DatabaseConnector의 integer64 지원 옵션).

     ```r
     options(databaseConnectorInteger64AsNumeric = FALSE)
     ```

     (이 옵션은 DatabaseConnector 버전에 따라 없을 수 있다. SparseArray Docker 이미지는 5.0.2로 고정되어 있으니 해당 버전에서 동작하는지 먼저 확인하고, 안 되면 1번 방식을 쓴다.)

### 대상 환자 (study population)

MedRep 논문에는 "EHR foundation model은 종단 기록에 의존하므로 2일 넘게 입원한 적이 있는 환자만 포함했다"고 적혀 있지만, 공개 코드(`create_trajectory.py`)에는 환자 단위로 입원 기간을 거르는 부분이 없다(질환 task용 `labeling.py`에만 비슷한 조건이 있음). 우리는 논문의 의도대로 다음 세 조건을 **모두** 만족하는 환자로 대상 환자를 제한한다. 이 판정은 **SQL로 DB에서** 한다.

| 조건 | 정의 |
|---|---|
| 성인 | 18세 이상 시점의 기록만 사용 (원본처럼 기록 단위로 `YEAR(기록일) - year_of_birth >= 18`) |
| 입원 이력 | 입원 visit(`visit_concept_id` 9201, 262 및 그 하위 concept) 중 **입원 기간 2일 이상**(`DATEDIFF(day, visit_start_date, visit_end_date) >= 2`)이고 **입원 시작 시점에 18세 이상**인 입원이 1회 이상 |
| 기록 수 | 1단계(`extractRecords()`, 원본 MedRep 규칙)를 거친 뒤 환자당 기록 10건 이상 (원본과 같은 기준: 중복 제거 후 4개 도메인 합계). 4단계 `allrecords`의 기록 수와는 다를 수 있고, 맞추지 않는다 |

- 입원 기간 기준은 config 값으로 둔다. 기본은 `>= 2`(MedRep `labeling.py`의 조건과 같음). 논문 문장("more than 2 days")을 엄격히 따르면 `> 2`이므로 둘 다 지원한다.
- 이 조건은 **환자 단위 포함 기준**이다. 대상 환자로 뽑힌 뒤에는 그 환자의 모든 기록(입원 기간과 무관)을 쓰고, SparseArray의 target cohort(입원 기간 1일 이상) 정의도 그대로 둔다.
- 결과는 `@cohort_database_schema`에 `study_population`(person_id) 테이블로 만들고, 이후 모든 단계(분할, `allrecords`, task input, MedRep 재현)는 이 환자만 대상으로 한다.
- 단계별 환자 수(전체 → 성인 기록 있음 → 2일 이상 입원 이력 → 기록 10건 이상)를 표로 남긴다(flow diagram용).

### allrecords (기록의 정의)

`allrecords`는 이 프로젝트의 **기준 데이터**다. pretraining 시퀀스도, downstream task input도, MedRep 재현 파일도 모두 여기서 파생된다. 따로 만들지 않는다.

- **출처는 SparseArray 추출(FeatureExtraction)이다.** study population **전원**, **전 기간**이고 입원 단위로 자르지 않는다. 추출 결과의 covariateId를 concept_id로 바꾼 것이 `allrecords`다.
- **전 기간을 뽑기 위한 cohort**: FE는 index date 기준으로만 뽑으므로, study population 환자 1인당 1행짜리 cohort를 만든다. `cohort_start_date`는 **그 환자의 마지막 기록일**(CDM 4개 도메인의 날짜 컬럼 MAX)이고 `sequenceStartDay = -99999`, `sequenceEndDay = 0`이다. 첫 기록일도 함께 구해 창 밖으로 빠진 기록이 없음을 검증 리포트에 남긴다. 기준일을 1단계 테이블이 아니라 **CDM에서** 구하는 이유는, 1단계가 버리는 기록이 FE에는 남아 index date 뒤로 빠질 수 있기 때문이다.
- **열**: `person_id, domain[cond/drug/proc/meas], concept_id, record_date, value_as_number, unit_concept_id`
  - `record_date`는 `cohort_start_date - timeId`로 복원한다. `timeId`가 일 단위이므로 **시각(hh:mm)은 남지 않는다**. 아래 "하루의 마지막 1건" 규칙과 일관된다.
  - `value_as_number`와 `unit_concept_id`는 측정값 covariate(998)에만 채우고, cond/drug/proc와 값 없는 측정(999)은 **NULL**이다. 단위가 모호한 covariate(아래)도 `unit_concept_id`를 NULL로 두고 건수를 리포트에 남긴다.
  - **bin(분위수)으로 바꾸지 않는다.** 원값 그대로다.
- **concept 필터**: FE의 `DomainConcept.sql`과 동일하게 `concept_id <> 0`만. `standard_concept`·`invalid_reason`·도메인 일치 필터는 두지 않는다.
- **검사 중복**: SparseArray와 같은 규칙, 즉 **(rowId, concept, 하루) 1건이고 그날의 마지막 값**이다(날짜 내림차순 → unit → value 순). MedRep 원래 규칙인 "시간당 1건"은 **쓰지 않는다.** 한 concept이 한 날에 두 단위로 측정되면 FE 규칙대로 **1건만** 남는다.
- **이 프로젝트의 커스텀 covariate 분석 두 개** (`99x`는 우리 블록. FE는 두 prespec 집합 모두 최대 926이라 충돌하지 않는다):

  | analysisId | 이름 | covariate_id | 내용 |
  |---|---|---|---|
  | 998 | `MeasurementValueUnit` | `concept*1000000 + (unit_concept_id % 1000)*1000 + 998` | 숫자값이 있는 측정. `covariate_value = value_as_number` |
  | 999 | `MeasurementNoValue` | `concept*1000 + 999` | 숫자값이 **없는** 측정. 그 (rowId, concept, 하루)에 998 행이 없을 때만 만든다 |

  - id **공식**은 FE의 `MeasurementValue.sql`·`DomainConcept.sql`을 그대로 쓴다. 단위를 id에서 빼면 한 concept의 두 단위가 한 covariate로 합쳐져 값이 섞이므로 공식은 바꾸지 않는다. 다만 **analysisId는 이 프로젝트 것**이다: 내용이 FE의 702와 다르고(아래 `COALESCE`), FE의 702는 temporal sequence에서 렌더조차 되지 않는다.
  - 단위는 `COALESCE(unit_concept_id, 0)`으로 998에 넣는다. 즉 **단위가 NULL이거나 0인 수치 검사도 기록으로 남는다**(`unit_concept_id = 0`, FE가 'Unknown unit'으로 쓰는 표현과 같다). 분위표에는 그 쌍이 없으므로 MedRep 단계에서 접미사 없는 토큰이 된다. MedRep 원본은 이 행을 버렸지만, 우리는 **버리지 않는다.**
  - FE의 `useMeasurement`(701)는 **끈 상태로 둔다.** 켜면 같은 측정이 701과 998에서 중복으로 나온다. 동시 설정은 에러로 막는다.
  - covariateId → `(conceptId, unitConceptId)` 복원은 `covariateRef.csv`와 `measurementValueUnitRef.csv`로 한다. 산술(특히 `unit % 1000`)로 되돌리지 않는다.
- **person_id**: 추출에는 `row_id`(ROW_NUMBER)를 rowIdField로 넘기고, `row_id ↔ person_id`(BIGINT) 매핑은 cohort 테이블에 두고 SQL/문자열로만 복원한다. person_id가 double로 내려가는 경로를 만들지 않는다.

### 분위수와 MedRep 재현 (extras 전용)

분위수는 본 파이프라인의 일부가 아니다. **비교 임베딩(MedRep) 검증용**이므로 `extras/CreateMedRepFiles.R`에서만 돌리고 결과는 `output/<databaseId>/MedRep/`에 둔다.

- 입력은 `allrecords`다. MedRep 전용 필터를 **여기서** 적용한다: `(concept, unit)` 쌍 **10건 이상**, `unit_concept_id <> 0`.
- **분위수 기준은 MedRep과 동일하게 간다**: 전체 환자로 계산하고(= `allrecords` 전원), 기관마다 자기 분포로 다시 계산한다. 기준 집합과 배정 집합이 같으므로 `bin 10`이 발생하지 않고, 토큰 공간이 MedRep·deploy_LG 임베딩과 같은 `_0`~`_9`로 유지된다. 다른 기관 표 적용은 옵션으로 남긴다(`createQuantileSettings(basis = "file")`).
- 분위 배정은 원본과 같은 `max(0, (경계 < 값 개수) - 1)`이고, 경계값은 pandas `quantile()`과 비트 단위로 일치시킨다.
- 측정만 `<concept_id>_<bin>`으로 바꾸고 나머지 도메인은 concept_id 그대로다. 분위표에 쌍이 없으면 접미사 없이 둔다.
- **원본과 다른 점을 MedRep 폴더 README에 적는다**: 시간 해상도가 하루 단위(원본은 시간당 1건, 시각 포함)이고, 단위 미매핑 수치 검사가 살아 있다.

### downstream task input

- **input**: `allrecords`를 task의 index date와 관찰 구간(`sequenceStartDay`~`sequenceEndDay`)으로 걸러 만든다. 관찰 구간은 `sequenceEndDay = 0`이므로 index 당일을 포함한다(SparseArray와 같은 규칙).
- **population**: task 설정(TAR, prior outcome, washout, requireTimeAtRisk 등)에 따라 **어떤 입원(rowId)이 대상인지**가 걸러진다. 이 판정은 PLP의 `createStudyPopulation()`이 하고, 그 결과가 label 파일이다. **TAR은 input의 기록을 거르는 기준이 아니다**(index 이후 구간이므로 누출이 된다).
- input은 task별이 아니라 **extraction별**로 만든다. 관찰 구간은 covariateSettings 블록이, index date는 targetId가 정하므로 38개 task가 실제로는 3개(`target1000_admission`, `target1000_admissionNoCondition`, `target1003_discharge`)만 필요하다. label만 task별이다.
- 대상은 downstream 환자뿐이다(target cohort SQL의 `WHERE EXISTS`로 제한).

### 환자 분할

- pretraining은 새로 하므로 MedRep의 기존 분할(sklearn `random_state=50`)을 재현할 필요는 없다. R에서 `set.seed`로 나눈다.
- 대상: `study_population`의 환자(성인 + 기록 10건 이상 + 2일 이상 입원 이력).
- 1차: MedRep과 같은 70:15:15 (환자 단위, 설정값). 70%는 pretraining train, 15%는 pretraining validation, 15%는 downstream 풀이다. pretraining에는 앞의 85%만 쓰고, downstream 15%는 pretraining에 절대 쓰지 않는다.
- downstream 안의 train / valid / test 분할은 **이번 범위가 아니다.** 이후 fine-tuning 단계(Python, 학습 seed별)에서 환자 단위로 나눈다. 이번 작업은 downstream 환자 전체의 입력·label만 만든다.
- 어떤 환자도 두 그룹에 동시에 속하면 안 된다. 특히 downstream 환자는 pretraining에 절대 들어가면 안 된다.
- 분할 결과는 `person_split.csv` 하나로 저장하고, 이후 모든 단계(pretraining, SparseArray, 이후 Python 평가)는 이 파일만 기준으로 쓴다. `@cohort_database_schema`에 테이블로도 올린다.

### SparseArray

**SparseArray에는 데이터를 추출하는 기능만 남긴다.** task 정의는 연구 정의이므로 TabEHR이 갖는다. cohort 정의(`CohortsToCreate.csv`와 38개 phenotype SQL), covariate 설정, 출력 형식은 바꾸지 않는다 — 논의를 거쳐 확정된 정의다.

| SparseArray에 남는 것 | TabEHR으로 옮기는 것 |
|---|---|
| `R/createCohort.R` + cohort SQL | `inst/settings/studySettings.json` |
| `R/extractPlpData.R` (`createPlpData.R`에서 이름을 바꿨다. `studySettings`를 읽지 않고 `targetId`·`outcomeIds`·`covariateSettings`를 인자로 받아 한 번에 한 추출만 한다) | `extras/MakeStudySettingsJson.R` |
| `R/createLongFormat.R` | `R/StudySettings.R` (`loadStudySettings`, `saveStudySettings`, `resolveStudySettings`, `studyExtractionGroups`) |
| `R/MeasurementValueUnit.R` + SQL 2개 (커스텀 covariate 998/999, 단위 crosswalk) | `R/createOutcomeLabels.R` (label 생성) |
| `R/Settings.R` + 신설 `buildCovariateSettings()`: 평평한 인자 목록 → FE 객체 + 커스텀 빌더 리스트 | `R/Main.R`의 `execute()` (SparseArray 쪽은 삭제) |

커스텀 플래그(`useMeasurementValueUnit`)를 빌더로 바꾸는 일은 빌더가 있는 SparseArray에 남기고, TabEHR이 `buildCovariateSettings()`를 호출한다. 이것이 두 패키지의 접합면이다.

- **target cohort SQL 수정**: downstream 환자의 person_id만으로 target cohort가 만들어지도록 primary event(visit_occurrence 조회)에 `WHERE EXISTS` 조건을 추가한다.
- **커스텀 covariate 수정은 "최소 수정" 원칙의 예외다.** 값 없는 측정(999)과 `COALESCE(unit, 0)`이 거기서 나와야 하기 때문이다. 어디를 왜 바꿨는지 `README.md`의 변경 사항 표에 전부 적는다.

### Seed

- 이번 작업에서 seed가 쓰이는 곳은 **1차 분할(70:15:15) 하나뿐**이다. config의 `splitSeed` 하나로 고정하고, 바꾸지 않는다. pretraining 분할은 이 값으로 한 번 정해지면 끝이다.
- downstream의 train/valid/test 분할과 평가 instance 선택(valid·test에서 환자당 1개 입원)은 **이후 fine-tuning 단계에서 학습 seed별로** 한다(이번 범위 밖). SparseArray 단계에서는 seed를 고려하지 않는다.
- **결정적 분할**: DB에서 가져온 환자 목록은 순서가 보장되지 않으므로, 무작위 배정 전에 **person_id로 정렬**한 뒤 `set.seed(splitSeed)`를 적용하고 `RNGkind`(`sample.kind = "Rejection"` 포함)도 명시한다. 정렬은 손상되지 않은 person_id 값(문자열 또는 integer64)으로 한다.
- **재현성 확인**: 같은 config로 두 번 실행했을 때 `person_split.csv`가 완전히 같은지 비교하는 스크립트를 만든다.

### 여러 기관 적용

MIMIC 외에 원내 CDM(YUHS)을 포함한 **여러 기관 DB에서 외부 검증**을 할 예정이다. 기관마다 코드를 고치지 않고 설정만 바꿔 돌릴 수 있어야 한다.

- **기관별 설정**: OHDSI 관례대로 기관별 값은 **`extras/CodeToRun.R` 한 곳**에만 둔다 — `databaseId`, 연결 정보(`DatabaseConnector::createConnectionDetails()`), `cdmDatabaseSchema`, `vocabularyDatabaseSchema`, `cohortDatabaseSchema`(쓰기 권한 필요. cohort 테이블과 이번 작업의 결과 테이블을 둔다), `tablePrefix`, `outputFolder`. 자격 증명은 `.env`의 환경 변수로 읽는다. 분석 설정(기준값·비율·seed)은 기관 공통이므로 `create*Settings()`와 `inst/settings/analysisSettings.json`에 둔다. 실행은 `CodeToRun.R`의 기관 값만 바꿔서 한다.
- **SQL 방언**: SQL은 OHDSI 관례대로 SQL Server 방언(OHDSI SQL)으로 쓰고, 실행 시 `SqlRender::translate()`로 기관의 `dbms`에 맞게 변환한다. 지금은 모두 SQL Server지만 다른 DBMS(PostgreSQL 등)도 올 수 있다고 가정한다. `PERCENTILE_CONT`, `TRY_CAST`처럼 변환이 안 될 수 있는 함수는 SqlRender 지원 여부를 확인하고, 안 되면 대안(분위수는 R에서 계산 등)을 둔다.
- **OMOP 표준 테이블만 사용**: 어느 기관이든 OMOP 표준 테이블만으로 돌아가야 한다. 특정 기관 전용 테이블이나 컬럼(`trace_id` 등)은 쓰지 않는다.
- **분위수는 기관별로 다시 계산한다**(MedRep과 동일). 외부 기관은 전체 환자가 평가 대상이고 pretraining·분할이 없다(분할 단계는 MIMIC에서만). 다른 기관의 표를 그대로 적용하려면 `createQuantileSettings(basis = "file")`로 가능하다.
- **출력 구분**: 모든 산출물은 `output/<databaseId>/` 아래에 저장하고, 실행에 쓴 설정과 vocabulary 버전(`vocabulary` 테이블의 `vocabulary_version`)을 함께 기록한다.

## 5. 출력

모든 파일 출력은 **CSV**(필요하면 gzip 압축)로 하고, `output/<databaseId>/` 아래에 저장한다. **person_id는 모든 파일에서 문자열**로 쓴다(앞의 "person_id 처리" 참고). 날짜는 `YYYY-MM-DD`, 일시는 `YYYY-MM-DD HH:MM:SS`로 통일한다.

### DB 테이블 (`@cohort_database_schema`, 결과 테이블 접두어 적용)

접두어는 `tablePrefix`(기본 `tabehr_`)이고 전체 목록은 `getTabehrTableNames()`에 있다.

| 테이블 | 단계 | 내용 |
|---|---|---|
| `records` | 1 | cond/drug/proc 기록. **환자 선정 전용**(MedRep 규칙) |
| `measurements` | 1 | 시간당 1건으로 줄인 검사 기록(값·단위 포함). **환자 선정 전용** |
| `concept_unit` | 1 | 10건 이상인 (검사 concept, 단위) 쌍. `measurements`의 수치 분기가 쓴다 |
| `record_counts` | 1 | 환자별 중복 제거 기록 수 |
| `admission_history` | 2 | 조건을 만족하는 입원이 있는 환자 |
| `study_population` | 2 | 대상 환자 person_id |
| `person_split` | 3 | person_id, stage, split (분할 결과와 같은 내용) |
| `downstream_person` | 3 | downstream 환자 person_id (target cohort SQL의 `WHERE EXISTS`에서 사용) |
| `allrecords_cohort` | 4 | 전 기간 추출용 cohort: person_id, `row_id`, 첫 기록일, 마지막 기록일(= index date) |
| `quantile_basis_person` | 6 | 분위수 계산 대상 환자. **MedRep 단계 전용** |
| `meas_quantiles` | 6 | 검사 분위수 표. **MedRep 단계에서 만든다** |

`allrecords`는 DB 테이블로 만들지 않는다. 수억 행을 JDBC로 되밀어 넣는 비용이 크기 때문에, FeatureExtraction이 만든 Andromeda(SQLite) 파일을 그대로 작업 산출물로 쓰고 거기서 `allrecords.csv.gz`를 스트리밍으로 내보낸다. 5단계의 task 필터링도 같은 Andromeda에 작은 cohort 표를 넣고 조인해서 한다.

### 파일

| 파일 | 열 | 비고 |
|---|---|---|
| `study_population_flow.csv` | step, n_person | 단계별 환자 수 (전체 → 성인 기록 있음 → 2일 이상 입원 이력 → 기록 10건 이상) |
| `person_split.csv` | person_id, stage[pretrain/downstream], split[train/valid 또는 빈 값], split_seed | pretrain만 train/valid로 나눈다. downstream은 split 없음(이후 fine-tuning에서 나눔). 외부 기관은 stage = external, split 없음 |
| `split_summary.csv` | stage, split, n_person, 비율 | 그룹 간 환자 겹침이 0임을 함께 기록 |
| `allrecords.csv.gz` | person_id, domain[cond/drug/meas/proc], concept_id, record_date, value_as_number, unit_concept_id | **기준 데이터.** 원값 그대로이고 bin으로 바꾸지 않는다. 값·단위는 측정값(998)에만 있고 나머지는 NULL. 크면 환자 단위로 나눠 저장 |
| `taskInput/<extraction>/input.csv.gz` | rowId, person_id, domain, concept_id, record_date, time_id, value_as_number, unit_concept_id | `allrecords`를 index date·관찰 구간으로 자른 것. extraction 3개 |
| `taskLabels/<taskId>.csv` | taskId, rowId, person_id, cohort 날짜, time at risk, outcomeLabel | PLP population이 거른 결과. 열 구성은 기존 `outcomeLabels.csv`와 같다 |
| `MedRep/allrecords.csv.gz` | person_id, domain, concept_id, record_date | **MedRep 비교용.** 원본과 같은 열 구성이고 검사의 concept_id는 `<concept_id>_<분위>`. 원본과 다른 점(하루 단위 해상도, 단위 미매핑 수치 검사 유지)은 같은 폴더 README에 적는다 |
| `MedRep/meas_quantiles.csv` | measurement_concept_id, unit_concept_id, unit_source_value, n_unit_source_value, quantile_0 … quantile_10, n, basis | 키는 `(measurement_concept_id, unit_concept_id)`. `unit % 1000` 잔차는 어디에도 쓰지 않는다 — 단위는 `covariateRef.csv`의 `unitConceptId`가 알려주고, 잔차를 키로 쓰면 "충돌이 없다"는 가정에 기대게 된다 |
| `MedRep/{train,valid,test}_id.csv` | person_id | 분할에서 바로 나온다: train = pretrain·train, valid = pretrain·valid, test = downstream |
| SparseArray 출력 | (패키지 기존 형식 그대로) | `featureExtractionLong.csv`, `covariateRef.csv`(+`unitConceptId`), `measurementValueUnitRef.csv`, `timeRef.csv`, `analysisRef.csv`, `CohortCounts.csv`. 형식은 바꾸지 않는다 |
| `cohort_counts_restricted.csv` | cohort_definition_id, n_row, n_person | target cohort 제한 후 수치 |
| `run_info.json` | databaseId, dbms, 스키마 이름, config 전체, splitSeed, vocabulary_version, 패키지 버전, 실행 일시 | 재현용 실행 기록 |
| `validation_report.md` | – | 검증 스크립트가 자동으로 쓰는 단계별 결과 요약(SQL 변환 검증, 분할 재현성, person_id 왕복 확인, cohort 제한 확인) |

## 6. 프로젝트 구성

이번 작업 결과는 `C:\git\TabEHR` 폴더 하나에 모은다. 이 폴더만 있으면 전처리부터 SparseArray 출력까지 전부 실행할 수 있다. 구성은 **HADES(OHDSI) R 패키지 관례**를 따른다 — SparseArray, PatientLevelPrediction, CohortMethod와 같은 모양이다.

- **TabEHR 자체가 R 패키지**다: `DESCRIPTION`, `NAMESPACE`, `R/`, `inst/sql/sql_server/`, `inst/settings/`, `man/`, `tests/testthat/`, `extras/CodeToRun.R`.
- **실행**은 `extras/CodeToRun.R` 하나로 한다. `execute()`가 단계별 플래그(`extractRecords`, `createStudyPopulation`, ...)를 받아 순서대로 돌리고, 각 단계는 같은 인자를 받는 export된 함수이기도 하다.
- **설정**은 세 종류로 나눈다: 기관별 값(연결·스키마·출력 폴더)은 `CodeToRun.R`에, 기관 공통 분석 설정은 `create*Settings()`와 `inst/settings/analysisSettings.json`에, **task 정의는 `inst/settings/studySettings.json`**(SparseArray에서 옮겨 온 것)에 둔다.
- **SQL**은 `inst/sql/sql_server/`에 OHDSI SQL로 두고 `SqlRender::loadRenderTranslateSql(packageName = "TabEHR")`로 읽는다.
- **SparseArray**: 원본 저장소를 `TabEHR/SparseArray`로 가져온다. 역할은 **추출 전용**으로 줄이고(위 "SparseArray" 절), 그 외에는 원래 상태를 유지한다. 변경·이동 내역은 전부 `README.md`에 정리한다. `.Rbuildignore`에 넣어 TabEHR 빌드에서는 제외하고, 별도로 `R CMD INSTALL SparseArray`로 설치한다. 두 사본(`C:\git\SparseArray`와 `TabEHR/SparseArray`)은 git이 추적하는 파일 전부가 바이트 단위로 같아야 한다.
- **MedRep**: `C:\git\MedRep\codes`는 참고용으로만 읽고 수정하지 않는다.
- **지시 문서**: 이 문서를 `TabEHR/CLAUDE.md`로 넣어, 다른 세션에서도 같은 배경과 결정을 따르게 한다.
- **개발용 점검**: `extras/CheckSqlRendering.R`(DB 없이 SQL 렌더·번역), `extras/CheckSqlParameters.R`(R 호출부 ↔ SQL 파라미터 대조), `extras/MakePandasFixtures.py`(pandas로 기대값 생성), `tests/testthat/`.

```
TabEHR/
  DESCRIPTION, NAMESPACE, TabEHR.Rproj
  R/                     단계별 코드 (Main.R, SettingsObjects.R, ExtractRecords.R,
                         AllRecords.R, TaskInput.R, StudySettings.R, ...)
  inst/sql/sql_server/   SqlRender SQL
  inst/settings/         analysisSettings.json, studySettings.json
  man/                   roxygen2 생성
  extras/                CodeToRun.R, CreateMedRepFiles.R, MakeStudySettingsJson.R,
                         Check*.R, MakePandasFixtures.py
  tests/testthat/        테스트와 pandas 기대값 fixture
  SparseArray/           가져온 SparseArray (수정 최소화)
  DockerImage/           이미지 (SparseArray 스택 + PatientLevelPrediction)
  README.md, CLAUDE.md, OPEN_QUESTIONS.md
```

---

## 작업 원칙 (세션 공통)

- 기존 코드는 크게 고치지 말고 래퍼와 새 스크립트를 추가하는 방식으로 한다. **예외 두 가지**: SparseArray의 역할을 추출 전용으로 줄이면서 task 정의를 TabEHR으로 옮기는 것, 그리고 값 없는 측정(999)과 `COALESCE(unit, 0)`을 위해 커스텀 covariate를 고치는 것. 둘 다 `README.md` 변경 표에 적는다.
- 자격 증명은 `.env`(SparseArray의 `SPARSE_ARRAY_DB_*` 변수 재사용)로만 다루고 코드나 추적 파일에 넣지 않는다.
- DB에는 `@cohort_database_schema`에만 테이블을 만들고, CDM 테이블은 읽기만 한다.
- 각 단계는 작은 샘플(환자 1,000명)로 먼저 돌려 결과를 확인한 뒤 전체 실행한다.
- 문서와 코드가 맞지 않거나 결정이 이상해 보이면 `OPEN_QUESTIONS.md`에 기록하고, 기본 결정으로 진행한다.
