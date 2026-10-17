-- Numeric measurement rows whose (concept, unit) pair has no row in the
-- quantile table. Those keep the bare concept_id, see AllRecords.sql. At the
-- primary site this is a pair that only pretraining-excluded patients have; at
-- an external site it is a pair missing from the primary site's table.
SELECT COUNT(*) AS n_numeric_row,
       SUM(CASE WHEN Q.measurement_concept_id IS NULL THEN 1 ELSE 0 END) AS n_row_without_quantile,
       COUNT(DISTINCT CASE WHEN Q.measurement_concept_id IS NULL
                           THEN CONCAT(CAST(H.measurement_concept_id AS VARCHAR(20)), '|', CAST(H.unit_concept_id AS VARCHAR(20)))
                      END) AS n_pair_without_quantile
FROM @measurements_table H
INNER JOIN @study_population_table SP
  ON H.person_id = SP.person_id
LEFT JOIN @meas_quantiles_table Q
  ON Q.measurement_concept_id = H.measurement_concept_id
  AND Q.unit_concept_id = H.unit_concept_id
WHERE H.is_numeric = 1;
