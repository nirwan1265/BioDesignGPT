# Unordered classes, expected ratios, correlation among traits and agreement between raters, read from the question
# (Bioana 0.11.0 contract). Patterns and words are in rules.tsv (cues category_list, ratio_stated, scale_range,
# correlation_vars, agreement_question, rater_count; categories correlation_method, rater_noun).

.sf_snake <- function(x) gsub("^_+|_+$", "", gsub("[^a-z0-9]+", "_", tolower(trimws(x))))

.sf_split_list <- function(x) {
  # commas and "and" inside brackets belong to one item ("glucose (mean 100, SD 15 mg/dL)")
  br <- regmatches(x, gregexpr("\\([^)]*\\)", x))[[1]]
  for (i in seq_along(br)) x <- sub(br[i], sprintf("<<%d>>", i), x, fixed = TRUE)
  p <- trimws(strsplit(x, "\\s*,\\s*|\\s+(?:and|or|vs\\.?|versus)\\s+", perl = TRUE)[[1]])
  for (i in seq_along(br)) p <- sub(sprintf("<<%d>>", i), tolower(br[i]), p, fixed = TRUE)
  p <- sub("^(?:and|or)\\s+", "", p, perl = TRUE)
  p[nzchar(p)]
}

.sf_categorical_from_text <- function(text) {
  t <- tolower(text); out <- list()
  g <- .sf_grab(t, "category_list"); if (length(g)) out$categories <- .sf_split_list(g[2])
  g <- .sf_grab(t, "ratio_labels"); if (length(g)) out$ratio_labels <- trimws(strsplit(g[2], "\\s+(?:to|:)\\s+|\\s*:\\s*", perl = TRUE)[[1]])
  g <- .sf_grab(t, "ratio_stated")
  if (length(g)) { r <- g[-1][nzchar(g[-1])][1]; out$ratio <- as.numeric(strsplit(gsub("\\s", "", r), ":", fixed = TRUE)[[1]]) }
  g <- .sf_grab(t, "scale_range"); if (length(g)) out$scale_levels <- seq(as.numeric(g[2]), as.numeric(g[3]))
  g <- .sf_grab(t, "correlation_vars")
  if (length(g)) {
    v <- .sf_split_list(paste(g[-1][nzchar(g[-1])], collapse = " and "))   # "is X related to Y": both groups
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
    noun <- if (length(g)) g[length(g)] else "rater"
    rl <- .sf_rules_rows("rater_label"); k <- which(vapply(rl$pattern, grepl, logical(1), x = noun, perl = TRUE))
    noun <- if (length(k)) rl$term[k[1]] else sub("s$", "", noun)
    out$agreement <- list(n = if (length(g)) .sf_num(g[2]) else NA, noun = noun)
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
    if (length(x$ratio_labels) == length(x$ratio)) po$categories <- x$ratio_labels
    lab <- if (length(po$categories) == length(x$ratio)) unlist(po$categories) else paste0("class_", seq_along(x$ratio))
    if (!identical(lab, unlist(po$categories))) {
      po$categories <- lab
      spec$assumptions[["primary_outcome.categories"]] <- "not stated: class_1, class_2, ... in the order of the ratio; asked"
    }
    if (is.null(po$type) || po$type %in% c("continuous", "binary", "nominal")) po$type <- "nominal"   # classes vs a ratio
    spec$analysis$expected_ratio <- stats::setNames(as.list(x$ratio), lab)
  }
  # correlation: the first trait is the primary outcome, the others secondary outcomes with their own columns
  if (length(x$correlation) >= 2) {
    v <- x$correlation
    if (is.null(po$name)) po$name <- .sf_snake(v[1])
    # each trait's type from its own name (rules.tsv outcome_type; no match = continuous): "tiller number" is a count,
    # "plant height" is not, whatever else the question says
    ty <- function(nm) .sf_outcome_type("", gsub("_", " ", nm)) %||% "continuous"
    if (is.null(po$type) || !identical(po$type, ty(po$name))) po$type <- ty(po$name)
    spec$secondary_outcomes <- lapply(v[-1], function(s) list(name = .sf_snake(s), type = ty(.sf_snake(s)), column = .sf_snake(s)))
    spec$analysis$correlation <- list(variables = unname(c(po$name, vapply(v[-1], .sf_snake, ""))), method = x$method %||% "pearson")
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

# a factor whose levels are known (rules.tsv known_levels: sex = female | male), named without them as an adjustment
# factor ("adjusting for sex") or with every level named ("6 male, 6 female"); a mere mention ("sex-matched") gets nothing
.sf_apply_known_levels <- function(spec, text = "") {
  r <- .sf_rules_rows("known_levels")
  adj <- unlist(spec$analysis$sf_adjust_factors)   # only where the question uses it as a factor ("adjusting for sex")
  for (i in seq_along(spec$factors %||% list())) {
    f <- spec$factors[[i]]; k <- which(r$term == f$name)
    if (!length(k) || length(f$levels)) next
    lv <- strsplit(r$pattern[k[1]], "|", fixed = TRUE)[[1]]
    # evidence: an adjustment factor, or every level named in the question ("6 male, 6 female", "males and females")
    named <- all(vapply(lv, function(l) grepl(sprintf("\\b%ss?\\b", l), tolower(text), perl = TRUE), logical(1)))
    if (!(f$name %in% adj) && !named) next
    if (!is.null(f$n_levels) && f$n_levels != length(lv)) next
    spec$factors[[i]]$levels <- lv; spec$factors[[i]]$n_levels <- length(lv)
    spec$assumptions[[paste0("factors.", f$name, ".levels")]] <- sprintf("named without levels: %s (rules.tsv known_levels)", paste(lv, collapse = ", "))
  }
  # "12 per diet" with sex only adjusted for: 12 per diet split evenly across the sexes (6 per cell), unless the
  # question gives the count per cell (cue per_cell_stated)
  if (length(adj) && !is.null(spec$design$reps) && !grepl(.sf_cue("per_cell_stated"), tolower(text), perl = TRUE)) {
    k <- prod(vapply(Filter(function(f) f$name %in% adj, spec$factors), function(f) as.numeric(f$n_levels %||% 1), numeric(1)))
    r <- as.numeric(spec$design$reps)
    if (k > 1 && r %% k == 0) {
      spec$design$reps <- r / k
      spec$assumptions[["design.reps"]] <- sprintf("%g per group split evenly across %s: %g per cell", r, paste(adj, collapse = " x "), r / k)
    } else if (k > 1) {
      spec$assumptions[["design.reps"]] <- sprintf("%g per group does not split evenly across %s; read as %g per cell (asked)", r, paste(adj, collapse = " x "), r)
    }
  }
  spec
}
