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
  # system is the setting only: a study type the reader gives as its system is the study_type, an assay family is
  # already in assays (readers trained before this convention still answer that way)
  if (is.character(model$system) && model$system %in% .sf_systems_where(kind = "study")) {
    if (is.null(model$study_type)) model$study_type <- model$system
    model$system <- NULL
  }
  if (is.character(model$system) && model$system %in% .sf_systems_where(kind = "assay")) model$system <- NULL
  # the reader's setting must fit the organism: plant settings (field, greenhouse, chamber) are not for animals,
  # the animal-facility setting ("mouse": cages, litters) is not for plants or people, vials are for flies
  org <- rule$organism %||% (if (is.character(model$organism)) model$organism)
  if (!is.null(model$system) && !is.null(org) && is.null(rule$system)) {
    grp <- .sf_group_of(org)
    bad <- (model$system %in% .sf_systems_where(plant_site = TRUE) && identical(grp, "animal")) ||
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
  off <- .sf_mating_props(model$population$mating %||% "")$parents_offset
  if (!is.null(off) && !is.null(model$population$parents)) {
    if (!stated(model$population$parents - as.numeric(off))) model$population$parents <- NULL
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
  #   system      tiers: validation / multi-environment > a field, greenhouse or chamber named outright >
  #               breeding / multi-omics > other named settings > assay family > weaker cue (pots, plots); the
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
    if (s %in% .sf_systems_where(keeps_type_over_setting = TRUE)) return(if (.sf_rule_hit("system", s, text)) 5 else 0)
    stated <- .sf_rule_hit("setting", s, text)
    if (stated && s %in% .sf_systems_where(plant_site = TRUE)) return(4)   # outranks breeding / multi-omics
    if (s %in% .sf_systems_where(kind = "study")) return(if (.sf_rule_hit("system", s, text)) 3.5 else 0)
    if (stated) return(3)
    if (s %in% .sf_system_set(list(assays = assays_said))) return(2)
    if (.sf_rule_hit("system", s, text)) return(1)
    0
  }
  # a number is a count of something else when every mention of it is followed by a non-replicate noun
  # ("two sites", "3 time points", "120 lines")
  other_count <- function(v) {
    w <- paste(c(as.character(v), names(.sf_number_words)[.sf_number_words == v]), collapse = "|")
    nouns <- paste(c(.sf_list("level_noun"), .sf_list("genotype_noun_general"), .sf_list("location_noun"), .sf_list("season_noun"),
                     .sf_list("not_rep_noun")), collapse = "|")
    all_m <- gregexpr(paste0("(?<![\\d.])\\b(?:", w, ")\\b(?![\\d.])"), text, perl = TRUE)[[1]]
    other <- gregexpr(paste0("(?<![\\d.])\\b(?:", w, ")\\s+(?:(?!(?:per|in|each|for|of|a|an|the)\\b)[a-z-]+\\s+)?(?:", nouns, ")\\b"), text, perl = TRUE)[[1]]
    all_m[1] > 0 && other[1] > 0 && length(other) >= length(all_m)
  }
  # a total split into groups ("8 pigs (4 male, 4 female)") is not the replicates per group
  breakdown <- function(v) {
    w <- paste(c(as.character(v), names(.sf_number_words)[.sf_number_words == v]), collapse = "|")
    grepl(paste0("(?<![\\d.])\\b(?:", w, ")", .sf_cue("count_breakdown")), tolower(question), perl = TRUE)
  }
  rep_said <- function(v) stated(v) && !rep_range(v) && !other_count(v) && !breakdown(v) && !.sf_reps_open(question) &&
    (v != 1 || grepl(.sf_cue("one_replicate_stated"), text, perl = TRUE))
  unit_counted <- function(u) .sf_unit_counted(u, text)
  out <- rule
  if (!is.null(model$system) && (is.null(rule$system) || tier(model$system) > tier(rule$system))) out$system <- model$system
  # the study type only when the text says it (the rules' study cues)
  if (is.null(out$study_type) && is.character(model$study_type) && .sf_rule_hit("system", model$study_type, text))
    out$study_type <- model$study_type
  ma <- unlist(model$assays)
  if (length(ma) && (all(ma %in% assays_said) || is.null(rule$assays)))
    out$assays <- as.list(unique(c(ma, setdiff(unlist(rule$assays), c(ma, .sf_generic_of(ma), .sf_list("method_assay"))))))
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
    if (nm %in% names(.sf_map("factor_synonym"))) return(.sf_map("factor_synonym")[[nm]])
    c <- .sf_factor_name(gsub("_", " ", nm))
    if (is.na(c)) nm else gsub(" ", "_", c)
  }
  units <- c(unlist(lapply(load_registry("experimental_units")$units, `[[`, "id")),
             .sf_list("unit_word_extra"))
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
  # the reader words a level its own way ("TEV-only control" for "a TEV-only control"): a level is in the text
  # when its content words are; and a count is stated when a clause enumerates exactly that many items
  enum_n <- .sf_enum_lengths(tolower(question))
  nums_alone <- as.numeric(regmatches(text, gregexpr("(?<![\\w.])\\d+(?![\\w.])", text, perl = TRUE))[[1]])
  stated_alone <- function(v) v %in% nums_alone ||
    any(vapply(names(.sf_number_words)[.sf_number_words == v], function(w) grepl(paste0("\\b", w, "\\b"), text, perl = TRUE), logical(1)))
  # "two parents and 146 lines" states 148 genotypes: a count may be the sum of two numbers written in the text
  nums_all <- c(nums_alone, unname(.sf_number_words[vapply(names(.sf_number_words), function(w) grepl(paste0("\\b", w, "\\b"), text, perl = TRUE), logical(1))]))
  sum_said <- function(v) length(nums_all) > 1 && any(outer(nums_all, nums_all, "+")[upper.tri(diag(length(nums_all)))] == v)
  count_ok <- function(f) !is.null(f$n_levels) &&
    (stated(f$n_levels) || f$n_levels %in% enum_n || sum_said(f$n_levels) ||
       (f$n_levels == 2 && tolower(f$name) %in% .sf_list("group_factor") && grepl(.sf_cue("two_group_contrast"), text, perl = TRUE)) ||
       ((mostly_named(f) || .sf_levels_in_text(f$levels, text)) && length(unlist(f$levels)) == f$n_levels))
  # a factor is stated when it is named (directly or by an alias: "RILs" for genotype, "at 2 h" for time),
  # counted, or its levels are
  canon_said <- unique(c(vapply(.sf_find_all(text, "factor"), canon, ""),
                         if (length(.sf_find_all(text, "genotype_noun"))) "genotype",
                         if (grepl(.sf_cue("time_stated"),
                                   text, perl = TRUE)) "time"))
  # a group factor is stated when the text says what formed the groups (the group_by_* cues)
  grouped <- grepl(.sf_cue("group_by_trait"), text, perl = TRUE) || grepl(.sf_cue("group_by_health"), text, perl = TRUE)
  said <- function(f) word_in(f$name) || canon(f$name) %in% canon_said || named(f) || count_ok(f) ||
    (grouped && tolower(f$name) %in% .sf_list("group_factor")) ||
    any(vapply(unlist(f$levels), function(l) agrepl(tolower(l), text, max.distance = 0.2, fixed = TRUE), logical(1)))
  rf <- rule$factors %||% list()
  rkey <- vapply(rf, function(f) canon(f$name), "")
  fx <- list(); used <- logical(length(rf))
  for (f in model$factors %||% list()) {
    f$name <- .sf_group_factor(f$name, text)
    k <- canon(f$name)
    if (k %in% units || k %in% vapply(fx, function(g) canon(g$name), "") || !said(f)) next
    i <- match(k, rkey)
    g <- list(name = f$name)
    if (!is.na(i)) { g <- rf[[i]]; used[i] <- TRUE }
    if (count_ok(f)) g$n_levels <- f$n_levels
    # the reader names the factor but leaves its count open: a rule count stands only if the number is written on
    # its own ("Mo17" or "rhp1" do not state 17 or 1 genotypes)
    else if (is.null(f$n_levels) && !is.null(g$n_levels) && !stated_alone(g$n_levels)) g$n_levels <- NULL
    if (named(f) || .sf_levels_in_text(f$levels, text)) g$levels <- f$levels
    if (is.null(g$applied_to) && !is.null(f$applied_to)) g$applied_to <- f$applied_to
    fx[[length(fx) + 1]] <- g
  }
  for (i in which(!used)) if (!rkey[i] %in% vapply(fx, function(g) canon(g$name), "")) fx[[length(fx) + 1]] <- rf[[i]]
  out$factors <- if (length(fx)) fx
  .sf_clear_asked(out, question)   # what the user asks about stays open, whoever filled it (questions.tsv)
}

