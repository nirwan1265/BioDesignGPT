test_that("organisms come from the alias table, not a hand list", {
  expect_equal(extract_spec_local("human rnaseq of blood")$organism, "Homo sapiens")
  expect_equal(extract_spec_local("drought on grapevine cuttings")$organism, "Vitis vinifera")
  expect_equal(extract_spec_local("ATAC-seq of C. elegans larvae")$organism, "Caenorhabditis elegans")
  expect_equal(extract_spec_local("a trial on 300 patients")$organism, "Homo sapiens")
})

test_that("factor counts are read generically", {
  lv <- function(q, nm) {
    f <- Filter(function(f) f$name == nm, extract_spec_local(q)$factors)
    if (length(f)) f[[1]]$n_levels %||% NA else NULL
  }
  expect_equal(lv("i have some human rnaseq data in 5 condition of diets", "diet"), 5)
  expect_equal(lv("we test 10 treatments on tomato with 4 reps", "treatment"), 10)
  expect_equal(lv("nitrogen at 4 rates on 12 wheat cultivars", "nitrogen"), 4)
  expect_equal(lv("nitrogen at 4 rates on 12 wheat cultivars", "genotype"), 12)
  expect_null(lv("nitrogen at 4 rates on 12 wheat cultivars", "rate"))            # no duplicate from "4 rates"
  expect_equal(lv("RNA-seq of maize roots at six time points", "time"), 6)
  expect_false(identical(lv("190 were treatment and the rest placebo", "treatment"), 190))  # a group size, not levels
})

test_that("specific factor words without counts are flagged, generic ones are not", {
  f <- vapply(extract_spec_local("a cold chamber experiment on arabidopsis roots")$factors, `[[`, "", "name")
  expect_true("temperature" %in% f)
  f2 <- extract_spec_local("rice in a growth chamber, 3 plants per group")$factors
  expect_false(any(vapply(f2, `[[`, "", "name") == "group"))
})

test_that("goal, phenotype text and tissue are captured for confirmation", {
  s <- extract_spec_local("i have some human rnaseq data. how to find DE genes")
  expect_equal(s$goal, "analysis")
  expect_equal(extract_spec_local("we plan to grow sorghum under drought")$goal, "design")
  s2 <- extract_spec_local("drought on sorghum, measuring leaf chlorophyll content in the greenhouse")
  expect_match(s2$outcome_text, "chlorophyll")
  expect_null(s2$primary_outcome$name)                                          # free text is never a stated outcome
  expect_equal(extract_spec_local("how cold affects arabidopsis roots")$tissue, "root")
})

test_that("plans open with the skeleton and studyforge_fix() corrects it", {
  a <- studyforge_ask("i have some human rnaseq data. in 5 condition of diets. how to find DE genes.")
  out <- paste(utils::capture.output(print(a)), collapse = "\n")
  expect_match(out, "Here's what I understood")
  expect_match(out, "diet \\(5\\)")
  expect_match(out, "analysis of data you already have")
  b <- studyforge_fix(a, design.reps = 4, tissue = "liver", factors = "diet:5, sex:2")
  expect_equal(b$spec$design$reps, 4)
  expect_equal(b$spec$tissue, "liver")
  expect_equal(vapply(b$spec$factors, `[[`, "", "name"), c("diet", "sex"))
  c2 <- studyforge_fix(b, outcome = "gene_expression")                         # earlier fixes are kept
  expect_equal(c2$spec$design$reps, 4)
  expect_equal(c2$spec$primary_outcome$name, "gene_expression")
})
