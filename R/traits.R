# Trait suggestions ("what can I measure?") and sequencing details for the plan skeleton.

.SF_STRESS_FROM_FACTOR <- c(water = "drought", salt = "salt", nitrogen = "nutrient", phosphorus = "nutrient",
                            nutrient = "nutrient", diet = "diet", light = "light", disease = "disease", co2 = "any")

# stresses implied by a spec and question ("cold" vs "heat" for a temperature factor)
.sf_stresses <- function(spec, text = "") {
  text <- tolower(text %||% "")
  f <- vapply(spec$factors %||% list(), `[[`, "", "name")
  s <- unname(.SF_STRESS_FROM_FACTOR[f])
  if ("temperature" %in% f || grepl("\\bcold\\b|chill|freez|low temperature|\\bheat\\b|high temperature", text)) {
    if (grepl("\\bcold\\b|chill|freez|low temperature|\\d+ ?c (?:vs|versus) ", text)) s <- c(s, "cold")
    if (grepl("\\bheat\\b|high temperature|thermotoleran", text)) s <- c(s, "heat")
    if (!any(c("cold", "heat") %in% s)) s <- c(s, "cold", "heat")
  }
  if (grepl("pathogen|infect|disease|fung|blight|rust\\b|lesion", text)) s <- c(s, "disease")
  if (grepl("drought|water stress|water deficit", text)) s <- c(s, "drought")
  if (grepl("\\bsalt|salin|nacl", text)) s <- c(s, "salt")
  unique(s[!is.na(s)])
}

.sf_group_of <- function(organism, system = NULL) {
  if (!is.null(system) && system %in% c("mouse", "drosophila", "cell_culture")) return("animal")
  p <- tryCatch(.sf_practice_tables()$practice, error = function(e) NULL)
  if (!is.null(organism) && !is.null(p) && "group" %in% names(p)) {
    g <- p$group[match(organism, p$organism)]
    if (length(g) && !is.na(g)) return(if (g %in% c("plant", "tree", "alga")) "plant" else if (g == "fungus") "other" else "animal")
  }
  if (!is.null(system) && system %in% c("field", "greenhouse", "growth_chamber", "breeding_genetics", "multi_environment")) return("plant")
  NA_character_
}

#' Suggest traits to measure
#'
#' Looks up the trait catalog (inst/registry/traits.json) by organ (tissue), stress and organism group, and
#' returns traits with how to measure them, tools, whether the measurement is destructive, a design note and a
#' source. These are options for the researcher to choose from, not a recommended outcome.
#'
#' @param organ Tissue or organ ("root", "leaves", "liver"); NULL for any.
#' @param stress One or more stresses ("cold", "heat", "drought", "salt", "nutrient", "disease", "diet");
#'   NULL for general traits.
#' @param organism Organism (used only to choose plant vs animal traits).
#' @param n Maximum number of traits.
#' @return A data frame (trait, measured_by, tools, unit, destructive, note, source, doi).
#' @export
#' @examples
#' suggest_traits("roots", "cold", "Arabidopsis thaliana")
suggest_traits <- function(organ = NULL, stress = NULL, organism = NULL, n = 8) {
  tr <- load_registry("traits")$traits
  grp <- .sf_group_of(organism)
  org <- if (!is.null(organ) && nzchar(organ)) .sf_norm_tissue(organ) else NULL
  if (!is.null(org) && org %in% c("rosette", "seedling")) org <- c(org, "leaf", "whole plant")
  score <- vapply(tr, function(t) {
    if (!is.na(grp) && !t$group %in% c(grp, "any")) return(-Inf)
    to <- unlist(t$organ)
    # organ first: a trait made for the stated organ beats a generic assay that also works on it
    so <- if (is.null(org)) 0.5 else if (any(org %in% to)) 3 + (length(to) == 1) else if ("any" %in% to) 0.5 else -Inf
    st <- unlist(t$stress)
    ss <- if (!length(stress)) (if ("any" %in% st) 1 else 0) else if (any(stress %in% st)) 1.5 else if ("any" %in% st) 1 else -Inf
    so + ss
  }, numeric(1))
  keep <- which(is.finite(score))
  keep <- keep[order(-score[keep])]
  if (!length(keep)) return(data.frame())
  tr <- tr[utils::head(keep, n)]
  data.frame(
    trait = vapply(tr, `[[`, "", "trait"),
    measured_by = vapply(tr, `[[`, "", "method"),
    tools = vapply(tr, `[[`, "", "tools"),
    unit = vapply(tr, `[[`, "", "unit"),
    destructive = vapply(tr, function(t) isTRUE(t$destructive), logical(1)),
    note = vapply(tr, function(t) t$note %||% "", ""),
    source = vapply(tr, function(t) if (is.null(t$source)) "" else t$source$citation, ""),
    doi = vapply(tr, function(t) if (is.null(t$source)) "" else t$source$doi, ""),
    stringsAsFactors = FALSE)
}

