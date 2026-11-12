# General, table-driven extraction layer.
#
# Runs after the hand-written rules in extract_spec_local() and only fills gaps, so it can't undo tuned
# behaviour. Everything here is driven by the alias table (inst/agent/aliases.tsv) and a few generic
# patterns, so new organisms, assays or factor words need new table rows, not new code:
#   organism  any organism alias, longest match first
#   assays    any assay alias (in every system)
#   factors   "<N> <factor word>", "<N> conditions/levels/groups/types of <X>", "<X> at/with <N> levels"
#             any number, any word; words not in the table become free-text factors
#   goal      design a new study vs analyse data already collected
#   free text phenotype/outcome as written, tissue -- shown for the user to confirm, never treated as stated facts

# every alias of one category found in the text, in reading order (longest alias wins an overlap)
.sf_find_all <- function(text, cat) {
  t <- .sf_alias_table()
  t <- t[t$category == cat, ]
  if (nrow(t) > 300) {   # big vocabularies: only aliases whose first word is in the text
    first <- sub("^[^a-z0-9]*([a-z0-9]+).*$", "\\1", tolower(t$alias))
    t <- t[first %in% regmatches(text, gregexpr("[a-z0-9]+", text))[[1]], ]
  }
  t <- t[order(-nchar(t$alias)), ]
  hits <- list()
  taken <- rep(FALSE, nchar(text))
  for (i in seq_len(nrow(t))) {
    m <- gregexpr(paste0("(?<![a-z0-9])\\Q", gsub("\\E", "", tolower(t$alias[i]), fixed = TRUE), "\\E(?![a-z0-9])"),
                  text, perl = TRUE)[[1]]
    for (k in seq_along(m)) {
      if (m[k] < 0) next
      rng <- m[k]:(m[k] + attr(m, "match.length")[k] - 1)
      if (any(taken[rng])) next
      taken[rng] <- TRUE
      hits[[length(hits) + 1]] <- c(pos = m[k], term = t$canonical_term[i])
    }
  }
  if (!length(hits)) return(character())
  h <- do.call(rbind, hits)
  unique(h[order(as.integer(h[, "pos"])), "term"])
}

# canonical name of a factor phrase: alias table first, else the phrase itself (free text)
.sf_factor_name <- function(phrase) {
  p <- trimws(tolower(phrase))
  if (!nzchar(p)) return(NA_character_)
  hit <- .sf_find_all(p, "factor")
  if (length(hit)) return(hit[1])
  if (length(.sf_find_all(p, "genotype_noun"))) return("genotype")
  p <- sub("(ies)$", "y", sub("(?<![su])s$", "", p, perl = TRUE))
  p
}

# words that are counted levels of something
.SF_LEVEL_NOUNS <- c(
  "conditions?", "treatments?", "treatment groups?", "experimental groups?", "groups?", "levels?", "doses?",
  "dose groups?", "concentrations?", "rates?", "regimes?", "diets?", "temperatures?", "time ?points?",
  "timepoints?", "sampling times?", "harvest times?", "stages?", "developmental stages?", "growth stages?",
  "tissues?", "organs?", "tissue types?", "cell types?", "ages?", "age groups?", "photoperiods?",
  "light levels?", "salinity levels?", "salt levels?", "water levels?", "irrigation levels?", "watering regimes?",
  "fertilizer levels?", "nitrogen rates?", "nitrogen levels?", "media", "medium types?", "soil types?",
  "inoculations?", "pathogens?", "isolates?", "drugs?", "compounds?", "hormones?", "stresses", "stress treatments?",
  "types", "kinds", "variants?")
.SF_GENO_NOUNS <- c("genotypes?", "lines", "cultivars?", "varieties", "accessions?", "strains?", "hybrids?",
                    "landraces", "ecotypes?", "inbreds?", "mutants?", "cell lines?", "breeds?", "families", "clones?")
# not factor levels: replication, space, sampling, units
.SF_NOT_LEVELS <- "^(reps?|replicates?|replications?|blocks?|plots?|pots?|plants?|sites?|locations?|years?|seasons?|samples?|cells?|mice|animals?|individuals?|benches?|trays?|cages?|vials?|chambers?|weeks?|days?|hours?|minutes?|times|people|patients?|participants?)$"

