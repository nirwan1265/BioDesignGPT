#' Create an empty StudySpec
#' @export
new_spec <- function() {
  list(status = "needs_clarification", assumptions = list())
}

#' Set a (dotted) field in a StudySpec
#'
#' @param spec StudySpec list.
#' @param path Dotted path, e.g. "power.residual_sd".
#' @param value Value to store.
#' @param assumption If TRUE, the value is recorded as an assumption rather
#'   than a user-stated fact, and listed in spec$assumptions.
#' @export
spec_set <- function(spec, path, value, assumption = FALSE) {
  keys <- strsplit(path, ".", fixed = TRUE)[[1]]
  spec <- .set_in(spec, keys, value)
  if (isTRUE(assumption)) spec$assumptions[[path]] <- value
  spec
}

.set_in <- function(x, keys, value) {
  if (length(keys) == 1) {
    x[[keys]] <- value
    return(x)
  }
  child <- x[[keys[1]]]
  if (is.null(child)) child <- list()
  x[[keys[1]]] <- .set_in(child, keys[-1], value)
  x
}

#' Get a dotted field from a StudySpec (NULL if missing)
#' @param spec StudySpec list.
#' @param path Dotted path.
#' @export
spec_get <- function(spec, path) {
  keys <- strsplit(path, ".", fixed = TRUE)[[1]]
  for (k in keys) {
    if (!is.list(spec) || is.null(spec[[k]])) return(NULL)
    spec <- spec[[k]]
  }
  spec
}

#' Validate a StudySpec against the bundled schema
#'
#' @param spec StudySpec list.
#' @return list(valid, missing, bad_enums, status)
#' @export
validate_spec <- function(spec) {
  schema <- load_registry("study_spec.schema")
  req <- unlist(schema$consequential)
  missing <- req[vapply(req, function(p) is.null(spec_get(spec, p)), logical(1))]

  bad <- character()
  for (field in names(schema$enums)) {
    v <- spec_get(spec, field)
    if (!is.null(v) && !all(unlist(v) %in% unlist(schema$enums[[field]]))) {
      bad <- c(bad, sprintf("%s = '%s'", field, paste(unlist(v), collapse = ",")))
    }
  }
  design_ids <- vapply(load_registry("design_catalog")$designs, `[[`, "", "id")
  cand <- unlist(spec_get(spec, "design.candidates"))
  if (length(cand) && !all(cand %in% design_ids)) {
    bad <- c(bad, sprintf("design.candidates contains unknown id(s): %s",
                          paste(setdiff(cand, design_ids), collapse = ",")))
  }

  status <- if (length(missing) || length(bad)) {
    "needs_clarification"
  } else if (length(spec$assumptions)) {
    "assumptions_flagged"
  } else {
    "validated"
  }
  list(valid = !length(missing) && !length(bad), missing = missing,
       bad_enums = bad, status = status)
}
