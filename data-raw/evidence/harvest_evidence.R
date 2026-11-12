#!/usr/bin/env Rscript
# harvest_evidence.R (v2) -- StudyForge evidence layer: multi-species, multi-technique harvest.
#
# Per species:
#   1. GEO: sequencing series + sample protocols/characteristics (cached, capped by max_geo)
#   2. ENA census: how many runs per library_strategy
#   3. ENA per strategy: full run metadata (ENA = INSDC mirror of SRA), linked to GEO via SRX
#   4. technique classifier: Ribo-seq, CUT&Tag, scRNA-seq, DAP-seq, degradome, ... beyond SRA's strategy
#   5. per-study summary (samples, conditions, reps/condition, depth, sequencer, kits, tissues)
#   6. per-species overview by technique; combined tables across species
#
# Usage
#   Rscript harvest_evidence.R --list                         # built-in species
#   Rscript harvest_evidence.R sorghum,maize evidence         # some species
#   Rscript harvest_evidence.R plants evidence                # group: plants | trees | animals | fungi | all
#   Rscript harvest_evidence.R my_species.tsv evidence        # your own list (columns as SPECIES below)
#   Rscript harvest_evidence.R 4558 "Sorghum bicolor" evidence  # one taxon ad hoc
#   Rscript harvest_evidence.R --combine evidence             # rebuild combined tables only
#   Rscript harvest_evidence.R --resummarise evidence [sp]    # re-summarise saved runs offline (no download)
#   Rscript harvest_evidence.R --fill-skipped evidence [sp]   # fetch newest years of strategies skipped for MAX_RUNS
#   flags: --force (redo finished species), --no-combine (for SLURM array tasks)
# Env: ENTREZ_KEY (NCBI key, strongly recommended), MAX_RUNS (per strategy per species, default 750000)
# Deps: jsonlite; data.table optional (much faster for big species). SLURM recipe at the bottom.

suppressPackageStartupMessages(library(jsonlite))
HAS_DT   <- requireNamespace("data.table", quietly = TRUE)
options(timeout = 7200)
MAX_RUNS <- as.numeric(Sys.getenv("MAX_RUNS", "750000"))
ENA      <- "https://www.ebi.ac.uk/ena/portal/api"

# ------------------------------------------------------------- species ----
# min_year: only runs/series public from that year (keeps human/mouse tractable)
# max_geo : most recent GEO sequencing series to fetch protocols for
# skip    : library_strategy values not to pull (";"-separated)
sp_row <- function(key, taxid, organism, group, min_year = NA, max_geo = 400, skip = "")
  data.frame(key = key, taxid = as.character(taxid), organism = organism, group = group,
             min_year = as.integer(min_year), max_geo = as.integer(max_geo), skip = skip,
             stringsAsFactors = FALSE)

SPECIES <- rbind(
  sp_row("sorghum",       4558,  "Sorghum bicolor",            "plant"),
  sp_row("maize",         4577,  "Zea mays",                   "plant"),
  sp_row("arabidopsis",   3702,  "Arabidopsis thaliana",       "plant"),
  sp_row("rice",          4530,  "Oryza sativa",               "plant"),
  sp_row("wheat",         4565,  "Triticum aestivum",          "plant"),
  sp_row("barley",        4513,  "Hordeum vulgare",            "plant"),
  sp_row("soybean",       3847,  "Glycine max",                "plant"),
  sp_row("tomato",        4081,  "Solanum lycopersicum",       "plant"),
  sp_row("potato",        4113,  "Solanum tuberosum",          "plant"),
  sp_row("cotton",        3635,  "Gossypium hirsutum",         "plant"),
  sp_row("medicago",      3880,  "Medicago truncatula",        "plant"),
  sp_row("brachypodium",  15368, "Brachypodium distachyon",    "plant"),
  sp_row("setaria",       4556,  "Setaria viridis",            "plant"),
  sp_row("nbenthamiana",  4100,  "Nicotiana benthamiana",      "plant"),
  sp_row("physcomitrium", 3218,  "Physcomitrium patens",       "plant"),
  sp_row("grape",         29760, "Vitis vinifera",             "tree"),
  sp_row("poplar",        3694,  "Populus trichocarpa",        "tree"),
  sp_row("eucalyptus",    71139, "Eucalyptus grandis",         "tree"),
  sp_row("loblolly_pine", 3352,  "Pinus taeda",                "tree"),
  sp_row("apple",         3750,  "Malus domestica",            "tree"),
  sp_row("citrus",        2711,  "Citrus sinensis",            "tree"),
  sp_row("chlamydomonas", 3055,  "Chlamydomonas reinhardtii",  "alga"),
  sp_row("human",         9606,  "Homo sapiens",               "animal", 2025, 400, "WGS;WXS;AMPLICON;Targeted-Capture"),
  sp_row("mouse",         10090, "Mus musculus",               "animal", 2024, 400, "WGS;WXS;AMPLICON"),
  sp_row("rat",           10116, "Rattus norvegicus",          "animal"),
  sp_row("zebrafish",     7955,  "Danio rerio",                "animal"),
  sp_row("fly",           7227,  "Drosophila melanogaster",    "animal"),
  sp_row("worm",          6239,  "Caenorhabditis elegans",     "animal"),
  sp_row("xenopus",       8355,  "Xenopus laevis",             "animal"),
  sp_row("chicken",       9031,  "Gallus gallus",              "animal"),
  sp_row("pig",           9823,  "Sus scrofa",                 "animal"),
  sp_row("cattle",        9913,  "Bos taurus",                 "animal"),
  sp_row("macaque",       9544,  "Macaca mulatta",             "animal"),
  sp_row("yeast",         4932,  "Saccharomyces cerevisiae",   "fungus")
)
GROUPS <- list(plants = c("plant", "tree", "alga"), trees = "tree", animals = "animal",
               fungi = "fungus", all = c("plant", "tree", "alga", "animal", "fungus"))

