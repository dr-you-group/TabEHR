# 확인이 필요한 사항과 적용한 결정

지시 문서(`CLAUDE.md`)와 실제 코드가 맞지 않거나, DB를 봐야 확정할 수 있는 항목을 모았다.

- 상태: `해결` = 결정 반영 / `실행 확인 완료` = 실제 산출물 또는 DB로 검증 /
  `일부 확인` = 확인 범위에 한계가 있음 / `답 대기` = 연구·구현 방향 결정 필요
- 마지막 갱신: 2026-10-24

## 2026-10-24 확인 범위

**재점검 판정**: 아래 D·G2·H4는 완료된 MIMIC 실행에서 확인한 사실이다. 이를 패키지의
모든 실행 경로가 안전하다는 의미로 해석하면 안 된다. 같은 날 후속 코드 점검에서 캐시
재사용·실패 반환·진단 누락 문제를 재현했으며, **I절의 수정 전에는 일반적인 재실행까지
“문제없는 구현”으로 판정하지 않는다.**

MIMIC-IV PostgreSQL 전체 실행(46,990명, 61,296,292개 기록, 38개 task)을 기준으로
D·G2·H4의 가정을 확인했다. DB 추가 조회는 읽기 전용으로 수행했으며 본 파이프라인을
재추출하지 않았다. **다른 기관·DBMS에 대한 실행 검증은 아니다.**

근거는 다음 파일에 있다. 전체 데이터는 `D:\TabEHR-storage\files\output\mimic`에 있고,
아래 링크는 프로젝트에 복사한 집계 보고서다.

- [전체 실행 진단](output/full-D-validation/validation_report.md)
- [독립 산출물 검증](output/full-D-validation/execution_validation.json)
- [미확인 가정 추가 조회](output/full-D-validation/open_questions_audit.json)
- [PLP·label·long format rowId 대조](output/full-D-validation/open_questions_rowids.json)

**읽는 순서**: C·F·G에는 이전 설계의 결정 이력이 남아 있다. 현재 주 산출물의 정의는
H와 `CLAUDE.md` §4가 우선한다. 본 `allrecords`는 날짜 단위의 원값이며, 단위 미매핑
수치 검사도 `unit_concept_id = 0`으로 남는다. 분위 토큰은 선택 기능인 MedRep 변환에만
해당한다. 그 선택 기능은 전체 실행에 포함하지 않았고, H3에 별도 미해결 오류를 기록했다.

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

## D. DB를 봐야 확정되는 가정 (status: 확인 완료, D5는 결측 존재)

`checkDatabase()`의 전체 DB 진단과 2026-10-24 추가 조회를 함께 사용했다.

