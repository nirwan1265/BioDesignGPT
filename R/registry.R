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

# ---- rule tables (data, not code) ---------------------------------------------------------------------------
# inst/agent/rules.tsv holds the extractor's pattern tables (organism, system, setting, outcome, genotype_noun) and
# factor synonyms; inst/registry/experimental_systems.json says what each system is (setting / assay / study).
# Python (training/setting.py, llm/make_sft.py) reads the same files, so R and Python follow one set of rules.
.sf_rules_cache <- new.env(parent = emptyenv())

.sf_rules_table <- function() {
  if (is.null(.sf_rules_cache$t)) {
    f <- system.file("agent", "rules.tsv", package = "studyforge")
    .sf_rules_cache$t <- utils::read.delim(f, quote = "", comment.char = "", stringsAsFactors = FALSE,
                                           colClasses = "character", na.strings = character())
  }
  .sf_rules_cache$t
}

.sf_rules_rows <- function(table) {
  t <- .sf_rules_table()
  t <- t[t$table == table, ]
  if (!nrow(t)) stop("rules.tsv has no table '", table, "'", call. = FALSE)
  t
}

# pattern table as a named list (key -> regex) in file order; order is priority
.sf_rules <- function(table) {
  t <- .sf_rules_rows(table)
  stats::setNames(as.list(t$value), t$key)
}

# word list (the keys of a table), in file order
.sf_list <- function(table) .sf_rules_rows(table)$key

# lookup table as a named character vector (key -> value)
.sf_map <- function(table) {
  t <- .sf_rules_rows(table)
  stats::setNames(t$value, t$key)
}

# one named pattern from the cue table; {N} stands for a number (digits or a number word)
.sf_cue <- function(name) {
  if (is.null(.sf_rules_cache$cue)) .sf_rules_cache$cue <- .sf_map("cue")
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

# table with several rows per key: the values of one key (file order), or all keys as a named list
.sf_group <- function(table, key) {
  t <- .sf_rules_rows(table)
  v <- t$value[t$key == key]
  if (!length(v)) stop("rules.tsv table '", table, "' has no key '", key, "'", call. = FALSE)
  v
}
.sf_groups <- function(table) {
  t <- .sf_rules_rows(table)
  split(t$value, factor(t$key, levels = unique(t$key)))
}
