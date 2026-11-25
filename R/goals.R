# Analysis goals (contract: Bioana docs/contracts/analysis_goals.md; vocabulary: inst/registry/analysis_goals.json).
# Biodes reads the goal from the question, asks when it does not, and writes analysis.goals, primary_goal,
# goal_terms and goal_effect; Bioana picks the test and the engine, Simitall plants truth for the primary goal.
# Vocabulary and wording live in rules.tsv (analysis_goal, goal_default, goal_question, time_shape, ...).

.sf_goal_registry <- function() {
  g <- load_registry("analysis_goals")$goals
  stats::setNames(g, vapply(g, `[[`, "", "id"))
}

# goals the text names (rules.tsv analysis_goal: term = goal id, pattern = regex), in order of first mention
.sf_goals_from_text <- function(text) {
  t <- tolower(text)
  r <- .sf_rules_rows("analysis_goal")
  if (!NROW(r)) return(character())
  pos <- vapply(seq_len(nrow(r)), function(i) { m <- regexpr(r$pattern[i], t, perl = TRUE); if (m > 0) as.numeric(m) else Inf }, 0)
  hit <- r$term[is.finite(pos)][order(pos[is.finite(pos)])]
  unique(hit[hit %in% names(.sf_goal_registry())])
}

# goals that follow from the data or outcome when the text names none (rules.tsv goal_default: term = goal id,
# pattern = an assay label, an assay kind, or "outcome:<type>")
.sf_goals_by_default <- function(spec) {
  r <- .sf_rules_rows("goal_default")
  have <- c(unlist(spec$assays), unlist(spec$assay_kinds), paste0("outcome:", spec$primary_outcome$type %||% ""))
  unique(r$term[r$pattern %in% have])
}

# time-course details stated in the text: shape (rules.tsv time_shape), peak / half-time (cues time_peak,
# time_half), scope (cue time_scope_within: only one group changes)
.sf_time_course_detail <- function(text) {
  t <- tolower(text); out <- list()
  r <- .sf_rules_rows("time_shape")
  for (i in seq_len(NROW(r))) if (grepl(r$pattern[i], t, perl = TRUE)) { out$shape <- r$term[i]; break }
  cues <- c(peak = "time_peak", half_time = "time_half")
  for (nm in names(cues)) {
    g <- regmatches(t, regexec(tryCatch(.sf_cue(cues[[nm]]), error = function(e) "(?!)"), t, perl = TRUE))[[1]]
    if (length(g) >= 3) out[[nm]] <- list(value = as.numeric(g[2]), unit = .sf_unit_name(g[3]))
  }
  # scope: the time pattern is expected in one group only; the group word ("infected") and the factor it names
  sg <- regmatches(t, regexec(tryCatch(.sf_cue("time_scope_within"), error = function(e) "(?!)"), t, perl = TRUE))[[1]]
  if (length(sg)) {
    out$scope <- "within_group"
    if (length(sg) >= 2 && nzchar(sg[2])) {
      out$group <- sg[2]
      f <- setdiff(.sf_find_all(sg[2], "factor"), "treatment")
      out$group_factor <- if (length(f)) f[1] else "treatment"
    }
  }
  out
}

# the goal question when the text leaves it open (rules.tsv goal_question: term = "time" when an occasion factor
# is crossed with a randomized one, "two_factors" for two randomized factors; {Y} what is measured, {A} {B} {T}
# factor names)
.sf_goal_question <- function(spec) {
  rf <- .sf_randomized_factors(spec)
  occ <- intersect(vapply(spec$factors %||% list(), function(f) f$name %||% "", ""), .sf_list("occasion_factor"))
  a <- setdiff(rf, occ)[1]
  key <- if (!is.na(a) && length(occ)) "time" else if (length(setdiff(rf, occ)) >= 2) "two_factors" else return(NULL)
  q <- .sf_rules_rows("goal_question"); q <- q$pattern[q$term == key][1]
  if (is.na(q)) return(NULL)
  omics <- length(spec$assays) > 0   # any assay named: many features (genes, taxa, peaks) per sample
  y <- if (omics) "genes/features" else (spec$primary_outcome$name %||% "outcomes")
  b <- setdiff(setdiff(rf, occ), a)[1]
  fill <- c(Y = y, A = a, B = if (is.na(b)) "" else b, T = if (length(occ)) occ[1] else "")
  for (nm in names(fill)) q <- gsub(paste0("{", nm, "}"), fill[[nm]], q, fixed = TRUE)
  q
}

