# Published practice: what designed studies in public archives actually did.
# Tables are built by data-raw/evidence/build_practice.R from the evidence layer (ENA/SRA, GEO, BioSample,
# Europe PMC) and shipped in inst/extdata. They describe practice, not correctness: a plan shows them next
# to the rule (power analysis), never instead of it.

.sf_practice_cache <- new.env()

.sf_practice_tables <- function() {
  if (is.null(.sf_practice_cache$p)) {
    rd <- function(f) {
      path <- system.file("extdata", f, package = "studyforge")
      if (!nzchar(path)) return(NULL)
      utils::read.delim(gzfile(path), quote = "", stringsAsFactors = FALSE, na.strings = "", check.names = FALSE)
    }
    .sf_practice_cache$p <- rd("published_practice.tsv.gz")
    .sf_practice_cache$s <- rd("published_studies.tsv.gz")
  }
  list(practice = .sf_practice_cache$p, studies = .sf_practice_cache$s)
}

# spec system / assay canonical terms -> evidence technique labels
.SF_TECH_BY_SYSTEM <- c(bulk_rnaseq = "Bulk RNA-seq", single_cell = "scRNA/snRNA-seq", ribo_seq = "Ribo-seq",
                        atac_seq = "ATAC-seq")
.SF_TECH_BY_ASSAY <- c(rnaseq = "Bulk RNA-seq", small_rnaseq = "small RNA-seq", single_cell = "scRNA/snRNA-seq",
                       ribo_seq = "Ribo-seq", atac_seq = "ATAC-seq", chip_seq = "ChIP-seq",
                       methylation = "Bisulfite / methylome", scatac_seq = "scATAC-seq", amplicon = "Amplicon",
                       m6a_seq = "m6A / MeRIP-seq", long_read_rna = "Long-read RNA (Iso-Seq/ONT)", gbs = "GBS / RAD-seq",
                       degradome = "Degradome / PARE", hic = "3D genome (Hi-C/HiChIP)", medip = "Methylation (enrichment)",
                       mnase_seq = "MNase-seq", nascent_rna = "Nascent RNA (GRO/PRO/NET)", spatial = "Spatial transcriptomics",
                       targeted_capture = "Targeted capture", rip_clip = "RIP / CLIP-seq", trap_seq = "TRAP-seq",
                       wgs = "WGS / resequencing")

.sf_norm_tissue <- function(x) {
  t <- tolower(trimws(x))
  map <- c(leaves = "leaf", roots = "root", seedlings = "seedling", seeds = "seed", shoots = "shoot")
  t <- if (t %in% names(map)) unname(map[t]) else t
  t <- sub("^(.+[^s])s$", "\\1", t)
  if (t == "leave") "leaf" else t
}

.sf_resolve_technique <- function(technique, techs) {
  if (is.null(technique) || !nzchar(technique)) return(NULL)
  if (technique %in% techs) return(technique)
  hit <- techs[tolower(techs) == tolower(technique)]
  if (length(hit)) return(hit[1])
  canon <- studyforge_alias(technique, "assay")
  if (is.na(canon)) canon <- technique
  t <- unname(c(.SF_TECH_BY_ASSAY, .SF_TECH_BY_SYSTEM)[canon])
  if (length(t) && !is.na(t)) return(t)
  hit <- techs[grepl(tolower(technique), tolower(techs), fixed = TRUE)]
  if (length(hit)) hit[1] else NULL
}

#' What published studies did for an organism and technique
#'
#' Summarises designed studies in public archives (ENA/SRA, GEO, BioSample; papers via Europe PMC) for one
#' organism and technique, optionally one tissue: how many replicates per condition they used, read depth,
#' sequencers, kits, and citable example studies with DOIs. This is descriptive: most studies use fewer
#' replicates than power analysis would ask for, so use it as context, not as a sample-size recommendation.
#'
#' @param organism Organism name or alias ("sorghum", "Zea mays", "mice", "C. elegans").
#' @param technique Technique or alias ("RNA-seq", "ATAC-seq", "ChIP-seq", "Bulk RNA-seq"). NULL lists all
#'   techniques with data for the organism.
#' @param tissue Optional tissue ("leaf", "roots", "liver"); falls back to all tissues if too few studies.
#' @param n_cite Number of example studies to return.
#' @return An object of class `studyforge_practice`, or a data frame of techniques when `technique` is NULL.
#' @export
#' @examples
#' published_practice("sorghum", "RNA-seq", "leaf")
#' published_practice("mouse")
published_practice <- function(organism, technique = NULL, tissue = NULL, n_cite = 3) {
  tb <- .sf_practice_tables()
  p <- tb$practice
  if (is.null(p)) stop("Published-practice tables not found; reinstall studyforge.", call. = FALSE)
  org <- studyforge_alias(organism, "organism")
  if (is.na(org)) org <- organism
  rows <- p[tolower(p$organism) == tolower(org) | tolower(p$species) == tolower(organism), , drop = FALSE]
  if (!nrow(rows)) {
    return(structure(list(organism = org, technique = technique, tissue = tissue, summary = NULL, studies = NULL,
                          note = sprintf("No published-practice data for '%s' yet.", organism)),
                     class = "studyforge_practice"))
  }
  if (is.null(technique)) {
    a <- rows[rows$tissue == "all", c("technique", "n_designed", "reps_median", "mreads_median", "years")]
    return(a[order(-a$n_designed), , drop = FALSE])
  }
  tech <- .sf_resolve_technique(technique, unique(rows$technique))
  note <- NULL
  r <- if (!is.null(tech)) rows[rows$technique == tech, , drop = FALSE] else rows[0, ]
  if (!nrow(r)) {
    return(structure(list(organism = rows$organism[1], technique = technique, tissue = tissue, summary = NULL,
                          studies = NULL, note = sprintf("No designed %s studies for %s in the evidence tables.",
                                                         technique, rows$organism[1])),
                     class = "studyforge_practice"))
  }
  tis <- "all"
  if (!is.null(tissue) && nzchar(tissue)) {
    nt <- .sf_norm_tissue(tissue)
    if (nt %in% r$tissue) tis <- nt else note <- sprintf("Too few %s studies of %s; showing all tissues.", tech, nt)
  }
  s <- r[r$tissue == tis, , drop = FALSE][1, , drop = FALSE]
  st <- tb$studies
  ex <- if (!is.null(st)) st[st$species == s$species & st$technique == tech & st$tissue_group == tis, , drop = FALSE]
  if (!is.null(ex) && nrow(ex)) ex <- utils::head(ex, n_cite)
  structure(list(organism = s$organism, technique = tech, tissue = tis, summary = s, studies = ex, note = note),
            class = "studyforge_practice")
}

