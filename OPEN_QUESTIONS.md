# 확인이 필요한 사항과 적용한 결정

지시 문서(`CLAUDE.md`)와 실제 코드가 맞지 않거나, DB를 봐야 확정할 수 있는 항목을 모았다.

- 상태: `해결` = 답을 받아 반영 완료 / `실행 확인` = 사용자가 돌려야 확정 / `답 대기` = 확인 필요
- 마지막 갱신: 2026-10-16

---

## A. 코드 버그 (해결)

### A1. `createOutcomeLabels()`가 label을 전혀 만들지 못한다 (status: 해결)

`SparseArray/R/createOutcomeLabels.R:155`는 추출 그룹마다 `group$taskIds`를 순회하는데,
`studyExtractionGroups()`는 `targetId`, `covariateSettingsId`, `outcomeIds` 세 개만 반환하고
`taskIds`는 반환하지 않았다. 따라서 루프가 0회 실행되고 `stop("No outcome produced any
labels.")`로 매번 실패했다. `tests/testthat/test-execute.R`는 `createOutcomeLabels`를 mock으로
대체하므로 이 버그를 잡지 못했다.

> 사용자 답변: 고치는 게 맞음. 원본 저장소도 업데이트 하기.

**반영**: `studyExtractionGroups()`가 `taskIds`를 함께 반환하도록 수정. **원본
`C:\git\SparseArray`와 `TabEHR/SparseArray` 양쪽에** 적용했고 `man/`도 갱신했다.

### A2. Docker 이미지에 `PatientLevelPrediction`이 설치되지 않는다 (status: 해결)

`DESCRIPTION`이 `PatientLevelPrediction (>= 6.0.0)`을 `Imports`에 두는데 Dockerfile이 설치하지
않아 `R CMD INSTALL`이 실패했다.

> 사용자 답변: 고치는 게 맞음. SparseArray/DockerImage/Dockerfile도 변경

**반영**: PLP v6.0.0 설치 줄을 양쪽 Dockerfile에 추가했다.

---

## B. 지시 문서와 코드가 다른 부분 (해결)

### B1. target cohort 1003은 `visit_occurrence`를 조회하지 않는다 (status: 해결)

`Inpatient_visit_discharge.sql`(cohort 1003)은 visit_occurrence를 보지 않고 cohort 1000의 행을
복사해 `cohort_end_date`를 index date로 쓰는 파생 cohort다.

> 사용자 답변: 지금대로 진행

**반영**: `WHERE EXISTS`는 `Inpatient_visit.sql`(1000)에만 있다. 1003은 1000에서 파생되므로
자동으로 제한되고, `runDiagnostics()`가 양쪽을 확인한다. 두 사본(원본·TabEHR)은 바이트 단위로
동일하다.

### B2. Shock(2027) phenotype 제외 여부 (status: 해결)

> 사용자 답변: Shock 포함

**반영**: 2027 유지(phenotype 27개, task 38개). settings 파일은 손대지 않았다.

### B3. study population flow의 단계 순서 (status: 해결)

> 사용자 답변: 성인 → 입원 이력 → 기록 수 순으로 통일

**반영**: `StudyPopulationFlow.sql`의 누적 순서를 `전체 → 성인 기록 있음 → 2일 이상 입원 이력
→ 기록 10건 이상(= 대상 환자)`으로 맞췄다. 단독 탈락 수(5~7행)도 함께 남긴다.

---

## C. MedRep 원본 코드의 경계 동작

`create_trajectory.py`의 pandas 동작 중 결과에 영향을 주는 것들이다. 로컬에서 pandas 2.3.2로
직접 실험해 확인했다(`tests/testthat/test-quantiles.R`). **cond/drug/proc는 원본대로 두고,
measurement는 FeatureExtraction에 맞췄다**(G절).

