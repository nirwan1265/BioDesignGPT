#!/usr/bin/env Rscript
# Regression eval: feed each example prompt to the agent (one turn, no
# follow-up answers) and score how much of the expected StudySpec it captured,
# whether it avoided filling must-ask fields, and whether it recommended a
# matching design.
#   Rscript eval_extraction.R [model]
# Writes eval_results.tsv. Requires ANTHROPIC_API_KEY and ellmer.
library(studyforge)

model <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(model)) model <- "claude-sonnet-5-5"

ex <- load_examples()
rows <- lapply(ex, function(e) {
  chat <- studyforge_chat(model = model, outdir = file.path(tempdir(), e$id))
  reply <- tryCatch(
    chat$chat(paste(e$prompt,
                    "\n\n(Record everything I stated with spec_update, then ask your questions.)"),
              echo = "none"),
    error = function(err) paste("ERROR:", conditionMessage(err)))
  spec <- attr(chat, "studyforge_state")$spec

  sc <- score_extraction(spec, e$expected_spec)
  leaked <- vapply(unlist(e$must_ask), function(p) {
    v <- spec_get(spec, p)
    !is.null(v) && is.null(spec$assumptions[[p]])
  }, logical(1))
  design_hit <- any(vapply(unlist(e$recommended_designs),
                           function(d) grepl(d, reply, ignore.case = TRUE), logical(1)))

  data.frame(id = e$id,
             fields_matched = sum(sc$match), fields_expected = nrow(sc),
             invented_must_ask = sum(leaked),
             mentions_recommended_design = design_hit)
})

res <- do.call(rbind, rows)
utils::write.table(res, "eval_results.tsv", sep = "\t", row.names = FALSE, quote = FALSE)
print(res)
cat(sprintf("\nField recall: %.1f%% | examples with invented values: %d / %d\n",
            100 * sum(res$fields_matched) / sum(res$fields_expected),
            sum(res$invented_must_ask > 0), nrow(res)))
