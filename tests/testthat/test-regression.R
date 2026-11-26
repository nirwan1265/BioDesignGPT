pkg_reg <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- fill_layout_defaults(a$spec); s$design$reps <- s$design$reps %||% 4
  d <- file.path(tempdir(), paste0("rg", sample.int(1e6, 1))); write_design_package(layout_from_spec(s, 1), s, d)
  list(j = jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE), m = utils::read.delim(file.path(d, "sample_metadata_template.tsv"))) }

test_that("regression on measured predictors: design, model, covariates, goal, template columns", {
  r <- pkg_reg("In 90 sorghum plots, does soil phosphorus (mg/kg) predict grain yield?")
  expect_equal(r$j$design$chosen, "regression"); expect_equal(r$j$analysis$model, "y ~ covariate")
  cv <- r$j$analysis$covariates[[1]]; expect_equal(cv$term, "covariate"); expect_equal(cv$column, "soil_phosphorus"); expect_equal(cv$unit, "mg/kg")
  expect_equal(unlist(r$j$analysis$goals), "regression"); expect_equal(r$j$analysis$goal_effect$regression$scale, "per_unit")
  expect_equal(nrow(r$m), 90); expect_true("soil_phosphorus" %in% names(r$m)); expect_length(r$j$factors, 0)
  i <- pkg_reg("Regress shoot mass on log(plant age) and temperature in 60 plants; does the effect of age depend on temperature? Predict shoot mass at a temperature of 20.")
  expect_equal(i$j$analysis$model, "y ~ covariate * covariate2"); expect_equal(i$j$analysis$covariates[[1]]$transform, "log")
  expect_equal(i$j$analysis$regression$predict_at[[1]]$temperature, 20)
})

test_that("ANCOVA, logistic scale, robust tests, categorical predictors stay factors", {
  a <- pkg_reg("Rats on two diets, 12 per group, final weight adjusting for sex and baseline weight.")
  expect_match(a$j$analysis$model, "\\+ covariate$"); expect_equal(a$j$analysis$covariates[[1]]$name, "baseline weight")
  l <- pkg_reg("Does seed weight (mg) predict germination yes or no in 120 seeds?")
  expect_equal(l$j$primary_outcome$type, "binary"); expect_equal(l$j$analysis$goal_effect$regression$scale, "odds_ratio_per_unit")
  expect_null(l$j$power$method)
  expect_equal(unlist(studyforge_ask("Four nitrogen rates in 5 blocks, grain yield, compared with trimmed means.", provider = "local")$spec$analysis$stat_tests), "robust")
  expect_null(studyforge_ask("Barley waterlogged vs control for 21 days, 3 biological replicates.", provider = "local")$spec$analysis$covariates)
})

test_that("a-priori power with pwr: method, effect size, source, n per group or total", {
  p <- function(q) studyforge_ask(q, provider = "local")$spec$power
  t2 <- p("Two oat varieties, 8 plots each, grain yield; we expect d = 0.8 from a pilot study.")
  expect_equal(t2$method, "pwr.t.test"); expect_equal(t2$n_per_group, ceiling(pwr::pwr.t.test(d = 0.8, power = 0.8)$n)); expect_equal(t2$source, "pilot")
  an <- p("Four nitrogen rates in 5 blocks, grain yield.")
  expect_equal(an$method, "pwr.anova.test"); expect_equal(an$effect_size, 0.25); expect_equal(an$source, "Cohen's convention")
  pr <- p("Seeds primed or not, germination yes or no, expected to rise from 50% to 70% with priming.")
  expect_equal(pr$method, "pwr.2p.test"); expect_equal(pr$n_per_group, ceiling(pwr::pwr.2p.test(h = abs(pwr::ES.h(0.5, 0.7)), power = 0.8)$n))
  rg <- p("In 90 sorghum plots, does soil phosphorus (mg/kg) predict grain yield? We expect an R2 of 0.2.")
  expect_equal(rg$method, "pwr.f2.test"); expect_equal(rg$effect_size, 0.25); expect_true(rg$n_total > 0)
  cr <- p("Across 40 barley lines in 3 replicates, how do plant height and grain weight relate? Expect a correlation of 0.4.")
  expect_equal(cr$method, "pwr.r.test"); expect_equal(cr$effect_size, 0.4)
})

test_that("covariate mean and SD from brackets or a following clause; brackets stay one item", {
  cv <- function(q) studyforge_ask(q, provider = "local")$spec$analysis$covariates
  a <- cv("In 80 patients, does fasting insulin (mean 12, SD 4 uU/mL) predict blood pressure?")
  expect_length(a, 1); expect_equal(a[[1]]$mean, 12); expect_equal(a[[1]]$sd, 4); expect_equal(a[[1]]$name, "fasting insulin")
  b <- cv("Pigs on two diets, 10 per group, final weight adjusting for starting weight, which averages 30 kg with an SD of 3.")
  expect_length(b, 1); expect_equal(b[[1]]$mean, 30); expect_equal(b[[1]]$sd, 3); expect_equal(b[[1]]$unit, "kg")
})

test_that("ANCOVA without stated blocks is completely randomized; 'adjusting for sex' is additive with two levels", {
  a <- pkg_reg("Hamsters on two diets, 20 per diet, final body weight adjusting for baseline body weight.")
  expect_equal(a$j$design$chosen, "crd"); expect_equal(a$j$analysis$model, "y ~ treatment + covariate")
  s <- pkg_reg("Rabbits on two diets, 10 per group, final weight adjusting for sex and baseline weight.")
  expect_equal(s$j$analysis$model, "y ~ treatment + treatment2 + covariate")
  sx <- Filter(function(f) f$name == "sex", s$j$factors)[[1]]; expect_equal(unlist(sx$levels), c("female", "male"))
  b <- pkg_reg("Pigs on two diets in 6 blocks, final weight adjusting for baseline weight.")
  expect_equal(b$j$analysis$model, "y ~ treatment + block + covariate")
})
