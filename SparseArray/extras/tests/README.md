Tests for `extras/CreateSparseArray.R`.

The sparse array is optional and lives outside the package, so `extras` is in
`.Rbuildignore` and these tests are not part of `R CMD check`. Run them from the
repository root:

```r
testthat::test_dir("extras/tests")
```

They need `slam`, `Andromeda` and `FeatureExtraction`.