.sf_fmt <- function(x) if (is.na(x)) "?" else format(round(as.numeric(x), 1), trim = TRUE, nsmall = 0)

.sf_practice_lines <- function(x) {
  s <- x$summary
  if (is.null(s)) return(x$note)
  first_names <- function(v) if (is.na(v)) NA else paste(sub(" \\(\\d+\\)$", "", strsplit(v, "; ", fixed = TRUE)[[1]]), collapse = ", ")
  out <- sprintf("%d designed %s studies of %s%s in public archives (%s).", s$n_designed, x$technique, x$organism,
                 if (x$tissue != "all") paste0(" (", x$tissue, ")") else "", s$years)
  if (!is.na(s$reps_median)) {
    out <- c(out, sprintf("Replicates per condition: median %s (IQR %s-%s, from %d studies); %d%% used 6 or more.",
                          .sf_fmt(s$reps_median), .sf_fmt(s$reps_q25), .sf_fmt(s$reps_q75), s$n_with_reps,
                          round(100 * s$share_reps_ge6)))
  }
  if (!is.na(s$mreads_median)) {
    out <- c(out, sprintf("Read depth: median %s M reads per run (IQR %s-%s).", .sf_fmt(s$mreads_median),
                          .sf_fmt(s$mreads_q25), .sf_fmt(s$mreads_q75)))
  }
  if (!is.na(s$top_instruments_recent)) out <- c(out, paste0("Recent sequencers: ", first_names(s$top_instruments_recent), "."))
  if (!is.na(s$top_kits)) out <- c(out, paste0("Kits named in protocols: ", first_names(s$top_kits), "."))
  if (!is.null(x$studies) && nrow(x$studies)) {
    out <- c(out, "Examples:")
    for (i in seq_len(nrow(x$studies))) {
      e <- x$studies[i, ]
      dz <- if (!is.na(e$design)) e$design else NA
      if (!is.na(dz) && lengths(regmatches(dz, gregexpr("\\[", dz))) > lengths(regmatches(dz, gregexpr("\\]", dz)))) {
        dz <- paste0(sub(",?\\s*[^,\\[]*$", "", dz), ", ...]")
      }
      bits <- c(if (!is.na(e$year)) e$year, if (!is.na(e$reps)) paste(e$reps, if (e$reps == 1) "rep" else "reps"),
                if (!is.na(dz)) dz)
      out <- c(out, sprintf("  %s (%s) doi:%s", e$study, paste(bits, collapse = "; "), e$doi))
    }
  }
  if (!is.null(x$note)) out <- c(out, x$note)
  out
}

#' @export
print.studyforge_practice <- function(x, ...) {
  cat(paste0(.sf_practice_lines(x), collapse = "\n"), "\n")
  cat("Descriptive only: what studies did, not what your study needs. Choose n from power analysis.\n")
  invisible(x)
}

# tissue named in the question that the table has rows for (e.g. "leaves" -> "leaf")
.sf_tissue_in_question <- function(question, organism, technique) {
  if (is.null(question) || !nzchar(question)) return(NULL)
  p <- .sf_practice_tables()$practice
  have <- unique(p$tissue[p$organism == organism & p$technique == technique & p$tissue != "all"])
  if (!length(have)) return(NULL)
  words <- strsplit(gsub("[^a-z ]", " ", tolower(question)), "\\s+")[[1]]
  words <- unique(c(words, paste(utils::head(words, -1), utils::tail(words, -1))))   # two-word tissues too
  hit <- have[have %in% vapply(words[nzchar(words)], .sf_norm_tissue, "")]
  if (length(hit)) hit[1] else NULL
}

# For a StudySpec: the technique comes from the assays first, then the system.
.sf_practice_for_spec <- function(spec, question = NULL) {
  if (is.null(spec$organism)) return(NULL)
  techs <- c(unname(.SF_TECH_BY_ASSAY[unlist(spec$assays)]), unname(.SF_TECH_BY_SYSTEM[spec$system %||% ""]))
  techs <- unique(techs[!is.na(techs)])
  for (t in techs) {
    tis <- spec$tissue %||% tryCatch(.sf_tissue_in_question(question, spec$organism, t), error = function(e) NULL)
    pr <- tryCatch(published_practice(spec$organism, t, tis),
                   error = function(e) NULL)
    if (inherits(pr, "studyforge_practice") && !is.null(pr$summary)) return(pr)
  }
  NULL
}
