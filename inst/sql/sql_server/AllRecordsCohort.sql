-- The cohort the whole-history extraction runs on: one row per study
-- population patient.
--
-- FeatureExtraction only extracts relative to an index date, so to get every
-- record a patient has, the index date is that patient's LAST record and the
-- window reaches back as far as FeatureExtraction allows
-- (sequenceStartDay = -99999, about 274 years). The first record date is kept
-- alongside so that runDiagnostics() can prove nothing fell outside the
-- window, and record_date is reconstructed later as
-- cohort_start_date - time_id.
--
-- The dates come from the CDM rather than from this project's own records
-- table on purpose: that table is built for the study population criteria and
-- drops records FeatureExtraction keeps, so a patient's last record there can
-- be earlier than their last record here, and anything after the index date
-- would silently be lost.
--
-- row_id exists because person_id is a 19-digit BIGINT. Passing it as
-- FeatureExtraction's rowIdField would send it through R as a double and
-- change its last digits; a dense row number cannot be damaged that way, and
-- this table is the one place that maps it back.

IF OBJECT_ID('tempdb..#ar_range', 'U') IS NOT NULL
	DROP TABLE #ar_range;

SELECT R.person_id,
	MIN(R.record_date) AS first_record_date,
	MAX(R.record_date) AS last_record_date
INTO #ar_range
FROM (
	SELECT C.person_id,
		CAST(C.condition_start_date AS DATE) AS record_date
	FROM @cdm_database_schema.condition_occurrence C
	INNER JOIN @study_population_table P
		ON P.person_id = C.person_id
	WHERE C.condition_concept_id != 0

	UNION ALL

	SELECT D.person_id,
		CAST(D.drug_exposure_start_date AS DATE) AS record_date
	FROM @cdm_database_schema.drug_exposure D
	INNER JOIN @study_population_table P
		ON P.person_id = D.person_id
	WHERE D.drug_concept_id != 0

	UNION ALL

	SELECT PR.person_id,
		CAST(PR.procedure_date AS DATE) AS record_date
	FROM @cdm_database_schema.procedure_occurrence PR
	INNER JOIN @study_population_table P
		ON P.person_id = PR.person_id
	WHERE PR.procedure_concept_id != 0

	UNION ALL

	SELECT M.person_id,
		CAST(M.measurement_date AS DATE) AS record_date
	FROM @cdm_database_schema.measurement M
	INNER JOIN @study_population_table P
		ON P.person_id = M.person_id
	WHERE M.measurement_concept_id != 0
	) R
WHERE R.record_date IS NOT NULL
GROUP BY R.person_id;

IF OBJECT_ID('@allrecords_cohort_table', 'U') IS NOT NULL
	DROP TABLE @allrecords_cohort_table;

CREATE TABLE @allrecords_cohort_table (
	cohort_definition_id INT NOT NULL,
	subject_id BIGINT NOT NULL,
	cohort_start_date DATE NOT NULL,
	cohort_end_date DATE NOT NULL,
	row_id BIGINT NOT NULL,
	first_record_date DATE NOT NULL,
	last_record_date DATE NOT NULL
);

-- ORDER BY person_id makes row_id deterministic, which matters because every
-- later join goes through it.
INSERT INTO @allrecords_cohort_table (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date, row_id, first_record_date, last_record_date)
SELECT @cohort_id AS cohort_definition_id,
	person_id AS subject_id,
	last_record_date AS cohort_start_date,
	last_record_date AS cohort_end_date,
	ROW_NUMBER() OVER (ORDER BY person_id) AS row_id,
	first_record_date,
	last_record_date
FROM #ar_range;

TRUNCATE TABLE #ar_range;
DROP TABLE #ar_range;
