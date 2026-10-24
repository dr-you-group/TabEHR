# TabEHR 수정 이력과 데이터·PLP 파이프라인 개선 계획

작성 기준: 2026-10-25. 제1장은 2026-10-24의 기존 이력을 보존한다. 본 패키지의 objective는 다음과 같다.

> pipeline to build the pretraining records and the downstream task inputs and labels for an EHR foundation model from an OMOP CDM.

이 문서는 **이미 적용한 실행 수정 이력**, **공통 데이터 생성 계획**, **PLP를 통한 모델 실행·평가 계획**을 구분한다. 공통 데이터는 tabular 모델과 sequence 모델 모두에 사용할 수 있도록 설계한다. 모델별 tokenization·embedding·학습 알고리즘은 외부 모델 코드가 제공하고, 선택 PLP 모듈은 그 코드를 호출하거나 예측 결과를 받아 동일한 task에서 평가한다. 데이터 생성만 사용하는 경우 Python 모델 설치·학습·평가는 요구하지 않는다.

- **제1장:** 기존 [REVISON.md](REVISON.md)의 1–10절과 본문·코드·검증 기록을 보존한다. 문서 제목을 챕터 제목으로 바꾸고, 하위 제목의 Markdown 수준만 한 단계 낮췄다. 제1장의 “현재”, “이번”, 파일명 `REVISON.md`는 원문 작성 당시의 표현이다.
- **제2장:** [첨부 논문](paper/iclr_2027_TabEHR.pdf), 추가 대화, 현재 코드와 저장된 검증 보고서를 대조한 **data pipeline 중심** 개선 계획이다. 원사건·기본 정보·task input·label·분할·manifest가 범위다.
- **제3장:** GlaucomaPrescreeningPrediction 및 OHDSI PatientLevelPrediction 소스를 참고한 **PLP pipeline 중심** 개선 계획이다. 신규 파일·API, 기존 코드 변경, Python 모델 연결, 학습·외부 검증, 버전·저장 계약과 합격 기준을 정한다. **제2·3장은 구현 제안이며, 현재 구현·실행 검증 완료 상태를 뜻하지 않는다.**

요청한 정확한 파일명 `REVISION.md`로 작성한다. 기존 `REVISON.md`는 별도 원본으로 유지한다. [FUTURE_PLAN.md](FUTURE_PLAN.md)는 선행 계획이며, 제2·3장은 논문 검토와 최신 사용자 결정으로 그 범위를 구체화한다. 현재 38개 task를 유지하고, 논문의 task·환자 수·모델 설정을 재현하는 것을 공통 pipeline의 필수 요구로 삼지 않는다. 기존 `CLAUDE.md`의 모델 실행 제외는 기본 데이터 실행에 적용하며, 사용자가 이번에 요청한 선택 PLP 연결 계획의 작성을 막는 것으로 해석하지 않는다.

## 제1장. TabEHR 실행을 위해 적용한 수정 사항

작성 기준: 2026-10-24. 파일명은 요청한 `REVISON.md`를 사용한다. 이 문서는 패키지 실행 과정에서 적용한 변경과 이유를 정리하며, 산출물의 정의·스키마·사용법은 [OUTPUT_DESCRIPTIOM.md](OUTPUT_DESCRIPTIOM.md)에 설명한다.

### 1. 원본의 범위와 현재 상태

이 문서에서 **원본**은 현재 저장소의 Git 기준점 `024e966` (`revised the README.md`)을 의미한다. 그 이전 커밋은 `bceb292` (`first commit`)이다. MedRep upstream 전체를 원본으로 삼아 설계 차이를 나열하는 문서가 아니다.

수정 사항은 `git diff 024e966 -- <파일>`과 새로 추가된 파일, 실행 로그·검증 보고서를 대조하여 작성했다. 작성 시점에 수정은 작업 트리에 있으며 새 커밋이나 패키지 버전 증가는 하지 않았다. 표시 버전은 TabEHR `0.1.0`, SparseArray `0.0.1` 그대로이므로 **버전 문자열만으로 원본과 수정본을 구분할 수 없다.** 전체 실행에 사용된 소스 SHA-256과 이미지 ID는 [source-state-D.json](output/full-D-validation/source-state-D.json)에 기록되어 있다.

결과적으로 현재 MIMIC 설정에서 전체 전처리와 별도 검증을 완료했다. 다만 일부 복구·검증은 실행 보조 스크립트로 수행했으며, 패키지 자체의 오류 처리·캐시 검증까지 모두 수정한 상태는 아니다. 아래에서 코드 수정, 환경 조치, 미해결 항목을 구분한다.

### 2. DB 연결과 실행 환경 설정 수정

#### 2.1 DBMS 고정값을 환경 변수로 변경

관련 파일: [extras/CodeToRun.R](extras/CodeToRun.R), [.env.example](.env.example), [compose.yaml](compose.yaml).

**왜 수정했는가:** 원래 runner는 `dbms = "sql server"`를 고정했다. 실제 연결 대상은 PostgreSQL이므로, `.env`의 서버·포트만 바꾸어도 드라이버 및 SQL 방언 선택이 맞지 않았다.

**수정 내용:**

```r
dbms = Sys.getenv("SPARSE_ARRAY_DBMS", unset = "sql server")
extraSettings = Sys.getenv("SPARSE_ARRAY_DB_EXTRA_SETTINGS")
```

- `SPARSE_ARRAY_DBMS`로 DBMS를 선택하되 기존 SQL Server 기본값은 유지했다.
- JDBC `extraSettings`를 환경 변수로 전달할 수 있도록 했다. 이번 PostgreSQL 실행의 세션 설정을 코드에 고정하지 않기 위한 변경이다.
- Compose에도 DBMS·추가 연결 설정·JDBC 폴더 변수를 전달하도록 반영했다.

**확인 결과:** PostgreSQL 연결·쿼리·전체 실행을 수행했다. 이것만으로 모든 지원 DBMS의 실행을 검증한 것은 아니다.

#### 2.2 BIGINT를 double로 자동 변환하지 않도록 runner 설정

관련 파일: [extras/CodeToRun.R](extras/CodeToRun.R).

**왜 수정했는가:** MIMIC의 환자 ID에는 양·음수 19자리 BIGINT가 많다. R double은 절댓값이 `2^53`을 넘는 모든 정수를 정확하게 표현할 수 없으므로, 자동 변환이 환자 식별자를 손상할 수 있다.

**수정 내용:** DB 호출 전에 다음 옵션을 설정했다.

```r
options(databaseConnectorInteger64AsNumeric = FALSE)
```

**확인 결과:** `2^53 + 1`, 양·음수 19자리 ID, BIGINT 최댓값의 4개 진단값이 원래 문자열과 일치했다. `TRUE` 옵션에서의 진단은 쿼리 실패로 기록되었으므로 해당 설정의 정상 동작을 확인한 것으로 해석하지 않는다. 원본 코드에 이미 존재하던 SQL의 문자열 ID export와 함께 사용한 조치다.

이는 모든 내부 ID 연산을 문자열로 바꾼 수정은 아니다. `TaskInput`의 PLP 연결에는 double 키와 충돌 방어가 남아 있다. 관련 제한은 9절에 설명한다.

### 3. 전체 이력 출력과 단위 연결 수정

#### 3.1 존재하지 않는 단위 해석 함수 호출 수정

관련 파일: [R/AllRecords.R](R/AllRecords.R), [R/CovariateTokens.R](R/CovariateTokens.R).

**왜 수정했는가:** `.allRecordsCovariateMap()`이 `resolveCovariateUnit()`을 호출했지만 실제 패키지의 함수 이름은 `resolveCovariateId()`였다. 단위 대응 단계가 정상 실행될 수 없는 호출이었다.

**수정 내용:** `AllRecords`의 호출을 기존에 구현된 `resolveCovariateId()`로 교체했다. 단위 해석 알고리즘을 새로 만든 것은 아니다.

**확인 결과:** 주 경로의 수치 측정 단위 대응이 실행되었고, 실제 등장한 수치 covariate 695종 모두에 단위를 대응시켰다. 같은 잘못된 함수명을 쓰는 **선택 기능 `extras/CreateMedRepFiles.R`은 이번에 수정하지 않았다.**

#### 3.2 환자 ID 검사 함수에 잘못 전달한 인수 수정

관련 파일: [R/AllRecords.R](R/AllRecords.R).

**왜 수정했는가:** `.assertCharacterIds()`는 데이터 프레임과 열 이름을 받는데, 기존 코드는 `cohort$personId` 벡터와 `person_id`라는 다른 표기 이름을 넘겼다. 데이터 구조와 함수의 입력 계약이 맞지 않았다.

**수정 내용:**

```r
cohort <- .assertCharacterIds(cohort, "personId")
```

in-memory 객체의 실제 열 이름을 사용하고 반환된 데이터 프레임을 다시 받아 다음 단계에 전달하도록 했다.

#### 3.3 전체 이력 배치의 행 ID 연결 방식 수정

관련 파일: [R/AllRecords.R](R/AllRecords.R), [tests/testthat/test-allRecords.R](tests/testthat/test-allRecords.R).

**왜 수정했는가:** Andromeda에서 읽은 `rowId`와 코호트의 `rowId`가 서로 다른 정수 표현을 가질 수 있었다. 일반 numeric과 `bit64::integer64`를 그대로 혼합하여 연결하면 대응 결과를 신뢰할 수 없다.

**수정 내용:** `.allRecordsBatch()`에서 양쪽 행 번호를 `as.character()`로 바꾼 뒤 `match()`하도록 했다. 원 환자 ID를 계산에 쓰는 것이 아니라, 전체 이력의 연속 행 번호를 안정적으로 연결하는 수정이다.

**확인 결과:** 서로 다른 정수 표현에 대한 회귀 테스트와 전체 기록 출력이 통과했다. 독립 검증에서 출력의 환자 ID가 선정 환자 집합에 속하는지도 확인했다.

#### 3.4 `allrecords_cohort.csv` 열 이름 계약 수정

관련 파일: [R/AllRecords.R](R/AllRecords.R), [R/TaskInput.R](R/TaskInput.R).

**왜 수정했는가:** 전체 이력 코호트는 내부에서 camelCase 열 이름을 사용하지만 후속 `createTaskInput()`은 CSV의 `person_id`를 문자열로 읽는 계약을 갖고 있었다. 파일에 내부 이름을 그대로 내보내면 후속 로더와 맞지 않았다.

**수정 내용:** 메모리 안에서는 `personId`, `indexDate` 등을 유지하고, 저장 직전에 별도 데이터 프레임을 만들어 snake_case로 변환했다.

```text
row_id,person_id,index_date,first_record_date,last_record_date
```

후속 로더는 이 이름으로 읽은 다음 내부에서 camelCase로 변환한다. 환자 ID의 문자열 지정이 실제 CSV 열에 적용되도록 맞춘 것이다.

#### 3.5 단위 참조표의 정수 자료형 불일치 수정

관련 파일: [R/AllRecords.R](R/AllRecords.R), [SparseArray/R/createLongFormat.R](SparseArray/R/createLongFormat.R).

**왜 수정했는가:** 단위 참조 CSV와 Andromeda의 `covariateId` 표현이 달라 연결이 실패하거나 단위가 누락될 수 있었다. 모호한 단위를 처리하기 위해 행을 추가하는 과정에서도 `integer64`와 일반 numeric을 섞을 수 있었다.

**수정 내용:**

- `measurementValueUnitRef.csv`의 `covariateId`를 문자열로 읽는다.
- `AllRecords`는 문자열 키로 `match()`한다. 모호성 검사용 추가 행은 기존 참조 객체에서 가져와 원 ID 자료형을 유지한다.
- `SparseArray::createLongFormat()`은 양쪽에 임시 문자열 키 `.unitJoinKey`를 만들어 조인하고, 조인 후 임시 키를 제거한다. 원래 `covariateId` 열의 자료형은 유지한다.

**확인 결과:** 큰 정수 ID와 모호한 단위 사례의 테스트를 추가했다. 특히 `2^53`을 넘는 인접한 두 covariate ID가 서로 다른 단위에 연결되는지 확인했다. 전체 산출물의 수치 측정 41,524,934행을 단위 참조와 독립 대조하여 누락·추가가 모두 0임을 확인했다.

이 변경은 단위 환산이나 값의 표준화가 아니다. 원 데이터의 단위 ID를 정확히 붙이는 수정이다. 이번에 나타난 미상 단위 `0`은 그대로 보존한다.

### 4. Downstream 입력의 도메인 필터 수정

관련 파일: [R/TaskInput.R](R/TaskInput.R), [tests/testthat/test-taskInput.R](tests/testthat/test-taskInput.R).

**왜 수정했는가:** 최종 task 입력은 모든 도메인이 들어 있는 공통 이력에서 생성된다. 기존 `.writeTaskInput()`은 시간 범위만 제한하고 extraction의 도메인 설정을 적용하지 않아, `admissionNoCondition`에도 진단 기록이 들어갈 수 있었다. 이는 단순 실행 오류보다 중요한 입력 정의의 불일치였다.

**수정 내용:**

- `.taskInputDomains()`를 추가하여 `useConditionOccurrence`, `useDrugExposure`, `useProcedureOccurrence`, `useMeasurementValueUnit`을 실제 도메인 목록으로 변환했다.
- `.writeTaskInput()`에 사용할 도메인을 전달하고, 허용되지 않은 도메인의 covariate를 조인 전에 제외했다.
- 입력 그룹별 설정을 호출부에서 연결했다.

**확인 결과:** 진단 제외와 날짜 범위 처리를 테스트했다. 전체 실행에서 `target1000_admissionNoCondition`은 6,317,950행이며 진단 행은 0이었다. 일반 입원 입력 6,630,399행과의 차이 312,449행은 그 입력에 포함된 진단 행 수와 일치했다.

Task의 outcome 정의나 시간창을 바꾸어서 문제를 우회한 것이 아니라, 이미 존재한 `useConditionOccurrence = FALSE` 설정을 실제 최종 입력에 적용한 수정이다.

### 5. 출력·임시 파일 경로 분리와 D 드라이브 사용 지원

#### 5.1 패키지 함수에 Andromeda 작업 폴더 인수 추가

관련 파일: [R/Main.R](R/Main.R), [extras/CodeToRun.R](extras/CodeToRun.R), [man/execute.Rd](man/execute.Rd).

**왜 수정했는가:** 출력 파일만 D 드라이브에 저장해도 대용량 Andromeda 작업 파일이나 R 임시 파일이 E 드라이브에 남으면 여유 공간 문제가 계속될 수 있었다. 기존 옵션 설정은 환경 변수가 없을 때 빈 경로를 받을 수도 있었다.

**수정 내용:**

- `execute(..., andromedaTempFolder = NULL)` 인수를 추가했다.
- 지정한 폴더를 검사·생성하고 실행 중 `options(andromedaTempFolder = ...)`로 적용한다.
- 실행 종료나 오류 시 이전 옵션을 복원한다.
- 기존 logger 정리용 `on.exit()`에 `add = TRUE`를 붙여, 앞서 등록한 옵션 복원 동작을 덮어쓰지 않게 했다.
- runner에서 `TABEHR_ANDROMEDA_TEMP_FOLDER` → 기존 `SPARSE_ARRAY_ANDROMEDA_TEMP_FOLDER` → `tempdir()/andromeda` 순의 대체값을 사용한다.

**확인 결과:** 작업 폴더 생성·옵션 적용·오류 시 복원 테스트가 통과했다. 현재 D 드라이브 경로에서 전체 처리를 완료했다.

원래도 `outputFolder` 인수와 `TABEHR_OUTPUT_FOLDER`는 있었다. 출력 경로 지정 기능 전체를 새로 만든 것으로 표현하지 않는다. 이번 수정은 **저장 볼륨·Andromeda 임시 공간·R 임시 공간을 분리하고 명시적으로 설정할 수 있도록 확장한 것**이다.

#### 5.2 Compose의 별도 저장 볼륨과 쓰기 권한

관련 파일: [compose.yaml](compose.yaml), [.env.example](.env.example), [README.md](README.md).

**수정 내용과 이유:**

| 변경 | 이유 |
| --- | --- |
| `${TABEHR_STORAGE_HOST_FOLDER:-./data/storage}:/home/rstudio/storage` 마운트 | 코드가 있는 디스크와 대용량 출력 디스크를 분리 |
| 출력·Andromeda·R 임시 경로를 각각 전달 | 최종 파일만 옮기고 중간 파일은 작은 디스크에 남는 상황 방지 |
| R 시작 전에 `TMPDIR` 지정 | 이미 시작한 R의 `tempdir()`는 나중 환경 변수 변경만으로 바뀌지 않기 때문 |
| 시작 명령에서 폴더 생성 및 UID/GID에 맞춘 소유권 설정 | RStudio 사용자 계정이 마운트된 출력·임시 디렉터리에 쓸 수 있도록 설정 |
| `.env.example`와 README에 호스트/컨테이너 경로 구분 | Windows D 경로와 컨테이너 내부 경로를 혼동하지 않도록 문서화 |

현재 호스트 저장소는 `D:/TabEHR-storage/files`이며, 코드의 E 드라이브 마운트와 별개다. 이 설정은 PostgreSQL 서버의 데이터 디렉터리까지 자동 이동시키지는 않는다.

