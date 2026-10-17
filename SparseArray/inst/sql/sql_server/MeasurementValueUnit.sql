-- Measurement covariates for a temporal sequence extraction.
--
-- Two analyses, both of this package's own, both built with
-- FeatureExtraction's id arithmetic:
--
--   @analysis_id (998)           concept * 1000000 + (unit % 1000) * 1000 + 998
--                                a measurement with a numeric value. The
--                                covariate value IS that number
--   @no_value_analysis_id (999)  concept * 1000 + 999
--                                a measurement with no numeric value, and only
--                                where the same (row, concept, interval) has
--                                no 998 covariate, so one record is one
--                                covariate and never two
--
-- Why not FeatureExtraction's own 701 and 702:
--
--   * 702 (MeasurementValue.sql) cannot run in a temporal sequence extraction.
--     Its temporal sequence branch has no comma after `as time_id`, so the
--     rendered SQL is not valid SQL. The analysis is isDefault = FALSE in
--     PrespecTemporalAnalyses.csv, which is presumably why that survived.
--   * The content would differ anyway: the unit is read as
--     COALESCE(unit_concept_id, 0) here, so a numeric measurement whose unit is
--     missing stays as an unknown-unit covariate instead of being dropped by
--     the join to #meas_cov, which is what MeasurementValue.sql does to it.
--   * 701 (Measurement) covers every measurement, so switching it on next to
--     998 would emit two covariates for one record. It stays off, and 999
--     covers exactly the records 998 cannot.
--
-- The arithmetic is still FeatureExtraction's, so nothing downstream needs a
-- new decoding rule, and 998 and 999 are free in both of its prespecified
-- analysis sets (both stop at 926).
--
-- Inherited from MeasurementValue.sql on purpose: ROW_NUMBER partitions by
-- measurement_concept_id, not by covariate_id, so one concept measured in two
-- units inside one interval contributes one row, the last by date, then the
-- lowest unit, then the lowest value.
--
-- Temp table names are prefixed mvu_ rather than reusing FeatureExtraction's
-- #meas_cov, so that this builder and that analysis cannot collide inside one
-- session.

{DEFAULT @cohort_id_clause = ''}

IF OBJECT_ID('tempdb..#mvu_cov', 'U') IS NOT NULL
	DROP TABLE #mvu_cov;

SELECT DISTINCT measurement_concept_id,
	COALESCE(unit_concept_id, 0) AS unit_concept_id,
	CAST((CAST(measurement_concept_id AS BIGINT) * 1000000) + ((COALESCE(unit_concept_id, 0) - (FLOOR(COALESCE(unit_concept_id, 0) / 1000) * 1000)) * 1000) + @analysis_id AS BIGINT) AS covariate_id
INTO #mvu_cov
FROM @cdm_database_schema.measurement
WHERE value_as_number IS NOT NULL;

-- The value FeatureExtraction keeps when one concept has several values in one
-- interval. measurement_concept_id is carried along for the anti-join below.
IF OBJECT_ID('tempdb..#mvu_val', 'U') IS NOT NULL
	DROP TABLE #mvu_val;

SELECT row_id,
	measurement_concept_id,
	covariate_id,
	covariate_value,
	time_id
INTO #mvu_val
FROM (
	SELECT cohort.@row_id_field AS row_id,
		measurement.measurement_concept_id,
		meas_cov.covariate_id,
		measurement.value_as_number AS covariate_value,
		CAST(FLOOR(DATEDIFF(@time_part, measurement.measurement_date, cohort.cohort_start_date) * 1.0 / @time_interval) AS INT) AS time_id,
		ROW_NUMBER() OVER (
			PARTITION BY cohort.@row_id_field,
				measurement.measurement_concept_id,
				FLOOR(DATEDIFF(@time_part, measurement.measurement_date, cohort.cohort_start_date) * 1.0 / @time_interval)
			ORDER BY measurement.measurement_date DESC,
				measurement.unit_concept_id,
				measurement.value_as_number
			) AS rn
	FROM @cohort_table cohort
	INNER JOIN @cdm_database_schema.measurement
		ON cohort.subject_id = measurement.person_id
	INNER JOIN #mvu_cov meas_cov
		ON meas_cov.measurement_concept_id = measurement.measurement_concept_id
			AND meas_cov.unit_concept_id = COALESCE(measurement.unit_concept_id, 0)
	WHERE measurement.measurement_date <= DATEADD(DAY, @sequence_end_day, cohort.cohort_start_date)
		AND measurement.measurement_date >= DATEADD(DAY, @sequence_start_day, cohort.cohort_start_date)
		AND measurement.measurement_concept_id != 0
		AND measurement.value_as_number IS NOT NULL
@cohort_id_clause
	) temp
WHERE rn = 1;

-- The measurements with no numeric value at all, one covariate per (row,
-- concept, interval), and only where that interval produced no value covariate
-- for the same concept. One record is one covariate: the two analyses
-- partition the measurements rather than overlapping.
IF OBJECT_ID('tempdb..#mvu_nov', 'U') IS NOT NULL
	DROP TABLE #mvu_nov;

