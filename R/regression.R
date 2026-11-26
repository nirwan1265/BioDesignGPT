# Measured predictors (covariates), regression and ANCOVA, robust tests, and a-priori power (pwr), read from the
# question (Bioana 0.13.0 contract docs/contracts/regression.md). Patterns and words are in rules.tsv (cues cov_*,
# reg_*, robust_*, pwr_*; categories covariate_transform, power_source, stat_test_id).

# a list item as a covariate: name, unit in brackets or after "in", transform written as log(x), log-transformed x
# a name ends before a phrase that starts with a number or an article ("screen of 90 rice lines in a growth chamber")
.sf_trim_name <- function(x) trimws(sub("\\s+(?:of|in|on|at|from|across|among|for|under|with)\\s+(?:\\d|an?\\s|the\\s).*$", "", x, perl = TRUE))

.sf_covariate_item <- function(x) {
  x <- .sf_trim_name(trimws(sub("^(?:the|their|its|a|an)\\s+", "", tolower(x), perl = TRUE)))
  unit <- NULL; tr <- NULL; st <- list()
  # summary values in brackets ("(mean 100, SD 15 mg/dL)") are not a unit: read them, keep any unit after them
  m <- regmatches(x, regexec("\\(([^)]*)\\)", x))[[1]]
  if (length(m) && length(.sf_grab(m[2], "cov_mean")) + length(.sf_grab(m[2], "cov_sd")) > 0) {
    st <- .sf_cov_stats(m[2]); x <- trimws(sub("\\([^)]*\\)", "", x))
    if (!is.null(st$unit)) unit <- st$unit
  }
  # a transform written as a function, log(plant age): the brackets hold the name, not a unit
  r <- .sf_rules_rows("covariate_transform")
  m <- regmatches(x, regexec("^([a-z0-9]+)\\s*\\(([^)]+)\\)(.*)$", x, perl = TRUE))[[1]]
  if (length(m)) {
    k <- which(vapply(r$pattern, grepl, logical(1), x = paste0(m[2], "("), perl = TRUE))
    if (length(k)) { tr <- r$term[k[1]]; x <- trimws(paste(m[3], m[4])) }
  }
  m <- regmatches(x, regexec("\\(([^)]+)\\)", x))[[1]]; if (length(m)) { unit <- trimws(m[2]); x <- trimws(sub("\\([^)]*\\)", "", x)) }
  m <- regmatches(x, regexec("\\s+in\\s+([a-z/%0-9]+)$", x, perl = TRUE))[[1]]; if (length(m)) { unit <- m[2]; x <- trimws(sub("\\s+in\\s+[a-z/%0-9]+$", "", x, perl = TRUE)) }
  if (is.null(tr)) for (i in seq_len(NROW(r))) if (grepl(r$pattern[i], x, perl = TRUE)) { tr <- r$term[i]; x <- trimws(gsub(r$pattern[i], "", x, perl = TRUE)); break }
  x <- trimws(gsub("[()]", "", x))
  if (!nzchar(x)) return(NULL)
  list(name = x, column = .sf_snake(x), unit = unit, transform = tr, mean = st$mean, sd = st$sd)
}

# a stated mean and SD of a covariate (cues cov_mean, cov_sd), and a unit written with them
.sf_cov_stats <- function(x) {
  out <- list()
  g <- .sf_grab(x, "cov_mean"); if (length(g)) { out$mean <- as.numeric(g[2]); if (length(g) >= 3 && nzchar(g[3])) out$unit <- g[3] }
  g <- .sf_grab(x, "cov_sd"); if (length(g)) { out$sd <- as.numeric(g[2]); if (is.null(out$unit) && length(g) >= 3 && nzchar(g[3])) out$unit <- g[3] }
  out
}