#### 5.3 실행 메타데이터에 실제 저장 위치 기록

관련 파일: [R/Export.R](R/Export.R).

**왜 수정했는가:** 환경 변수만으로 저장 위치를 추정하면 실행 당시 실제 적용된 경로를 확정하기 어렵다.

**수정 내용:** `run_info.json`에 `storage.outputFolder`, `storage.andromedaTempFolder`, `storage.rTempFolder`를 추가했다. 출력 폴더는 정규화한 경로, R 임시 폴더는 실제 `tempdir()`를 기록한다.

**확인 결과:** [run_info.json](output/full-D-validation/run_info.json)에 세 경로가 `/home/rstudio/storage/` 아래로 기록되어 있다. Task 설정 전체 snapshot/hash를 추가한 변경은 아니며, 해당 재현성 항목은 아직 남아 있다.

### 6. 진단·시험 추출·컨테이너 보조 수정

#### 6.1 진단표의 integer64 표시 수정

관련 파일: [R/Diagnostics.R](R/Diagnostics.R), [tests/testthat/test-export.R](tests/testthat/test-export.R).

**왜 수정했는가:** `.asMetricTable()`에서 행을 `unlist()`한 뒤 문자열로 바꾸면 `integer64`의 클래스가 사라져 큰 정수 값이 잘못 표시될 수 있었다.

**수정 내용:** 각 열의 첫 값을 원래 클래스 상태에서 `as.character()`로 변환하고 `vapply()`로 모으도록 바꾸었다. DB 데이터 자체를 수정한 것은 아니며, 진단 결과의 표시를 바로잡은 것이다.

#### 6.2 선택적 분위수 산출물을 필수 진단에서 제외

관련 파일: [R/Diagnostics.R](R/Diagnostics.R).

**왜 수정했는가:** 현재 기본 `execute()`는 원 수치를 보존하는 전체 이력·task 입력 경로이며 분위수 표를 만들지 않는다. 그런데 진단은 `measQuantiles` 테이블과 `meas_quantiles.csv`를 필수로 보아, 정상적인 주 경로에도 불필요한 실패를 표시했다.

**수정 내용:** 분위수 테이블을 필수 테이블 목록에서 제외하고, 존재할 때만 관련 검사를 수행한다. 분위수 CSV도 선택적 파일로 분류했다.

이것은 **진단의 모든 부족한 점을 해결한 수정이 아니다.** 주 산출물과 task 누락의 필수 검사, `FAILED` 시 실행 실패 전파는 여전히 미해결이다.

#### 6.3 시험 추출용 환자 테이블에 기본 키 추가

관련 파일: [CreatePersonSample.sql](inst/sql/sql_server/CreatePersonSample.sql).

**왜 수정했는가:** 1,000명 시험 추출은 큰 CDM 테이블과 표본 환자 집합을 대조한다. 표본 테이블의 환자 ID에 고유성·인덱스가 없어 비효율적인 실행 계획을 선택할 여지가 있었다.

**수정 내용:** `person_id BIGINT NOT NULL`에 `PRIMARY KEY`를 추가했다. 환자 고유성을 보장하고 인덱스를 제공하는 변경이다. 같은 실행에서 PostgreSQL 세션 설정도 조정했으므로, 관찰된 실행 속도 개선을 기본 키 한 가지 효과로 단정하지 않는다.

#### 6.4 RStudio 바인딩과 상태 확인

관련 파일: [compose.yaml](compose.yaml).

**수정 내용:**

- 포트 표현을 `48788:8787`에서 `0.0.0.0:48788:8787`로 명시했다.
- Rscript로 컨테이너 내부의 `/auth-sign-in`에 접근하는 healthcheck를 추가했다. HTTP 연결 실패 시 상태 1로 끝내도록 했다.

기존 Docker 포트 축약형도 일반적으로 전체 인터페이스에 바인딩된다. 따라서 이전 설정이 localhost 전용이었다고 설명하지 않는다. 이번 변경은 요청한 외부 접근 바인딩을 명시하고, 서비스가 실제 응답하는지 확인 가능하게 만든 것이다.

서버의 실제 배포·방화벽 설정은 7절의 운영 조치다. [rstudio-access-final.json](output/full-D-validation/rstudio-access-final.json)에는 2026-10-24 17:47:52 KST 기준 HTTP 200과 로그인 화면 응답 확인이 기록되어 있다. 이 문서를 작성하면서 전처리를 새로 실행한 것은 아니다.

#### 6.5 빌드 컨텍스트, 의존성·문서 정리

| 파일 | 변경 및 이유 |
| --- | --- |
| [.dockerignore](.dockerignore) | 새로 추가. `.env`, `.Renviron`, `.git`, 출력·데이터·JDBC 폴더, 로그 등을 Docker 빌드 컨텍스트에서 제외하여 불필요한 대용량 파일·로컬 설정이 이미지에 복사되지 않게 함. |
| [DESCRIPTION](DESCRIPTION), [SparseArray/DESCRIPTION](SparseArray/DESCRIPTION) | `bit64`를 Suggests에 추가. 큰 정수 자료형 회귀 테스트의 의존성을 명시. |
| [man/execute.Rd](man/execute.Rd) | 실제 `execute()` 인수·단계에 맞춰 문서 갱신. 새 임시 폴더 인수와 기존에 변경되어 있던 task 입력 흐름을 반영. |
| [README.md](README.md) | 저장 경로, 임시 공간, 단위 연결 관련 사용 설명 갱신. |
| [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) | 실제 DB 확인 결과·전체 실행 결과·미해결 코드 검토 항목 기록. 문서 기록 자체가 기능 수정은 아님. |

기존 `DockerImage/Dockerfile`에는 이번 실행 수정에 해당하는 Git 차이가 없다. 과거에 이미 반영된 PLP 설치 수정 등을 이번에 새로 고쳤다고 포함하지 않는다.

### 7. 소스 수정과 별도로 수행한 운영 조치

다음은 이번 서버에서 실행을 완료하기 위한 설정·복구 절차다. 패키지의 일반 기능으로 구현되어 있다고 해석하면 안 된다. `data/runtime/`는 Git 추적에서 제외된 실행 보조 디렉터리다.

#### 7.1 환경 변수와 JDBC 준비

- 요청에 따라 형제 프로젝트 `../sparse_array_v3/.env`의 연결 환경을 사용했다. 비밀번호 값은 이 문서에 기록하지 않는다.
- JDBC 드라이버는 형제 디렉터리를 계속 참조하는 대신 프로젝트의 `jdbc/postgresql-42.7.13.jar`로 복사했다.
- 컨테이너에서의 경로는 `/home/rstudio/tabehr/jdbc/postgresql-42.7.13.jar`다.
- 드라이버 SHA-256: `6e0e4cc2d8cae902084f8a2b18728b073a6fd9d1f87c9d8bff8f298c18185b93`.

#### 7.2 실제 Windows Docker 호스트와 RStudio 연결

- `10.19.10.241`의 Docker 호스트에 `tabehr-rstudio`를 실행하고 `0.0.0.0:48788 -> 8787`을 사용했다.
- Windows 방화벽 규칙 `TabEHR-RStudio-TCP-48788`을 적용했다.
- 코드 E 마운트와 데이터 D 마운트를 분리했다. 이전 중첩 Docker 환경의 같은 이름 컨테이너·이전 접근 경로는 정리하여 실제 Windows 호스트의 서비스를 사용했다.
- 로그인 화면 응답과 RStudio 사용자의 파일 쓰기를 확인했다. 최종 URL은 `http://10.19.10.241:48788`이다.

#### 7.3 PostgreSQL 작업 공간을 D 드라이브로 이동

R 출력 위치 변경만으로 DB 내부의 테이블·정렬 작업 공간은 옮겨지지 않기 때문에 별도로 처리했다.

- `D:\TabEHR-storage\postgresql`에 PostgreSQL용 tablespace `tabehr_d`를 준비하고 서비스 계정의 접근 권한을 설정했다.
- 프로젝트 작업 세션에서 `default_tablespace`와 `temp_tablespaces`를 사용하도록 설정했다.
- 실행 계획·메모리 관련 세션 설정으로 `enable_nestloop = off`, `work_mem = 128MB`를 사용했다. 현재 데이터와 서버를 위한 운영 조정이며 모든 DB에 공통 적용할 기본 알고리즘으로 추가하지 않았다.
- 최종적으로 프로젝트의 10개 작업 테이블이 D tablespace에 있는지 확인했다: `tabehr_records`, `tabehr_measurements`, `tabehr_concept_unit`, `tabehr_record_counts`, `tabehr_admission_history`, `tabehr_study_population`, `tabehr_person_split`, `tabehr_downstream_person`, `tabehr_allrecords_cohort`, `tabehr_cohort_v3`.

원 CDM 전체와 PostgreSQL WAL까지 D 드라이브로 옮긴 것은 아니다. 근거는 [storage-D-final.json](output/full-D-validation/storage-D-final.json)과 [source-state-D.json](output/full-D-validation/source-state-D.json)이다.

#### 7.4 완료된 측정 처리를 유지하고 단계별 재개

E 드라이브 공간 문제 이후 완료된 수치 측정 185,869,003행을 보존하고 필요한 나머지 단계부터 재개했다. 비수치 측정은 최종 36,780,281행까지 처리했다. 이 숫자는 환자 선정용 1단계 중간 테이블의 행 수이며, 최종 `allrecords`의 수치·비수치 건수와는 다르다.

단위 연결 수정 적용 과정에서는 진행 중인 후속 집계를 통제하여 중단한 뒤, 보존된 중간 결과에서 다시 진행했다. 관련 보조 스크립트는 `data/runtime/Resume-full-D.R`, `data/runtime/Continue-full-D.R`이다. 자동 checkpoint·자동 복구 엔진을 패키지에 구현한 것은 아니다.

#### 7.5 오류 종료 코드 보조 래퍼와 별도 검증

현재 logger 조합에서는 R 오류가 표시되어도 기본 실행의 프로세스 종료 코드가 0이 되는 문제가 재현되었다. 전체 실행 재개에는 `data/runtime/Run-Continue-full-D.R`의 명시적 오류 래퍼를 사용했다.

```r
tryCatch(
  source("data/runtime/Continue-full-D.R"),
  error = function(e) {
    message(conditionMessage(e))
    quit(status = 1)
  }
)
```

이는 이번 실행을 위한 보조 조치이며, 공식 `extras/CodeToRun.R`과 `execute()`의 오류 전파를 모두 수정한 것은 아니다.

기본 진단만으로 완료를 선언하지 않고, `data/runtime/verify_outputs.py`와 DB 이벤트·covariate 집계 export를 이용하여 별도 대조했다. 원본 데이터가 포함된 대용량 출력은 D에 유지하고, 집계 검증 보고서를 `output/full-D-validation/`에 복사했다. 이 검증 도구도 현재 패키지의 정식 자동 검사로 통합되어 있지는 않다.

### 8. 수정에 대한 검증 결과

#### 8.1 추가·보강한 회귀 테스트

| 파일 | 검증 내용 |
| --- | --- |
| [test-allRecords.R](tests/testthat/test-allRecords.R) | 올바른 resolver 호출, 행 ID 연결, 큰 정수 covariate·단위 대응, 모호한 단위 처리 |
| [test-taskInput.R](tests/testthat/test-taskInput.R) | 도메인 필터, 진단 제외, 시간 범위·미래 기록 제외, ID 대응 |
| [test-storage.R](tests/testthat/test-storage.R) | 작업 폴더 생성, 옵션 적용, 오류 시 기존 옵션 복원 |
| [test-export.R](tests/testthat/test-export.R) | 진단 지표에서 integer64 값 보존 |
| [SparseArray test-createLongFormat.R](SparseArray/tests/testthat/test-createLongFormat.R) | 큰 정수 covariate ID와 단위 조인 |
| [helper-load.R](tests/testthat/helper-load.R) | 새 테스트가 `TaskInput`·`Main` 구현을 읽도록 보완 |

2026-10-24 실제 RStudio 실행 컨테이너에서 확인한 결과는 다음과 같다. 문서 작성 때문에 같은 전체 전처리를 다시 실행하지 않았다.

| 검사 | 결과 | 근거 |
| --- | --- | --- |
| TabEHR 테스트 | 56개 테스트, 173 assertions 통과 | [TabEHR-tests.csv](output/code-review-20261024/TabEHR-tests.csv) |
| SparseArray 테스트 | 21개 테스트, 80 assertions 통과 | [SparseArray-tests.csv](output/code-review-20261024/SparseArray-tests.csv) |
| 테스트 합계 | 77개 테스트, 253 assertions. 실패·오류·skip·warning 0 | 위 두 결과 |
| SQL 호출 인수 검사 | 30/30 call sites 통과 | [sql-parameters.log](output/sql-parameters.log) |
| PostgreSQL SQL 렌더링 검사 | 32/32 통과 | [sql-rendering-postgresql.log](output/sql-rendering-postgresql.log) |

SQL 렌더링 통과는 해당 검사에서 SQL 매개변수·변환을 확인했다는 뜻으로, 모든 DBMS에서 실행을 검증했다는 뜻은 아니다. 테스트 warning 0과 별개로 전체 실행 로그에는 사용하지 않은 SQL 매개변수 등의 경고가 있으므로 실행 전체에 경고가 전혀 없었다고 표현하지 않는다.

#### 8.2 전체 데이터 실행 및 독립 대조

완료 시점: **2026-10-24 17:47:52 KST**. 처리·독립 검증 종료 코드 모두 0.

| 확인 항목 | 결과 |
| --- | --- |
| 선정 환자 | 46,990명 |
| 사전학습 train / valid / downstream | 32,893 / 7,048 / 7,049명, 중복 0 |
| 전체 이력 출력 | 61,296,292행 |
| Task 레이블 | 38/38 task, 315,525행 |
| 일반 입원 입력 | 6,630,399행 |
| 진단 제외 입원 입력 | 6,317,950행, 진단 0행 |
| 퇴원 입력 | 6,580,431행 |
| 입력과 공통 이력 대조 | 3그룹 모두 누락·추가 0 |
| 수치 측정 단위 대조 | 예상 41,524,934행과 일치 |
| 레이블 대조 | 실제 DB outcome cohort event와 환자·기간·정답 대조 통과 |

근거: [completion_summary.json](output/full-D-validation/completion_summary.json), [execution_validation.json](output/full-D-validation/execution_validation.json), [preprocessing_contract.json](output/code-review-20261024/preprocessing_contract.json).

입력이 없는 레이블 행은 일반 입원 6개, 진단 제외 입원 155개, 퇴원 2개다. 허용된 날짜·도메인에 입력 기록이 없는 경우이며, 이를 누락된 출력으로 간주해 임의로 기록을 채우지 않았다. 후속 학습에서 처리 방식을 명시해야 한다.

### 9. 발견했지만 아직 수정하지 않은 항목

다음은 완료된 수정 목록에 포함하지 않는다. [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md)의 I·J, [edge_cases.json](output/code-review-20261024/edge_cases.json), [diagnostic_coverage.json](output/code-review-20261024/diagnostic_coverage.json)에 근거가 있다.

| 항목 | 현재 문제와 영향 | 이번 실행에서의 구분 |
| --- | --- | --- |
| 캐시 무결성·설정 일치 | 파일·폴더 존재만으로 추출을 재사용하며, 빈 PLP 폴더도 재사용되는 사례가 있음. 설정을 바꿔도 과거 결과가 쓰일 수 있음. | 이번 결과는 별도 대조했지만 일반 캐시 검증은 미수정. |
| 오류 종료 코드 | 기본 logger/runner 조합에서 오류가 출력되어도 Rscript가 0으로 끝나는 사례 재현. | 전체 재개에는 명시적 `tryCatch` 래퍼 사용. 공식 경로의 근본 수정은 미완료. |
| 진단의 검사 범위·실패 전파 | 주 산출물이나 다수 task가 없어도 일부 진단이 OK로 끝남. `FAILED`가 있어도 `execute()`가 정상 반환할 수 있음. | 이번에는 독립 검증으로 38 task와 실제 파일을 모두 확인. |
| `timeInterval > 1` | 설정은 허용하지만 날짜 복원은 `indexDate - timeId`로 1일 단위에 고정. 간격 2, `timeId = 1` 사례에서 날짜가 하루 어긋남. | 이번 설정은 1일이며 해당 경계 오류는 사용하지 않음. |
| PLP 연결의 double ID | 서로 다른 정확한 환자 ID가 같은 double로 반올림되면 중단. 완전한 문자열 조인으로 일반화되지 않음. | 현재 DB의 충돌 그룹은 0이고 실제 ID 대응은 대조 통과. |
| 선택 MedRep 변환 | `extras/CreateMedRepFiles.R`에 존재하지 않는 `resolveCovariateUnit()` 호출이 남음. | 기본 task 출력에는 사용하지 않았고 MedRep 산출물을 만들지 않음. |
| Task 설정의 실행 provenance | `run_info.json`에 `studySettings.json` 전체 snapshot/hash가 없음. | 현재 설정과 실행 보고서를 함께 보존했지만 정식 기록 기능은 미완료. |
| 문서·부가 출력 정합성 | DESCRIPTION의 분위수 중심 설명 등 일부 과거 표현이 남음. Outcome 이름표 기본 경로도 TabEHR 쪽을 보므로 `outcomeName`이 ID로 출력됨. | 이번 문서는 실제 동작을 명시. 이름표 경로·기존 설명의 일괄 수정은 하지 않음. |

