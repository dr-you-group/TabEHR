-- cohort_counts_restricted.csv: what is in the cohort table after the target
-- cohorts were restricted to the downstream patients.
SELECT C.cohort_definition_id,
       COUNT(*) AS n_row,
       COUNT(DISTINCT C.subject_id) AS n_person
FROM @cohort_database_schema.@cohort_table C
GROUP BY C.cohort_definition_id
ORDER BY C.cohort_definition_id;
