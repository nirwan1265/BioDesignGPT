#' Augmented-by-tray layout with checks in every tray and guard edges
#'
#' For seedling trays or flats in chambers and greenhouses. Every tray gets
#' each check `check_copies` times so tray effects can be estimated; entries are
#' spread as evenly as possible across trays; edge cells can be reserved for
#' guard (unmeasured) plants.
#'
#' @param entries Character vector of test entries (genotypes).
#' @param checks Character vector of reference/check genotypes (>= 1).
#' @param tray_rows,tray_cols Cell grid of one tray (e.g. 6 x 8 for a 48-cell tray).
#' @param n_trays Number of trays; if NULL, the minimum that fits.
#' @param check_copies Copies of each check per tray.
#' @param entry_reps Replicates of each entry (usually 1 in augmented designs).
#' @param guard_edges If TRUE, outer-ring cells hold guard plants and are not measured.
#' @param seed Randomization seed.
#' @return data.frame: tray, cell_row, cell_col, role (entry/check/guard/empty), genotype.
#' @export
make_tray_design <- function(entries, checks, tray_rows, tray_cols, n_trays = NULL,
                             check_copies = 1, entry_reps = 1, guard_edges = TRUE,
                             seed = 42) {
  stopifnot(length(checks) >= 1, tray_rows >= 1, tray_cols >= 1)
  grid <- expand.grid(cell_col = seq_len(tray_cols), cell_row = seq_len(tray_rows))[, 2:1]
  edge <- grid$cell_row %in% c(1, tray_rows) | grid$cell_col %in% c(1, tray_cols)
  usable <- if (guard_edges) sum(!edge) else nrow(grid)
  per_tray_checks <- length(checks) * check_copies
  per_tray_entries <- usable - per_tray_checks
  if (per_tray_entries < 1) {
    stop(sprintf("Each tray has %d usable cells but needs %d for checks; use bigger trays, fewer check copies, or guard_edges = FALSE.",
                 usable, per_tray_checks), call. = FALSE)
  }
  slots <- rep(entries, each = entry_reps)
  min_trays <- ceiling(length(slots) / per_tray_entries)
  if (is.null(n_trays)) n_trays <- min_trays
  if (n_trays < min_trays) {
    stop(sprintf("%d entry slots need at least %d trays (%d entry cells per tray).",
                 length(slots), min_trays, per_tray_entries), call. = FALSE)
  }
  set.seed(seed)
  # spread entries evenly, and never put two reps of one entry in the same tray when avoidable
  slots <- slots[order(rep(seq_len(entry_reps), times = length(entries)), stats::runif(length(slots)))]
  tray_of_slot <- rep_len(sample(seq_len(n_trays)), length(slots))

  out <- lapply(seq_len(n_trays), function(t) {
    g <- grid
    g$tray <- t
    g$is_edge <- edge
    g$role <- if (guard_edges) ifelse(edge, "guard", NA) else NA
    g$genotype <- if (guard_edges) ifelse(edge, "GUARD", NA) else NA
    free <- which(is.na(g$role))
    content <- c(rep(checks, check_copies), slots[tray_of_slot == t])
    role <- c(rep("check", per_tray_checks), rep("entry", sum(tray_of_slot == t)))
    pos <- sample(free, length(content))
    g$role[pos] <- role
    g$genotype[pos] <- content
    g$role[is.na(g$role)] <- "empty"
    g$genotype[is.na(g$genotype)] <- ""
    g
  })
  book <- do.call(rbind, out)
  book <- book[, c("tray", "cell_row", "cell_col", "is_edge", "role", "genotype")]
  rownames(book) <- NULL
  attr(book, "design") <- "augmented_tray"
  attr(book, "seed") <- seed
  book
}