또한 최종 입력은 기준일 **당일**까지 포함하고 측정 시각을 보존하지 않는다. 입력의 observation period 경계와 레이블의 경계 계산에도 차이가 있다. 이는 산출물의 정의 및 활용 시 확인할 내용으로 [OUTPUT_DESCRIPTIOM.md](OUTPUT_DESCRIPTIOM.md)에 상세히 설명했다. 이 문서 작성 작업에서 그 정의를 새로 변경하지 않았다.

### 10. 이번 수정으로 주장할 수 있는 범위

현재 MIMIC 데이터와 1일 단위 기본 task 설정에서는 위 수정·환경 조치·단계별 재개를 거쳐 **환자 선정, 전체 이력, 38개 task의 입력·레이블 생성 및 독립 검증을 완료했다.**

반면 모든 환경에서 중단 없이 실행되는 범용 패키지, 설정 변경에 안전한 자동 재실행, 기본 종료 코드만으로 판정 가능한 완전한 운영 체계까지 완성했다고 볼 수는 없다. 미해결 항목은 9절처럼 별도로 남겨두었다.

원본 Git 기준에 이미 있던 task 정의, 환자 분할 알고리즘, 수치·비수치 측정용 998/999 분석, 공통 이력에서 task 입력을 만드는 설계, 코호트 SQL 및 MedRep 비교 경로는 이번 실행 중 새로 만든 개선으로 계산하지 않았다. 실제 수정의 주된 목적은 **연결·자료형·파일 계약 오류를 고치고, 기존 입력 도메인 설정을 적용하며, 저장 공간과 실행 확인을 가능하게 하는 것**이었다.

## 제2장. 공통 data pipeline 개선 계획

### 2.1 목적, 유지할 연구 정의와 구현 경계

이 장의 목표는 특정 논문의 실험을 복제하는 것이 아니라, OMOP CDM에서 **pretraining records, downstream task inputs, downstream labels**를 생성하는 공통 pipeline을 구체화하는 것이다. TabEHR 논문은 공통 기록에 어떤 정보가 남아 있어야 하는지 확인하는 사용 사례로 검토한다. 같은 출력으로 MedRep 같은 sequence 모델이나 통계 특징 기반 tabular 모델도 입력을 구성할 수 있어야 한다.

| 구분 | 공통 data pipeline이 책임질 내용 | 모델 코드 및 선택 PLP 모듈로 넘길 내용 |
| --- | --- | --- |
| Pretraining records | 선정 환자의 사건 기록, 환자 정보, split 및 사용 가능한 환자 집합의 명시 | 사전학습 샘플·mask 구성, tokenization, objective와 학습 |
| Downstream inputs | 환자·예측 instance, 선언된 입력 구간의 사건, 기본 정보, 입력이 없는 instance의 상태 | 집계 특징, token budget, 모델별 tensor와 batch 구성 |
| Downstream labels | 등록된 task의 대상자·정답·판정 기간·attrition·설정 버전 | 모델별 label encoding·support/query·loss; 제3장의 예측 연결·평가 |
| 데이터 품질·재현성 | 정확한 ID, 필드·시간 의미, 원본과의 대조, split 검사, 캐시·실패 상태·manifest | 모델 artifact·학습 설정·예측 provenance와 제3장의 성능 검증 |

현재 기본 연구 정의는 유지한다.

- `studySettings.json`의 **38개 task**: 사망 2개, 장기 재원 1개, 재입원 1개, phenotype 27개, 신규 진단 7개를 기본값으로 유지한다. 논문의 9개 task·24개 phenotype으로 교체하지 않는다.
- 현재 task의 직접 구현 출처는 SparseArray이며, [CLAUDE.md](CLAUDE.md)에 해당 정의를 사용하도록 명시되어 있다. 사용자가 설명한 EHRSHOT 기반 재설계의 세부 대응은 별도 provenance로 확인할 대상이다. 공식 EHRSHOT과 완전히 동일한 task라고 표시하지 않는다.
- 현재의 환자 선정 기준과 70:15:15 분할을 기본값으로 유지한다. 새 사건 출력의 행 수가 늘었다는 이유로 선정용 1단계의 최소 기록 수 기준을 바꾸거나 재분할하지 않는다.
- 논문의 환자 수, downstream 60/20/20 비율, anchor 수, token 수를 패키지 전역 기본값으로 강제하지 않는다.
- 새 task 정의·시간 정책·환자 선정 변경이 필요하면 별도 설정과 버전으로 등록한다. 현재 task와의 차이는 연구 설계 차이로 기록한다.

`plpData`는 필요한 PLP 처리 및 선택 feature export에 계속 사용할 수 있다. **PLP 객체는 short/long-term covariate만 허용하는 형식이 아니며, 사용자 정의 min/max/mean·embedding도 담을 수 있다.** 공통 원사건을 제공하는 이유는 모델마다 다른 집계·시간 표현을 선택할 수 있도록 정보를 보존하기 위해서다. 제2장은 그 정보와 연결 계약을 제공하고, PLP feature 변환·Python 호출·예측 평가의 구현은 제3장에 둔다.

### 2.2 제공된 추가 대화에 대한 검토 결과

| 추가 대화의 주장 | 검토 결과 및 이 계획의 반영 |
| --- | --- |
| Python tokenizer만 추가하면 충분하지 않다 | 동의. 현재 날짜별 축약에서 없어진 기록·값·시각을 후단에서 복구할 수 없으므로 추출 단계부터 수정한다. |
| TabEHR의 concept embedding, anchor 구성, 환자 예측 학습은 서로 다른 단계다 | 동의. 공통 pipeline은 임상 기록·환자·task·label을 제공한다. LLM 설명문 생성, MLM/contrastive 학습, anchor clustering, aggregator 학습은 필수 구현에 포함하지 않는다. |
| 환자 예측용 task를 논문 정의에 맞춰야 한다 | 현재 사용자 목적에 맞춰 조정한다. **현재 38개 task로 새로운 TabEHR 실험을 수행할 수 있으며, 논문 task 재현은 필수 요구가 아니다.** |
| PLP population RDS의 age·gender를 export하면 된다 | downstream 일부 instance에는 활용할 수 있으나 전체 pretraining 환자 정보로는 부족하다. OMOP `person`에서 전체 선정 환자 정보를 export하고, 기준 시점별 age를 계산하는 경로가 필요하다. |
| downstream 내부 train/valid/test를 추가해야 한다 | 논문 비율을 강제하지 않고, 외부에서 정한 환자별 분할을 import·검증하는 인터페이스를 우선 제공한다. 분할 생성은 명시적으로 선택하는 공통 기능으로 확장 가능하다. |
| 일별 count·last·min·max를 보존하는 대안이 있다 | 특정 후처리에는 가능하지만 일중 cutoff나 다른 통계 요구를 모두 지원하지 못한다. **기준 데이터는 원사건**, 일별 요약은 선택 파생 출력으로 둔다. |
| 46,990명·61,296,292행·38개 task 검증이 있다 | 현재 정의의 실행·산출물 검증 근거다. 사건 단위 v2, TabEHR 연결, 다른 DBMS 또는 모델 학습의 검증 완료로 확대하지 않는다. |

### 2.3 논문에서 확인한 데이터 요구와 책임의 연결

근거 논문은 [paper/iclr_2027_TabEHR.pdf](paper/iclr_2027_TabEHR.pdf)이다. 아래 페이지는 PDF에 인쇄된 페이지 번호다.

| 논문 근거 | 확인한 요구 | 공통 pipeline에 반영할 내용 |
| --- | --- | --- |
| §3.1, p.3 | 한 instance는 환자와 예측 시점의 조합이며 정적 변수와 과거 기록을 사용 | `sample_id`, 정확한 `person_id`, prediction time, 입력 구간, 기본 정보를 연결 |
| §3.3, pp.5–6; Appendix E.1, p.28 | concept·시간 bin별 count, 마지막 비결측값, min/max, 최근 기록 시각 | 이를 계산할 수 있도록 원사건·값·단위·시각을 보존. bin 생성 자체는 후단 처리 |
| §3.3, pp.5–6 | source training 통계로 수치값 표준화, recency·domain 사용 | 원값·단위·시간·도메인과 학습 집합 정보를 제공. 특정 정규화를 공통 기록에 강제하지 않음 |
| Appendix C.1, p.21 | 정적 입력은 age·sex | 선정 환자 전체의 birth 정보·gender concept과 instance 기준 age 제공 |
| Appendix C.2, p.21 | label 없는 anchor 구성 pool과 downstream 학습 환자가 분리됨 | 역할별 환자 membership을 검증하고 export. 전체 `allrecords`를 자동 pretraining 집합으로 취급하지 않음 |
| Appendix C.4, p.24 | recorded timestamp가 prediction timestamp보다 엄격히 이전 | 날짜 기준 기존 정책과 timestamp 기준 정책을 구분하여 선언·검증 |
| Appendix F.3–F.5, pp.31–33 | 소급 입력된 진단·청구 기록의 가용성 판단에 record type·encounter 정보가 필요 | 원본 메타데이터 보존 및 선택적인 availability 정책 지원 |
| Appendix E.5, p.30 | 값과 단위가 따로 선택되면 동일시각 중복 처리에서 값이 달라질 수 있음 | 값·단위를 같은 원사건에서 전달하고, 변환·집계 순서와 동률 처리를 기록 |

논문의 주요 aggregator는 label이 있는 downstream training episode로 학습되며, 임상 pretraining 집합은 anchor 구성 통계와 sequence baseline 등에 사용된다. 따라서 패키지는 **어떤 환자·기록 집합을 어떤 역할로 제공했는지**를 명확히 하고, 세 단계의 학습 데이터가 모두 준비되었다고 표시하지 않는다.

### 2.4 개선안 R1 — 사건 단위 공통 기록을 새 기준 데이터로 제공

**문제와 이유:** 현재 `MeasurementValueUnit.sql`은 `(cohort row, measurement concept, 시간 구간)`에서 한 숫자값을 고른다. 정렬 기준은 `measurement_date DESC → unit_concept_id → value_as_number`이므로 실제 시각상 마지막 측정이 보장되지 않는다. 원본 오전 100·오후 200이 100 한 건으로 남으면 후단에서 last 200, max 200, count 2를 재구성할 수 없다.

**제안하는 코드 수정:**

1. 신규 `R/CanonicalRecords.R::extractCanonicalRecords()`와 4개 `ExtractCanonical*.sql`을 추가한다. 선정 환자와 CDM을 직접 조인하여 원본 PK별 사건을 읽는다. 사건 경로에는 날짜별 `DISTINCT`, `rn = 1`, 숫자값 우선 anti-join을 적용하지 않는다.
2. `R/AllRecords.R::createAllRecords()`는 `legacy_daily`와 `events` 모드를 명시적으로 선택하게 한다. 현재 FE/998·999 경로를 기존 출력 재현용으로 유지하고, v2 사건 경로를 분리한다.
3. `R/TaskInput.R`의 v2 입력은 새 사건 저장소에서 만든다. 기존 `allRecordsCovariates.zip`을 v2 원사건 cache로 재사용하지 않는다.
4. 같은 환자·concept·날짜·시각·값이라도 서로 다른 유효 source PK이면 기본적으로 유지한다. source PK 자체의 중복은 별도 정합성 오류로 보고한다. 임상적 중복 제거가 필요한 경우 별도 규칙과 제외 건수를 기록한다.
5. CSV/gzip shard로 스트리밍하며 R 메모리에 전체 자료를 올리지 않는다. 초기 작업 저장소는 현재 환경의 Andromeda/SQLite를 활용하되, ID를 TEXT로 저장하는 별도 `events` 스키마와 인덱스를 검증한다. 큰 자료의 task join은 이 저장소에서 수행한다.

**최소 사건 필드:** `record_id`, `person_id`, `domain`, `concept_id`, `record_date`, `record_datetime`, `time_precision`, `value_as_number`, `value_as_concept_id`, `unit_concept_id`. 도메인은 현재와 같이 원본 CDM 테이블에서 가져온다. `record_id`는 database/run namespace 내에서 source table·원본 PK와 연결되는 정확한 문자열 키로 정의한다.

도메인별 시각은 `condition_start_datetime`, `drug_exposure_start_datetime`, `procedure_datetime`, `measurement_datetime`에서 가져오고 대응 date 필드도 보존한다. 선정용 1단계의 시간당 축약·단위 필터·최소 빈도 규칙을 사건 출력에 다시 적용하지 않는다. 기존 concept 0 제외 기본값과 명시적인 source 날짜 범위는 설정·제외 건수로 기록한다. “원사건 보존”은 이 선언된 범위 안의 보존이며 OMOP 전체를 복제한다는 뜻이 아니다. CDM은 읽기만 하고 작업 테이블은 cohort schema 및 run별 작업 공간에 만든다.

측정의 `operator_concept_id`, 참고 범위, source value 등 가용한 원본 필드도 schema에 명시하여 보존한다. 숫자 0·NULL, unit 0·NULL, 범주 concept 0·NULL을 임의로 동일하게 바꾸지 않는다. 지원 컬럼의 부재는 capability manifest에 기록하고 필수 컬럼의 부재는 시작 전에 실패시킨다.

**합격 기준:** 동일 source 범위에서 원본 PK별 사건·값·단위의 전달이 일치해야 한다. 도메인별 원본 건수는 선택·명시적 제외·오류 건수와 대조하며, source PK가 다른 반복 측정의 누락이 없어야 한다. 원사건 v2의 행 수가 기존 61,296,292행과 달라지는 것 자체는 오류가 아니다.

### 2.5 개선안 R2 — 수치·범주·단위를 결합한 상태로 보존

**문제와 이유:** 현재 공통 출력에는 `value_as_concept_id`가 없으며, 숫자값과 범주값이 함께 있거나 같은 날 서로 다른 결과가 있는 경우를 온전히 표현하지 못한다. 저장된 [범주형 감사](output/categorical-audit-20261024/categorical_loss_report.json)에서는 범주 원본과 연결되는 일 단위 key 619,481개 중 252,056개가 숫자값도 빈 상태였고, 해당 빈 값 손실을 가진 환자는 31,870/46,990명이었다. 이는 원본 범주 concept이 nonzero인 범위의 감사이며 전체 결측률은 아니다.

**제안하는 코드 수정:**

- measurement 한 원사건의 숫자값·개념값·단위·operator·시각을 하나의 행으로 전달한다. `numeric`, `categorical`, `both`, `none`, `source_only` 같은 파생 상태는 원본 필드를 대체하지 않는다.
- 범주 결과와 숫자 결과가 동시에 존재하면 둘 다 유지한다. 취소, 명시적 음성, 미매핑 텍스트, 값 없음도 구분 가능하게 보존한다. absence를 자동으로 0 또는 negative로 바꾸지 않는다.
- 단위를 `unit % 1000` 같은 잔차 키로 해석하지 않는다. 서로 다른 단위의 숫자를 먼저 합친 뒤 대표 단위 하나를 붙이는 처리를 금지한다.
- 원본 추출은 값을 임의로 정규화·clipping·binning하지 않는다. 후속 변환은 단위별 변환 규칙과 version을 갖고, 원본 값과 단위를 같은 행에서 함께 해석·변환한 다음 집계한다. 알 수 없는 단위는 명시적인 unknown 정책을 따른다.
- 같은 시각에 여러 수치가 있어 last를 고를 때는 실제 순서가 확인되는지 구분한다. source PK를 결정적 tie-break로 사용할 수 있으나 그것이 임상적 측정 순서라는 주장은 하지 않는다.

**선택 일별 요약의 최소 계약:** `record_count`, `numeric_count`, `last_nonmissing_value`, `min_value`, `max_value`, `last_record_datetime`, `last_nonmissing_datetime`, 단위/변환 규칙을 제공한다. 최근 사건의 시각과 최근 비결측값의 시각은 다를 수 있다. 이 요약은 해당 통계에 한정된 파생 출력이며 원사건을 대체하지 않는다.

TabEHR 논문이 명시하는 주 value channel은 수치 기반이다. 범주값을 공통 데이터에 보존하는 것과 특정 TabEHR 구현이 그 범주값을 자동으로 이용하는 것은 별개다. 범주 token/embedding의 정의는 모델별 adapter에서 정한다.

### 2.6 개선안 R3 — 예측 시점과 기록 가용성의 명시적 계약

**문제와 이유:** 현재 `record_date`와 일 단위 `time_id`만으로는 임의의 일중 cutoff를 복원할 수 없다. 또한 입원 시점으로 소급 기록된 퇴원 진단은 recorded time만으로 실제 이용 가능성을 판단하기 어렵다.

**제안하는 코드 수정:**

