## Biodes -> Simitall -> Bioana: GWAS diversity panel
## Sorghum, 300 accessions, alpha lattice, 2 replicates, plant height.
suppressMessages({ library(studyforge); library(simitall); library(bioana) })
`%||%` <- function(a, b) if (is.null(a)) b else a
## 1. Biodes: read the question, answer what it asks, build and write the design
a <- studyforge_ask("GWAS of plant height in 300 sorghum accessions grown in an alpha lattice with 2 replicates at one location.")
print(a$questions)                                   # what Biodes still wants to know
a <- studyforge_fix(a,
  design.locations = 1,
  primary_outcome.unit = "cm",
  primary_outcome.baseline_mean = 150,
  power.residual_sd = 15)
spec <- a$spec
book <- layout_from_spec(spec, seed = 2026)
out <- path.expand("~/biodes_runs/e2e_gwas_sorghum")   # this study's folder
unlink(out, recursive = TRUE)
write_design_package(book, spec, out)
js <- jsonlite::fromJSON(file.path(out, "study_spec.json"))   # goals are filled when the package is written
cat("goals:", js$analysis$goals, "| factors:", paste0(js$factors$name, collapse = ", "), "\n")
cat("design:", spec$design$chosen %||% attr(book, "design"), "| plots:", nrow(book), "\n")

## 2. Simitall: genotypes + phenotypes at a chosen heritability
simitall_from_biodes(out, params = list(suite_genetics = list(heritability = 0.6)))

## 3. Bioana: GWAS (rrBLUP; GAPIT as secondary) and recovery of the planted QTL
res <- bioana_analyze(out, allow_fallback = FALSE, secondary = FALSE)
str(res$summary, max.level = 2)
