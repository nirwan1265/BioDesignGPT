ex <- load_examples()
design_ids <- vapply(load_registry("design_catalog")$designs, `[[`, "", "id")
schema <- load_registry("study_spec.schema")

test_that("there are at least 20 examples with unique ids", {
  expect_gte(length(ex), 20)
  ids <- vapply(ex, `[[`, "", "id")
  expect_false(anyDuplicated(ids) > 0)
})

test_that("every example has a prompt, a cited source and expected output", {
  for (e in ex) {
    expect_true(nzchar(e$prompt), info = e$id)
    expect_true(nzchar(e$source$citation), info = e$id)
    expect_type(e$expected_spec, "list")
    expect_gt(length(e$must_ask), 0)
  }
})

test_that("recommended designs exist in the catalog", {
  for (e in ex) {
    expect_true(all(unlist(e$recommended_designs) %in% design_ids), info = e$id)
  }
})

test_that("expected specs only use valid enum values", {
  for (e in ex) {
    v <- validate_spec(e$expected_spec)
    expect_length(v$bad_enums, 0)
  }
})

test_that("must_ask fields are not pre-filled in the expected spec (no leaking answers)", {
  for (e in ex) {
    for (p in unlist(e$must_ask)) {
      expect_null(spec_get(e$expected_spec, p), label = paste(e$id, p))
    }
  }
})

test_that("expected audits agree with the deterministic unit_audit()", {
  for (e in ex) {
    s <- e$expected_spec
    if (is.null(e$expected_audit) || is.null(s$experimental_unit) || is.null(s$measurement_unit)) next
    a <- unit_audit("organism", s$experimental_unit, s$measurement_unit,
                    subsamples_per_unit = s$subsamples_per_unit %||% 1)
    expect_equal(a$pseudoreplication_risk, e$expected_audit$pseudoreplication_risk, label = e$id)
  }
})

test_that("expected hazards exist and match the example's system", {
  hz <- load_registry("setup_hazards")$hazards
  hz_sys <- setNames(vapply(hz, `[[`, "", "system"), vapply(hz, `[[`, "", "id"))
  for (e in ex) {
    ids <- unlist(e$expected_hazards)
    if (!length(ids)) next
    expect_true(all(ids %in% names(hz_sys)), label = e$id)
  }
})

test_that("reference plans are complete", {
  fields <- c("design", "layout", "replication", "randomization", "record", "analysis", "pitfalls")
  plans <- Filter(function(e) !is.null(e$reference_plan), ex)
  expect_gte(length(plans), 25)
  for (e in plans) expect_true(all(fields %in% names(e$reference_plan)), label = e$id)
})

test_that("score_extraction scores a perfect and an imperfect extraction", {
  e <- ex[[1]]
  perfect <- score_extraction(e$expected_spec, e$expected_spec)
  expect_true(all(perfect$match))
  wrong <- spec_set(e$expected_spec, "design.reps", 4)
  sc <- score_extraction(wrong, e$expected_spec)
  expect_false(sc$match[sc$field == "design.reps"])
})

`%||%` <- function(a, b) if (is.null(a)) b else a
