test_that("rules.tsv: every table and cue the code asks for exists, and every pattern compiles", {
  t <- .sf_rules_table()
  expect_true(all(c("table", "key", "value", "note") %in% names(t)))
  pats <- t[t$table %in% c("cue", "organism", "system", "setting", "outcome"), ]
  for (i in seq_len(nrow(pats))) {
    v <- if (pats$table[i] == "cue") .sf_cue(pats$key[i]) else pats$value[i]
    expect_silent(grepl(v, "", perl = TRUE))
  }
  expect_false(anyDuplicated(t$key[t$table == "cue"]) > 0)
  src <- c(test_path("..", "..", "R"))
  skip_if_not(dir.exists(src))
  code <- paste(unlist(lapply(list.files(src, full.names = TRUE), readLines)), collapse = "\n")
  used <- function(fn) unique(regmatches(code, gregexpr(paste0("\\", fn, '\\("[a-z_]+"\\)'), code))[[1]])
  name <- function(x) sub('.*\\("([a-z_]+)"\\)', "\\1", x)
  expect_setequal(setdiff(name(used(".sf_cue")), t$key[t$table == "cue"]), character())
  for (fn in c(".sf_list", ".sf_map", ".sf_rules")) expect_setequal(setdiff(name(used(fn)), t$table), character())
})

test_that("rules.tsv: the reader's vocabulary is vocabulary the rest of the system knows", {
  al <- .sf_alias_table()
  expect_setequal(setdiff(.sf_list("reader_assay"), al$canonical_term[al$category == "assay"]), character())
  sys <- c(vapply(load_registry("experimental_systems")$systems, `[[`, "", "id"), names(.sf_rules("setting")))
  expect_setequal(setdiff(.sf_list("reader_system"), sys), character())
  reg <- load_registry("experimental_systems")$systems
  for (s in reg) if (identical(s$kind, "assay")) expect_true(s$assay %in% al$canonical_term[al$category == "assay"])
})
