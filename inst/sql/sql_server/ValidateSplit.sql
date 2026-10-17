-- The split invariants: nobody in two groups, the split covers exactly the
-- study population, and the group sizes.
SELECT (SELECT COUNT(*) FROM (
          SELECT person_id FROM @person_split_table GROUP BY person_id HAVING COUNT(*) > 1
        ) D) AS n_person_in_two_groups,
       (SELECT COUNT(*) FROM @person_split_table) AS n_split_row,
       (SELECT COUNT(DISTINCT person_id) FROM @person_split_table) AS n_split_person,
       (SELECT COUNT(*) FROM @study_population_table) AS n_study_population,
       (SELECT COUNT(*) FROM @study_population_table SP
         WHERE NOT EXISTS (SELECT 1 FROM @person_split_table S WHERE S.person_id = SP.person_id)
       ) AS n_population_without_split,
       (SELECT COUNT(*) FROM @person_split_table S
         WHERE NOT EXISTS (SELECT 1 FROM @study_population_table SP WHERE SP.person_id = S.person_id)
       ) AS n_split_outside_population,
       (SELECT COUNT(*) FROM @person_split_table S
         INNER JOIN @downstream_person_table D ON D.person_id = S.person_id
         WHERE S.stage <> '@downstream_stage'
       ) AS n_downstream_from_wrong_stage
;
