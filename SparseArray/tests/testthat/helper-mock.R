# testthat::local_mocked_bindings() does not exist in the testthat that ships
# with the pinned analysis environment (3.1.2), so the tests go through this
# wrapper: it delegates when the function is available and otherwise rebinds the
# names in the target namespace for the duration of the calling test.
localMockedBindings <- function(..., .package, .env = parent.frame()) {
  if (exists("local_mocked_bindings", envir = asNamespace("testthat"))) {
    mock <- get("local_mocked_bindings", envir = asNamespace("testthat"))
    return(mock(..., .package = .package, .env = .env))
  }
  bindings <- list(...)
  stopifnot(length(bindings) > 0, !is.null(names(bindings)))
  namespace <- asNamespace(.package)
  originals <- lapply(names(bindings), function(name) {
    get(name, envir = namespace, inherits = FALSE)
  })
  names(originals) <- names(bindings)
  for (name in names(bindings)) {
    assignInNamespace(name, bindings[[name]], ns = .package)
  }
  withr::defer(
    {
      for (name in names(originals)) {
        assignInNamespace(name, originals[[name]], ns = .package)
      }
    },
    envir = .env
  )
  invisible(NULL)
}
