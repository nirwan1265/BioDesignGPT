# Trait suggestions ("what can I measure?") and sequencing details for the plan skeleton.

# stresses implied by a spec and question ("cold" vs "heat" for a temperature factor)
.sf_stresses <- function(spec, text = "") {
  text <- tolower(text %||% "")
  f <- vapply(spec$factors %||% list(), `[[`, "", "name")
  s <- unname(.sf_map("stress_from_factor")[f])
  if ("temperature" %in% f || grepl(.sf_cue("temperature_stress"), text)) {
    if (grepl(.sf_cue("cold_stress"), text)) s <- c(s, "cold")
    if (grepl(.sf_cue("heat_stress"), text)) s <- c(s, "heat")
    if (!any(c("cold", "heat") %in% s)) s <- c(s, "cold", "heat")
  }
  if (grepl(.sf_cue("disease_stress"), text)) s <- c(s, "disease")
  if (grepl(.sf_cue("drought_stress"), text)) s <- c(s, "drought")
  if (grepl(.sf_cue("salt_stress"), text)) s <- c(s, "salt")
  unique(s[!is.na(s)])
}

.sf_group_of <- function(organism, system = NULL) {
  if (!is.null(system) && identical(unname(.sf_map("system_organism_group")[system]), "animal")) return("animal")
  p <- tryCatch(.sf_practice_tables()$practice, error = function(e) NULL)
  if (!is.null(organism) && !is.null(p) && "group" %in% names(p)) {
    g <- p$group[match(organism, p$organism)]
    if (length(g) && !is.na(g)) return(unname(.sf_map("taxon_group")[g]) %|na|% "animal")
  }
  if (!is.null(system) && identical(unname(.sf_map("system_organism_group")[system]), "plant")) return("plant")
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
  if (!is.null(org) && org %in% names(.sf_groups("organ_also"))) org <- c(org, .sf_groups("organ_also")[[org]])
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



# sequencing details stated in the prompt
.sf_sequencing <- function(text) {
  out <- list()
  inst <- regmatches(text, regexpr(.sf_cue("sequencer"), text, perl = TRUE))
  if (length(inst)) {
    nice <- .sf_map("sequencer_name")
    w <- strsplit(inst, " ")[[1]]
    out$instrument <- paste(ifelse(w %in% names(nice), nice[w], toupper(w)), collapse = " ")
  }
  rl <- regmatches(text, regexec(.sf_cue("read_length"), text, perl = TRUE))[[1]]
  if (length(rl)) out$read_length <- as.numeric(rl[nzchar(rl)][2])
  if (grepl(.sf_cue("paired_end"), text, perl = TRUE)) out$layout <- "paired"
  else if (grepl(.sf_cue("single_end"), text, perl = TRUE)) out$layout <- "single"
  dp <- regmatches(text, regexec(.sf_cue("read_depth"), text, perl = TRUE))[[1]]
  if (length(dp)) out$depth_m <- as.numeric(dp[2])
  if (length(out)) out else NULL
}

# skeleton hints from published practice for a missing tissue / sequencing value
.sf_practice_hint <- function(spec, what = c("tissue", "sequencing")) {
  what <- match.arg(what)
  if (is.null(spec$organism)) return(NULL)
  techs <- c(unname(.sf_map("tech_by_assay")[unlist(spec$assays)]), unname(.sf_map("tech_by_system")[spec$system %||% ""]))
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
