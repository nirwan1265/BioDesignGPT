pkg_cat <- function(q) { a <- studyforge_ask(q, provider = "local"); s <- a$spec; d <- file.path(tempdir(), paste0("ct", sample.int(1e6, 1)))
  write_design_package(layout_from_spec(s, 1), s, d)
  list(j = jsonlite::fromJSON(file.path(d, "study_spec.json"), simplifyVector = FALSE), m = utils::read.delim(file.path(d, "sample_metadata_template.tsv")), q = a$questions) }

test_that("nominal categories and an expected ratio in one group", {
  n <- studyforge_ask("Flower colour of 4 petunia lines, classified as white, pink or red, 30 plants per line.", provider = "local")$spec
  expect_equal(n$primary_outcome$type, "nominal"); expect_equal(unlist(n$primary_outcome$categories), c("white", "pink", "red"))
  r <- pkg_cat("F2 progeny of a cross between tall and dwarf parents, 250 plants scored for tall or dwarf; test a 3:1 segregation.")
  expect_equal(r$j$analysis$expected_ratio, list(tall = 3, dwarf = 1)); expect_equal(r$j$design$chosen, "single_group")
  expect_equal(r$j$analysis$model, "y ~ 1"); expect_equal(nrow(r$m), 250); expect_length(r$q, 0)
  u <- pkg_cat("An F2 population of 160 plants segregating 1:2:1 for seed coat colour.")
  expect_equal(names(u$j$analysis$expected_ratio), c("class_1", "class_2", "class_3")); expect_match(u$q[1], "1:2:1 ratio refer to")
})

test_that("correlation: traits as primary and secondary outcomes with template columns; GWAS wording is not a correlation", {
  c <- pkg_cat("Across 40 barley lines in 3 replicates, how do plant height, tiller number and grain weight relate?")
  expect_equal(unlist(c$j$analysis$correlation$variables), c("plant_height", "tiller_number", "grain_weight"))
  expect_equal(c$j$analysis$correlation$method, "pearson")
  expect_true(all(c("tiller_number", "grain_weight") %in% names(c$m)))
  s <- studyforge_ask("Spearman correlation between root length and shoot biomass in 30 wheat lines.", provider = "local")$spec
  expect_equal(s$analysis$correlation$method, "spearman")
  expect_null(studyforge_ask("GWAS of the association between SNPs and flowering time in 300 maize lines.", provider = "local")$spec$analysis$correlation)
})

test_that("agreement: raters within each unit, scale and levels", {
  a <- pkg_cat("Four raters score leaf rust severity on a 1-9 scale on the same 50 oat leaves; how well do they agree?")
  ag <- a$j$analysis$agreement
  expect_equal(ag$scale, "ordinal"); expect_equal(unlist(ag$levels), 1:9); expect_equal(ag$rater_column, "rater"); expect_equal(ag$unit_column, "plot")
  expect_equal(nrow(a$m), 200); expect_equal(sort(unique(a$m$rater)), paste0("rater_", 1:4))
})

test_that("survival subsamples: one template row per seed, the unit as cluster", {
  s <- pkg_cat("Seeds primed or not in 11 trays, 8 seeds per treatment per tray, days to germination, followed for 21 days, hazard ratio 0.6.")
  expect_equal(nrow(s$m), 11 * 2 * 8); expect_true("subsample" %in% names(s$m)); expect_equal(s$j$analysis$survival$cluster, "plot")
})

test_that("looser wordings: 'expected 3:1 A to B', 'is X related to Y', 'two people scored from 1 to 9', per-trait types", {
  r <- pkg_cat("An F2 population of 180 pepper plants scored for fruit colour, expected 3:1 red to orange.")
  expect_equal(r$j$analysis$expected_ratio, list(red = 3, orange = 1)); expect_equal(r$j$primary_outcome$type, "nominal")
  expect_equal(r$j$design$chosen, "single_group"); expect_equal(nrow(r$m), 180)
  c <- studyforge_ask("50 oat lines in 3 blocks: is plant height related to grain yield?", provider = "local")$spec
  expect_equal(unlist(c$analysis$correlation$variables), c("plant_height", "grain_yield")); expect_equal(c$primary_outcome$type, "continuous")
  a <- pkg_cat("Two people scored blotch from 1 to 9 on each of 70 barley plots; how well do they agree?")
  expect_equal(unlist(a$j$analysis$agreement$levels), 1:9); expect_equal(sort(unique(a$m$rater)), c("rater_1", "rater_2")); expect_equal(nrow(a$m), 140)
  t <- studyforge_ask("Across 30 rye lines in 2 replicates, how do plant height, tiller number and grain weight relate?", provider = "local")$spec
  expect_equal(t$primary_outcome$type, "continuous"); expect_equal(t$secondary_outcomes[[1]]$type, "count")
})
