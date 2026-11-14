test_that("alias table maps synonyms to canonical terms", {
  expect_equal(studyforge_alias("milo"), "Sorghum bicolor")
  expect_equal(studyforge_alias("Glasshouse", "system"), "greenhouse")
  expect_equal(studyforge_alias("von frey"), "mechanical_threshold")
  expect_true(is.na(studyforge_alias("not a term")))
  t <- .sf_alias_table()
  expect_gte(nrow(t), 400)
  expect_named(t, c("alias", "canonical_term", "category", "source", "confidence"))
})

test_that("merge keeps rules first and only fills gaps", {
  q <- "We test 30 barley lines at four sites with 3 replications."
  rule <- extract_spec_local(q)
  model <- list(system = "greenhouse", organism = "Hordeum vulgare", design = list(reps = 3, locations = 4),
                factors = list(list(name = "genotype", n_levels = 30), list(name = "nitrogen", n_levels = 2)))
  m <- merge_specs(rule, model, q)
  expect_equal(m$system, "field")                      # rule wins
  expect_false("nitrogen" %in% vapply(m$factors, `[[`, "", "name"))  # level 2 never stated
})

test_that("merge refuses unstated numbers and misattributed reps", {
  q <- "Hybrids at two sites, measuring yield."
  model <- list(design = list(reps = 2, locations = 2), primary_outcome = list(name = "open-pollinated"))
  m <- merge_specs(new_spec(), model, q)
  expect_null(m$design$reps)                           # "two sites" is not 2 reps
  expect_equal(m$design$locations, 2)
  expect_null(m$primary_outcome)                       # unknown outcome term rejected
  m2 <- merge_specs(new_spec(), list(design = list(locations = 7)), q)
  expect_null(m2$design$locations)                     # 7 never appears
})

test_that("model extractor degrades gracefully without Python", {
  expect_message(r <- extract_spec_model("120 maize lines", python = "definitely-not-python"), "rules only")
  expect_null(r)
  h <- suppressMessages(extract_spec_hybrid("120 maize lines at two locations", python = "definitely-not-python"))
  expect_equal(h$organism, "Zea mays")
})

test_that("bundled model and inference code ship with the package", {
  expect_true(file.exists(system.file("models", "sf-tiny", "tagger.pt", package = "studyforge")))
  expect_true(file.exists(system.file("python", "predict.py", package = "studyforge")))
  expect_true(file.exists(system.file("python", "decode.py", package = "studyforge")))
})

test_that("bundled model runs when Python is available", {
  py <- Sys.getenv("STUDYFORGE_PYTHON")
  skip_if(!nzchar(py), "set STUDYFORGE_PYTHON to a Python with torch + transformers")
  s <- extract_spec_model("We are evaluating 150 rice landraces across 4 locations with 3 replications.", python = py)
  expect_equal(s$design$locations, 4)
  # multi-location yield trials sit on the field / multi_environment boundary; in hybrid mode the rules decide
  expect_true(s$system %in% c("field", "multi_environment"))
  h <- extract_spec_hybrid("We are evaluating 150 rice landraces across 4 locations with 3 replications.", python = py)
  expect_equal(h$system, "field")
})

test_that("new topics: rules read populations, assays and organisms", {
  s <- extract_spec_local("I want a half diallel among 8 maize inbreds to estimate GCA and SCA at three locations.")
  expect_equal(s$system, "breeding_genetics")
  expect_equal(s$population$mating, "diallel")
  expect_equal(s$population$parents, 8)
  v <- extract_spec_local("We want to validate 3 candidate genes in silico and in vivo with CRISPR in rice and heterologous expression in Arabidopsis.")
  expect_equal(v$system, "functional_validation")
  expect_equal(unlist(v$organisms), c("Oryza sativa", "Arabidopsis thaliana"))
  expect_true(all(c("crispr", "heterologous", "in_silico") %in% unlist(v$assays)))
  a <- studyforge_ask("ATAC-seq of maize roots across 3 water treatments with 2 biological replicates")
  expect_true("atac_replicated" %in% a$candidates)
  expect_true("atac_organellar_reads" %in% vapply(a$hazards, `[[`, "", "id"))
})
