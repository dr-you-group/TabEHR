-- The patients the SparseArray stages are allowed to see.
--
-- At the primary site that is stage = 'downstream', the 15% that pretraining
-- never touches. At an external site every patient is evaluated, and the split
-- table marks them all stage = 'external'. Either way this is the table the
-- SparseArray target cohort definition joins against, through the
-- restrictPersonTable argument of SparseArray::createCohorts(), so the
-- restriction is expressed in exactly one place.

IF OBJECT_ID('@downstream_person_table', 'U') IS NOT NULL DROP TABLE @downstream_person_table;

CREATE TABLE @downstream_person_table (
  person_id BIGINT NOT NULL
);

INSERT INTO @downstream_person_table (person_id)
SELECT S.person_id
FROM @person_split_table S
WHERE S.stage = '@downstream_stage';
