## Biodes -> Simitall -> Bioana: inbred lines by selfing (RILs to F6), QTL mapping
suppressMessages({ library(studyforge); library(simitall); library(bioana) })
`%||%` <- function(a, b) if (is.null(a)) b else a
## 1. Biodes
a <- studyforge_ask("QTL mapping of days to anthesis in 200 maize RILs from a B73 x Mo17 cross selfed to F6, grown in 2 replicates in a randomized complete block design.")
print(a$questions)
a <- studyforge_fix(a,
  design.locations = 1,
  primary_outcome.unit = "days",
  primary_outcome.baseline_mean = 70,
  power.residual_sd = 3)
spec <- a$spec
book <- layout_from_spec(spec, seed = 2026)
out <- path.expand("~/biodes_runs/e2e_ril_maize")   # this study's folder
unlink(out, recursive = TRUE)
write_design_package(book, spec, out)
js <- jsonlite::fromJSON(file.path(out, "study_spec.json"))   # goals are filled when the package is written
cat("goals:", js$analysis$goals, "| factors:", paste0(js$factors$name, collapse = ", "), "\n")
cat("design:", attr(book, "design"), "| plots:", nrow(book), "| mating:", unlist(spec$population$mating), "\n")

## 2. Simitall: RILs from simulate_breeding() (two founders, selfed to F6) + phenotypes
simitall_from_biodes(out, params = list(suite_genetics = list(heritability = 0.7)))

## 3. Bioana: marker-trait scan on the RILs and recovery of the planted QTL
res <- bioana_analyze(out, allow_fallback = FALSE, secondary = FALSE)
str(res$summary, max.level = 2)