1. `R/StudySettings.R`에 입력 경계의 기준·포함 여부·정밀도를 추가한다. 기존 날짜 기준 task는 기존 의미를 유지하고, timestamp 기반 task는 `prediction_datetime`, `input_start_datetime`, 경계 연산자 등을 명시한다.
2. 현재의 index 당일 포함 규칙이 다음 날 0시보다 이전이라는 정책과 동등한 경우에는 그 대응을 명시한다. 날짜를 임의 00:00으로 채워 실제 사건 시각을 복원했다고 표현하지 않는다. 정밀도가 부족한 기록의 포함/제외/거부 정책을 설정으로 드러낸다.
3. **instance의 입력 경계와 선택된 availability 정책을 먼저 적용한 뒤 집계한다.** 전체 날짜의 값을 먼저 요약하고 cutoff를 나중에 적용하면, cutoff 뒤의 측정값이 min/max/last에 섞일 수 있다.
4. 원본 `record_datetime`과 가용성 판단용 메타데이터를 보존하고, 파생 `available_datetime`을 사용하는 경우 추론 규칙·근거·정밀도를 별도로 기록한다. 원본 시각을 덮어쓰지 않는다.
5. 기존 label의 `covariateStartDate`와 실제 입력 필터의 차이를 해소한다. 보고용 window와 실제 적용 window를 구분하여 검사하고, 관찰기간 절단 여부를 바꾸면 별도 task version으로 기록한다.

보존할 context는 `record_id`, source table·PK, 원본 `*_type_concept_id`, `visit_occurrence_id`, 가용한 `visit_detail_id`, 방문 시작·종료 날짜/시각·유형이다. 이를 `metadata/record_context`와 `metadata/visits`로 연결하고 모델 predictor에서는 제외한다. cohort row와 visit의 일대일 관계를 가정하지 않는다.

시간대나 ETL의 시각 정밀도를 확인할 수 없으면 이를 unknown으로 기록한다. source local time을 임의로 UTC로 바꾸거나 날짜만 있는 사건을 자정 발생으로 단정하지 않는다. 사건의 원본 date와 datetime이 충돌하면 별도 검증 결과로 남긴다.

| 입력 정책 | 동작 | 필수 검사 |
| --- | --- | --- |
| 기존 날짜 정책 | 현재 task의 날짜 구간·도메인 제한 유지 | 기존 입력 집합과의 동등성, 정밀도 표시 |
| `recorded_time` | 원본 timestamp와 prediction timestamp를 비교 | 선언한 `<`/`<=` 경계, timezone/날짜 정밀도 |
| encounter 가용성 정책 | 설정된 retrospective record type에 방문 종료 등의 가용 시점을 적용 | type·visit 연결과 종료 시각의 가용성; 추론 불가 시 명시적 처리 |

availability 정책에 필수인 context가 없는데 검사를 통과한 것처럼 진행하지 않는다. 다만 **기록 유형만으로 모든 청구 기록을 삭제하거나, 모든 task에 같은 마지막 24시간 제거 규칙을 강제하지 않는다.** 이전 입원에서 이미 확정된 기록은 현재 입원의 소급 기록과 구분해야 한다.

논문 Appendix F는 encounter 기준의 제안 규칙, 실제 사용한 24시간 heuristic, 과거 교정 build와 현재 manifest의 미확인 연결을 함께 기록한다. 이들을 하나의 확정된 구현으로 취급하지 않는다. 질환 정의 concept 제외(C2)도 해당 task의 선정·label 정책이 요구할 때 적용하며, 현재 task의 모든 과거 진단을 일괄 제거하지 않는다.

기존 [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) E절의 observation_period/death 추가 연구 검토 보류는 유지한다. 여기서는 시간 계약과 필요한 원본 보존을 구현하고, 임상 연구 정의 변경은 분리한다.

### 2.7 개선안 R4 — 전체 환자 기본 정보와 instance 기준 age

**문제와 이유:** `studyPopulation/<task>.rds`는 해당 downstream task의 선정 결과다. 여기에 있는 `ageYear`, `gender`만 복사하면 사전학습 환자 전체를 제공할 수 없고, 다른 prediction time에 필요한 age도 자동으로 해결되지 않는다.

**제안하는 코드 수정:**

- 신규 `R/Demographics.R::exportPersons()`와 `ExportPersons.sql`로 전체 `study_population`을 OMOP `person`과 연결한다. `persons.csv.gz`는 환자당 한 행이며, pretraining·downstream 전원을 포함한다.
- `person_id`, 원본 출생 연·월·일, `birth_precision`, `gender_concept_id`를 제공한다. 신뢰할 수 없는 월/일을 생일로 간주하거나 누락된 날짜를 1월 1일로 보정하지 않는다.
- `ageAtDate()`는 신뢰 가능한 생일이 있으면 만 나이, 출생 연도만 있으면 연도 차이를 계산하고 `age_method`·`age_reference_date`를 함께 내보낸다. source/ETL의 날짜 보정 여부도 정밀도 판단에 포함한다.
- `createTaskDemographics()`는 `sample_id`, `person_id`, `age_at_prediction`, `age_reference_date`, `age_method`, `gender_concept_id`를 만든다. 기존 cohort index와 prediction time이 다르면 그 차이를 반영한다.
- pretraining은 `persons`와 기록을 연결하여 record date 또는 모델이 정한 기준일의 age를 구할 수 있게 한다. 마지막 기록 시점의 age 하나를 모든 과거 사건에 재사용하지 않는다.

현재 성인 선정의 연도 차이 기준은 변경하지 않는다. OMOP gender concept과 PLP `gender`의 encoding이 같다고 가정하지 않고, 새 공통 출력은 원본 concept을 기준으로 한다. 모델별 sex encoding과 결측 처리는 adapter가 결정한다.

### 2.8 개선안 R5 — 환자 분할과 데이터 역할의 명시

**문제와 이유:** 현재 `allrecords.csv.gz`에는 선정 환자 전원이 들어 있다. 파일명만으로 pretraining 집합이라고 판단하면 downstream 환자가 사전학습이나 anchor 통계에 들어갈 수 있다. 현재 `person_split.csv`는 pretrain train/valid와 downstream을 구분하지만 downstream 내부 분할은 만들지 않는다.

**제안하는 코드 수정:**

1. `R/PersonSplit.R`의 현재 분할 알고리즘과 seed를 유지하고, 각 출력의 허용 환자 집합을 manifest로 명시한다. pretraining용 reader/export는 선택된 `stage`와 `split`을 검증한 뒤 기록을 제공한다.
2. 선택 pool을 정의하는 `population_membership.csv` 또는 동등한 manifest를 지원한다. `pool_id`, 정확한 `person_id`, site/역할, 원래 split과의 관계, membership 파일 hash를 기록한다. anchor용 pool도 하나의 명시적 부분집합으로 표현한다.
3. `importPatientPartitions()`와 `validatePatientPartitions()`를 제안한다. 외부에서 확정한 `person_id → train/valid/test` 배정을 읽고, 대상 집합 포함 여부·중복·미배정·pretrain과의 교집합을 검사한다. 누락을 임의 train으로 채우지 않는다.
4. 분할을 패키지에서 생성할 경우에는 선택 기능으로 제공한다. 비율·seed·정렬/RNG·환자 목록 hash를 저장하고, task별이나 모델 seed별로 몰래 다시 배정하지 않는다. 논문식 고정 분할은 사용할 수 있는 하나의 protocol이며 기본 연구 정의를 대체하지 않는다.
5. 하나의 분할 배정을 모든 task와 반복 입원에 연결한다. support/query를 실제로 뽑는 것은 모델 코드의 책임이지만, 환자 중복 검사에 사용할 exact ID와 partition 정보를 제공한다.

pretraining을 위한 기록, source-fitted 정규화에 쓰는 학습 집합, anchor 통계에 쓰는 label-free pool은 자동으로 같은 집합이 아니다. 각 사용처가 `fit_scope`와 membership을 명시해야 한다. 외부 기관의 기존 `stage = external` 정책은 유지하며, 외부 평가 입력·label의 존재를 전처리 통계 적합이나 학습에 사용할 권한으로 해석하지 않는다.

### 2.9 개선안 R6 — 현재 task를 유지한 instance·input·label 계약

**제안하는 코드 수정:**

- `R/StudySettings.R`에서 task ID, target/outcome, 입력 시간 정책, TAR, 제외 기준, label type, registry/SQL 출처와 version을 검증한다. 기본 38개 task의 clinical definition은 유지한다.
- `taskInstances.csv.gz`에 `(taskId, sample_id)`별 환자·예측 시점·실제 입력 구간·정밀도·입력 건수·`has_input`을 기록한다. 같은 환자의 여러 진입 건과 여러 task를 구분한다.
- `outcomeLabels.csv`에 exact `person_id`, `sample_id`를 연결한다. 현재 `rowId`는 extraction별 식별자로 취급하며 전역 ID로 가정하지 않는다. 정답·TAR·outcome 발생일은 predictor에서 제외한다.
- `R/TaskInput.R`에서 입력 공유 여부는 target뿐 아니라 실제 입력 window, domain, 시간 정밀도, availability 및 task-specific 제외 정책까지 포함한 signature로 판단한다. 서로 다른 정책이 같은 cache를 공유하지 않게 한다.
- 현재 `outcomeLabel = as.integer(outcomeCount > 0)`의 의미를 `label_type = binary`로 명시한다. 회귀·다중분류·별도 생존 target은 구현하지 않은 상태에서 지원한다고 표시하지 않는다. 여러 phenotype은 현재처럼 task별 이진 label을 내보내고, 후단에서 multi-label 행렬로 구성할 수 있게 한다.
- `createOutcomeLabels()`가 빈 population을 단순히 건너뛰어 task가 사라지지 않도록 `task_status.csv`와 attrition을 남긴다. label은 있으나 입력이 비어 있는 instance도 유지한다. 정상 empty, 실패, 미실행을 구분한다.
- 기본 cohort 이름표 경로를 실제 registry와 일치시킨다. 이름이 없는 경우의 ID fallback은 상태로 표시하고 source를 기록한다.

새 task 추가는 기존 설정 확장 및 사용자 registry/SQL 경로 또는 prebuilt cohort 연결로 지원한다. prebuilt 원본을 삭제·재생성하지 않으며, 사용자 target SQL이 제한 파라미터를 선언하지 않아도 최종 target이 허용 환자 집합에 속하는지 공통 단계에서 강제 검증한다. 논문 task 재현 profile과 공식 EHRSHOT label/split import는 별도 요청 시 구현할 선택 확장이다.

현재 phenotype을 유지하는 목적에는 논문의 원본 ICD–CCS 변환을 새로 필수 구현할 이유가 없다. `condition_source_concept_id`, `condition_source_value`, 원본 vocabulary를 보존하는 것은 선택 provenance 또는 그런 labeler를 사용할 때의 요구로 구분한다.

### 2.10 제안하는 산출물 묶음과 스키마 역할

기존 출력은 그대로 보존하고, 새 스키마의 run은 `<outputRoot>/<databaseId>/runs/<runId>/`에 작성한다. `execute(outputFolder = ...)`는 지금처럼 최종 폴더를 받고 runner가 경로를 조합한다. 이름이 같은 파일을 새 의미로 조용히 덮어쓰지 않는다.

| 산출물 | 최소 내용 | 역할 |
| --- | --- | --- |
| `allrecords/part-*.csv.gz` | exact ID, 사건 날짜/시각·정밀도, domain/concept, 수치·범주·단위 | 모든 선정 환자의 사건 기준 데이터 |
| `persons.csv.gz` | 환자 키, 출생 정보·정밀도, gender concept | pretraining과 downstream 공통 기본 정보 |
| `person_split.csv` | 기존 stage/split/seed | 기존 연구 분할의 기준 |
| `population_membership.csv`, `patient_partitions.csv` | 선택한 pool과 외부/선택 분할 | 선택 기능. 사용한 집합의 hash·source를 manifest에 기록 |
| `taskInstances.csv.gz` | task/sample/person 키, prediction time, 실제 입력 window, 입력 건수·상태 | label·기록·기본 정보 연결 |
| `taskDemographics.csv.gz` | sample/person 키, age와 기준일·방법, gender concept | instance별 정적 입력 구성 |
| `taskInput/<extraction>/part-*.csv.gz` | sample/record 키와 해당 사건의 임상 필드 | 선언된 정책을 통과한 사건 집합 |
| `outcomeLabels.csv`, `task_status.csv` | task/sample별 정답·판정 기간 및 모든 task 상태 | 학습·평가용 target과 생성 상태 |
| `metadata/record_context.csv.gz`, `metadata/visits.csv.gz` | source lineage, 기록 유형, encounter 연결·시각 | 감사와 정책 적용용. predictor에서 제외 |
| `metadata/plp_instance_map.csv.gz`, `metadata/plp_person_map.csv.gz` | exact person/sample 키와 추출별 PLP rowId·안전한 subject surrogate | label 생성 시 확보하고 제3장이 검증·재사용할 연결 정보. predictor에서 제외 |
| `schema.json`, `manifest.json`, `run_info.json`, `settings/` | 타입·role·NULL·시간 의미, 버전·설정·출처·완료 상태 | 재현과 reader 검증 |
| `compatibility/`, `plpData/`, `studyPopulation/<taskId>.rds` | 기존 view, label 생성에 사용한 PLP 객체와 population metadata | 기존 워크플로·label 엔진 및 선택 PLP 실행의 출처. 제3장의 모델별 feature·결과는 별도 경로에 저장 |

기본 교환 형식은 현재 환경에 맞는 CSV/gzip을 유지한다. 분할 파일·label·source ID를 읽는 R/Python 예제는 schema의 문자열 dtype을 명시한다. CSV quoting만으로 큰 ID의 자동 숫자 추론을 방지했다고 간주하지 않는다. Parquet은 별도 의존성과 왕복 검증을 거친 선택 형식으로 둔다.

`schema.json`에는 identifier, clinical value/code, clinical time, label, eligibility, provenance 역할을 표시한다. predictor 선택 예제는 allowlist를 사용한다. ID 숫자를 입력 feature로 만들지 않고, metadata를 모델 입력에서 뺀다는 이유로 데이터 연결·시간 감사에 필요한 원본까지 삭제하지 않는다.

대용량 input은 기본적으로 사건 값을 포함한 materialized shard로 제공하고, 필요하면 `(sample_id, record_id)` 연결 표와 공통 사건 reader를 사용하는 대안을 둔다. 두 방식의 포함 사건 집합은 같아야 한다. 빈 instance는 어느 방식에서도 사라지면 안 된다.

### 2.11 파일·함수별 구현 작업 목록

아래 신규 이름은 제안 API다. 현재 호출 가능한 함수나 생성된 산출물로 해석하지 않는다.

| 대상 | 구체적인 수정 | 우선순위 |
| --- | --- | --- |
| [R/SettingsObjects.R](R/SettingsObjects.R), [R/StudySettings.R](R/StudySettings.R), `inst/settings/` | 사건 모드·schema version·시간/availability·context·partition import 설정과 검증. 기존 JSON의 legacy 해석 유지 | P0 |
| [R/AllRecords.R](R/AllRecords.R), 신규 `R/CanonicalRecords.R` | 기존 FE 경로와 사건 경로 분리; `extractCanonicalRecords()`·batch/shard writer·정확한 타입 계약 | P0 |
| 신규 `inst/sql/sql_server/ExtractCanonicalCondition.sql`, `ExtractCanonicalDrug.sql`, `ExtractCanonicalProcedure.sql`, `ExtractCanonicalMeasurement.sql` | 원본 PK·시간·임상값·단위·기록 유형 조회. SqlRender 방언 변환. DB source와 stream의 일치 검사 | P0 |
| 신규 `R/RecordContext.R`, `ExportRecordContext.sql`, `ExportVisits.sql` | 사건·visit/source 연결 보존 및 capability 검사. 필수 정책 실행에 필요한 metadata 제공 | P0: 사용 정책의 필수 필드; P1: 독립 편의 export |
| 신규 `R/Demographics.R`, `ExportPersons.sql` | 전체 선정 환자 export, `ageAtDate()`, `createTaskDemographics()` | P0 |
| [R/TaskInput.R](R/TaskInput.R) | exact ID로 instance 생성, 사건 저장소 연결, 실제 cutoff·정책 적용, empty input 상태, 원본 임상 필드 전달 | P0 |
| [R/createOutcomeLabels.R](R/createOutcomeLabels.R) | 정확한 person/sample key, 빈 task 상태·attrition, label type 명시, outcome 이름표 경로 수정 | P0 |
| [R/PersonSplit.R](R/PersonSplit.R), 신규 `R/PatientPartitions.R` | 기존 split 보존; 역할별 membership 검증; 외부 partition import와 전체 task 일관성 검사 | P0: 분할 검사·기록; P1: 선택 분할 생성 |
| [SparseArray/R/extractPlpData.R](SparseArray/R/extractPlpData.R), [SparseArray/R/createCohort.R](SparseArray/R/createCohort.R), 신규 `R/PlpIdentity.R` | exact mapping·검증된 cache; task registry/prebuilt 연결; 공통 target 환자 제한. PLP 임시 cohort에서 exact ID를 확보하는 구체적인 wrapper는 3.5절 | P0: 기존 경로의 정확성; P1: 사용자 task 확장 |
| [R/Export.R](R/Export.R), 신규 `R/RunManifest.R`, `R/Cache.R` | 타입 지정 reader/writer, atomic 저장, 설정·SQL·code·source hash, 단계 의존성과 cache 검증 | P0 |
| 신규 `R/DataBundle.R` | `loadDataBundle()`·`readTaskBatch()`; 검증된 manifest·타입·task 정책에 따라 후속 모델/PLP가 공통 데이터를 batch로 읽는 인터페이스 | P0 계약, reader 검증 단계에서 구현 |
| [R/Diagnostics.R](R/Diagnostics.R), [R/Main.R](R/Main.R), [extras/CodeToRun.R](extras/CodeToRun.R) | 실행 계획에 따른 필수 산출물 검사, 구조화된 실패, 예외 전파, CLI 종료 코드, 성공 marker | P0 |
| 신규 `extras/ValidateOutputs.R` 또는 공식 검증 모듈 | 현재 독립 validator의 의도를 정식 코드로 이관. CDM 집계와 출력 대조를 유지 | P0 |
| `tests/testthat/`, `SparseArray/tests/testthat/` | 2.14절의 손실·경계·캐시·실패 재현 테스트 | 해당 구현과 함께 |
| `README.md`, `DESCRIPTION`, `NAMESPACE`, `man/`, 출력 설명·설계 문서 | 설치 API·스키마·지원 범위·마이그레이션 일치. 구현 전 계획과 구현 완료 이력을 구분 | 해당 구현과 함께 |

