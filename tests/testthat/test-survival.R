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
