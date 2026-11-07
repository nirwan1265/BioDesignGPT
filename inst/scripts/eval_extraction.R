#!/usr/bin/env Rscript
# Score StudyForge's spec extraction against the bundled paper-grounded examples.
#   Rscript eval_extraction.R                 # free offline extractor (default)
#   Rscript eval_extraction.R ollama qwen2.5  # conversational agent on a free local model
# Writes eval_results.tsv.
library(studyforge)

args <- commandArgs(trailingOnly = TRUE)
provider <- if (length(args)) args[1] else "local"

extractor <- if (provider == "local") {
  extract_spec_local
} else {
  model <- if (length(args) > 1) args[2] else NULL
  function(question) {
    chat <- studyforge_chat(provider = provider, model = model, outdir = tempfile("sf_eval_"))
    tryCatch(chat$chat(paste(question, "\n\n(Record everything I stated with spec_update, then ask your questions.)"),
                       echo = "none"), error = function(e) NULL)
    attr(chat, "studyforge_state")$spec
  }
}

res <- evaluate_extraction(extractor)
utils::write.table(res$by_example, "eval_results.tsv", sep = "\t", row.names = FALSE, quote = FALSE)
print(res$by_example)
cat(sprintf("\n[%s] field recall %.1f%% | examples with invented values: %d / %d | right design suggested: %.0f%%\n",
            provider, 100 * res$field_recall, res$examples_with_invented_values,
            nrow(res$by_example), 100 * res$design_hit_rate))
