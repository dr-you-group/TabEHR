-- Load a quantile table computed elsewhere, normally the primary site's
-- meas_quantiles.csv, so every site bins measurements with the same
-- boundaries. The staging table arrives from R as text only, so nothing is
-- rounded on the way in.
IF OBJECT_ID('@meas_quantiles_table', 'U') IS NOT NULL DROP TABLE @meas_quantiles_table;

CREATE TABLE @meas_quantiles_table (
  measurement_concept_id BIGINT NOT NULL,
  unit_concept_id BIGINT NOT NULL,
  unit_source_value VARCHAR(50) NULL,
  n_unit_source_value INT NULL,
@quantile_column_definitions
  n BIGINT NOT NULL,
  basis VARCHAR(10) NOT NULL
);

INSERT INTO @meas_quantiles_table (measurement_concept_id, unit_concept_id, unit_source_value, n_unit_source_value, @quantile_column_names, n, basis)
SELECT CAST(S.measurement_concept_id AS BIGINT) AS measurement_concept_id,
       CAST(S.unit_concept_id AS BIGINT) AS unit_concept_id,
       S.unit_source_value,
       CAST(S.n_unit_source_value AS INT) AS n_unit_source_value,
@quantile_cast_columns
       CAST(S.n AS BIGINT) AS n,
       'file' AS basis
FROM @staging_table S;
