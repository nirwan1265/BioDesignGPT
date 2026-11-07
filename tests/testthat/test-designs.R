trt <- paste0("G", 1:12)

test_that("RCBD has each treatment once per block", {
  b <- make_design("rcbd", trt, reps = 3, seed = 1)
  expect_equal(nrow(b), 36)
  expect_true(all(table(b$block, b$treatment) == 1))
  expect_equal(attr(b, "seed"), 1)
})

test_that("CRD has the right replication", {
  b <- make_design("crd", trt, reps = 2)
  expect_true(all(table(b$treatment) == 2))
})

test_that("alpha-lattice: each entry once per rep, blocks of size k", {
  b <- make_design("alpha", trt, reps = 2, block_size = 3, seed = 1)
  expect_equal(nrow(b), 24)
  expect_true(all(table(b$rep, b$treatment) == 1))
  expect_true(all(table(interaction(b$rep, b$block, drop = TRUE)) == 3))
})

test_that("alpha-lattice gives helpful errors", {
  expect_error(make_design("alpha", trt, reps = 2, block_size = 5), "Try block_size")
  expect_error(make_design("alpha", trt, reps = 2), "block_size")
  expect_error(make_design("alpha", trt, reps = 2, block_size = 4), "could not build")
})

test_that("split-plot keeps the whole-plot factor constant within a main plot", {
  b <- make_design("split", c("WW", "WS"), reps = 3, treatments2 = c("A", "B", "C"), seed = 2)
  expect_equal(nrow(b), 2 * 3 * 3)
  per_plot <- tapply(b$main, b$plot, function(x) length(unique(x)))
  expect_true(all(per_plot == 1))
  expect_true(all(table(b$plot) == 3))
  expect_error(make_design("split", c("WW", "WS"), reps = 2), "treatments2")
})

test_that("factorial maps level names and crosses all combinations", {
  b <- make_design("factorial", reps = 2,
                   factor_levels = list(water = c("WW", "WS"), genotype = c("A", "B", "C")))
  expect_equal(nrow(b), 12)
  expect_setequal(unique(b$water), c("WW", "WS"))
  expect_true(all(table(b$block, b$treatment) == 1))
})

test_that("augmented design repeats checks in every block", {
  b <- make_design("augmented", paste0("N", 1:10), reps = 3, checks = c("C1", "C2"))
  expect_equal(sum(!b$is_check), 10)
  expect_true(all(table(b$block[b$is_check]) == 2))
})

test_that("write_design_package writes the expected files", {
  out <- withr_local_tempdir()
  b <- make_design("rcbd", trt[1:4], reps = 2)
  spec <- spec_set(new_spec(), "system", "field")
  files <- write_design_package(b, spec, out, audit = unit_audit("plant", "plot", "plot"),
                                power = power_rcbd(4, 2, 1, 1, nsim = 20))
  expect_true(all(file.exists(files)))
  s <- jsonlite::read_json(file.path(out, "study_spec.json"))
  expect_equal(s$design$chosen, "rcbd")
  expect_equal(s$design$randomization_seed, 42)
})
