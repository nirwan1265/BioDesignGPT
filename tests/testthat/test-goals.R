test_that("goal registry and rules agree", {
  reg <- .sf_goal_registry()
  expect_true(all(c("treatment_effect", "interaction", "time_course", "trend", "alpha_diversity",
                    "biomarker_classification", "coexpression_network") %in% names(reg)))
  expect_true(all(vapply(reg, function(g) g$test %in% c("wald", "lrt", "wald_or_lrt", "other"), logical(1))))
  slots <- unique(unlist(lapply(reg, `[[`, "required_terms")))
  expect_true(all(slots %in% c("factor_a", "factor_b", "time", "numeric", "covariate")))
  for (cat in c("analysis_goal", "goal_default")) expect_true(all(.sf_rules_rows(cat)$term %in% names(reg)))
})

test_that("goals: read, asked, defaulted, written with terms, effect and power", {
  pkg <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- a$spec; s$design$reps <- s$design$reps %||% 3
    d <- file.path(tempdir(), paste0("goal", sample.int(1e6, 1))); write_design_package(layout_from_spec(s, 1), s, d)
    list(ask = a, j = jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE)) }
  x <- pkg("RNA-seq of wild-type and mutant maize roots at 0, 6, 12, 24 and 48 h, 3 replicates.")
  expect_true(any(grepl("change over time differs between genotype levels", x$ask$all_questions)))
  expect_equal(x$j$analysis$primary_goal, "treatment_effect"); expect_false(is.null(x$j$assumptions[["analysis.goals"]]))
  y <- pkg("RNA-seq of wild-type and mutant maize roots at 0, 6, 12, 24 and 48 h, 3 replicates; we want genes whose response over time differs between genotypes.")
  expect_equal(y$j$analysis$primary_goal, "interaction")
  expect_length(y$j$analysis$goal_terms$interaction, 2)
  expect_match(y$j$analysis$goal_effect$interaction$definition, "difference of differences")
  expect_match(y$j$power$reps_note, "4x")
  z <- pkg("Time-course RNA-seq of the same mice at 1, 3 and 7 days after infection vs mock, 5 mice per group; expression peaks at 3 days and returns to baseline.")
  expect_equal(z$j$analysis$goal_terms$time_course, "time")
  expect_equal(z$j$analysis$goal_effect$time_course$shape, "transient")
  expect_equal(z$j$analysis$goal_effect$time_course$peak$value, 3)
  w <- pkg("Arabidopsis seedlings treated with 0, 1, 10 and 100 uM ABA, dose-response RNA-seq, 3 replicates.")
  expect_equal(w$j$analysis$primary_goal, "trend"); expect_equal(w$j$analysis$goal_terms$trend, "treatment")
  dose <- Filter(function(f) f$name == "dose", w$j$factors)[[1]]
  expect_equal(unlist(dose$values), c(0, 1, 10, 100)); expect_equal(dose$scale, "log")
  m <- pkg("Faecal 16S of pigs on two diets, 8 pigs per diet.")
  expect_equal(unlist(m$j$analysis$goals), c("differential_abundance", "community_composition"))
  g <- pkg("Maize hybrids in a G x E trial at 4 locations, 30 hybrids, alpha lattice with 2 reps, heritability and stability of yield.")
  expect_equal(unlist(g$j$analysis$goal_terms$interaction), c("treatment", "env"))
  expect_match(g$j$analysis$model, "treatment:env")
})

test_that("effect scale follows the data type; a zero dose on a log scale gets an offset", {
  expect_equal(.sf_effect_scale(list(assays = list("rnaseq"))), "log2")
  expect_equal(.sf_effect_scale(list(assays = list("methylation"))), "M")
  expect_equal(.sf_effect_scale(list(primary_outcome = list(type = "binary"))), "logit")
  expect_equal(.sf_effect_scale(list(primary_outcome = list(type = "continuous"))), "identity")
  s <- extract_spec_local("Arabidopsis seedlings treated with 0, 1, 10 and 100 uM ABA, dose-response RNA-seq, 3 replicates.")
  d <- Filter(function(f) f$name == "dose", s$factors)[[1]]
  expect_equal(d$scale, "log"); expect_equal(d$log_offset, 1)
})

test_that("trend size only from a per-unit change; peak implies a time course; scope names the group; log base 10", {
  pkg <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- a$spec; s$design$reps <- s$design$reps %||% 3
    d <- file.path(tempdir(), paste0("g2", sample.int(1e6, 1))); write_design_package(layout_from_spec(s, 1), s, d)
    jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE) }
  a <- pkg("Arabidopsis seedlings treated with 0, 1, 10 and 100 uM ABA, dose-response RNA-seq, 3 replicates.")
  expect_null(a$analysis$goal_effect$trend$size)
  expect_match(a$assumptions[["analysis.goal_effect.trend.size"]], "over the factor's range")
  dose <- Filter(function(f) f$name == "dose", a$factors)[[1]]
  expect_equal(dose$unit, "uM"); expect_equal(dose$log_base, 10); expect_equal(dose$log_offset, 1)
  b <- pkg("Arabidopsis seedlings treated with 0, 1, 10 and 100 uM ABA, dose-response RNA-seq, 3 replicates; we expect a 0.5 log2 change per 10-fold dose.")
  expect_equal(b$analysis$goal_effect$trend$size, 0.5)
  m <- pkg("Mice infected or mock, blood from the same mice at 0, 6, 24 and 72 h, peak response expected at 24 h then return to baseline, 5 mice per group.")
  expect_equal(m$analysis$primary_goal, "time_course")
  expect_equal(m$analysis$goal_effect$time_course$shape, "transient"); expect_equal(m$analysis$goal_effect$time_course$peak$value, 24)
  w <- pkg("Time-course RNA-seq of wild-type and mutant roots at 0, 6, 24 and 48 h, 3 replicates; genes change over time only in the mutant.")
  expect_equal(w$analysis$goal_effect$time_course$group, "mutant"); expect_equal(w$analysis$goal_effect$time_course$group_factor, "genotype")
})