기존 `MeasurementValueUnit.sql`의 998/999 부호화에 범주값·원사건을 억지로 추가하지 않는다. legacy 기능으로 유지하고, “하루 마지막 값”이라는 설명이 실제 시각순 선택을 뜻하지 않도록 문서·주석을 정정한다. 선택 `extras/CreateMedRepFiles.R`의 미정의 resolver 문제는 비교 기능의 별도 수정·검증 항목이다.

### 2.12 개선안 R7 — 실패·캐시·ID·출처의 신뢰성

**캐시:** `file.exists()`/`dir.exists()`만으로 재사용하지 않는다. 완료 상태, schema, 필수 파일의 읽기·행 수·checksum, source snapshot, 환자/split/pool, analysis·task settings, cohort SQL/registry, 관련 code/package version을 검증한다. 데이터가 바뀌었는데 코드·설정 hash만 같은 경우도 막아야 한다. 안정된 source snapshot 식별이 없으면 새 실행 간 자동 재사용을 기본적으로 제한하고, 실행 중 원본 변화의 통제·한계도 기록한다.

**단계 의존성:** 사건 필드·source 범위가 바뀌면 사건과 input을, task window가 바뀌면 해당 instance·input을, label 규칙이 바뀌면 해당 label/선정 결과를 다시 만든다. 기본 정보만 추가하는 경우 사건 전체를 불필요하게 다시 추출하지 않는다. 선행 산출물 확인은 stage skip 플래그로 우회할 수 없게 한다.

**파일 완료:** 같은 파일시스템의 `.partial`에 쓰고 close·검증 후 rename한다. 현재 allrecords의 staging 동작을 task input·label·manifest로 확장한다. 여러 파일의 묶음 완료는 마지막 stage manifest로 판정하고, interrupted shard를 완료 산출물로 보지 않는다. Windows/D bind mount의 rename·교체 동작도 확인한다.

**실패 신호:** `runDiagnostics()`는 구조화된 passed/errors/warnings와 task 상태를 반환하고, 필수 실패는 `execute()`의 error 및 runner의 nonzero 종료로 전파한다. 라이브러리 함수에서 R 세션을 종료하지 않는다. 로그의 `Done`과 완료 marker는 필수 검증을 통과한 뒤 기록한다. 등록된 task가 정상 empty인지, 누락·실패인지도 구분한다.

**ID:** DB→R→CSV→reader→task/label 연결 전 구간에서 문자열 또는 검증된 integer64를 유지한다. 현재 `.taskRowsForExtraction()`의 `as.numeric(personId)` 조인을 제거하고 CSV 읽기 타입도 명시한다. numeric만 받는 라이브러리 경계가 있으면 손실 이전의 exact mapping 또는 검증된 surrogate를 사용한다. 이미 반올림된 ID를 문자로 바꾸는 것을 복원이라고 하지 않는다. PLP 연결 방식은 설치 버전의 작은 fixture로 먼저 확정한다.

**시간 간격:** legacy 경로의 `timeInterval > 1` 날짜 복원 오류는 우선 미지원 설정의 명시적 거부로 막는다. v2는 원본 날짜·시각을 사용한다. 임의 interval을 지원하려면 사건 timestamp와 bin 경계를 별개로 검증해야 한다.

**Provenance:** schema·코드 commit/dirty hash, 분석/task 설정 snapshot, cohort SQL·registry, vocabulary/source/ETL snapshot, 시간·값 정책, 선택 필드 capability, split/pool/partition hash, 출력 건수·checksum·단계 상태를 저장한다. 연결 자격 증명은 포함하지 않는다. 코드 commit 하나나 package version 문자열만으로 미커밋 실행 수정을 식별했다고 보지 않는다.

### 2.13 모델 및 PLP 모듈에 전달할 데이터 계약

`loadDataBundle(dataRunFolder)`와 `readTaskBatch(bundle, taskId, sampleIds, columns)`를 신규 `R/DataBundle.R`의 공통 reader로 제안한다. 완료 manifest·schema·checksum을 검증하고, 문자열 ID와 task별 허용 사건 집합을 유지하며, 전체 파일을 한 번에 메모리에 올리지 않는 batch를 반환한다. label·eligibility·provenance 필드는 predictor allowlist에서 제외한다.

reader는 환자 집합·instance·partition, 실제 input window·availability 정책, 원사건·값·단위·정밀도, instance 기준 age·gender, task 정의 및 빈 입력 상태를 전달한다. `allrecords`를 사용하는 후단 reader도 이미 정의한 task input과 같은 사건 집합을 만들어야 한다. phenotype의 condition 제외처럼 task별로 다른 정책을 모델이 전체 이력으로 우회하지 않게 검증한다.

단위 통일·집계·token budget·tensor·학습 통계의 적용은 모델 adapter의 책임이며, 구체적인 순서는 3.7절에 둔다. 공통 기록은 원값을 유지한다. 정규화 artifact는 fit 환자 membership hash, concept/단위, 변환 규칙·버전으로 데이터와 연결한다. source training, pretraining, anchor pool, support/query를 자동으로 같은 집합으로 취급하지 않는다.

LLM 기반 설명문 생성, MLM·contrastive 학습, embedding·anchor·aggregator·TFM 알고리즘과 checkpoint는 기본 data pipeline의 필수 구현에 넣지 않는다. 선택 PLP 모듈이 등록된 외부 모델의 fit/predict를 호출하는 것은 제3장의 명시적 실행 모드다. 새로운 도메인·노트·파형이 필요한 모델은 현재 네 도메인 계약만으로 지원한다고 표시하지 않는다.

### 2.14 검증 계획과 합격 조건

아래는 향후 코드 변경과 함께 추가할 검증이다. 이 문서를 작성하면서 테스트 코드나 실제 데이터를 새로 생성·실행한 결과가 아니다.

| 검증 | 합격 조건 |
| --- | --- |
| 오전 100·오후 200, 동일 concept·unit | 원사건 2행 보존. 독립 집계에서 count 2·min 100·max 200·last 200 |
| 마지막 사건의 값은 NULL, 이전 사건은 숫자 | last record timestamp와 last non-missing value timestamp를 구분 |
| 같은 시각·다른 단위·다른 PK | 원사건별 값/단위 유지. 단위 하나를 임의 선택해 혼합값에 붙이지 않음 |
| 숫자·범주 동시 존재, 복수 범주, 음성/취소/미상 | 원본 필드와 사건 수 보존. 결측·0·negative의 의미 혼합 없음 |
| 임의 일중 cutoff 및 직전·정각·직후 기록 | 선언한 경계와 실제 사건 집합 일치. cutoff 뒤의 값이 요약에 포함되지 않음 |
| 소급 기록된 현재 입원 진단과 이전 퇴원 진단 | 선택된 availability 정책을 정확히 적용하고 과거 유효 이력을 일괄 제거하지 않음 |
| 생일 전후·윤년·year-only·gender 미상 | age 기준일·방법·정밀도 표시, 임의 생일/sex 생성 없음 |
| `9007199254740992`, `9007199254740993`, 음수 19자리 ID | DB·파일·PLP 연결에서 환자와 사건이 구분되고 문자열 왕복 일치 |
| 동일 환자의 여러 입원·task·shard | 허용된 partition 일관성, pretrain/downstream 및 선언된 support/query 교집합 0 |
| 빈 입력 instance·빈 task·누락 task | 각각의 상태를 구분하고 label/instance가 조용히 사라지지 않음 |
| 설정·SQL·split·source 변경, 빈/잘린 cache | 잘못된 재사용 거부. stage 의존성에 맞는 재생성 |
| shard 작성 중단 후 resume | 완료 shard만 사용하고 최종 사건 중복·누락 0 |
| 단계 예외·진단 실패를 별도 Rscript에서 실행 | nonzero 종료 및 완료 marker 부재. 정상 완료와 명확히 구분 |
| 현재 38개 task 정의의 회귀 | 설정·source가 같을 때 선정·split·label 의미 보존. 사건 출력 변경과 label 변경을 구분 |

전체 검증은 source 범위와 snapshot을 맞춘 뒤 도메인별 행 수, 원본 PK, 숫자·범주·단위·NULL·timestamp 집계를 독립 SQL과 비교한다. task별 instance 수·label·실제 입력 구간·empty 수·기본 정보 연결을 대조한다. 범주형 감사의 과거 수치를 고정 정답으로 쓰지 않고 동일 snapshot인지 먼저 확인한다.

작은 fixture → 기존 1,000명 샘플 모드의 별도 run → 전체 대상 실행 순으로 진행한다. raw 사건의 정보 보존 확인에는 기존 선정 환자의 결정적 부분집합을 별도로 사용할 수 있으나 이를 새 연구 선정 기준으로 사용하지 않는다. SQL 렌더링과 실제 DB 실행을 구분하고, PostgreSQL에서 확인한 결과를 SQL Server 실행 완료로 표시하지 않는다.

모델 학습 없이 동일 공통 기록에서 시간순 event sequence와 기간별 min/max/mean/count table을 구성하는 reader 예제를 검증한다. 이 예제의 집계 규칙은 공통 pipeline의 유일한 데이터 정의로 승격하지 않는다.

### 2.15 기존 산출물 전환과 구현 순서

| 자산/단계 | 처리 방침 |
| --- | --- |
| 현재 선정 환자·기존 split | 정의·exact ID·hash 검증 후 재사용. 새로운 사건 수로 다시 선정하지 않음 |
| 기존 allrecords·FE cache·PLP 출력 | legacy 원본으로 보존. v2 원사건으로 간주하지 않음 |
| 전체 환자 정보 | person을 추가 조회하여 생성 가능. 이 작업만으로 사건 전체 재추출은 불필요 |
| 사건 시각·반복값·범주·context | 기존 파일에서 복구 불가한 정보는 **CDM 재추출 필요** |
| v2 task input | 새 사건과 explicit instance 정책에서 재생성 |
| 기존 label | 동일 source·task·cohort·선정 기준과 exact mapping을 확인한 경우 재사용 가능. 확인할 수 없으면 재생성 |
| 현재 검증 보고서 | 기준 실행의 증거로 유지. 새 계약의 검증 보고서는 새 run에 저장 |

구현 순서는 **계약/fixture → ID·실패·캐시 검증 → 원사건·값·시간/context 추출 → 전체 환자 정보·membership → instance/input/label 연결 → 샘플·전체 검증 → reader와 전환 문서**로 둔다. 현재 task의 연구 정의를 바꾸지 않는 경로부터 검증한다.

우선 P0로 사건·값·시간·기본 정보·정확한 연결·실패 판정을 구현한다. P1은 사용자 task/partition 인터페이스와 운영 편의 기능을 강화한다. Parquet, 새 도메인, 새로운 label type, 특정 논문/benchmark의 재현 profile은 P2 선택 확장이다. 기존 `FUTURE_PLAN.md`에서 visit context를 선택 확장으로 분류한 것은 편의 export에 한정하며, **선택한 시간 정책이 요구하는 원본 context의 확보·검증은 그 정책의 필수 조건**으로 해석한다.

새 출력과 작업 cache는 현재 설정된 D 저장 영역의 run별 경로를 사용한다. 기존 출력은 `D:\TabEHR-storage\files\output\mimic`에 유지한다. R/Andromeda 임시 파일과 DB tablespace는 각각 확인한다. 사건 단위 v2의 저장량과 시간은 일 단위 결과에서 단순 비례 추정하지 않고, 샘플에서 처리율·압축률·임시 공간을 측정한 뒤 실제 여유 공간을 확인한다. 오래된 검증 결과를 자동 삭제해 공간을 확보하지 않는다.

### 2.16 근거, 보류 사항과 완료 판정

| 근거 | 이 장에서 사용한 범위 |
| --- | --- |
| [기존 수정 이력](REVISON.md) | 제1장으로 보존한 실제 수정·운영 조치·검증·미해결 사항 |
| [선행 개선 계획](FUTURE_PLAN.md) | 사건 중심 데이터, 기본 정보·schema·cache·migration 설계의 기반 |
| [TabEHR 논문](paper/iclr_2027_TabEHR.pdf) | §3.1–3.5, Appendix B.3·C.1–C.4·E.1/E.5·F의 요구 및 명시된 한계 |
| [전체 실행 요약](output/full-D-validation/completion_summary.json), [독립 검증](output/full-D-validation/execution_validation.json) | 현재 정의로 수행한 전체 실행의 증거 |
| [현재 계약](output/code-review-20261024/preprocessing_contract.json), [경계 오류](output/code-review-20261024/edge_cases.json), [진단 범위](output/code-review-20261024/diagnostic_coverage.json) | 공통 필드 누락·캐시·ID·실패 판정 문제 |
| [범주형 감사](output/categorical-audit-20261024/categorical_loss_report.json) | 현재 출력과 원본 categorical measurement의 차이 |
| 사용자가 제공한 추가 대화와 최신 task 설명 | 논문 재현을 필수 목표에서 제외하고 현재 task를 유지하는 범위 결정 |

첨부 논문의 SHA-256은 `1e3ed63676df0708b25bc2039d44448cebfe89d30e1d8e4063efd62bd1bbbd65`다. 기존 `REVISON.md` 원본의 SHA-256은 `c038f17a84cf6c1d2c8df6459f87c8c53c48c564a49b6f7b24dce46367343f0f`다.

논문은 E.5에서 값·단위 결합의 재현성 문제를, F에서 제안 규칙·과거 교정·현재 build의 차이를 명시한다. 논문 문장만으로 해당 처리가 모두 정확히 구현·검증되었다고 간주하지 않는다. 정확한 논문 재현이 별도로 요청되면 원본 builder 설정, unit/range 규칙, label·split·pool·model artifact manifest를 확인해야 한다. 이 항목이 공통 pipeline 개선을 논문 전용 파이프라인으로 확대하는 이유는 아니다.

공통 pipeline의 완료 조건은 정의한 source 범위의 사건·임상값·시간·기본 정보가 보존되고, 등록된 task의 input·label·split을 정확히 연결하며, 그 결과를 독립 검증·manifest로 확인할 수 있는 상태다. 이를 `data_validation = passed`로 기록한다. 제3장의 `plp_integration_validation` 및 실제 모델 성능 결과와 구분하며, 데이터 검증 통과만으로 모델 연결·학습·외부 검증 완료를 주장하지 않는다.

## 제3장. Python foundation model을 연결하는 PLP pipeline 개선 계획

### 3.1 목표, 지원 범위와 실행 모드

제3장은 제2장의 공통 산출물 위에 **선택적으로 실행하는 모델 연결·평가 기능**을 추가하는 계획이다. 본 패키지의 기본 objective는 유지한다. 사용자는 데이터만 생성하거나, 외부 Python 예측값만 평가하거나, 등록한 Python 모델을 PLP에서 호출할 수 있다. 모델별 tokenizer·embedding·head·fine-tuning 알고리즘은 외부 adapter가 구현한다. 본 패키지는 공통 입력 계약, 실행·저장 인터페이스, 평가 대상과 라벨의 일관성을 책임진다.

| 실행 모드 | 입력과 동작 | 구현 순서 |
| --- | --- | --- |
| `import_predictions` | 완료된 data run과 외부 예측 파일을 검증하고 PLP prediction 객체·평가 결과 생성. Python 실행 불필요 | 첫 연결 경로 |
| `validate_model` | 고정된 모델·전처리 artifact를 읽어 Python 추론 → 예측 연결 → PLP 평가 | 두 번째 경로 |
| `develop_model` | 확정된 train/valid/test 및 fold에서 등록된 fit 함수를 호출하고 모델 저장·예측·평가 | 선택 개발 경로 |

입력 표현도 별도로 등록한다. `events`는 원사건을 읽는 sequence/TabEHR adapter, `features`는 집계 table 또는 frozen embedding을 PLP covariate로 연결하는 adapter다. 실행 모드와 표현을 섞지 않는다. 예를 들어 sequence 모델의 예측 파일도 `import_predictions`로 평가할 수 있다.

현재 38개 task를 이진 예측 task로 유지한다. 모델이 embedding만 반환하면 task head 또는 별도 예측 절차가 있어야 평가 확률을 만들 수 있다. 새 회귀·다중분류·생존 labeler, 노트·파형·새 도메인, foundation model 자체의 pretraining 학습 엔진은 이 확장의 기본 구현에 포함하지 않는다. PLP의 survival 지원은 현재 패키지에 survival task가 구현되어 있다는 뜻이 아니다.