.SF_ASKS_TRAITS <- "what (?:phenotyp\\w*|traits?)|which (?:phenotyp\\w*|traits?)|what (?:can|should|could) (?:i|we) (?:measure|phenotype|score|take)|what to (?:measure|phenotype|score)|phenotype traits"

# sequencing details stated in the prompt
.sf_sequencing <- function(text) {
  out <- list()
  inst <- regmatches(text, regexpr(paste0("novaseq(?: x(?: plus)?| ?\\d{4})?|hiseq(?: x(?: ten)?| ?\\d{4})?|nextseq(?: ?\\d{3,4})?|miseq|",
                                          "dnbseq(?:-?[gt]\\d+)?|bgiseq(?:-?\\d+)?|mgiseq(?:-?\\d+)?|pacbio(?: (?:sequel|revio)\\w*)?|",
                                          "promethion|gridion|minion|nanopore|element aviti|aviti|ion torrent"), text, perl = TRUE))
  if (length(inst)) {
    nice <- c(novaseq = "NovaSeq", hiseq = "HiSeq", nextseq = "NextSeq", miseq = "MiSeq", dnbseq = "DNBSEQ", bgiseq = "BGISEQ",
              mgiseq = "MGISEQ", pacbio = "PacBio", promethion = "PromethION", gridion = "GridION", minion = "MinION",
              nanopore = "Nanopore", aviti = "AVITI", "element aviti" = "Element AVITI", "ion torrent" = "Ion Torrent",
              sequel = "Sequel", revio = "Revio", x = "X", plus = "Plus", ten = "Ten")
    w <- strsplit(inst, " ")[[1]]
    out$instrument <- paste(ifelse(w %in% names(nice), nice[w], toupper(w)), collapse = " ")
  }
  rl <- regmatches(text, regexec("\\b(?:pe|2 ?x ?)(\\d{2,3})\\b|\\b(\\d{2,3}) ?(?:bp|nt|base)s? (?:paired|single)", text, perl = TRUE))[[1]]
  if (length(rl)) out$read_length <- as.numeric(rl[nzchar(rl)][2])
  if (grepl("paired[- ]end|\\bpe\\d{2,3}\\b|\\b2 ?x ?\\d{2,3}\\b", text, perl = TRUE)) out$layout <- "paired"
  else if (grepl("single[- ]end|\\bse\\d{2,3}\\b", text, perl = TRUE)) out$layout <- "single"
  dp <- regmatches(text, regexec("(\\d+(?:\\.\\d+)?) ?(?:m|million) (?:reads|read pairs|fragments)", text, perl = TRUE))[[1]]
  if (length(dp)) out$depth_m <- as.numeric(dp[2])
  if (length(out)) out else NULL
}

# skeleton hints from published practice for a missing tissue / sequencing value
.sf_practice_hint <- function(spec, what = c("tissue", "sequencing")) {
  what <- match.arg(what)
  if (is.null(spec$organism)) return(NULL)
  techs <- c(unname(.SF_TECH_BY_ASSAY[unlist(spec$assays)]), unname(.SF_TECH_BY_SYSTEM[spec$system %||% ""]))
  techs <- unique(techs[!is.na(techs)])
  if (!length(techs)) return(NULL)
  p <- .sf_practice_tables()$practice
  r <- p[p$organism == spec$organism & p$technique == techs[1], , drop = FALSE]
  if (!nrow(r)) return(NULL)
  if (what == "tissue") {
    t <- r[r$tissue != "all", , drop = FALSE]
    if (!nrow(t)) return(NULL)
    return(paste0("most studied: ", paste(utils::head(t$tissue[order(-t$n_designed)], 4), collapse = ", ")))
  }
  a <- r[r$tissue == (spec$tissue %||% "all"), , drop = FALSE]
  if (!nrow(a)) a <- r[r$tissue == "all", , drop = FALSE]
  if (!nrow(a)) return(NULL)
  inst <- sub(" \\(\\d+\\).*$", "", a$top_instruments_recent[1])
  paste0("typical: ", inst, if (!is.na(a$mreads_median[1])) paste0(", ~", a$mreads_median[1], " M reads per sample"))
}
