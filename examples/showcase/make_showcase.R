# Builds the three showcase examples from a plain-language question each, with fixed answers and seed 2026.
# Run from the repository root:  Rscript examples/showcase/make_showcase.R
# Each folder gets: question.txt, questions_asked.txt, the Biodes package (study_spec.json, field_layout.csv,
# sample_metadata_template.tsv), layout_map.png and README.md. Simitall, Bioana and Biopaint continue from these folders.
suppressMessages({ library(studyforge); library(jsonlite); library(ggplot2) })
`%||%` <- function(a, b) if (is.null(a)) b else a
root <- "examples/showcase"
seed <- 2026

examples <- list(
  list(dir = "01_gwas_sorghum",
       title = "GWAS of plant height in a sorghum diversity panel",
       question = "GWAS of plant height in 300 sorghum accessions grown in an alpha lattice with 2 replicates at one location in one season.",
       answers = list(primary_outcome.unit = "cm", power.residual_sd = 15),
       answers_text = "plant height in cm; plot-to-plot SD about 15 cm from earlier trials"),
  list(dir = "02_rnaseq_drought",
       title = "RNA-seq: which genes respond to drought differently in a mutant",
       question = "RNA-seq of leaves from wild type and mutant Arabidopsis under drought and well-watered conditions, 4 plants per genotype per treatment; we want genes whose drought response differs between genotypes.",
       answers = list(experimental_unit = "plant"),
       answers_text = "one plant is one biological replicate"),
  list(dir = "03_germination_survival",
       title = "Seed priming and time to germination (survival design)",
       question = "Seeds of 2 sorghum lines primed or not in 12 trays in a growth chamber, 10 seeds per treatment per tray, days to germination checked every 2 days, followed for 21 days; seed rot can occur before germination; the priming effect is delayed; hazard ratio 0.6; germination by day 7 and 14.",
       answers = list(),
       answers_text = "none needed for the design: one chamber, no repeated runs, trays are the blocks")
)

layout_map <- function(book, spec, file) {
  b <- book
  b$block <- as.integer(b$block %||% 1L); b$rep <- as.integer(b$rep %||% 1L)
  trt_cols <- intersect(vapply(spec$factors, `[[`, "", "name"), names(b))
  b$group <- if (length(trt_cols)) do.call(paste, c(b[trt_cols], sep = " / ")) else "unit"
  b$pos <- stats::ave(seq_len(nrow(b)), b$rep, b$block, FUN = seq_along)
  many <- length(unique(b$group)) > 12
  nested <- any(tapply(b$block, b$rep, function(x) length(unique(x))) > 1)   # incomplete blocks inside replicates
  b$row <- factor(b$block, levels = rev(sort(unique(b$block))))
  p <- ggplot(b, aes(x = pos, y = row)) +
    geom_tile(aes(fill = if (many) as.integer(factor(group)) else group), colour = "white", linewidth = 0.4) +
    labs(x = "position", y = "block", fill = if (many) NULL else paste(trt_cols, collapse = " / "),
         title = sprintf("%s design, %d units, randomization seed %d", attr(book, "design"), nrow(b), seed),
         subtitle = if (many) sprintf("%d entries, each once per replicate, shuffled within %d incomplete blocks; colour = entry number", length(unique(b$group)), length(unique(b$block)) / length(unique(b$rep))) else NULL) +
    theme_minimal(base_size = 11) + theme(panel.grid = element_blank(), legend.position = if (many) "none" else "right")
  if (nested) p <- p + facet_wrap(~ paste("Replicate", rep), scales = "free_y", ncol = 2)
  if (many) p <- p + scale_fill_viridis_c() + theme(axis.text.y = element_blank())
  h <- if (nested) 7 else max(2.5, min(9, 1.2 + 0.32 * length(unique(b$block))))
  ggsave(file, p, width = 9, height = h, dpi = 120, bg = "white")
}

fmt <- function(x) if (is.null(x) || !length(x)) "" else if (is.list(x)) as.character(toJSON(x, auto_unbox = TRUE)) else paste(x, collapse = ", ")

