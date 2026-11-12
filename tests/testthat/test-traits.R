test_that("trait suggestions follow organ and stress, with sources", {
  r <- suggest_traits("roots", "cold", "Arabidopsis thaliana", n = 6)
  expect_match(r$trait[1], "root", ignore.case = TRUE)
  expect_true(any(grepl("proline", r$trait, ignore.case = TRUE)))          # cold-response assays follow
  expect_false(any(grepl("electrolyte", r$trait)))                           # leaf assay, not for roots
  d <- suggest_traits("leaf", "drought", "Sorghum bicolor")
  expect_true(any(grepl("water content", d$trait)))
  m <- suggest_traits(NULL, "diet", "Mus musculus")
  expect_true(any(grepl("Glucose", m$trait)))
  expect_false(any(grepl("root", m$trait, ignore.case = TRUE)))             # no plant traits for mice
  tr <- load_registry("traits")$traits
  src <- Filter(Negate(is.null), lapply(tr, `[[`, "source"))
  expect_true(all(grepl("^10\\.", vapply(src, `[[`, "", "doi"))))
})

test_that("plans list traits when asked, and sequencing for omics", {
  a <- studyforge_ask("cold chamber experiment for arabidopsis roots. what phenotype traits can i take?")
  expect_true(nrow(a$traits) > 0)
  expect_match(paste(capture.output(print(a)), collapse = "\n"), "Traits you could measure")
  b <- studyforge_ask("RNA-seq of human blood in 5 condition of diets, NovaSeq PE150, 30 million reads")
  expect_equal(b$spec$sequencing$instrument, "NovaSeq")
  expect_equal(b$spec$sequencing$read_length, 150)
  expect_equal(b$spec$sequencing$depth_m, 30)
  expect_null(b$traits)                                                      # omics: no phenotype list
  c2 <- studyforge_ask("I want maize RNA-seq for drought vs control")
  out <- paste(capture.output(print(c2)), collapse = "\n")
  expect_match(out, "Sequencing: +\\? \\(typical: ")
  expect_match(out, "Tissue: +\\? \\(most studied: ")
})
