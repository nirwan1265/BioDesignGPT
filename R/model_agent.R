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
merge_specs <- function(rule, model, question) {
  if (is.null(model)) return(rule)
  text <- tolower(gsub(",", "", question))
  stated <- function(v) {
    if (!is.numeric(v)) return(TRUE)
    words <- names(.sf_number_words)[.sf_number_words == v]
    grepl(paste0("(?<![\\d.])", v, "(?![\\d])"), text, perl = TRUE) ||
      any(vapply(words, function(w) grepl(paste0("\\b", w, "\\b"), text, perl = TRUE), logical(1))) ||
      (v == 1 && grepl("\\b(one|single|this|no) ", text))
  }
  # guard 1: a rep count must sit next to a replication word ("two sites" is not 2 reps)
  rep_ok <- function(v) {
    w <- c(as.character(v), names(.sf_number_words)[.sf_number_words == v], if (v == 1) c("no", "one", "single"))
    re <- paste0("\\b(", paste(w, collapse = "|"), ")\\s+(?:\\w+\\s+){0,2}?(reps?|replicat\\w*|replications?|blocks?|benches|vials|dams|plants per combination)|",
                 "\\b(", paste(w, collapse = "|"), ")\\s+(plot|row) (each|per)")
    grepl(re, text, perl = TRUE)
  }
  # guard 2: outcomes must be known canonical terms
  known_outcomes <- unique(.sf_alias_table()$canonical_term[.sf_alias_table()$category == "outcome"])
  if (!is.null(model$design$reps) && !rep_ok(model$design$reps)) model$design$reps <- NULL
  if (!is.null(model$primary_outcome$name) && !model$primary_outcome$name %in% known_outcomes) model$primary_outcome <- NULL
  out <- rule
  for (p in c("system", "organism", "experimental_unit", "measurement_unit", "subsamples_per_unit",
              "primary_outcome.name", "primary_outcome.type", "design.reps", "design.locations",
              "design.seasons", "blocking_factors")) {
    if (is.null(spec_get(out, p))) {
      v <- spec_get(model, p)
      if (!is.null(v) && all(vapply(as.list(unlist(v)), stated, logical(1)))) out <- spec_set(out, p, v)
    }
  }
  have <- vapply(out$factors %||% list(), `[[`, "", "name")
  for (f in model$factors %||% list()) {
    if (f$name %in% have) {
      i <- which(have == f$name)[1]
      if (is.null(out$factors[[i]]$n_levels) && !is.null(f$n_levels) && stated(f$n_levels)) out$factors[[i]]$n_levels <- f$n_levels
      if (is.null(out$factors[[i]]$applied_to) && !is.null(f$applied_to)) out$factors[[i]]$applied_to <- f$applied_to
    } else if (is.null(f$n_levels) || stated(f$n_levels)) {
      out$factors[[length(out$factors) + 1]] <- f[c("name", intersect(c("n_levels", "applied_to"), names(f)))]
      have <- c(have, f$name)
    }
  }
  out
}

.sf_alias_cache <- new.env()
.sf_alias_table <- function() {
  if (is.null(.sf_alias_cache$t)) {
    f <- system.file("agent", "aliases.tsv", package = "studyforge")
    .sf_alias_cache$t <- utils::read.delim(f, quote = "", stringsAsFactors = FALSE)
  }
  .sf_alias_cache$t
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