| # | 원본 동작 | 적용한 결정 |
|---|---|---|
| C1 | 검사값은 숫자인데 단위가 결측인 행 → `groupby`가 결측 키를 버려서 **기록이 통째로 사라짐** | **유지**(단위 판정만 `unit_source_value` → `unit_concept_id` 0/NULL로 변경). FE는 이 행을 'Unknown unit' covariate로 남기므로, 그 covariate는 이쪽에 대응 토큰이 없다 |
| C2 | `unit_source_value`가 문자열 `'nan'`인 행 → 비수치 분기 | **해소**. 단위를 `unit_concept_id`로 보고 값을 `value_as_number`로 읽으므로 `'nan'` 문자열이라는 개념 자체가 없어졌다 |
| C3 | `measurement_datetime`이 NULL이면 `measurement_date`로 채우지 **않는다** → 탈락 | 원본대로 유지. 건수는 `checkDatabase()`가 보고 |
| C4 | `drug_exposure`는 start와 **end** datetime 모두 범위를 통과해야 한다 → end가 NULL이면 탈락 | 원본대로 유지 |
| C5 | concept 필터가 4개 도메인 목록으로 조인되고 `standard_concept`·`invalid_reason` 필터는 없다 | **FE와 동일하게 통일: `concept_id <> 0`만.** FE의 `DomainConcept.sql`이 그렇게만 필터하므로(CONCEPT은 이름용 LEFT JOIN), 두 출력의 concept 집합이 일치한다. 원본의 4개 도메인 조인도 제거했다 |
| C6 | 날짜 범위가 **문자열 비교**(`<= '2260-12-31'`)라 그날의 시각이 있는 행은 탈락 | SQL에서 `<= '2260-12-31 00:00:00'`으로 동일하게 재현 |
| C7 | 시간당 1건 추출에서 pandas는 **파일 순서**의 첫 행을 고른다 | `ORDER BY measurement_datetime, measurement_id`(결정적). 컬럼은 `measurementTieBreakColumn` 설정 |
| C8 | 중복 제거 키에 `domain`이 포함되어 같은 concept·시각이 두 도메인에 있으면 두 행 모두 남는다 | 원본대로 유지 |
| C9 | 나이 조건은 `>= 18`만 (`labeling.py`는 `between(18, 100)`) | 지시 문서대로 **상한 없음** |
| C10 | 분위수는 pandas `quantile()` 선형보간. 단 pandas는 `np.percentile(x, q*100)`을 거쳐 **확률이 `q*100/100`으로 왕복**되며 double 값이 바뀐다 | R에서 같은 왕복을 재현해 SQL에 리터럴로 주입. 경계값 77개 전부 pandas와 비트 단위 일치 |
| C11 | 분위 배정은 `max(0, bisect_left(q, value) - 1)` | `max(0, (q_j < value 개수) - 1)`로 동일 (probe 197개 일치). R에서도 `assignQuantileBin()`이 같은 규칙 |
| C12 | 분위수를 **분할 전, 전체 환자**로 계산하고 **기관마다 따로** 계산한다 | **동일하게 유지**(한때 pretraining 기준으로 바꿨다가 되돌림). 기준 집합 = 배정 집합이므로 `value > q10`이 불가능하고 `bin 10`이 생기지 않는다 → 토큰 공간이 `_0`~`_9`로 유지되어 MedRep 표현 테이블과 deploy_LG 임베딩 양쪽과 호환된다 |

---

## D. DB를 봐야 확정되는 가정 (status: 실행 확인)

`checkDatabase()`를 돌리면 아래가 `output/<databaseId>/validation_report.md`에 기록된다.

