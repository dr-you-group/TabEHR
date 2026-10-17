-- study_population.csv. person_id leaves the database as text, never as a
-- number, so a 19 digit id keeps every digit in R and in the CSV.
SELECT CAST(SP.person_id AS VARCHAR(20)) AS person_id,
       SP.n_records,
       SP.n_admissions
FROM @study_population_table SP
ORDER BY SP.person_id;
