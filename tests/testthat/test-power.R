test_that("RCBD power is near alpha under the null", {
  p <- power_rcbd(4, 4, delta = 0, sd = 1, nsim = 800, seed = 11)
  expect_lt(abs(p$power - 0.05), 0.03)
})

test_that("RCBD power increases with blocks and effect size", {
  small <- power_rcbd(4, 3, delta = 1.5, sd = 1, nsim = 400, seed = 2)$power
  big <- power_rcbd(4, 8, delta = 1.5, sd = 1, nsim = 400, seed = 2)$power
  expect_gt(big, small)
  expect_gt(power_rcbd(4, 4, delta = 3, sd = 1, nsim = 300)$power,
            power_rcbd(4, 4, delta = 1, sd = 1, nsim = 300)$power)
})

test_that("RCBD power is reproducible given a seed", {
  expect_identical(power_rcbd(3, 4, 1, 1, nsim = 100, seed = 5)$power,
                   power_rcbd(3, 4, 1, 1, nsim = 100, seed = 5)$power)
})

test_that("split-plot: whole-plot factor has less power than subplot factor", {
  main <- power_split_plot(2, 6, 4, delta = 1.5, effect = "main",
                           sd_whole = 1, sd_sub = 1, nsim = 200, seed = 3)$power
  sub <- power_split_plot(2, 6, 4, delta = 1.5, effect = "sub",
                          sd_whole = 1, sd_sub = 1, nsim = 200, seed = 3)$power
  expect_lt(main, sub)
})

test_that("split-plot holds alpha for the whole-plot test", {
  p <- power_split_plot(3, 4, 4, delta = 0, effect = "main",
                        sd_whole = 1, sd_sub = 1, nsim = 600, seed = 4)$power
  expect_lt(abs(p - 0.05), 0.035)
})

test_that("split-plot interaction effect runs", {
  p <- power_split_plot(2, 3, 4, delta = 2, effect = "interaction",
                        sd_whole = 0.5, sd_sub = 1, nsim = 100)
  expect_true(p$power >= 0 && p$power <= 1)
  expect_equal(p$settings$effect, "interaction")
})

test_that("alpha-lattice beats RCBD analysis when incomplete blocks vary", {
  skip_if_not_installed("lme4")
  a <- power_alpha_lattice(n_trt = 30, block_size = 5, reps = 2, delta = 1.5,
                           sd = 0.5, block_sd = 1, nsim = 60, seed = 7)
  expect_gte(a$power, a$power_if_analysed_as_rcbd)
  expect_gt(a$residual_df, 0)
})

test_that("alpha-lattice rejects block sizes that don't divide n_trt", {
  expect_error(power_alpha_lattice(30, 7, 2, 1, 1, 1, nsim = 5), "divisible")
})

test_that("simr wrapper estimates power for a litter-structured design", {
  skip_if_not_installed("simr")
  d <- expand.grid(pup = 1:4, litter = factor(1:16))
  d$trt <- factor(ifelse(as.integer(d$litter) %% 2 == 0, "trt", "ctrl"))
  d$sex <- factor(rep(c("F", "M"), length.out = nrow(d)))
  r <- power_mixed_simr(y ~ trt * sex + (1 | litter), d,
                        fixef = c(0, 1.5, 0, 0), var_corr = list(0.5), sigma = 1,
                        test_term = "trttrt", nsim = 20, seed = 1)
  expect_true(r$power > 0 && r$power <= 1)
  expect_error(power_mixed_simr(y ~ trt * sex + (1 | litter), d,
                                fixef = c(0, 1.5, 0, 0), var_corr = list(0.5), sigma = 1,
                                test_term = "trttrt", method = "lr", nsim = 3),
               "All simr simulations failed")
})

test_that("power_sensitivity varies one argument", {
  s <- power_sensitivity(power_rcbd, "n_blocks", c(3, 6),
                         n_trt = 3, delta = 1, sd = 1, nsim = 100)
  expect_equal(nrow(s), 2)
  expect_named(s, c("n_blocks", "power", "mcse"))
})
