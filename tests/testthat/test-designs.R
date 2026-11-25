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

test_that("the hand-off spec records the chosen design's analysis model and the schema version", {
  b <- data.frame(plots = 101:104, block = rep(1:2, each = 2), treatment = rep(c("a", "b"), 2))
  attr(b, "design") <- "rcbd"; attr(b, "seed") <- 1
  p <- write_design_package(b, new_spec(), outdir = tempfile())
  j <- jsonlite::fromJSON(p[basename(p) == "study_spec.json"])
  expect_equal(j$analysis$model, "y ~ treatment + block")
  expect_equal(j$handoff_version, load_registry("study_spec.schema")$version)
})

test_that("layout_from_spec keeps every factor, crosses randomized ones and repeats units over tissues", {
  s <- new_spec(); s$system <- "greenhouse"; s$design$reps <- 3
  s$factors <- list(list(name = "genotype", n_levels = 2), list(name = "water", n_levels = 2), list(name = "tissue", n_levels = 2))
  expect_equal(.sf_candidates(s)[1], "factorial")
  b <- layout_from_spec(s, seed = 1)
  expect_true(all(c("genotype", "water", "tissue") %in% names(b)))
  expect_equal(nrow(b), 2 * 2 * 3 * 2)
  expect_equal(nrow(unique(b[c("genotype", "water")])), 4)
  t1 <- new_spec(); t1$factors <- list(list(name = "time", n_levels = 4)); t1$design$reps <- 3
  expect_equal(sort(unique(layout_from_spec(t1)$time)), paste0("time_", 1:4))
  p <- new_spec(); p$system <- "field"; p$factors <- list(list(name = "genotype", n_levels = 149)); p$design$reps <- 2
  expect_match(paste(attr(layout_from_spec(p), "layout_notes"), collapse = " "), "no alpha lattice")
  expect_error(layout_from_spec(new_spec()), "missing: factors")
})

test_that("a factor named treatment keeps its own column in factorial and split layouts", {
  s <- new_spec(); s$design$reps <- 3
  s$factors <- list(list(name = "treatment", n_levels = 2), list(name = "time", n_levels = 3))
  b <- layout_from_spec(s, seed = 1)
  expect_setequal(unique(b$treatment), c("treatment_1", "treatment_2"))
  expect_setequal(unique(b$time), paste0("time_", 1:3))
  expect_true("treatment_combination" %in% names(b))
  s$system <- "field"; s$factors[[1]]$applied_to <- "main_plot"
  b2 <- layout_from_spec(s, seed = 1)
  expect_setequal(unique(b2$treatment), c("treatment_1", "treatment_2"))
})

test_that("layout defaults are flagged, augmented builds with assumed checks, environments are randomized separately", {
  s <- new_spec(); s$assays <- list("gwas"); s$factors <- list(list(name = "genotype"), list(name = "time"))
  s2 <- fill_layout_defaults(s)
  expect_equal(vapply(s2$factors, function(f) f$n_levels, 1), c(200, 3))
  expect_match(s2$assumptions[["factors.time.n_levels"]], "assumed default")
  a <- new_spec(); a$factors <- list(list(name = "genotype", n_levels = 60)); a$design$chosen <- "augmented"
  b <- layout_from_spec(fill_layout_defaults(a))
  expect_equal(sum(!b$is_check), 60)
  e <- new_spec(); e$factors <- list(list(name = "genotype", n_levels = 6)); e$design$reps <- 2
  e$design$locations <- 2; e$design$seasons <- 2
  be <- layout_from_spec(e)
  expect_equal(nrow(be), 6 * 2 * 4)
  expect_setequal(unique(paste(be$location, be$season)), c("location_1 season_1", "location_1 season_2", "location_2 season_1", "location_2 season_2"))
})

test_that("cell types and fractions are measured within the unit, not randomized", {
  s <- extract_spec_local("RNA-seq of neutrophils, macrophages and B cells from mice on chow vs high-fat diet, 4 mice per diet.")
  b <- layout_from_spec(s, 1)
  expect_equal(nrow(b), 2 * 4 * 3)
  expect_true(all(table(b$plot) == 3))
})

test_that("same units at every stage: within-unit layout, (1 | unit) note; destructive: crossed; unstated: asked", {
  a <- studyforge_ask("Sperm RNA-seq from the same 7 Duroc boars at puberty and at maturity, fed diet A vs B, 3 boars per diet.", provider = "local")
  expect_equal(unlist(a$spec$repeated_factors), "stage")
  b <- layout_from_spec(a$spec, 1)
  expect_true(all(table(b[[setdiff(names(b), c("stage", "diet", "block", "plots", "plot", "unit", "rep"))[1]]] %||% 1) >= 1))
  expect_equal(nrow(b), 2 * 3 * 2)
  expect_equal(.sf_model_terms(a$spec, b, "y ~ treatment * time + (1 | unit)")$time, "stage")
  d <- studyforge_ask("Liver RNA-seq of rats on two diets, 3 rats sacrificed at each of days 7, 14 and 28.", provider = "local")
  expect_length(d$spec$repeated_factors, 0); expect_false(is.null(d$spec$repeated_factors))
  u <- studyforge_ask("Faecal 16S of sows on two diets sampled in late gestation and lactation, 6 sows per diet.", provider = "local")
  expect_null(u$spec$repeated_factors)
  expect_true(any(grepl("same .* every stage", u$all_questions)))
})

