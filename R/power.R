# All power functions are simulation-based and deterministic given `seed`.
# They return a list: power, mcse (Monte Carlo SE), and the settings used,
# so the agent can report exactly what was assumed.

.power_result <- function(hits, settings, extra = list()) {
  hits <- hits[!is.na(hits)]
  p <- mean(hits)
  c(list(power = p,
         mcse = sqrt(p * (1 - p) / length(hits)),
         nsim_ok = length(hits)),
    extra,
    list(settings = settings))
}

#' Power for a one-way treatment test in an RCBD
#'
#' @param n_trt Number of treatments.
#' @param n_blocks Number of complete blocks.
#' @param delta Difference of one treatment from all others (outcome units).
#' @param sd Residual (plot-level) SD.
#' @param block_sd SD of block effects.
#' @param alpha Significance level.
#' @param nsim Number of simulations.
#' @param seed RNG seed.
#' @export
power_rcbd <- function(n_trt, n_blocks, delta, sd, block_sd = 0,
                       alpha = 0.05, nsim = 1000, seed = 1) {
  stopifnot(n_trt >= 2, n_blocks >= 2, sd > 0)
  set.seed(seed)
  d <- expand.grid(trt = factor(seq_len(n_trt)), block = factor(seq_len(n_blocks)))
  shift <- ifelse(d$trt == "1", delta, 0)
  hits <- replicate(nsim, {
    d$y <- shift + stats::rnorm(n_blocks, 0, block_sd)[d$block] +
      stats::rnorm(nrow(d), 0, sd)
    stats::anova(stats::lm(y ~ block + trt, data = d))["trt", "Pr(>F)"] < alpha
  })
  .power_result(hits, list(design = "rcbd", n_trt = n_trt, n_blocks = n_blocks,
                           delta = delta, sd = sd, block_sd = block_sd,
                           alpha = alpha, nsim = nsim, seed = seed))
}

#' Power for a split-plot design (whole plots in RCBD)
#'
#' Simulates y = block + main + whole-plot error + sub + main:sub + residual,
#' and analyses with the correct split-plot error strata.
#'
#' @param n_main Levels of the whole-plot factor (e.g. irrigation).
#' @param n_sub Levels of the subplot factor (e.g. genotype).
#' @param n_blocks Number of blocks.
#' @param delta Effect size: shift of level 1 of the tested effect.
#' @param effect One of "main", "sub", "interaction".
#' @param sd_whole SD of whole-plot error (block:main).
#' @param sd_sub Residual (subplot) SD.
#' @param block_sd SD of block effects.
#' @inheritParams power_rcbd
#' @export
power_split_plot <- function(n_main, n_sub, n_blocks, delta,
                             effect = c("main", "sub", "interaction"),
                             sd_whole, sd_sub, block_sd = 0,
                             alpha = 0.05, nsim = 500, seed = 1) {
  effect <- match.arg(effect)
  stopifnot(n_main >= 2, n_sub >= 2, n_blocks >= 2, sd_sub > 0, sd_whole >= 0)
  set.seed(seed)
  d <- expand.grid(sub = factor(seq_len(n_sub)), main = factor(seq_len(n_main)),
                   block = factor(seq_len(n_blocks)))
  d$wp <- interaction(d$block, d$main, drop = TRUE)
  shift <- switch(effect,
    main = ifelse(d$main == "1", delta, 0),
    sub = ifelse(d$sub == "1", delta, 0),
    interaction = ifelse(d$main == "1" & d$sub == "1", delta, 0))
  term <- switch(effect, main = "main", sub = "sub", interaction = "main:sub")
  stratum <- if (effect == "main") "Error: block:main" else "Error: Within"

  hits <- replicate(nsim, {
    d$y <- shift +
      stats::rnorm(n_blocks, 0, block_sd)[d$block] +
      stats::rnorm(nlevels(d$wp), 0, sd_whole)[d$wp] +
      stats::rnorm(nrow(d), 0, sd_sub)
    fit <- summary(stats::aov(y ~ main * sub + Error(block / main), data = d))
    tab <- fit[[stratum]][[1]]
    rn <- trimws(rownames(tab))
    tab[rn == term, "Pr(>F)"] < alpha
  })
  .power_result(hits, list(design = "split", effect = effect, n_main = n_main,
                           n_sub = n_sub, n_blocks = n_blocks, delta = delta,
                           sd_whole = sd_whole, sd_sub = sd_sub, block_sd = block_sd,
                           alpha = alpha, nsim = nsim, seed = seed))
}

