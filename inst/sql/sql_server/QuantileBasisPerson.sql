-- The patients the measurement quantiles are computed from.
--
-- CLAUDE.md makes the pretraining patients the default, so that the value
-- distribution of the downstream patients never leaks into the bin boundaries
-- the model is trained with. @quantile_basis_stage = '' falls back to the whole
-- study population, which is what the original MedRep code does.
{DEFAULT @quantile_basis_stage = ''}

IF OBJECT_ID('@quantile_basis_person_table', 'U') IS NOT NULL DROP TABLE @quantile_basis_person_table;

CREATE TABLE @quantile_basis_person_table (
  person_id BIGINT NOT NULL
);

INSERT INTO @quantile_basis_person_table (person_id)
{@quantile_basis_stage != ''} ? {
SELECT S.person_id
FROM @person_split_table S
WHERE S.stage = '@quantile_basis_stage'
} : {
SELECT SP.person_id
FROM @study_population_table SP
}
;