.sf_generic_factors <- function(text) {
  stop <- paste0("(?!(?:per|at|in|on|for|this|each|from|and|with|of|to|by|or|than|reps?|replicates?|plants?|plots?|",
                 "were|was|are|is|be|been|got|get|received|receive|had|have|has|given|took|take|people|patients?|mice|animals?)\\b)")
  nouns <- paste(c(.SF_GENO_NOUNS, .SF_LEVEL_NOUNS), collapse = "|")
  out <- list()
  # P2: "<X> at|with|across <N> levels|doses|concentrations|rates|temperatures"
  re2 <- paste0("([a-z][a-z-]*(?:\\s+[a-z][a-z-]*)?)\\s+(?:at|with|across|in)\\s+", .sf_num_re,
                "\\s+(?:levels?|doses?|concentrations?|rates?|temperatures?|intensities)\\b")
  p2_spans <- regmatches(text, gregexpr(re2, text, perl = TRUE))[[1]]
  for (m in p2_spans) {
    g <- regmatches(m, regexec(re2, m, perl = TRUE))[[1]]
    n <- .sf_num(g[3]); x <- sub("^(the|a|an|of|and|with|different)\\s+", "", g[2])
    if (is.na(n) || n < 2) next
    nm <- .sf_factor_name(x)
    if (is.na(nm) || grepl(.SF_NOT_LEVELS, nm)) next
    out[[length(out) + 1]] <- list(name = nm, n = n, phrase = m)
  }
  # P1: "<N> [m1 m2] <noun> [of|for <X>]"
  re1 <- paste0("(?<![\\w.])", .sf_num_re, "\\s+((?:", stop, "[a-z][a-z-]*\\s+){0,2}?)(", nouns, ")\\b",
                "(?:\\s+(?:of|for)\\s+(?:the\\s+|different\\s+)?([a-z][a-z-]*(?:\\s+[a-z][a-z-]*)?))?")
  for (m in regmatches(text, gregexpr(re1, text, perl = TRUE))[[1]]) {
    if (any(vapply(p2_spans, function(sp) grepl(m, sp, fixed = TRUE), logical(1)))) next
    g <- regmatches(m, regexec(re1, m, perl = TRUE))[[1]]
    n <- .sf_num(g[2]); mods <- trimws(g[3]); noun <- g[4]; of_x <- if (length(g) >= 5) g[5] else ""
    if (is.na(n) || n < 2 || n > 5000) next
    if (grepl(paste0("^(", paste(.SF_GENO_NOUNS, collapse = "|"), ")$"), noun)) {
      out[[length(out) + 1]] <- list(name = "genotype", n = n, phrase = m); next
    }
    phrase <- if (nzchar(of_x) && grepl("^(conditions?|levels?|groups?|types|kinds|variants?|treatments?)$", noun)) of_x else
      trimws(paste(mods, noun))
    if (grepl(.SF_NOT_LEVELS, phrase)) next
    nm <- .sf_factor_name(phrase)
    if (is.na(nm) || grepl(.SF_NOT_LEVELS, nm)) next
    out[[length(out) + 1]] <- list(name = nm, n = n, phrase = m)
  }
  out
}

.SF_ANALYSIS_RE <- paste0(
  "\\b(?:already (?:have|collected|ran|did)|i have (?:some |the |my )?(?:\\w+ )?data|we have (?:some |the )?(?:\\w+ )?data|",
  "data (?:is|are) (?:collected|in)|(?:what|which) (?:statistical )?(?:test|analysis|model)|how (?:do i|to|should i) ",
  "(?:analy[sz]e|find|test|compare)|find (?:the )?de genes|differentially expressed|p-?values?|significan(?:t|ce) test)")

.sf_goal <- function(text) if (grepl(.SF_ANALYSIS_RE, text, perl = TRUE)) "analysis" else "design"

# phenotype / outcome exactly as written (shown for confirmation; never counted as a stated canonical outcome)
.sf_outcome_text <- function(text) {
  re <- paste0("(?:measur\\w*|scor\\w*|phenotyp\\w*|quantif\\w*|record\\w*|look(?:ing)? at|effects? (?:on|of)|",
               "affects?|impact on|response of|traits? (?:like|such as)|primary outcome is|outcome is)\\s+",
               "(?:the |its |their |how )?([a-z][a-z -]{2,40}?)(?=[.,;?!]|\\s+(?:and|in|under|of|from|at|with|for|using)\\b|$)")
  m <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
  if (length(m) < 2) return(NULL)
  v <- trimws(m[2])
  if (!nzchar(v) || grepl("^(the|it|them|this|that|what|which|data|results?)$", v)) NULL else v
}

