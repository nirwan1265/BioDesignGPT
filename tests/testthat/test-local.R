test_that("free offline extractor meets the regression bar on all examples", {
  r <- evaluate_extraction(extract_spec_local)
  expect_gte(r$field_recall, 0.85)
  expect_equal(r$examples_with_invented_values, 0)   # never fills effect sizes, SDs etc.
  expect_gte(r$design_hit_rate, 0.9)
})

test_that("extractor reads common phrasings", {
  s <- extract_spec_local("I have 324 sorghum accessions at three sites this season, two replicates per site, five plants per plot.")
  expect_equal(s$system, "field")
  expect_equal(s$organism, "Sorghum bicolor")
  expect_equal(s$design$reps, 2)
  expect_equal(s$design$locations, 3)
  expect_equal(s$design$seasons, 1)
  expect_equal(s$subsamples_per_unit, 5)
  expect_equal(s$experimental_unit, "plot")
  expect_null(spec_get(s, "power.residual_sd"))
})

test_that("undecided counts are left empty", {
  s <- extract_spec_local("70 sorghum varieties, I can do two or three reps.")
  expect_null(s$design$reps)
})

test_that("studyforge_ask returns a complete offline answer", {
  a <- studyforge_ask("Antibiotics vs control in the drinking water, 10 mice per group housed 5 per cage.")
  expect_s3_class(a, "studyforge_answer")
  expect_equal(a$provider, "local")
  expect_equal(a$audit$pseudoreplication_risk, "high")
  expect_true(length(a$hazards) > 0)
  expect_match(a$disclaimer, "IACUC")
  out <- utils::capture.output(print(a))
  expect_true(any(grepl("Unit audit: risk HIGH", out)))
})

test_that("starter recipes run", {
  prompts <- c("324 sorghum accessions, 2 reps, 3 sites",
               "200 Arabidopsis accessions in 48-cell trays, can't replicate everything",
               "Lifespan of Dahomey females on 3 yeast concentrations",
               "Three irrigation levels and five cultivars, linear-move irrigation, 4 replications")
  for (p in prompts) {
    env <- new.env()
    expect_no_error(eval(parse(text = studyforge_ask(p)$recipe), envir = env))
  }
})

test_that("ollama provider degrades gracefully when no server is running", {
  skip_if_not_installed("httr2")
  a <- studyforge_ask("120 maize lines at two locations", provider = "ollama",
                      ollama_endpoint = "http://127.0.0.1:9/api/generate")
  expect_match(a$llm_text, "Could not reach Ollama")
  expect_true(length(a$designs) > 0)
})

test_that("shiny app ships and parses", {
  app <- system.file("shiny", "studyforge", "app.R", package = "studyforge")
  expect_true(file.exists(app))
  expect_no_error(parse(app))
})
