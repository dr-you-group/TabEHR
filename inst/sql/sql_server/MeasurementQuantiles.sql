-- The measurement quantile table, computed the way pandas computes it.
--
-- Port of create_trajectory.py lines 155-173. The original calls
--   x.quantile(np.linspace(0, 1, 11))
-- per (concept, unit), which is linear interpolation between order statistics:
-- for probability p and n values sorted ascending,
--   h    = (n - 1) * p
--   value = v[floor(h)] + (h - floor(h)) * (v[floor(h) + 1] - v[floor(h)])
-- with 0-based indexing. This file does exactly that with ROW_NUMBER, which
-- SqlRender translates on every dialect, instead of PERCENTILE_CONT, which it
-- passes through untouched (see MeasurementQuantilesPercentileCont.sql for that
-- variant). The probabilities themselves are rendered as literals by
-- R/MeasurementQuantiles.R, reproduced from the same numpy and pandas
-- arithmetic, so the floating point values match bit for bit
--  [OPEN_QUESTIONS C10].
--
-- The grouping is (measurement_concept_id, unit_concept_id), not the
-- unit_source_value text the original groups by, because unit_concept_id is
-- what the FeatureExtraction covariate_id carries: one covariate_id then
-- resolves to exactly one row here, which is what makes a featureExtractionLong
-- value convertible into an allrecords token. The source text is kept as a
-- descriptive column, with how many distinct texts share the unit.
--
-- @restrict_person_table limits which patients the values come from. Empty
-- means every patient in the records, which is what the original does: it
-- computes the quantiles before it splits the patients, so the basis and the
-- rows being binned are the same set and bin 10 cannot occur.

{DEFAULT @restrict_person_table = ''}

-- The numeric rows the quantiles are computed from.
SELECT H.measurement_concept_id,
       H.unit_concept_id,
       H.value_number
INTO #quantile_source
FROM @measurements_table H
WHERE H.is_numeric = 1
{@restrict_person_table != ''} ? {  AND EXISTS (SELECT 1 FROM @restrict_person_table RP WHERE RP.person_id = H.person_id)}
;

SELECT X.measurement_concept_id,
       X.unit_concept_id,
       X.value_number,
       X.ordinal,
       X.n
INTO #ranked
FROM (
  SELECT S.measurement_concept_id,
         S.unit_concept_id,
         S.value_number,
         ROW_NUMBER() OVER (
           PARTITION BY S.measurement_concept_id, S.unit_concept_id
           ORDER BY S.value_number
         ) AS ordinal,
         COUNT(*) OVER (
           PARTITION BY S.measurement_concept_id, S.unit_concept_id
         ) AS n
  FROM #quantile_source S
) X;

-- One row per (concept, unit) and probability, with the interpolation position.
SELECT G.measurement_concept_id,
       G.unit_concept_id,
       G.n,
       Q.j,
       CAST(G.n - 1 AS FLOAT) * Q.p AS h
INTO #position
FROM (
  SELECT DISTINCT measurement_concept_id, unit_concept_id, n
  FROM #ranked
) G
CROSS JOIN (
@quantile_index_rows
) Q;

SELECT P.measurement_concept_id,
       P.unit_concept_id,
       P.n,
       P.j,
       CAST(FLOOR(P.h) AS BIGINT) + 1 AS low_rank,
       CASE WHEN CAST(FLOOR(P.h) AS BIGINT) + 2 > P.n
            THEN P.n
            ELSE CAST(FLOOR(P.h) AS BIGINT) + 2 END AS high_rank,
       P.h - FLOOR(P.h) AS fraction
INTO #bound
FROM #position P;

SELECT B.measurement_concept_id,
       B.unit_concept_id,
       B.n,
       B.j,
       LO.value_number + B.fraction * (HI.value_number - LO.value_number) AS q_value
INTO #quantile_long
FROM #bound B
INNER JOIN #ranked LO
  ON LO.measurement_concept_id = B.measurement_concept_id
  AND LO.unit_concept_id = B.unit_concept_id
  AND LO.ordinal = B.low_rank
INNER JOIN #ranked HI
  ON HI.measurement_concept_id = B.measurement_concept_id
  AND HI.unit_concept_id = B.unit_concept_id
  AND HI.ordinal = B.high_rank;

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
SELECT P.measurement_concept_id,
       P.unit_concept_id,
       CU.unit_source_value,
       CU.n_unit_source_value,
@quantile_pivot_expressions
       P.n,
       '@quantile_basis' AS basis
FROM #quantile_long P
INNER JOIN @concept_unit_table CU
  ON P.measurement_concept_id = CU.measurement_concept_id
  AND P.unit_concept_id = CU.unit_concept_id
GROUP BY P.measurement_concept_id,
         P.unit_concept_id,
         CU.unit_source_value,
         CU.n_unit_source_value,
         P.n;

TRUNCATE TABLE #quantile_source;
DROP TABLE #quantile_source;

TRUNCATE TABLE #ranked;
DROP TABLE #ranked;

TRUNCATE TABLE #position;
DROP TABLE #position;

TRUNCATE TABLE #bound;
DROP TABLE #bound;

TRUNCATE TABLE #quantile_long;
DROP TABLE #quantile_long;
