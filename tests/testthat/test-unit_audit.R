test_that("leaves within a pot are flagged as pseudoreplication", {
  a <- unit_audit("plant", "pot", "leaf", subsamples_per_unit = 3, units_per_group = 6)
  expect_equal(a$pseudoreplication_risk, "high")
  expect_equal(a$effective_n_per_group, 6)
  expect_equal(a$nominal_n_per_group, 18)
  expect_equal(a$analysis_unit, "pot_mean")
})

test_that("matching units carry no risk", {
  a <- unit_audit("mouse", "mouse", "mouse")
  expect_equal(a$pseudoreplication_risk, "none")
  expect_length(a$rules, 0)
})

test_that("cage-delivered treatment triggers the ARRIVE rule even without subsamples", {
  a <- unit_audit("mouse", "cage", "mouse")
  expect_equal(a$pseudoreplication_risk, "high")
  expect_true("mice_within_cage_cage_treatment" %in% vapply(a$rules, `[[`, "", "id"))
})

test_that("unknown nesting asks for a check rather than guessing", {
  a <- unit_audit("plant", "plot", "tiller", subsamples_per_unit = 1)
  expect_equal(a$pseudoreplication_risk, "check")
})

test_that("invalid subsample count errors", {
  expect_error(unit_audit("plant", "pot", "leaf", subsamples_per_unit = 0))
})
