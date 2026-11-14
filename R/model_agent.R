#' Combine the rule-based spec with a model-predicted spec
#'
#' The model (LLM reader or tagger) states the facts and the rules check them: a
#' model value is kept when the question supports it (a number that appears in the
#' text, a unit, setting or assay that is named); otherwise the rule's value stands,
#' and the rules fill whatever the model left empty. Factors are matched by
#' canonical name; the model's level counts are used only when stated.
#'
#' @param rule Spec from extract_spec_local().
#' @param model Spec from the trained tagger.
#' @param question The original text.
#' @export
merge_specs <- function(rule, model, question, judgments = FALSE) {
  if (is.null(model)) return(rule)
  # which of several stated outcomes is primary is a judgment: it stays with the user
  if (!judgments) {
    listed <- strsplit(tolower(model$outcome_text %||% ""), ",|;| and | plus ")[[1]]
    if (length(unique(.sf_find_all(tolower(question), "outcome"))) > 1 || sum(nzchar(trimws(listed))) > 1)
      model$primary_outcome <- NULL
  }
  if (is.character(model$organism) && !grepl("^[A-Z][a-z]+ [a-z]+", model$organism)) model$organism <- NULL
  # the reader's setting must fit the organism: plant settings (field, greenhouse, chamber) are not for animals,
  # the animal-facility setting ("mouse": cages, litters) is not for plants or people, vials are for flies
  org <- rule$organism %||% (if (is.character(model$organism)) model$organism)
  if (!is.null(model$system) && !is.null(org) && is.null(rule$system)) {
    grp <- .sf_group_of(org)
    bad <- (model$system %in% c("field", "greenhouse", "growth_chamber") && identical(grp, "animal")) ||
      (model$system == "mouse" && (identical(grp, "plant") || org == "Homo sapiens")) ||
      (model$system == "drosophila" && org != "Drosophila melanogaster")
    if (isTRUE(bad)) model$system <- NULL
  }
  text <- tolower(gsub(",", "", question))
  stated <- function(v) {
    if (!is.numeric(v)) return(TRUE)
    words <- names(.sf_number_words)[.sf_number_words == v]
    grepl(paste0("(?<![\\d.])", v, "(?![\\d])"), text, perl = TRUE) ||
      any(vapply(words, function(w) grepl(paste0("\\b", w, "\\b"), text, perl = TRUE), logical(1))) ||
      (v == 1 && grepl("\\b(one|single|this|no) ", text))
  }
  # "F6" states a filial generation, and NAM parents = founders + 1
  if (!is.null(model$population$filial_generation)) {
    fg <- model$population$filial_generation
    if (!grepl(paste0("\\bf", fg, "\\b"), text, perl = TRUE)) model$population$filial_generation <- NULL
  }
  if (identical(model$population$mating, "nam") && !is.null(model$population$parents)) {
    if (!stated(model$population$parents - 1)) model$population$parents <- NULL
  } else if (!is.null(model$population$parents)) {
    pn <- model$population$parents
    parts_ok <- stated(pn) || {
      nums <- as.numeric(regmatches(text, gregexpr("\\d+", text))[[1]])
      any(outer(nums, nums, "+") == pn)
    }
    if (!parts_ok && pn != 2) model$population$parents <- NULL
  }
  # a replicate count stated as a range ("two or three reps") is not a fact yet
  rep_range <- function(v) {
    w <- paste(c(as.character(v), names(.sf_number_words)[.sf_number_words == v]), collapse = "|")
    grepl(paste0("\\b(", w, ")\\s*(or|to|-)\\s*\\w+\\s+(reps?|replicat\\w*)|\\b\\w+\\s*(or|to|-)\\s*(", w, ")\\s+(reps?|replicat\\w*)"),
          text, perl = TRUE)
  }
  # guard 2: outcomes must be known canonical terms named in the question ("track growth" is not biomass)
  known_outcomes <- unique(.sf_alias_table()$canonical_term[.sf_alias_table()$category == "outcome"])
  if (!is.null(model$primary_outcome$name) && !model$primary_outcome$name %in% known_outcomes) model$primary_outcome <- NULL
  if (!is.null(model$primary_outcome$name) && !judgments &&
      !model$primary_outcome$name %in% .sf_find_all(text, "outcome")) model$primary_outcome <- NULL

  # Each field goes to whichever source the question supports better. The reader is better at stating what the
  # text says; the rules are better where they encode a specific convention (study types, "use the panicles as
  # replicates" = 1 rep, lifespan = survival, Dahomey = fly), so:
  #   system      tiers: study type > setting named outright > assay family > weaker cue (pots, plots); the
  #               reader's system replaces the rules' only from a higher tier, and fills when the rules found none
  #   assays      the reader's list when every assay in it is named in the text (plus any other measurement the
  #               rules found, e.g. eQTL), else the rules', else the reader's
  #   reps, unit  rules first; the reader fills when the text supports it (the number is stated and not a range;
  #               the experimental unit is counted as the replicate: "4 replicate cages per diet", "60 cages of
  #               15 hens", "one seedling per pot")
  #   the rest    rules first, the reader fills what is stated
  word_in <- function(w) {
    w <- trimws(gsub("_", " ", tolower(w)))
    nzchar(w) && grepl(paste0("\\b", .sf_re_escape(sub("(?<![su])s$", "", w, perl = TRUE))), text, perl = TRUE)
  }
  assays_said <- .sf_find_all(text, "assay")
  tier <- function(s) {
    if (is.null(s) || !nzchar(s)) return(0)
    hit <- function(p) !is.null(p) && grepl(p, text, perl = TRUE)
    if (s %in% .SF_STUDY_SYSTEMS) return(if (hit(.sf_systems[[s]])) 4 else 0)
    if (hit(.sf_settings_stated[[s]])) return(3)
    if (s %in% .sf_system_set(list(assays = assays_said))) return(2)
    if (hit(.sf_systems[[s]])) return(1)
    0
  }
  # a number is a count of something else when every mention of it is followed by a non-replicate noun
  # ("two sites", "3 time points", "120 lines")
  other_count <- function(v) {
    w <- paste(c(as.character(v), names(.sf_number_words)[.sf_number_words == v]), collapse = "|")
    nouns <- paste(c(.SF_LEVEL_NOUNS, .SF_GENO_NOUNS, "sites?", "locations?", "environments?", "years?", "seasons?",
                     "generations?", "weeks?", "days?", "hours?", "h", "months?", "regions?", "farms?", "populations?",
                     "parents?", "founders?"), collapse = "|")
    all_m <- gregexpr(paste0("(?<![\\d.])\\b(?:", w, ")\\b(?![\\d.])"), text, perl = TRUE)[[1]]
    other <- gregexpr(paste0("(?<![\\d.])\\b(?:", w, ")\\s+(?:(?!(?:per|in|each|for|of|a|an|the)\\b)[a-z-]+\\s+)?(?:", nouns, ")\\b"), text, perl = TRUE)[[1]]
    all_m[1] > 0 && other[1] > 0 && length(other) >= length(all_m)
  }
  rep_said <- function(v) stated(v) && !rep_range(v) && !other_count(v) &&
    (v != 1 || grepl("\\bonly (?:one|1)\\b|\\b(?:one|single|1) (?:plot|sample|replicate|rep|pool|library)\\b|\\bno (?:replicat|biological rep)|unreplicated|\\bn ?= ?1\\b", text, perl = TRUE))
  unit_counted <- function(u) {
    w <- .sf_re_escape(sub("(?<![su])s$", "", gsub("_", " ", tolower(u)), perl = TRUE))
    n <- paste0("(?:\\d+|", paste(names(.sf_number_words), collapse = "|"), ")")
    grepl(paste0("\\b", n, " (?:replicate |independent |separate |\\w+ ){0,2}", w, "(?:e?s)? (?:per|for each|in each|each)\\b|",
                 "\\b", w, "(?:e?s)? of ", n, "\\b|\\b(?:one|1|a single|each) \\w+ (?:per|in its own|in their own) ", w, "\\b|",
                 "\\b", n, " replicate ", w), text, perl = TRUE)
  }
  out <- rule
  if (!is.null(model$system) && (is.null(rule$system) || tier(model$system) > tier(rule$system))) out$system <- model$system
  ma <- unlist(model$assays)
  if (length(ma) && (all(ma %in% assays_said) || is.null(rule$assays)))
    out$assays <- as.list(unique(c(ma, setdiff(unlist(rule$assays), c(ma, .sf_generic_of(ma), .SF_METHOD_ASSAYS)))))
  if (is.null(out$design$reps) && !is.null(model$design$reps) && rep_said(model$design$reps)) out <- spec_set(out, "design.reps", model$design$reps)
  if (is.null(out$experimental_unit) && !is.null(model$experimental_unit) && unit_counted(model$experimental_unit))
    out$experimental_unit <- model$experimental_unit
  for (p in c("organism", "measurement_unit", "subsamples_per_unit", "design.locations", "design.seasons",
              "population.mating", "population.type", "population.parents", "population.generations",
              "population.filial_generation", "primary_outcome.name", "primary_outcome.type",
              "blocking_factors", "organisms", "environments", "method", "tissue", "outcome_text")) {
    if (is.null(spec_get(out, p))) {
      v <- spec_get(model, p)
      prechecked <- p %in% c("population.parents", "population.filial_generation")
      if (!is.null(v) && (prechecked || all(vapply(as.list(unlist(v)), stated, logical(1))))) out <- spec_set(out, p, v)
    }
  }

  # factors: one list keyed by canonical name; reader counts and levels when stated, rule counts otherwise.
  # A unit is not a factor ("pup", "mouse", "biological replicate").
  canon <- function(nm) {
    nm <- tolower(nm %||% "")
    if (nm %in% names(.sf_factor_synonyms)) return(.sf_factor_synonyms[[nm]])
    c <- .sf_factor_name(gsub("_", " ", nm))
    if (is.na(c)) nm else gsub(" ", "_", c)
  }
  units <- c(unlist(lapply(load_registry("experimental_units")$units, `[[`, "id")),
             "pup", "mouse", "rat", "fly", "plant", "cell", "replicate", "biological_replicate", "sample", "individual")
  named <- function(f) {
    lv <- unlist(f$levels)
    length(lv) >= 2 && all(vapply(tolower(lv), function(l) agrepl(l, text, max.distance = 0.2, fixed = TRUE), logical(1)))
  }
  # a count is stated if the number is in the text, or the reader lists that many levels and most are in the text
  # ("sham, BDL, BDL + salidroside low, medium or high" states 5)
  mostly_named <- function(f) {
    lv <- tolower(unlist(f$levels))
    length(lv) >= 2 && mean(vapply(lv, function(l) agrepl(l, text, max.distance = 0.2, fixed = TRUE), logical(1))) > 0.5
  }
  count_ok <- function(f) !is.null(f$n_levels) && (stated(f$n_levels) || (mostly_named(f) && length(unlist(f$levels)) == f$n_levels))
  # a factor is stated when it is named (directly or by an alias: "RILs" for genotype, "at 2 h" for time),
  # counted, or its levels are
  canon_said <- unique(c(vapply(.sf_find_all(text, "factor"), canon, ""),
                         if (length(.sf_find_all(text, "genotype_noun"))) "genotype",
                         if (grepl("\\b\\d+ ?(?:h|hr|hrs|hours?|min|days?|d|dpi|hpi|dai|weeks?|wk|months?)\\b|time ?points?|time course|diurnal|sampled at|harvested at",
                                   text, perl = TRUE)) "time"))
  said <- function(f) word_in(f$name) || canon(f$name) %in% canon_said || named(f) || count_ok(f) ||
    any(vapply(unlist(f$levels), function(l) agrepl(tolower(l), text, max.distance = 0.2, fixed = TRUE), logical(1)))
  rf <- rule$factors %||% list()
  rkey <- vapply(rf, function(f) canon(f$name), "")
  fx <- list(); used <- logical(length(rf))
  for (f in model$factors %||% list()) {
    k <- canon(f$name)
    if (k %in% units || k %in% vapply(fx, function(g) canon(g$name), "") || !said(f)) next
    i <- match(k, rkey)
    g <- list(name = f$name)
    if (!is.na(i)) { g <- rf[[i]]; used[i] <- TRUE }
    if (count_ok(f)) g$n_levels <- f$n_levels
    if (named(f)) g$levels <- f$levels
    if (is.null(g$applied_to) && !is.null(f$applied_to)) g$applied_to <- f$applied_to
    fx[[length(fx) + 1]] <- g
  }
  for (i in which(!used)) if (!rkey[i] %in% vapply(fx, function(g) canon(g$name), "")) fx[[length(fx) + 1]] <- rf[[i]]
  out$factors <- if (length(fx)) fx
  out
}