### 3.2 참고 구현에서 재사용할 구조와 그대로 복사하지 않을 부분

검토한 GlaucomaPrescreeningPrediction snapshot은 `bd335b7458276d84dba92b382ee5c8719513388c`다. 아래는 소스에서 확인한 구조이며, 해당 저장소를 이 환경에서 실행 검증했다는 의미가 아니다.

| 근거 코드 | 확인한 구조 | 본 패키지의 적용 방안 |
| --- | --- | --- |
| [measurementFeatures.R](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/R/measurementFeatures.R) | 사용자 정의 추출 함수가 max/min/mean/median/stdev/recent를 계산하고 `covariates`, `covariateRef`, `analysisRef`를 가진 `CovariateData` 반환 | 제2장의 원사건에서 모델별 집계를 만든 후 같은 PLP 계약으로 변환. 모델마다 CDM 재추출 경로를 만들지 않음 |
| [autoEncoders.R](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/R/autoEncoders.R) | reticulate로 Python Keras encoder를 호출하고 embedding을 새 covariate로 추가 | frozen encoder 결과를 선택 feature로 연결하되, 원래 instance mapping·차원 순서·encoder hash 보존 |
| [plpModel.R](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/R/plpModel.R) | 모델·전처리·covariate map과 custom prediction 함수를 PLP 객체로 묶음 | `createFoundationPlpModel()` 및 `predictFoundation()`으로 일반화 |
| [execute.R](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/R/execute.R) | PLP population 생성 → `predictPlp()` → `evaluatePlp()` 및 결과 export | 기존 task population을 재사용하는 `executePlp()` 구현 |
| [FineTuning.R](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/R/FineTuning.R) | 외부 Keras 학습·평가 절차를 연결 | 모델별 fit callback의 사례로 참고. 본 패키지에서는 기존 환자 partition과 fold를 사용 |

이 예제의 질환별 concept 목록, 학습 집합에서 정해진 scale/imputation, feature 순서 및 모델 파일은 그 연구의 계약이다. 이를 모든 EHR 모델의 기본값으로 옮기지 않는다. 특히 행렬의 행 번호를 원래 PLP `rowId`로 간주하거나 현재 연도 기준 age를 새로운 공통 기준으로 사용하지 않는다. 본 패키지에서는 exact instance mapping과 prediction time 기준 age를 적용한다.

`plpData`의 형식이 min/max/mean·embedding을 금지한다는 해석은 배제한다. 정보 손실 여부는 **어떤 추출·집계를 수행했는지**에 달려 있다. PLP용 파생 feature를 만들더라도 제2장의 원사건 bundle은 유지한다.

### 3.3 패키지 구조와 신규 파일

우선 같은 R 패키지 안에 아래 선택 모듈을 두고 `executePlp()`로 분리한다. 별도 패키지 분리를 선행 조건으로 삼지 않는다. 신규 이름은 제안이며 현재 존재하는 API·파일로 해석하지 않는다. 모델 구현은 외부 Python package/module로 등록한다.

| 신규 파일 | 주요 함수·책임 | 단계 |
| --- | --- | --- |
| `R/DataBundle.R` | `loadDataBundle()`, `readTaskBatch()`; 제2장 완료 산출물·타입·허용 사건 검증 | 공통 데이터 |
| `R/PlpSettings.R` | `createPlpPipelineSettings()`, `loadPlpSettings()`, `validateModelSpec()`; mode·task·partition·모델 등록 계약 | P0 |
| `R/PlpCompatibility.R` | `assertPlpCompatibility()`, 내부 version adapter; population·prediction hook·분할·직렬화 차이 격리 | P0 |
| `R/PlpIdentity.R` | `createMappedCovariateSettings()`, `getMappedCovariateData()`, `repairPlpIdentity()`, `validatePlpIdentity()`; 3.5절 | P0, label 생성 단계에도 필요 |
| `R/PlpPopulation.R` | `preparePlpTask()`; 저장 population·taskInstances·label·exact map 연결과 평가 대상 확정 | P0 |
| `R/PlpSplits.R` | `createManifestSplitSettings()`, `implementManifestSplit()`; 기존 환자 partition→PLP fold 매핑 | P0 계약, 개발 모드에서 사용 |
| `R/PlpFeatures.R` | `buildPlpCovariateData()`, `validateFeatureMap()`; 집계·embedding 결과를 PLP feature로 변환 | P1 |
| `R/FoundationModel.R` | `setFoundationModel()`, `createFoundationPlpModel()`, `predictFoundation()`, `fitFoundationPlp()` | P1 추론, P2 학습 |
| `R/PythonRunner.R` | `callFoundationRunner()`; 별도 Python 프로세스 또는 reticulate 호출·종료·응답 검증 | P1 |
| `R/PlpPrediction.R` | `importFoundationPredictions()`, `validatePredictions()`; key 기반 연결·확률·coverage 검사 | P0 |
| `R/PlpEvaluation.R` | `evaluateFoundationPredictions()`; PLP 평가·평가 불가 상태·task별 요약 | P0 |
| `R/PlpArtifacts.R` | `saveFoundationBundle()`, `loadFoundationBundle()`, `exportPlpRun()`; artifact·예측·결과·manifest 저장 | P0 결과, P1 모델 |
| `R/PlpMain.R` | `executePlp()`; task×model 실행 계획, 단계 상태, resume, 오류 전파 | P0부터 단계적 확장 |
| `inst/sql/sql_server/ExportPlpRowMap.sql` | 살아 있는 PLP cohort 임시 테이블의 rowId·원래 person ID·index를 정확히 export | P0 |
| `inst/schema/plp-settings.schema.json`, `model-spec.schema.json`, `prediction.schema.json`, `runner-request.schema.json` | R/Python에서 공유할 설정·요청·응답 계약 | P0/P1 |
| `inst/settings/plpSettings.example.json`, `modelRegistry.example.json` | 실제 task `death7` 등을 사용하는 명시적 예시. 실행 기본값은 data-only | P0 |
| `inst/python/tabehr_bridge/__init__.py`, `contract.py`, `runner.py` | schema/dtype 검사, 등록 module의 prepare/fit/predict 호출. 모델 알고리즘 없음 | P1 |
| `inst/python/examples/sequence_adapter.py`, `tabular_adapter.py` | 작동 계약을 보여 주는 작은 reference adapter. 실모델 검증과 구분 | P1 |
| `extras/CodeToRunPlp.R`, `vignettes/PlpPipeline.Rmd` | 세 실행 모드·모델 등록·외부 기관 적용 예제 | P0부터 갱신 |
| `DockerImage/Dockerfile.plp`, `compose.plp.yaml` | PLP 확장용 버전 고정 R 환경과 선택 Python 실행 설정 | P1 |
| `tests/testthat/test-plp-*.R`, `tests/python/test_runner_contract.py` | 3.16절의 계약·연결·실패 테스트 | 해당 단계와 함께 |

P0/P1/P2는 제3장 안의 구현 순서다. 제2장의 원사건·시간·값·ID 검증이 이 모듈의 선행 조건이며, 데이터 수정 없이 PLP 연결만 추가했다고 새 모델 입력 계약이 충족되지는 않는다.

### 3.4 사용자 API와 설정 계약

기존 `execute()`는 데이터 생성 진입점으로 유지한다. 아래는 **향후 API 사용 예시이며 현재 실행 가능한 코드가 아니다.** `dataRunFolder`는 제2장의 완료 run, `outputFolder`는 새 PLP analysis의 최종 폴더다. `executePlp()` 안에서 analysisId를 경로에 다시 붙이지 않는다. task ID `death7`, `death30`은 현재 registry의 값을 사용한다.

```r
plpSettings <- createPlpPipelineSettings(
  mode = "import_predictions",
  taskIds = c("death7", "death30"),
  modelIds = "sequence_model_v1",
  evaluationPartition = "test",
  plpProfile = "legacy-6.0",
  analysisId = "foundation_comparison_v1"
)

result <- executePlp(
  dataRunFolder = "/home/rstudio/storage/output/mimic/runs/<dataRunId>",
  outputFolder = "/home/rstudio/storage/plp/mimic/foundation_comparison_v1",
  settings = plpSettings,
  predictionFolder = "/home/rstudio/storage/predictions/<predictionRunId>"
)
```

`validate_model`은 `modelRegistryFile`을, `develop_model`은 이에 더해 partition/fold와 학습 설정을 요구한다. 모드별 필수 입력이 없으면 추측해 채우거나 자동 학습하지 않고 설정 검증에서 중단한다. `evaluationPartition = "test"`는 downstream 내부에 검증된 test 배정이 존재할 때만 허용한다. 현재 70:15:15의 마지막 15% 전체를 자동 최종 test로 해석하지 않는다.

모델 spec은 `modelId`, `adapterVersion`, `inputRepresentation`, `requiredFields/domains`, `supportedTaskTypes`, `backend`, `entryPoint`, `artifactManifest`, `positiveClass`, `outputScale`, `prepare/fit/predict` capability, `maxBatchSize`, precision/device, 환경 lock hash를 갖는다. task별 head가 다르면 head 및 task-definition hash를 따로 연결한다. 이름만 같은 모델이나 task를 동일 실행으로 간주하지 않는다.

지원하지 않는 모델·task 조합은 실행 계획에 `unsupported`로 표시한다. 기본 실행은 등록한 task×model 목록 전체의 성공·실패·제외 이유를 남기며, 성공한 일부만으로 전체 benchmark 완료를 표시하지 않는다.

### 3.5 Exact ID와 PLP rowId 연결의 구현

현재 [TaskInput.R](R/TaskInput.R)의 `.taskRowsForExtraction()`은 exact person 문자열을 double로 바꿔 PLP `subjectId`와 맞춘다. 새 경로는 이를 제거한다. `(databaseId, dataRunId, extraction, rowId)`를 PLP 행의 범위로, `(taskId, sample_id)`를 task instance의 키로 사용한다. `rowId` 하나를 전체 task·기관에서 유일하다고 간주하지 않는다.

**추출 시점에 exact map을 확보하는 방안:**

1. `createMappedCovariateSettings(originalSettings, mapDestination)`가 FeatureExtraction custom settings를 만든다. `attr(settings, "fun")`은 `TabEHR::getMappedCovariateData`를 가리킨다. 원래 settings는 내부 인수로 보관한다.
2. `getMappedCovariateData()`는 PLP가 넘겨 준 **동일 DB connection·cohortTable·rowIdField**에서 `ExportPlpRowMap.sql`을 실행한다. PLP 6.7.0의 추출 경로에서는 `#cohort_person`, `row_id`, `subject_id`, `cohort_start_date`가 존재한다. 다른 버전의 이름·타입은 compatibility 검사로 확정한다.
3. DB에서 `subject_id`를 `VARCHAR(20)`으로 CAST하여 `rowId ↔ exact person_id ↔ cohort_start_date`를 atomic sidecar로 저장한다. 이 query는 원본 BIGINT로 CDM 조인을 끝낸 후의 임시 cohort를 읽는다. 나중에 별도 connection에서 이미 제거된 임시 테이블을 조회하지 않는다.
4. 같은 함수가 `FeatureExtraction::getDbCovariateData()`에 **원래 settings만** 전달해 기존 feature 추출을 위임한다. 반환 `CovariateData` 및 temporal/temporalSequence 의미·metadata를 유지하고, SparseArray의 settings 판정·로그도 통과하도록 한다. ID를 feature로 추가하거나 dummy covariate를 넣지 않는다. wrapper 재귀·중복 호출과 cohort/rowId 누락을 검사한다.
5. `getPlpData()`가 반환한 후, 저장·label 생성 **이전**에 `repairPlpIdentity()`가 이 map으로 `cohorts$subjectId`를 안전한 surrogate로 교체한다. 정확한 원래 person ID는 sidecar에 보존한다. 동일 환자는 모든 extraction에서 같은 `plp_subject_id`를 쓰며, 정확히 표현 가능한 범위와 일대일성을 검사한다. 이미 반올림된 값으로 surrogate를 생성하지 않는다.
6. PLP가 subject별로 계산한 metadata·환자 수는 정확한 map을 기준으로 재검증·재산출한다. rowId 기반 outcomes/covariates 및 cohort row 수의 일치도 확인한다. 반환 전에 해당 PLP 버전이 반올림된 subjectId로 행을 합치거나 제거한다면 이 wrapper만으로 복구했다고 간주하지 않고 해당 profile을 실패 처리한다.

이 wrapper는 FeatureExtraction의 사용자 정의 추출 확장점을 이용하는 **제안**이다. 신규 fixture에서 중첩 위임·metadata 유지·SQL Server temp table 수명을 확인하기 전에는 지원 완료로 표시하지 않는다. 설치된 OHDSI namespace를 전역 수정하거나 CDM person ID를 덮어쓰지 않는다.

[SparseArray/R/extractPlpData.R](SparseArray/R/extractPlpData.R)에 선택 `plpDataPostprocessor = NULL` 인수를 추가하는 최소 확장을 제안한다. `getPlpData()` 직후 callback을 적용하고, map 검증이 성공한 객체만 `savePlpData()`로 저장한다. TabEHR의 `createTaskInput()`은 mapped settings와 postprocessor를 명시적으로 전달한다. SparseArray는 TabEHR를 import하지 않아 순환 의존성이 생기지 않는다. cache hit도 map·source·settings hash가 일치해야 하며, callback을 생략한 채 과거 map 없는 cache를 새 계약으로 인정하지 않는다.

기존 `getPlpData()` 호출과 `savePlpData()` 사이에 들어갈 코드의 형태는 다음과 같다. callback은 TabEHR가 만든 exact map 경로·surrogate map·검증 함수를 포함하며, 계약을 충족하지 못하면 error를 전파한다.

```r
# extractPlpData(..., plpDataPostprocessor = NULL)의 기존 추출 직후
if (!is.null(plpDataPostprocessor)) {
  if (!is.function(plpDataPostprocessor)) stop("Expected a postprocessor function")
  plpData <- plpDataPostprocessor(plpData)
}
PatientLevelPrediction::savePlpData(plpData, folder)
```

`metadata/plp_person_map.csv.gz`는 exact person↔surrogate, `metadata/plp_instance_map.csv.gz`는 task/sample↔extraction/rowId/index 연결을 저장한다. `sample_id`는 data run과 원래 cohort 행을 명시하는 규칙으로 생성하고, 재추출 후 rowId가 같다는 이유만으로 과거 예측을 재사용하지 않는다. person·sample·record 키는 Python에서도 문자열이다.

### 3.6 Population·label·partition·fold의 단일 기준

`preparePlpTask(bundle, taskId, partition)`은 다음을 반환한다: 원래 metadata가 있는 PLP population, 정확한 instance map, input manifest, 평가 대상 sample 목록, task-definition hash. 기존 [createOutcomeLabels.R](R/createOutcomeLabels.R)의 population RDS와 label을 기준으로 하며, label·TAR·attrition을 평가 단계에서 기본 설정으로 다시 정의하지 않는다.

data run의 task·population·observation window·source snapshot이 일치하지 않으면 재사용을 거부한다. 새 기관의 local target/outcome ID가 달라도 명시적 task mapping과 정의 hash로 연결한다. `death7`과 원내 사망, 같은 outcome의 7일과 30일 label은 다른 task다.

현재 pretrain train / pretrain valid / downstream 분할은 그대로 유지한다. downstream train/valid/test는 제2장의 `patient_partitions.csv` 또는 외부에서 지정한 partition을 사용하며, 같은 환자의 반복 입원·다른 task는 같은 배정을 갖는다. 기관 간 person ID 문자열이 같다는 이유만으로 같은 환자로 연결하지 않는다.

PLP 6.7.0의 `createExistingSplitSettings()`는 `rowId, index`를 받고 음수 index를 test, 양수를 training fold로 사용한다. `createManifestSplitSettings()`는 exact person partition을 각 task의 rowId로 확장하여 이 설정을 만든다. legacy profile은 동등한 custom splitter로 검증한다. **PLP fold는 별도의 고정 validation set과 동일하지 않다.** valid를 test에 합치거나 index 0을 validation으로 해석하지 않는다. 고정 valid는 개발 executor에서 별도 유지한다. [분할 구현](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/DataSplitting.R)

source training 통계, pretraining 기록, anchor pool, few-shot support는 각기 membership을 선언한다. 외부 query label은 평가에만 전달하며, support를 사용하는 실험은 support/query와 그 정답 접근 범위를 별도로 기록한다. 현재 내부 분할의 비중·환자 선정 기준을 PLP 기본값으로 바꾸지 않는다.

### 3.7 Sequence·tabular adapter와 feature 계약

공통 처리 순서는 **대상 instance 선택 → task cutoff/availability/domain 적용 → 허용된 전처리 artifact 적용 → 모델별 표현 생성 → 예측**이다. 사건 집계는 cutoff 뒤의 기록을 제거한 후 수행한다. `allrecords`에 전체 환자·전체 이력이 있다는 이유로 후속 모델이 그 전부를 읽도록 하지 않는다.