| # | 확인 항목 | 실제 결과 |
|---|---|---|
| D1 | DatabaseConnector 5.0.2의 BIGINT 보존 | `databaseConnectorInteger64AsNumeric = FALSE`에서 2^53+1, 양·음수 19자리 ID, BIGINT 최댓값 **4/4 정확**. TRUE 설정은 진단에서 QUERY FAILED이므로 지원 확인으로 해석하지 않는다 |
| D2 | PLP subjectId와 실제 환자 연결 | downstream 7,049명 중 외부 환자 0명. 전체 label 315,525행을 정확한 ID와 DB cohort event로 검증 완료. 저장된 PLP cohort와의 직접 대조 결과는 별도 rowId 보고서 참조 |
| D3 | double 변환 시 서로 다른 person_id 충돌 | 전체 317,878명 중 317,571명의 절댓값이 2^53 초과. **충돌 그룹 0개**. 이 DB에서만 확인한 성질이며 CSV ID는 계속 문자열로 읽어야 한다 |
| D4 | cohort schema 생성·삭제 권한 | `mimiciv`에서 생성→2행 쓰기→문자열 왕복→삭제 성공. 실제 작업 테이블 10개도 D tablespace에서 확인 |
| D5 | 수치값·단위의 채움 정도 | **완전하게 채워져 있지는 않다.** 전체 433,533,849건 중 수치값 NULL 83,794,670건(19.33%), 단위 ID NULL 131,741,298건(30.39%), 0은 3,128,630건(0.72%). 수치값은 있으나 단위 미매핑 65,650,336건(수치값 있는 행의 18.77%) |
| D6 | 입원 종료일 결측 | 9201·262 및 하위 concept에 해당하는 입원 **68,059건 중 NULL 0건** |
| D7 | 단위 mod 1000 충돌 | `measurementValueUnitRef.csv` **728행 / covariateId 728개 / 서로 다른 단위가 공유하는 ID 0개**. 실제 allrecords의 수치 covariate 695/695개 단위 복원 성공 |
| D8 | vocabulary_version | 컬럼 존재, `vocabulary_id = 'None'`의 값은 **v5.0 27-AUG-25**. `run_info.json`과 일치 |
| D9 | querySqlToAndromeda() | DatabaseConnector 5.0.2에서 export 존재. 998/999 빌더가 실제 호출해 전체 추출 성공. 현재 빌더는 이 함수를 직접 호출하므로 없는 환경의 메모리 fallback은 보장하지 않는다 |
| D10 | measurement_id | **BIGINT, NOT NULL** 컬럼 존재. 현재 tie-break 설정은 `measurement_id` |

D5의 `value_source_value`가 있으나 `value_as_number`가 없는 행은 65,437,058건이다.
이 집계만으로 ETL 오류인지 정상적인 비수치 검사인지 판정할 수는 없다. 현재 본 파이프라인은
998(수치)·999(비수치) 정의를 따르며, 최종 수치 검사 41,524,934행의 단위가 raw 추출과
crosswalk에 일치함을 검증했다. **단위 미매핑을 버린다는 기존 진단 안내는 1단계 환자 선정
규칙에 관한 설명이며, 4단계 allrecords에는 적용되지 않는다.**

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

### G2. measurement value covariate: FE와 같은 id + 디코딩 가능한 ref (status: 실행 확인 완료)

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

**2026-10-24 실행 확인 결과**:

1. 세 추출의 저장된 `cohorts.rds`와 label 315,525행을 `(extraction, rowId)`로 대조했다.
   rowId 누락·subjectId 불일치·index date 불일치가 모두 **0**이다. long format 전체
   22,040,045행도 읽었으며 PLP cohort에 없는 rowId는 **0**이다. PLP subjectId의 실제
   클래스는 세 그룹 모두 **integer64**였다(double이라는 과거 설명은 현재 실행과 다르다).
2. 전체 allrecords 추출과 세 PLP 추출에서 FE 표준 분석과 998/999의 병합이 성공했다.
   실제 long format은 `rowId,covariateId,timeId,covariateValue`, `analysisRef`는
   `analysisId,analysisName,domainId,startDay,endDay,isBinary,missingMeansZero`다.
   998/999의 `startDay`·`endDay`는 NULL로 보존됐다. CSV `covariateRef`의
   `unitConceptId`는 병합 후 별도 조인한 컬럼이다.

long format에는 label 자격 판정 전 추출 행도 있다. 따라서 discharge long format
9,091,696행과 최종 task input 6,580,431행의 차이는 오류가 아니다. 관찰 구간·허용
도메인에 기록이 없는 labelled entry는 admission 6개, no-condition 155개,
discharge 2개이며, 독립 검증에서도 동일하게 확인됐다.

### G1. deploy_LG v12 임베딩은 분위를 구분하지 못한다 (status: 일부 확인 / 학습 방향 답 대기)

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

**2026-10-24 재확인**: 현재 접근 가능한 `/workspace/lgai/medfm`의 index는 실제로
493,560개이며 `_`가 포함된 항목은 0개다. `scripts/build_v12_npy.py:353-369`는
분위 토큰에도 base concept 벡터를 복사하고, `pretrain.py:169` 및
`finetune.py:807-810`은 표현을 주입하는 경로에서 이를 freeze한다. 위 표의 예전
줄 번호 대신 이 현재 경로·줄 번호를 사용해야 한다.