.sf_alias_cache <- new.env()
.sf_alias_table <- function() {
  if (is.null(.sf_alias_cache$t)) {
    f <- system.file("agent", "aliases.tsv", package = "studyforge")
    t <- utils::read.delim(f, quote = "", stringsAsFactors = FALSE)
    .sf_alias_cache$t <- rbind(t, .sf_vocab_aliases(t))
  }
  .sf_alias_cache$t
}

# Organism names built from sources (data-raw/vocab/build_vocab.py: NCBI Taxonomy + strains, cultivars and
# cell lines recorded in our harvested studies), added as organism aliases. Curated rows win. For prompts,
# a strain name must not be able to pass as an everyday word: a single plain word ("atlantic", "jack",
# "lewis") is left out; names with a digit, hyphen, slash or space (B73, Col-0, C57BL/6J, Sprague-Dawley,
# Heinz 1706) are used when seen in >= 3 studies.
.sf_vocab_aliases <- function(t) {
  f <- system.file("vocab", "organism_names.tsv", package = "studyforge")
  if (!nzchar(f)) return(t[0, ])
  v <- utils::read.delim(f, quote = "", stringsAsFactors = FALSE, colClasses = "character")
  # names the corpus check (retrieval/label_organisms.py) found non-specific: "santa clara", "p53", "a/j"
  d <- system.file("vocab", "organism_names_dropped.tsv", package = "studyforge")
  if (nzchar(d)) {
    bad <- utils::read.delim(d, quote = "", stringsAsFactors = FALSE, colClasses = "character")$name
    tok <- vapply(regmatches(tolower(v$name), gregexpr("[a-z0-9]+", tolower(v$name))), paste, "", collapse = " ")
    v <- v[!tok %in% bad, ]
  }
  n <- suppressWarnings(as.integer(v$n_studies))
  keep <- v$source != "aliases.tsv" &
    (v$source != "biosample" | (!grepl("^[a-z]+$", v$name) & !is.na(n) & n >= 3)) &
    !tolower(v$name) %in% tolower(t$alias[t$category == "organism"])
  v <- v[keep, ]
  if (!nrow(v)) return(t[0, ])
  out <- t[rep(1, nrow(v)), ]
  out[] <- NA
  out$alias <- v$name
  out$canonical_term <- v$organism
  out$category <- "organism"
  if ("source" %in% names(out)) out$source <- paste0("vocab:", v$source)
  if ("confidence" %in% names(out)) out$confidence <- ifelse(v$source == "biosample", "medium", "high")
  rownames(out) <- NULL
  out
}

