#' @param connectionDetails An object of type `connectionDetails` as created by
#'   [DatabaseConnector::createConnectionDetails()].
#' @param cdmDatabaseSchema Schema holding the OMOP CDM. Read only.
#' @param vocabularyDatabaseSchema Schema holding the OMOP vocabulary. Defaults
#'   to `cdmDatabaseSchema`.
#' @param cohortDatabaseSchema Schema this package creates its tables in. It
#'   needs create and drop rights, and it is where the SparseArray cohort table
#'   lives too.
#' @param tablePrefix Prefix for the tables this package creates, as
#'   [getTabehrTableNames()] applies it.
#' @param tempEmulationSchema Schema used to emulate temporary tables on
#'   platforms that need it, such as Oracle.
