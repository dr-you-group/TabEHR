-- Drop one table if it is there.
-- SqlRender turns the OBJECT_ID idiom into DROP TABLE IF EXISTS elsewhere.
IF OBJECT_ID('@drop_table', 'U') IS NOT NULL DROP TABLE @drop_table;
