#' Load the bundled prompt -> expected-spec examples
#' @param path Path to a JSONL file (defaults to the bundled one).
#' @return A list of examples.
#' @export
load_examples <- function(path = system.file("examples", "study_examples.jsonl", package = "studyforge")) {
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(trimws(lines))]
  lapply(lines, jsonlite::fromJSON, simplifyVector = FALSE)
}

#' Score an extracted spec against an expected spec
#'
#' Compares only the fields present in `expected` (dotted paths), so examples
#' can pin down exactly what extraction must get right.
#'
#' @param extracted Spec produced by the agent.
#' @param expected Expected spec from an example.
#' @return data.frame(field, expected, got, match)
#' @export
score_extraction <- function(extracted, expected) {
  flat <- .flatten(expected)
  rows <- lapply(names(flat), function(p) {
    got <- spec_get(extracted, p)
    exp <- flat[[p]]
    ok <- !is.null(got) && identical(sort(as.character(unlist(got))), sort(as.character(unlist(exp))))
    data.frame(field = p, expected = paste(unlist(exp), collapse = ","),
               got = if (is.null(got)) NA_character_ else paste(unlist(got), collapse = ","),
               match = ok)
  })
  do.call(rbind, rows)
}

.flatten <- function(x, prefix = NULL) {
  out <- list()
  for (n in names(x)) {
    key <- if (is.null(prefix)) n else paste(prefix, n, sep = ".")
    if (is.list(x[[n]]) && !is.null(names(x[[n]]))) {
      out <- c(out, .flatten(x[[n]], key))
    } else {
      out[[key]] <- x[[n]]
    }
  }
  out
}
