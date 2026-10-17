-- The study population: every one of the three criteria in CLAUDE.md.
--
--   adult        already applied per record when the record tables were built,
--                so a patient is here only if some adult record survived
--   record count at least @min_record_count de-duplicated records
--   admission    at least one qualifying inpatient admission
--
-- All three are AND, so the order does not change the result. The flow counts
-- are reported separately by StudyPopulationFlow.sql.

IF OBJECT_ID('@study_population_table', 'U') IS NOT NULL DROP TABLE @study_population_table;

CREATE TABLE @study_population_table (
  person_id BIGINT NOT NULL,
  n_records BIGINT NOT NULL,
  n_admissions BIGINT NOT NULL
);

INSERT INTO @study_population_table (person_id, n_records, n_admissions)
SELECT RC.person_id, RC.n_records, AH.n_admissions
FROM @record_counts_table RC
INNER JOIN @admission_history_table AH
  ON RC.person_id = AH.person_id
WHERE RC.n_records >= @min_record_count;