**확인 못 한 것**: 이것은 현재 로컬 checkout의 동작을 확인한 것이다. 문서에 언급된
배포 BEHRT 체크포인트가 정확히 어느 코드·표현 행렬로 학습됐는지 증명하는 provenance는
확인하지 못했다. SSH 서버에는 `C:\git` 및 원래 지목된 PDF 경로가 없고, 현재 TabEHR에도
`Manuscript/iclr_2027_TabEHR.pdf`가 없다. 따라서 과거의 “PDF 추출 라이브러리 부재”를
현재 차단 사유로 반복하지 않는다. 체크포인트에 연결된 학습 설정·로그·표현 행렬 해시가
있어야 그 학습 이력까지 확정할 수 있다.

**질문**: LG 쪽에 분위별 표현을 요청할지, embedding을 unfreeze 할지, `rep_type='none'`으로
처음부터 학습할지. 이는 모델 설계 결정이다. 현재 본 파이프라인의 원값 출력 형식에는
영향이 없으며, `<concept_id>_<bin>`은 선택 MedRep 변환을 실행할 때만 만들어진다.

---

## H. 기준 데이터 전환 (2026-10-16 방향 수정, status: 본 흐름 실행 확인 완료)

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
- **전체 기록을 DB 테이블로 다시 적재하지 않는다.** `allrecords_cohort`라는 매핑 테이블은
  생성한다. FE가 만든 Andromeda(`allRecordsCovariates.zip`)를 작업 산출물로 쓰고 거기서
  CSV를 스트리밍하므로 수억 행을 JDBC로 되밀어 넣지 않는다

### H2. 1단계와 4단계의 기록은 다르다 (의도)

`extractRecords()`는 환자 선정 기준(원본 MedRep 규칙: 시간당 1건, 쌍 10건, unit≠0)을 위한
것이고 `createAllRecords()`는 FE 규칙이다. 맞추지 않는다. `runDiagnostics()`가 환자별 기록 수
차이와 **allrecords 기록이 10건 미만인 study population 환자 수**를 보고한다.

2026-10-24 전체 진단에서 선정 단계보다 allrecords가 적은 환자 23,018명, 많은 환자
23,459명이며 차이의 중앙값은 0이다. allrecords가 10건 미만인 대상 환자는 **0명**이다.

### H3. DB 분위 경로를 남겨둔 상태 (status: 대체 경로 미검증 / 삭제 보류)

분위수는 이제 `extras/CreateMedRepFiles.R`이 allrecords에서 R로 계산한다(`stats::quantile(type = 7)`
= pandas 선형보간, 확률은 C10의 왕복 재현). 그런데 DB에서 계산하던 기존 경로
(`createMeasurementQuantiles()` + `MeasurementQuantiles*.sql` 4개)를 **지우지 않고 남겼다**:
pandas 일치를 비트 단위로 검증해 둔 코드라, 실제 데이터에서 R 경로가 확인될 때까지 두는 게
안전하다고 판단했다. 본 흐름(`execute()`)에서는 호출하지 않는다. 확인되면 삭제한다.

**2026-10-24 확인**: 전체 실행에서 MedRep 변환은 실행하지 않았고 `MedRep/` 산출물도
없다. 더구나 `extras/CreateMedRepFiles.R:82`가 호출하는 `resolveCovariateUnit()`은
현재 소스·NAMESPACE·설치된 TabEHR에 **존재하지 않는다**. 존재하는 함수는
`resolveCovariateId()`다. 따라서 지금 상태의 extras가 실행 가능하다고 판정할 수 없고,
실제 데이터에서 분위수·토큰을 검증했다는 주장도 할 수 없다. 이번 확인에서는 주
파이프라인이나 extras 코드를 수정하지 않았다.