# the scale an effect is stated and tested on, from the data type (rules.tsv effect_scale: term = scale, pattern =
# an assay label or outcome:<type>; counts -> log2, methylation -> M, binary -> logit; otherwise identity)
.sf_effect_scale <- function(spec) {
  r <- .sf_rules_rows("effect_scale")
  keys <- c(paste0("outcome:", spec$primary_outcome$type %||% ""), unlist(spec$assays))
  for (k in keys) { h <- r$term[r$pattern == k]; if (length(h)) return(h[1]) }
  "identity"
}

# a log-scaled numeric factor with a zero level (an untreated control) is fitted as log(x + offset); the offset is
# the smallest positive level, written into the spec so Simitall and Bioana use the same one
.sf_log_offset <- function(v) { v <- v[is.finite(v)]; if (any(v == 0) && any(v > 0)) min(v[v > 0]) else NULL }

# a stated change per unit of a numeric factor ("a 5% increase per 10-fold dose"; cue per_unit_effect) -> its number
.sf_per_unit_effect <- function(text) {
  g <- regmatches(tolower(text), regexec(tryCatch(.sf_cue("per_unit_effect"), error = function(e) "(?!)"), tolower(text), perl = TRUE))[[1]]
  # groups: size, the amount after "per" (0.5 per 50 kg = 0.01 per kg), a log word ("per 10-fold": per log10 unit)
  if (length(g) < 2) return(NULL)
  per <- if (length(g) >= 3 && nzchar(g[3])) as.numeric(g[3]) else 1
  list(size = as.numeric(g[2]) / per, per = if (length(g) >= 4 && nzchar(g[4])) "log" else "linear")
}

# the group a within-group time course names: a factor level it matches ("mutant" is the genotype level "mutant"),
# else the factor its word belongs to; a word that is neither is dropped (scope stays within_group, group unknown)
.sf_resolve_group <- function(spec, tc) {
  if (is.null(tc$group)) return(tc)
  w <- tolower(tc$group)
  for (f in spec$factors %||% list()) {
    lv <- tolower(unlist(f$levels))
    hit <- lv[lv == w | grepl(paste0("\\b", w, "\\b"), lv, perl = TRUE)]
    if (length(hit) == 1) { tc$group <- unlist(f$levels)[match(hit, lv)]; tc$group_factor <- f$name; return(tc) }
  }
  have <- vapply(spec$factors %||% list(), function(f) f$name %||% "", "")
  if (!(tc$group_factor %||% "") %in% have) { tc$group <- NULL; tc$group_factor <- NULL }
  tc
}

# the outcome's scale as stated: the unit an effect is given in (cue effect_unit), a residual SD (residual_sd_stated),
# a CV (cv_stated) and a usual level (baseline_mean_stated). Units: rules.tsv time/level/outcome_unit_name.
.sf_outcome_scale <- function(text) {
  t <- tolower(text); out <- list()
  grab <- function(cue) regmatches(t, regexec(tryCatch(.sf_cue(cue), error = function(e) "(?!)"), t, perl = TRUE))[[1]]
  # only outcome units (rules.tsv outcome_unit_name): "30 min", "50 C" are settings, not the outcome's scale
  ou <- .sf_rules_rows("outcome_unit_name")
  u <- function(x) if (length(x) && !is.na(x) && nzchar(x)) { k <- which(vapply(ou$pattern, grepl, logical(1), x = x, perl = TRUE)); if (length(k)) ou$term[k[1]] }
  g <- grab("effect_unit"); if (length(g)) out$unit <- u(g[2])
  g <- grab("residual_sd_stated"); if (length(g)) { out$residual_sd <- as.numeric(g[2]); if (length(g) >= 3) out$sd_unit <- u(g[3]) }
  g <- grab("cv_stated"); if (length(g)) out$cv <- as.numeric(g[2])
  g <- grab("mdd_stated"); if (length(g) && !identical(g[3], "fold")) { out$mdd <- as.numeric(g[2]); if (length(g) >= 3) out$mdd_unit <- u(g[3]) }
  g <- grab("baseline_mean_stated"); if (length(g) && !is.null(u(g[3]))) { out$baseline_mean <- as.numeric(g[2]); out$mean_unit <- u(g[3]) }
  out$unit <- out$unit %||% out$mdd_unit %||% out$mean_unit %||% out$sd_unit
  out
}

