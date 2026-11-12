#!/usr/bin/env Rscript
# download_papers.R -- save open-access full texts for the papers found by enrich_evidence.R
#
# Reads evidence/<species>/papers.tsv and, for papers with a PMCID (open access in PMC/Europe PMC),
# saves the full-text JATS XML and optionally the PDF to papers/<species>/, plus an index.tsv.
# Only open-access articles are fetched; keep them for your own reading/text mining.
#
# Usage (login node, needs internet; resumable)
#   Rscript download_papers.R evidence sorghum
#   Rscript download_papers.R evidence sorghum,maize --pdf
#   Rscript download_papers.R evidence plants --pdf --linked-only --max 200
#   flags: --pdf (also PDFs), --linked-only (skip papers that only mention the accession), --max N (per species)
# Keep next to enrich_evidence.R and harvest_evidence.R.

local({
  here <- tryCatch(dirname(normalizePath(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))), error = function(e) ".")
  f <- file.path(here, "enrich_evidence.R")
  if (!file.exists(f)) f <- "enrich_evidence.R"
  if (!file.exists(f)) stop("enrich_evidence.R must be in the same folder")
  source(f)
})

save_url <- function(u, dest, check = NULL) {
  ok <- tryCatch({ utils::download.file(u, dest, quiet = TRUE, mode = "wb"); TRUE },
                 error = function(e) FALSE, warning = function(w) FALSE)
  if (ok && file.exists(dest) && file.size(dest) > 1000) {
    if (is.null(check)) return(TRUE)
    head_bytes <- readBin(dest, "raw", 5)
    if (identical(rawToChar(head_bytes[1:min(4, length(head_bytes))]), check)) return(TRUE)
  }
  unlink(dest)
  FALSE
}

download_species <- function(dir, out_root, pdf = FALSE, linked_only = FALSE, max_n = Inf) {
  pf <- file.path(dir, "papers.tsv")
  if (!file.exists(pf)) { message("  no papers.tsv yet (run enrich_evidence.R papers first)"); return(invisible()) }
  p <- read_tsv_file(pf)
  if (!nrow(p) || !"pmcid" %in% names(p)) { message("  no papers"); return(invisible()) }
  p <- p[nzchar(nz(p$pmcid)), ]
  if (linked_only) p <- p[p$confidence == "linked", ]
  p <- p[!(p$confidence == "mentions_accession" & as.numeric(p$paper_n_studies) > 5), ]
  p <- p[order(p$confidence != "linked", -suppressWarnings(as.numeric(p$year))), ]
  idx <- do.call(rbind, lapply(split(p, p$pmcid), function(d) data.frame(
    pmcid = d$pmcid[1], pmid = d$pmid[1], doi = d$doi[1], year = d$year[1], journal = d$journal[1],
    title = d$title[1], confidence = d$confidence[1],
    study_groups = paste(unique(d$study_group), collapse = ";"), stringsAsFactors = FALSE)))
  idx <- idx[order(idx$confidence != "linked", -suppressWarnings(as.numeric(idx$year))), ]
  idx <- head(idx, max_n)
  od <- file.path(out_root, basename(dir))
  dir.create(file.path(od, "xml"), recursive = TRUE, showWarnings = FALSE)
  if (pdf) dir.create(file.path(od, "pdf"), showWarnings = FALSE)
  message("  ", nrow(idx), " open-access papers")
  idx$xml <- idx$pdf <- FALSE
  for (i in seq_len(nrow(idx))) {
    id <- idx$pmcid[i]
    xf <- file.path(od, "xml", paste0(id, ".xml"))
    idx$xml[i] <- file.exists(xf) ||
      save_url(sprintf("%s/%s/fullTextXML", EPMC, id), xf, check = "<?xm")
    if (pdf) {
      pf2 <- file.path(od, "pdf", paste0(id, ".pdf"))
      idx$pdf[i] <- file.exists(pf2) ||
        save_url(sprintf("https://europepmc.org/backend/ptpmcrender.fcgi?accid=%s&blobtype=pdf", id),
                 pf2, check = "%PDF")
    }
    Sys.sleep(0.3)
    if (i %% 25 == 0) message("    ", i, "/", nrow(idx))
  }
  write_tsv(idx, file.path(od, "index.tsv"))
  message(sprintf("  saved %d XML%s", sum(idx$xml), if (pdf) sprintf(", %d PDF", sum(idx$pdf)) else ""))
}

main_dl <- function() {
  a <- commandArgs(trailingOnly = TRUE)
  pdf <- "--pdf" %in% a; linked_only <- "--linked-only" %in% a
  mi <- match("--max", a); max_n <- if (!is.na(mi)) as.numeric(a[mi + 1]) else Inf
  if (!is.na(mi)) a <- a[-c(mi, mi + 1)]
  a <- setdiff(a, c("--pdf", "--linked-only"))
  if (length(a) < 2) {
    message("Usage: Rscript download_papers.R <evidence_dir> <species|group|list> [--pdf] [--linked-only] [--max N]")
    return(invisible())
  }
  root <- a[1]
  keys <- tryCatch(select_species(a[2])$key, error = function(e) trimws(strsplit(a[2], ",")[[1]]))
  out_root <- file.path(dirname(normalizePath(root)), "papers")
  for (k in keys) {
    d <- file.path(root, k)
    if (!dir.exists(d)) next
    message("== ", k)
    tryCatch(download_species(d, out_root, pdf, linked_only, max_n),
             error = function(e) message("!! ", k, ": ", conditionMessage(e)))
  }
  message("Papers in ", out_root)
}

if (sys.nframe() == 0) main_dl()
