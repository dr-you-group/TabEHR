-- Records per person, on the de-duplicated union of the four domains.
--
-- Port of create_trajectory.py lines 244-264: the records are concatenated,
-- drop_duplicates() is applied over (person_id, domain, concept_id,
-- record_datetime). The minimum record count itself is applied later, by
-- StudyPopulation.sql.
-- Note "domain" is part of the key, so the same concept at the same instant in
-- two domains counts twice  [OPEN_QUESTIONS C8].
--
-- The measurement concept_id is counted WITHOUT its quantile suffix, which the
-- final table adds later. That cannot change the count: the per-hour step
-- leaves at most one measurement row per (person, concept, hour), so no two
-- measurement rows share a (person, concept, record_datetime) key and the
-- suffix can never merge or split a pair. runDiagnostics() re-counts from
-- the finished allrecords table and compares, so this reasoning is checked
-- against the data rather than trusted.

IF OBJECT_ID('@record_counts_table', 'U') IS NOT NULL DROP TABLE @record_counts_table;

CREATE TABLE @record_counts_table (
  person_id BIGINT NOT NULL,
  n_records BIGINT NOT NULL
);

INSERT INTO @record_counts_table (person_id, n_records)
SELECT R.person_id, COUNT(*) AS n_records
FROM (
  SELECT DISTINCT person_id,
         domain,
         CAST(concept_id AS VARCHAR(20)) AS concept_id,
         record_datetime
  FROM @records_table

  UNION

  SELECT DISTINCT person_id,
         'meas' AS domain,
         CAST(measurement_concept_id AS VARCHAR(20)) AS concept_id,
         record_datetime
  FROM @measurements_table
) R
GROUP BY R.person_id;
