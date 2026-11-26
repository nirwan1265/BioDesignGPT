## Biodes -> Simitall -> Bioana: RNA-seq, genotype x drought (interaction goal)
suppressMessages({ library(studyforge); library(simitall); library(bioana) })
`%||%` <- function(a, b) if (is.null(a)) b else a
## 1. Biodes
a <- studyforge_ask("RNA-seq of leaves from wild type and mutant Arabidopsis under drought and well-watered conditions, 4 plants per genotype per treatment; we want genes whose drought response differs between genotypes.")
print(a$questions)
a <- studyforge_fix(a, experimental_unit = "plant")
spec <- a$spec
book <- layout_from_spec(spec, seed = 2026)
out <- path.expand("~/biodes_runs/e2e_rnaseq_arabidopsis")   # this study's folder
unlink(out, recursive = TRUE)
write_design_package(book, spec, out)
js <- jsonlite::fromJSON(file.path(out, "study_spec.json"))   # goals are filled when the package is written
cat("goals:", js$analysis$goals, "| factors:", paste0(js$factors$name, collapse = ", "), "\n")
cat("design:", attr(book, "design"), "| libraries:", nrow(book), "\n")

## 2. Simitall: counts.tsv (genes x samples) with known DE and interaction genes
simitall_from_biodes(out, n_genes = 5000)

## 3. Bioana: DESeq2 with the design's model; recovery of the interaction genes
res <- bioana_analyze(out, allow_fallback = FALSE, secondary = FALSE)
str(res$summary, max.level = 2)