.sf_regression_from_text <- function(text) {
  t <- tolower(text); out <- list(covariates = list())
  add <- function(items) for (it in .sf_split_list(items)) {
    # a relative clause ("which averages 250 g with an SD of 20") describes the item before it
    if (grepl("^(?:which|that|who|whose|with)\\b", trimws(it), perl = TRUE)) {
      k <- length(out$covariates)
      if (k) { st <- .sf_cov_stats(it); for (nm in names(st)) if (is.null(out$covariates[[k]][[if (nm == "unit") "unit" else nm]])) out$covariates[[k]][[nm]] <<- st[[nm]] }
      next
    }
    c <- .sf_covariate_item(it); if (!is.null(c)) out$covariates[[length(out$covariates) + 1]] <<- c }
  g <- .sf_grab(t, "cov_regress"); if (length(g)) { out$outcome <- g[2]; add(g[3]); out$asked <- TRUE }
  g <- .sf_grab(t, "cov_predict"); if (length(g)) { add(g[2]); out$outcome <- out$outcome %||% g[3]; out$asked <- TRUE }
  g <- .sf_grab(t, "cov_function_of"); if (length(g)) { out$outcome <- out$outcome %||% g[2]; add(g[3]); out$asked <- TRUE }
  g <- .sf_grab(t, "cov_adjust"); if (length(g)) add(g[2])
  g <- .sf_grab(t, "cov_baseline"); if (length(g)) add(paste(g[2], g[3]))
  # categorical predictors stay factors ("adjusting for sex"): drop items that are factor words
  fw <- tolower(.sf_list("categorical_predictor"))
  keep <- vapply(out$covariates, function(c) !(c$name %in% fw), logical(1))
  # categorical words after "adjusting for" are adjustment factors: additive in the model, not crossed
  out$adjust <- unique(vapply(out$covariates[!keep], `[[`, "", "name"))
  out$covariates <- out$covariates[keep]
  # same covariate named twice: keep the first
  out$covariates <- out$covariates[!duplicated(vapply(out$covariates, `[[`, "", "column"))]
  if (length(.sf_grab(t, "cov_interaction"))) out$interaction <- TRUE
  g <- .sf_grab(t, "reg_predict_at"); if (length(g)) out$predict_at <- stats::setNames(list(as.numeric(g[3])), .sf_snake(g[2]))
  if (length(.sf_grab(t, "reg_robust"))) out$robust <- "mm"
  out
}

