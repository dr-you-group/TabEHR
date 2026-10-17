-- Turn the staging table written by R into the typed person_split table.
--
-- R sends every column as text, so a 19 digit person_id cannot be rounded on
-- the way in; the cast to BIGINT happens here, in SQL. An empty split string
-- becomes NULL, which is what a pretraining-stage-only or external row means.

IF OBJECT_ID('@person_split_table', 'U') IS NOT NULL DROP TABLE @person_split_table;

CREATE TABLE @person_split_table (
  person_id BIGINT NOT NULL,
  stage VARCHAR(12) NOT NULL,
  split VARCHAR(12) NULL,
  split_seed INT NOT NULL
);

INSERT INTO @person_split_table (person_id, stage, split, split_seed)
SELECT CAST(S.person_id AS BIGINT) AS person_id,
       S.stage,
       CASE WHEN S.split IS NULL OR S.split = '' THEN CAST(NULL AS VARCHAR(12))
            ELSE S.split END AS split,
       CAST(S.split_seed AS INT) AS split_seed
FROM @staging_table S;
