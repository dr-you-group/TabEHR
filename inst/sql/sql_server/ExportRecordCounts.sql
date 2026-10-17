-- The record count each study population patient was selected on, which is
-- extractRecords()'s count under the original MedRep rules. createAllRecords()
-- counts differently on purpose, and runDiagnostics() compares the two per
-- patient rather than assuming they agree.
SELECT CAST(P.person_id AS VARCHAR(20)) AS person_id,
       RC.n_records AS n_records_selection
FROM @study_population_table P
INNER JOIN @record_counts_table RC
  ON RC.person_id = P.person_id
ORDER BY P.person_id;
