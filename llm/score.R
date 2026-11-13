# Score reader predictions against every labelled set: rules alone, reader alone, rules + reader (facts only).
#   Rscript llm/score.R llm/preds                       one folder of preds_llm_*.json
#   Rscript llm/score.R WORK/eval_base WORK/eval_ft     compare base vs fine-tuned
# Run from the repo root. Field recall in %, then examples with an invented must-ask value.
args <- commandArgs(trailingOnly = TRUE)
if (!length(args)) args <- "llm/preds"
suppressMessages(pkgload::load_all(".", quiet = TRUE))
sets <- c(study_examples = "inst/examples/study_examples.jsonl", fresh_v1 = "training/data/fresh_test.jsonl",
          fresh_v2 = "training/data/fresh_test_v2.jsonl", fresh_v3 = "training/data/fresh_test_v3.jsonl",
          fresh_v4 = "training/data/fresh_test_v4.jsonl", grounded = "training/data/grounded_eval.jsonl")
rows <- list()
for (s in names(sets)) {
  ex <- lapply(readLines(sets[[s]], warn = FALSE), jsonlite::fromJSON, simplifyVector = FALSE)
  h <- evaluate_extraction(extract_spec_local, ex)
  r <- data.frame(set = s, n = length(ex), rules = round(100 * h$field_recall, 1))
  inv <- c(rules = h$examples_with_invented_values)
  for (d in args) {
    f <- file.path(d, paste0("preds_llm_", sub("\\.jsonl$", "", basename(sets[[s]])), ".json"))
    if (!file.exists(f)) next
    P <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    tag <- basename(normalizePath(d))
    h1 <- evaluate_extraction(function(q) P[[q]] %||% list(), ex)
    h2 <- evaluate_extraction(function(q) merge_specs(extract_spec_local(q), P[[q]], q), ex)
    r[[paste0(tag, ":alone")]] <- round(100 * h1$field_recall, 1)
    r[[paste0(tag, ":merged")]] <- round(100 * h2$field_recall, 1)
    inv[paste0(tag, ":merged")] <- h2$examples_with_invented_values
  }
  rows[[s]] <- cbind(r, invented = paste(names(inv), inv, sep = "=", collapse = " "))
}
out <- do.call(rbind, rows)
print(out[, setdiff(names(out), "invented")], row.names = FALSE)
cat("\ninvented must-ask values (examples):\n"); for (s in names(rows)) cat(sprintf("  %-15s %s\n", s, rows[[s]]$invented))
