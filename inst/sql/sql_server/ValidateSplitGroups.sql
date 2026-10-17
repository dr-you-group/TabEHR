-- split_summary.csv as the database sees it.
SELECT S.stage,
       CASE WHEN S.split IS NULL THEN '' ELSE S.split END AS split,
       COUNT(*) AS n_person
FROM @person_split_table S
GROUP BY S.stage, CASE WHEN S.split IS NULL THEN '' ELSE S.split END
ORDER BY S.stage, 2;