test_that("a within-group scope resolves to a named level; a per-amount change gives a per-unit slope on a linear factor", {
  pkg <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- a$spec; s$design$reps <- s$design$reps %||% 3
    d <- file.path(tempdir(), paste0("g3", sample.int(1e6, 1))); write_design_package(layout_from_spec(s, 1), s, d)
    jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE) }
  w <- pkg("Wild type and mutant tomato, leaves sampled at 0, 3, 9 and 27 h after wounding, only the mutant is expected to respond, peak at 9 h, 4 plants per genotype per time.")
  g <- Filter(function(f) f$name == "genotype", w$factors)[[1]]
  expect_equal(unlist(g$levels), c("wild type", "mutant"))
  tc <- w$analysis$goal_effect$time_course
  expect_equal(tc$scope, "within_group"); expect_equal(tc$group, "mutant"); expect_equal(tc$group_factor, "genotype")
  n <- pkg("Wheat given 0, 40, 80, 160 kg N/ha in 3 blocks, grain yield expected to rise by 0.4 t/ha per 40 kg N.")
  f <- Filter(function(f) f$name == "nitrogen", n$factors)[[1]]
  expect_equal(unlist(f$values), c(0, 40, 80, 160)); expect_equal(f$unit, "kg N/ha"); expect_equal(f$scale, "linear"); expect_null(f$log_offset)
  expect_equal(n$analysis$primary_goal, "trend")
  expect_equal(n$analysis$goal_effect$trend$size, 0.01); expect_equal(n$analysis$goal_effect$trend$per_unit, "kg N/ha")
})

test_that("the outcome's unit, usual level and spread are read, or asked for when an effect has a unit", {
  a <- studyforge_ask("Barley given 0, 30, 60, 120 kg N/ha in 4 blocks, yield expected to rise by 0.3 t/ha per 30 kg N.", provider = "local")
  expect_equal(a$spec$primary_outcome$unit, "t/ha"); expect_null(a$spec$power$residual_sd)
  expect_true(any(grepl("usual .* t/ha", a$all_questions)))
  expect_match(a$spec$assumptions[["power.residual_sd"]], "asked")
  b <- studyforge_ask("Barley given 0, 30, 60, 120 kg N/ha in 4 blocks, yield is about 6 t/ha with a CV of 12%, expected to rise by 0.3 t/ha per 30 kg N.", provider = "local")
  expect_equal(b$spec$primary_outcome$baseline_mean, 6); expect_equal(b$spec$power$residual_sd, 0.72)
  c <- studyforge_ask("Two oat cultivars in 6 blocks; plant height usually around 100 cm, SD 8 cm; we want to detect a 6 cm difference between cultivars.", provider = "local")
  expect_equal(c$spec$power$residual_sd, 8); expect_equal(c$spec$power$minimum_detectable_difference, 6); expect_equal(c$spec$primary_outcome$unit, "cm")
  d <- studyforge_ask("We want to detect a 2-fold change in expression between treated and control mice.", provider = "local")
  expect_null(d$spec$power$minimum_detectable_difference)
})

test_that("post-hoc comparisons: vs a control level label, pairwise, none; none for two levels", {
  ph <- function(q) studyforge_ask(q, provider = "local")$spec$analysis$posthoc
  a <- ph("Barley treated with 0, 25, 75 and 150 mM NaCl, 4 replicates; each dose compared with the untreated control.")
  expect_equal(a$type, "vs_control"); expect_equal(a$control, "0 mM"); expect_equal(a$factor, "salt")
  b <- ph("Four oat genotypes under drought, each compared with the wild type, 3 blocks.")
  expect_equal(b$control, "wild type"); expect_equal(b$factor, "genotype")
  s <- studyforge_ask("Four oat genotypes under drought, each compared with the wild type, 3 blocks.", provider = "local")$spec
  expect_equal(unlist(Filter(function(f) f$name == "genotype", s$factors)[[1]]$levels)[1], "wild type")
  expect_equal(ph("Seven barley genotypes in 3 blocks; which genotypes differ in grain weight?"), list(type = "pairwise", factor = "genotype"))
  expect_equal(ph("Three phosphorus rates in 5 blocks, only the overall effect, no post-hoc tests.")$type, "none")
  expect_null(ph("Two oat cultivars in 4 blocks compared with the check cultivar."))
  expect_null(ph("Two oat cultivars in 4 blocks, grain yield."))
})