| # | 가정 | 확인 방법 | 안 맞으면 |
|---|---|---|---|
| D1 | DatabaseConnector 5.0.2에서 BIGINT가 손상 없이 R에 온다 | 큰 BIGINT 왕복 비교 | 이미 모든 export가 `CAST(... AS VARCHAR(20))`이므로 동작에는 영향 없음 |
| D2 | PLP의 `population$subjectId`가 2^53을 넘는 person_id를 유지한다 | `runDiagnostics()`의 "Labelled patients against the downstream set" | 손상되면 label 조인을 (subject_id, cohort_start_date) 쌍으로 |
| D3 | person_id를 double로 반올림해도 두 환자가 같은 값이 되지 않는다 | `CheckPersonIdRange.sql`의 `n_colliding_groups` | 문자열 방식만 사용 |
| D4 | `cohortDatabaseSchema`에 테이블 생성·삭제 권한이 있다 | 임시 테이블 생성/삭제 | 쓰기 가능한 스키마 필요 |
| D5 | `measurement.value_as_number`, `unit_concept_id`가 채워져 있다 | `CheckMeasurementColumns.sql`의 NULL 비율과 `n_value_source_without_number` | 많이 비어 있으면 분위 토큰이 거의 생기지 않는다. 그 경우 값 출처를 다시 논의해야 한다 |
| D6 | `visit_occurrence.visit_end_date`가 입원 행에서 NULL이 아니다 | NULL 건수 | NULL이면 2일 조건에서 탈락(현재 동작) |
| D7 | `unit_concept_id mod 1000`이 같은 서로 다른 단위가 한 검사에 쓰이지 않는다 | 전용 진단은 없다(삭제). `measurementValueUnitRef.csv`에서 `covariateId`가 2행인 것, 또는 `covariateToToken()` 결과의 `unitAmbiguous` 건수 | 충돌이 있으면 그 covariate는 FE가 이미 두 단위를 합쳐 버린 것이다. 값 자체가 섞여 있어 되돌릴 수 없으므로 `resolveCovariateId()`은 하나를 고르지 않고 `unitAmbiguous`로 보고하고, 그 레코드는 bin 없는 bare concept 토큰으로 떨어진다 |
| D8 | `vocabulary` 테이블에 `vocabulary_version`이 있다 | 조회 | `run_info.json`에 빈 값 |
| D9 | DatabaseConnector에 `querySqlToAndromeda()`가 있다 | 패키지 확인 + 4단계 | 없으면 경고 후 전체를 메모리에 모은다(전체 실행은 불가) |
| D10 | `measurement.measurement_id` 컬럼이 있다 | 컬럼 확인 | `measurementTieBreakColumn = ""`로 두면 datetime만으로 정렬(비결정적) |

---

## E. observation_period와 death 테이블 이슈 (status: 보류)

> 사용자 답변: 앞으로 이부분은 우선 무시

**반영**: 관련 보고 쿼리와 스크립트를 삭제했다. 필요해지면 git 이력에서 되살린다.

---

## F. 그 밖의 결정

| # | 항목 | 적용한 결정 |
|---|---|---|
| F1 | 설정 형식 | OHDSI 관례대로 `create*Settings()` 설정 객체. 기관 공통 설정은 `inst/settings/analysisSettings.json`, 기관별 값은 `extras/CodeToRun.R`의 인자 |
| F2 | 출력 형식 | `arrow`가 이미지에 없어서 **CSV(+gzip)**만 |
| F3 | 1,000명 샘플 | `createPersonSampleSettings(samplePersonCount = 1000)`. `person_id` 정렬 후 상위 N명(결정적) |
| F4 | `meas_quantiles.csv` | 키 `(measurement_concept_id, unit_concept_id)` + `unit_source_value`·`n_unit_source_value`·`n`·`basis` (원본의 상위집합). `unit_concept_id_mod1000`은 넣었다가 다시 뺐다: 단위 해석은 `covariateRef.csv`의 `unitConceptId`가 하므로 쓰는 곳이 없다 |
| F5 | 외부 기관 | `siteRole = "external"` → 분할 없이 전원 `stage = external`. 분위수는 **자기 분포로 다시 계산**(MedRep과 동일). 다른 기관 표를 쓰려면 `basis = "file"` |
| F6 | `codes/` 폴더 | 21MB CSV라 `TabEHR/SparseArray`로 복사하지 않았다. 결과물(`icd10ccsr.csv`)은 이미 반영되어 있다 |
| F7 | `SparseArray::execute()`에 `vocabularyDatabaseSchema` 인자가 없다 | **해소**: `SparseArray::execute()` 자신이 삭제됐다(H절). 단계 함수를 `R/TaskInput.R`에서 직접 호출한다 |
| F8 | `(concept, unit) 10건 이상` 필터 기준 | 전체 환자 기준. FE 702에는 이 임계값이 **없으므로**, 임계값 미달 쌍은 FE에는 covariate가 있고 이쪽에는 분위 행이 없다 → 접미사 없는 토큰(F9) |
| F9 | 분위표에 없는 `(concept, unit)` 조합 | 기록을 **버리지 않고** 접미사 없는 `concept_id`로 남긴다. `covariateToToken()`도 같은 규칙을 쓰고 `hasBin = FALSE`로 표시한다 |
| F10 | `createLongFormat()`이 출력 폴더마다 고정 파일명을 쓴다 | 호출 후 `longFormat/<extraction>/`로 파일을 이동. 함수와 형식은 그대로 |
| F11 | PostgreSQL에서 SqlRender가 `FLOAT` → `NUMERIC`으로 번역 | SQL Server에서는 문제없음. 다른 DBMS에서는 경계값 최하위 자릿수가 달라질 수 있다 |
| F12 | `TRY_CAST` 방언 분기 | **삭제.** 값을 `value_as_number`로 읽으므로 캐스트가 필요 없다. 방언별 표현식은 `DATEPART`(시간당 1건) 하나만 남았다 |

