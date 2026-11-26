test_that("every design-catalog model is a formula lm/lmer can fit, using only the generic terms", {
  skip_if_not_installed("lme4")
  cat <- load_registry("design_catalog")
  terms <- unlist(cat$model_terms$terms)
  set.seed(1); n <- 480
  f <- function(k) factor(sample(seq_len(k), n, TRUE))
  d <- data.frame(treatment = f(4), treatment2 = f(3), block = f(8), rep = f(4), row = f(10), col = f(12),
                  unit = f(40), subject = f(30), time = f(4), env = f(3), period = f(2), sequence = f(2), check = f(2))
  d$covariate <- rnorm(n); d$covariate2 <- rnorm(n); d$covariate3 <- rnorm(n)
  d$y <- rnorm(n)
  num <- transform(d, treatment = as.numeric(treatment), treatment2 = as.numeric(treatment2))
  ids <- vapply(cat$designs, `[[`, "", "id")
  expect_equal(anyDuplicated(ids), 0L)
  for (x in cat$designs) {
    fm <- stats::as.formula(x$model)
    expect_true(all(all.vars(fm) %in% terms), info = x$id)
    dat <- if (grepl("\\^2", x$model)) num else d
    fit <- tryCatch(if (length(lme4::findbars(fm))) suppressMessages(lme4::lmer(fm, dat)) else stats::lm(fm, dat),
                    error = function(e) e)
    expect_false(inherits(fit, "error"), info = x$id)
  }
})
