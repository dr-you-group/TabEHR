-- Recorded in run_info.json so a run can be tied to a vocabulary release.
SELECT vocabulary_version
FROM @vocabulary_database_schema.vocabulary
WHERE vocabulary_id = 'None';
