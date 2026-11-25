test_that("goal registry and rules agree", {
  reg <- .sf_goal_registry()
  expect_true(all(c("treatment_effect", "interaction", "time_course", "trend", "alpha_diversity",
                    "biomarker_classification", "coexpression_network") %in% names(reg)))
  expect_true(all(vapply(reg, function(g) g$test %in% c("wald", "lrt", "wald_or_lrt", "other"), logical(1))))
  slots <- unique(unlist(lapply(reg, `[[`, "required_terms")))
  expect_true(all(slots %in% c("factor_a", "factor_b", "time", "numeric")))
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
