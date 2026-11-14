#' Path to a bundled registry file
#' @param name Registry name without extension (e.g. "design_catalog").
#' @export
registry_path <- function(name) {
  f <- system.file("registry", paste0(name, ".json"), package = "studyforge")
  if (!nzchar(f)) stop("Unknown registry: ", name, call. = FALSE)
  f
}

#' Load a registry as a list
#' @param name Registry name without extension.
#' @export
load_registry <- function(name) {
  jsonlite::fromJSON(registry_path(name), simplifyVector = FALSE)
}

#' List registry names shipped with the package
#' @export
list_registries <- function() {
  files <- list.files(system.file("registry", package = "studyforge"), pattern = "\\.json$")
  sub("\\.json$", "", files)
}

#' Look up a design in the catalog
#' @param id Design id (e.g. "alpha", "split").
#' @export
lookup_design <- function(id) {
  designs <- load_registry("design_catalog")$designs
  hit <- Filter(function(d) identical(d$id, id), designs)
  if (!length(hit)) {
    stop("Design '", id, "' not in catalog. Known: ",
         paste(vapply(designs, `[[`, "", "id"), collapse = ", "), call. = FALSE)
  }
  hit[[1]]
}

#' Designs suitable for an experimental system
#' @param system System id (e.g. "field", "greenhouse", "mouse").
#' @export
designs_for_system <- function(system) {
  designs <- load_registry("design_catalog")$designs
  keep <- vapply(designs, function(d) system %in% unlist(d$systems), logical(1))
  vapply(designs[keep], `[[`, "", "id")
}

#' Consequential questions for a system
#' @param system System id.
#' @export
system_questions <- function(system) {
  sys <- load_registry("experimental_systems")$systems
  hit <- Filter(function(s) identical(s$id, system), sys)
  if (!length(hit)) stop("Unknown system: ", system, call. = FALSE)
  unlist(hit[[1]]$consequential_questions)
}

#' Find pseudoreplication rules that match a unit pair
#' @param measurement_unit What is measured (e.g. "leaf").
#' @param experimental_unit What receives the treatment independently (e.g. "plant", "pot").
#' @return A list of matching rules (possibly empty).
#' @export
match_pseudoreplication_rules <- function(measurement_unit, experimental_unit) {
  rules <- load_registry("pseudoreplication_rules")$rules
  norm <- function(x) tolower(gsub("[^a-z]", "", tolower(x)))
  m <- norm(measurement_unit)
  e <- norm(experimental_unit)
  Filter(function(r) norm(r$measurement_unit) == m &&
           (norm(r$nested_in) == e || e == ""), rules)
}

# ---- the rule table (data, not code) -------------------------------------------------------------------------
# inst/agent/rules.tsv is the one table of words and patterns: category | term | match | pattern | note | source.
#   match = word   a literal phrase searched in the text (an alias: pattern -> term); .sf_alias_table(), .sf_find_all()
#           regex  a regular expression searched in the text; .sf_rules() (category -> term = pattern), .sf_cue() (by name)
#           value  a literal the code uses: word lists (.sf_list), lookups (.sf_map), groups (.sf_group, .sf_groups)
# Order within a category is priority. inst/registry/experimental_systems.json says what each system is.
# Python reads the same file (inst/python/rulebook.py), so R and Python follow one set of rules.
.sf_rules_cache <- new.env(parent = emptyenv())

.sf_rules_table <- function() {
  if (is.null(.sf_rules_cache$t)) {
    f <- system.file("agent", "rules.tsv", package = "studyforge")
    .sf_rules_cache$t <- utils::read.delim(f, quote = "", comment.char = "", stringsAsFactors = FALSE,
                                           colClasses = "character", na.strings = character())
  }
  .sf_rules_cache$t
}

.sf_rules_rows <- function(category, match = NULL) {
  t <- .sf_rules_table()
  t <- t[t$category == category & (is.null(match) | t$match %in% match), ]
  if (!nrow(t)) stop("rules.tsv has no rows for category '", category, "'", call. = FALSE)
  t
}

# regex rows of a category as a named list (term -> pattern), in file order; order is priority
.sf_rules <- function(category) {
  t <- .sf_rules_rows(category, "regex")
  stats::setNames(as.list(t$pattern), t$term)
}

# word list: the patterns of a category, in file order
.sf_list <- function(category) .sf_rules_rows(category)$pattern

# lookup: named character vector (pattern -> term)
.sf_map <- function(category) {
  t <- .sf_rules_rows(category)
  stats::setNames(t$term, t$pattern)
}

# the patterns that belong to one term (e.g. the nouns that count water levels)
.sf_group <- function(category, term) {
  t <- .sf_rules_rows(category)
  v <- t$pattern[t$term == term]
  if (!length(v)) stop("rules.tsv category '", category, "' has no term '", term, "'", call. = FALSE)
  v
}

# pattern -> all its terms (e.g. a specific assay -> the generic labels it stands in for)
.sf_groups <- function(category) {
  t <- .sf_rules_rows(category)
  split(t$term, factor(t$pattern, levels = unique(t$pattern)))
}

# one named pattern (category cue); {N} stands for a number (digits or a number word)
.sf_cue <- function(name) {
  if (is.null(.sf_rules_cache$cue)) {
    t <- .sf_rules_rows("cue", "regex")
    .sf_rules_cache$cue <- stats::setNames(t$pattern, t$term)
  }
  v <- .sf_rules_cache$cue[name]
  if (is.na(v)) stop("rules.tsv has no cue '", name, "'", call. = FALSE)
  v <- unname(v)
  repeat {
    i <- regexpr("{N}", v, fixed = TRUE)
    if (i < 0) return(v)
    v <- paste0(substr(v, 1, i - 1), .sf_num_re, substr(v, i + 3, nchar(v)))
  }
}

# system ids by registry property, e.g. .sf_systems_where(kind = "study"), .sf_systems_where(plant_site = TRUE)
.sf_systems_where <- function(...) {
  want <- list(...)
  if (is.null(.sf_rules_cache$systems)) .sf_rules_cache$systems <- load_registry("experimental_systems")$systems
  s <- .sf_rules_cache$systems
  ok <- vapply(s, function(x) all(vapply(names(want), function(k) identical(x[[k]], want[[k]]), logical(1))), logical(1))
  vapply(s[ok], `[[`, "", "id")
}
