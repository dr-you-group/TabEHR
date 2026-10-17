-- The (covariate id, concept, unit) crosswalk of the measurement value
-- covariates.
--
-- A measurement value covariate id carries the unit only as
-- `unit_concept_id % 1000`, and covariateRef has no column for the unit at
-- all, so (concept, unit) cannot be read back from an extraction. It can be
-- read back from the CDM: the id is a function of the pair, so running the
-- same arithmetic over the measurement table recovers every pair and the id it
-- maps to. That is all this file is, plus a record count, which is what tells
-- the two pairs of a collision apart when one of them is marginal.
--
-- Two pairs whose units agree modulo 1000 share one covariate id and so yield
-- two rows with the same covariate_id. That is not a defect here: it is the
-- ambiguity the id already contains, made visible.
--
-- The filters are MeasurementValueUnit.sql's, so that every row here is a
-- covariate an extraction can actually produce and nothing else:
-- measurement_concept_id = 0 is excluded there, and the unit is read as
-- COALESCE(unit_concept_id, 0), so a numeric measurement with no unit is a
-- covariate with unit 0 rather than a dropped record.

SELECT CAST((CAST(measurement_concept_id AS BIGINT) * 1000000) + ((COALESCE(unit_concept_id, 0) - (FLOOR(COALESCE(unit_concept_id, 0) / 1000) * 1000)) * 1000) + @analysis_id AS BIGINT) AS covariate_id,
	measurement_concept_id AS concept_id,
	COALESCE(unit_concept_id, 0) AS unit_concept_id,
	COUNT(*) AS record_count
FROM @cdm_database_schema.measurement
WHERE value_as_number IS NOT NULL
	AND measurement_concept_id != 0
GROUP BY measurement_concept_id,
	COALESCE(unit_concept_id, 0)
ORDER BY measurement_concept_id,
	COALESCE(unit_concept_id, 0);