.sf_apply_regression <- function(spec, text) {
  x <- .sf_regression_from_text(text)
  t <- tolower(text)
  # robust tests and robust correlation are asked by name (rules.tsv stat_test_id, cue robust_test)
  r <- .sf_rules_rows("stat_test_id"); ids <- r$term[vapply(r$pattern, grepl, logical(1), x = t, perl = TRUE)]
  if (!length(ids) && length(.sf_grab(t, "robust_test"))) ids <- "robust"
  if (length(ids)) spec$analysis$stat_tests <- unique(c(unlist(spec$analysis$stat_tests), ids))
  if (length(x$adjust)) {
    fn <- unique(unlist(lapply(x$adjust, function(w) c(.sf_find_all(w, "factor"), sub("s$", "", w)))))
    spec$analysis$sf_adjust_factors <- intersect(fn, vapply(spec$factors %||% list(), function(f) f$name %||% "", ""))
  }
  if (!length(x$covariates)) return(spec)
  # covariates and no stated blocks: completely randomized (as for survival); replicate "blocks" of two units are not blocks
  if (!grepl(.sf_cue("blocks_stated"), t, perl = TRUE) && is.null(spec$design$type) && is.null(spec$design$chosen)) {
    spec$design$candidates <- unique(c("crd", unlist(spec$design$candidates)))
    spec$assumptions[["design.candidates"]] <- "crd first: covariates (ANCOVA/regression) with no stated blocks"
  }
  cv <- lapply(seq_along(x$covariates), function(i) {
    c <- x$covariates[[i]]; c$term <- if (i == 1) "covariate" else paste0("covariate", i)
    k <- c("term", "name", "column", "unit", "transform", "mean", "sd")
    c[k][!vapply(c[k], is.null, logical(1))]
  })
  spec$analysis$covariates <- cv
  # a factor named only inside a covariate ("soil nitrogen" -> nitrogen) is that measured covariate, not a factor
  rest <- t; for (c in cv) rest <- gsub(c$name, " ", rest, fixed = TRUE)
  catp <- tolower(.sf_list("categorical_predictor"))
  keep <- vapply(spec$factors %||% list(), function(f) length(f$levels) > 0 || f$name %in% catp || !(f$name %in% .sf_find_all(paste(vapply(cv, `[[`, "", "name"), collapse = " "), "factor")) ||
    f$name %in% .sf_find_all(rest, "factor"), logical(1))
  if (any(!keep)) {
    spec$assumptions[["factors.covariate_words"]] <- sprintf("removed %s: named only as a measured covariate", paste(vapply(spec$factors[!keep], `[[`, "", "name"), collapse = ", "))
    spec$factors <- spec$factors[keep]
  }
  # the outcome named by regression wording only in a pure regression (nothing randomized); otherwise the main
  # outcome reader decides
  rand0 <- Filter(function(f) !(f$name %in% .sf_within_factors(spec)), spec$factors %||% list())
  if (!is.null(x$outcome) && is.null(spec$primary_outcome$name) && !length(rand0)) {
    y <- gsub(tryCatch(.sf_cue("outcome_yes_no"), error = function(e) "(?!)"), " ", x$outcome, perl = TRUE)   # "germination yes or no"
    spec$primary_outcome$name <- .sf_snake(.sf_trim_name(sub("^(?:the|their)\\s+", "", trimws(y))))
  }
  if (isTRUE(x$asked)) spec$analysis$goals <- unique(c("regression", unlist(spec$analysis$goals)))
  opt <- list(predict_at = if (!is.null(x$predict_at)) list(x$predict_at), robust = x$robust)
  opt <- opt[!vapply(opt, is.null, logical(1))]
  if (length(opt)) spec$analysis$regression <- opt
  if (isTRUE(x$interaction)) spec$analysis$sf_cov_interaction <- TRUE
  # nothing randomized: the number of units ("in 120 plots") is the sample size (cue group_size)
  rand <- Filter(function(f) !(f$name %in% .sf_within_factors(spec)), spec$factors %||% list())
  if (!length(rand) && is.null(spec$design$reps)) {
    g <- .sf_grab(t, "group_size")
    if (length(g)) { n <- .sf_num(g[-1][nzchar(g[-1])][1]); if (!is.na(n) && n >= 2) spec$design$reps <- n }
  }
  spec
}

