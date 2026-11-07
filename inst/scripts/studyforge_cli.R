#!/usr/bin/env Rscript
# StudyForge from the terminal. Free by default.
#   Rscript studyforge_cli.R "120 maize lines, drought, two locations, 3 reps"   # one question, offline
#   Rscript studyforge_cli.R                                                     # interactive, offline
#   Rscript studyforge_cli.R --ollama "..."                                       # free local LLM rephrasing
#   Rscript studyforge_cli.R --chat                                               # conversational agent via Ollama
#   Rscript studyforge_cli.R --app                                                # local Shiny app
library(studyforge)

args <- commandArgs(trailingOnly = TRUE)
flags <- args[startsWith(args, "--")]
question <- paste(args[!startsWith(args, "--")], collapse = " ")
provider <- if ("--ollama" %in% flags) "ollama" else "local"

if ("--app" %in% flags) {
  launch_studyforge(launch.browser = TRUE)
} else if ("--chat" %in% flags) {
  ellmer::live_console(studyforge_chat(provider = "ollama"))
} else if (nzchar(question)) {
  print(studyforge_ask(question, provider = provider))
} else {
  con <- file("stdin")
  cat("Describe your experiment (empty line to quit):\n> ")
  while (length(line <- readLines(con, n = 1)) && nzchar(line)) {
    print(studyforge_ask(line, provider = provider))
    cat("\n> ")
  }
  close(con)
}
