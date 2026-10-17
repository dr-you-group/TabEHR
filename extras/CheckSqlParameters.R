# Do the R call sites pass every parameter their SQL file needs?
#
#   Rscript extras/CheckSqlParameters.R
#
# CheckSqlRendering.R renders each file with a superset of parameters, so it
# cannot see a parameter that R forgets to pass; this walks the parsed R code
# instead, finds every .executeTabehrSql() and .queryTabehrSql() call, and
# compares its named arguments against the parameters the named SQL file uses.
#
# A parameter the file declares with {DEFAULT @x = ...} does not have to be
# passed. Anything else does, and anything passed but unused is a leftover that
# SqlRender would warn about at run time.

root <- Sys.getenv("TABEHR_ROOT", unset = getwd())
sqlFolder <- file.path(root, "inst", "sql", "sql_server")
stopifnot(dir.exists(sqlFolder))

sqlParameters <- function(file) {
  sql <- paste(readLines(file.path(sqlFolder, file), warn = FALSE),
               collapse = "\n")
  used <- unique(gsub("^@", "", unlist(regmatches(
    sql, gregexpr("@[A-Za-z_][A-Za-z0-9_]*", sql)
  ))))
  defaulted <- unique(gsub("^.*@", "", unlist(regmatches(
    sql, gregexpr("\\{DEFAULT[[:space:]]+@[A-Za-z_][A-Za-z0-9_]*", sql)
  ))))
  list(used = used, defaulted = defaulted)
}

# Every .executeTabehrSql() / .queryTabehrSql() call in the package, with the
# names it passes. do.call(.executeTabehrSql, c(...)) is reported separately,
# because its arguments are assembled at run time.
calls <- list()
dynamic <- character(0)
walk <- function(node, file) {
  if (!is.call(node)) {
    return(invisible(NULL))
  }
  name <- if (is.name(node[[1]])) as.character(node[[1]]) else ""
  if (name %in% c(".executeTabehrSql", ".queryTabehrSql")) {
    arguments <- as.list(node)[-1]
    literal <- vapply(arguments, function(a) is.character(a) &&
                        length(a) == 1 && grepl("[.]sql$", a), logical(1))
    sqlFilename <- if (any(literal)) arguments[[which(literal)[1]]] else NA
    if (!is.na(sqlFilename)) {
      calls[[length(calls) + 1]] <<- list(
        file = file,
        sqlFilename = sqlFilename,
        passed = setdiff(names(arguments),
                         c("", "connection", "sqlFilename",
                           "tempEmulationSchema", "snakeCaseToCamelCase",
                           "progressBar"))
      )
    }
  }
  if (name == "do.call") {
    target <- as.list(node)[-1][[1]]
    if (is.name(target) &&
        as.character(target) %in% c(".executeTabehrSql", ".queryTabehrSql")) {
      dynamic <<- c(dynamic, file)
    }
  }
  for (i in seq_along(node)) {
    # An empty argument, as in x[1, ], is the empty symbol: binding it to a
    # variable and touching it raises "argument is missing", so it is tested
    # and skipped in place.
    if (identical(node[[i]], quote(expr = ))) {
      next
    }
    walk(node[[i]], file)
  }
  invisible(NULL)
}
for (file in list.files(file.path(root, "R"), pattern = "[.]R$")) {
  for (expression in parse(file.path(root, "R", file))) {
    walk(expression, file)
  }
}

rows <- lapply(calls, function(call) {
  parameters <- sqlParameters(call$sqlFilename)
  required <- setdiff(parameters$used, parameters$defaulted)
  data.frame(
    r_file = call$file,
    sql_file = call$sqlFilename,
    missing = paste(setdiff(required, call$passed), collapse = " "),
    unused = paste(setdiff(call$passed, parameters$used), collapse = " "),
    stringsAsFactors = FALSE
  )
})
results <- do.call(rbind, rows)
results$ok <- !nzchar(results$missing) & !nzchar(results$unused)
results <- results[order(results$sql_file), ]

cat("\n==== R call sites against their SQL files ====\n")
print(results[, c("r_file", "sql_file", "ok", "missing", "unused")],
      row.names = FALSE)

if (length(dynamic) > 0) {
  cat("\nassembled with do.call(), so not checked here:",
      paste(unique(dynamic), collapse = ", "), "\n")
}

# Files nothing calls, and files called more than once, are both worth seeing.
called <- unique(vapply(calls, function(call) call$sqlFilename, ""))
orphans <- setdiff(list.files(sqlFolder, pattern = "[.]sql$"), called)
if (length(orphans) > 0) {
  cat("\nnot called from R (used via do.call, or unused):\n  ",
      paste(orphans, collapse = "\n  "), "\n")
}

failures <- sum(!results$ok)
cat("\n", nrow(results) - failures, "of", nrow(results), "call sites ok\n")
if (failures > 0) {
  quit(status = 1)
}
