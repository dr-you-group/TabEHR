-- A deterministic sample of persons, used to run every stage on a small slice
-- before the full run (CLAUDE.md: "각 단계는 작은 샘플(환자 1,000명)로 먼저 돌려").
--
-- The sample is the first @sample_person_count person_id values in ascending
-- order. The MIMIC OMOP person_id is a hash, so ordering by it is effectively
-- an arbitrary but reproducible selection; at a site with sequential ids it is
-- the earliest patients instead. ROW_NUMBER is used rather than TOP because
-- SqlRender translates it on every dialect.
--
-- Note the sample is applied before any inclusion criterion, so the flow counts
-- from a sample run have the same shape as a full run, just smaller. The
-- (concept, unit) >= 10 record filter and the quantiles will differ from the
-- full run, which is expected of a smoke test.

IF OBJECT_ID('@person_sample_table', 'U') IS NOT NULL DROP TABLE @person_sample_table;

CREATE TABLE @person_sample_table (
  person_id BIGINT NOT NULL
);

INSERT INTO @person_sample_table (person_id)
SELECT person_id
FROM (
  SELECT person_id,
         ROW_NUMBER() OVER (ORDER BY person_id) AS ordinal
  FROM @cdm_database_schema.person
) S
WHERE S.ordinal <= @sample_person_count;
