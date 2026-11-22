#' Generate a randomized design layout
#'
#' Thin, standardized wrapper over agricolae. Every design returns a data.frame
#' with at least `plot`, `rep`, `block`, `treatment`, so downstream code
#' (power, metadata templates) never depends on agricolae's column naming.
#'
#' @param design One of "crd", "rcbd", "alpha", "split", "factorial", "augmented".
#' @param treatments Character vector of treatments (genotypes). For "split",
#'   these are the whole-plot levels; for "augmented", the new entries.
#' @param reps Replicates (blocks for rcbd/split/factorial/augmented).
#' @param block_size Incomplete block size k (alpha only).
#' @param treatments2 Subplot levels (split only).
#' @param factor_levels Named list of factor levels (factorial only),
#'   e.g. list(water = c("WW","WS"), genotype = c("A","B","C")).
#' @param checks Check entries (augmented only).
#' @param seed Randomization seed (recorded in the output).
#' @export
make_design <- function(design = c("crd", "rcbd", "alpha", "split", "factorial", "augmented"),
                        treatments = NULL, reps, block_size = NULL, treatments2 = NULL,
                        factor_levels = NULL, checks = NULL, seed = 42) {
  design <- match.arg(design)
  quiet <- function(expr) {
    out <- NULL
    utils::capture.output(out <- expr)
    out
  }

  book <- switch(design,
    crd = {
      b <- agricolae::design.crd(treatments, r = reps, seed = seed)$book
      data.frame(plot = b$plots, rep = b$r, block = 1L, treatment = b[[3]])
    },
    rcbd = {
      b <- agricolae::design.rcbd(treatments, r = reps, seed = seed)$book
      data.frame(plot = b$plots, rep = b$block, block = b$block, treatment = b[[3]])
    },
    alpha = {
      if (is.null(block_size)) stop("alpha design needs block_size.", call. = FALSE)
      n <- length(treatments)
      if (n %% block_size != 0) {
        stop(sprintf("alpha: %d treatments not divisible by block_size %d. Try block_size in {%s}.",
                     n, block_size, paste(.divisors(n), collapse = ", ")), call. = FALSE)
      }
      res <- quiet(agricolae::design.alpha(treatments, k = block_size, r = reps, seed = seed))
      if (!is.list(res) || is.null(res$book)) {
        stop(sprintf(paste0("agricolae could not build an alpha design for %d entries, k = %d, r = %d ",
                            "(it needs s = n/k >= k for r = 2, and stricter conditions for more reps)."),
                     n, block_size, reps), call. = FALSE)
      }
      b <- res$book
      data.frame(plot = b$plots, rep = b$replication, block = b$block,
                 col = b$cols, treatment = b[[4]])
    },
    split = {
      if (is.null(treatments2)) stop("split design needs treatments2 (subplot levels).", call. = FALSE)
      b <- agricolae::design.split(treatments, treatments2, r = reps,
                                   design = "rcbd", seed = seed)$book
      data.frame(plot = b$plots, subplot = b$splots, rep = b$block, block = b$block,
                 main = b[[4]], sub = b[[5]],
                 treatment = paste(b[[4]], b[[5]], sep = ":"),
                 treatment_combination = paste(b[[4]], b[[5]], sep = ":"))
    },
    factorial = {
      if (is.null(factor_levels) || is.null(names(factor_levels))) {
        stop("factorial design needs a named list factor_levels.", call. = FALSE)
      }
      b <- agricolae::design.ab(lengths(factor_levels), r = reps,
                                design = "rcbd", seed = seed)$book
      out <- data.frame(plot = b$plots, rep = b$block, block = b$block)
      for (i in seq_along(factor_levels)) {
        out[[names(factor_levels)[i]]] <- factor_levels[[i]][as.integer(b[[2 + i]])]
      }
      # the joined levels go to treatment_combination; treatment holds them too unless a factor is itself
      # called treatment, whose own column must not be overwritten
      out$treatment_combination <- do.call(paste, c(out[names(factor_levels)], sep = ":"))
      if (!"treatment" %in% names(factor_levels)) out$treatment <- out$treatment_combination
      out
    },
    augmented = {
      if (is.null(checks)) stop("augmented design needs checks.", call. = FALSE)
      b <- agricolae::design.dau(checks, treatments, r = reps, seed = seed)$book
      data.frame(plot = b$plots, rep = b$block, block = b$block, treatment = b$trt,
                 is_check = b$trt %in% checks)
    }
  )
  book$treatment <- as.character(book$treatment)
  attr(book, "design") <- design
  attr(book, "seed") <- seed
  book
}

.divisors <- function(n) {
  d <- seq_len(n)
  d[n %% d == 0 & d > 1 & d < n]
}