# at write time: covariates go into the model (regression: covariates only; ANCOVA: + covariate), the goal's terms
# and scale
.sf_fill_regression <- function(spec, ge, pu = NULL) {
  cv <- spec$analysis$covariates
  inter <- isTRUE(spec$analysis$sf_cov_interaction); spec$analysis$sf_cov_interaction <- NULL
  # adjustment factors ("adjusting for sex") enter additively: "a * b" -> "a + b" for their terms
  adj <- unlist(spec$analysis$sf_adjust_factors); spec$analysis$sf_adjust_factors <- NULL
  terms <- spec$analysis$terms %||% list()
  for (a in adj) {
    tm <- names(terms)[vapply(terms, function(v) identical(unlist(v), a), logical(1))]
    for (t1 in tm) spec$analysis$model <- gsub(sprintf("\\b(\\w+)\\s*\\*\\s*%s\\b|\\b%s\\s*\\*\\s*(\\w+)\\b", t1, t1),
      sprintf("\\1\\2 + %s", t1), spec$analysis$model, perl = TRUE)
    if (length(tm)) spec$analysis$note <- trimws(paste(spec$analysis$note %||% "", sprintf("%s is an adjustment factor (additive, not crossed).", a)))
  }
  if (!length(cv)) return(list(spec = spec, ge = ge))
  tm <- vapply(cv, `[[`, "", "term")
  model <- spec$analysis$model %||% "y ~ 1"
  has_trt <- grepl("\\btreatment\\b", model)
  rhs <- if (inter && has_trt) paste("treatment *", tm[1]) else if (inter && length(tm) >= 2) paste(tm[1], "*", tm[2]) else NULL
  add <- setdiff(tm, all.vars(stats::as.formula(model)))
  if (identical(spec$design$chosen, "regression") || !has_trt) {
    spec$analysis$model <- paste("y ~", rhs %||% paste(tm, collapse = " + "),
      if (!is.null(rhs) && length(tm) > 2) paste("+", paste(tm[-(1:2)], collapse = " + ")) else "")
    spec$analysis$model <- trimws(spec$analysis$model)
  } else {
    base <- if (!is.null(rhs)) sub("\\btreatment\\b", rhs, model) else model
    rest <- setdiff(add, if (!is.null(rhs)) tm[1] else character())
    spec$analysis$model <- if (length(rest)) paste(base, "+", paste(rest, collapse = " + ")) else base
  }
  spec$analysis$note <- trimws(paste(spec$analysis$note %||% "", sprintf("Covariates (one value per unit, sample metadata columns): %s.",
    paste(sprintf("%s = %s", tm, vapply(cv, `[[`, "", "column")), collapse = ", "))))
  if ("regression" %in% unlist(spec$analysis$goals)) {
    spec$analysis$goal_terms$regression <- as.list(tm)
    e <- ge$regression %||% list()
    e$scale <- if (identical(spec$primary_outcome$type, "binary")) "odds_ratio_per_unit" else "per_unit"
    e$definition <- if (e$scale == "per_unit") "slope: change in y per unit of the (transformed) covariate" else "odds ratio per unit of the (transformed) covariate"
    e$size <- pu$size   # a stated change per unit ("2 mg/dL per year"), else absent
    ge$regression <- e[!vapply(e, is.null, logical(1))]
  }
  list(spec = spec, ge = ge)
}

# ---- a-priori power (pwr), before any data: method from the design, effect size stated or Cohen's convention ----
.sf_pwr_effect <- function(t, name) {
  g <- .sf_grab(t, paste0("pwr_", name)); if (length(g)) as.numeric(g[-1][nzchar(g[-1])][1]) else NULL
}