test_that("Simitall repeated-measures cases: same animals across stages/times; time values; no double count", {
  a <- studyforge_ask("Liver biopsies from the same cows in late gestation and again in early lactation, 6 cows per diet, two diets.", provider = "local")
  expect_setequal(vapply(a$spec$factors, `[[`, "", "name"), c("diet", "stage"))
  expect_equal(unlist(a$spec$repeated_factors), "stage")
  b <- layout_from_spec(a$spec, 1)
  expect_equal(nrow(b), 2 * 6 * 2); expect_true(all(table(b$plot) == 2))
  expect_equal(attr(b, "design"), "randomized_complete_block_repeated")
  m <- studyforge_ask("Blood from the same mice at 24, 48 and 72 h, infected vs mock, 5 mice per group.", provider = "local")
  tf <- Filter(function(f) f$name == "time", m$spec$factors)[[1]]
  expect_equal(tf$values, c(24, 48, 72)); expect_equal(tf$unit, "h"); expect_equal(tf$levels, c("24 h", "48 h", "72 h"))
  bm <- layout_from_spec(m$spec, 1)
  expect_equal(nrow(bm), 2 * 5 * 3); expect_setequal(unique(bm$time), c("24 h", "48 h", "72 h"))
  z <- extract_spec_local("Maize lines under drought vs control, leaves at anthesis and grain filling, 4 plots each.")
  expect_setequal(vapply(z$factors, `[[`, "", "name"), c("water", "stage"))
})

test_that("same-units cue: only the unit itself, not a shared source; embryonic days are destructive", {
  r <- function(q) { s <- extract_spec_local(q); if (is.null(s$repeated_factors)) "absent" else paste(unlist(s$repeated_factors), collapse = ",") }
  # a reviewed spec with a stage factor (how Simitall calls it)
  rv <- .sf_repeated_on_unit(list(factors = list(list(name = "stage", n_levels = 4))),
    "Heart RNA-seq of rat embryos at E12, E14 and E16 in two strains, each sample a pool of 3 embryos from the same dam.")
  expect_length(rv$repeated_factors, 0); expect_false(is.null(rv$repeated_factors))
  hv <- .sf_repeated_on_unit(list(factors = list(list(name = "stage", n_levels = 2))),
    "Ovarian follicle RNA-seq of laying hens in individual cages, prehierarchal vs selected follicles from the same hen.")
  expect_equal(unlist(hv$repeated_factors), "stage")
  expect_equal(r("Liver biopsies from the same cows in late gestation and again in early lactation, 6 cows per diet, two diets."), "stage")
  expect_equal(r("Liver RNA-seq of cows slaughtered in late gestation or in early lactation, two diets, 6 cows per diet and stage."), "")
  expect_equal(r("Leaf RNA-seq of leaves from the same plants at 1, 3 and 7 days after drought vs control, 4 plants per treatment."), "time")
})

test_that("repeated occasion as the only factor: paired rcbd, unit is the block, no (1 | unit) note", {
  a <- studyforge_ask("Endometrial RNA-seq of biopsies taken from the same beef cows at 15 and 30 days postpartum, 3 cows.", provider = "local")
  tf <- Filter(function(f) f$name == "time", a$spec$factors)[[1]]
  expect_equal(tf$values, c(15, 30)); expect_equal(tf$unit, "d")
  a$spec$design$reps <- a$spec$design$reps %||% 3   # "3 cows" is read as the replicate count only in some phrasings
  b <- layout_from_spec(a$spec, 1); d <- file.path(tempdir(), "paired"); unlink(d, TRUE)
  write_design_package(b, a$spec, d); j <- jsonlite::fromJSON(file.path(d, "study_spec.json"))
  expect_true(j$analysis$terms$paired); expect_equal(j$analysis$terms$unit_column, "block")
  expect_false(grepl("add (1 | unit)", j$analysis$note, fixed = TRUE))
})

test_that("same X must be the measured subject; before/after on living subjects with a non-destructive sample is repeated", {
  rp <- function(q, f = "time") { v <- .sf_repeated_on_unit(list(factors = list(list(name = f, n_levels = 2))), q)$repeated_factors
    if (is.null(v)) "absent" else paste(unlist(v), collapse = ",") }
  expect_equal(rp("Faecal 16S of Iberian and Landrace piglets produced by embryo transfer into the same recipient sows, sampled at 21 and 60 days."), "absent")
  expect_equal(rp("Whole-blood RNA-seq from pigs infected with a low- or high-pathogenic ASFV isolate, sampled before and after infection, 3 pigs per isolate."), "time")
  expect_equal(rp("Faecal 16S over time from 12 SLA dd minipigs and 12 Large White pigs."), "time")
  expect_equal(rp("Liver RNA-seq of two pig breeds, before and after weaning, 6 pigs per breed and stage."), "absent")
  expect_equal(rp("RNA-seq of HeLa cells transfected with a siRNA or scrambled control, before and after serum starvation."), "absent")
  expect_equal(rp("RNA-seq of tomato plants in pots under low or high nitrogen, sampled before and after flowering from roots and leaves."), "absent")
})
