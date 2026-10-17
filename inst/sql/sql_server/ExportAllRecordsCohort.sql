-- The row_id to person_id map, and the index date every record_date is
-- reconstructed from. person_id leaves the database as text, never as a
-- double.
SELECT C.row_id,
       CAST(C.subject_id AS VARCHAR(20)) AS person_id,
       C.cohort_start_date AS index_date,
       C.first_record_date,
       C.last_record_date
FROM @allrecords_cohort_table C
ORDER BY C.row_id;
