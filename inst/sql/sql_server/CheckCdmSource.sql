-- Optional: not every site fills cdm_source in.
SELECT cdm_source_name, cdm_version, vocabulary_version, source_release_date, cdm_release_date
FROM @cdm_database_schema.cdm_source;