SELECT DISTINCT cohort.@row_id_field AS row_id,
	measurement.measurement_concept_id,
	CAST(CAST(measurement.measurement_concept_id AS BIGINT) * 1000 + @no_value_analysis_id AS BIGINT) AS covariate_id,
	CAST(FLOOR(DATEDIFF(@time_part, measurement.measurement_date, cohort.cohort_start_date) * 1.0 / @time_interval) AS INT) AS time_id
INTO #mvu_nov
FROM @cohort_table cohort
INNER JOIN @cdm_database_schema.measurement
	ON cohort.subject_id = measurement.person_id
WHERE measurement.measurement_date <= DATEADD(DAY, @sequence_end_day, cohort.cohort_start_date)
	AND measurement.measurement_date >= DATEADD(DAY, @sequence_start_day, cohort.cohort_start_date)
	AND measurement.measurement_concept_id != 0
	AND measurement.value_as_number IS NULL
	AND NOT EXISTS (
		SELECT 1
		FROM #mvu_val taken
		WHERE taken.row_id = cohort.@row_id_field
			AND taken.measurement_concept_id = measurement.measurement_concept_id
			AND taken.time_id = CAST(FLOOR(DATEDIFF(@time_part, measurement.measurement_date, cohort.cohort_start_date) * 1.0 / @time_interval) AS INT)
		)
@cohort_id_clause
;

-- The two analyses in the column set FeatureExtraction's own covariates table
-- has. A no-value covariate carries 1, the way every DomainConcept covariate
-- does.
IF OBJECT_ID('tempdb..#mvu_data', 'U') IS NOT NULL
	DROP TABLE #mvu_data;

SELECT row_id,
	covariate_id,
	covariate_value,
	time_id
INTO #mvu_data
FROM (
	SELECT row_id,
		covariate_id,
		covariate_value,
		time_id
	FROM #mvu_val

	UNION ALL

	SELECT row_id,
		covariate_id,
		CAST(1 AS FLOAT) AS covariate_value,
		time_id
	FROM #mvu_nov
	) both_analyses;

-- The reference table, with FeatureExtraction's covariate name for the value
-- analysis, including the way it names a unit it cannot resolve. A pair of
-- units that agree modulo 1000 shares one covariate id and so yields two rows
-- here, which is also what FeatureExtraction does: the ambiguity is visible
-- rather than hidden.
IF OBJECT_ID('tempdb..#mvu_ref', 'U') IS NOT NULL
	DROP TABLE #mvu_ref;

SELECT temp.covariate_id,
	CAST(CASE WHEN unit_concept.concept_id IS NULL OR unit_concept.concept_id = 0 THEN
		CONCAT('measurement value: ', CASE WHEN measurement_concept.concept_name IS NULL THEN 'Unknown concept' ELSE measurement_concept.concept_name END, ' (Unknown unit)')
	ELSE
		CONCAT('measurement value: ', CASE WHEN measurement_concept.concept_name IS NULL THEN 'Unknown concept' ELSE measurement_concept.concept_name END, ' (', unit_concept.concept_name, ')')
	END AS VARCHAR(512)) AS covariate_name,
	CAST(@analysis_id AS INT) AS analysis_id,
	covariate_ids.measurement_concept_id AS concept_id
INTO #mvu_ref
FROM (
	SELECT DISTINCT covariate_id
	FROM #mvu_val
	) temp
INNER JOIN #mvu_cov covariate_ids
	ON covariate_ids.covariate_id = temp.covariate_id
LEFT JOIN @cdm_database_schema.concept measurement_concept
	ON covariate_ids.measurement_concept_id = measurement_concept.concept_id
LEFT JOIN @cdm_database_schema.concept unit_concept
	ON covariate_ids.unit_concept_id = unit_concept.concept_id;

INSERT INTO #mvu_ref (covariate_id, covariate_name, analysis_id, concept_id)
SELECT temp.covariate_id,
	CAST(CONCAT('measurement with no value: ', CASE WHEN measurement_concept.concept_name IS NULL THEN 'Unknown concept' ELSE measurement_concept.concept_name END) AS VARCHAR(512)) AS covariate_name,
	CAST(@no_value_analysis_id AS INT) AS analysis_id,
	temp.measurement_concept_id AS concept_id
FROM (
	SELECT DISTINCT covariate_id,
		measurement_concept_id
	FROM #mvu_nov
	) temp
LEFT JOIN @cdm_database_schema.concept measurement_concept
	ON temp.measurement_concept_id = measurement_concept.concept_id;

TRUNCATE TABLE #mvu_cov;
DROP TABLE #mvu_cov;

TRUNCATE TABLE #mvu_val;
DROP TABLE #mvu_val;

TRUNCATE TABLE #mvu_nov;
DROP TABLE #mvu_nov;
