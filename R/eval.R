# factor synonyms: inst/agent/rules.tsv (table factor_synonym)
.sf_canon_factors <- function(f) {
  if (is.null(f)) return(character())
  vapply(f, function(x) {
    nm <- x$name %||% ""
    syn <- .sf_rules("factor_synonym")
    nm <- if (nm %in% names(syn)) syn[[nm]] else nm
    paste0(nm, ":", x$n_levels %||% "?")
  }, "")
}

#' Score the free local extractor (or any extractor) against the bundled examples
#'
#' Factor names are compared after mapping synonyms (accession, line, hybrid,
#' variety, cultivar, family -> genotype), so wording differences do not count
#' as errors; levels must still match.
#'
#' @param extractor Function taking a question and returning a StudySpec.
#' @param examples Examples list (defaults to load_examples()).
#' @return list(by_example = data.frame, field_recall, examples_with_invented_values,
#'   design_hit_rate, hazard_coverage)
#' @export
evaluate_extraction <- function(extractor = extract_spec_local, examples = load_examples()) {
  rows <- lapply(examples, function(e) {
    spec <- extractor(e$prompt)
    exp <- e$expected_spec
    flat <- .flatten(exp[setdiff(names(exp), "factors")])
    match <- vapply(names(flat), function(p) {
      got <- spec_get(spec, p)
      !is.null(got) && identical(sort(as.character(unlist(got))), sort(as.character(unlist(flat[[p]]))))
    }, logical(1))
    f_exp <- .sf_canon_factors(exp$factors)
    f_got <- .sf_canon_factors(spec$factors)
    f_hit <- sum(f_exp %in% f_got)
    invented <- sum(vapply(unlist(e$must_ask), function(p) {
      !is.null(spec_get(spec, p)) && is.null(spec$assumptions[[p]])
    }, logical(1)))
    cand <- tryCatch(.sf_candidates(spec), error = function(err) character())
    data.frame(id = e$id,
               fields_matched = sum(match) + f_hit,
               fields_expected = length(match) + length(f_exp),
               invented_must_ask = invented,
               design_hit = any(unlist(e$recommended_designs) %in% cand))
  })
  res <- do.call(rbind, rows)
  list(by_example = res,
       field_recall = sum(res$fields_matched) / sum(res$fields_expected),
       examples_with_invented_values = sum(res$invented_must_ask > 0),
       design_hit_rate = mean(res$design_hit))
}