.sf_tissue_text <- function(text) {
  p <- tryCatch(.sf_practice_tables()$practice, error = function(e) NULL)
  vocab <- c("leaf", "root", "shoot", "stem", "seed", "flower", "fruit", "seedling", "panicle", "ear", "tassel",
             "anther", "pollen", "endosperm", "embryo", "kernel", "tuber", "berry", "bud", "liver", "brain", "blood",
             "muscle", "heart", "kidney", "lung", "skin", "intestine", "colon", "spleen", "adipose", "bone marrow")
  if (!is.null(p)) vocab <- unique(c(vocab, p$tissue[p$tissue != "all" & nchar(p$tissue) <= 20 & !grepl("[^a-z ]", p$tissue)]))
  words <- strsplit(gsub("[^a-z ]", " ", text), "\\s+")[[1]]
  words <- words[nzchar(words)]
  grams <- c(if (length(words) > 1) paste(utils::head(words, -1), utils::tail(words, -1)), words)
  norm <- vapply(grams, .sf_norm_tissue, "")
  hit <- norm[norm %in% vocab]
  if (length(hit)) unname(hit[1]) else NULL
}

# factor words specific enough to count as a stated factor even without a number
.SF_SPECIFIC_FACTORS <- c("temperature", "water", "salt", "nitrogen", "phosphorus", "nutrient", "diet", "co2", "light",
                          "injury", "antibiotic", "sex", "disease")

.SF_SYSTEM_BY_ASSAY <- c(rnaseq = "bulk_rnaseq", small_rnaseq = "bulk_rnaseq", atac_seq = "atac_seq",
                         ribo_seq = "ribo_seq", single_cell = "single_cell")

.sf_general_layer <- function(spec, text) {
  set <- function(path, value) if (!is.null(value) && !all(is.na(value))) spec <<- spec_set(spec, path, value)
  if (is.null(spec$organism)) {
    o <- .sf_find_all(text, "organism")
    if (length(o)) set("organism", o[1])
  }
  if (is.null(spec$assays)) {
    a <- .sf_find_all(text, "assay")
    if (!identical(spec$system, "functional_validation")) a <- setdiff(a, "heterologous")   # "benthamiana" is an organism
    if (length(a)) set("assays", a)
  }
  if (is.null(spec$system) && length(spec$assays)) {
    s <- unname(.SF_SYSTEM_BY_ASSAY[unlist(spec$assays)])
    s <- s[!is.na(s)]
    if (length(s)) set("system", s[1])
  }
  # factors: fill counts the hand rules missed or defaulted, add factors they never saw
  gen <- .sf_generic_factors(text)
  if (length(gen)) {
    fx <- spec$factors %||% list()
    canon_of <- function(nm) { c <- .sf_factor_name(nm); if (is.na(c)) nm else c }
    have <- vapply(fx, function(f) canon_of(f$name), "")
    for (g in gen) {
      i <- match(g$name, have)
      if (!is.na(i)) {
        cur <- fx[[i]]$n_levels
        if (is.null(cur) || (identical(as.numeric(cur), 2) && g$n != 2)) fx[[i]]$n_levels <- g$n
      } else {
        fx[[length(fx) + 1]] <- list(name = g$name, n_levels = g$n)
        have <- c(have, g$name)
      }
    }
    spec$factors <- fx
  }
  # specific factor words stated without a count ("cold", "drought", "placebo"): factor with unknown levels
  fx <- spec$factors %||% list()
  have <- vapply(fx, function(f) { c <- .sf_factor_name(f$name); if (is.na(c)) f$name else c }, "")
  spec_words <- intersect(.sf_find_all(text, "factor"), .SF_SPECIFIC_FACTORS)
  if (grepl("\\bplac[ei]bo\\b|\\bvehicle\\b|\\bsham\\b|\\bmock\\b", text, perl = TRUE)) spec_words <- union(spec_words, "treatment")
  for (w in setdiff(spec_words, have)) fx[[length(fx) + 1]] <- list(name = w)
  if (length(fx)) spec$factors <- fx
  if (is.null(spec$goal)) set("goal", .sf_goal(text))
  if (is.null(spec$primary_outcome$name)) set("outcome_text", .sf_outcome_text(text))
  if (is.null(spec$tissue)) set("tissue", .sf_tissue_text(text))
  if (is.null(spec$sequencing)) {
    sq <- .sf_sequencing(text)
    if (!is.null(sq)) spec$sequencing <- sq
  }
  spec
}

