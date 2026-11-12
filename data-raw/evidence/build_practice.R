#!/usr/bin/env Rscript
# build_practice.R -- compact "published practice" tables shipped with the package.
#
# From the evidence layer (enrich_evidence.R combine) to two small files:
#   inst/extdata/published_practice.tsv.gz  species x technique x tissue: designed studies, replicates per
#                                        condition (median, IQR), samples, read depth, sequencers, kits, years
#   inst/extdata/published_studies.tsv.gz   up to 5 citable designed studies per group (DOI-linked), with the
#                                        design each actually used
# Usage (repo root):
#   Rscript data-raw/evidence/build_practice.R path/to/evidence
suppressPackageStartupMessages(library(data.table))

args <- commandArgs(trailingOnly = TRUE)
ev <- if (length(args)) args[1] else "evidence"
rd <- function(f) fread(file.path(ev, f), sep = "\t", quote = "", na.strings = "", colClasses = "character",
                        encoding = "UTF-8", showProgress = FALSE)
bs <- rd("all_species_by_study.tsv")
fx <- rd("all_species_study_factors.tsv")
pp <- rd("all_species_papers.tsv")

POP <- c("WGS / resequencing", "GBS / RAD-seq", "Amplicon", "Exome", "Targeted capture")
SKIP <- c("OTHER", "unclassified")
bs <- bs[designed == "TRUE" & !technique %in% SKIP & !is.na(technique)]

# ---- per-study values ----------------------------------------------------------------------------
first_item <- function(x) trimws(sub(" \\(\\d+\\)$", "", sub(";.*$", "", x)))
num <- function(x) suppressWarnings(as.numeric(x))

TISSUE <- c(leaves = "leaf", roots = "root", seedlings = "seedling", seeds = "seed", shoots = "shoot",
            flowers = "flower", fruits = "fruit", stems = "stem", embryos = "embryo", buds = "bud",
            panicles = "panicle", berries = "berry", tubers = "tuber", "whole plants" = "whole plant",
            "whole seedlings" = "seedling", "young leaves" = "leaf", "young leaf" = "leaf", "leaf tissue" = "leaf",
            "root tissue" = "root", "fruit flesh" = "fruit", "liver tissue" = "liver", "whole blood" = "blood",
            "peripheral blood" = "blood", "skeletal muscle" = "muscle", "whole body" = "whole body",
            "whole larvae" = "whole larvae", "whole flies" = "whole body", "whole worms" = "whole body")
norm_tissue <- function(x) {
  t <- tolower(first_item(x))
  t[is.na(t) | !nzchar(t) | nchar(t) > 25 | grepl("\\d{3,}|[:/=_]|^(missing|not |na$|n/a|unknown|sample|tissue|none|other|mixed)", t)] <- NA
  t <- ifelse(t %in% names(TISSUE), TISSUE[t], t)
  t <- sub("^(.+[^s])s$", "\\1", t)                                    # simple plural -> singular
  ifelse(grepl("^(leave|leafs)$", t), "leaf", t)
}

bs[, `:=`(
  tissue = norm_tissue(tissues),
  instrument = first_item(instruments),
  mreads = num(median_Mreads),
  n_samp = num(n_samples),
  n_cond = num(n_conditions),
  year_i = suppressWarnings(as.integer(year))
)]
# replicates per condition: BioSample cell sizes first, then sample-title grouping; whole numbers 1-24 only
fx[, reps_fx := num(reps_per_cell)]
bs <- merge(bs, fx[, .(species, study_group, technique, reps_fx, factors)], by = c("species", "study_group", "technique"), all.x = TRUE)
bs[, reps := fifelse(!is.na(reps_fx), reps_fx, num(reps_per_condition))]
bs[!is.na(reps) & (reps != round(reps) | reps < 1 | reps > 24), reps := NA]
bs[technique %in% POP, reps := NA]
bs[technique %in% POP, n_cond := NA]

# kits mentioned (normalised names, one count per study)
kit_names <- function(k) {
  if (is.na(k) || !nzchar(k)) return(character())
  v <- trimws(sub(" \\(\\d+\\)$", "", strsplit(k, "; ", fixed = TRUE)[[1]]))
  v <- gsub("\\s+", " ", v)
  v <- ifelse(grepl("^trizol$", v, ignore.case = TRUE), "TRIzol", v)
  unique(v[nchar(v) >= 3])
}