#' Map a design book onto a field grid
#'
#' Assigns row/column coordinates in planting order (rep, then block, then plot),
#' optionally serpentine, and adds a ring of border plots. Coordinates are what
#' spatial analysis (SpATS, AR1xAR1) needs.
#'
#' @param book Output of make_design().
#' @param n_cols Plots per field row (columns).
#' @param serpentine Reverse direction on alternate rows (planter path).
#' @param border Add one ring of border (filler) plots around the trial.
#' @return data.frame with row, col and role ("plot" or "border").
#' @export
add_field_coordinates <- function(book, n_cols, serpentine = TRUE, border = TRUE) {
  ord <- order(book$rep, book$block, book$plot)
  b <- book[ord, , drop = FALSE]
  i <- seq_len(nrow(b)) - 1
  b$row <- i %/% n_cols + 1
  pos <- i %% n_cols + 1
  b$col <- if (serpentine) ifelse(b$row %% 2 == 0, n_cols - pos + 1, pos) else pos
  b$role <- "plot"
  if (border) {
    b$row <- b$row + 1
    b$col <- b$col + 1
    nr <- max(b$row) + 1
    nc <- n_cols + 2
    ring <- expand.grid(row = seq_len(nr), col = seq_len(nc))
    ring <- ring[ring$row %in% c(1, nr) | ring$col %in% c(1, nc), ]
    filler <- as.data.frame(lapply(b[0, setdiff(names(b), c("row", "col", "role")), drop = FALSE],
                                   function(x) rep(x[NA_integer_], nrow(ring))))
    filler$row <- ring$row
    filler$col <- ring$col
    filler$role <- "border"
    filler$treatment <- "BORDER"
    b <- rbind(b, filler[, names(b)])
  }
  b <- b[order(b$row, b$col), ]
  rownames(b) <- NULL
  attr(b, "design") <- attr(book, "design")
  attr(b, "seed") <- attr(book, "seed")
  b
}

#' Drosophila vial allocation blocked by rearing bottle
#'
#' Each rearing bottle supplies one vial to every treatment (Piper & Partridge
#' 2016), and vials are placed in random tray positions.
#'
#' @param treatments Character vector of treatments (diets, drugs, genotypes).
#' @param vials_per_treatment Replicate vials per treatment (= number of rearing bottles).
#' @param flies_per_vial Flies per vial (10-15 recommended for lifespan).
#' @param vials_per_tray Tray capacity.
#' @param seed Randomization seed.
#' @export
make_vial_allocation <- function(treatments, vials_per_treatment, flies_per_vial = 10,
                                 vials_per_tray = 25, seed = 42) {
  set.seed(seed)
  d <- expand.grid(treatment = treatments, rearing_bottle = seq_len(vials_per_treatment),
                   stringsAsFactors = FALSE)
  d <- d[order(d$rearing_bottle, stats::runif(nrow(d))), ]
  d$vial_id <- sprintf("V%03d", seq_len(nrow(d)))
  slot <- sample(nrow(d))
  d$tray <- (slot - 1) %/% vials_per_tray + 1
  d$tray_position <- (slot - 1) %% vials_per_tray + 1
  d$flies_per_vial <- flies_per_vial
  d <- d[, c("vial_id", "rearing_bottle", "treatment", "flies_per_vial", "tray", "tray_position")]
  rownames(d) <- NULL
  attr(d, "design") <- "vial_lifespan"
  attr(d, "seed") <- seed
  attr(d, "flies_per_treatment") <- vials_per_treatment * flies_per_vial
  d
}