.sf_apriori_power <- function(spec, text = NULL) {
  if (!requireNamespace("pwr", quietly = TRUE)) return(spec)
  if (identical(spec$primary_outcome$type, "survival")) return(spec)   # events (Schoenfeld) instead
  ytype <- spec$primary_outcome$type %||% "continuous"
  t <- tolower(text %||% spec$sf_question %||% "")
  pw <- spec$power %||% list()
  alpha <- pw$alpha %||% .sf_pwr_effect(t, "alpha") %||% 0.05
  target <- .sf_pwr_effect(t, "target") %||% 0.8; if (target > 1) target <- target / 100
  src <- function(stated) {
    if (!stated) return("Cohen's convention")
    r <- .sf_rules_rows("power_source"); k <- which(vapply(r$pattern, grepl, logical(1), x = t, perl = TRUE))
    if (length(k)) r$term[k[1]] else "stated"
  }
  out <- NULL
  k_levels <- function() { f <- Filter(function(f) !(f$name %in% .sf_within_factors(spec)), spec$factors %||% list())
    if (length(f) == 1) as.numeric(f[[1]]$n_levels %||% length(f[[1]]$levels)) else NA }
  if (!is.null(spec$analysis$correlation)) {
    r <- .sf_pwr_effect(t, "r"); es <- r %||% 0.3
    n <- pwr::pwr.r.test(r = es, sig.level = alpha, power = target)$n
    out <- list(method = "pwr.r.test", effect_size_name = "r", effect_size = es, n_total = ceiling(n), source = src(!is.null(r)))
  } else if ("regression" %in% unlist(spec$analysis$goals) && length(spec$analysis$covariates) && identical(ytype, "binary")) {
    # logistic regression: pwr has no closed form; power is checked by simulation (Simitall)
    spec$assumptions[["power.method"]] <- "logistic regression: a-priori power by simulation (pwr has no method); state the odds ratio per unit to plant"
    return(spec)
  } else if ("regression" %in% unlist(spec$analysis$goals) && length(spec$analysis$covariates)) {
    u <- length(spec$analysis$covariates)
    f2 <- .sf_pwr_effect(t, "f2"); r2 <- .sf_pwr_effect(t, "r2")
    es <- f2 %||% (if (!is.null(r2)) r2 / (1 - r2)) %||% 0.15
    v <- pwr::pwr.f2.test(u = u, f2 = es, sig.level = alpha, power = target)$v
    out <- list(method = "pwr.f2.test", effect_size_name = "f2", effect_size = round(es, 4), u = u, n_total = ceiling(v) + u + 1,
                source = src(!is.null(f2) || !is.null(r2)))
  } else if (!is.null(spec$analysis$expected_ratio)) {
    w <- .sf_pwr_effect(t, "w"); es <- w %||% 0.3; df <- length(spec$analysis$expected_ratio) - 1
    n <- pwr::pwr.chisq.test(w = es, df = df, sig.level = alpha, power = target)$N
    out <- list(method = "pwr.chisq.test", effect_size_name = "w", effect_size = es, df = df, n_total = ceiling(n), source = src(!is.null(w)))
  } else if (!is.na(k <- k_levels()) && k >= 2) {
    if (identical(ytype, "binary") && k == 2) {
      p <- .sf_grab(t, "pwr_proportions")
      es <- if (length(p)) { pp <- as.numeric(p[-1][nzchar(p[-1])][1:2]); pp <- ifelse(pp > 1, pp / 100, pp); abs(pwr::ES.h(pp[1], pp[2])) } else 0.5
      n <- pwr::pwr.2p.test(h = es, sig.level = alpha, power = target)$n
      out <- list(method = "pwr.2p.test", effect_size_name = "h", effect_size = round(es, 4), n_per_group = ceiling(n), source = src(length(p) > 0))
    } else if (k == 2 && !ytype %in% c("binary", "nominal", "ordinal", "count")) {
      d <- .sf_pwr_effect(t, "d")
      mdd <- spec$power$minimum_detectable_difference; sd <- spec$power$residual_sd
      es <- d %||% (if (!is.null(mdd) && !is.null(sd) && sd > 0) mdd / sd) %||% 0.5
      n <- pwr::pwr.t.test(d = es, sig.level = alpha, power = target, type = "two.sample")$n
      out <- list(method = "pwr.t.test", effect_size_name = "d", effect_size = round(es, 4), n_per_group = ceiling(n),
                  source = src(!is.null(d) || (!is.null(mdd) && !is.null(sd))))
    } else if (k > 2 && !ytype %in% c("binary", "nominal", "ordinal", "count")) {
      f <- .sf_pwr_effect(t, "f"); es <- f %||% 0.25
      n <- pwr::pwr.anova.test(k = k, f = es, sig.level = alpha, power = target)$n
      out <- list(method = "pwr.anova.test", effect_size_name = "f", effect_size = es, k = k, n_per_group = ceiling(n), source = src(!is.null(f)))
    }
  }
  if (is.null(out)) return(spec)
  out$alpha <- alpha; out$power <- target
  # written straight into power (Bioana contract): n is per group or total as named
  spec$power <- utils::modifyList(spec$power %||% list(), out)
  spec
}
