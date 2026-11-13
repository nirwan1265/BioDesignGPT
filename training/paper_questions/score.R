# Score extractors on the paper-question split, field by field.
#   Rscript training/paper_questions/score.R                          rules on dev
#   Rscript training/paper_questions/score.R dev llm/preds            + reader alone and rules + reader (preds_llm_dev.json)
#   Rscript training/paper_questions/score.R test_heldout llm/preds   held-out species (score test sets only at the end)
# Run from the repo root. Gold specs hold only what each question states, so recall is the main number;
# "invented" counts questions where the extractor filled a field the question leaves open (must_ask).
args <- commandArgs(trailingOnly = TRUE)
split <- if (length(args)) args[1] else "dev"
pred_dirs <- args[-1]
suppressMessages(pkgload::load_all(".", quiet = TRUE))
ex <- lapply(readLines(file.path("training/paper_questions/splits", paste0(split, ".jsonl")), warn = FALSE),
             jsonlite::fromJSON, simplifyVector = FALSE)

field_of <- function(path) sub("\\..*$", "", sub("^design\\.", "design.", path))
score <- function(extractor) {
  rows <- lapply(ex, function(e) {
    spec <- tryCatch(extractor(e$prompt), error = function(err) list())
    g <- e$expected_spec
    flat <- .flatten(g[setdiff(names(g), "factors")])
    hit <- vapply(names(flat), function(p) {
      got <- spec_get(spec, p)
      !is.null(got) && identical(sort(tolower(as.character(unlist(got)))), sort(tolower(as.character(unlist(flat[[p]])))))
    }, logical(1))
    f_exp <- .sf_canon_factors(g$factors)
    f_got <- .sf_canon_factors(spec$factors)
    fn_exp <- sub(":.*", "", f_exp)
    fn_got <- sub(":.*", "", f_got)
    inv <- vapply(unlist(e$must_ask), function(p) !is.null(spec_get(spec, p)) && is.null(spec$assumptions[[p]]), logical(1))
    data.frame(id = e$id, species = e$species, style = e$style,
               field = c(names(flat), rep("factors (name+levels)", length(f_exp)), rep("factors (name)", length(fn_exp))),
               hit = c(hit, f_exp %in% f_got, fn_exp %in% fn_got),
               invented = any(inv), stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
summarise <- function(d, tag) {
  d$group <- ifelse(grepl("^factors", d$field), d$field, sub("\\.(reps|locations|seasons)$", ".\\1", d$field))
  d$group <- sub("^primary_outcome\\..*", "primary_outcome", d$group)
  by <- aggregate(hit ~ group, d, function(x) c(n = length(x), pct = round(100 * mean(x), 1)))
  by <- data.frame(field = by$group, n = by$hit[, "n"], pct = by$hit[, "pct"])
  names(by)[3] <- tag
  inv <- tapply(d$invented, d$id, any)
  list(by = by, overall = round(100 * mean(d$hit[!grepl("^factors \\(name\\)", d$field)]), 1),
       invented = sum(inv), n = length(inv),
       by_style = round(100 * tapply(d$hit, d$style, mean), 1))
}

res <- list(rules = summarise(score(extract_spec_local), "rules"))
for (dir in pred_dirs) {
  f <- file.path(dir, paste0("preds_llm_", split, ".json"))
  if (!file.exists(f)) { message("no ", f); next }
  P <- jsonlite::fromJSON(f, simplifyVector = FALSE)
  tag <- basename(normalizePath(dir))
  res[[paste0(tag, ":alone")]] <- summarise(score(function(q) P[[q]] %||% list()), paste0(tag, ":alone"))
  res[[paste0(tag, ":merged")]] <- summarise(score(function(q) merge_specs(extract_spec_local(q), P[[q]], q)), paste0(tag, ":merged"))
}
tab <- Reduce(function(a, b) merge(a, b[, c("field", names(b)[3])], by = "field", all = TRUE), lapply(res, `[[`, "by"))
cat(sprintf("%s: %d questions\n\n", split, length(ex)))
print(tab[order(-tab$n), ], row.names = FALSE)
cat("\n")
for (k in names(res)) cat(sprintf("%-22s overall field recall %5.1f%%   invented a must-ask value in %d / %d questions\n",
                                  k, res[[k]]$overall, res[[k]]$invented, res[[k]]$n))
cat("\nrecall by question style:\n"); print(do.call(rbind, lapply(res, `[[`, "by_style")))