삭제의 선행 조건은 extras의 함수 호출·integer64 조인 경로를 점검/수정하고, 실제 데이터로
분위 경계·토큰 범위·단위 미매핑 처리·환자 분할 보존을 검증하는 것이다. 기존 DB 분위
코드를 삭제할 조건이 아직 충족되지 않았으므로 그대로 둔다.

### H4. 실행 가정 검증 (status: 5개 항목 확인 완료)

| # | 가정 | 2026-10-24 결과 |
|---|---|---|
| H4-1 | 영구 cohort와 `rowIdField = "row_id"` 사용 | 실제 로그가 `mimiciv.tabehr_allrecords_cohort`, `row_id` 사용을 기록. 46,990명 / 61,296,292행 추출 성공 |
| H4-2 | 표준 FE와 998/999 컬럼 호환 | 전체 allrecords 및 세 PLP 추출의 병합 성공. G2에서 실제 ref 컬럼과 NULL 확인 |
| H4-3 | 전체 데이터의 크기·속도 | cohort 생성 시작 14:58:29 → cache 저장 15:30:35 → CSV 완료 15:53:59 KST. 4단계 **55분 30초**, 이 중 FE 추출 시작→cache 저장 **29분 51초**. ZIP **559,821,233 bytes(약 534 MiB)**. 현재 MIMIC/서버의 실측이며 타 기관 규모에 일반화하지 않는다 |
| H4-4 | label의 환자 연결 | 실제 PLP subjectId는 integer64. 정확한 환자 ID·rowId·index date 대조 불일치 0, 최종 task input의 allrecords 대비 누락·추가 기록 모두 0. 내부 double 키 조인은 D3의 충돌 없음 조건에 계속 의존 |
| H4-5 | 전 기간 추출 창 | cohort 46,990행의 최대 first→last 간격 **5,847일**, 결측 0, 99,999일 초과 0, index_date ≠ last_record_date 0. 이 항목은 기존 진단에 자동 기록되지 않아 이번에 CSV로 추가 확인 |

---

## I. task 수행 코드 재점검 (2026-10-24, status: 수정 필요)

현재 소스의 TabEHR 테스트 56개(173 assertions), bundled SparseArray 테스트 21개
(80 assertions)를 실제 RStudio 컨테이너에서 다시 실행했다. 실패·오류·skip·warning은
모두 0이다. 그러나 기존 테스트가 다루지 않던 아래 경로에서는 문제가 재현됐다.

근거:

- [격리 실행 재현](output/code-review-20261024/edge_cases.json)
- [실제 진단 함수의 누락 탐지 결과](output/code-review-20261024/diagnostic_coverage.json)
- [불완전한 출력 폴더에 대한 진단 보고서](output/code-review-20261024/incomplete-output-diagnostic.md)
- [TabEHR 테스트](output/code-review-20261024/TabEHR-tests.csv),
  [SparseArray 테스트](output/code-review-20261024/SparseArray-tests.csv)

### I1. 변경된 설정이나 불완전한 추출도 캐시로 재사용 (P1)

- 위치: `SparseArray/R/extractPlpData.R:157-160`, `R/AllRecords.R:218-220`,
  `R/TaskInput.R:301-321`, `R/Main.R:150-177`.
- PLP 추출은 폴더가 있다는 이유만으로 반환한다. **파일 0개인 빈 추출 폴더**를 만들고
  다른 target/outcome을 요청해도 예외 없이 기존 폴더를 반환하는 것을 재현했다.
- allrecords도 ZIP 존재 여부만 보고 재사용한다. 환자 선정·seed·추출 설정·CDM 상태의
  일치 여부는 검사하지 않는다. `execute()`는 앞 단계 테이블을 다시 만들면서 뒤 단계
  캐시는 그대로 사용할 수 있고, 두 캐시를 함께 갱신하는 인자도 노출하지 않는다.