# Lengths of the enumerations in a text: per clause, the items between list separators ("A, B or C" = 3,
# "X vs Y" = 2), plus every list of numbers ("at 3, 6, 18 and 72 h" = 4). Separators and clause breaks are cues
# in rules.tsv.
.sf_enum_lengths <- function(text) {
  nums <- regmatches(text, gregexpr(.sf_cue("number_list"), text, perl = TRUE))[[1]]
  n_num <- vapply(nums, function(s) length(regmatches(s, gregexpr("\\d+(?:\\.\\d+)?", s, perl = TRUE))[[1]]), 1L)
  clauses <- strsplit(text, .sf_cue("clause_break"), perl = TRUE)[[1]]
  n_cl <- vapply(clauses, function(cl) {
    items <- trimws(strsplit(cl, .sf_cue("list_separator"), perl = TRUE)[[1]])
    sum(nzchar(items))
  }, 1L)
  unique(c(n_num, n_cl[n_cl >= 2]))
}

# Every level is in the text when at least two thirds of its content words are (stopwords in rules.tsv;
# a trailing plural s is ignored).
.sf_levels_in_text <- function(levels, text) {
  lv <- tolower(unlist(levels))
  if (length(lv) < 2) return(FALSE)
  words <- unique(sub("(?<![su])s$", "", strsplit(text, "[^a-z0-9]+", perl = TRUE)[[1]], perl = TRUE))
  stop <- .sf_list("level_stopword")
  all(vapply(lv, function(l) {
    w <- setdiff(sub("(?<![su])s$", "", strsplit(l, "[^a-z0-9]+", perl = TRUE)[[1]], perl = TRUE), c(stop, ""))
    length(w) > 0 && mean(w %in% words) >= 2 / 3
  }, logical(1)))
}