#' Look up the canonical term for an alias (SimItAll-style alias table)
#' @param x Text to normalise.
#' @param category Optional category (organism, genotype_noun, system, factor, unit, outcome, blocking, application, design).
#' @export
studyforge_alias <- function(x, category = NULL) {
  t <- .sf_alias_table()
  if (!is.null(category)) t <- t[t$category %in% category, ]
  hit <- t$canonical_term[tolower(t$alias) == tolower(trimws(x))]
  if (length(hit)) hit[1] else NA_character_
}

#' Tag a prompt with the trained StudyForge model (optional)
#'
#' Calls training/predict.py with a Python environment that has torch and
#' transformers. Returns NULL (with a message) when Python or the model is not
#' available, so callers can fall back to the rules.
#'
#' @param question Text.
#' @param model_dir Trained model directory (from training/train.py); defaults to the bundled tiny model.
#' @param python Python executable.
#' @export
extract_spec_model <- function(question, model_dir = Sys.getenv("STUDYFORGE_MODEL", system.file("models", "sf-tiny", package = "studyforge")),
                               python = Sys.getenv("STUDYFORGE_PYTHON", "python3")) {
  script <- system.file("python", "predict.py", package = "studyforge")
  if (!nzchar(script)) script <- file.path("inst", "python", "predict.py")
  if (!nzchar(model_dir) || !dir.exists(model_dir) || !file.exists(script)) {
    message("StudyForge model not available; using rules only.")
    return(NULL)
  }
  out <- tryCatch(suppressWarnings(system2(python, c(shQuote(script), "--model", shQuote(model_dir), "--text", shQuote(question)),
                                           stdout = TRUE, stderr = FALSE)), error = function(e) character())
  js <- out[startsWith(trimws(out), "{")]
  if (!length(js)) {
    message("StudyForge model call failed; using rules only.")
    return(NULL)
  }
  jsonlite::fromJSON(paste(out[which(startsWith(trimws(out), "{"))[1]:length(out)], collapse = "\n"), simplifyVector = FALSE)
}

#' Hybrid extractor: rules first, trained model fills gaps
#' @inheritParams extract_spec_model
#' @export
extract_spec_hybrid <- function(question, model_dir = Sys.getenv("STUDYFORGE_MODEL", system.file("models", "sf-tiny", package = "studyforge")),
                                python = Sys.getenv("STUDYFORGE_PYTHON", "python3")) {
  merge_specs(extract_spec_local(question), extract_spec_model(question, model_dir, python), question)
}

.sf_re_escape <- function(x) gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x)

# generic assay labels a specific one stands in for (an MeDIP study is not also "methylation" unless both are said)
.sf_generic_of <- function(a) unique(unlist(list(medip = "methylation", scatac_seq = c("single_cell", "atac_seq"),
  long_read_rna = "rnaseq", trap_seq = "rnaseq", nascent_rna = "rnaseq", m6a_seq = "rnaseq")[intersect(a, c("medip", "scatac_seq",
  "long_read_rna", "trap_seq", "nascent_rna", "m6a_seq"))]))

# how genotypes were made or analysed, not what is measured: never added to a list on the rules' word alone
.SF_METHOD_ASSAYS <- c("overexpression", "crispr", "heterologous", "complementation", "in_silico", "qtl_mapping")
