-- Is every cohort row inside the downstream patient set?
--
-- n_row_outside_downstream must be 0 for the target cohorts (1000 and 1003).
-- The outcome cohorts are deliberately NOT restricted: an outcome only matters
-- for a patient who is in a target cohort, and leaving them unrestricted keeps
-- the cohort definitions untouched.
SELECT C.cohort_definition_id,
       COUNT(*) AS n_row,
       COUNT(DISTINCT C.subject_id) AS n_person,
       SUM(CASE WHEN D.person_id IS NULL THEN 1 ELSE 0 END) AS n_row_outside_downstream
FROM @cohort_database_schema.@cohort_table C
LEFT JOIN @downstream_person_table D
  ON C.subject_id = D.person_id
GROUP BY C.cohort_definition_id
ORDER BY C.cohort_definition_id;
