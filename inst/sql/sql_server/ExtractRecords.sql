-- Condition, drug and procedure records.
--
-- Port of MedRep create_trajectory.py lines 65-110 (cond, drug) and 204-224
-- (proc):
--   * fill a missing *_datetime from the *_date
--   * keep @date_min <= record_datetime <= @date_max, where @date_max is
--     midnight of the configured day because the original compares strings and
--     so drops any time of day on that date  [OPEN_QUESTIONS C6]
--   * keep records from age @adult_age_min onwards, per record, as
--     YEAR(record_datetime) - person.year_of_birth
--   * drug additionally requires its END datetime to be inside the range, so a
--     drug row without an end date is dropped  [OPEN_QUESTIONS C4]
--
-- The concept filter is `concept_id <> 0` and nothing else, which is exactly
-- what FeatureExtraction's DomainConcept.sql does: no standard_concept, no
-- invalid_reason and no domain_id check, with the CONCEPT table joined only to
-- name the covariate. The original instead joins one concept list built from
-- all four domains. Matching FeatureExtraction means allrecords and
-- featureExtractionLong admit the same concepts, which is what makes a
-- covariate_id convertible back to an allrecords token  [OPEN_QUESTIONS C5].
--
-- The join to PERSON is an inner join, which reproduces the original's left
-- merge followed by a comparison against a missing year_of_birth.

{DEFAULT @person_sample_table = ''}

IF OBJECT_ID('@records_table', 'U') IS NOT NULL DROP TABLE @records_table;

CREATE TABLE @records_table (
  person_id BIGINT NOT NULL,
  domain VARCHAR(4) NOT NULL,
  concept_id BIGINT NOT NULL,
  record_datetime DATETIME2 NOT NULL
);

-- Condition
INSERT INTO @records_table (person_id, domain, concept_id, record_datetime)
SELECT E.person_id, 'cond' AS domain, E.concept_id, E.record_datetime
FROM (
  SELECT C.person_id,
         C.condition_concept_id AS concept_id,
         COALESCE(C.condition_start_datetime, C.condition_start_date) AS record_datetime,
         P.year_of_birth
  FROM @cdm_database_schema.condition_occurrence C
  INNER JOIN @cdm_database_schema.person P
    ON C.person_id = P.person_id
  WHERE C.condition_concept_id <> 0
) E
WHERE E.record_datetime >= '@date_min'
  AND E.record_datetime <= '@date_max'
  AND YEAR(E.record_datetime) - E.year_of_birth >= @adult_age_min
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = E.person_id)}
;

-- Drug
INSERT INTO @records_table (person_id, domain, concept_id, record_datetime)
SELECT E.person_id, 'drug' AS domain, E.concept_id, E.record_datetime
FROM (
  SELECT D.person_id,
         D.drug_concept_id AS concept_id,
         COALESCE(D.drug_exposure_start_datetime, D.drug_exposure_start_date) AS record_datetime,
         COALESCE(D.drug_exposure_end_datetime, D.drug_exposure_end_date) AS end_datetime,
         P.year_of_birth
  FROM @cdm_database_schema.drug_exposure D
  INNER JOIN @cdm_database_schema.person P
    ON D.person_id = P.person_id
  WHERE D.drug_concept_id <> 0
) E
WHERE E.record_datetime >= '@date_min'
  AND E.record_datetime <= '@date_max'
  AND E.end_datetime >= '@date_min'
  AND E.end_datetime <= '@date_max'
  AND YEAR(E.record_datetime) - E.year_of_birth >= @adult_age_min
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = E.person_id)}
;

-- Procedure
INSERT INTO @records_table (person_id, domain, concept_id, record_datetime)
SELECT E.person_id, 'proc' AS domain, E.concept_id, E.record_datetime
FROM (
  SELECT PR.person_id,
         PR.procedure_concept_id AS concept_id,
         COALESCE(PR.procedure_datetime, PR.procedure_date) AS record_datetime,
         P.year_of_birth
  FROM @cdm_database_schema.procedure_occurrence PR
  INNER JOIN @cdm_database_schema.person P
    ON PR.person_id = P.person_id
  WHERE PR.procedure_concept_id <> 0
) E
WHERE E.record_datetime >= '@date_min'
  AND E.record_datetime <= '@date_max'
  AND YEAR(E.record_datetime) - E.year_of_birth >= @adult_age_min
{@person_sample_table != ''} ? {  AND EXISTS (SELECT 1 FROM @person_sample_table SMP WHERE SMP.person_id = E.person_id)}
;
