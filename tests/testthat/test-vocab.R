test_that("assays added from the paper-question gaps resolve to their own canonical terms", {
  expect_equal(studyforge_alias("16S", "assay"), "amplicon")
  expect_equal(studyforge_alias("MeRIP-seq", "assay"), "m6a_seq")
  expect_equal(studyforge_alias("Iso-Seq", "assay"), "long_read_rna")
  expect_equal(studyforge_alias("scATAC-seq", "assay"), "scatac_seq")
  expect_equal(studyforge_alias("hMeDIP-seq", "assay"), "medip")
  expect_equal(studyforge_alias("PRO-seq", "assay"), "nascent_rna")
  expect_equal(studyforge_alias("CUT&Tag", "assay"), "chip_seq")
  expect_equal(studyforge_alias("3' Tag-seq", "assay"), "rnaseq")
  expect_equal(studyforge_alias("breed", "factor"), "genotype")
  expect_equal(studyforge_alias("cell types", "factor"), "cell_type")
})

test_that("assays in a question map to evidence techniques", {
  s <- extract_spec_local("MeRIP-seq and CUT&Tag of HEK293T cells, knockdown vs control.")
  expect_true(all(c("m6a_seq", "chip_seq") %in% unlist(s$assays)))
  expect_equal(unname(.SF_TECH_BY_ASSAY["m6a_seq"]), "m6A / MeRIP-seq")
})

test_that("single-cell ATAC is a single-cell study, not bulk ATAC", {
  s <- extract_spec_local("scATAC-seq of mouse retina, Oct4 overexpression vs control.")
  expect_equal(s$system, "single_cell")
  expect_true("scatac_seq" %in% unlist(s$assays))
})

test_that("livestock: pens are the unit when the diet is given per pen", {
  s <- extract_spec_local("450 day-old broilers: control, LPS, or LPS + gallotannins in the diet, 6 replicate pens of 25 birds per treatment.")
  expect_equal(s$system, "livestock")
  expect_equal(s$experimental_unit, "pen")
  expect_equal(s$subsamples_per_unit, 25)
  expect_equal(s$design$reps, 6)
  expect_true("rcbd" %in% .sf_candidates(c(s, list(question = "broilers in pens"))))
  expect_length(match_pseudoreplication_rules("animal", "pen"), 1)
  expect_gt(length(system_questions("livestock")), 2)
})

test_that("fish sharing a tank: the tank is the unit", {
  s <- extract_spec_local("Zebrafish fed a fishmeal or plant diet, 16 fish in each of 4 replicate tanks per diet, muscle RNA-seq.")
  expect_equal(s$experimental_unit, "tank")
  expect_equal(s$measurement_unit, "fish")
  expect_equal(s$subsamples_per_unit, 16)
  expect_length(match_pseudoreplication_rules("fish", "tank"), 1)
})
