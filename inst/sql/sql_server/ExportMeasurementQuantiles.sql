-- meas_quantiles.csv, in the column order of the original MedRep file plus the
-- n and basis columns CLAUDE.md asks for.
SELECT Q.measurement_concept_id,
       Q.unit_concept_id,
       Q.unit_source_value,
       Q.n_unit_source_value,
       @quantile_column_names,
       Q.n,
       Q.basis
FROM @meas_quantiles_table Q
ORDER BY Q.measurement_concept_id, Q.unit_concept_id;
