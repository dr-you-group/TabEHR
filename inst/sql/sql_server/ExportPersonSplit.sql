-- The split as the database holds it, used to confirm the CSV written by R and
-- the table in the database agree row for row.
SELECT CAST(S.person_id AS VARCHAR(20)) AS person_id,
       S.stage,
       S.split,
       S.split_seed
FROM @person_split_table S
ORDER BY S.person_id;