# the prompt counts the unit as the replicate (cue unit_counted in rules.tsv; llm/make_sft.py reads the same row)
# A factor of subject groups is named by what formed the groups (rules.tsv cues): a ranked or scored trait
# ("high vs low backfat", "resistant vs susceptible") is phenotype_group; a health state ("patients vs healthy
# controls") is disease. Other factor names pass through.
.sf_group_factor <- function(name, text) {
  nm <- tolower(name %||% "")
  if (!nm %in% .sf_list("group_factor")) return(name)
  if (grepl(.sf_cue("group_by_trait"), text, perl = TRUE)) return("phenotype_group")
  if (grepl(.sf_cue("group_by_health"), text, perl = TRUE)) return("disease")
  if (nm %in% c("disease", "phenotype_group")) name else "phenotype_group"
}

.sf_unit_counted <- function(u, text) {
  w <- .sf_re_escape(sub("(?<![su])s$", "", gsub("_", " ", tolower(u)), perl = TRUE))
  re <- gsub("{U}", w, .sf_cue("unit_counted"), fixed = TRUE)
  re <- gsub("{LEAD}", .sf_cue("unit_compound_lead"), gsub("{N}", .sf_cue("count_word"), re, fixed = TRUE), fixed = TRUE)
  grepl(re, text, perl = TRUE)
}
.sf_alias_cache <- new.env()
.sf_alias_table <- function() {
  if (is.null(.sf_alias_cache$t)) {
    r <- .sf_rules_table()
    r <- r[r$match == "word", ]   # word rows of rules.tsv are the aliases
    t <- data.frame(alias = r$pattern, canonical_term = r$term, category = r$category, source = r$source,
                    confidence = ifelse(grepl("confidence: medium", r$note, fixed = TRUE), "medium", "high"),
                    stringsAsFactors = FALSE)
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
  keep <- !v$source %in% c("rules.tsv", "aliases.tsv") &   # curated rows are already in the table
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
.sf_generic_of <- function(a) {
  g <- .sf_groups("generic_assay")
  unique(unlist(g[intersect(a, names(g))]))
}

# how genotypes were made or analysed, not what is measured: never added to a list on the rules' word alone