for (ex in examples) {
  out <- file.path(root, ex$dir); unlink(out, recursive = TRUE); dir.create(out, recursive = TRUE)
  writeLines(ex$question, file.path(out, "question.txt"))
  a <- studyforge_ask(ex$question)
  writeLines(c("# What Biodes asked before designing", a$questions, "", "# Answers given in this example", ex$answers_text),
             file.path(out, "questions_asked.txt"))
  if (length(ex$answers)) a <- do.call(studyforge_fix, c(list(a), ex$answers))
  spec <- a$spec
  book <- layout_from_spec(spec, seed = seed)
  write_design_package(book, spec, out)
  layout_map(book, spec, file.path(out, "layout_map.png"))
  j <- fromJSON(file.path(out, "study_spec.json"), simplifyVector = FALSE)
  meta <- utils::read.delim(file.path(out, "sample_metadata_template.tsv"))
  fac <- vapply(j$factors, function(f) sprintf("`%s` (%s)", f$name, if (length(f$levels)) paste(unlist(f$levels), collapse = ", ") else paste(f$n_levels, "levels")), "")
  pw <- j$power %||% list()
  power_line <- if (!is.null(pw$method)) sprintf("%s, %s = %s (%s), alpha %s, power %s: **%s %s**", pw$method, pw$effect_size_name, pw$effect_size,
      pw$source, pw$alpha, pw$power, pw$n_per_group %||% pw$n_total, if (!is.null(pw$n_per_group)) "per group" else "in total")
    else if (!is.null(pw$events_required)) sprintf("Schoenfeld: hazard ratio %s needs **%s events** (alpha 0.05, power 0.8)", pw$target_hazard_ratio, pw$events_required)
    else if (!is.null(pw$reps_range)) sprintf("replicates are open: Simitall sweeps %s to %s", pw$reps_range[[1]], pw$reps_range[[2]])
    else "no closed form for this goal: checked by simulation in Simitall (replicates as stated)"
  surv <- j$analysis$survival
  plural <- function(n, w) if (n == 1 || grepl("s$", w)) w else paste0(w, "s")
  unit_w <- j$experimental_unit %||% "unit"; if (identical(unit_w, "cell")) unit_w <- "tray cell"
  surv_line <- if (length(surv)) paste(c(
      if (length(surv$landmarks)) sprintf("share germinated at days %s", paste(unlist(surv$landmarks), collapse = " and ")),
      if (!is.null(surv$logrank_weight)) sprintf("weighted log-rank `%s` (stated delayed effect)", surv$logrank_weight),
      if (!is.null(surv$life_table)) sprintf("life table in %s-day intervals", surv$life_table),
      if (!is.null(surv$strata)) sprintf("strata: %s", paste(unlist(surv$strata), collapse = ", ")),
      if (!is.null(surv$cluster)) sprintf("seeds clustered in `%s`", surv$cluster)), collapse = "; ") else NULL
  assays <- unlist(j$assays)
  outcome_line <- if (length(intersect(assays, c("rnaseq", "rna_seq", "rna-seq")))) "gene counts per sample (RNA-seq)" else
    sprintf("%s (%s%s)", j$primary_outcome$name %||% j$primary_outcome$event %||% "primary outcome", j$primary_outcome$type %||% "continuous",
            if (!is.null(j$primary_outcome$unit)) paste(",", j$primary_outcome$unit) else "")
  md <- c(
    sprintf("# %s", ex$title), "",
    "**The question, as a researcher would type it:**", "", paste0("> ", ex$question), "",
    "**What Biodes asked back** (only questions that change the design):", "", paste0("- ", a$questions %||% "none"), "",
    sprintf("Answer given here: %s.", ex$answers_text), "",
    "## The design Biodes wrote", "",
    "| | |", "|---|---|",
    sprintf("| Design | `%s` |", j$design$chosen),
    sprintf("| Units | %d %s (%s) |", nrow(book), plural(nrow(book), unit_w), if (nrow(meta) != nrow(book)) sprintf("%d seeds, one row each in the sample sheet", nrow(meta)) else "one row each in the sample sheet"),
    sprintf("| Factors | %s |", paste(fac, collapse = "; ")),
    sprintf("| Outcome | %s |", outcome_line),
    sprintf("| Model | `%s` |", gsub("|", "\\|", j$analysis$model, fixed = TRUE)),
    sprintf("| Goal | `%s`%s |", j$analysis$primary_goal %||% "", if (length(j$analysis$goal_terms)) paste0(" on ", paste(unlist(j$analysis$goal_terms[[1]]), collapse = " x ")) else ""),
    sprintf("| Power | %s |", power_line),
    if (length(surv)) sprintf("| Survival analysis | %s |", surv_line) else NULL,
    if (!is.null(j$primary_outcome$event_codes)) sprintf("| Event codes | %s |", paste(sprintf("%s = %s", names(j$primary_outcome$event_codes), unlist(j$primary_outcome$event_codes)), collapse = ", ")) else NULL,
    if (!is.null(j$primary_outcome$censoring)) sprintf("| Censoring | %s |", j$primary_outcome$censoring) else NULL,
    sprintf("| Randomization seed | %d |", seed), "",
    if (length(j$assumptions)) c("**Defaults Biodes assumed (listed, never hidden):**", "", sprintf("- `%s`: %s", names(j$assumptions), vapply(j$assumptions, fmt, "")), "") else NULL,
    "![layout](layout_map.png)", "",
    "## Files", "",
    "- [`study_spec.json`](study_spec.json): the full StudySpec that Simitall and Bioana read",
    "- [`field_layout.csv`](field_layout.csv): the randomized layout, one row per unit",
    "- [`sample_metadata_template.tsv`](sample_metadata_template.tsv): the sample sheet to fill in",
    "- [`questions_asked.txt`](questions_asked.txt): what Biodes asked and the answers used", "",
    "## Continue this example", "",
    sprintf("- **Simitall** simulates data for this exact design: [simitall/examples/showcase/%s](https://github.com/nirwan1265/simitall/tree/main/examples/showcase/%s)", ex$dir, ex$dir),
    sprintf("- **Bioana** analyzes it with the model above and checks the planted truth: [Bioana/examples/showcase/%s](https://github.com/nirwan1265/Bioana/tree/main/examples/showcase/%s)", ex$dir, ex$dir),
    sprintf("- **Biopaint** draws the figures: Biopaint/examples/showcase/%s (in progress)", ex$dir), "",
    "Rebuild this folder: `Rscript examples/showcase/make_showcase.R` (from the repository root).")
  writeLines(unlist(md), file.path(out, "README.md"))
  cat("built", out, "\n")
}