ENA_FIELDS <- c(
  "run_accession", "experiment_accession", "sample_accession", "study_accession",
  "secondary_study_accession", "scientific_name", "tax_id", "library_strategy",
  "library_source", "library_selection", "library_layout", "library_construction_protocol",
  "instrument_platform", "instrument_model", "read_count", "base_count", "first_public",
  "study_title", "experiment_title", "sample_title", "sample_alias", "sample_description",
  "tissue_type", "dev_stage", "cultivar", "strain", "breed", "cell_type", "cell_line",
  "sex", "age", "treatment", "center_name"
)

# brand -> how many following words to keep ("TruSeq Stranded mRNA Library")
KIT_BRANDS <- c(
  "TruSeq" = 3, "Illumina Stranded" = 2, "NEBNext" = 3, "KAPA" = 3, "Nextera" = 2,
  "MGIEasy" = 3, "VAHTS" = 3, "Vazyme" = 2, "SMART-?Seq" = 1, "SMARTer" = 3,
  "QuantSeq" = 1, "Lexogen" = 1, "10x Genomics" = 2, "Chromium Single Cell" = 2,
  "Ribo-?Zero" = 1, "ARTseq" = 1, "Accel-NGS" = 2, "Ovation" = 2, "ScriptSeq" = 2,
  "Watchmaker" = 2, "Collibri" = 2, "SureSelect" = 2, "Twist" = 2,
  "EZ DNA Methylation" = 1, "Zymo" = 2, "Hyperactive" = 2, "CUTANA" = 2,
  "RNeasy" = 2, "DNeasy" = 2, "Spectrum Plant" = 2, "Direct-zol" = 1, "PureLink" = 2,
  "Quick-RNA" = 2, "MagMAX" = 2, "Monarch" = 2, "Dynabeads" = 1, "Diagenode" = 2,
  "TRIzol" = 0, "CTAB" = 0, "Tn5" = 0, "Covaris" = 0, "Bioruptor" = 0
)

# ------------------------------------------------------------- helpers ----
`%||%` <- function(a, b) if (is.null(a) || !length(a) || all(is.na(a))) b else a
enc <- function(x) utils::URLencode(x, reserved = TRUE)
nz  <- function(x) ifelse(is.na(x), "", x)
s1  <- function(x) if (is.null(x)) NA_character_ else paste(unlist(x), collapse = ";")
safe_name <- function(x) gsub("[^A-Za-z0-9]+", "_", x)
med <- function(x) { x <- suppressWarnings(as.numeric(x)); x <- x[!is.na(x)]; if (length(x)) stats::median(x) else NA_real_ }

