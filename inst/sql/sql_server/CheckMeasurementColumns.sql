-- The measurement columns the port depends on, and how often each one costs
-- records.
--
-- n_null_datetime            dropped: the original never falls back to
--                            measurement_date  [OPEN_QUESTIONS C3]
-- n_null_value_source        dropped: value_source_value decides whether a
--                            measurement becomes a record at all
-- n_value_source_without_number
--                            kept, but as a bare concept_id with no bin: the
--                            record exists and value_as_number is NULL
-- n_numeric_unmapped_unit    dropped: a numeric value whose unit_concept_id is
--                            0 or NULL  [OPEN_QUESTIONS C1]. FeatureExtraction
--                            keeps these as an "Unknown unit" covariate, so
--                            such a covariate has no token on this side
-- n_null_unit_concept_id /
-- n_zero_unit_concept_id     which convention this CDM uses for an unmapped
--                            unit
{DEFAULT @person_sample_table = ''}
SELECT COUNT(*) AS n_row,
       SUM(CASE WHEN M.measurement_datetime IS NULL THEN 1 ELSE 0 END) AS n_null_datetime,
       SUM(CASE WHEN M.value_source_value IS NULL THEN 1 ELSE 0 END) AS n_null_value_source,
       SUM(CASE WHEN M.value_as_number IS NULL THEN 1 ELSE 0 END) AS n_null_value_as_number,
       SUM(CASE WHEN M.value_source_value IS NOT NULL AND M.value_as_number IS NULL
                THEN 1 ELSE 0 END) AS n_value_source_without_number,
       SUM(CASE WHEN M.value_as_number IS NOT NULL AND COALESCE(M.unit_concept_id, 0) = 0
                THEN 1 ELSE 0 END) AS n_numeric_unmapped_unit,
       SUM(CASE WHEN M.unit_concept_id IS NULL THEN 1 ELSE 0 END) AS n_null_unit_concept_id,
       SUM(CASE WHEN M.unit_concept_id = 0 THEN 1 ELSE 0 END) AS n_zero_unit_concept_id,
       SUM(CASE WHEN M.unit_source_value IS NULL THEN 1 ELSE 0 END) AS n_null_unit_source_value,
       COUNT(DISTINCT M.measurement_concept_id) AS n_concept
FROM @cdm_database_schema.measurement M
WHERE 1 = 1
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = M.person_id)}
;