- 영향: 샘플→전체 실행, seed 변경, task/관찰 창 변경, 중단 후 재개 때 이전 결과와 새
  설정이 섞이거나 불완전한 캐시 때문에 실패할 수 있다. 이번 전체 실행은 별도 D 출력에서
  만들어졌고 환자·라벨·입력을 독립 대조했으므로, 이 발견만으로 기존 결과가 틀렸다는
  뜻은 아니다.
- 필요한 수정: 캐시 완전성 및 입력/설정 일치 검사, 의도적인 재사용·재추출 제어,
  샘플→전체와 설정 변경에 대한 회귀 검증.

### I2. 오류가 발생해도 Rscript 종료 코드가 0일 수 있음 (P1)

- 위치: `R/Main.R:89-95`, `extras/CodeToRun.R:56`의 최상위 `execute()` 호출.
- 현재 ParallelLogger 2.0.2의 오류 처리와 결합하면, 단계에서 `stop()`을 발생시켜도
  **오류 메시지 출력 → 다음 최상위 문장 실행 → 종료 코드 0**이 되는 것을 별도 Rscript에서
  재현했다. DB를 건드리지 않도록 추출 단계만 통제된 오류 함수로 대체했고 실제
  `execute()` 및 logger는 그대로 실행했다.
- 영향: README의 직접 `Rscript extras/CodeToRun.R` 실행을 종료 코드만으로 감시하면
  실패한 작업을 완료로 오인할 수 있다.
- 이번 실제 전체 실행에서는 `data/runtime/Run-Continue-full-D.R`의
  `tryCatch(..., error = function(e) quit(status = 1))`와 별도 산출물 검증을 사용했다.
  이 보호 장치가 공식 runner에는 없다.
- 필요한 수정: 공식 runner에서 오류 시 비정상 종료를 보장하고 실제 자식 프로세스
  종료 코드를 검사하는 회귀 검증을 추가한다.

### I3. 주 산출물·task 누락을 진단이 놓치고, FAILED도 실행을 실패시키지 않음 (P1)

- 위치: `R/Diagnostics.R:602`, `R/Diagnostics.R:632-653`, `R/Main.R:193-209`.
- 별도 임시 출력 폴더에 환자 분할 등 기본 파일만 복사하고 라벨은 `death7` **1개 task**만
  남겼다. `allrecords.csv.gz`와 `taskInput/`은 만들지 않았다. 기존 DB에 읽기 전용으로
  연결해 **실제 `runDiagnostics()`**를 실행했는데 `Labels per task — OK`,
  `Output files — OK`, FAILED 0개, WARNING 0개였다.
- 원인: label 검사는 task가 하나라도 있으면 OK이고, allrecords·labels는 optional,
  task input은 파일 목록에 없다. 별도의 FAILED 보고서를 반환하는 진단 사례에서도
  `execute()`가 정상 반환하며 `Done`을 기록하는 것을 확인했다.
- 필요한 수정: 활성 단계의 필수 산출물과 실제 38개 설정을 대조하고, task마다 완료·대상
  없음·실패를 명시한다. 정당하게 대상이 없는 task와 검증 누락을 구분해야 한다.
  검증 실패는 호출자 및 CLI에 실패로 전파해야 한다.
- 현재 MIMIC 결과의 38/38 task·단위·입력/라벨 일치는 별도
  `execution_validation.json`의 독립 검증 근거이며, 이 패키지 진단만으로 증명한 것이 아니다.

### I4. timeInterval > 1을 허용하지만 날짜 변환은 1일 단위로 고정 (P2)

- 위치: `R/AllRecords.R:44-51`, `R/AllRecords.R:161`, `R/TaskInput.R:176-183`.
- `timeInterval = 2` 설정은 받아들이지만 index `2020-01-10`, timeId `1`의 출력 날짜는
  `2020-01-09`였다. 2일 구간의 기준 날짜는 `2020-01-08`이어야 한다. task input도
  bin index를 일수 shift와 직접 빼므로 같은 단위 문제가 있다.
