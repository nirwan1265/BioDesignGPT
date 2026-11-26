# Unordered classes, expected ratios, correlation among traits and agreement between raters, read from the question
# (Bioana 0.11.0 contract). Patterns and words are in rules.tsv (cues category_list, ratio_stated, scale_range,
# correlation_vars, agreement_question, rater_count; categories correlation_method, rater_noun).

.sf_snake <- function(x) gsub("^_+|_+$", "", gsub("[^a-z0-9]+", "_", tolower(trimws(x))))

.sf_split_list <- function(x) {
  p <- trimws(strsplit(x, "\\s*,\\s*|\\s+(?:and|or|vs\\.?|versus)\\s+", perl = TRUE)[[1]])
  p <- sub("^(?:and|or)\\s+", "", p, perl = TRUE)
  p[nzchar(p)]
}

.sf_categorical_from_text <- function(text) {
  t <- tolower(text); out <- list()
  g <- .sf_grab(t, "category_list"); if (length(g)) out$categories <- .sf_split_list(g[2])
  g <- .sf_grab(t, "ratio_stated")
  if (length(g)) { r <- g[-1][nzchar(g[-1])][1]; out$ratio <- as.numeric(strsplit(gsub("\\s", "", r), ":", fixed = TRUE)[[1]]) }
  g <- .sf_grab(t, "scale_range"); if (length(g)) out$scale_levels <- seq(as.numeric(g[2]), as.numeric(g[3]))
  g <- .sf_grab(t, "correlation_vars")
  if (length(g)) {
    v <- .sf_split_list(g[-1][nzchar(g[-1])][1])
    v <- sub("^(?:the|their|plant's|seed)\\s+", "", v, perl = TRUE)
    bad <- tolower(.sf_list("not_a_correlation_variable"))
    if (length(v) >= 2 && !any(vapply(v, function(x) any(strsplit(x, "\\s+")[[1]] %in% bad), logical(1)))) out$correlation <- v
  }
  if (!is.null(out$correlation)) {
    r <- .sf_rules_rows("correlation_method"); k <- which(vapply(r$pattern, grepl, logical(1), x = t, perl = TRUE))
    out$method <- if (length(k)) r$term[k[1]] else NULL
  }
  g <- .sf_grab(t, "rater_count")
  if (length(.sf_grab(t, "agreement_question")) && (length(g) || grepl("inter[- ]?(?:rater|observer)", t, perl = TRUE))) {
    # the count pattern ({N}) has groups of its own: the noun is the last group, the count the first number
    out$agreement <- list(n = if (length(g)) .sf_num(g[2]) else NA, noun = if (length(g)) sub("s$", "", g[length(g)]) else "rater")
  }
  out
}

.sf_apply_categorical <- function(spec, text) {
  x <- .sf_categorical_from_text(text)
  po <- spec$primary_outcome %||% list()
  # categories: three or more unordered classes are nominal, two are binary (reference = first named)
  if (length(x$categories) >= 2) {
    po$categories <- x$categories
    if (is.null(po$type) || po$type %in% c("continuous", "binary"))
      po$type <- if (length(x$categories) >= 3) "nominal" else "binary"
  }
  # a stated ratio (3:1, 9:3:3:1, 1:2:1): weights labelled by the categories in order, else class_1, class_2, ...
  if (length(x$ratio) >= 2) {
    lab <- if (length(po$categories) == length(x$ratio)) unlist(po$categories) else paste0("class_", seq_along(x$ratio))
    if (!identical(lab, unlist(po$categories))) {
      po$categories <- lab
      spec$assumptions[["primary_outcome.categories"]] <- "not stated: class_1, class_2, ... in the order of the ratio; asked"
    }
    if (is.null(po$type) || po$type %in% c("continuous", "binary", "nominal"))
      po$type <- if (length(x$ratio) >= 3) "nominal" else "binary"
    spec$analysis$expected_ratio <- stats::setNames(as.list(x$ratio), lab)
  }
  # correlation: the first trait is the primary outcome, the others secondary outcomes with their own columns
  if (length(x$correlation) >= 2) {
    v <- x$correlation
    if (is.null(po$name)) po$name <- .sf_snake(v[1])
    spec$secondary_outcomes <- lapply(v[-1], function(s) list(name = .sf_snake(s), column = .sf_snake(s)))
    spec$analysis$correlation <- list(variables = c(po$name, vapply(v[-1], .sf_snake, "")), method = x$method %||% "pearson")
    if (is.null(x$method)) spec$assumptions[["analysis.correlation.method"]] <- "not stated: pearson (spearman for ranks or skewed traits)"
  }
  # agreement: the raters (or methods) score every unit, so the rater is a factor within the unit
  if (!is.null(x$agreement)) {
    n <- x$agreement$n
    rf <- list(name = "rater")
    if (!is.na(n) && n >= 2) { rf$n_levels <- n; rf$levels <- paste0(x$agreement$noun, "_", seq_len(n)) }
    spec$factors <- c(Filter(function(f) !identical(f$name, "rater"), spec$factors %||% list()), list(rf))
    sc <- if (identical(po$type, "ordinal")) "ordinal" else if (identical(po$type, "nominal") || identical(po$type, "binary")) "nominal" else "continuous"
    lev <- if (identical(sc, "ordinal") && length(x$scale_levels)) x$scale_levels else if (identical(sc, "nominal")) unlist(po$categories)
    spec$analysis$agreement <- list(rater_column = "rater", score_column = "primary_outcome", scale = sc, levels = lev)
    spec$analysis$agreement <- spec$analysis$agreement[!vapply(spec$analysis$agreement, is.null, logical(1))]
  }
  if (length(po)) spec$primary_outcome <- po
  one_group <- !is.null(spec$analysis$expected_ratio) || !is.null(spec$analysis$correlation) || !is.null(spec$analysis$agreement)
  if (one_group) {
    # a segregating population tested against a ratio is the population itself, not a panel of genotypes
    if (!is.null(spec$analysis$expected_ratio))
      spec$factors <- Filter(function(f) !(identical(f$name, "genotype") && is.null(f$n_levels)), spec$factors %||% list())
    # one group's size: "400 plants", "the same 60 leaves" (cue group_size)
    rand <- Filter(function(f) !(f$name %in% .sf_within_factors(spec)), spec$factors %||% list())
    if (!length(rand) && is.null(spec$design$reps)) {
      g <- .sf_grab(tolower(text), "group_size")
      if (length(g)) { n <- .sf_num(g[-1][nzchar(g[-1])][1]); if (!is.na(n) && n >= 2) spec$design$reps <- n }
    }
  }
  spec
}
