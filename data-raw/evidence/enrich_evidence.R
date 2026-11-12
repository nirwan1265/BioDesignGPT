#!/usr/bin/env Rscript
# enrich_evidence.R -- StudyForge evidence layer, step 2: papers, BioSample factors, methods.
#
# Runs on the output of harvest_evidence.R (keep both scripts in the same folder).
# For DESIGNED studies (>= 4 samples) in evidence/<species>/by_study.tsv:
#   papers    : PubMed links from GEO, NCBI BioProject -> PubMed, and Europe PMC accession mentions
#   biosample : every BioSample attribute -> which attributes vary (factors), levels, reps per cell
#   methods   : open-access full text (Europe PMC) -> methods section -> growth/design/reps/stats fields
#
# Usage (login node, needs internet; every step is resumable)
#   Rscript enrich_evidence.R papers    evidence [species]
#   Rscript enrich_evidence.R biosample evidence [species]
#   Rscript enrich_evidence.R methods   evidence [species]   # after papers
#   Rscript enrich_evidence.R all       evidence [species]
#   Rscript enrich_evidence.R combine   evidence             # all-species tables + coverage
#   [species]: key, comma list or group (plants, animals, ...); default = every harvested species
#   --force redoes a finished step
# Env: ENTREZ_KEY (recommended), MAX_BIOSAMPLES (per species, default 60000), MAX_PAPERS (default 3000)
#
# Outputs per species: papers.tsv, biosample_long.tsv, study_factors.tsv,
#   methods_text/ (local cache, not for redistribution), methods_extracted.tsv, study_methods.tsv

local({
  here <- tryCatch(dirname(normalizePath(sub("^--file=", "",
            grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))), error = function(e) ".")
  f <- file.path(here, "harvest_evidence.R")
  if (!file.exists(f)) f <- "harvest_evidence.R"
  if (!file.exists(f)) stop("harvest_evidence.R must be in the same folder")
  source(f)
})

MAX_BIOSAMPLES <- as.numeric(Sys.getenv("MAX_BIOSAMPLES", "60000"))
MAX_PAPERS     <- as.numeric(Sys.getenv("MAX_PAPERS", "3000"))
EU   <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
EPMC <- "https://www.ebi.ac.uk/europepmc/webservices/rest"

# ---------------------------------------------------------- web helpers ----
eu_get <- function(path, query) {
  k <- Sys.getenv("ENTREZ_KEY")
  u <- sprintf("%s/%s?%s%s", EU, path, query, if (nzchar(k)) paste0("&api_key=", k) else "")
  x <- paste(get_text(u), collapse = "\n")
  Sys.sleep(if (nzchar(k)) 0.12 else 0.4)
  x
}
eu_json <- function(path, query) fromJSON(eu_get(path, query), simplifyVector = FALSE)
batches <- function(x, n) split(x, ceiling(seq_along(x) / n))

# one attempt; returns text, or "404" (not available), or NULL (transient error, retry next run)
fetch_once <- function(u) {
  r <- tryCatch(paste(readLines(url(u), warn = FALSE, encoding = "UTF-8"), collapse = "\n"),
                error = function(e) structure(conditionMessage(e), class = "err"))
  if (inherits(r, "err")) return(if (grepl("404|Not Found", r)) "404" else NULL)
  r
}

xml_unescape <- function(x) {
  x <- gsub("&lt;", "<", x, fixed = TRUE); x <- gsub("&gt;", ">", x, fixed = TRUE)
  x <- gsub("&quot;", "\"", x, fixed = TRUE); x <- gsub("&apos;", "'", x, fixed = TRUE)
  m <- gregexpr("&#x?[0-9A-Fa-f]+;", x)
  regmatches(x, m) <- lapply(regmatches(x, m), function(e) vapply(e, function(s) {
    hex <- grepl("^&#x", s)
    intToUtf8(strtoi(sub("^&#x?([0-9A-Fa-f]+);$", "\\1", s), if (hex) 16L else 10L))
  }, ""))
  gsub("&amp;", "&", x, fixed = TRUE)
}

# make text ASCII so regexes behave the same in any locale (C locale on HPC)
to_ascii <- function(x) {
  rep <- c("°" = " deg ", "º" = " deg ", "℃" = " deg C", "–" = "-", "—" = "-",
           "−" = "-", "×" = "x", "µ" = "u", "μ" = "u", "±" = "+/-",
           " " = " ", " " = " ", " " = " ", "’" = "'", "‘" = "'",
           "“" = "\"", "”" = "\"", "≤" = "<=", "≥" = ">=", "α" = "alpha")
  for (k in names(rep)) x <- gsub(k, rep[[k]], x, fixed = TRUE, useBytes = TRUE)
  x <- iconv(x, "UTF-8", "ASCII", sub = " ")
  x[is.na(x)] <- ""
  x
}

load_designed <- function(dir) {
  bs <- read_tsv_file(file.path(dir, "by_study.tsv"))
  if (!nrow(bs)) return(bs)
  if (!"bioprojects" %in% names(bs))
    stop("by_study.tsv predates study grouping; first run: Rscript harvest_evidence.R --resummarise ",
         dirname(dir))
  bs[toupper(bs$designed) == "TRUE", ]
}