#' Power to detect a pairwise genotype difference in an alpha-lattice
#'
#' Generates an alpha-lattice layout with agricolae, simulates incomplete-block
#' effects, fits the intra-block mixed model y ~ genotype + rep + (1 | rep:block)
#' with lme4, and tests the contrast between two entries. Also reports power of
#' the same data analysed as an RCBD (ignoring incomplete blocks), which shows
#' what the incomplete blocks buy you.
#'
#' @param n_trt Number of entries (must be divisible by block_size).
#' @param block_size Plots per incomplete block (k).
#' @param reps Number of replicates (>= 2).
#' @param delta Difference between the two compared entries.
#' @param sd Residual SD.
#' @param block_sd SD of incomplete-block effects.
#' @inheritParams power_rcbd
#' @export
power_alpha_lattice <- function(n_trt, block_size, reps, delta, sd, block_sd,
                                alpha = 0.05, nsim = 200, seed = 1) {
  if (!requireNamespace("lme4", quietly = TRUE)) stop("Install lme4.", call. = FALSE)
  if (n_trt %% block_size != 0) {
    stop("n_trt (", n_trt, ") must be divisible by block_size (", block_size, ").", call. = FALSE)
  }
  book <- make_design("alpha", treatments = paste0("G", seq_len(n_trt)),
                      reps = reps, block_size = block_size, seed = seed)
  book$geno <- factor(book$treatment, levels = paste0("G", seq_len(n_trt)))
  book$rep <- factor(book$rep)
  book$iblock <- interaction(book$rep, book$block, drop = TRUE)
  shift <- ifelse(book$geno == "G2", delta, 0)
  df_res <- nrow(book) - n_trt - nlevels(book$iblock) + 1
  if (df_res < 1) stop("Not enough residual df; increase reps.", call. = FALSE)

  set.seed(seed)
  res <- t(replicate(nsim, {
    book$y <- shift + stats::rnorm(nlevels(book$iblock), 0, block_sd)[book$iblock] +
      stats::rnorm(nrow(book), 0, sd)
    fit <- suppressMessages(suppressWarnings(
      lme4::lmer(y ~ geno + rep + (1 | iblock), data = book)))
    est <- lme4::fixef(fit)[["genoG2"]]
    se <- sqrt(as.matrix(stats::vcov(fit))["genoG2", "genoG2"])
    p_alpha <- 2 * stats::pt(-abs(est / se), df_res)
    p_rcbd <- summary(stats::lm(y ~ geno + rep, data = book))$coefficients["genoG2", 4]
    c(alpha = p_alpha < alpha, rcbd = p_rcbd < alpha, sed = se)
  }))
  .power_result(res[, "alpha"],
                list(design = "alpha", n_trt = n_trt, block_size = block_size,
                     reps = reps, delta = delta, sd = sd, block_sd = block_sd,
                     alpha = alpha, nsim = nsim, seed = seed),
                extra = list(power_if_analysed_as_rcbd = mean(res[, "rcbd"]),
                             mean_sed = mean(res[, "sed"]),
                             residual_df = df_res))
}

#' Generic mixed-model power via simr
#'
#' Builds an artificial lmer model with \code{simr::makeLmer} and runs
#' \code{simr::powerSim}. Use for designs not covered by the specific helpers,
#' e.g. treatment x sex with (1 | litter).
#'
#' @param formula Model formula with random effects, e.g. y ~ trt * sex + (1 | litter).
#' @param data Design data frame (covariates only; no response needed).
#' @param fixef Named numeric vector of fixed effects, in model-matrix order.
#' @param var_corr Variance(s) of random effects (list or numeric, see simr::makeLmer).
#' @param sigma Residual SD.
#' @param test_term Coefficient to test, as named in the model matrix (e.g.
#'   "trttrt") for method "t"/"z"; a term label for "lr".
#' @param method Test method passed to simr::fixed(); "t" uses Satterthwaite df.
#' @inheritParams power_rcbd
#' @export
power_mixed_simr <- function(formula, data, fixef, var_corr, sigma, test_term,
                             method = "t", alpha = 0.05, nsim = 100, seed = 1) {
  if (!requireNamespace("simr", quietly = TRUE)) stop("Install simr.", call. = FALSE)
  model <- simr::makeLmer(formula, fixef = fixef, VarCorr = var_corr,
                          sigma = sigma, data = data)
  ps <- simr::powerSim(model, test = simr::fixed(test_term, method),
                       nsim = nsim, alpha = alpha, seed = seed, progress = FALSE)
  s <- summary(ps)
  errs <- unique(ps$errors$message)
  if (length(errs) && nrow(ps$errors) >= nsim) {
    stop("All simr simulations failed: ", paste(errs, collapse = "; "),
         ". For method = 't' or 'z', test_term is a coefficient name (e.g. 'trttrt'); ",
         "for 'lr' it is a term label.", call. = FALSE)
  }
  list(power = s$mean, lower = s$lower, upper = s$upper, nsim_ok = s$trials,
       errors = errs,
       settings = list(design = "mixed_simr", formula = deparse(formula),
                       test_term = test_term, method = method, sigma = sigma,
                       alpha = alpha, nsim = nsim, seed = seed))
}

#' Power sensitivity table: vary one argument of a power function
#'
#' @param fun A power function, e.g. power_rcbd.
#' @param vary Name of the argument to vary.
#' @param values Values to try.
#' @param ... Fixed arguments passed to fun.
#' @return data.frame with the varied value, power and MCSE.
#' @export
power_sensitivity <- function(fun, vary, values, ...) {
  rows <- lapply(values, function(v) {
    args <- list(...)
    args[[vary]] <- v
    r <- do.call(fun, args)
    data.frame(value = v, power = r$power,
               mcse = if (is.null(r$mcse)) NA_real_ else r$mcse)
  })
  out <- do.call(rbind, rows)
  names(out)[1] <- vary
  out
}
