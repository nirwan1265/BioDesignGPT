test_that("spec_set / spec_get handle dotted paths", {
  s <- spec_set(new_spec(), "power.residual_sd", 2.1)
  expect_equal(spec_get(s, "power.residual_sd"), 2.1)
  expect_null(spec_get(s, "power.alpha"))
})

test_that("assumptions are tracked separately", {
  s <- spec_set(new_spec(), "power.residual_sd", 2, assumption = TRUE)
  expect_equal(s$assumptions[["power.residual_sd"]], 2)
})

test_that("validation reports missing fields and bad enums", {
  s <- spec_set(new_spec(), "system", "orchard")
  v <- validate_spec(s)
  expect_false(v$valid)
  expect_true("goal" %in% v$missing)
  expect_match(v$bad_enums[1], "system")
})

complete_spec <- function() {
  s <- new_spec()
  s <- spec_set(s, "system", "field")
  s <- spec_set(s, "goal", "compare yield")
  s <- spec_set(s, "primary_outcome.name", "yield")
  s <- spec_set(s, "primary_outcome.type", "continuous")
  s <- spec_set(s, "experimental_unit", "plot")
  s <- spec_set(s, "factors", list(list(name = "genotype", n_levels = 10)))
  s <- spec_set(s, "design.candidates", c("rcbd", "alpha"))
  s <- spec_set(s, "power.minimum_detectable_difference", 0.5)
  spec_set(s, "power.residual_sd", 1)
}

test_that("a complete spec validates; an assumed value downgrades status", {
  expect_equal(validate_spec(complete_spec())$status, "validated")
  s <- spec_set(complete_spec(), "power.residual_sd", 1, assumption = TRUE)
  expect_equal(validate_spec(s)$status, "assumptions_flagged")
})

test_that("unknown candidate designs are rejected", {
  s <- spec_set(complete_spec(), "design.candidates", c("rcbd", "magic"))
  expect_false(validate_spec(s)$valid)
})
