test_that("tray design puts every check in every tray and fills guard edges", {
  b <- make_tray_design(paste0("A", 1:200), c("Col-0", "Ler"), tray_rows = 6, tray_cols = 8)
  expect_equal(max(b$tray), 10)
  expect_equal(sum(b$role == "entry"), 200)
  expect_true(all(table(b$tray[b$role == "check"], b$genotype[b$role == "check"]) == 1))
  expect_true(all(b$role[b$is_edge] == "guard"))
  expect_equal(nrow(b), 10 * 48)
})

test_that("tray design errors when trays are too small or too few", {
  expect_error(make_tray_design("A1", c("C1", "C2"), 3, 3), "usable cells")
  expect_error(make_tray_design(paste0("A", 1:100), "C1", 6, 8, n_trays = 2), "at least")
})

test_that("tray design without guards uses all cells", {
  b <- make_tray_design(paste0("A", 1:40), "C1", 6, 8, guard_edges = FALSE)
  expect_equal(max(b$tray), 1)
  expect_false(any(b$role == "guard"))
})

test_that("field coordinates: unique positions, border ring, serpentine", {
  book <- make_design("rcbd", paste0("G", 1:12), reps = 3)
  f <- add_field_coordinates(book, n_cols = 6)
  expect_false(any(duplicated(paste(f$row, f$col))))
  expect_equal(sum(f$role == "plot"), 36)
  expect_equal(sum(f$role == "border"), 2 * 8 + 2 * 6)
  nb <- add_field_coordinates(book, n_cols = 6, border = FALSE)
  first <- nb[nb$row == 1, ]
  second <- nb[nb$row == 2, ]
  expect_true(first$col[first$plot == min(first$plot)] == 1)
  expect_true(second$col[second$plot == min(second$plot)] == 6)
})

test_that("vial allocation gives every rearing bottle one vial per treatment", {
  v <- make_vial_allocation(c("DR", "AL", "Rapa"), vials_per_treatment = 15, flies_per_vial = 10)
  expect_true(all(table(v$rearing_bottle, v$treatment) == 1))
  expect_equal(attr(v, "flies_per_treatment"), 150)
  expect_false(any(duplicated(paste(v$tray, v$tray_position))))
})

test_that("cage allocation: individual dosing mixes groups, cage delivery does not", {
  ind <- make_cage_allocation(c("ctrl", "drug"), 8, 4, "individual")
  per_cage <- tapply(ind$group, ind$cage, function(x) length(unique(x)))
  expect_true(all(per_cage == 2))
  expect_true(all(tapply(ind$sex, ind$cage, function(x) length(unique(x))) == 1))
  cg <- make_cage_allocation(c("LF", "HF"), 8, 4, "cage")
  expect_true(all(tapply(cg$group, cg$cage, function(x) length(unique(x))) == 1))
  expect_equal(attr(cg, "true_n"), 2)
  expect_equal(attr(cg, "unit"), "cage")
  expect_error(make_cage_allocation(c("a", "b"), 7, 4, "cage"), "multiple")
})

test_that("resource equation matches the published formula", {
  r <- resource_equation_n(4)
  expect_equal(r$min_per_group, 4)
  expect_equal(r$max_per_group, 6)
  expect_gt(resource_equation_n(4, attrition = 0.2)$min_per_group, 4)
})

test_that("hazards and protocol notes are queryable and cited", {
  hz <- load_registry("setup_hazards")$hazards
  expect_gte(length(hz), 35)
  for (h in hz) {
    expect_true(all(c("id", "system", "hazard", "mitigation", "source") %in% names(h)), info = h$id)
    expect_true(nzchar(h$source), info = h$id)
  }
  expect_false(anyDuplicated(vapply(hz, `[[`, "", "id")) > 0)
  expect_true(all(vapply(setup_hazards("drosophila"), `[[`, "", "system") == "drosophila"))
  expect_gte(length(protocol_notes(system = "field")), 8)
  expect_length(protocol_notes("larval density"), 2)
  notes <- load_registry("protocol_notes")$notes
  expect_gte(length(notes), 25)
  expect_false(anyDuplicated(vapply(notes, `[[`, "", "id")) > 0)
})
