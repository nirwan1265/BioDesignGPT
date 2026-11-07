# Rebuild inst/examples/study_examples.jsonl from the readable JSON sources.
# Run from the package root: Rscript data-raw/build_examples.R
srcs <- c("data-raw/study_examples.json", "data-raw/study_plans_v2.json")
ex <- unlist(lapply(srcs, jsonlite::fromJSON, simplifyVector = FALSE), recursive = FALSE)
dir.create("inst/examples", showWarnings = FALSE, recursive = TRUE)
lines <- vapply(ex, function(e) as.character(jsonlite::toJSON(e, auto_unbox = TRUE, null = "null")), "")
writeLines(lines, "inst/examples/study_examples.jsonl")
message("Wrote ", length(lines), " examples")