- 현재 전체 실행은 **timeInterval = 1**이라 이 문제의 영향을 받지 않는다.
- 필요한 수정: 현재 날짜 단위 계약에 맞게 1만 허용하거나, 구간 폭·기준일을 전체
  allrecords/task 변환 경로에 일관되게 반영하고 검증한다.

### I5. BIGINT를 보존할 수 있는데도 double 충돌 시 중단 (P2, 타 기관 이식 제한)

- 위치: `R/TaskInput.R:94-101`, `R/TaskInput.R:350`.
- label CSV는 기본 숫자로 읽고 cohort의 정확한 문자열 ID도 double로 바꾼다.
  `9007199254740992`, `9007199254740993` 두 명을 가진 격리 사례는 명확한 문자열 ID가
  있어도 충돌 오류로 중단했다. 잘못된 환자에게 연결되지는 않지만, 유효한 BIGINT 데이터에
  대해 task 수행이 불가능해진다.
- 현재 MIMIC은 D3의 충돌 0건을 검증했다. 다른 기관에도 그대로 적용할 수 있다는 보장은
  아니다. 필요한 수정은 CSV 읽기부터 조인까지 person ID를 문자열로 유지하는 것이다.

### I6. 선택 MedRep 변환은 아직 실행 불가 (P2)

H3의 `resolveCovariateUnit()` 미존재를 설치된 namespace에서도 다시 확인했다.
본 파이프라인의 완료와 선택 변환 기능의 완료를 구분해야 한다. 이 기능의 수정·실데이터
검증 전에는 프로젝트의 모든 기능을 완료했다고 표현하지 않는다.

이번 재점검에서는 본 코드와 기존 산출물을 수정하지 않았다. DB 추가 작업은 읽기 전용이며,
격리 재현 파일 및 집계 보고서를 D 드라이브에 저장했다. 우선 수정 대상은 I1~I3이다.

---

## J. MedRep의 문제를 개선한 전처리 패키지로서의 충분성 (2026-10-24)

**판정: 정해진 전처리와 38개 task 데이터 생성의 핵심 구현은 완료됐고 현재 MIMIC에서
실행 검증됐다. 다만 설정 변경·재개·다기관 실행까지 패키지 자체로 보장하는 완료 상태는
아니다. 남은 핵심 작업은 I1~I3, I5의 실행/검증/ID 처리와 아래 재현성 보강이다.**

### J1. 평가 기준과 비교한 원본

평가 대상은 MedRep과 바이트 단위로 같은 데이터를 만드는 기능이 아니라, `CLAUDE.md`의
확정된 개선 요구다. 필수 흐름은 **환자 선정 → 환자 단위 분할 → 공통 전체 이력 → task별
입력과 라벨 → 자체 검증·실행 기록**이다. Python 토큰화, 임베딩 생성, 모델 학습·평가는
이 패키지 범위 밖이다. MedRep 분위 토큰 변환은 `extras/`의 선택 기능이다.

비교 소스는 `/workspace/lgai/medrep`의 HEAD
`5cb64c5ef38cb370801dfbead7e31a2d3529663c`이다. 두 파일의 작업 사본 변경은 실행 권한만이며
내용은 HEAD와 동일함을 확인했다.

- `codes/preprocessing/create_trajectory.py`:
  SHA-256 `8c96e92392342ffd902d5e8b6123157cf6aee99e49a1577805bb70a453f4c0dd`
- `codes/preprocessing/labeling.py`:
  SHA-256 `03809b0487cdfef5d5c35a28a98c0922034148ef4e8a729a3ed26aefda9f4989`

### J2. 개선 요구별 구현과 증거