---

## G. allrecords ↔ featureExtractionLong 대응 (해결)

두 출력이 기록을 다르게 식별한다는 문제였다.

```
allrecords.csv            concept_id, 검사는 "<concept_id>_<bin>"   ← 모델 임베딩의 키
featureExtractionLong.csv covariateId
```

FeatureExtraction v3.2.0 원본 SQL에서 확인한 규칙:

```sql
-- DomainConcept.sql (101 ConditionOccurrence / 301 DrugExposure / 501 ProcedureOccurrence)
covariate_id = concept_id * 1000 + analysis_id

-- MeasurementValue.sql (702 MeasurementValue, temporal 분석 집합)
covariate_id = measurement_concept_id * 1000000
             + (unit_concept_id % 1000) * 1000
             + analysis_id
covariate_value = value_as_number      -- 창(window)의 마지막 값
```

**결정**: 어느 쪽도 식별자를 바꾸지 않는다.

- `allrecords`를 covariateId로 바꿀 수 없다. deploy_LG 임베딩 index는 **concept_id 정수
  493,560개**이고(`_` 포함 항목 0개), MedRep `tokenize_for_pretrain_1.py:155`가
  `vocab = allrecords['concept_id']`로 vocab을 만든다. covariateId로 바꾸면
  `build_v12_npy.py`의 모든 분기를 빗나가 **전부 0 벡터**가 된다.
- SparseArray/PLP도 covariateId를 유지한다. covariateId는 PLP의 feature 키이고, analysis 출처와
  단위 구분을 담고 있다.
- 대신 **사후 변환**으로 잇는다: `decodeCovariateId()` → `covariateToToken()`. FE의 SQL을
  대체할 필요가 없다.

이를 위해 measurement 쪽을 FE에 맞췄다(C절 C1·C5, CLAUDE.md 4절). 남은 차이는 **시간 해상도**
하나뿐이다: 이쪽은 (환자, concept, 시간) 1건, FE 702는 하루의 마지막 값. 당장은 그대로 둔다.

### G2. measurement value covariate: FE와 같은 id + 디코딩 가능한 ref (status: 구현됨, 실행 확인 필요)

처음에는 분위 bin을 covariate_id에 담는 빌더(711/710)를 만들었으나 **폐기**했다. 요구는
"SparseArray에서 나오는 건 FE 기반 measurementValue랑 똑같고, cov_ref로 디코딩만 되면 된다"
이므로, id 규칙을 새로 만들 이유가 없다.