#' Write the design package to disk
#'
#' @param book Output of make_design().
#' @param spec StudySpec list (see new_spec()).
#' @param outdir Output directory.
#' @param audit Optional unit_audit() result.
#' @param power Optional power result or sensitivity data.frame.
#' @return Character vector of written file paths.
#' @export
write_design_package <- function(book, spec, outdir = "studyforge_run",
                                 audit = NULL, power = NULL) {
  dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
  paths <- character()
  layout <- file.path(outdir, "field_layout.csv")
  utils::write.csv(book, layout, row.names = FALSE)
  paths <- c(paths, layout)

  meta <- book
  meta$sample_id <- sprintf("SF_%s_%04d", attr(book, "design") %||% "x", seq_len(nrow(book)))
  meta$date_measured <- NA
  meta$primary_outcome <- NA
  meta$notes <- NA
  mpath <- file.path(outdir, "sample_metadata_template.tsv")
  utils::write.table(meta, mpath, sep = "\t", row.names = FALSE, quote = FALSE, na = "")
  paths <- c(paths, mpath)

  spec$design$randomization_seed <- attr(book, "seed")
  spec$design$chosen <- attr(book, "design")
  # the analysis model that matches the chosen design (design_catalog.json), so Bioana and Simitall read it
  # from the spec instead of looking it up; y is the primary outcome, terms are the layout's columns
  cat_d <- Filter(function(d) identical(d$id, spec$design$chosen), load_registry("design_catalog")$designs)
  if (length(cat_d)) {
    spec$analysis$model <- cat_d[[1]]$model
    if (!is.null(cat_d[[1]]$analysis_note)) spec$analysis$note <- cat_d[[1]]$analysis_note
    spec$analysis$terms <- .sf_model_terms(spec, book, cat_d[[1]]$model)
    if (length(attr(book, "layout_notes"))) spec$design$layout_notes <- as.list(attr(book, "layout_notes"))
  }
  spec$handoff_version <- load_registry("study_spec.schema")$version
  spath <- file.path(outdir, "study_spec.json")
  jsonlite::write_json(spec, spath, auto_unbox = TRUE, pretty = TRUE, null = "null")
  paths <- c(paths, spath)

  if (!is.null(audit)) {
    apath <- file.path(outdir, "unit_audit.json")
    jsonlite::write_json(audit, apath, auto_unbox = TRUE, pretty = TRUE)
    paths <- c(paths, apath)
  }
  if (!is.null(power)) {
    ppath <- file.path(outdir, "power_sensitivity.tsv")
    p <- if (is.data.frame(power)) power else as.data.frame(power[c("power", "mcse")])
    utils::write.table(p, ppath, sep = "\t", row.names = FALSE, quote = FALSE)
    paths <- c(paths, ppath)
  }
  paths
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# What each generic model term stands for in this study (design_catalog.json model_terms), as layout columns where
# they exist: treatment and treatment2 are the first two randomized factors, time the time factor, block the block
# column, unit the experimental unit. Factors in the layout that the model does not hold are listed in
# uncovered_factors so Bioana can add them as fixed effects (e.g. a third factor, or tissue measured within units).
.sf_model_terms <- function(spec, book = NULL, model = NULL) {
  rf <- .sf_randomized_factors(spec)
  allf <- vapply(spec$factors %||% list(), function(x) x$name %||% "", "")
  mv <- if (!is.null(model)) all.vars(stats::as.formula(model)) else character()
  out <- list(treatment = rf[1], treatment2 = rf[2], time = if ("time" %in% allf) "time", unit = spec$experimental_unit,
              block = unlist(spec$blocking_factors)[1] %||% (if (!is.null(book) && "block" %in% names(book)) "block"))
  if ("time" %in% mv && identical(out$treatment, "time")) out$treatment <- setdiff(rf, "time")[1]
  if ("time" %in% mv && identical(out$treatment2, "time")) out$treatment2 <- setdiff(rf, c("time", out$treatment))[1]
  out <- Filter(function(v) length(v) && !is.na(v), out)
  if (length(mv)) out <- out[intersect(names(out), c(mv, "unit"))]
  if (!is.null(book)) {
    out$layout_columns <- intersect(unlist(out[setdiff(names(out), "unit")]), names(book))
    out$uncovered_factors <- setdiff(intersect(allf, names(book)), unlist(out))
  }
  out
}

#' Build the randomized layout straight from a StudySpec
#'
#' Keeps every factor in the spec. Factors randomized to units are crossed (factorial, or split when one is applied
#' to main plots); factors measured within a unit (rules.tsv within_unit_factor, e.g. tissue) repeat each unit's row.
#' The design is the spec's chosen design, else the first candidate make_design() can build whose catalog model holds
#' the factor structure. Level labels come from `levels` in the spec, else `name_1..name_n`.
#'
#' @param spec A StudySpec (e.g. `studyforge_ask(q)$spec`).
#' @param seed Randomization seed.
#' @return The layout data.frame, with attributes `design`, `seed` and `layout_notes` (every default it used);
#'   an error naming the missing spec field when it cannot build one.
#' @export
layout_from_spec <- function(spec, seed = 42) {
  notes <- character()
  f <- Filter(function(x) nzchar(x$name %||% ""), spec$factors %||% list())
  if (!length(f)) stop("layout_from_spec: the spec has no factors (missing: factors).", call. = FALSE)
  lv <- lapply(f, function(x) {
    if (length(x$levels)) return(as.character(unlist(x$levels)))
    if (is.null(x$n_levels)) return(NULL)
    paste0(x$name, "_", seq_len(as.integer(x$n_levels)))
  })
  names(lv) <- vapply(f, `[[`, "", "name")
  if (any(vapply(lv, is.null, logical(1))))
    stop(sprintf("layout_from_spec: no level count for %s (missing: factors.n_levels).",
                 paste(names(lv)[vapply(lv, is.null, logical(1))], collapse = ", ")), call. = FALSE)
  reps <- spec$design$reps
  if (is.null(reps)) stop("layout_from_spec: no replicate count (missing: design.reps).", call. = FALSE)
  within <- intersect(names(lv), .sf_list("within_unit_factor"))
  rand <- setdiff(names(lv), within)
  if (!length(rand)) { rand <- within[1]; within <- within[-1]; notes <- c(notes, sprintf("%s is the only factor, so it is randomized to units", rand)) }
  buildable <- eval(formals(make_design)$design)
  cand <- unlist(c(spec$design$chosen, spec$design$type, spec$design$candidates, .sf_candidates(spec)))
  cand <- intersect(cand, buildable)
  applied <- setNames(lapply(f, function(x) x$applied_to %||% ""), names(lv))
  design <- if (length(rand) >= 2) {
    if (any(unlist(applied[rand]) %in% "main_plot") && "split" %in% c(cand, "split")) "split" else "factorial"
  } else (utils::head(setdiff(cand, c("split", "factorial")), 1) %||% "rcbd")
  if (!length(design) || is.na(design)) design <- "rcbd"
  if (length(rand) >= 2 && !design %in% cand[1]) notes <- c(notes, sprintf("%d randomized factors (%s): %s design keeps them all", length(rand), paste(rand, collapse = ", "), design))
  book <- switch(design,
    factorial = make_design("factorial", factor_levels = lv[rand], reps = reps, seed = seed),
    split = {
      mp <- rand[unlist(applied[rand]) %in% "main_plot"][1]; sp <- setdiff(rand, mp)
      if (length(sp) > 1) notes <- c(notes, sprintf("split plot holds two factors; %s crossed into the subplot", paste(sp, collapse = " x ")))
      sub <- do.call(paste, c(expand.grid(lv[sp], stringsAsFactors = FALSE), sep = ":"))
      b <- make_design("split", treatments = lv[[mp]], treatments2 = sub, reps = reps, seed = seed)
      b[[mp]] <- b$main; parts <- do.call(rbind, strsplit(b$sub, ":", fixed = TRUE))
      for (i in seq_along(sp)) b[[sp[i]]] <- parts[, i]
      b
    },
    alpha = {
      # block size: the spec's, else divisors of the entry count from the square root down (agricolae needs n/k >= k)
      n <- length(lv[[rand]]); d <- .divisors(n)
      ks <- unique(c(spec$design$block_size, rev(d[d <= sqrt(n)]), d))
      b <- NULL
      for (k in ks) { b <- tryCatch(make_design("alpha", treatments = lv[[rand]], reps = reps, block_size = k, seed = seed),
                                    error = function(e) NULL); if (!is.null(b)) break }
      if (is.null(b)) {
        notes <- c(notes, sprintf("no alpha lattice exists for %d entries x %d reps; complete blocks (rcbd) used instead (add filler entries or use row-column for incomplete blocks)", n, reps))
        b <- make_design("rcbd", treatments = lv[[rand]], reps = reps, seed = seed)
      } else if (!identical(k, spec$design$block_size)) notes <- c(notes, sprintf("block size %d for %d entries (spec has no usable design.block_size)", k, n))
      b[[rand]] <- b$treatment; b
    },
    augmented = stop("layout_from_spec: augmented designs need check entries (missing: design.checks).", call. = FALSE),
    { b <- make_design(design, treatments = lv[[rand]], reps = reps, seed = seed); b[[rand]] <- b$treatment; b })
  if (length(within)) {
    grid <- expand.grid(lv[within], stringsAsFactors = FALSE)
    idx <- rep(seq_len(nrow(book)), each = nrow(grid))
    book2 <- book[idx, , drop = FALSE]
    for (w in within) book2[[w]] <- rep(grid[[w]], times = nrow(book))
    rownames(book2) <- NULL
    attr(book2, "design") <- attr(book, "design"); attr(book2, "seed") <- attr(book, "seed")
    notes <- c(notes, sprintf("%s measured within each unit: one row per unit and level", paste(within, collapse = " x ")))
    book <- book2
  }
  attr(book, "layout_notes") <- notes
  book
}