| 원본의 동작 또는 개선 요구 | TabEHR의 구현 | 판정·근거 |
|---|---|---|
| 원본은 `allrecords` 저장(trajectory:254) 후에 10건 기준으로 split 대상만 줄임(261~264) | 환자 선정을 먼저 수행하고 선정 환자와 CDM을 조인해 allrecords 생성 | **확인 완료**. 선정 46,990명과 전체 이력의 환자 범위가 일치하며 선정 밖 기록 없음 |
| trajectory에는 환자 단위의 2일 이상 입원 이력 제한이 없음 | `AdmissionHistory.sql` + `StudyPopulation.sql`: 성인·입원 이력·최소 기록 수를 결합 | **현재 MIMIC 실행 확인**. flow 317,878 → 313,896 → 47,000 → 46,990. 기록 수 기준은 1단계 MedRep식 전처리에 적용한다는 설계를 유지 |
| MIMIC 원본 `patients.csv`·`trace_id`에 의존하는 나이 보정 | OMOP person의 year_of_birth 사용, 표준 CDM에서 SQL로 추출 | **구현·현재 실행 확인**. 현재 CDM의 나이 보정 완료라는 기존 결정에 따름; 타 CDM의 생년 정확성을 검증한 것은 아님 |
| 검사값을 source 문자열에서 숫자로 변환하고 단위를 source 문자열로 묶어 분위 토큰만 남김 | `value_as_number`, `unit_concept_id`를 사용하고 본 출력에 원값·단위를 보존 | **확인 완료**. 수치 검사 41,524,934행의 concept/unit별 건수가 raw FE 추출과 CDM crosswalk에 일치 |
| 단위 미매핑 수치 검사가 원본의 numeric grouping/filter 경로에서 소실 가능 | 998 분석의 `COALESCE(unit_concept_id,0)`, 단위 0도 유지 | **실제 보존 확인**. 최종 전체 이력에 해당 수치 검사 **3,578,574행**. 단, 1단계 선정용 규칙에서는 기존 unit 필터를 유지하며, 이 개선은 4단계 기준 데이터의 동작 |
| 수치·비수치 검사를 명확히 구분하고 이중 추출 방지 | 998 수치 / 999 비수치, 같은 row·concept·day에 998이 있으면 999 제외, 701 동시 사용 차단 | **현재 실행 및 테스트 확인**. 비수치 검사 10,278,054행 보존. 이는 비수치 검사의 존재를 나타내며 value_as_concept_id 등 원본의 모든 필드를 보존한다는 뜻은 아님 |
| 분할을 downstream 추출과 공유하고 pretrain 환자 유입을 방지 | person_split 하나로 분할, downstream_person과 target cohort의 EXISTS 제한 | **확인 완료**. 32,893 / 7,048 / 7,049명, 분할 겹침 0. 전체 allrecords에는 세 그룹이 모두 있으므로 후속 pretraining은 person_split으로 앞의 두 그룹만 선택해야 함 |
| pretraining 이력과 downstream 입력의 추출 규칙 불일치 방지 | 동일한 allrecords/Andromeda에서 rowId·날짜·허용 도메인으로 task input 생성 | **확인 완료**. 세 그룹 총 19,528,780행, 독립 필터 대비 누락·추가 0. no-condition 그룹의 condition 행 0 |
| 원본 labeling의 입원 표 선택이 task마다 별도이며 readmission 경로에서 직전 필터 결과를 다시 덮어씀(labeling:134~137) | PLP의 입원 rowId·population 설정과 TabEHR의 명시적 38개 task 정의 사용 | **현재 정의 기준 확인**. 라벨 315,525행, 38/38 task, 환자·입원·TAR와 실제 DB cohort event 대조 통과. MedRep과 task 정의가 동일하다는 주장은 하지 않음 |
| 파일 순서·분할 입력 순서에 의존하지 않는 재현성 | 선정용 measurement의 datetime/id tie-break, 환자 ID radix 정렬, 명시적 RNG·seed | **코드·테스트 확인**. 원본 sklearn split 자체를 재현하는 요구는 아니며 R의 고정 분할을 공통 사용 |
| 큰 데이터와 별도 저장 장치 지원 | SQL 추출 + Andromeda 스트리밍, output/Andromeda/R temp 설정 | **전체 실행 확인**. 전체 이력 61,296,292행 생성, 산출물·작업 파일은 D 저장 설정으로 실행 |

