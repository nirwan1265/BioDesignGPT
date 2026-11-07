#!/usr/bin/env Rscript
# Interactive StudyForge session.
#   Rscript studyforge_cli.R            # terminal chat
#   Rscript studyforge_cli.R --browser  # Shiny chat in the browser
# Requires: ANTHROPIC_API_KEY, and packages studyforge + ellmer.
library(studyforge)

args <- commandArgs(trailingOnly = TRUE)
chat <- studyforge_chat(outdir = "studyforge_run")

if ("--browser" %in% args) {
  ellmer::live_browser(chat)
} else {
  ellmer::live_console(chat)
}
