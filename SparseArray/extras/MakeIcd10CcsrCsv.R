# ---------------------------------------------------------------------------
# Builds codes/icd10ccsr.csv  (CCSR / ICD-10-CM analogue of codes/icd9ccs.csv)
#
# Scope: the conditions covered by codes/icd9ccs.csv, except
#   "Complications of surgical/medical care" (CCS 238), which CCSR scatters over
#   ~22 categories and so cannot be expressed as one phenotype.
#
# Design: exactly ONE CCSR category per phenotype, and the phenotype name IS the
# CCSR category description, read from the reference file (so names can never
# drift from the official taxonomy). Three CCS categories that CCSR splits in two
# therefore become two rows each - see the `+` comments below.
#
# Input : codes/DXCCSR_v2026-1.csv   (AHRQ HCUP DXCCSR reference file)
# Output: codes/icd10ccsr.csv        Phenotype,type,CCSR,ICD10
#
# One-off script, not part of the package. Run from the repository root.
# Rewrites icd10ccsr.csv from scratch, so any SNOMED column added by
# AddSnomedToIcd10CcsrCsv.R is dropped - re-run that script afterwards.
# ---------------------------------------------------------------------------

suppressPackageStartupMessages(library(data.table))

in_dx    <- "codes/DXCCSR_v2026-1.csv"
out_file <- "codes/icd10ccsr.csv"

# Which CCSR assignment to use:
#   "default_ip" - Default CCSR CATEGORY IP   (one category per code, like CCS)
#   "default_op" - Default CCSR CATEGORY OP
#   "any"        - CCSR CATEGORY 1..6 (a code may then land in two phenotypes)
category_source <- "default_ip"

# ---------------------------------------------------------------------------
# 1. the phenotype set: CCSR category -> acute / chronic / mixed
#    `type` is carried over from icd9ccs.csv; CCS -> CCSR notes on the right.
# ---------------------------------------------------------------------------
pheno <- data.table(
  ccsr = c("GEN002",   # CCS 157  Acute and unspecified renal failure
           "CIR020",   # CCS 109  Acute cerebrovascular disease  (split 1/2)
           "CIR021",   # CCS 109                                 (split 2/2)
           "CIR009",   # CCS 100  Acute myocardial infarction
           "CIR017",   # CCS 106  Cardiac dysrhythmias
           "GEN003",   # CCS 158  Chronic kidney disease
           "RSP008",   # CCS 127  COPD  (+ bronchiectasis in CCSR)
           "CIR016",   # CCS 105  Conduction disorders
           "CIR019",   # CCS 108  CHF   (+ hypertensive HF in CCSR)
           "CIR011",   # CCS 101  Coronary atherosclerosis
           "END003",   # CCS  50  Diabetes mellitus with complications
           "END002",   # CCS  49  Diabetes mellitus without complication
           "END010",   # CCS  53  Disorders of lipid metabolism
           "CIR007",   # CCS  98  Essential hypertension
           "END011",   # CCS  55  Fluid and electrolyte disorders
           "DIG021",   # CCS 153  Gastrointestinal hemorrhage
           "CIR008",   # CCS  99  Hypertension with complications (+ secondary)
           "DIG018",   # CCS 151  Other liver diseases            (split 1/2)
           "DIG019",   # CCS 151                                  (split 2/2)
           "RSP016",   # CCS 133  Other lower respiratory disease
           "RSP007",   # CCS 134  Other upper respiratory disease
           "RSP011",   # CCS 130  Pleurisy; pneumothorax; collapse (split 1/2)
           "RSP014",   # CCS 130                                  (split 2/2)
           "RSP002",   # CCS 122  Pneumonia
           "RSP012",   # CCS 131  Respiratory failure
           "INF002",   # CCS   2  Septicemia (except in labor)
           "SYM003"),  # CCS 249  Shock  (not in icd9ccs.csv; added on request)
  type = c("acute",
           "acute", "acute",
           "acute",
           "mixed",
           "chronic",
           "chronic",
           "mixed",
           "mixed",
           "chronic",
           "mixed",
           "chronic",
           "chronic",
           "chronic",
           "acute",
           "acute",
           "chronic",
           "acute", "mixed",
           "acute",
           "acute",
           "acute", "acute",
           "acute",
           "acute",
           "acute",
           "acute")   # Shock
)
stopifnot(!anyDuplicated(pheno$ccsr))

# ---------------------------------------------------------------------------
# 2. read + tidy DXCCSR  (every field is wrapped in single quotes)
# ---------------------------------------------------------------------------
unq <- function(x) trimws(gsub("^'|'$", "", trimws(x)))

dx <- fread(in_dx, colClasses = "character", showProgress = FALSE)
setnames(dx, trimws(gsub("^'|'$", "", names(dx))))

icd10   <- unq(dx[["ICD-10-CM CODE"]])
cat_col <- switch(category_source,
  default_ip = list(unq(dx[["Default CCSR CATEGORY IP"]])),
  default_op = list(unq(dx[["Default CCSR CATEGORY OP"]])),
  any        = lapply(sprintf("CCSR CATEGORY %d", 1:6), function(n) unq(dx[[n]])),
  stop("bad category_source")
)

long <- unique(rbindlist(lapply(cat_col, function(cc)
  data.table(icd10 = icd10, ccsr = cc)))[nzchar(ccsr) & ccsr != "XXX000"])

# official category code -> description, used as the phenotype name
desc <- unique(rbindlist(lapply(1:6, function(n) data.table(
  ccsr  = unq(dx[[sprintf("CCSR CATEGORY %d", n)]]),
  Phenotype = unq(dx[[sprintf("CCSR CATEGORY %d DESCRIPTION", n)]])
)))[nzchar(ccsr)], by = "ccsr")

# ---------------------------------------------------------------------------
# 3. assemble
# ---------------------------------------------------------------------------
missing_cats <- setdiff(pheno$ccsr, desc$ccsr)
if (length(missing_cats))
  stop("CCSR categories absent from the reference file: ",
       paste(missing_cats, collapse = ", "))

out <- desc[pheno, on = "ccsr"][
  , .(Phenotype, type, CCSR = ccsr,
      ICD10 = vapply(ccsr, function(k)
        paste(sort(unique(long[ccsr == k, icd10])), collapse = " "), ""))]
setorder(out, Phenotype)
stopifnot(all(nzchar(out$ICD10)))

fwrite(out, out_file, quote = TRUE)
cat(sprintf("wrote %s - %d phenotypes, %d ICD-10-CM codes\n\n",
            out_file, nrow(out), sum(lengths(strsplit(out$ICD10, " ")))))
print(out[, .(Phenotype, type, CCSR, n_icd10 = lengths(strsplit(ICD10, " ")))],
      nrows = 100, class = FALSE)
