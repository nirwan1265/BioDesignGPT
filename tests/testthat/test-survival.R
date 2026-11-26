test_that("survival: endpoint, competing event, options, event-based power, estimand and clusters", {
  pkg <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- fill_layout_defaults(a$spec); s$design$reps <- s$design$reps %||% 3
    d <- file.path(tempdir(), paste0("sv", sample.int(1e6, 1))); write_design_package(layout_from_spec(s, 1), s, d)
    list(j = jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE), q = a$questions) }
  g <- pkg("Germination of seeds from 5 barley lines, scored every 3 days for 24 days after sowing; seeds that rot before germinating are recorded; germination by day 6 and 12, and how much faster each line germinates.")$j
  po <- g$primary_outcome
  expect_equal(po$type, "survival"); expect_equal(po$event, "germination"); expect_equal(po$origin, "sowing"); expect_equal(po$unit, "days")
  expect_match(po$censoring, "administrative at 24 days"); expect_equal(po$event_codes[["2"]], "rot before germinating")
  expect_equal(unlist(g$analysis$survival$landmarks), c(6, 12)); expect_true(g$analysis$survival$aft); expect_equal(g$analysis$survival$life_table, 3)
  expect_false(any(vapply(g$factors, function(f) f$name == "time", logical(1))))
  expect_equal(g$analysis$goal_effect$survival$scale, "time_ratio")
  l <- pkg("Time to first lesion on 100 oat lines in 15 blocks after inoculation, checked daily for 30 days; hazard ratio 0.7, 50% of plants expected to show symptoms, 20% lost.")$j
  expect_equal(l$power$events_required, 247); expect_equal(l$power$units_required, ceiling(247 / 0.5 / 0.8))
  expect_equal(l$analysis$goal_effect$survival$scale, "hazard_ratio"); expect_equal(l$analysis$goal_effect$survival$size, 0.7)
  expect_match(l$analysis$model, "\\(1 \\| block\\)")
  expect_equal(vapply(l$factors, `[[`, "", "name"), "genotype")
  f <- pkg("Days to heading of 3 rice lines under flooding and control in 4 blocks; plants that die before heading are recorded; the flooding effect is expected to appear late.")
  expect_equal(f$j$analysis$survival$logrank_weight, "fh_0_1"); expect_equal(unlist(f$j$analysis$survival$strata), "block")
  expect_match(f$q[1], "hazard ratio")
  m <- pkg("Rats infected with a virus, treated or vehicle, 10 per group, survival followed for 21 days after infection; hazard ratio 0.4.")$j
  expect_equal(vapply(m$factors, `[[`, "", "name"), "treatment"); expect_equal(m$factors[[1]]$n_levels, 2)
})

test_that("survival size only from a stated hazard ratio, in numbers or words; never from the outcome-unit difference", {
  ge <- function(q, fix = list()) { a <- studyforge_ask(q, provider = "local"); if (length(fix)) a <- do.call(studyforge_fix, c(list(a), fix))
    s <- fill_layout_defaults(a$spec); s$design$reps <- s$design$reps %||% 4; d <- file.path(tempdir(), paste0("hr", sample.int(1e6, 1)))
    write_design_package(layout_from_spec(s, 1), s, d); jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE)$analysis$goal_effect$survival }
  expect_equal(ge("Lifespan of worms on two diets, 6 plates per diet; the drug should halve the hazard of death.")$size, 0.5)
  expect_equal(ge("Rats infected with a virus, drug or vehicle, 10 per group, survival over 21 days; the drug should reduce the risk of death by 30%.")$size, 0.7)
  x <- ge("Rats infected with a virus, drug or vehicle, 10 per group, survival over 21 days.", list(power.minimum_detectable_difference = 10))
  expect_equal(x$scale, "hazard_ratio"); expect_null(x$size)
})

test_that("loss, competing event, delayed effect, trays as blocks and 'X or not' levels in looser wording", {
  s <- studyforge_ask("Seeds of 3 wheat lines primed or not in 5 trays, days to germination checked every 2 days, followed for 18 days, 15% of seeds may be lost, seed rot can occur before germination, the priming effect is delayed, hazard ratio 0.7.", provider = "local")$spec
  expect_equal(s$power$loss_fraction, 0.15)
  expect_equal(s$primary_outcome$event_codes[["2"]], "seed rot before germination")
  expect_equal(s$analysis$survival$logrank_weight, "fh_0_1")
  expect_equal(s$design$reps, 5)
  expect_equal(unlist(Filter(function(f) f$name == "treatment", s$factors)[[1]]$levels), c("not primed", "primed"))
})
