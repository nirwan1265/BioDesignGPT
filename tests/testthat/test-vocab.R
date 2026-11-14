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

test_that("single-cell ATAC is a single-cell study, not bulk ATAC; a named setting comes first", {
  s <- extract_spec_local("scATAC-seq of retina, Oct4 overexpression vs control.")
  expect_equal(s$system, "single_cell")
  expect_true("scatac_seq" %in% unlist(s$assays))
  s <- extract_spec_local("scATAC-seq of mouse retina, Oct4 overexpression vs control.")
  expect_equal(s$system, "mouse")                      # the setting is the system; the assay stays listed
  expect_true("scatac_seq" %in% unlist(s$assays))
})

test_that("system is the stated setting, else the assay family; assay advice follows the assay", {
  s <- extract_spec_local("ATAC-seq of soybean trifoliate leaves from greenhouse plants, drought vs control, 3 reps.")
  expect_equal(s$system, "greenhouse")
  expect_true("atac_replicated" %in% .sf_candidates(s))
  expect_equal(extract_spec_local("RNA-seq of 2 cultivars under heat vs control.")$system, "bulk_rnaseq")
  expect_equal(extract_spec_local("Drosophila S2 cells, ATAC-seq after induction.")$system, "cell_culture")
  expect_equal(extract_spec_local("Ribosome profiling of yeast under heat vs control to measure translation efficiency.")$primary_outcome$name,
               "translation_efficiency")
})

test_that("merge: the reader fills what the text supports, the rules keep their conventions", {
  q <- "Bulk RNA-seq of pig liver, high-fat vs control diet, 6 pigs per diet, 4 replicate pens per diet."
  m <- merge_specs(extract_spec_local(q), list(system = "bulk_rnaseq", experimental_unit = "pen", design = list(reps = 4)), q)
  expect_equal(m$system, "livestock")                  # a named setting outranks the reader's assay family
  expect_equal(m$experimental_unit, "pen")             # counted as the replicate: "4 replicate pens per diet"
  q2 <- "Lifespan of wild-type Dahomey females on 3 yeast concentrations."
  m2 <- merge_specs(extract_spec_local(q2), list(organism = "Saccharomyces cerevisiae", primary_outcome = list(name = "lifespan", type = "continuous")), q2)
  expect_equal(m2$organism, "Drosophila melanogaster")
  expect_equal(m2$primary_outcome$type, "survival")
  q3 <- "Maize hybrids under managed drought, I can do two or three reps, about 90 hybrids."
  expect_null(merge_specs(new_spec(), list(design = list(reps = 2)), q3)$design$reps)   # a range is not a count
  q4 <- "84 male mice randomly allocated to 7 groups, 12 per group, housed 4 per cage."
  expect_equal(merge_specs(new_spec(), list(design = list(reps = 12)), q4)$design$reps, 12)
  m5 <- merge_specs(new_spec(), list(factors = list(list(name = "pup"), list(name = "treatment", n_levels = 7))), q4)
  expect_equal(vapply(m5$factors, `[[`, "", "name"), "treatment")   # a unit is not a factor
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

test_that("settings: cells in culture, lab growth systems, and a named field beat breeding / assay cues", {
  sys <- function(q) extract_spec_local(q)$system
  expect_equal(sys("rat hippocampal neuron cultures treated with picrotoxin vs untreated, RNA-seq."), "cell_culture")
  expect_equal(sys("circRNA-seq of BRL-3A rat liver cells under hypoxia vs normoxia."), "cell_culture")
  expect_equal(sys("CUT&Tag of CD8 T cells sorted from mice infected with LCMV."), "mouse")          # in vivo
  expect_equal(sys("Ribo-seq of rice shoots after 24 h of 150 mM NaCl in hydroponics."), "growth_chamber")
  expect_equal(sys("Grafted tomato in hydroponic channels in one glasshouse compartment, RNA-seq."), "greenhouse")
  expect_equal(sys("IBM recombinant inbred lines in a randomised complete block in the field, two reps."), "field")
  expect_equal(sys("Newborn calves each in their own pen, fed live yeast or not, rumen RNA-seq."), "livestock")
})
