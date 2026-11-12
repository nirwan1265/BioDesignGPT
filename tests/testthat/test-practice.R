test_that("published practice summarises real studies with citations", {
  p <- published_practice("sorghum", "RNA-seq")
  expect_s3_class(p, "studyforge_practice")
  expect_equal(p$organism, "Sorghum bicolor")
  expect_equal(p$technique, "Bulk RNA-seq")
  expect_gt(p$summary$n_designed, 50)
  expect_true(p$summary$reps_median >= 1 && p$summary$reps_median <= 12)
  expect_true(nrow(p$studies) >= 1)
  expect_true(all(grepl("^10\\.", p$studies$doi)))
})

test_that("aliases, tissues and listing work", {
  expect_equal(published_practice("corn", "ATAC-seq")$organism, "Zea mays")
  expect_equal(published_practice("mice", "ChIP-seq")$organism, "Mus musculus")
  leaf <- published_practice("sorghum", "rnaseq", "leaves")
  expect_equal(leaf$tissue, "leaf")
  odd <- published_practice("sorghum", "RNA-seq", "a tissue nobody sampled")
  expect_equal(odd$tissue, "all")
  expect_match(odd$note, "showing all tissues")
  lst <- published_practice("arabidopsis")
  expect_s3_class(lst, "data.frame")
  expect_true("Bulk RNA-seq" %in% lst$technique)
})

test_that("unknown organisms and techniques return a note, never invented numbers", {
  u <- published_practice("unicorn", "RNA-seq")
  expect_null(u$summary)
  expect_match(u$note, "No published-practice data")
  t <- published_practice("sorghum", "telepathy-seq")
  expect_null(t$summary)
})

test_that("plans cite published practice for omics prompts", {
  ans <- studyforge_ask("RNA-seq of sorghum leaves under drought vs control with 2 replicates")
  expect_false(is.null(ans$practice))
  out <- paste(utils::capture.output(print(ans)), collapse = "\n")
  expect_match(out, "Published practice")
  expect_match(out, "doi:10\\.")
  expect_match(out, "fewer than the median of these studies")
  expect_equal(ans$practice$tissue, "leaf")          # tissue picked up from "leaves" in the question
})
