-- Patient counts for the flow diagram.
--
-- The cumulative steps are the criteria that are actually applied: all
-- patients, then those with an adult record left after the preprocessing, then
-- those with a qualifying inpatient admission when
-- @require_qualifying_admission is 1, then those with enough records, which is
-- the study population  [OPEN_QUESTIONS B3]. The criteria are AND, so the final
-- set does not depend on the order, but the intermediate counts do.
--
-- step_order keeps the same value for the same step whether or not the
-- admission criterion is applied, so two runs can be compared column by column.
-- Step 3 is therefore missing from the table when the criterion is off, and
-- steps 5 to 7 are the single-criterion counts, which say what the admission
-- criterion would have cost had it been applied.

{DEFAULT @person_sample_table = ''}
{DEFAULT @require_qualifying_admission = 0}

SELECT 1 AS step_order,
       'all_persons' AS step,
       COUNT(*) AS n_person
FROM @cdm_database_schema.person P
WHERE 1 = 1
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = P.person_id)}

UNION ALL
SELECT 2 AS step_order,
       'with_adult_record' AS step,
       COUNT(*) AS n_person
FROM @record_counts_table

{@require_qualifying_admission == 1} ? {
UNION ALL
SELECT 3 AS step_order,
       'with_qualifying_admission' AS step,
       COUNT(*) AS n_person
FROM @record_counts_table RC
INNER JOIN @admission_history_table AH
  ON RC.person_id = AH.person_id
}

UNION ALL
SELECT 4 AS step_order,
       'with_min_records' AS step,
       COUNT(*) AS n_person
FROM @study_population_table

UNION ALL
-- Single-criterion counts, all among the patients that have adult records.
SELECT 5 AS step_order,
       'only_record_count_criterion' AS step,
       COUNT(*) AS n_person
FROM @record_counts_table RC
WHERE RC.n_records >= @min_record_count

UNION ALL
SELECT 6 AS step_order,
       'lost_to_admission_only' AS step,
       COUNT(*) AS n_person
FROM @record_counts_table RC
WHERE RC.n_records >= @min_record_count
  AND NOT EXISTS (
    SELECT 1 FROM @admission_history_table AH WHERE AH.person_id = RC.person_id
  )

UNION ALL
SELECT 7 AS step_order,
       'lost_to_record_count_only' AS step,
       COUNT(*) AS n_person
FROM @record_counts_table RC
INNER JOIN @admission_history_table AH
  ON RC.person_id = AH.person_id
WHERE RC.n_records < @min_record_count
;
