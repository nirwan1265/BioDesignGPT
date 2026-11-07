test_that("every registry parses as JSON", {
  for (r in list_registries()) {
    expect_type(load_registry(r), "list")
  }
  expect_true(all(c("design_catalog", "pseudoreplication_rules", "experimental_units",
                    "experimental_systems", "study_spec.schema") %in% list_registries()))
})

test_that("design catalog entries have the fields the agent relies on", {
  for (d in load_registry("design_catalog")$designs) {
    expect_true(all(c("id", "name", "use_when", "strength", "tradeoff", "model", "systems") %in% names(d)),
                info = d$id)
  }
})

test_that("ids are unique", {
  ids <- vapply(load_registry("design_catalog")$designs, `[[`, "", "id")
  expect_false(anyDuplicated(ids) > 0)
  rid <- vapply(load_registry("pseudoreplication_rules")$rules, `[[`, "", "id")
  expect_false(anyDuplicated(rid) > 0)
})

test_that("every pseudoreplication rule cites a source", {
  for (r in load_registry("pseudoreplication_rules")$rules) {
    expect_true(nzchar(r$source %||% ""), info = r$id)
  }
})

test_that("lookups work and fail loudly", {
  expect_equal(lookup_design("split")$engine, "agricolae::design.split")
  expect_error(lookup_design("latin_hypercube"), "not in catalog")
  expect_true("alpha" %in% designs_for_system("field"))
  expect_false("augmented" %in% designs_for_system("mouse"))
  expect_gt(length(system_questions("greenhouse")), 2)
  expect_length(match_pseudoreplication_rules("leaf", "plant"), 1)
})

`%||%` <- function(a, b) if (is.null(a)) b else a
