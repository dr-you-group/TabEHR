# Generates one outcome-cohort SQL file per CCSR phenotype from
# extras/OutcomeCohortTemplate.sql, substituting the phenotype's SNOMED concepts
# for @concept_ids, and registers them in CohortsToCreate.csv.
#
# One-off script, not part of the package. Run from the repository root, after
# AddSnomedToIcd10CcsrCsv.R has added the SNOMED column. Those are direct
# 'Maps to' targets; the template's #Codesets block expands descendants itself.

library(data.table)

csvFile      <- "codes/icd10ccsr.csv"
templateFile <- "extras/OutcomeCohortTemplate.sql"
sqlFolder    <- "inst/sql/sql_server"
cohortsFile  <- "inst/settings/CohortsToCreate.csv"
cohortIdBase <- 2000L   # generated cohorts get cohortIdBase + 1, + 2, ...

pheno <- fread(csvFile, colClasses = "character")
if (!"SNOMED" %in% names(pheno))
  stop("no SNOMED column - run extras/AddSnomedToIcd10CcsrCsv.R first")

pheno <- pheno[nzchar(SNOMED)]
setorder(pheno, Phenotype)

# File-safe cohort name, e.g. "Pleurisy_pleural_effusion_and_pulmonary_collapse_phenotype"
pheno[, cohortName := gsub("_+", "_", gsub("[^A-Za-z0-9]+", "_", Phenotype))]
pheno[, cohortName := paste0(gsub("_$", "", cohortName), "_phenotype")]
pheno[, cohortId := cohortIdBase + seq_len(.N)]
stopifnot(!anyDuplicated(pheno$cohortName))

template <- paste(readLines(templateFile, warn = FALSE), collapse = "\n")

for (i in seq_len(nrow(pheno))) {
  conceptIds <- paste(strsplit(pheno$SNOMED[i], " ")[[1]], collapse = ",")
  sql <- gsub("@concept_ids", conceptIds, template, fixed = TRUE)
  writeLines(sql, file.path(sqlFolder, paste0(pheno$cohortName[i], ".sql")))
}

# Keep hand-made cohorts, replace any previously generated CCSR rows.
cohorts <- fread(cohortsFile, colClasses = "character")
cohorts <- cohorts[!name %chin% pheno$cohortName]
cohorts <- rbind(cohorts, pheno[, .(atlasId = as.character(cohortId),
                                    atlasName = Phenotype,
                                    cohortId = as.character(cohortId),
                                    name = cohortName)])
fwrite(cohorts, cohortsFile)