그런데 조사 과정에서 **FE 3.2.0은 temporal sequence에서 measurement value를 아예 뽑을 수
없다**는 것이 드러났다. `inst/sql/sql_server/MeasurementValue.sql`의 temporal sequence 분기가

```
FLOOR(DATEDIFF(@time_part, measurement_date, cohort.cohort_start_date)*1.0/@time_interval ) as time_id
ROW_NUMBER() OVER (...) AS rn,
```

로, `as time_id` 뒤에 **쉼표가 없다** → 렌더된 SQL이 문법 오류. 702는
`PrespecTemporalAnalyses.csv`에서 `isDefault = FALSE`라 기본 설정으로는 아무도 밟지 않는
경로이고, 그래서 버그가 남아 있던 것으로 보인다. 즉 우리 SQL은 "선택"이 아니라 **필수**다.

그래서 `useMeasurementValue` 대신 **`useMeasurementValueUnit`**을 studySettings.json에 쓴다.
`SparseArray::createMeasurementValueUnitCovariateSettings()`가 FE 파일의 복사본(쉼표 추가)을
실행하므로 **id 공식과 값은 FE 것**이지만, analysisId는 이 프로젝트 것이다:

| analysisId | 이름 | 내용 |
|---|---|---|
| 998 | `MeasurementValueUnit` | 숫자값이 있는 측정. `concept*1e6 + (unit%1000)*1000 + 998` |
| 999 | `MeasurementNoValue` | 숫자값이 없는 측정. `concept*1000 + 999`. 같은 (row, concept, 하루)에 998이 없을 때만 |

- 702를 쓰지 않는 이유: 내용이 다르다(단위를 `COALESCE(unit_concept_id, 0)`으로 읽어서, FE가
  조인에서 버리는 **단위 미매핑 수치 검사를 살린다**), 그리고 FE의 702는 temporal에서 렌더조차
  안 된다. 99x는 FE의 두 prespec 집합(최대 926) 어디와도 겹치지 않는다
- 701(`useMeasurement`)은 **끈다**. 모든 측정을 덮으므로 998과 함께 켜면 한 기록이 covariate
  2개가 된다. 동시 설정은 `buildCovariateSettings()`가 에러로 막는다
- 상속되는 동작은 그대로: 한 구간에 한 concept이 두 단위로 측정되면 `ROW_NUMBER`가 concept
  단위로 분할되므로 한 행만 남는다

단위 디코딩은 **빌더가 아니라 별도 crosswalk**로 한다. `covariateRef`에 컬럼을 더할 수 없기
때문이다: FE는 여러 설정의 결과를 `Andromeda::appendToTable()`로 합치고, 그 함수는
`select(data, all_of(colnames(tbl)))`로 **붙여넣는 쪽 테이블의 컬럼만** 고르므로 5번째 컬럼은
조용히 사라진다(반대로 우리 테이블이 타깃이면 FE 쪽 4컬럼이 부족해 에러). 대신 id가 (concept,
unit)의 함수라는 점을 이용해 CDM에서 되돌린다:

- `SparseArray::exportMeasurementValueUnitRef()`가 `measurementValueUnitRef.csv` 작성 —
  `(covariateId, conceptId, unitConceptId, recordCount)`, FE의 `#meas_cov`와 같은 쿼리
- `createLongFormat()`이 그 `unitConceptId`를 `covariateRef.csv`에 조인
- `covariateToToken(..., covariateRef = ref)`가 **단위 전체**로 분위표를 조회

mod 1000이 겹치는 두 단위는 한 covariate_id를 공유하고 crosswalk에 2행으로 나타난다. 그 값은
실제로 두 단위가 섞여 있어 되돌릴 수 없으므로 `resolveCovariateId()`은 하나를 고르지 않고
`unitAmbiguous = TRUE`로 보고하고, 토큰은 bare concept로 떨어진다.

그래서 **잔차(mod 1000)를 쓰는 코드는 전부 삭제했다.** 순서대로 지운 것:

1. `covariateToToken()`의 `covariateRef = NULL` 분기(잔차로 분위표 조회) → `covariateRef` 필수
2. `meas_quantiles` 표/CSV의 `unit_concept_id_mod1000` 컬럼 → 쓰는 곳이 없어짐
3. `resolveCovariateId()`의 정합성 검사(잔차를 역산해 ref와 비교) → 삭제
4. `CheckUnitCollision.sql`과 그것이 읽던 `concept_unit.unit_concept_id_mod1000` 컬럼,
   `runDiagnostics()`의 해당 섹션 → 삭제

4번은 "합쳐진 covariate가 몇 건인가"를 세는 진단이었는데, 같은 사실이 이제 변환 경로 자체에서
`unitAmbiguous`로 나온다(crosswalk에 2행인 id). measurement 테이블을 또 스캔해서 따로 셀 이유가
없다. 3번이 잡던 "다른 run의 ref" 상황은 대부분 `covariateRef`에 없는 covariateId 조인에서
에러로 걸린다. 남은 산술은 `decodeCovariateId()` 하나뿐이고, 그건 ref 없이 id만 들여다볼 때
쓰는 유틸리티라 변환 경로에 들어가지 않는다.

**실행 확인이 필요한 것 2가지** (DB 없이는 불가):
1. 빌더가 만든 `rowId`가 `outcomeLabels.csv`의 `rowId`와 맞는지
2. 빌더가 반환하는 `covariates`/`covariateRef`/`analysisRef`의 컬럼 **이름 집합**이 FE 쪽과
   같은지 — `appendToTable()`은 이름으로 맞추므로 어긋나면 조용히 틀리지 않고 에러가 난다.
   특히 `analysisRef`의 `startDay`/`endDay`(temporal sequence에서 NULL로 들어감)

### G1. deploy_LG v12 임베딩은 분위를 구분하지 못한다 (status: 답 대기)

| 증거 | 내용 |
|---|---|
`embeddings/medfm_embeddings_v12.index.json` | concept_id 정수 493,560개. decile 토큰 슬롯 없음 |
`scripts/build_v12_npy.py:109-118` | `<base>_<0-9>` 토큰 → **base concept 벡터를 복사** |
`codes/experiments/finetune.py:167-169` | 그 행렬을 embedding에 넣고 `model.bert.embeddings` **전체 freeze** |
`codes/experiments/pretrain.py:169` | pretraining에서도 `concept_embeddings` freeze |

⇒ `3004501_0` … `3004501_9`가 **동일한 고정 벡터**다. 입력 단계에서 값의 높낮이를 구분할 수
없다(`EhrEmbeddings.forward`의 다른 채널은 age/visit_rank/record_rank/domain뿐).

MedRep 원본은 달랐다: `representation/preprocess_for_representation.py:79-86`이 분위별로
concept_name을 `"... (7th decile)"`로 바꿔 **분위별 텍스트를 따로 인코딩**하고,
`gpt_description.py:31`은 LLM에게 decile의 임상적 의미를 설명하라고 지시한다.

**확인 못 한 것**: 배포된 BEHRT 체크포인트가 실제로 복사 벡터로 pretraining된 것인지는
artifact만으로는 알 수 없다. `Manuscript/iclr_2027_TabEHR.pdf`는 로컬에 PDF 텍스트 추출
라이브러리가 없어 읽지 못했다.

**질문**: LG 쪽에 분위별 표현을 요청할지, embedding을 unfreeze 할지, `rep_type='none'`으로
처음부터 학습할지. 이 프로젝트의 출력 형식에는 영향이 없다(어느 쪽이든 `<concept_id>_<bin>`
토큰을 만든다).

---

## H. 기준 데이터 전환 (2026-10-16 방향 수정, status: 구현됨 / 실행 확인 필요)

allrecords와 SparseArray 출력이 따로 만들어지던 구조를 뒤집었다. **allrecords가 기준
데이터**이고, downstream input은 거기서 걸러 만든다. MedRep 재현은 비교용으로 `extras/`에
분리했다. 확정된 내용은 `CLAUDE.md` §4 "처리 흐름"·"allrecords"·"downstream task input"에
있고, 여기에는 구현하면서 생긴 사실과 남은 확인 사항만 적는다.

