# Rebuild inst/examples/study_examples.jsonl from the readable JSON source.
# Run from the package root: Rscript data-raw/build_examples.R
ex <- jsonlite::fromJSON("data-raw/study_examples.json", simplifyVector = FALSE)
dir.create("inst/examples", showWarnings = FALSE, recursive = TRUE)
lines <- vapply(ex, function(e) as.character(jsonlite::toJSON(e, auto_unbox = TRUE, null = "null")), "")
writeLines(lines, "inst/examples/study_examples.jsonl")
message("Wrote ", length(lines), " examples")
