test_that("rules.tsv: well-formed, every category and cue the code asks for exists, every pattern compiles", {
  t <- .sf_rules_table()
  expect_named(t, c("category", "term", "match", "pattern", "note", "source"))
  expect_true(all(t$match %in% c("word", "regex", "value")))
  expect_false(any(t$category == "" | t$pattern == "" & t$match != "value"))
  rx <- t[t$match == "regex", ]
  for (i in seq_len(nrow(rx))) {
    v <- if (rx$category[i] == "cue") .sf_cue(rx$term[i]) else rx$pattern[i]
    expect_silent(grepl(v, "", perl = TRUE))
  }
  expect_false(anyDuplicated(rx$term[rx$category == "cue"]) > 0)
  src <- test_path("..", "..", "R")
  skip_if_not(dir.exists(src))
  code <- paste(unlist(lapply(list.files(src, full.names = TRUE), readLines)), collapse = "\n")
  used <- function(fn) unique(sub('.*\\("([a-z_]+)".*', "\\1", regmatches(code, gregexpr(paste0("\\", fn, '\\("[a-z_]+"'), code))[[1]]))
  expect_setequal(setdiff(used(".sf_cue"), rx$term[rx$category == "cue"]), character())
  for (fn in c(".sf_list", ".sf_map", ".sf_rules", ".sf_group", ".sf_groups"))
    expect_setequal(setdiff(used(fn), t$category), character())
})

test_that("rules.tsv: the reader's vocabulary is vocabulary the rest of the system knows", {
  al <- .sf_alias_table()
  expect_setequal(setdiff(.sf_list("reader_assay"), al$canonical_term[al$category == "assay"]), character())
  sys <- c(vapply(load_registry("experimental_systems")$systems, `[[`, "", "id"), names(.sf_rules("setting")))
  expect_setequal(setdiff(.sf_list("reader_system"), sys), character())
  for (s in load_registry("experimental_systems")$systems)
    if (identical(s$kind, "assay")) expect_true(s$assay %in% al$canonical_term[al$category == "assay"])
})