#' Mouse cage allocation that avoids treatment-cage confounding
#'
#' @param groups Character vector of treatment groups.
#' @param n_per_group Animals per group per sex.
#' @param per_cage Animals per cage.
#' @param delivery "individual" (dosing per mouse: cages are mixed, so cage is a
#'   block) or "cage" (diet/water: whole cage gets one treatment, so cage is the unit).
#' @param sexes Sexes to include; cages are single-sex.
#' @param seed Randomization seed.
#' @return data.frame of animals with cage and group; attribute `true_n` gives
#'   experimental units per group.
#' @export
make_cage_allocation <- function(groups, n_per_group, per_cage = 4,
                                 delivery = c("individual", "cage"),
                                 sexes = c("F", "M"), seed = 42) {
  delivery <- match.arg(delivery)
  set.seed(seed)
  out <- list()
  cage_counter <- 0
  for (s in sexes) {
    if (delivery == "cage") {
      if (n_per_group %% per_cage != 0) {
        stop("With cage-level delivery, n_per_group must be a multiple of per_cage.", call. = FALSE)
      }
      cages_per_group <- n_per_group / per_cage
      cage_group <- sample(rep(groups, each = cages_per_group))
      cages <- cage_counter + seq_along(cage_group)
      cage_counter <- max(cages)
      out[[s]] <- data.frame(sex = s, cage = rep(cages, each = per_cage),
                             group = rep(cage_group, each = per_cage))
    } else {
      # rounds of one animal per group (random order), filled into cages consecutively,
      # so every cage holds animals from several groups; then shuffle cage labels
      animals <- unlist(lapply(seq_len(n_per_group), function(i) sample(groups)))
      n_cages <- ceiling(length(animals) / per_cage)
      cage <- rep(seq_len(n_cages), each = per_cage)[seq_along(animals)]
      cage <- (sample(n_cages) + cage_counter)[cage]
      cage_counter <- cage_counter + n_cages
      out[[s]] <- data.frame(sex = s, cage = cage, group = animals)
    }
  }
  d <- do.call(rbind, out)
  d <- d[order(d$cage), ]
  d$animal_id <- sprintf("M%03d", seq_len(nrow(d)))
  rownames(d) <- NULL
  d <- d[, c("animal_id", "sex", "cage", "group")]
  attr(d, "design") <- paste0("cage_", delivery)
  attr(d, "seed") <- seed
  attr(d, "true_n") <- if (delivery == "cage") n_per_group / per_cage else n_per_group
  attr(d, "unit") <- if (delivery == "cage") "cage" else "mouse"
  d
}

#' Resource-equation sample size range (when no SD is available)
#'
#' Error df E = N - k should lie between 10 and 20 (Arifin & Zahiruddin 2017).
#'
#' @param k Number of groups (one-way design).
#' @param attrition Expected proportion lost; inflates n.
#' @return list(min_per_group, max_per_group, note)
#' @export
resource_equation_n <- function(k, attrition = 0) {
  stopifnot(k >= 2, attrition >= 0, attrition < 1)
  lo <- ceiling((10 / k + 1) / (1 - attrition))
  hi <- floor((20 / k + 1) / (1 - attrition))
  list(min_per_group = lo, max_per_group = hi,
       note = "Resource equation (error df 10-20). Use a power analysis instead whenever an SD and effect of interest are available.",
       source = "Arifin & Zahiruddin 2017, doi:10.21315/mjms2017.24.5.11")
}

#' Setup hazards for an experimental system
#' @param system System id (field, greenhouse, growth_chamber, mouse, drosophila).
#' @param ids Optional hazard ids to return.
#' @export
setup_hazards <- function(system = NULL, ids = NULL) {
  hz <- load_registry("setup_hazards")$hazards
  if (!is.null(system)) hz <- Filter(function(h) h$system %in% system, hz)
  if (!is.null(ids)) hz <- Filter(function(h) h$id %in% ids, hz)
  hz
}

#' Search protocol notes taken from published methods
#' @param query Text to match against id, citation, tags and lesson (case-insensitive).
#' @param system Optional system filter.
#' @export
protocol_notes <- function(query = NULL, system = NULL) {
  notes <- load_registry("protocol_notes")$notes
  if (!is.null(system)) notes <- Filter(function(n) n$system %in% system, notes)
  if (!is.null(query) && nzchar(query)) {
    words <- tolower(strsplit(query, "\\s+")[[1]])
    notes <- Filter(function(n) {
      hay <- tolower(paste(n$id, n$citation, paste(unlist(n$tags), collapse = " "), n$lesson))
      all(vapply(words, grepl, logical(1), x = hay, fixed = TRUE))
    }, notes)
  }
  notes
}