# linked papers (DOI) per study
pl <- pp[confidence == "linked" & !is.na(doi) & nzchar(doi)]
pl <- pl[order(species, study_group, -num(year))][, .SD[1], by = .(species, study_group)]
bs <- merge(bs, pl[, .(species, study_group, doi, paper_year = year, paper_title = title, pmid)],
            by = c("species", "study_group"), all.x = TRUE)

# ---- group summaries -----------------------------------------------------------------------------
top_str <- function(x, n = 3) {
  x <- x[!is.na(x) & nzchar(x)]
  if (!length(x)) return(NA_character_)
  t <- head(sort(table(x), decreasing = TRUE), n)
  paste(sprintf("%s (%d)", names(t), as.integer(t)), collapse = "; ")
}
q <- function(x, p) { x <- x[!is.na(x)]; if (length(x)) as.numeric(stats::quantile(x, p, names = FALSE, type = 7)) else NA_real_ }
summ <- function(d) {
  recent <- d[!is.na(year_i) & year_i >= max(d$year_i, na.rm = TRUE) - 4]
  list(
    n_designed = nrow(d),
    n_with_reps = sum(!is.na(d$reps)),
    reps_median = q(d$reps, .5), reps_q25 = q(d$reps, .25), reps_q75 = q(d$reps, .75),
    share_reps_ge6 = if (any(!is.na(d$reps))) round(mean(d$reps >= 6, na.rm = TRUE), 2) else NA_real_,
    samples_median = q(d$n_samp, .5),
    conditions_median = q(d$n_cond, .5),
    mreads_median = round(q(d$mreads, .5), 1), mreads_q25 = round(q(d$mreads, .25), 1), mreads_q75 = round(q(d$mreads, .75), 1),
    top_instruments = top_str(d$instrument, 3),
    top_instruments_recent = top_str(recent$instrument, 3),
    top_kits = top_str(unlist(lapply(d$kits, kit_names)), 4),
    years = if (any(!is.na(d$year_i))) paste(range(d$year_i, na.rm = TRUE), collapse = "-") else NA_character_,
    n_with_paper = sum(!is.na(d$doi))
  )
}
all_t <- bs[, summ(.SD), by = .(species, organism, group, technique)][, tissue := "all"]
tis_t <- bs[!is.na(tissue), if (.N >= 5) summ(.SD), by = .(species, organism, group, technique, tissue)]
practice <- rbind(all_t, tis_t, use.names = TRUE)
setcolorder(practice, c("species", "organism", "group", "technique", "tissue"))
practice <- practice[n_designed >= 3][order(species, technique, tissue != "all", -n_designed)]

# ---- citable examples ----------------------------------------------------------------------------
cite <- bs[!is.na(doi)]
cite[, score := (!is.na(reps)) * 2 + (!is.na(factors)) + pmin(num(year), 2030) / 10000]
pick <- function(d, n) head(d[order(-score)], n)
ex_all <- cite[, pick(.SD, 5), by = .(species, technique)][, tissue_group := "all"]
ex_tis <- cite[!is.na(tissue), pick(.SD, 3), by = .(species, technique, tissue)][, tissue_group := tissue]
studies <- rbind(ex_all, ex_tis, use.names = TRUE, fill = TRUE)
studies <- unique(studies[, .(species, technique, tissue_group, study = study, year = year_i,
                              n_samples = n_samp, reps, design = substr(factors, 1, 90), instrument, mreads, doi,
                              title = substr(paper_title, 1, 110))])

dir.create("inst/extdata", showWarnings = FALSE, recursive = TRUE)
fwrite(practice, "inst/extdata/published_practice.tsv.gz", sep = "\t", na = "", compress = "gzip")
fwrite(studies, "inst/extdata/published_studies.tsv.gz", sep = "\t", na = "", compress = "gzip")
cat(sprintf("published_practice.tsv: %d rows (%d species x technique groups); published_studies.tsv: %d rows\n",
            nrow(practice), nrow(all_t[n_designed >= 3]), nrow(studies)))
cat(sprintf("sizes: %.0f KB, %.0f KB\n", file.size("inst/extdata/published_practice.tsv.gz") / 1024,
            file.size("inst/extdata/published_studies.tsv.gz") / 1024))
