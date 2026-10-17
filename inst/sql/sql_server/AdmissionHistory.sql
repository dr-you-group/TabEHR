-- Patients with at least one qualifying inpatient admission.
--
-- CLAUDE.md, "대상 환자": an inpatient visit (@inpatient_concept_ids and, when
-- enabled, their descendants) whose length of stay satisfies
-- DATEDIFF(DAY, visit_start_date, visit_end_date) @length_of_stay_operator
-- @min_length_of_stay, and where the patient was at least @adult_age_min at
-- admission.
--
-- The concept list is built the same way as the SparseArray target cohort in
-- SparseArray/inst/sql/sql_server/Inpatient_visit.sql, including the
-- "invalid_reason IS NULL" filter on the descendants, so the two agree on what
-- counts as an inpatient visit.
--
-- A NULL visit_end_date makes DATEDIFF NULL, so such an admission does not
-- qualify  [OPEN_QUESTIONS D6].

{DEFAULT @person_sample_table = ''}

SELECT concept_id
INTO #inpatient_concept
FROM (
  SELECT concept_id
  FROM @vocabulary_database_schema.concept
  WHERE concept_id IN (@inpatient_concept_ids)

{@include_descendant_visit_concepts == 1} ? {
  UNION
  SELECT C.concept_id
  FROM @vocabulary_database_schema.concept C
  INNER JOIN @vocabulary_database_schema.concept_ancestor CA
    ON C.concept_id = CA.descendant_concept_id
  WHERE CA.ancestor_concept_id IN (@inpatient_concept_ids)
    AND C.invalid_reason IS NULL
}
) I;

IF OBJECT_ID('@admission_history_table', 'U') IS NOT NULL DROP TABLE @admission_history_table;

CREATE TABLE @admission_history_table (
  person_id BIGINT NOT NULL,
  n_admissions BIGINT NOT NULL
);

INSERT INTO @admission_history_table (person_id, n_admissions)
SELECT V.person_id, COUNT(*) AS n_admissions
FROM @cdm_database_schema.visit_occurrence V
INNER JOIN @cdm_database_schema.person P
  ON V.person_id = P.person_id
INNER JOIN #inpatient_concept IC
  ON V.visit_concept_id = IC.concept_id
WHERE DATEDIFF(DAY, V.visit_start_date, V.visit_end_date) @length_of_stay_operator @min_length_of_stay
  AND YEAR(V.visit_start_date) - P.year_of_birth >= @adult_age_min
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = V.person_id)}
GROUP BY V.person_id;

TRUNCATE TABLE #inpatient_concept;
DROP TABLE #inpatient_concept;
