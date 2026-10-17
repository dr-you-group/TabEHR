/************************************************************************
Inpatient visit indexed on the DISCHARGE date.

Derived from the admission-indexed cohort rather than restating its definition:
every row is one row of @source_cohort_id with cohort_start_date moved to that
visit's discharge. The eligibility criteria therefore cannot drift from the
admission cohort, which a copy of its ATLAS SQL would be free to do.

cohort_end_date of the admission cohort is already capped at the observation
period end, so the discharge date is inside the observation period by
construction.

This target exists because FeatureExtraction anchors sequenceStartDay and
sequenceEndDay on cohort_start_date only. Tasks whose covariates run up to
discharge and whose time at risk starts the day after it cannot be expressed
against an admission-indexed target, since the length of stay differs per
patient.
************************************************************************/

{DEFAULT @source_cohort_id = 1000}

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT
  @target_cohort_id AS cohort_definition_id,
  subject_id,
  cohort_end_date AS cohort_start_date,
  cohort_end_date AS cohort_end_date
FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @source_cohort_id
;
