-- The study population.
--
--   adult        already applied per record when the record tables were built,
--                so a patient is here only if some adult record survived
--   record count at least @min_record_count de-duplicated records
--   admission    at least one qualifying inpatient admission, and only when
--                @require_qualifying_admission is 1
--
-- The admission criterion is off by default: on MIMIC it removed most of the
-- patients that the other two criteria keep, and a patient level length of stay
-- rule is not what either MedRep's own code or the SparseArray target cohort
-- applies. n_admissions is still reported for every patient, counted the same
-- way, so the criterion can be applied afterwards or reported on without
-- re-running anything. The flow counts are reported separately by
-- StudyPopulationFlow.sql.
--
-- The criteria are AND, so the order does not change the result.

{DEFAULT @require_qualifying_admission = 0}

IF OBJECT_ID('@study_population_table', 'U') IS NOT NULL DROP TABLE @study_population_table;

CREATE TABLE @study_population_table (
  person_id BIGINT NOT NULL,
  n_records BIGINT NOT NULL,
  n_admissions BIGINT NOT NULL
);

INSERT INTO @study_population_table (person_id, n_records, n_admissions)
SELECT RC.person_id, RC.n_records, COALESCE(AH.n_admissions, 0) AS n_admissions
FROM @record_counts_table RC
{@require_qualifying_admission == 1} ? {
INNER JOIN @admission_history_table AH
  ON RC.person_id = AH.person_id
} : {
LEFT JOIN @admission_history_table AH
  ON RC.person_id = AH.person_id
}
WHERE RC.n_records >= @min_record_count;
