-- How large are the person_id values here, and would rounding them to a double
-- merge two patients?
--
-- 9007199254740992 is 2^53, the largest integer a double represents exactly.
-- n_colliding_groups > 0 means the double route is unusable at this site and
-- every export must stay textual.
{DEFAULT @person_sample_table = ''}
SELECT (SELECT COUNT(*) FROM @cdm_database_schema.person) AS n_person,
       (SELECT CAST(MIN(person_id) AS VARCHAR(20)) FROM @cdm_database_schema.person) AS min_person_id,
       (SELECT CAST(MAX(person_id) AS VARCHAR(20)) FROM @cdm_database_schema.person) AS max_person_id,
       (SELECT COUNT(*) FROM @cdm_database_schema.person
         WHERE person_id > 9007199254740992 OR person_id < -9007199254740992) AS n_beyond_double,
       (SELECT COUNT(*) FROM (
          SELECT CAST(CAST(person_id AS FLOAT) AS BIGINT) AS rounded
          FROM @cdm_database_schema.person
          GROUP BY CAST(CAST(person_id AS FLOAT) AS BIGINT)
          HAVING COUNT(DISTINCT person_id) > 1
        ) C) AS n_colliding_groups
;
