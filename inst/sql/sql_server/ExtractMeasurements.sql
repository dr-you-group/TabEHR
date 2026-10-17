-- Measurement records.
--
-- Port of MedRep create_trajectory.py lines 112-201, with the measurement side
-- deliberately aligned to FeatureExtraction so that a row of
-- featureExtractionLong.csv can be turned back into an allrecords token. The
-- decisions, and where they came from:
--
--   concept filter  FeatureExtraction's DomainConcept.sql filters on nothing
--                   but concept_id <> 0: no standard_concept, no invalid_reason
--                   and no domain_id check, and the CONCEPT table is only
--                   joined to name the covariate. This file does the same, so
--                   the two sides admit the same concepts  [OPEN_QUESTIONS C5]
--   value           value_as_number, which is what FeatureExtraction's
--                   MeasurementValue.sql reads, instead of parsing
--                   value_source_value the way the original does. That also
--                   removes the need for a dialect specific numeric cast
--   unit            unit_concept_id, which is what the FeatureExtraction
--                   covariate_id carries, instead of the unit_source_value
--                   text the original groups by. unit_source_value is kept as a
--                   descriptive column of the (concept, unit) table
--   record exists   value_source_value IS NOT NULL, as in the original: that is
--                   what decides whether the measurement becomes a record at
--                   all. Only the numeric VALUE comes from value_as_number
--   missing unit    a numeric row whose unit_concept_id is 0 or NULL is
--                   dropped, as the original drops it  [OPEN_QUESTIONS C1].
--                   FeatureExtraction keeps it as an "Unknown unit" covariate,
--                   so such a covariate has no token on this side
--
-- The rest follows the original:
--   * measurement_datetime inside the date range. Unlike condition and
--     procedure, the original does NOT fall back to measurement_date, so a
--     missing datetime drops the row  [OPEN_QUESTIONS C3]
--   * adult records only, per record
--   * one row per (person, concept, hour). pandas keeps the first row in file
--     order; SQL needs an explicit ORDER BY, so this uses the datetime and then
--     the tie break column from the settings  [OPEN_QUESTIONS C7]
--   * a (concept, unit) pair needs at least @min_concept_unit_count numeric
--     rows before its values are binned
--   * everything whose value is not numeric keeps the bare concept_id and no
--     quantile
--
-- The output keeps the value and the unit so the bins can be assigned later,
-- after the quantile table exists.
--
-- The measurement source is aliased M throughout: @hour_of_day is rendered
-- against M.measurement_datetime.

{DEFAULT @person_sample_table = ''}
{DEFAULT @tie_break_column = ''}

-- 1-3: adult measurement rows with a value and a datetime inside the range.
SELECT E.person_id,
       E.measurement_concept_id,
       E.measurement_datetime,
       E.unit_concept_id,
       E.unit_source_value,
       E.value_as_number{@tie_break_column != ''} ? {,
       E.@tie_break_column}
INTO #meas_adult
FROM (
  SELECT M.person_id,
         M.measurement_concept_id,
         M.measurement_datetime,
         COALESCE(M.unit_concept_id, 0) AS unit_concept_id,
         M.unit_source_value,
         M.value_as_number,
         P.year_of_birth{@tie_break_column != ''} ? {,
         M.@tie_break_column}
  FROM @cdm_database_schema.measurement M
  INNER JOIN @cdm_database_schema.person P
    ON M.person_id = P.person_id
  WHERE M.measurement_concept_id <> 0
    AND M.value_source_value IS NOT NULL
    AND M.measurement_datetime IS NOT NULL
) E
WHERE E.measurement_datetime >= '@date_min'
  AND E.measurement_datetime <= '@date_max'
  AND YEAR(E.measurement_datetime) - E.year_of_birth >= @adult_age_min
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = E.person_id)}
;

-- 4: one row per (person, concept, hour).
SELECT T.person_id,
       T.measurement_concept_id,
       T.measurement_datetime,
       T.unit_concept_id,
       T.unit_source_value,
       T.value_as_number