# --------------------------------------------------------------- papers ----
bioproject_to_pubmed <- function(accs) {
  accs <- unique(accs[grepl("^PRJ[A-Z]{1,2}[0-9]+$", accs)])
  out <- list()
  for (b in batches(accs, 100)) {
    es <- eu_json("esearch.fcgi", sprintf("db=bioproject&term=%s&retmax=500&retmode=json",
                                          enc(paste(b, collapse = " OR "))))
    uids <- unlist(es$esearchresult$idlist)
    if (!length(uids)) next
    sm <- eu_json("esummary.fcgi", sprintf("db=bioproject&id=%s&retmode=json", paste(uids, collapse = ",")))
    acc_of <- vapply(uids, function(u) {
      v <- unlist(sm$result[[u]]); a <- v[grepl("^PRJ[A-Z]{1,2}[0-9]+$", v)]
      if (length(a)) a[[1]] else NA_character_ }, "")
    keep <- !is.na(acc_of) & acc_of %in% b
    if (!any(keep)) next
    lk <- eu_json("elink.fcgi", paste0("dbfrom=bioproject&db=pubmed&retmode=json&",
                                       paste0("id=", uids[keep], collapse = "&")))
    for (ls in lk$linksets) {
      uid <- as.character(unlist(ls$ids)[1])
      pm  <- unlist(lapply(ls$linksetdbs, function(x) if (identical(x$dbto, "pubmed")) x$links))
      if (length(pm)) out[[length(out) + 1]] <- data.frame(
        bioproject = acc_of[[uid]], pmid = as.character(pm), link_source = "bioproject",
        stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

pubmed_meta <- function(pmids) {
  pmids <- unique(pmids[!is.na(pmids) & grepl("^[0-9]+$", pmids)])
  out <- list()
  for (b in batches(pmids, 200)) {
    sm <- eu_json("esummary.fcgi", sprintf("db=pubmed&id=%s&retmode=json", paste(b, collapse = ",")))
    for (u in unlist(sm$result$uids)) {
      r <- sm$result[[u]]
      getid <- function(t) {
        v <- unlist(lapply(r$articleids, function(a) if (identical(a$idtype, t)) a$value))
        if (length(v)) v[1] else NA_character_ }
      out[[length(out) + 1]] <- data.frame(
        pmid = u, pmcid = getid("pmc"), doi = getid("doi"),
        year = substr(r$pubdate %||% "", 1, 4),
        journal = r$fulljournalname %||% r$source %||% NA_character_,
        title = r$title %||% NA_character_, stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

epmc_mentions <- function(terms, max_hits = 20) {
  terms <- unique(terms[!is.na(terms) & nzchar(terms)])
  if (!length(terms)) return(NULL)
  q  <- paste0("\"", terms, "\"", collapse = " OR ")
  u  <- sprintf("%s/search?query=%s&format=json&resultType=lite&pageSize=%d", EPMC, enc(q), max_hits)
  js <- tryCatch(fromJSON(paste(get_text(u, tries = 3), collapse = ""), simplifyVector = FALSE),
                 error = function(e) NULL)
  Sys.sleep(0.15)
  r <- js$resultList$result
  if (!length(r)) return(NULL)
  do.call(rbind, lapply(r, function(x) data.frame(
    pmid = x$pmid %||% NA_character_, pmcid = x$pmcid %||% NA_character_,
    doi = x$doi %||% NA_character_, year = x$pubYear %||% NA_character_,
    journal = x$journalTitle %||% NA_character_, title = x$title %||% NA_character_,
    stringsAsFactors = FALSE)))
}

term_key <- function(bioprojects, srp, gse) {
  t <- c(head(strsplit(nz(bioprojects), ";", fixed = TRUE)[[1]], 10),
         strsplit(nz(srp), ";", fixed = TRUE)[[1]], strsplit(nz(gse), ";", fixed = TRUE)[[1]])
  paste(sort(unique(t[nzchar(t)])), collapse = ";")
}

# Rebuild the Europe PMC cache from an earlier run (papers.tsv + the by_study it was made from),
# so regrouped species don't repeat days of searches.
seed_epmc_cache <- function(dir) {
  cache <- list()
  pf <- file.path(dir, "papers.tsv"); bf <- file.path(dir, "by_study.prev.tsv")
  if (!file.exists(pf) || !file.exists(bf)) return(cache)
  prev <- read_tsv_file(bf)
  if (!nrow(prev) || !"bioprojects" %in% names(prev)) return(cache)
  prev <- prev[toupper(prev$designed) == "TRUE" & !duplicated(prev$study_group), ]
  pp <- read_tsv_file(pf)
  ep <- if (nrow(pp)) pp[grepl("europepmc_mention", nz(pp$link_source)), ] else pp
  cols <- c("pmid", "pmcid", "doi", "year", "journal", "title")
  for (i in seq_len(nrow(prev))) {
    k <- term_key(prev$bioprojects[i], prev$srp[i], prev$gse[i])
    r <- if (nrow(ep)) ep[ep$study_group == prev$study_group[i], intersect(cols, names(ep)), drop = FALSE] else NULL
    cache[[k]] <- if (is.null(r) || !nrow(r)) "none" else r
  }
  message("  reused ", length(cache), " earlier Europe PMC searches")
  saveRDS(cache, file.path(dir, ".epmc_cache.rds"))
  cache
}

step_papers <- function(dir, force = FALSE) {
  out_f <- file.path(dir, "papers.tsv")
  if (file.exists(out_f) && !force) { message("  papers: done (--force to redo)"); return(invisible()) }
  bs <- load_designed(dir)
  if (!nrow(bs)) { message("  no designed studies"); return(invisible()) }
  ug <- bs[!duplicated(bs$study_group), c("study_group", "bioprojects", "srp", "gse")]
  links <- list()

  # 1. GEO series -> PubMed
  gs <- read_tsv_file(file.path(dir, "geo_series.tsv"))
  if (nrow(gs) && "pubmed" %in% names(gs)) {
    for (i in which(nzchar(nz(ug$gse)))) for (g in strsplit(ug$gse[i], ";", fixed = TRUE)[[1]]) {
      pm <- gs$pubmed[match(g, gs$gse)]
      if (!is.na(pm) && nzchar(pm)) links[[length(links) + 1]] <- data.frame(
        study_group = ug$study_group[i], pmid = strsplit(pm, ";", fixed = TRUE)[[1]],
        link_source = "geo", stringsAsFactors = FALSE)
    }
  }

  # 2. BioProject -> PubMed (first 20 projects per study group)
  bp <- lapply(strsplit(ug$bioprojects, ";", fixed = TRUE), head, 20)
  bp_long <- unique(data.frame(study_group = rep(ug$study_group, lengths(bp)), bioproject = unlist(bp),
                               stringsAsFactors = FALSE))
  message("  BioProject -> PubMed: ", length(unique(bp_long$bioproject)), " projects")
  bl <- bioproject_to_pubmed(unique(bp_long$bioproject))
  if (!is.null(bl)) {
    m <- merge(bp_long, bl, by = "bioproject")
    links[[length(links) + 1]] <- m[, c("study_group", "pmid", "link_source")]
  }

  # 3. Europe PMC: papers that mention the accessions (data availability statements).
  #    Cached per accession set, so reruns after regrouping only query what's new.
  cache_f <- file.path(dir, ".epmc_cache.rds")
  cache <- if (file.exists(cache_f)) readRDS(cache_f) else seed_epmc_cache(dir)
  keys <- vapply(seq_len(nrow(ug)), function(i) term_key(ug$bioprojects[i], ug$srp[i], ug$gse[i]), "")
  todo <- which(!keys %in% names(cache))
  message("  Europe PMC mentions: ", nrow(ug), " studies (", length(todo), " not yet searched)")
  for (j in seq_along(todo)) {
    i <- todo[j]
    r <- epmc_mentions(strsplit(keys[i], ";", fixed = TRUE)[[1]])
    cache[[keys[i]]] <- if (is.null(r)) "none" else r
    if (j %% 100 == 0) { saveRDS(cache, cache_f); message("    ", j, "/", length(todo)) }
  }
  saveRDS(cache, cache_f)
  ep_rows <- lapply(seq_len(nrow(ug)), function(i) {
    r <- cache[[keys[i]]]
    if (is.null(r) || !is.data.frame(r) || !nrow(r)) return(NULL)
    cbind(study_group = ug$study_group[i], r, link_source = "europepmc_mention", stringsAsFactors = FALSE)
  })
  st <- list(rows = Filter(Negate(is.null), ep_rows))

  cols <- c("study_group", "link_source", "pmid", "pmcid", "doi", "year", "journal", "title")
  lk <- do.call(rbind, links)
  if (!is.null(lk) && nrow(lk)) {
    meta <- pubmed_meta(lk$pmid)
    lk <- if (!is.null(meta)) merge(lk, meta, by = "pmid", all.x = TRUE) else lk
    for (c in setdiff(cols, names(lk))) lk[[c]] <- NA_character_
    lk <- lk[, cols]
  }
  ep <- do.call(rbind, st$rows)
  if (!is.null(ep)) ep <- ep[, cols]
  papers <- rbind(lk, ep)
  if (is.null(papers) || !nrow(papers)) { message("  no papers found"); write_tsv(data.frame(), out_f); return(invisible()) }

  papers$key <- ifelse(nzchar(nz(papers$pmid)), papers$pmid,
                       ifelse(nzchar(nz(papers$doi)), tolower(papers$doi), tolower(nz(papers$title))))
  gk  <- paste(papers$study_group, papers$key, sep = "\r")
  src <- tapply(papers$link_source, gk, function(x) paste(sort(unique(x)), collapse = ";"))
  papers <- papers[order(match(papers$link_source, c("geo", "bioproject", "europepmc_mention"))), ]
  papers <- papers[!duplicated(paste(papers$study_group, papers$key, sep = "\r")), ]
  papers$link_source <- as.vector(src[paste(papers$study_group, papers$key, sep = "\r")])
  papers$confidence  <- ifelse(grepl("geo|bioproject", papers$link_source), "linked", "mentions_accession")
  papers$paper_n_studies <- as.vector(table(papers$key)[papers$key])   # high = reanalysis/review/resource paper
  papers$key <- NULL
  write_tsv(papers, out_f)
  message(sprintf("  %d of %d designed studies have >=1 paper (%d linked)",
                  length(unique(papers$study_group)), nrow(ug),
                  length(unique(papers$study_group[papers$confidence == "linked"]))))
}

# ------------------------------------------------------------ biosample ----
parse_biosample_xml <- function(x) {
  blocks <- strsplit(x, "<BioSample ", fixed = TRUE)[[1]][-1]
  if (!length(blocks)) return(NULL)
  do.call(rbind, lapply(blocks, function(b) {
    acc <- regmatches(b, regexpr("accession=\"[^\"]+\"", b))
    if (!length(acc)) return(NULL)
    at <- regmatches(b, gregexpr("<Attribute [^>]*>[^<]*</Attribute>", b))[[1]]
    if (!length(at)) return(NULL)
    nm <- ifelse(grepl("harmonized_name=\"", at, fixed = TRUE),
                 sub(".*harmonized_name=\"([^\"]+)\".*", "\\1", at),
                 sub(".*attribute_name=\"([^\"]+)\".*", "\\1", at))
    data.frame(sample = sub("accession=\"([^\"]+)\"", "\\1", acc),
               attribute = tolower(trimws(xml_unescape(nm))),
               value = trimws(xml_unescape(sub("^<Attribute [^>]*>([^<]*)</Attribute>$", "\\1", at))),
               stringsAsFactors = FALSE)
  }))
}

biosample_fetch <- function(accs) {
  out <- list()
  for (b in batches(accs, 100)) {
    es <- eu_json("esearch.fcgi", sprintf("db=biosample&term=%s&retmax=500&retmode=json",
                                          enc(paste(b, collapse = " OR "))))
    uids <- unlist(es$esearchresult$idlist)
    if (!length(uids)) next
    p <- parse_biosample_xml(eu_get("efetch.fcgi", sprintf("db=biosample&id=%s&retmode=xml",
                                                            paste(uids, collapse = ","))))
    if (!is.null(p)) out[[length(out) + 1]] <- p[p$sample %in% b, ]
  }
  do.call(rbind, out)
}

ID_ATTRS <- c("sample_name", "sample name", "title", "description", "biosample", "sample_title",
              "submitter_id", "external_id", "external id", "alias", "sra_accession", "broker_name",
              "broker name", "lat_lon", "isolate_name_alias", "geo_accession", "insdc_center_name",
              "insdc center name", "insdc_first_public", "insdc first public", "insdc_last_update",
              "insdc last update", "insdc_status", "insdc status", "ena_first_public", "ena first public",
              "ena_last_update", "ena last update", "ena-checklist", "ena-first-public", "ena-last-update",
              "checklist", "project name", "project_name", "bioproject", "submission date")
REP_ATTR <- "replicate|^rep$|^bio_?rep|biological rep|^individual$|^pool"
# administrative / identifier-like attributes: never experimental factors or useful fixed context
ID_ATTR_RX <- paste0("(^|[ _-])(id|ids|name|accession|alias|title|description|provider|contact|release|",
                     "submission|submitter|center|centre|checklist|broker|status|update|ngdc|insdc|ena|",
                     "lat|lon|lat_lon|email|url|note|notes|comment|comments|common|scientific|biomaterial|",
                     "project|bioproject|sra|geo|taxonomy|organism)([ _-]|$)")
NAME_ATTRS <- c("sample_name", "sample name", "title", "sample_title", "alias", "submitter id", "submitter_id")
LOCATION_ATTRS <- c("geo_loc_name", "geographic location", "geographic location (country and/or sea)",
                    "geographic location (region and locality)", "location", "site", "field")
is_id_attr <- function(a) !(a %in% LOCATION_ATTRS) && (a %in% ID_ATTRS || grepl(ID_ATTR_RX, a, perl = TRUE))

# Design hidden in sample names (JGI style: "R3_M13_HI", "52DAE_P5_Pul/WB_R1"): split names into tokens,
# keep positions with few levels as factors, positions like R1/rep2 (or a trailing number) as replicates.
name_factors <- function(nm) {
  out <- list(fac = list(), rep_max = NA_real_)
  nm <- nm[!is.na(nm) & nzchar(nm)]
  if (length(nm) < 4) return(out)
  x <- sub("(?i)\\s+transcriptome$", "", sub("^.* - ", "", nm), perl = TRUE)
  tok <- strsplit(x, "[_[:space:]/|,;:-]+")
  L <- as.integer(names(which.max(table(lengths(tok)))))
  keep <- lengths(tok) == L
  if (L < 2 || mean(keep) < 0.8) return(out)
  m <- do.call(rbind, tok[keep]); smp <- names(nm)[keep]; n <- nrow(m)
  for (j in seq_len(L)) {
    v <- m[, j]; k <- length(unique(v))
    is_rep <- all(grepl("^(?i)(r|rep|br|bio|b|replicate)\\d{1,2}$", v, perl = TRUE)) ||
              (j == L && all(grepl("^\\d{1,2}$", v)) && k <= n / 2)
    if (is_rep) { out$rep_max <- max(as.numeric(gsub("\\D", "", v))); next }
    if (k == 1 || k > n / 2) next
    out$fac[[paste0("name_part", j)]] <- stats::setNames(v, smp)
  }
  out
}

# which attributes vary across a study's samples -> factors, levels, cells, reps per cell
study_factors <- function(long) {
  samples <- unique(long$sample); n <- length(samples)
  fac <- list(); fixed <- character(); rep_max <- NA_real_; source <- "biosample"
  for (a in unique(long$attribute)) {
    d  <- long[long$attribute == a & !duplicated(long[, c("sample", "attribute")]), ]
    ok <- d$value %in% clean_values(d$value)
    if (!any(ok)) next
    v  <- d$value[ok]
    if (grepl(REP_ATTR, a)) {
      r <- suppressWarnings(as.numeric(sub("^\\D*(\\d+).*$", "\\1", v)))
      if (any(!is.na(r))) rep_max <- max(c(rep_max, r), na.rm = TRUE)
      next
    }
    if (is_id_attr(a)) next
    k <- length(unique(v))
    if (k == 1) { fixed <- c(fixed, sprintf("%s=%s", a, substr(v[1], 1, 40))); next }
    if (n >= 3 && k >= n) next                        # one level per sample = an identifier
    if (n >= 6 && k >= 0.8 * n) next                  # per-sample IDs, dates, coordinates
    if (length(v) / n < 0.8) next                     # mostly missing
    fac[[a]] <- stats::setNames(v, d$sample[ok])
  }
  if (!length(fac)) {                                 # fall back to the sample names
    na <- intersect(NAME_ATTRS, unique(long$attribute))
    for (a in na) {
      d <- long[long$attribute == a & !duplicated(long[, c("sample", "attribute")]), ]
      nf <- name_factors(stats::setNames(d$value, d$sample))
      if (length(nf$fac)) { fac <- nf$fac; source <- "sample_names"
        if (!is.na(nf$rep_max)) rep_max <- max(c(rep_max, nf$rep_max), na.rm = TRUE); break }
    }
  }
  res <- data.frame(n_samples_attr = n, n_factors = 0L, factors = NA_character_, factor_source = NA_character_,
                    n_cells = NA_integer_, reps_per_cell = NA_real_, reps_attr_max = rep_max,
                    fixed = if (length(fixed)) paste(head(fixed, 8), collapse = "; ") else NA_character_,
                    stringsAsFactors = FALSE)
  if (!length(fac)) return(res)
  # keep a factor only if it splits the samples further (drops redundant twins like source_name/treatment)
  fac  <- fac[order(vapply(fac, function(f) length(unique(f)), 1L))]
  keep <- character(); cell <- rep("", n)
  for (a in names(fac)) {
    newcell <- paste(cell, nz(fac[[a]][samples]), sep = "|")
    if (length(unique(newcell)) > length(unique(cell))) { keep <- c(keep, a); cell <- newcell }
  }
  covered <- Reduce(`&`, lapply(keep, function(a) !is.na(fac[[a]][samples])))
  tab <- table(cell[covered])
  lev <- vapply(keep, function(a) {
    u <- unique(fac[[a]])
    if (length(u) <= 4) sprintf("%s[%s]", a, paste(substr(u, 1, 25), collapse = ", "))
    else sprintf("%s[%d]", a, length(u)) }, "")
  res$n_factors <- length(keep); res$factors <- paste(lev, collapse = " x "); res$factor_source <- source
  res$n_cells <- length(tab); res$reps_per_cell <- stats::median(as.numeric(tab))
  res
}

POP_FILES <- "^(WGS|WXS|AMPLICON|GBS|RAD_Seq|Targeted_Capture|WGA|CLONEEND|POOLCLONE)\\.tsv\\.gz$"

step_biosample <- function(dir, force = FALSE) {
  out_f <- file.path(dir, "study_factors.tsv")
  if (file.exists(out_f) && !force) { message("  biosample: done (--force to redo)"); return(invisible()) }
  bs <- load_designed(dir)
  bs <- bs[!bs$technique %in% POP_TECH, ]
  if (!nrow(bs)) { message("  no designed non-population studies"); return(invisible()) }
  want <- paste(bs$study_group, bs$technique, sep = "\r")

  # sample accessions per (study_group, technique), from the saved run tables
  files <- Sys.glob(file.path(dir, "runs", "*.tsv.gz"))
  files <- files[!grepl(POP_FILES, basename(files))]
  sm <- do.call(rbind, lapply(files, function(f) {
    r <- read_tsv_file(f)
    if (!nrow(r)) return(NULL)
    for (c in setdiff(c(ENA_FIELDS, GEO_COLS), names(r))) r[[c]] <- NA_character_
    r$technique   <- classify_technique(r)
    r$study_group <- assign_study_group(r)
    k <- paste(r$study_group, r$technique, sep = "\r")
    x <- unique(data.frame(key = k, sample = r$sample_accession, stringsAsFactors = FALSE)[k %in% want, ])
    rm(r); invisible(gc()); x
  }))
  if (is.null(sm) || !nrow(sm)) { message("  no samples matched"); return(invisible()) }

  # budget: studies with papers first, then newest
  pf <- file.path(dir, "papers.tsv")
  has_paper <- if (file.exists(pf)) unique(read_tsv_file(pf)$study_group) else character()
  ord <- bs[order(!(bs$study_group %in% has_paper), -suppressWarnings(as.numeric(bs$year))), ]
  key_order <- paste(ord$study_group, ord$technique, sep = "\r")
  sm <- sm[order(match(sm$key, key_order)), ]
  accs <- unique(sm$sample)
  if (length(accs) > MAX_BIOSAMPLES) {
    message("  capping at MAX_BIOSAMPLES=", MAX_BIOSAMPLES, " of ", length(accs), " samples")
    accs <- accs[seq_len(MAX_BIOSAMPLES)]
  }

  # fetch with append-cache so interruptions resume
  long_f <- file.path(dir, "biosample_long.tsv"); done_f <- file.path(dir, ".biosample_done.txt")
  done <- if (file.exists(done_f)) readLines(done_f) else character()
  todo <- setdiff(accs, done)
  message("  BioSample attributes: ", length(accs), " samples (", length(todo), " to fetch)")
  chunks <- batches(todo, 1000)
  for (j in seq_along(chunks)) {
    p <- tryCatch(biosample_fetch(chunks[[j]]), error = function(e) { message("    chunk failed: ", conditionMessage(e)); NULL })
    if (is.null(p)) next
    utils::write.table(p, long_f, sep = "\t", quote = FALSE, row.names = FALSE, na = "",
                       append = file.exists(long_f), col.names = !file.exists(long_f))
    cat(chunks[[j]], file = done_f, sep = "\n", append = TRUE)
    message("    ", min(j * 1000, length(todo)), "/", length(todo))
  }

  long <- read_tsv_file(long_f)
  if (!nrow(long)) { message("  no attributes returned"); return(invisible()) }
  long <- long[!duplicated(long), ]
  sm <- sm[sm$sample %in% long$sample, ]
  idx <- split(sm$sample, sm$key)
  rows <- lapply(names(idx), function(k) {
    f <- study_factors(long[long$sample %in% idx[[k]], ])
    p <- strsplit(k, "\r", fixed = TRUE)[[1]]
    cbind(study_group = p[1], technique = p[2], f, stringsAsFactors = FALSE)
  })
  fx <- do.call(rbind, rows)
  write_tsv(fx, out_f)
  message(sprintf("  factors found for %d of %d studies; median reps/cell %.1f",
                  sum(fx$n_factors > 0), nrow(fx), med(fx$reps_per_cell)))
}

# -------------------------------------------------------------- methods ----
# headings that end a methods section in plain text (capitalised, as headings are)
BACKMATTER_RX <- paste0("\\b(Acknowledg(e)?ments?|Author [Cc]ontributions|Competing [Ii]nterests|",
                        "Conflicts? of [Ii]nterest|Declaration of ([Cc]ompeting )?[Ii]nterests?|Footnotes|",
                        "Associated Data|Reporting [Ss]ummary|Supplementary [Ii]nformation Supplementary|",
                        "Supplementary [Mm]aterials? Supplementary)\\b|\\bReferences 1\\. ")
cut_backmatter <- function(txt) {
  m <- gregexpr(BACKMATTER_RX, txt, perl = TRUE)[[1]]
  m <- m[m > 300]
  if (length(m)) substr(txt, 1, min(m) - 1) else txt
}

extract_methods_section <- function(x) {
  body_end <- regexpr("</body>", x, fixed = TRUE)
  if (body_end < 0) body_end <- nchar(x)
  head_rx <- "(?:<label>[^<]*</label>\\s*)?<title>\\s*(?:[0-9IVX]+\\.?\\s*)?"
  start_rx <- paste0("(?i)<sec[^>]*>\\s*", head_rx,
    "(?:materials?\\s+(?:and|&amp;)\\s+methods?|methods?(?:\\s+(?:and|&amp;)\\s+materials?)?|",
    "experimental\\s+(?:procedures|section|design|methods)|online\\s+methods|star\\s*\\W*\\s*methods)\\s*</title>")
  s <- regexpr(start_rx, x, perl = TRUE)
  if (s < 0) s <- regexpr("(?i)<sec[^>]*sec-type=\"[^\"]*method", x, perl = TRUE)
  if (s < 0) return(NA_character_)
  rest <- substr(x, s, body_end)
  end_rx <- paste0("(?i)<sec[^>]*>\\s*", head_rx,
                   "(?:results(?:\\s+and\\s+discussion)?|discussion|conclusions?)\\s*</title>")
  e <- regexpr(end_rx, substr(rest, 2, nchar(rest)), perl = TRUE)
  if (e > 0) rest <- substr(rest, 1, e)
  back_rx <- paste0("(?i)<ack\\b|<ref-list\\b|<back\\b|<fn-group\\b|<sec[^>]*>\\s*", head_rx,
                    "(?:acknowledg|data (?:and code )?availability|author contrib|funding|competing|",
                    "conflicts? of interest|declaration|supplementary|associated data|references)")
  b <- regexpr(back_rx, substr(rest, 2, nchar(rest)), perl = TRUE)
  if (b > 0) rest <- substr(rest, 1, b)
  txt <- gsub("<[^>]+>", " ", rest)
  txt <- to_ascii(xml_unescape(txt))
  txt <- cut_backmatter(trimws(gsub("\\s+", " ", txt)))
  if (nchar(txt) < 200) return(NA_character_)
  substr(txt, 1, 80000)
}

WORDNUM <- c(two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9,
             ten = 10, eleven = 11, twelve = 12, fifteen = 15, twenty = 20, triplicate = 3,
             duplicate = 2, quadruplicate = 4)
NUMW <- "(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|\\d{1,3})"
as_num <- function(s) { s <- tolower(s); ifelse(s %in% names(WORDNUM), WORDNUM[s], suppressWarnings(as.numeric(s))) }

ENV_RX <- c(
  greenhouse = "(?i)green ?house|glass ?house|polytunnel|screen ?house",
  growth_chamber = "(?i)growth (chamber|cabinet|room)|phytotron|climate chamber|controlled[- ]environment",
  field = "(?i)field (trial|experiment|station|plot|condition|site|season|grown)|experimental (farm|station)|in the field",
  hydroponic = "(?i)hydroponic|nutrient solution|hoagland",
  plate_in_vitro = "(?i)\\bMS (medium|agar|plates?)|murashige|agar plates?|petri dish",
  animal_facility = "(?i)animal facility|vivarium|pathogen[- ]free|\\bSPF\\b|IACUC|ARRIVE guidelines",
  cell_culture = "(?i)\\bDMEM\\b|RPMI|fetal bovine serum|\\bFBS\\b|5 ?% CO2")
DESIGN_RX <- c(
  RCBD = "(?i)randomi[sz]ed complete[- ]blocks?|\\bRCBD\\b", alpha_lattice = "(?i)alpha[- ]?lattice",
  split_plot = "(?i)split[- ]plot", strip_plot = "(?i)strip[- ]plot", CRD = "(?i)completely randomi[sz]ed|\\bCRD\\b",
  latin_square = "(?i)latin square", augmented = "(?i)augmented (randomi[sz]ed )?(complete )?(block )?design",
  incomplete_block = "(?i)incomplete blocks?", row_column = "(?i)row[- ]column design",
  p_rep = "(?i)\\bp-rep\\b|partially replicated", factorial = "(?i)factorial (design|experiment|arrangement)",
  blocks_mentioned = "(?i)\\bblocks?\\b", randomized = "(?i)randomi[sz]ed|randomly (placed|arranged|assigned|positioned|distributed)",
  rotation = "(?i)(pots?|trays?|plants?|flats?)[^.]{0,40}(rotated|re-?randomi[sz]ed|repositioned|moved)",
  blinded = "(?i)blind(ed)? to|double[- ]blind|investigators? (were )?blind")
STATS_RX <- c(
  DESeq2 = "DESeq2?", edgeR = "edgeR", limma = "\\blimma\\b|\\bvoom\\b", sleuth = "\\bsleuth\\b",
  ANOVA = "(?i)\\bANOVA\\b|analysis of variance", Tukey = "(?i)tukey", mixed_model = "(?i)mixed[- ](effects? )?models?|\\blme4\\b|\\blmer\\b|ASReml|\\bREML\\b",
  BLUP_BLUE = "\\bBLUPs?\\b|\\bBLUEs?\\b", SpATS = "SpATS", FDR = "(?i)benjamini|false discovery|\\bFDR\\b|q-?values?",
  t_test = "(?i)\\bt-?tests?\\b|student'?s t", nonparametric = "(?i)wilcoxon|mann-whitney|kruskal",
  MACS = "MACS2?|MACS3", DiffBind = "DiffBind", GWAS_tools = "GAPIT|GEMMA|TASSEL|rMVP|FarmCPU|BLINK|EMMAX|PLINK",
  power_analysis = "(?i)power analysis|statistical power|sample size (was )?(calculat|determin|estimat)")
ALIGN_RX <- c(STAR = "\\bSTAR\\b", HISAT2 = "HISAT2?", Salmon = "\\bSalmon\\b", kallisto = "kallisto",
              Bowtie2 = "Bowtie ?2?", BWA = "\\bBWA\\b", featureCounts = "featureCounts", HTSeq = "HTSeq",
              StringTie = "StringTie", Trimmomatic = "Trimmomatic", fastp = "\\bfastp\\b", cellranger = "(?i)cell ?ranger")
SEQ_RX <- "(?i)NovaSeq ?(X Plus|X|\\d{4})?|HiSeq ?(X Ten|X|\\d{4})?|NextSeq ?\\d{0,4}|MiSeq|DNBSEQ-?[A-Z0-9]*|BGISEQ-?\\d*|MGISEQ-?\\d*|PacBio( Sequel ?I{0,2}| RS ?I{0,2})?|Sequel ?I{1,2}|PromethION|GridION|MinION|Ion (Torrent|Proton|S5)|Element AVITI"

flags <- function(txt, rx) {
  hit <- names(rx)[vapply(rx, function(r) grepl(r, txt, perl = TRUE), logical(1))]
  if (length(hit)) paste(hit, collapse = "; ") else NA_character_
}
matches <- function(txt, rx, n = 3) {
  m <- unique(trimws(regmatches(txt, gregexpr(rx, txt, perl = TRUE))[[1]]))
  if (length(m)) paste(head(m, n), collapse = "; ") else NA_character_
}
max_num <- function(txt, rx) {
  m <- regmatches(txt, gregexpr(rx, txt, perl = TRUE))[[1]]
  if (!length(m)) return(NA_real_)
  w <- regmatches(m, regexpr(paste0("(?i)", NUMW, "|triplicate|duplicate|quadruplicate"), m, perl = TRUE))
  v <- as_num(w); v <- v[!is.na(v) & v <= 100]
  if (length(v)) max(v) else NA_real_
}

POOL_UNITS <- "(individual\\s+|independent\\s+|different\\s+|separate\\s+)?(plants|seedlings|individuals|leaves|leaf discs|roots|ears|kernels|seeds|animals|mice|rats|flies|larvae|fish|embryos|worms)"
POOL_VERB  <- "(pool(ed|ing)?|bulk(ed|ing)?|(were|was) (mixed|combined)|mixed (together|as one|into one|to form)|combined (into|as) (one|a single))"
POOL_RX    <- paste0("(?i)\\b", POOL_VERB, "\\b[^.]{0,80}", POOL_UNITS, "|", POOL_UNITS, "[^.]{0,80}\\b", POOL_VERB, "\\b")

# growth temperatures only (5-45 C); drops storage (-80), PCR (95), incubations
growth_temps <- function(g) {
  m <- regmatches(g, gregexpr("(?<![-\\d.])\\d{1,2}(\\.\\d)?(\\s*(/|-|to|and)\\s*\\d{1,2}(\\.\\d)?)?\\s*deg\\s*C?\\b", g, perl = TRUE))[[1]]
  if (!length(m)) return(NA_character_)
  first <- suppressWarnings(as.numeric(sub("^(\\d{1,2}(\\.\\d)?).*", "\\1", m)))
  m <- unique(trimws(m[!is.na(first) & first >= 5 & first <= 45]))
  if (length(m)) paste(head(m, 3), collapse = "; ") else NA_character_
}

extract_method_fields <- function(txt) {
  sent <- strsplit(txt, "(?<=[.;])\\s+(?=[A-Z(])", perl = TRUE)[[1]]
  grow <- sent[grepl("(?i)grown|growth|cultivat|greenhouse|chamber|photoperiod|day/night|light/dark|housed|maintained|reared|incubator|humidity",
                     sent, perl = TRUE) &
               !grepl("(?i)\\bPCR\\b|denatur|anneal|extension|centrifug|cycles|elut|hybridi[sz]|\\bmin(ute)?s?\\b|\\bsec(ond)?s?\\b|overnight at|library|ligat|digest|stor(ed|age)|frozen|liquid nitrogen|-\\s?80|autoclav|\\brpm\\b|incubated (at|for)|thermomixer|water bath",
                      sent, perl = TRUE)]
  g <- paste(grow, collapse = " ")
  data.frame(
    environment = flags(txt, ENV_RX),
    temperature = growth_temps(g),
    photoperiod = matches(g, paste0("(?i)\\d{1,2}(\\.\\d)?\\s*h(ours?|rs?)?\\s*(of\\s*)?(light|day|photoperiod)[^.;]{0,30}?\\d{1,2}(\\.\\d)?\\s*h(ours?|rs?)?\\s*(of\\s*)?(dark|night)",
                                    "|\\d{1,2}\\s*h?\\s*/\\s*\\d{1,2}\\s*h\\s*\\(?\\s*(light\\s*/\\s*dark|day\\s*/\\s*night)|\\b(long|short)[- ]day\\b|\\d{1,2}\\s*:\\s*\\d{1,2}\\s*(h\\s*)?(light\\s*:\\s*dark|L\\s*:\\s*D)"), 2),
    humidity = matches(g, "(?i)\\d{2}(\\s*(-|to)\\s*\\d{2})?\\s*%\\s*(relative humidity|RH|humidity)|relative humidity[^.;]{0,20}?\\d{2}\\s*%", 2),
    light = matches(g, "(?i)\\d{2,4}\\s*u?mol\\s*(photons\\s*)?(m\\s*-?\\s*2|/m2|per square)", 2),
    age_stage = matches(txt, paste0("(?i)\\b", NUMW, "[- ](day|week|month)s?[- ]old\\b|\\bV\\d{1,2}\\b stage|\\b(anthesis|heading|flowering|booting|seedling|tillering|grain[- ]filling) stage"), 3),
    sampling_time = matches(txt, "(?i)\\bZT\\s?\\d{1,2}\\b|zeitgeber|(sampled|harvested|collected)[^.;]{0,40}?\\b(at|between)\\s+\\d{1,2}(:\\d{2})?\\s*(am|pm|h)\\b", 2),
    design = flags(txt, DESIGN_RX),
    blocks_or_field_reps = max_num(txt, paste0("(?i)\\b", NUMW, "\\s+(complete\\s+|randomi[sz]ed\\s+|independent\\s+)?(blocks|replications|field replicates|reps per (block|location|environment))\\b")),
    bio_reps = max_num(txt, paste0("(?i)\\b", NUMW, "\\s+(independent\\s+)?(biological|biologically independent)\\s+(replicates?|replications?|samples)|biological (replicates?|triplicates?) \\(n\\s*=\\s*\\d{1,2}\\)|\\bin (biological )?(triplicate|duplicate|quadruplicate)")),
    independent_repeats = max_num(txt, paste0("(?i)\\b(repeated|performed|conducted|replicated)\\s+(at least\\s+)?", NUMW, "\\s+times|\\b", NUMW, "\\s+independent\\s+(experiments|infections|inoculations|trials|batches|experimental (runs|replicates))")),
    tech_reps = max_num(txt, paste0("(?i)\\b", NUMW, "\\s+technical\\s+(replicates?|replications?)|technical (triplicate|duplicate)")),
    pooled = grepl(POOL_RX, txt, perl = TRUE),
    pooled_n = max_num(txt, paste0(
      "(?i)(from|of)\\s+(at least\\s+)?", NUMW, "\\s+", POOL_UNITS, "[^.]{0,60}", POOL_VERB, "|",
      "\\b(at least\\s+)?", NUMW, "\\s+", POOL_UNITS, "[^.]{0,60}", POOL_VERB, "|",
      POOL_VERB, "[^.]{0,60}?(from|of)\\s+(at least\\s+)?", NUMW, "\\s+", POOL_UNITS)),
    stats = flags(txt, STATS_RX),
    pipeline = flags(txt, ALIGN_RX),
    depth = matches(txt, "(?i)\\d+(\\.\\d+)?\\s*(million|M)\\s+(clean\\s+|raw\\s+|high[- ]quality\\s+|paired[- ]end\\s+|uniquely mapped\\s+)?(reads|read pairs|fragments)", 3),
    read_length = matches(txt, "(?i)\\b(2\\s*x\\s*|PE ?)\\d{2,3}(\\s*(bp|nt))?\\b|\\b\\d{2,3}[- ]?(bp|nt)\\s+(paired|single)[- ]end", 2),
    sequencers = matches(txt, SEQ_RX, 3),
    kits = find_kits(txt),
    stringsAsFactors = FALSE)
}

step_methods <- function(dir, force = FALSE) {
  out_f <- file.path(dir, "methods_extracted.tsv")
  if (file.exists(out_f) && !force) { message("  methods: done (--force to redo)"); return(invisible()) }
  pf <- file.path(dir, "papers.tsv")
  if (!file.exists(pf)) { message("  run the papers step first"); return(invisible()) }
  papers <- read_tsv_file(pf)
  if (!nrow(papers) || !"pmcid" %in% names(papers)) { message("  no papers"); return(invisible()) }
  p <- papers[nzchar(nz(papers$pmcid)), ]
  # linked papers first; skip resource/reanalysis papers mentioned by many studies
  p <- p[order(p$confidence != "linked", as.numeric(p$paper_n_studies)), ]
  p <- p[!(p$confidence == "mentions_accession" & as.numeric(p$paper_n_studies) > 5), ]
  ids <- head(unique(p$pmcid), MAX_PAPERS)
  cache <- file.path(dir, "methods_text"); dir.create(cache, showWarnings = FALSE)
  miss_f <- file.path(cache, "_unavailable.txt")
  miss <- if (file.exists(miss_f)) readLines(miss_f) else character()
  todo <- ids[!file.exists(file.path(cache, paste0(ids, ".txt"))) & !(ids %in% miss)]
  message("  full text: ", length(ids), " PMC papers (", length(todo), " to fetch)")
  for (i in seq_along(todo)) {
    id <- todo[i]
    x  <- fetch_once(sprintf("%s/%s/fullTextXML", EPMC, id))
    Sys.sleep(0.15)
    if (is.null(x)) next                                  # transient: retry next run
    sec <- if (identical(x, "404")) NA_character_ else extract_methods_section(x)
    if (is.na(sec)) { cat(id, file = miss_f, sep = "\n", append = TRUE); next }
    writeLines(sec, file.path(cache, paste0(id, ".txt")))
    if (i %% 50 == 0) message("    ", i, "/", length(todo))
  }
  have <- ids[file.exists(file.path(cache, paste0(ids, ".txt")))]
  if (!length(have)) { message("  no open-access methods sections"); return(invisible()) }
  mx <- do.call(rbind, lapply(have, function(id)
    cbind(pmcid = id, extract_method_fields(cut_backmatter(paste(readLines(file.path(cache, paste0(id, ".txt")), warn = FALSE), collapse = " "))),
          stringsAsFactors = FALSE)))
  write_tsv(mx, out_f)
  sm <- merge(p[, c("study_group", "pmcid", "pmid", "doi", "year", "confidence")], mx, by = "pmcid")
  write_tsv(sm, file.path(dir, "study_methods.tsv"))
  message(sprintf("  methods extracted for %d papers -> %d studies", nrow(mx), length(unique(sm$study_group))))
}

# -------------------------------------------------------------- combine ----
combine_enrich <- function(root) {
  dirs <- dirname(Sys.glob(file.path(root, "*", "by_study.tsv")))
  if (!length(dirs)) return(invisible())
  for (f in c("papers.tsv", "study_factors.tsv", "study_methods.tsv")) {
    l <- lapply(dirs, function(d) { x <- read_tsv_file(file.path(d, f)); if (nrow(x)) cbind(species = basename(d), x, stringsAsFactors = FALSE) })
    l <- Filter(Negate(is.null), l)
    if (!length(l)) next
    cols <- unique(unlist(lapply(l, names)))
    x <- do.call(rbind, lapply(l, function(y) { for (c in setdiff(cols, names(y))) y[[c]] <- NA; y[cols] }))
    write_tsv(x, file.path(root, paste0("all_species_", f)))
  }
  cov <- do.call(rbind, lapply(dirs, function(d) {
    bs <- tryCatch(load_designed(d), error = function(e) data.frame())
    g  <- unique(bs$study_group)
    sg <- function(f, filt = NULL) { x <- read_tsv_file(file.path(d, f)); if (!nrow(x)) return(0L)
      if (!is.null(filt)) x <- x[filt(x), ]; length(intersect(unique(x$study_group), g)) }
    data.frame(species = basename(d), designed_studies = length(g),
               with_paper = sg("papers.tsv"),
               with_linked_paper = sg("papers.tsv", function(x) x$confidence == "linked"),
               with_pmc = sg("papers.tsv", function(x) nzchar(nz(x$pmcid))),
               with_methods = sg("study_methods.tsv"),
               with_factors = sg("study_factors.tsv", function(x) as.numeric(x$n_factors) > 0),
               stringsAsFactors = FALSE)
  }))
  write_tsv(cov, file.path(root, "enrichment_coverage.tsv"))
  print(cov, row.names = FALSE)
}

# ----------------------------------------------------------------- main ----
main_enrich <- function() {
  a <- commandArgs(trailingOnly = TRUE)
  force <- "--force" %in% a; a <- setdiff(a, "--force")
  step <- if (length(a)) a[1] else "help"
  root <- if (length(a) >= 2) a[2] else "evidence"
  if (!step %in% c("papers", "biosample", "methods", "all", "combine")) {
    message("Usage: Rscript enrich_evidence.R <papers|biosample|methods|all|combine> [evidence_dir] [species] [--force]")
    return(invisible())
  }
  if (step != "combine") {
    dirs <- dirname(Sys.glob(file.path(root, "*", "by_study.tsv")))
    if (length(a) >= 3) {
      keys <- tryCatch(select_species(a[3])$key, error = function(e) trimws(strsplit(a[3], ",")[[1]]))
      dirs <- dirs[basename(dirs) %in% keys]
    }
    if (!length(dirs)) stop("no harvested species found in ", root)
    steps <- if (step == "all") c("papers", "biosample", "methods") else step
    message("ENTREZ_KEY: ", if (nzchar(Sys.getenv("ENTREZ_KEY"))) "set" else "not set (slower)")
    for (d in dirs) for (s in steps) {
      message("== ", basename(d), ": ", s)
      tryCatch(switch(s, papers = step_papers(d, force), biosample = step_biosample(d, force),
                      methods = step_methods(d, force)),
               error = function(e) message("!! ", basename(d), " ", s, ": ", conditionMessage(e), " (rerun to resume)"))
    }
  }
  combine_enrich(root)
}

if (sys.nframe() == 0) main_enrich()
