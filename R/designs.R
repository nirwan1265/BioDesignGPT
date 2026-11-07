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
                 treatment = paste(b[[4]], b[[5]], sep = ":"))
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
      out$treatment <- do.call(paste, c(out[names(factor_levels)], sep = ":"))
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
