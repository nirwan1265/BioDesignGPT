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
  s2 <- extract_spec_local("drought on sorghum, measuring leaf wax bloom in the greenhouse")
  expect_match(s2$outcome_text, "wax bloom")
  expect_null(s2$primary_outcome$name)                                          # free text is never a stated outcome
  s3 <- extract_spec_local("drought on sorghum, measuring leaf chlorophyll content in the greenhouse")
  expect_equal(s3$primary_outcome$name, "chlorophyll_content")                  # a vocabulary outcome in that phrase is
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

test_that("a coordinated list of line groups adds each conjunct's number, or 1", {
  g <- function(t) .sf_level_factors(t)[["genotype"]]
  expect_equal(g("rna-seq of four commercial cultivars and two hybrids under drought"), 6)
  expect_equal(g("leaves of two wild and two cultivated accessions, 3 replicates"), 4)
  expect_equal(g("a hybrid and its two parents grown in a greenhouse"), 3)
  expect_equal(g("wild type and two named mutants, salt vs control"), 3)
  expect_equal(g("wild type, mutant and complemented lines"), 3)
  expect_false(identical(g("blocks of 20 plots (18 lines plus 2 checks)"), 20))   # one block's contents
  expect_false(identical(g("at 10 dpi, 4 birds per line"), 14))                  # a comma alone is not a list
})

test_that("checklist questions the prompt already answers are not asked again", {
  a <- studyforge_ask("GWAS for grain yield in 200 maize inbred lines, 2 reps, RCBD in the field")
  expect_false(any(grepl("^Primary outcome and its unit", a$all_questions)))
  expect_false(any(grepl("^Number of entries/genotypes", a$all_questions)))
  expect_false("design.candidates" %in% a$validation$missing)
  b <- studyforge_ask("120 maize lines for drought tolerance at two locations")   # no outcome stated
  expect_true(any(grepl("^Primary outcome and its unit", b$all_questions)))
})

test_that("a factor without a level count, or no factor at all, is asked about", {
  a <- studyforge_ask("RNA-seq of Arabidopsis wild type and photolesion repair mutants under UV, 3 replicates")
  g <- Filter(function(f) identical(f$name, "genotype"), a$spec$factors)
  expect_length(g, 1); expect_null(g[[1]]$n_levels)
  expect_true("factors.genotype.n_levels" %in% a$validation$missing)
  expect_match(a$all_questions[1], "How many genotypes")
  b <- studyforge_ask("Leaf RNA-seq of maize sampled at several time points after drought vs control, 3 replicates")
  expect_true(any(grepl("How many time points", b$all_questions)))
  m <- studyforge_ask("How many macaques do I need for mapping genetic effects on DNA methylation?")
  expect_match(m$all_questions[1], "What do you compare or map")
})