INTO #meas_hour
FROM (
  SELECT M.person_id,
         M.measurement_concept_id,
         M.measurement_datetime,
         M.unit_concept_id,
         M.unit_source_value,
         M.value_as_number,
         ROW_NUMBER() OVER (
           PARTITION BY M.person_id,
                        M.measurement_concept_id,
                        CAST(M.measurement_datetime AS DATE),
                        @hour_of_day
           ORDER BY M.measurement_datetime{@tie_break_column != ''} ? {, M.@tie_break_column}
         ) AS ordinal
  FROM #meas_adult M
) T
WHERE T.ordinal = 1;

-- 5: the (concept, unit) pairs with enough numeric rows. This is also the unit
-- reference table: unit_source_value is the lowest source text seen for that
-- unit_concept_id, and n_unit_source_value says how many distinct texts map to
-- it, which is the information the unit_concept_id grouping gives up.
IF OBJECT_ID('@concept_unit_table', 'U') IS NOT NULL DROP TABLE @concept_unit_table;

CREATE TABLE @concept_unit_table (
  measurement_concept_id BIGINT NOT NULL,
  unit_concept_id BIGINT NOT NULL,
  unit_source_value VARCHAR(50) NULL,
  n_unit_source_value INT NOT NULL,
  n BIGINT NOT NULL
);

INSERT INTO @concept_unit_table (measurement_concept_id, unit_concept_id, unit_source_value, n_unit_source_value, n)
SELECT T.measurement_concept_id,
       T.unit_concept_id,
       -- The unit_concept_id grouping gives up the source text, so keep one
       -- of them and say how many there were.
       MIN(T.unit_source_value) AS unit_source_value,
       COUNT(DISTINCT T.unit_source_value) AS n_unit_source_value,
       COUNT(*) AS n
FROM #meas_hour T
WHERE T.value_as_number IS NOT NULL
  AND T.unit_concept_id <> 0
GROUP BY T.measurement_concept_id, T.unit_concept_id
HAVING COUNT(*) >= @min_concept_unit_count;

-- 6: the records that survive, flagged as numeric (a quantile bin will be
-- assigned) or not (bare concept_id).
IF OBJECT_ID('@measurements_table', 'U') IS NOT NULL DROP TABLE @measurements_table;

CREATE TABLE @measurements_table (
  person_id BIGINT NOT NULL,
  measurement_concept_id BIGINT NOT NULL,
  record_datetime DATETIME2 NOT NULL,
  unit_concept_id BIGINT NOT NULL,
  value_number FLOAT NULL,
  is_numeric INT NOT NULL
);

-- The numeric branch: a value, a mapped unit, and a frequent enough pair.
INSERT INTO @measurements_table (person_id, measurement_concept_id, record_datetime, unit_concept_id, value_number, is_numeric)
SELECT T.person_id,
       T.measurement_concept_id,
       T.measurement_datetime AS record_datetime,
       T.unit_concept_id,
       T.value_as_number AS value_number,
       1 AS is_numeric
FROM #meas_hour T
INNER JOIN @concept_unit_table CU
  ON T.measurement_concept_id = CU.measurement_concept_id
  AND T.unit_concept_id = CU.unit_concept_id
WHERE T.value_as_number IS NOT NULL;

-- The non-numeric branch: no numeric value at all.
INSERT INTO @measurements_table (person_id, measurement_concept_id, record_datetime, unit_concept_id, value_number, is_numeric)
SELECT T.person_id,
       T.measurement_concept_id,
       T.measurement_datetime AS record_datetime,
       T.unit_concept_id,
       CAST(NULL AS FLOAT) AS value_number,
       0 AS is_numeric
FROM #meas_hour T
WHERE T.value_as_number IS NULL;

TRUNCATE TABLE #meas_adult;
DROP TABLE #meas_adult;

TRUNCATE TABLE #meas_hour;
DROP TABLE #meas_hour;