# numeric levels: linear or log spacing (equal ratios of at least 2 between successive positive values)
.sf_level_scale <- function(v) {
  v <- sort(unique(v[is.finite(v) & v > 0]))   # a zero control does not decide the spacing (0, 1, 10, 100 is log)
  if (length(v) >= 3) { r <- v[-1] / v[-length(v)]; if (min(r) >= 2 && diff(range(r)) / mean(r) < 0.15) return("log") }
  "linear"
}

# fill analysis.goals / primary_goal / goal_terms / goal_effect for the model the design chose; adds the terms the
# primary goal needs to the model when the catalog model lacks them, and widens the replicate sweep for goals that
# need more replicates (registry replicate_multiplier)
.sf_fill_goals <- function(spec) {
  reg <- .sf_goal_registry()
  terms <- spec$analysis$terms %||% list()
  model <- spec$analysis$model %||% ""
  goals <- unlist(spec$analysis$goals)
  if (!length(goals)) {
    goals <- .sf_goals_by_default(spec)
    if (!length(goals)) goals <- "treatment_effect"
    spec$assumptions[["analysis.goals"]] <- sprintf("assumed: %s (the question does not say which comparison%s)",
      paste(goals, collapse = ", "), if (is.null(.sf_goal_question(spec))) "" else "; asked")
  }
  # a goal the design cannot answer is dropped with a note (interaction needs two factors, time_course a time term,
  # trend a numeric factor)
  rf_terms <- intersect(c("treatment", "treatment2"), names(terms)[!vapply(terms, is.null, logical(1))])
  num_term <- NULL
  for (k in c("treatment", "treatment2", "time")) {
    f <- Filter(function(x) identical(x$name, terms[[k]]), spec$factors %||% list())
    if (length(f) && length(f[[1]]$values)) { num_term <- k; break }
  }
  # the generic model term that holds a layout column (time may be "time" or, in a factorial, "treatment2")
  rhs_has <- function(x) grepl(paste0("(^|[~+*: (|])", x, "($|[ +*:)|])"), model)
  term_for <- function(col) { for (g in c("time", "treatment", "treatment2")) if (identical(terms[[g]], col) && rhs_has(g)) return(g)
    for (g in c("time", "treatment", "treatment2")) if (identical(terms[[g]], col)) return(g); NULL }
  occ_col <- intersect(.sf_list("occasion_factor"), vapply(spec$factors %||% list(), function(f) f$name %||% "", ""))[1]
  t_time <- if (!is.na(occ_col)) term_for(occ_col)
  # several locations/seasons in the layout are the environment of a G x E interaction ("env"), even when the
  # design's own model has no env term
  envc <- unlist(terms$uncovered_factors)[unlist(terms$uncovered_factors) %in% c("location", "season")]
  if (is.null(terms$env) && length(envc)) { terms$env <- paste(envc, collapse = ":"); env_added <- TRUE } else env_added <- FALSE
  if (!is.null(terms$env)) rf_terms <- c(rf_terms, "env")
  gt <- list(); dropped <- character()
  for (g in goals) {
    need <- unlist(reg[[g]]$required_terms)
    if ("factor_a" %in% need) {
      other <- setdiff(rf_terms, t_time)
      pair <- if (!is.null(t_time) && length(other)) c(other[1], t_time) else if (length(rf_terms) == 2) rf_terms else NULL
      if (is.null(pair)) { dropped <- c(dropped, g); next }
      gt[[g]] <- pair
    } else if ("time" %in% need) {
      if (is.null(t_time)) { dropped <- c(dropped, g); next }
      gt[[g]] <- t_time
    } else if ("numeric" %in% need) {
      if (is.null(num_term)) { dropped <- c(dropped, g); next }
      gt[[g]] <- num_term
    }
  }
  goals <- setdiff(goals, dropped)
  if (!length(goals)) goals <- "treatment_effect"
  if (length(dropped)) spec$analysis$note <- paste(c(spec$analysis$note, sprintf("goal %s not possible with this design (needs %s); not written",
    paste(dropped, collapse = ", "), paste(unique(unlist(lapply(dropped, function(g) reg[[g]]$required_terms))), collapse = ", "))), collapse = "; ")
  # the model holds what the goal tests: "treatment:time" for an interaction, a time term for a time course
  for (g in intersect(goals, names(gt))) {
    tt <- gt[[g]]
    if (length(tt) == 2) {
      inter <- paste(tt, collapse = ":")
      held <- any(vapply(list(tt, rev(tt)), function(p) grepl(paste0("\\b", p[1], "\\s*[*:]\\s*", p[2], "\\b"), model, perl = TRUE), logical(1)))
      if (!held) {
        for (x in tt) if (!rhs_has(x)) model <- sub("~\\s*", paste0("~ ", x, " + "), model)
        model <- sub("~\\s*", paste0("~ ", inter, " + "), model)
      }
    } else if (!rhs_has(tt)) model <- sub("~\\s*", paste0("~ ", tt, " + "), model)
  }
  if (!identical(model, spec$analysis$model %||% "")) {
    spec$analysis$note <- paste(c(spec$analysis$note, sprintf("model extended for goal %s: %s", goals[1], model)), collapse = "; ")
    spec$analysis$model <- model
  }
  if (env_added && any(vapply(gt, function(x) "env" %in% x, logical(1)))) {
    spec$analysis$terms$env <- terms$env
    spec$analysis$terms$uncovered_factors <- as.list(setdiff(unlist(terms$uncovered_factors), envc))
  }
  spec$analysis$goals <- as.list(goals)
  spec$analysis$primary_goal <- goals[1]
  spec$analysis$goal_terms <- gt[intersect(goals, names(gt))]
  # goal_effect for each goal: size from the stated minimum detectable difference, else listed as an assumption
  # size from the registry's size_from: a difference between levels (power.minimum_detectable_difference) or a
  # stated change per unit (spec$analysis$per_unit_effect, cue per_unit_effect) for a slope
  pu <- spec$analysis$per_unit_effect
  if (is.numeric(pu)) pu <- list(size = pu, per = "linear")
  # a change stated per linear amount ("per 50 kg N") fits the factor on its linear scale, even when its levels are
  # spaced by equal ratios
  if ("trend" %in% goals && !is.null(pu) && !is.null(gt$trend)) {
    k <- which(vapply(spec$factors, function(f) identical(f$name, terms[[gt$trend]]), logical(1)))[1]
    if (!is.na(k)) {
      f <- spec$factors[[k]]
      if (identical(pu$per, "linear") && identical(f$scale, "log")) {
        f$scale <- "linear"; f$log_base <- NULL; f$log_offset <- NULL
        spec$assumptions[[paste0("factors.", f$name, ".scale")]] <- "linear: the stated change is per unit, not per fold"
      }
      pu$per_unit <- if (identical(f$scale, "log")) paste("log10", f$unit %||% "") else f$unit
      spec$factors[[k]] <- f
    }
  }
  src <- list(minimum_detectable_difference = spec$power$minimum_detectable_difference, per_unit_effect = pu$size)
  ge <- list()
  for (g in goals) {
    sf <- reg[[g]]$size_from %||% "minimum_detectable_difference"
    e <- list(size = src[[sf]], scale = .sf_effect_scale(spec), definition = reg[[g]]$effect_definition)
    if (identical(g, "time_course")) e <- c(e, .sf_resolve_group(spec, spec$analysis$time_course %||% list()))
    if (identical(g, "trend") && !is.null(pu$per_unit)) e$per_unit <- trimws(pu$per_unit)
    ge[[g]] <- e[!vapply(e, is.null, logical(1))]
    if (is.null(src[[sf]])) spec$assumptions[[paste0("analysis.goal_effect.", g, ".size")]] <-
      if (sf == "per_unit_effect") "not stated: use the treatment effect over the factor's range" else "not stated: use power.minimum_detectable_difference default"
  }
  spec$analysis$per_unit_effect <- NULL
  spec$analysis$goal_effect <- ge
  spec$analysis$time_course <- NULL
  # replicate sweep sized for the primary goal
  m <- reg[[goals[1]]]$replicate_multiplier %||% 1
  spec$power$goal <- goals[1]
  if (m > 1 && length(spec$power$reps_range) == 2) {
    spec$power$reps_range <- list(spec$power$reps_range[[1]], as.integer(spec$power$reps_range[[2]] * m))
    spec$power$reps_note <- sprintf("upper end x%g for %s (registry replicate_multiplier)", m, goals[1])
  } else if (m > 1 && !is.null(spec$design$reps))
    spec$power$reps_note <- sprintf("%s needs about %gx the replicates of a main effect of the same size; %s replicates were stated",
      goals[1], m, spec$design$reps)
  spec
}