### H1. allrecords를 FE 추출로 뽑으면서 따라온 것

- **날짜 단위**가 됐다. `timeId`가 일 단위이므로 `record_date = index_date - timeId`이고
  시각(hh:mm)은 남지 않는다. MedRep 원본(시간당 1건, 타임스탬프)과 다르고, 그 차이는
  `output/<db>/MedRep/README.md`에 적힌다
- **전 기간 cohort**: 환자 1인 1행, `cohort_start_date` = 그 환자의 **마지막 기록일**(CDM 4개
  도메인 MAX), 창은 `-99999..0`. 기준일을 1단계 테이블이 아니라 CDM에서 구하는 이유는 1단계가
  버리는 기록이 FE에는 남아 index 뒤로 빠질 수 있기 때문
- **person_id**는 `allrecords_cohort`의 `row_id ↔ person_id`로만 복원한다. FE에 넘기는
  rowIdField는 dense `row_id`라 double로 깎일 값이 없다
- **DB 테이블을 만들지 않는다.** FE가 만든 Andromeda(`allRecordsCovariates.zip`)를 그대로
  작업 산출물로 쓰고 거기서 CSV를 스트리밍한다. 수억 행을 JDBC로 되밀어 넣는 비용을 피한다

### H2. 1단계와 4단계의 기록은 다르다 (의도)

`extractRecords()`는 환자 선정 기준(원본 MedRep 규칙: 시간당 1건, 쌍 10건, unit≠0)을 위한
것이고 `createAllRecords()`는 FE 규칙이다. 맞추지 않는다. `runDiagnostics()`가 환자별 기록 수
차이와 **allrecords 기록이 10건 미만인 study population 환자 수**를 보고한다.

### H3. DB 분위 경로를 남겨둔 상태 (status: 삭제 여부 답 대기)

분위수는 이제 `extras/CreateMedRepFiles.R`이 allrecords에서 R로 계산한다(`stats::quantile(type = 7)`
= pandas 선형보간, 확률은 C10의 왕복 재현). 그런데 DB에서 계산하던 기존 경로
(`createMeasurementQuantiles()` + `MeasurementQuantiles*.sql` 4개)를 **지우지 않고 남겼다**:
pandas 일치를 비트 단위로 검증해 둔 코드라, 실제 데이터에서 R 경로가 확인될 때까지 두는 게
안전하다고 판단했다. 본 흐름(`execute()`)에서는 호출하지 않는다. 확인되면 삭제한다.

### H4. 실행해야 확정되는 것

| # | 가정 | 확인 방법 |
|---|---|---|
| H4-1 | `FeatureExtraction::getDbCovariateData()`가 우리 영구 cohort 테이블과 `rowIdField = "row_id"`로 동작한다 | 4단계 로그. 시그니처는 소스로 확인했다(`cohortTable`, `cohortDatabaseSchema`, `cohortTableIsTemp`, `cohortId`, `rowIdField`) |
| H4-2 | 998/999 covariate가 FE의 condition/drug/procedure 결과와 **컬럼 이름 집합**이 같아 `appendToTable()`이 받아들인다 | 4단계가 에러 없이 끝나는지. 어긋나면 조용히 틀리지 않고 에러가 난다 |
| H4-3 | allrecords Andromeda(SQLite)가 전체 데이터에서 실용적인 크기·속도인지 | 4단계 소요 시간과 `allRecordsCovariates.zip` 크기 |
| H4-4 | label의 `subjectId`(PLP가 double로 준다)로 환자를 맞출 수 있는지 | `createTaskInput()`이 study population의 person_id가 double로 충돌하지 않는지 먼저 확인하고, 충돌하면 에러로 멈춘다(D3와 같은 가정) |
| H4-5 | 창 밖으로 빠진 기록이 없는지 | `allrecords_cohort.csv`의 first/last record date 간격이 99999일 미만인지 |