#' Correct what StudyForge understood and re-plan
#'
#' Every plan starts with the fields StudyForge extracted. Fix any of them here (dotted paths) and the plan is
#' rebuilt from the corrected spec; corrected values are treated as stated by the user.
#'
#' @param answer A `studyforge_answer` from studyforge_ask().
#' @param ... Fields to set, e.g. `organism = "Homo sapiens"`, `design.reps = 4`, `tissue = "root"`,
#'   `factors = "diet:5, sex:2"` (name:levels pairs) or a list of factor lists.
#' @return A new `studyforge_answer`.
#' @export
#' @examples
#' a <- studyforge_ask("i have some human rnaseq data in 5 condition of diets")
#' a2 <- studyforge_fix(a, design.reps = 4, tissue = "liver")
studyforge_fix <- function(answer, ...) {
  fix <- utils::modifyList(answer$fixes %||% list(), list(...))
  studyforge_ask(answer$question, provider = answer$provider, engine = answer$engine, fix = fix)
}

.sf_apply_fix <- function(spec, fix) {
  if (!length(fix)) return(spec)
  for (p in names(fix)) {
    v <- fix[[p]]
    if (p == "factors" && is.character(v)) {
      parts <- trimws(strsplit(paste(v, collapse = ","), ",")[[1]])
      v <- lapply(parts[nzchar(parts)], function(x) {
        kv <- trimws(strsplit(x, ":", fixed = TRUE)[[1]])
        f <- list(name = kv[1])
        if (length(kv) > 1 && !is.na(suppressWarnings(as.numeric(kv[2])))) f$n_levels <- as.numeric(kv[2])
        f
      })
    }
    if (p == "outcome") p <- "primary_outcome.name"
    spec <- spec_set(spec, p, v)
  }
  if (!is.null(spec$primary_outcome$name) && is.null(spec$primary_outcome$type)) {
    spec <- spec_set(spec, "primary_outcome.type", "continuous", assumption = TRUE)
  }
  spec
}

# the "here's what I understood" block at the top of every plan
.sf_skeleton_lines <- function(s, fixes = list()) {
  q <- function(x) if (is.null(x) || !length(x)) "?" else paste(unlist(x), collapse = ", ")
  fx <- if (length(s$factors)) paste(vapply(s$factors, function(f)
    paste0(f$name, if (!is.null(f$n_levels)) paste0(" (", f$n_levels, ")") else " (? levels)"), ""), collapse = "; ") else "?"
  outcome <- if (!is.null(s$primary_outcome$name)) s$primary_outcome$name else
    if (!is.null(s$outcome_text)) paste0("\"", s$outcome_text, "\" (as written; confirm)") else "?"
  hint <- function(what) { h <- tryCatch(.sf_practice_hint(s, what), error = function(e) NULL); if (is.null(h)) "?" else paste0("? (", h, ")") }
  tissue <- if (!is.null(s$tissue)) s$tissue else hint("tissue")
  omics <- length(s$assays) || isTRUE(s$system %in% c("bulk_rnaseq", "single_cell", "ribo_seq", "atac_seq", "multi_omics"))
  sq <- s$sequencing
  seqtxt <- if (!is.null(sq)) paste(c(sq$instrument, if (!is.null(sq$read_length)) paste0(sq$layout %||% "", if (!is.null(sq$layout)) " ", sq$read_length, " bp"),
                                      if (!is.null(sq$depth_m)) paste0(sq$depth_m, " M reads")), collapse = ", ") else hint("sequencing")
  rows <- c(
    Goal = if (identical(s$goal, "analysis")) "analyse data already collected" else "design a new study",
    Organism = q(s$organism), Setting = q(s$system), `Assay / data` = q(s$assays), Tissue = tissue,
    `Factors (levels)` = fx, `Outcome / phenotype` = outcome, `Experimental unit` = q(s$experimental_unit),
    `Replicates` = q(s$design$reps), `Locations / seasons` = paste(q(s$design$locations), "/", q(s$design$seasons)))
  if (omics) rows <- append(rows, c(Sequencing = seqtxt), after = 5)
  c(sprintf("  %-20s %s%s", paste0(names(rows), ":"), rows,
            ifelse(names(rows) %in% c("Organism", "Replicates", "Tissue") & names(rows) %in% names(fixes), "  (corrected)", "")))
}