| 표현 | adapter의 작업 | 연결 모듈의 검사 |
| --- | --- | --- |
| Sequence | concept/vocabulary mapping, timestamp 기반 순서·동률 처리, age/static, tokenizer, truncation, padding/mask | input 사건·순서 규칙·OOV·truncation 건수와 sample 일치. 환자/visit ID는 predictor 제외 |
| 통계 기반 tabular | 선언한 시간 구간별 count/min/max/mean/last 등, 단위 변환, 결측 indicator | feature 이름·열 순서·단위·window·aggregation version 및 적합 집합 |
| Frozen embedding | 고정 encoder로 instance별 vector 생성 | encoder·vocabulary hash, 출력 차원·순서, encoder를 적합한 환자 범위 |
| TabEHR 논문 profile | 단위·범위 처리 → source training 정규화 → 일/기하 bin → count·last·min·max·recency·coverage 선택 → 모델 encoding/aggregation | 논문 설정을 선택한 경우 `δ = 0.5`, `L = 512` 등 명시. 다른 모델의 기본값으로 강제하지 않음 |

TabEHR의 time scale을 lookback cutoff로 해석하지 않는다. concept embedding, anchor 구성 및 aggregator/TFM 학습은 외부 구현이다. 공통 package는 이들의 입력·fit pool·artifact version 연결만 검증한다. 수치 channel을 가진 모델이 categorical measurement를 자동 지원한다고 가정하지 않고, 지원·누락 정책을 model spec에 남긴다.

`buildPlpCovariateData(features, instanceMap, featureMap)`은 `covariates(rowId, covariateId, covariateValue)`, `covariateRef`, `analysisRef`를 생성한다. `featureMap`은 `feature_key, columnId, covariateId, analysisId, value_type, unit, window, aggregation, missing_policy, representation_hash`를 보존한다. embedding dimension은 임상 concept ID로 위장하지 않는다. feature ID 충돌·중복 row/feature·열 순서 변경을 거부하고, test·외부 기관에서는 학습 시 map을 그대로 적용한다.

희소 행렬의 생략된 값 0과 관측값 0·미측정은 구분한다. imputation/mask는 모델의 학습 계약을 따르고, `missingMeansZero` 표기만으로 결측 처리가 구현됐다고 보지 않는다. 모델 전처리를 적용한 feature에 PLP 기본 normalize·희귀 변수 제거를 다시 적용하지 않도록 명시적으로 설정한다. 원사건이나 가변 길이 sequence를 `toSparseM()`에 넣어 시간 구조가 유지된다고 가정하지 않는다. 전체 cohort의 dense 변환 대신 batch·메모리 제한을 사용한다.

### 3.8 Python 호출·학습·추론 요청 계약

기본 backend는 별도 Python 프로세스로 제안한다. R/PLP와 PyTorch·Keras·TFM 환경을 분리하고, 모델별 interpreter/module과 환경 lock을 등록한다. `reticulate`도 선택 지원하되 한 R 세션에서 서로 다른 Python 환경을 자유롭게 전환할 수 있다고 가정하지 않는다. import-only 모드는 Python 의존성이 필요 없다.

`callFoundationRunner()`는 요청 JSON 파일과 출력 디렉터리를 전달한다. `inst/python/tabehr_bridge/runner.py`는 등록된 adapter의 `prepare_inputs(request)`, 선택 `fit(request)`, `predict(request)`를 호출한다. Python reader는 schema의 문자열 dtype을 강제하며 전체 CSV를 무조건 메모리에 올리지 않는다. 실행 파일과 인수는 분리해 전달하고, 종료 코드·stderr·timeout·응답 manifest를 검사한다. 실패한 프로세스의 오래된 예측 파일을 성공 결과로 읽지 않는다.

| 요청/응답 | 필수 내용 |
| --- | --- |
| 요청 식별 | `request_id`, `data_run_id`, `taskId`, `modelId`, 실행 mode·partition·fold, 허용 sample 목록 hash |
| 데이터 참조 | input shard/reader manifest, static 파일, schema·task-definition hash; prediction 요청에는 query label 경로를 전달하지 않음 |
| 모델 참조 | checkpoint·head·vocabulary·feature map·정규화 artifact manifest, adapter/environment version |
| fit 전용 | 허용 train/fold 및 valid/support의 별도 목록·label, seed, 학습 설정·artifact 목적지. test/query 정답은 제외 |
| 예측 응답 | `(taskId, sample_id, probability)`와 model/run manifest. positive class·출력 scale·partition·건수·checksum |
| 실행 상태 | `started/completed/failed`, 사용한 artifact hash, stage별 시간·batch/coverage, 구조화된 오류 |

원시 logit이나 class label을 확률로 암묵 변환하지 않는다. 이진 확률은 등록한 positive class에 대한 유한한 `[0,1]` 값이어야 한다. logit 변환이 필요한 모델은 adapter에 명시한다. 다중 task 모델도 task별 head와 예측 key를 구분한다. few-shot 반복 실험은 `episode_id/repeat_id/seed`를 별도 보존하고 동일 sample의 반복 예측을 독립 환자 행으로 합치지 않는다.

### 3.9 외부 예측 import와 PLP prediction 객체

`importFoundationPredictions()`는 한 task·model·partition·반복 단위로 처리한다. 다음 예시는 핵심 연결 로직의 **설계 코드**이며 `preparePlpTask()`, `readPredictionCsv()`, `assertSameKeys()`는 신규 구현 대상이다.

```r
importFoundationPredictions <- function(task, predictionFile, evaluationType) {
  p <- readPredictionCsv(predictionFile)  # taskId/sample_id는 문자열
  assertSameKeys(p, task$instanceMap, keys = c("taskId", "sample_id"))
  if (anyDuplicated(p$sample_id)) stop("Duplicate prediction key")
  if (!is.numeric(p$probability) ||
      any(!is.finite(p$probability)) ||
      any(p$probability < 0 | p$probability > 1)) {
    stop("Expected finite positive-class probabilities in [0, 1]")
  }
  # task는 단일 task이며 instanceMap 순서는 population 순서와 검증돼 있다.
  position <- match(task$instanceMap$sample_id, p$sample_id)
  if (anyNA(position)) stop("Missing predictions")
  prediction <- task$population
  prediction$value <- p$probability[position]
  prediction$evaluationType <- evaluationType
  metadata <- attr(prediction, "metaData")
  if (is.null(metadata)) metadata <- list()
  metadata$modelType <- "binary"
  attr(prediction, "metaData") <- metadata
  prediction
}
```

이 함수 전후에 manifest의 task·model·partition·source·positive class를 검증하고, `outcomeCount`, `timeAtRisk`, `survivalTime`, demographic 및 원래 population metadata를 보존한다. prediction 파일에 label 열이 있어도 정답의 기준으로 쓰지 않는다. label은 data run의 task population에서 가져온다. exact map 없는 과거 CSV를 순서나 반올림된 ID로 연결하지 않는다.

기본 coverage는 선언한 평가 instance의 100%다. 입력이 없는 instance도 population에서 제거하지 않는다. 모델이 이를 처리하지 못하면 명시적 실패 또는 사전에 정한 제외 정책·attrition을 기록한다. 모델마다 실패한 행을 자동으로 버려 서로 다른 분모의 성능을 동일 benchmark로 비교하지 않는다. 공통 평가 subset이 필요하면 prediction 결과를 보기 전에 정의·hash를 고정하고 전체 대상 대비 coverage도 보고한다.

### 3.10 PLP native inference와 모델 wrapper

`validate_model`의 native 경로는 `preparePlpTask()`로 준비한 검증된 PLP 객체와 population을 `PatientLevelPrediction::predictPlp()`에 전달한다. `createFoundationPlpModel()`은 task/head, artifact manifest, 전처리와 예측 함수 정보를 가진 `plpModel`을 만든다. events adapter는 Python에서 원사건을 읽고, features adapter는 확정된 feature map을 사용한다.