새 집계 근거: [preprocessing_contract.json](output/code-review-20261024/preprocessing_contract.json).
단위 미매핑 기록 수는 기존 raw covariate 건수와 CDM crosswalk를 다시 대조해 얻었으며,
그 건수 집합이 실제 CSV와 일치한다는 근거는 기존 전체 독립 검증이다. 전체 데이터를
이번에 재추출하거나 MedRep 원본을 새로 실행한 것은 아니다.

### J3. 필수 완료 판정을 막는 사항

1. **실행 상태를 신뢰할 수 있어야 한다(I1~I3).** 캐시 내용·설정 불일치를 검사하고,
   오류는 비정상 종료로 전파하며, 모든 설정 task의 완료/대상 없음/실패와 필수 입력·라벨을
   검증해야 한다. 이는 개선된 전처리 결과를 반복 생성하는 데 필요한 기능이다.
2. **독립 검증이 패키지에 포함되어야 한다.** 이번 전체 산출물 검증에 사용한
   `data/runtime/verify_outputs.py`는 Git 제외 경로이고, `execute()`가 호출하지 않는다.
   따라서 현재 검증 성과를 새 checkout의 기본 기능으로 간주할 수 없다. 검증 로직을
   추적되는 패키지 함수나 공식 실행 스크립트·회귀 테스트로 포함해야 한다.
3. **BIGINT 보존이 모든 조인에 적용되어야 한다(I5).** 파일 출력은 정확하지만 task input
   생성 중 label을 double로 읽는 경로가 남아 있다. 현재 DB의 충돌 0건에 기대지 않고
   문자열 ID로 연결해야 “다른 기관은 설정만 변경” 요구를 충족할 수 있다.
4. **task 정의까지 실행에 고정해야 한다.** `execute()`는 studySettingsFile을 받아 라벨을
   만들지만 `exportRunInfo()`에는 전달하지 않는다. 실제 run_info에는 analysisSettings만
   있고 38개 task의 전체 설정이나 정의 파일 해시가 없다. 부가 PLP/RDS 메타데이터와
   별개로, 실행한 study 설정·cohort SQL 버전을 명시적으로 저장하고 캐시와 연결해야 한다.
5. **지원 범위와 문서를 맞춰야 한다.** 기본 일 단위 흐름은 검증됐지만 2일 이상 간격은
   I4의 오류가 있다. 현재 계약에 맞춰 1일만 허용하는 것도 해결 방법이다. DESCRIPTION의
   “pretraining 환자만으로 분위수 계산”은 현재 원값 중심 주 흐름 및 선택 extras와
   다르므로 수정이 필요하다. SQL Server·외부 기관은 실제 실행 검증을 별도로 해야 한다.

### J4. 이번 목적의 필수 누락으로 세지 않는 항목

- 모델용 tokenizer·embedding·pretraining·finetuning·성능 평가: 후속 작업 범위.
- MedRep 선택 변환의 오류(I6)와 임베딩 선택(G1): 해당 비교 기능을 사용할 때 해결할 사항.
  이것만으로 원값 기반 본 전처리와 38개 task 생성이 미구현이라고 판단하지 않는다.
- 원본과 다른 하루 단위 해상도, 입원 선정 기준, SparseArray task 정의: 확정된 설계.
- observation_period/death의 추가 연구 검토(E): 기존 사용자 결정에 따라 보류.

현재 판정은 **“목표에 맞는 핵심 전처리·task 생성 구현 및 현재 데이터 검증 완료,
독립적 재실행·다기관 재사용을 위한 패키지 완결성은 미완료”**다. 기존 I절의 결함은
여전히 미수정이며 이번 작업은 목적과 요구를 기준으로 한 추가 점검이다.