get_text <- function(u, tries = 5) {
  for (i in seq_len(tries)) {
    res <- tryCatch(readLines(url(u), warn = FALSE, encoding = "UTF-8"), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    Sys.sleep(2^i)
  }
  stop("failed after ", tries, " tries: ", u, "\n", conditionMessage(res))
}

fetch_to <- function(u, dest, tries = 5) {
  for (i in seq_len(tries)) {
    ok <- tryCatch({ utils::download.file(u, dest, quiet = TRUE, mode = "wb"); TRUE },
                   error = function(e) FALSE, warning = function(w) FALSE)
    if (ok && file.exists(dest)) return(dest)
    Sys.sleep(2^i)
  }
  stop("download failed after ", tries, " tries: ", substr(u, 1, 200))
}

read_tsv_file <- function(f) {
  if (!file.exists(f) || file.size(f) == 0) return(data.frame())
  gz <- grepl("\\.gz$", f)
  if (HAS_DT) {
    args <- list(sep = "\t", quote = "", na.strings = "", fill = TRUE, colClasses = "character",
                 encoding = "UTF-8", showProgress = FALSE)
    if (gz) args$cmd <- paste("gzip -dc", shQuote(f)) else args$file <- f
    as.data.frame(do.call(data.table::fread, args))
  } else {
    utils::read.delim(if (gz) gzfile(f) else f, quote = "", na.strings = "", fill = TRUE,
                      colClasses = "character", check.names = FALSE, comment.char = "")
  }
}

write_tsv <- function(df, path) {
  utils::write.table(df, path, sep = "\t", quote = FALSE, row.names = FALSE, na = "")
  message("    wrote ", path, " (", nrow(df), " rows)")
}
write_gz <- function(df, path) {
  con <- gzfile(path, "w"); on.exit(close(con))
  utils::write.table(df, con, sep = "\t", quote = FALSE, row.names = FALSE, na = "")
}

# values that carry no information ("missing", "cultivar", GPS coordinates as tissue, ...)
NULLISH <- paste0("^(missing|missing:.*|not applicable|not collected|not provided|not available|",
                  "not determined|restricted access|na|n/?a|none|null|unknown|unspecified|other|",
                  "-+|\\.|\\?|cultivar|tissue|sample|strain|genotype|breed|variety|age|sex)$")
clean_values <- function(x, drop = character()) {
  x <- trimws(as.character(x))
  bad <- is.na(x) | !nzchar(x) | grepl(NULLISH, x, ignore.case = TRUE) |
    grepl("^-?[0-9]+\\.[0-9]+[^A-Za-z0-9]{0,3}[NSns]\\b", x, useBytes = TRUE) |
    tolower(x) %in% tolower(drop)
  x[!bad]
}

top_counts <- function(x, n = 5, drop = character()) {
  x <- clean_values(unlist(strsplit(as.character(x[!is.na(x)]), ";", fixed = TRUE)), drop)
  if (!length(x)) return(NA_character_)
  tab <- head(sort(table(x), decreasing = TRUE), n)
  paste(sprintf("%s (%d)", names(tab), as.integer(tab)), collapse = "; ")
}

# aggregate "a (3); b (1)" columns across studies -> how many studies mention each
agg_top <- function(x, n = 5) {
  v <- unlist(strsplit(x[!is.na(x)], "; ", fixed = TRUE))
  top_counts(sub(" \\(\\d+\\)$", "", v), n)
}

find_kits <- function(txt) {
  txt <- unique(txt[!is.na(txt) & nzchar(txt)])
  if (!length(txt)) return(NA_character_)
  txt <- iconv(txt, "UTF-8", "ASCII", sub = "")   # drops (R)/(TM); safe in C locale
  txt <- txt[!is.na(txt)]
  hits <- unlist(lapply(names(KIT_BRANDS), function(b) {
    p <- sprintf("\\b(?:%s)\\b(?:[ -]+[A-Za-z0-9]+){0,%d}", b, KIT_BRANDS[[b]])
    unlist(regmatches(txt, gregexpr(p, txt, ignore.case = TRUE, perl = TRUE)))
  }))
  if (!length(hits)) return(NA_character_)
  top_counts(trimws(hits), n = 6)
}

# ------------------------------------------------- replicates (heuristic) ----
REP_RX <- "(?i)(?:biological[ _-]?replicate|replicate|bio[ _-]?rep|(?<![A-Za-z])rep|_r)[ _.:#-]{0,2}(\\d{1,2})(?!\\d)"

# highest replicate label seen ("rep3", "replicate: 2")
rep_guess <- function(x) {
  x <- unique(x[!is.na(x) & nzchar(x)])
  if (!length(x)) return(NA_integer_)
  m <- regmatches(x, regexpr(REP_RX, x, perl = TRUE))
  if (!length(m)) return(NA_integer_)
  n <- as.integer(sub(".*?(\\d{1,2})$", "\\1", m, perl = TRUE))
  n <- n[n <= 50]
  if (length(n)) max(n) else NA_integer_
}

# conditions and reps/condition from sample titles: strip rep tokens / trailing index, count groups
reps_by_groups <- function(titles) {
  t <- titles[!is.na(titles) & nzchar(titles)]
  out <- c(n_conditions = NA_real_, reps = NA_real_)
  if (length(t) < 2) return(out)
  cond <- gsub(REP_RX, "", t, perl = TRUE)
  cond <- sub("[ _.#-]*[0-9]{1,2}[A-Za-z]?$", "", cond)
  cond <- tolower(gsub("[ _.-]+", "_", trimws(cond)))
  k <- length(unique(cond))
  if (k == length(t) || k == 1) return(out)        # no grouping signal
  c(n_conditions = k, reps = stats::median(as.numeric(table(cond))))
}

# ----------------------------------------------------------- technique ----
classify_technique <- function(d) {
  low  <- function(x) tolower(nz(x))
  txt  <- paste(low(d$experiment_title), low(d$sample_title), low(d$library_construction_protocol),
                low(d$geo_title), low(d$geo_extract_protocol))
  st   <- nz(d$library_strategy)
  src  <- toupper(nz(d$library_source))
  sel  <- tolower(nz(d$library_selection))
  plat <- toupper(nz(d$instrument_platform))
  h    <- function(p) grepl(p, txt, perl = TRUE)
  rna  <- st %in% c("RNA-Seq", "ssRNA-seq", "ncRNA-Seq", "miRNA-Seq", "FL-cDNA", "OTHER")
  sc   <- src %in% c("TRANSCRIPTOMIC SINGLE CELL", "GENOMIC SINGLE CELL") |
          h("single[- ]?(cell|nucle)|\\bs[cn](rna|atac)-?seq|10x genomics|chromium (single|next ?gem|controller)")
  rules <- list(                                    # first match wins
    list(sc & (st == "ATAC-seq" | h("atac")),                                   "scATAC-seq"),
    list(sc & (rna | src == "TRANSCRIPTOMIC SINGLE CELL"),                      "scRNA/snRNA-seq"),
    list(h("visium|spatial transcriptom|stereo-seq|slide-seq|merfish|xenium"),   "Spatial transcriptomics"),
    list(h("\\bm6a\\b|merip|methylated rna immuno"),                             "m6A / MeRIP-seq"),
    list(h("ribosome profil|ribo-?seq\\b|ribosome footprint|ribosome[- ]protected|polysome profil"), "Ribo-seq"),
    list(h("\\btrap-?seq\\b|translating ribosome affinity"),                     "TRAP-seq"),
    list(h("cut ?(&|and) ?(tag|run)|cut-and-(tag|run)|cutandtag|cutandrun|cutana"), "CUT&Tag / CUT&RUN"),
    list(h("\\bdap-?seq\\b|dna affinity purification"),                          "DAP-seq"),
    list(h("degradome|\\bpare\\b|parallel analysis of rna ends"),                "Degradome / PARE"),
    list(h("\\b(gro|pro|net)-?seq\\b|nascent (rna|transcript)"),                 "Nascent RNA (GRO/PRO/NET)"),
    list(st == "miRNA-Seq" | (rna & sel == "size fractionation") |
           (st %in% c("ncRNA-Seq", "OTHER") & h("small rna|\\bsrna-?seq|mirna")), "small RNA-seq"),
    list(st %in% c("RNA-Seq", "FL-cDNA", "OTHER") & src == "TRANSCRIPTOMIC" &
           plat %in% c("PACBIO_SMRT", "OXFORD_NANOPORE"),                       "Long-read RNA (Iso-Seq/ONT)"),
    list(rna & h("quantseq|lexogen|\\btag-?seq\\b|\\b3'[ -]?(tag|mrna)[- ]?seq|3'[ -]?end (rna|mrna)[- ]?seq|\\bbrb-?seq\\b|\\bmars-?seq\\b|\\blasy-?seq\\b"),
                                                                                 "3' Tag-seq"),
    list(st %in% c("Hi-C", "ChIA-PET") | h("\\bhi-?c\\b|hichip|chia-pet|\\bmicro-?c\\b"), "3D genome (Hi-C/HiChIP)"),
    list(st == "ATAC-seq" | h("\\batac-?seq"),                                   "ATAC-seq"),
    list(st == "DNase-Hypersensitivity" | h("dnase-?seq"),                       "DNase-seq"),
    list(st == "MNase-Seq",                                                      "MNase-seq"),
    list(st == "ChIP-Seq",                                                       "ChIP-seq"),
    list(st == "Bisulfite-Seq" | h("bisulfite|\\bwgbs\\b|\\bem-seq|enzymatic methyl"), "Bisulfite / methylome"),
    list(st %in% c("MeDIP-Seq", "MRE-Seq", "MBD-Seq"),                           "Methylation (enrichment)"),
    list(st == "RIP-Seq" | h("\\b(e|i|par-?)?clip-?seq\\b"),                     "RIP / CLIP-seq"),
    list(st %in% c("RNA-Seq", "ssRNA-seq"),                                      "Bulk RNA-seq"),
    list(st == "OTHER" & src == "TRANSCRIPTOMIC" & sel != "size fractionation",  "Bulk RNA-seq"),
    list(st == "ncRNA-Seq",                                                      "ncRNA-seq"),
    list(st %in% c("GBS", "RAD-Seq"),                                            "GBS / RAD-seq"),
    list(st == "WGS",                                                            "WGS / resequencing"),
    list(st == "WXS",                                                            "Exome"),
    list(st == "AMPLICON",                                                       "Amplicon"),
    list(st == "Targeted-Capture",                                               "Targeted capture")
  )
  tech <- rep(NA_character_, nrow(d))
  for (r in rules) { i <- is.na(tech) & r[[1]]; tech[i] <- r[[2]] }
  ifelse(is.na(tech), st, tech)
}

# ----------------------------------------------------------------- ENA ----
ena_fields_available <- local({
  cache <- NULL
  function() {
    if (is.null(cache))
      cache <<- utils::read.delim(text = get_text(paste0(ENA, "/returnFields?result=read_run&format=tsv")),
                                  quote = "")[[1]]
    cache
  }
})

ena_query <- function(taxid, strategy = NULL, min_year = NA) {
  q <- sprintf("tax_tree(%s)", taxid)
  if (!is.null(strategy)) q <- sprintf('%s AND library_strategy="%s"', q, strategy)
  if (!is.na(min_year)) {
    d <- if (grepl("-", as.character(min_year))) as.character(min_year) else sprintf("%d-01-01", as.integer(min_year))
    q <- sprintf("%s AND first_public>=%s", q, d)
  }
  q
}

ena_fetch <- function(query, fields, dest) {
  u <- sprintf("%s/search?result=read_run&query=%s&fields=%s&format=tsv&limit=0",
               ENA, enc(query), paste(fields, collapse = ","))
  fetch_to(u, dest)
  read_tsv_file(dest)
}

# ----------------------------------------------------------------- GEO ----
parse_soft <- function(lines, gse) {
  lines <- lines[grepl("^[\\^!]", lines)]
  start <- grepl("^\\^SAMPLE", lines)
  if (!any(start)) return(NULL)
  blocks <- split(lines, cumsum(start))
  blocks <- blocks[vapply(blocks, function(b) grepl("^\\^SAMPLE", b[1]), logical(1))]
  do.call(rbind, lapply(blocks, function(b) {
    key <- sub("^!Sample_([^ =]+).*", "\\1", b)
    val <- sub("^[^=]*= ?", "", b)
    get <- function(k) { v <- val[key == k]; if (length(v)) paste(v, collapse = " | ") else NA_character_ }
    chars  <- val[key == "characteristics_ch1"]
    tissue <- chars[grepl("^(tissue|organ|tissue type|plant part|cell type)\\s*:", chars, ignore.case = TRUE)]
    tissue <- sub("^[^:]*:\\s*", "", tissue)
    rel    <- val[key == "relation"]
    data.frame(
      gse = gse, gsm = sub("^\\^SAMPLE = ", "", b[1]),
      geo_title = get("title"), geo_source = get("source_name_ch1"),
      geo_tissue = if (length(tissue)) paste(tissue, collapse = ";") else NA_character_,
      geo_characteristics = if (length(chars)) paste(chars, collapse = " | ") else NA_character_,
      geo_library_strategy = get("library_strategy"), geo_instrument = get("instrument_model"),
      geo_extract_protocol = get("extract_protocol_ch1"),
      srx = paste(unlist(regmatches(rel, gregexpr("SRX[0-9]+", rel))), collapse = ";"),
      stringsAsFactors = FALSE)
  }))
}

harvest_geo <- function(organism, soft_dir, max_geo = 400, min_year = NA) {
  if (!nzchar(organism)) return(list(series = NULL, samples = NULL))
  eutils <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
  key    <- Sys.getenv("ENTREZ_KEY")
  key_q  <- if (nzchar(key)) paste0("&api_key=", key) else ""
  pause  <- if (nzchar(key)) 0.12 else 0.4
  term   <- sprintf('"%s"[Organism] AND gse[ETYP]', organism)
  if (!is.na(min_year)) term <- sprintf('%s AND ("%d"[PDAT] : "3000"[PDAT])', term, as.integer(min_year))
  es  <- fromJSON(paste(get_text(sprintf("%s/esearch.fcgi?db=gds&term=%s&retmax=%d&retmode=json%s",
                                         eutils, enc(term), min(10000L, 3L * max_geo), key_q)), collapse = ""))
  ids <- es$esearchresult$idlist
  message("    GEO series: ", es$esearchresult$count, " total, ", length(ids), " fetched")
  if (!length(ids)) return(list(series = NULL, samples = NULL))

  series <- list()
  for (b in split(ids, ceiling(seq_along(ids) / 200))) {
    js <- fromJSON(paste(get_text(sprintf("%s/esummary.fcgi?db=gds&id=%s&retmode=json%s",
                                          eutils, paste(b, collapse = ","), key_q)), collapse = ""),
                   simplifyVector = FALSE)
    for (uid in unlist(js$result$uids)) {
      r <- js$result[[uid]]
      series[[length(series) + 1]] <- data.frame(
        gse = s1(r$accession), gse_title = s1(r$title), gdstype = s1(r$gdstype),
        n_samples = suppressWarnings(as.integer(s1(r$n_samples))), gpl = s1(r$gpl),
        pdat = s1(r$pdat), pubmed = s1(r$pubmedids), stringsAsFactors = FALSE)
    }
    Sys.sleep(pause)
  }
  series <- do.call(rbind, series)
  hts <- head(series$gse[grepl("high throughput sequencing", series$gdstype, ignore.case = TRUE)], max_geo)
  message("    GEO sequencing series to parse: ", length(hts))
  dir.create(soft_dir, showWarnings = FALSE, recursive = TRUE)
  samples <- list()
  for (i in seq_along(hts)) {
    g <- hts[i]
    f <- file.path(soft_dir, paste0(g, ".soft"))
    if (!file.exists(f)) {
      txt <- tryCatch(get_text(sprintf(
        "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=%s&targ=gsm&form=text&view=brief", g)),
        error = function(e) { message("    skip ", g, ": ", conditionMessage(e)); NULL })
      if (is.null(txt)) next
      writeLines(txt, f)
      Sys.sleep(pause)
    }
    samples[[g]] <- parse_soft(readLines(f, warn = FALSE, encoding = "UTF-8"), g)
    if (i %% 50 == 0) message("      ", i, "/", length(hts))
  }
  list(series = series, samples = do.call(rbind, samples))
}

GEO_COLS <- c("gse", "gsm", "geo_title", "geo_tissue", "geo_characteristics", "geo_extract_protocol")

geo_link_table <- function(samples) {
  if (is.null(samples) || !nrow(samples)) return(NULL)
  s <- samples[!is.na(samples$srx) & nzchar(samples$srx), ]
  if (!nrow(s)) return(NULL)
  ids  <- strsplit(s$srx, ";", fixed = TRUE)
  long <- s[rep(seq_len(nrow(s)), lengths(ids)), GEO_COLS]
  long$experiment_accession <- unlist(ids)
  long[!duplicated(long$experiment_accession), ]
}

link_geo <- function(runs, link) {
  if (is.null(link)) { for (f in GEO_COLS) runs[[f]] <- NA_character_; return(runs) }
  i <- match(runs$experiment_accession, link$experiment_accession)
  for (f in GEO_COLS) runs[[f]] <- link[[f]][i]
  runs
}

# ------------------------------------------------------------- summary ----
# techniques where every sample is a genotype/individual: "reps per condition" doesn't apply
POP_TECH <- c("WGS / resequencing", "GBS / RAD-seq", "Amplicon", "Exome", "Targeted capture")

# JGI-style submissions register one BioProject per sample ("<experiment> - <sample> transcriptome").
# Group such small BioProjects by center + the title text before " - " so one experiment = one study.
assign_study_group <- function(runs) {
  st  <- runs$study_accession
  ns  <- tapply(runs$sample_accession, st, function(x) length(unique(x)))
  acc <- names(ns)
  i   <- match(acc, st)
  title  <- nz(runs$study_title[i])
  center <- tolower(nz(runs$center_name[i]))
  org    <- tolower(nz(runs$scientific_name[i]))
  year   <- substr(nz(runs$first_public[i]), 1, 4)
  prefix <- tolower(trimws(sub(" - .*$", "", title)))
  # what's left of the prefix once the species name and boilerplate are removed must say something
  core <- mapply(function(p, o) trimws(gsub("\\s+", " ", if (nzchar(o)) sub(o, "", p, fixed = TRUE) else p)), prefix, org,
                 USE.NAMES = FALSE)
  core <- gsub("\\b(raw sequence reads|transcriptome|gene expression( profiling)?|rna-?seq|sequencing)\\b",
               "", core, perl = TRUE)
  split_like <- as.vector(ns) <= 3 & grepl(" - ", title, fixed = TRUE) & nchar(trimws(core)) >= 2
  key <- ifelse(split_like, paste0("grp:", center, ":", prefix, ":", year), acc)
  cnt  <- table(key)
  lone <- split_like & as.vector(cnt[key]) < 2          # a "group" of one is just a study
  key[lone] <- acc[lone]
  key[match(st, acc)]
}

summarise_studies <- function(runs, organism) {
  runs$study_accession <- ifelse(nzchar(nz(runs$study_accession)), runs$study_accession, "unknown_study")
  runs$sample_accession <- ifelse(nzchar(nz(runs$sample_accession)), runs$sample_accession, runs$run_accession)
  runs$technique[!nzchar(nz(runs$technique))] <- "unclassified"
  runs$study_group  <- assign_study_group(runs)
  runs$tissue_any   <- ifelse(nzchar(nz(runs$tissue_type)), runs$tissue_type,
                              ifelse(nzchar(nz(runs$cell_type)), runs$cell_type, runs$geo_tissue))
  runs$genotype_any <- ifelse(nzchar(nz(runs$cultivar)), runs$cultivar,
                              ifelse(nzchar(nz(runs$strain)), runs$strain,
                                     ifelse(nzchar(nz(runs$breed)), runs$breed, runs$cell_line)))
  runs$protocol_any <- trimws(paste(nz(runs$library_construction_protocol), nz(runs$geo_extract_protocol)))
  runs$read_count   <- suppressWarnings(as.numeric(runs$read_count))

  groups <- split(seq_len(nrow(runs)), paste(runs$study_group, runs$technique, sep = "\r"))
  out <- lapply(groups, function(ix) {
    d   <- runs[ix, , drop = FALSE]
    smp <- d[!duplicated(d$sample_accession), , drop = FALSE]
    titles <- ifelse(nzchar(nz(smp$sample_title)), smp$sample_title,
                     ifelse(nzchar(nz(smp$geo_title)), smp$geo_title, smp$sample_alias))
    pop <- d$technique[1] %in% POP_TECH
    rg  <- if (pop) c(n_conditions = NA, reps = NA) else reps_by_groups(titles)
    fp  <- d$first_public[nzchar(nz(d$first_public))]
    bps <- unique(d$study_accession)
    grouped <- isTRUE(startsWith(nz(d$study_group[1]), "grp:"))
    data.frame(
      study = if (length(bps) > 1) sprintf("%s +%d", bps[1], length(bps) - 1) else bps[1],
      study_group = d$study_group[1],
      n_bioprojects = length(bps),
      bioprojects = paste(bps, collapse = ";"),
      srp = s1(unique(stats::na.omit(d$secondary_study_accession))),
      gse = s1(unique(stats::na.omit(d$gse))),
      library_strategy = s1(unique(d$library_strategy)),
      technique = d$technique[1],
      year = if (length(fp)) substr(min(fp), 1, 4) else NA_character_,
      n_runs = nrow(d),
      n_samples = nrow(smp),
      designed = nrow(smp) >= 4,
      n_conditions = rg[["n_conditions"]],
      reps_per_condition = rg[["reps"]],
      reps_label_max = if (pop) NA_integer_ else
        rep_guess(c(smp$sample_title, smp$sample_alias, d$experiment_title,
                    smp$geo_title, smp$geo_characteristics)),
      platform = top_counts(d$instrument_platform, 2),
      instruments = top_counts(d$instrument_model, 3),
      layout = top_counts(d$library_layout, 2),
      selection = top_counts(d$library_selection, 2),
      median_Mreads = round(med(d$read_count) / 1e6, 1),
      tissues = top_counts(d$tissue_any, 6),
      dev_stage = top_counts(d$dev_stage, 4),
      genotypes = top_counts(d$genotype_any, 4, drop = organism),
      sex = top_counts(smp$sex, 3),
      treatment = top_counts(smp$treatment, 4),
      kits = find_kits(d$protocol_any),
      title = if (grouped) trimws(sub(" - .*$", "", d$study_title[1])) else d$study_title[1],
      stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, out)
  rownames(out) <- NULL
  out
}

overview_species <- function(bs) {
  ov <- do.call(rbind, lapply(split(bs, bs$technique), function(d) {
    dd <- d[as.logical(d$designed), , drop = FALSE]
    yr <- suppressWarnings(as.integer(d$year))
    data.frame(
      technique = d$technique[1],
      n_studies = nrow(d),
      n_designed = nrow(dd),
      n_samples = sum(as.numeric(d$n_samples)),
      median_samples_designed = med(dd$n_samples),
      median_conditions = med(dd$n_conditions),
      median_reps_per_condition = med(dd$reps_per_condition),
      median_reps_label = med(dd$reps_label_max),
      median_Mreads = med(d$median_Mreads),
      years = if (any(!is.na(yr))) paste(range(yr, na.rm = TRUE), collapse = "-") else NA_character_,
      top_instruments = agg_top(d$instruments, 3),
      top_kits = agg_top(dd$kits, 5),
      top_tissues = agg_top(dd$tissues, 5),
      stringsAsFactors = FALSE)
  }))
  ov[order(-ov$n_designed, -ov$n_studies), ]
}

# ------------------------------------------------------------- species ----
harvest_species <- function(sp, out_root, force = FALSE) {
  dir  <- file.path(out_root, sp$key)
  done <- file.path(dir, "by_study.tsv")
  if (file.exists(done) && !force) { message("== ", sp$key, ": already done (--force to redo)"); return(invisible()) }
  dir.create(file.path(dir, "runs"), recursive = TRUE, showWarnings = FALSE)
  tmp <- file.path(dir, "ena_tmp.tsv"); on.exit(unlink(tmp), add = TRUE)
  message("== ", sp$key, " (", sp$organism, ", taxid ", sp$taxid,
          if (!is.na(sp$min_year)) paste0(", public from ", sp$min_year), ")")

  message("  GEO ...")
  geo <- tryCatch(harvest_geo(sp$organism, file.path(dir, "geo_soft"), sp$max_geo, sp$min_year),
                  error = function(e) { message("    GEO failed: ", conditionMessage(e)); list() })
  if (!is.null(geo$series))  write_tsv(geo$series,  file.path(dir, "geo_series.tsv"))
  if (!is.null(geo$samples)) write_tsv(geo$samples, file.path(dir, "geo_samples.tsv"))
  link <- geo_link_table(geo$samples)

  message("  ENA census ...")
  census <- ena_fetch(ena_query(sp$taxid, NULL, sp$min_year), "library_strategy", tmp)
  if (!nrow(census)) { message("    no ENA runs"); return(invisible()) }
  cen <- as.data.frame(table(library_strategy = census$library_strategy), stringsAsFactors = FALSE)
  names(cen)[2] <- "n_runs"
  cen  <- cen[order(-cen$n_runs), ]
  skip <- trimws(unlist(strsplit(nz(sp$skip), ";", fixed = TRUE)))
  cen$status <- ifelse(cen$library_strategy %in% skip, "skipped (config)",
                       ifelse(cen$n_runs > MAX_RUNS, "skipped (> MAX_RUNS; set min_year)", "harvested"))
  write_tsv(cen, file.path(dir, "census.tsv"))
  rm(census)

  fields <- intersect(ENA_FIELDS, ena_fields_available())
  res <- list()
  for (s in cen$library_strategy[cen$status == "harvested"]) {
    message(sprintf("  %-24s %9d runs", s, cen$n_runs[cen$library_strategy == s]))
    runs <- tryCatch(ena_fetch(ena_query(sp$taxid, s, sp$min_year), fields, tmp),
                     error = function(e) { message("    failed: ", conditionMessage(e)); NULL })
    if (is.null(runs) || !nrow(runs)) next
    for (f in setdiff(ENA_FIELDS, names(runs))) runs[[f]] <- NA_character_
    runs <- link_geo(runs, link)
    runs$technique <- classify_technique(runs)
    write_gz(runs, file.path(dir, "runs", paste0(safe_name(s), ".tsv.gz")))
    res[[s]] <- summarise_studies(runs, sp$organism)
    rm(runs); invisible(gc())
  }
  finalize_species(res, sp, dir)
}

finalize_species <- function(res, sp, dir) {
  done <- file.path(dir, "by_study.tsv")
  bs <- do.call(rbind, res)
  if (is.null(bs) || !nrow(bs)) { message("    nothing summarised"); return(invisible()) }
  bs <- cbind(species = sp$key, organism = sp$organism, group = sp$group, bs, stringsAsFactors = FALSE)
  bs <- bs[order(bs$technique, -suppressWarnings(as.integer(bs$year)), na.last = TRUE), ]
  ov <- cbind(species = sp$key, organism = sp$organism, group = sp$group, overview_species(bs),
              stringsAsFactors = FALSE)
  write_tsv(ov, file.path(dir, "overview.tsv"))
  prev <- file.path(dir, "by_study.prev.tsv")          # lets enrich_evidence.R reuse earlier paper searches
  if (file.exists(done) && !file.exists(prev)) file.copy(done, prev)
  write_tsv(bs, done)                                  # written last = species finished
  print(head(ov[, c("technique", "n_studies", "n_designed", "median_samples_designed",
                    "median_reps_per_condition", "median_Mreads")], 15), row.names = FALSE)
  invisible(bs)
}

ena_count <- function(query) {
  u <- sprintf("%s/count?result=read_run&query=%s", ENA, enc(query))
  x <- get_text(u)
  n <- suppressWarnings(as.numeric(gsub("[^0-9]", "", x[length(x)])))
  if (is.na(n)) stop("could not read ENA count: ", paste(x, collapse = " "))
  n
}

# Strategies skipped for size (e.g. human/mouse RNA-seq): take the newest years that fit under MAX_RUNS.
fill_skipped <- function(out_root, keys = NULL) {
  cen_files <- Sys.glob(file.path(out_root, "*", "census.tsv"))
  if (!is.null(keys)) cen_files <- cen_files[basename(dirname(cen_files)) %in% keys]
  this_year <- as.integer(format(Sys.Date(), "%Y"))
  fields <- intersect(ENA_FIELDS, ena_fields_available())
  for (cf in cen_files) {
    dir <- dirname(cf); key <- basename(dir)
    cen <- read_tsv_file(cf)
    todo <- cen$library_strategy[grepl("MAX_RUNS", cen$status)]
    if (!length(todo)) next
    sp <- if (key %in% SPECIES$key) SPECIES[SPECIES$key == key, ] else NULL
    if (is.null(sp)) { message("!! ", key, ": not a built-in species, skipping"); next }
    gs <- read_tsv_file(file.path(dir, "geo_samples.tsv"))
    link <- geo_link_table(if (nrow(gs)) gs else NULL)
    tmp <- file.path(dir, "ena_tmp.tsv")
    for (s in todo) {
      start <- NA_character_; nn <- NA_real_
      for (y in this_year:max(2005L, if (is.na(sp$min_year)) 2005L else sp$min_year)) {
        n <- ena_count(ena_query(sp$taxid, s, y))
        if (n > MAX_RUNS) break
        start <- sprintf("%d-01-01", y); nn <- n
      }
      if (is.na(start)) {                       # even this year is too big: step back month by month
        this_month <- as.integer(format(Sys.Date(), "%m"))
        for (m in this_month:1) {
          d <- sprintf("%d-%02d-01", this_year, m)
          n <- ena_count(ena_query(sp$taxid, s, d))
          if (n > MAX_RUNS) break
          start <- d; nn <- n
        }
      }
      if (is.na(start)) { message("!! ", key, " ", s, ": even this month exceeds MAX_RUNS"); next }
      message(sprintf("== %s %s: %d runs public from %s", key, s, nn, start))
      runs <- tryCatch(ena_fetch(ena_query(sp$taxid, s, start), fields, tmp),
                       error = function(e) { message("   failed: ", conditionMessage(e)); NULL })
      if (is.null(runs) || !nrow(runs)) next
      for (f in setdiff(ENA_FIELDS, names(runs))) runs[[f]] <- NA_character_
      runs <- link_geo(runs, link)
      runs$technique <- classify_technique(runs)
      write_gz(runs, file.path(dir, "runs", paste0(safe_name(s), ".tsv.gz")))
      cen$status[cen$library_strategy == s] <- sprintf("harvested from %s (%d newest runs)", start, nn)
      write_tsv(cen, cf)
      rm(runs); invisible(gc())
    }
    unlink(tmp)
  }
  message("Now run: Rscript harvest_evidence.R --resummarise ", out_root)
}

# Rebuild by_study/overview from saved runs/*.tsv.gz with the current classifier and grouping.
# No network. Use after updating this script instead of re-downloading.
resummarise <- function(out_root, keys = NULL) {
  dirs <- dirname(dirname(Sys.glob(file.path(out_root, "*", "runs", "*.tsv.gz"))))
  dirs <- unique(dirs)
  if (!is.null(keys)) dirs <- dirs[basename(dirs) %in% keys]
  for (dir in dirs) {
    key <- basename(dir)
    sp  <- if (key %in% SPECIES$key) SPECIES[SPECIES$key == key, ] else {
      ov <- read_tsv_file(file.path(dir, "overview.tsv"))
      sp_row(key, NA, ov$organism[1] %||% "", ov$group[1] %||% "custom")
    }
    message("== resummarise ", key)
    res <- lapply(Sys.glob(file.path(dir, "runs", "*.tsv.gz")), function(f) {
      runs <- read_tsv_file(f)
      if (!nrow(runs)) return(NULL)
      for (c in setdiff(c(ENA_FIELDS, GEO_COLS), names(runs))) runs[[c]] <- NA_character_
      runs$technique <- classify_technique(runs)
      out <- tryCatch(summarise_studies(runs, sp$organism),
                      error = function(e) { message("!! ", key, " ", basename(f), ": ", conditionMessage(e)); NULL })
      rm(runs); invisible(gc())
      out
    })
    tryCatch(finalize_species(res, sp, dir),
             error = function(e) message("!! ", key, ": ", conditionMessage(e)))
  }
}

combine <- function(out_root) {
  bs_files <- Sys.glob(file.path(out_root, "*", "by_study.tsv"))
  if (!length(bs_files)) { message("nothing to combine in ", out_root); return(invisible()) }
  message("== combining ", length(bs_files), " species")
  bind <- function(files) {
    l <- lapply(files, read_tsv_file)
    cols <- unique(unlist(lapply(l, names)))
    do.call(rbind, lapply(l, function(x) { for (c in setdiff(cols, names(x))) x[[c]] <- NA; x[cols] }))
  }
  bs <- bind(bs_files)
  ov <- bind(Sys.glob(file.path(out_root, "*", "overview.tsv")))
  write_tsv(bs, file.path(out_root, "all_species_by_study.tsv"))
  write_tsv(ov, file.path(out_root, "all_species_overview.tsv"))
  m <- as.data.frame.matrix(stats::xtabs(as.numeric(n_designed) ~ technique + species, data = ov))
  m <- cbind(technique = rownames(m), m, total = rowSums(m))
  write_tsv(m[order(-m$total), ], file.path(out_root, "designed_studies_technique_x_species.tsv"))
}

select_species <- function(x) {
  if (file.exists(x)) {
    s <- utils::read.delim(x, colClasses = "character", na.strings = c("", "NA"))
    s$min_year <- as.integer(s$min_year %||% NA); s$max_geo <- as.integer(s$max_geo %||% 400)
    s$skip <- nz(s$skip %||% ""); s$group <- s$group %||% "custom"
    return(s)
  }
  toks <- trimws(unlist(strsplit(tolower(x), ",")))
  keys <- unique(unlist(lapply(toks, function(t)
    if (t %in% names(GROUPS)) SPECIES$key[SPECIES$group %in% GROUPS[[t]]] else t)))
  bad <- setdiff(keys, SPECIES$key)
  if (length(bad)) stop("unknown species: ", paste(bad, collapse = ", "),
                        "\nknown: ", paste(SPECIES$key, collapse = ", "),
                        "\nor give a taxid: Rscript harvest_evidence.R 4558 \"Sorghum bicolor\" evidence")
  SPECIES[match(keys, SPECIES$key), ]
}

# ---------------------------------------------------------------- main ----
main <- function() {
  a <- commandArgs(trailingOnly = TRUE)
  force <- "--force" %in% a; no_combine <- "--no-combine" %in% a
  a   <- setdiff(a, c("--force", "--no-combine"))
  arg <- function(i, default) if (length(a) >= i) a[i] else default
  if (!length(a) || a[1] %in% c("--list", "-h", "--help")) {
    print(SPECIES, row.names = FALSE)
    message("\nUsage: Rscript harvest_evidence.R <species|group|file.tsv|taxid [\"Organism\"]> [out_dir] [--force] [--no-combine]")
    return(invisible())
  }
  if (a[1] == "--keys")    { cat(SPECIES$key, sep = "\n"); return(invisible()) }
  if (a[1] == "--combine") { combine(arg(2, "evidence")); return(invisible()) }
  if (a[1] == "--fill-skipped") {
    fill_skipped(arg(2, "evidence"), if (length(a) >= 3) select_species(a[3])$key else NULL)
    return(invisible())
  }
  if (a[1] == "--resummarise") {
    root <- arg(2, "evidence")
    keys <- if (length(a) >= 3) select_species(a[3])$key else NULL
    resummarise(root, keys)
    if (!no_combine) combine(root)
    return(invisible())
  }
  if (grepl("^[0-9]+$", a[1])) {
    org  <- arg(2, "")
    todo <- sp_row(if (nzchar(org)) safe_name(tolower(org)) else paste0("taxid_", a[1]), a[1], org, "custom")
    out_root <- arg(3, "evidence")
  } else {
    todo <- select_species(a[1]); out_root <- arg(2, "evidence")
  }
  dir.create(out_root, showWarnings = FALSE, recursive = TRUE)
  message("data.table: ", if (HAS_DT) "yes" else "no (install for big species)",
          " | ENTREZ_KEY: ", if (nzchar(Sys.getenv("ENTREZ_KEY"))) "set" else "not set",
          " | MAX_RUNS: ", MAX_RUNS)
  for (i in seq_len(nrow(todo)))
    tryCatch(harvest_species(todo[i, ], out_root, force),
             error = function(e) message("!! ", todo$key[i], " failed: ", conditionMessage(e), " (rerun to retry)"))
  if (!no_combine) combine(out_root)
}

if (sys.nframe() == 0) main()

# ---------------------------------------------------------------- SLURM ----
# One species per array task; %4 keeps NCBI/ENA from rate-limiting the cluster's IP.
# Big ones (human, mouse, maize, arabidopsis, rice, wheat) want --mem=32G and data.table.
#
#   #!/bin/bash
#   #SBATCH -J evidence -t 24:00:00 --mem=32G -c 1 --array=1-34%4 -o logs/%x_%a.log
#   export ENTREZ_KEY=xxxx
#   key=$(Rscript harvest_evidence.R --keys | sed -n "${SLURM_ARRAY_TASK_ID}p")
#   Rscript harvest_evidence.R "$key" evidence --no-combine
#
# then, after all tasks finish:
#   Rscript harvest_evidence.R --combine evidence
