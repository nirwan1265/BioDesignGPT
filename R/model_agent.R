#' Combine the rule-based spec with a model-predicted spec
#'
#' Rules go first (they are precise); the model only fills fields the rules left
#' empty and adds factors the rules missed. A number from the model is accepted
#' only if it literally appears in the question (digits or a number word), so
#' the model cannot introduce values the user never stated.
#'
#' @param rule Spec from extract_spec_local().
#' @param model Spec from the trained tagger.
#' @param question The original text.
#' @export
merge_specs <- function(rule, model, question, judgments = FALSE) {
  if (is.null(model)) return(rule)
  # the reader states facts; design judgments stay with the engine or become questions for the user:
  # which unit is the experimental unit, and which of several stated outcomes is primary
  if (!judgments) {
    model$experimental_unit <- NULL
    listed <- strsplit(tolower(model$outcome_text %||% ""), ",|;| and | plus ")[[1]]
    if (length(unique(.sf_find_all(tolower(question), "outcome"))) > 1 || sum(nzchar(trimws(listed))) > 1)
      model$primary_outcome <- NULL
  }
  if (is.character(model$organism) && !grepl("^[A-Z][a-z]+ [a-z]+", model$organism)) model$organism <- NULL
  text <- tolower(gsub(",", "", question))
  stated <- function(v) {
    if (!is.numeric(v)) return(TRUE)
    words <- names(.sf_number_words)[.sf_number_words == v]
    grepl(paste0("(?<![\\d.])", v, "(?![\\d])"), text, perl = TRUE) ||
      any(vapply(words, function(w) grepl(paste0("\\b", w, "\\b"), text, perl = TRUE), logical(1))) ||
      (v == 1 && grepl("\\b(one|single|this|no) ", text))
  }
  # guard 1: a rep count must sit next to a replication word ("two sites" is not 2 reps)
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
  rep_ok <- function(v) {
    w <- c(as.character(v), names(.sf_number_words)[.sf_number_words == v], if (v == 1) c("no", "one", "single"))
    re <- paste0("\\b(", paste(w, collapse = "|"), ")\\s+(?:\\w+\\s+){0,2}?(reps?|replicat\\w*|replications?|blocks?|benches|vials|dams|plants per combination)|",
                 "\\b(", paste(w, collapse = "|"), ")\\s+(plot|row) (each|per)")
    rng <- paste0("\\b(", paste(w, collapse = "|"), ")\\s*(or|to|-)\\s*\\w+\\s+(reps?|replicat\\w*)|",
                  "\\b\\w+\\s*(or|to|-)\\s*(", paste(w, collapse = "|"), ")\\s+(reps?|replicat\\w*)")
    grepl(re, text, perl = TRUE) && !grepl(rng, text, perl = TRUE)   # "two or three reps" is a range, not 2
  }
  # guard 2: outcomes must be known canonical terms
  known_outcomes <- unique(.sf_alias_table()$canonical_term[.sf_alias_table()$category == "outcome"])
  if (!is.null(model$design$reps) && !rep_ok(model$design$reps)) model$design$reps <- NULL
  if (!is.null(model$primary_outcome$name) && !model$primary_outcome$name %in% known_outcomes) model$primary_outcome <- NULL
  out <- rule
  for (p in c("system", "organism", "experimental_unit", "measurement_unit", "subsamples_per_unit",
              "primary_outcome.name", "primary_outcome.type", "design.reps", "design.locations",
              "design.seasons", "blocking_factors", "population.mating", "population.type",
              "population.parents", "population.generations", "population.filial_generation",
              "assays", "organisms", "environments", "method", "tissue", "outcome_text")) {
    if (is.null(spec_get(out, p))) {
      v <- spec_get(model, p)
      prechecked <- p %in% c("population.parents", "population.filial_generation")
      if (!is.null(v) && (prechecked || all(vapply(as.list(unlist(v)), stated, logical(1))))) out <- spec_set(out, p, v)
    }
  }
  have <- vapply(out$factors %||% list(), `[[`, "", "name")
  # a level count is stated if the number is in the text, or every named level is (typos allowed:
  # "medicine ... placibo" states 2 levels)
  named <- function(f) {
    lv <- unlist(f$levels)
    length(lv) >= 2 && all(vapply(tolower(lv), function(l) agrepl(l, text, max.distance = 0.2, fixed = TRUE), logical(1)))
  }
  count_ok <- function(f) !is.null(f$n_levels) && (stated(f$n_levels) || (named(f) && length(unlist(f$levels)) == f$n_levels))
  for (f in model$factors %||% list()) {
    if (f$name %in% have) {
      i <- which(have == f$name)[1]
      if (is.null(out$factors[[i]]$n_levels) && count_ok(f)) out$factors[[i]]$n_levels <- f$n_levels
      if (is.null(out$factors[[i]]$levels) && named(f)) out$factors[[i]]$levels <- f$levels
      if (is.null(out$factors[[i]]$applied_to) && !is.null(f$applied_to)) out$factors[[i]]$applied_to <- f$applied_to
    } else if (is.null(f$n_levels) || count_ok(f)) {
      g <- f[c("name", intersect(c("n_levels", "applied_to"), names(f)))]
      if (named(f)) g$levels <- f$levels
      out$factors[[length(out$factors) + 1]] <- g
      have <- c(have, f$name)
    }
  }
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