PLP 6.7.0에서는 `modelDesign$modelSettings$settings$predict`에 `TabEHR::predictFoundation`을 연결할 수 있다. 6.0.0은 `predictionFunction` attribute의 문자열을 사용하는 경로이므로 compatibility helper가 해당 형태를 만든다. `attr(plpModel, "modelType") <- "binary"`도 설정한다. PLP가 예측 후 metadata를 다시 기록하므로 prediction 결과에만 modelType을 넣는 것으로 끝내지 않는다. [6.7.0 predict 코드](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/Predict.R), [6.0.0 predict 코드](https://github.com/OHDSI/PatientLevelPrediction/blob/v6.0.0/R/Predict.R)

핵심 adapter의 설계는 다음과 같다. context 구성·runner·import 함수는 신규 구현 대상이다.

```r
predictFoundation <- function(plpModel, data, cohort) {
  context <- resolvePredictionContext(
    plpData = data,
    population = cohort,
    modelSpec = plpModel$model
  )
  response <- callFoundationRunner(context$inferenceRequest)
  importFoundationPredictions(
    task = context$task,
    predictionFile = response$predictionFile,
    evaluationType = context$evaluationType
  )
}
```

`resolvePredictionContext()`는 **이번 평가 기관의 data run과 전달된 cohort**에서 입력을 해석한다. 학습 모델 artifact에 저장된 원래 기관의 절대 데이터 경로를 재사용하지 않는다. runtime context는 `plpData$metaData$tabehr`와 검증된 manifest로 연결하고, 모델 artifact에는 데이터 계약·학습 provenance만 둔다.

PLP의 `splitData()`는 새 객체를 구성하므로 사용자 정의 metadata가 자동 보존된다고 가정하지 않는다. 선택 executor가 Train/Test/valid 객체에 필요한 context를 명시적으로 연결하고, `fitFoundationPlp()`는 전달된 labels/folds의 sample만 읽는다. `toSparseM()`를 쓰는 features 경로는 `originalRowId`와 원래 rowId를 검증해 복원한다. events 경로는 시간 정보가 사라지는 기본 행렬 변환을 사용하지 않는다.

이미 모델이 처리한 입력에는 PLP의 tidy/normalize를 중복 적용하지 않는다. events 모델의 `covariateImportance`나 `covariateSummary`를 임의 임상 feature 중요도로 채우지 않으며, 지원하지 않는 항목은 상태와 이유를 표시한다. 기존 PLP 함수의 옵션·객체 요구를 만족하는지는 profile별 통합 테스트로 확인한다.

### 3.11 개발·head 학습·fine-tuning 실행 경로

`develop_model`은 명시적으로 요청한 경우에만 실행한다. `setFoundationModel()`은 PLP `modelSettings`와 연결된 model spec을 만들고, `fitFunction`을 `TabEHR::fitFoundationPlp`로 지정한다. 이 함수는 `trainData, modelSettings, hyperparameterSettings, analysisId, analysisPath`를 받아 PLP가 요구하는 model·prediction·modelDesign·trainDetails·preprocessing을 반환한다. standard classifier용 기본 sparse 변환이 sequence 입력에 적용되지 않게 한다. [fit 확장점](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/Fit.R)

두 개발 절차를 구분한다.

- **PLP가 fold·튜닝을 관리하는 feature 모델:** 고정 feature 계약과 기존 partition에서 PLP 개발 함수를 사용한다. `plpData$population`을 준비된 population으로 지정하고, existing/custom split, preprocessing 및 실행 옵션을 명시한다. 기본 `runPlp()` 설정에 맡겨 대상자·분할·feature가 달라지지 않게 한다.
- **외부 trainer가 epoch·support/query·튜닝을 관리하는 foundation model:** `fitFoundationPlp()`가 허용된 train/fold/valid만 전달하고 trainer가 학습을 수행한다. PLP executor는 artifact·예측·평가를 관리한다. `tuningOwner`를 기록하고 PLP grid search와 외부 trainer의 탐색을 의도 없이 중복하지 않는다.

고정 train/valid/test protocol에서는 train 내부 적합 → valid로 선택/early stopping·필요한 calibration → 설정·artifact 고정 → test 평가 순서를 따른다. train+valid 재학습을 사용할 경우 미리 정의한 protocol로 기록한다. source에서 고정된 pretrained encoder의 전처리와 이번 task의 train에서 새로 적합하는 전처리를 구분한다.

CV를 보고할 때는 imputer·scaler·feature 선택·학습 가능한 encoder/head를 **해당 training fold에서만** 적합한다. PLP의 feature engineering이 전체 training 부분집합에 먼저 적용된다는 사실만으로 fold 내부 누수가 방지됐다고 보지 않는다. 학습이 필요한 변환은 fold callback 안으로 옮기거나, 별도 개발 집합에서 이미 고정된 변환을 적용한다. 외부 query/test에서 통계를 새로 적합하는 동작은 기본 지원하지 않는다.

`runPlp()` 하나에 모든 단계를 넣는 것을 완료 조건으로 삼지 않는다. 고정 valid·few-shot protocol은 `splitData()/fitPlp()/predictPlp()/evaluatePlp()`를 명시적으로 조합하는 `executePlp()`에서 보존한다. 6.7.0의 `runPlp()`는 사전 population을 사용할 수 있으나, native 개발 지원은 동일 대상·라벨·분할이 유지되는 회귀 테스트를 통과한 경로만 공개한다. [runPlp 구현](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/RunPlp.R)

보고서에는 frozen model validation, frozen encoder + 새 head, fine-tuning, 외부 기관의 별도 adaptation을 구분한다. 외부 label로 fine-tuning한 뒤 같은 환자에서 평가한 결과를 독립 외부 검증으로 표시하지 않는다. checkpoint만 읽었다고 task별 예측 능력이 준비됐다고 간주하지 않는다.

### 3.12 평가 결과, 반복 관측과 실패 상태

`evaluateFoundationPredictions()`는 검증된 prediction을 `PatientLevelPrediction::evaluatePlp()`에 전달한다. task별 평가 통계, threshold·calibration·demographic summary와 예측 분포를 저장하고, task/model/partition/seed/episode와 분모·양성 수를 붙인다. 이진 판별·calibration·하위군 비교는 같은 task 정의와 평가 대상에서 수행한다. [공식 평가 API](https://ohdsi.github.io/PatientLevelPrediction/reference/evaluatePlp.html)

PLP 6.7.0의 evaluator는 binary/survival을 검사하며 상수 예측을 거부한다. 일부 summary 오류는 NULL로 반환할 수 있다. wrapper는 함수가 반환했다는 사실만으로 모든 평가가 성공했다고 표시하지 않는다. `empty_population`, `single_class`, `constant_predictions`, `metric_failed`, `unsupported`, `failed`, `complete`를 구분하고 해당 metric의 계산 가능 여부를 기록한다. 계산 불가 결과를 0이나 성공으로 대체하지 않는다. [평가 코드](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/EvaluatePlp.R)

같은 환자의 반복 입원은 서로 독립적인 환자 표본이 아니다. 기본 보고서는 episode 수와 unique person 수를 모두 표시한다. 신뢰구간·모델 간 차이 검정을 추가할 경우 patient 단위 재표집/묶음을 사용하며, PLP가 제공한 행 단위 통계에 임의로 환자 단위 보장을 붙이지 않는다. 작은 표본이나 한 class만 있는 task는 평가 불가 상태를 남기고 다른 task 결과와 분리한다.

현재 phenotype은 task별 이진 평가를 우선 제공한다. micro/macro multi-label 요약이나 support/query 반복 요약을 추가하면 task·환자·반복에 대한 집계 단위와 가중치를 별도로 명시한다. 반복 예측을 복제 환자로 합쳐 표본 수를 늘리지 않는다. cutoff·추적 기간·기존 task의 관찰 가능성 규칙은 데이터 manifest를 따르며, 평가 함수에서 조용히 바꾸지 않는다.

### 3.13 PLP 산출물과 모델 저장·복원

데이터 run은 읽기 기준으로 두고, PLP 결과는 독립 `outputFolder` 아래에 저장한다. 호출자가 최종 analysis 폴더를 지정하며, `analysisId`는 manifest에도 기록한다. 같은 data run을 여러 모델이 재사용할 수 있으며, 모델 변경만으로 CDM 추출을 다시 수행하지 않는다. 아래는 제안 구조다.

```text
<plpOutputFolder>/
  analysis_manifest.json
  settings/
    plp_settings.json
    model_registry.json
  shared/
    task_manifest.json
    partition_manifest.json
  <taskId>/<modelId>/<runId>/
    instance_map.csv.gz
    population.rds
    split_ids.csv.gz
    request.json
    prediction.csv.gz
    prediction.rds
    evaluation.rds
    evaluation_summary.csv
    coverage.csv
    status.json
    model_bundle/
      manifest.json
      model_spec.json
      artifacts/
      feature_map.csv
      preprocessing/
      environment/
    logs/
```

import-only는 model bundle을 필수로 복제하지 않고 외부 prediction provenance를 저장한다. native 개발/검증은 checkpoint·head·tokenizer/vocabulary·scaler/imputer·feature map·adapter 코드 version·환경 lock의 hash를 가진 bundle을 요구한다. 해당 모델에 없는 파일은 manifest에 absent/not-applicable로 표시한다. 학습 instance 목록 자체와 공유 가능한 학습 provenance를 구분한다.

`saveFoundationBundle()/loadFoundationBundle()`은 Python live object를 단순 RDS로 저장하지 않고 파일 artifact와 JSON 명세를 저장·검증한다. 상대 경로를 사용하고 새 R/Python 세션·다른 폴더에서 복원한 예측이 같은지 검사한다. hash가 맞는 artifact는 복사 또는 검증된 참조로 재사용할 수 있다.

PLP 6.7.0은 custom save/load 함수와 `saveType = "file"` 경로를 제공하지만 후자는 중첩 artifact 디렉터리 전체가 보존된다는 보장이 아니다. `R/PlpArtifacts.R`의 serializer를 profile에 연결하고 재귀 파일 목록·checksum을 검증한다. `modelDesign`, preprocessing, `modelType`, 예측 함수 식별자도 복원한다. PLP의 일반 save/load가 임의 추가 field를 모두 보존한다고 가정하지 않는다. [저장 구현](https://github.com/OHDSI/PatientLevelPrediction/blob/c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b/R/SaveLoadPlp.R)

cache fingerprint는 data/input/task·population/partition·model/adapter/environment·fit scope·정규화/feature map·실행 mode·seed/episode를 포함한다. 완료된 응답·예측·필수 평가 상태를 검증한 경우만 resume한다. model fit cache를 다른 fold에 재사용하지 않는다. 파일은 `.partial`→검증→rename, 묶음 완료는 마지막 manifest로 기록한다. D 저장 경로는 설정으로 받고 Windows/Linux 경로 대응과 실제 용량은 실행 전 샘플에서 확인한다.

`savePlpShareable()` 연동은 해당 버전의 결과 schema에 맞춰 평가 요약만 구성한다. 내부 population·person map·예측 파일을 공유 산출물에 무조건 포함하지 않는다. 임의의 빈 `plpResults`를 만들어 전체 PLP 결과가 생성되었다고 표시하지 않는다.

### 3.14 기존 파일별 코드 수정 사항

아래는 제3장을 구현할 때의 변경 목록이다. 이 문서 개정에서 실제 코드 파일을 변경하는 목록이 아니다.

| 기존 파일 | 수정할 내용 | 호환·검증 조건 |
| --- | --- | --- |
| [R/Main.R](R/Main.R) | 선택 `plpSettings = NULL`, `plpOutputFolder = NULL`을 끝에 추가하는 편의 연결. data manifest 검증 후 설정이 있을 때만 `executePlp()` 호출 | 기본 호출은 기존 data-only. 데이터 오류 후 모델 실행 금지. 독립 `executePlp()`도 제공 |
| [R/TaskInput.R](R/TaskInput.R) | mapped covariate wrapper·PLP postprocessor 전달, exact map으로 `.taskRowsForExtraction()` 교체, sample/task key와 input signature 연결 | double 변환 제거. 기존 task별 domain·window 및 빈 입력 instance 유지 |
| [R/createOutcomeLabels.R](R/createOutcomeLabels.R) | 저장 전 PLP identity 검증, exact person/sample key export, metadata가 있는 population과 label을 같은 manifest에 등록 | `outcomeCount`, TAR, attrition 및 38개 task 의미 보존. 빈 task도 상태 파일에 남김 |
| [SparseArray/R/extractPlpData.R](SparseArray/R/extractPlpData.R) | `plpDataPostprocessor = NULL` callback, map을 포함한 cache 검사, postprocess 이후 저장 | 기본 인수 유지. SparseArray→TabEHR 의존성 추가 금지. 실패 cache 완료 처리 금지 |
| [R/StudySettings.R](R/StudySettings.R) | PLP version profile에 맞는 population settings 검증, task-definition hash와 model experiment 설정 연결 | `riskWindowStart/End`, anchor·exclusion 기본값을 업그레이드로 변경하지 않음 |
| [R/SettingsObjects.R](R/SettingsObjects.R) | data 설정과 PLP 실행 설정의 schema version을 분리하고 선택 PLP 참조만 허용 | 모델 hyperparameter를 데이터 추출 fingerprint에 무조건 섞지 않음 |
| [R/PersonSplit.R](R/PersonSplit.R), 제2장 신규 `R/PatientPartitions.R` | exact person partition 및 fold 연결용 reader, 역할·교집합 검사 제공 | 현재 70:15:15 알고리즘·seed 유지. downstream 세부 배정은 명시적 import/생성 |
| [R/Export.R](R/Export.R), 제2장 신규 `R/RunManifest.R`·`R/Cache.R` | data run ID, PLP map·population 경로/hash, 공통 완료·cache API 제공 | PLP 실행마다 원래 data manifest를 덮어쓰지 않음 |
| [R/Diagnostics.R](R/Diagnostics.R) | data validation과 PLP integration validation 분리; 실행 계획별 필수 파일·coverage·오류 검사 | data-only에서 모델 파일을 요구하지 않음. NULL 평가·누락 task 감지 |
| [extras/CodeToRun.R](extras/CodeToRun.R) | data-only 기본 유지, 별도 PLP runner 사용법 안내 및 명시 설정 시 연결 | 모델 경로가 있다는 이유로 자동 학습하지 않음 |
| [tests/testthat/helper-load.R](tests/testthat/helper-load.R) | pure 계약 검증 파일 로드 목록 확장; PLP/DB/Python 의존 테스트는 구분 | 패키지 source 테스트가 Python·GPU를 무조건 초기화하지 않음 |
| [DESCRIPTION](DESCRIPTION), [SparseArray/DESCRIPTION](SparseArray/DESCRIPTION) | 직접 쓰는 FeatureExtraction·hash 의존성 명시, 선택 Python backend 의존성을 Suggests로 관리, profile별 PLP pin 일치 | 검증 후 release version 변경. 선언상 `>= 6.0.0`만으로 모든 중간 버전 호환을 주장하지 않음 |
| [NAMESPACE](NAMESPACE), `man/` | 신규 공개 함수와 custom callback의 roxygen export·문서 생성 | 함수 이름·인수·예시·반환 계약 일치 |
| [DockerImage/Dockerfile](DockerImage/Dockerfile), [SparseArray/DockerImage/Dockerfile](SparseArray/DockerImage/Dockerfile), [compose.yaml](compose.yaml) | legacy 환경 유지, 신규 PLP profile은 별도 Dockerfile/compose override로 제공 | data image·Andromeda/FE/PLP 조합을 묵시적으로 업그레이드하지 않음 |
| [README.md](README.md), [OUTPUT_DESCRIPTIOM.md](OUTPUT_DESCRIPTIOM.md), [.env.example](.env.example) | 세 모드, 지원 모델 계약·환경 설정, data/PLP 출력·완료 수준과 예제 추가 | 현재 구현과 계획 구분. credentials는 모델 manifest로 export하지 않음 |
| [.gitignore](.gitignore), [.Rbuildignore](.Rbuildignore) | release 시 REVISION/vignette/schema 포함 여부와 model/data artifact 제외를 명시 | 문서를 실제 배포하려면 현재 루트 Markdown 제외 규칙에 필요한 예외 추가. 이번 문서 작업에서는 변경하지 않음 |

`inst/settings/studySettings.json`의 38개 task는 교체하지 않는다. 새 `plpSettings.example.json`과 `modelRegistry.example.json`에서 모델·모드·평가 대상을 지정한다. 선택 model profile이 본 패키지의 임상 task 정의를 덮어쓰지 않게 한다.

### 3.15 PLP·R·Python 버전 및 배포 방안

현재 데이터 환경은 PLP 6.0.0을 고정한다. 참고 Glaucoma 저장소의 `renv.lock`은 PLP 6.6.0을 기록한다. 이번에 확인한 공식 PLP `v6.7.0` tag는 commit `c0c3e5b691399fc4135b4ee4cdfa956ed4f8c21b`다. 후속 native 개발의 목표 profile은 6.7.0으로 제안하되, 설치·DB 회귀 테스트 통과 전 기본 환경을 바꾸지 않는다. [현재 Dockerfile](DockerImage/Dockerfile), [참고 lockfile](https://github.com/ohdsi-studies/GlaucomaPrescreeningPrediction/blob/bd335b7458276d84dba92b382ee5c8719513388c/renv.lock), [공식 6.7.0 release source](https://github.com/OHDSI/PatientLevelPrediction/tree/v6.7.0)

| Profile | 목표 범위 | 공개 조건 |
| --- | --- | --- |
| `legacy-6.0` | 기존 data 생성·population 보존, 우선 prediction import와 평가 연결 | exact ID·38개 task 회귀·평가 계약 검증 |
| `native-6.7` | native Python inference, feature/embedding 연결, 선택 fit·저장·복원 | 버전 고정 환경에서 데이터·모델 연결·외부 적용 테스트 통과 |
| 다른 PLP 버전 | 별도 호환 대상 | 기능 존재 여부만으로 허용하지 않고 신규 profile 검사·fixture 필요 |

`R/PlpCompatibility.R`는 packageVersion과 실제 함수 signature/호출 동작을 검사하고 지원 범위를 넘어가면 명확한 오류를 낸다. 공식 vignette의 설명과 설치된 source가 다르면 고정된 source·테스트를 기준으로 구현한다. `settings$predict`, legacy `predictionFunction`, `fitFunction`, serializer를 한 helper 계층에서 처리한다.

PLP 6.7.0 upgrade는 PLP만 교체하는 작업으로 간주하지 않는다. R, DatabaseConnector, SqlRender, FeatureExtraction, Andromeda 및 선택 reticulate 조합을 lock하고 SQL Server에서 population·label·ID 결과를 대조한다. Python interpreter, NumPy/PyTorch/Keras/TFM package 및 device 설정도 별도 환경 파일로 고정한다. 기본 data image에는 모든 foundation model의 대형 의존성을 일괄 설치하지 않는다.

환경 설치 성공, 모델 load 성공, inference 성공, task 평가 성공, 독립 외부 검증 성공을 각각 기록한다. 모델 다운로드나 checkpoint 경로 지정만으로 실행 완료를 표시하지 않는다.

### 3.16 테스트와 통합 검증의 합격 조건

아래 파일은 신규 테스트 계획이다. 작은 인공 fixture로 계약을 먼저 검증한 뒤, 제2장의 검증된 샘플·전체 run으로 확대한다. 테스트용 adapter의 성공을 실제 foundation model의 성능 검증으로 해석하지 않는다.

| 제안 테스트 파일 | 검증 내용·합격 기준 |
| --- | --- |
| `tests/testthat/test-plp-settings.R` | 모드별 필수 인수·지원 버전·model/task capability 검사. import-only가 Python 없이 실행 가능 |
| `test-plp-identity.R` | `2^53` 경계·음수 BIGINT·반올림 충돌 fixture에서도 정확한 환자/row 매핑. SQL 임시 cohort 수명·custom wrapper 재귀·위임 반환 확인 |
| `test-plp-population.R` | 저장 population metadata·라벨·TAR 유지, task 간 rowId 재사용·반복 입원·빈 입력 처리, 원래 38개 task 회귀 |
| `test-plp-splits.R` | 동일 환자의 모든 task/입원이 같은 partition/fold. valid/test 혼합·미배정·겹침 차단 |
| `test-plp-features.R` | 두 검사값의 min/max/mean/count, mixed unit·결측/0, frozen embedding 차원, 안정된 feature/column map |
| `test-plp-prediction.R` | 예측 행을 섞어도 같은 연결. 누락/중복/잘못된 task·partition·artifact 및 NaN/Inf/범위 밖 확률 거부 |
| `test-plp-evaluation.R` | 동일 prediction의 직접 `evaluatePlp()`와 wrapper 결과 일치. empty/single-class/constant/NULL summary 상태 구분 |
| `test-plp-python.R`, `tests/python/test_runner_contract.py` | 문자열 ID 왕복, 허용 sample만 전달, query label 미전달, nonzero/timeout/잘린 응답/오래된 출력 감지 |
| `test-plp-model.R` | 직접 Python inference와 PLP 경유 inference가 사전 선언한 수치 허용오차 안에서 일치. sample·task·class 방향은 정확히 일치 |
| `test-plp-artifacts.R` | 새 세션·다른 폴더로 bundle 이동 후 예측 일치. 중첩 파일·vocabulary·head·scaler·hash 누락 탐지 |
| `test-plp-main.R` | 중단·resume 및 task×model 상태 보존. 데이터 실패 후 추론 금지, fit cache의 fold 간 잘못된 재사용 금지 |
| profile별 통합 실행 | PLP 6.0과 6.7의 대상/라벨/평가 동등성 또는 의도된 차이를 명시. silent drift는 실패 |

실모델 연결의 최소 합격 범위는 **sequence 모델 1개와 tabular 모델 1개**다. 각 모델에 대해 직접 Python 경로와 PLP 경로의 동일 입력·동일 checkpoint·동일 sample별 예측을 비교하고, 동일 task의 평가 결과까지 확인한다. 모델/adapter/환경/지원 task 범위를 문서에 기록한다. 특정 두 모델의 통과를 모든 EHR foundation model 지원 완료로 일반화하지 않는다.

새 기관 검증은 별도 data run에서 동일한 task 정책·입력 계약을 적용하고, source의 vocabulary/feature map/정규화/checkpoint를 고정하여 수행한다. 기관별 calibration/adaptation 실험은 별도 analysis로 둔다. native 데이터 재추출까지 포함하는 자동 `externalValidateDbPlp()` 연동은 custom raw-event builder를 재호출하는 계약이 추가 검증된 경우에만 지원한다. 기본 외부 경로는 현지 data run 생성 후 `executePlp(validate_model)`이다.

### 3.17 구현 순서와 완료 수준

1. **데이터 계약 선행:** 제2장 P0, exact PLP map, population/sample 연결 및 38개 task 회귀를 확정한다. 기존 결과·split을 검증 없이 덮어쓰지 않는다.
2. **P0 — 예측 import·평가:** 설정·population/map reader·prediction 검증·PLP evaluator·상태/manifest·standalone runner를 구현한다. Python 모델 실행과 독립적으로 평가 연결을 검증한다.
3. **P1 — 추론·feature·artifact:** Python runner, sequence/tabular reference adapter, `CovariateData` 변환, `predictFoundation`, 저장/복원을 구현한다. 실제 두 종류 모델의 inference 동등성을 검증한다.
4. **P2 — 개발·fine-tuning:** 고정 partition과 fold 내 전처리, custom fit, frozen/head/fine-tuning 구분, hyperparameter/early-stopping 및 재현 가능한 학습 기록을 구현한다.
5. **확대 검증·배포:** 샘플→선택 task 전체→등록된 38개 task 중 모델이 지원하는 모든 조합→외부 기관 순으로 검증한다. unsupported/empty/실패 조합을 모두 보고하고 지원 matrix와 실행 예제를 배포한다.

| 완료 상태 | 주장할 수 있는 범위 |
| --- | --- |
| `data_validation = passed` | 공통 기록·task input·label·split 계약을 검증함 |
| `prediction_import_validation = passed` | 외부 예측을 정확한 population에 연결하고 PLP 평가를 수행함 |
| `plp_integration_validation = passed` | 명시한 모델·adapter·환경에서 직접 Python과 PLP 호출의 동등성을 검증함 |
| `model_development_validation = passed` | 지정한 개발 protocol에서 학습·저장·복원·평가를 검증함 |
| `external_validation = complete` | 지정한 외부 기관·task·평가 집합에서 frozen 또는 별도로 표시한 adaptation 평가를 완료함 |

전체 PLP pipeline 구축은 P0–P2 중 공개한 기능의 합격 조건을 충족하고, 모델별 지원 범위가 문서·schema·테스트와 일치하는 상태를 뜻한다. 성능이 높다는 주장과 연결 코드가 정확하다는 주장은 구분한다. 저장량·GPU 요구·ETA는 사용할 모델과 샘플에서 측정하며, 기존 R 데이터 추출 시간으로 추정하지 않는다.

### 3.18 검토 근거와 이번 문서 변경의 범위

이 장의 근거는 3.2절의 Glaucoma snapshot, OHDSI PLP 6.0.0·6.7.0의 추출/분할/fit/predict/evaluate/save 소스, 현재 TabEHR의 함수·설정·Dockerfile이다. 공개 소스는 고정 commit/tag 링크로 기록했고, 현재 PLP 6.7.0 tag와 commit의 대응을 확인했다. 사용자 정의 모델·분할의 공식 설명은 [custom models](https://ohdsi.github.io/PatientLevelPrediction/articles/AddingCustomModels.html), [custom splitting](https://ohdsi.github.io/PatientLevelPrediction/articles/AddingCustomSplitting.html), [기존 sklearn 모델 연결](https://ohdsi.github.io/PatientLevelPrediction/reference/createSklearnModel.html)을 참고한다. sklearn 연결 기능을 임의의 sequence/PyTorch 모델 자동 지원으로 해석하지 않는다.

**이번 작업은 `REVISION.md`의 구조와 구현 계획을 수정한 문서 작업이다. 제1장의 본문·코드·검증 기록은 보존하고, 제2장은 data pipeline 중심으로 정리했으며, 제3장에 PLP 확장과 파일·코드 수정 방안을 추가했다.** 위 신규 R/Python/SQL/설정/테스트 파일은 아직 만들지 않았고, DB 재추출·PLP 설치 변경·모델 실행·학습·성능 평가도 수행하지 않았다. 원본 `REVISON.md`, `FUTURE_PLAN.md`와 기존 코드·산출물은 이번 작업의 변경 대상이 아니다.

현재 `.gitignore`는 루트 Markdown을 기본 제외하므로 `REVISION.md`도 Git 추적에서 제외된다. 실제 기능 release에 문서를 포함할 때 3.14절의 예외 설정을 적용해야 한다. 문서만 저장된 상태를 구현 또는 배포 완료로 표시하지 않는다.

