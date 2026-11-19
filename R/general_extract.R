# General, table-driven extraction layer.
#
# Runs after the hand-written rules in extract_spec_local() and only fills gaps, so it can't undo tuned
# behaviour. Everything here is driven by the word rows of inst/agent/rules.tsv and a few generic
# patterns, so new organisms, assays or factor words need new table rows, not new code:
#   organism  any organism alias, longest match first
#   assays    any assay alias (in every system)
#   factors   "<N> <factor word>", "<N> conditions/levels/groups/types of <X>", "<X> at/with <N> levels"
#             any number, any word; words not in the table become free-text factors
#   goal      design a new study vs analyse data already collected
#   free text phenotype/outcome as written, tissue -- shown for the user to confirm, never treated as stated facts

# every alias of one category found in the text, in reading order (longest alias wins an overlap)
.sf_find_all <- function(text, cat) {
  t <- .sf_alias_table()
  t <- t[t$category == cat, ]
  if (nrow(t) > 300) {   # big vocabularies: only aliases whose first word is in the text
    first <- sub("^[^a-z0-9]*([a-z0-9]+).*$", "\\1", tolower(t$alias))
    t <- t[first %in% regmatches(text, gregexpr("[a-z0-9]+", text))[[1]], ]
  }
  t <- t[order(-nchar(t$alias)), ]
  hits <- list()
  taken <- rep(FALSE, nchar(text))
  for (i in seq_len(nrow(t))) {
    m <- gregexpr(paste0("(?<![a-z0-9])\\Q", gsub("\\E", "", tolower(t$alias[i]), fixed = TRUE), "\\E(?![a-z0-9])"),
                  text, perl = TRUE)[[1]]
    for (k in seq_along(m)) {
      if (m[k] < 0) next
      rng <- m[k]:(m[k] + attr(m, "match.length")[k] - 1)
      if (any(taken[rng])) next
      taken[rng] <- TRUE
      hits[[length(hits) + 1]] <- c(pos = m[k], term = t$canonical_term[i])
    }
  }
  # regex rows of the category (abbreviations, context patterns) after the literal aliases, on what is left
  rx <- .sf_regex_rows(cat)
  lt <- tolower(text)
  for (i in seq_len(nrow(rx))) {
    m <- gregexpr(rx$pattern[i], lt, perl = TRUE)[[1]]
    for (k in seq_along(m)) {
      if (m[k] < 0) next
      rng <- m[k]:(m[k] + max(attr(m, "match.length")[k], 1) - 1)
      if (any(taken[rng])) next
      taken[rng] <- TRUE
      hits[[length(hits) + 1]] <- c(pos = m[k], term = rx$term[i])
    }
  }
  if (!length(hits)) return(character())
  h <- do.call(rbind, hits)
  unique(h[order(as.integer(h[, "pos"])), "term"])
}

# canonical name of a factor phrase: alias table first, else the phrase itself (free text)
.sf_factor_name <- function(phrase) {
  p <- trimws(tolower(phrase))
  if (!nzchar(p)) return(NA_character_)
  hit <- .sf_find_all(p, "factor")
  if (length(hit)) return(hit[1])
  if (length(.sf_find_all(p, "genotype_noun"))) return("genotype")
  p <- sub("(ies)$", "y", sub("(?<![su])s$", "", p, perl = TRUE))
  p
}

# words that are counted levels of something
# not factor levels: replication, space, sampling, units


.sf_generic_factors <- function(text) {
  stop <- paste0("(?!(?:per|at|in|on|for|this|each|from|and|with|of|to|by|or|than|reps?|replicates?|plants?|plots?|",
                 "were|was|are|is|be|been|got|get|received|receive|had|have|has|given|took|take|people|patients?|mice|animals?)\\b)")
  nouns <- paste(c(.sf_list("genotype_noun_general"), .sf_list("level_noun")), collapse = "|")
  out <- list()
  # P2: "<X> at|with|across <N> levels|doses|concentrations|rates|temperatures"
  re2 <- paste0("([a-z][a-z-]*(?:\\s+[a-z][a-z-]*)?)\\s+(?:at|with|across|in)\\s+", .sf_num_re,
                "\\s+(?:levels?|doses?|concentrations?|rates?|temperatures?|intensities)\\b")
  p2_spans <- regmatches(text, gregexpr(re2, text, perl = TRUE))[[1]]
  for (m in p2_spans) {
    g <- regmatches(m, regexec(re2, m, perl = TRUE))[[1]]
    n <- .sf_num(g[3]); x <- sub("^(the|a|an|of|and|with|different)\\s+", "", g[2])
    if (is.na(n) || n < 2) next
    nm <- .sf_factor_name(x)
    if (is.na(nm) || grepl(.sf_cue("not_a_level"), nm)) next
    out[[length(out) + 1]] <- list(name = nm, n = n, phrase = m)
  }
  # P1: "<N> [m1 m2] <noun> [of|for <X>]"
  re1 <- paste0("(?<![\\w.])", .sf_num_re, "\\s+((?:", stop, "[a-z][a-z-]*\\s+){0,2}?)(", nouns, ")\\b",
                "(?:\\s+(?:of|for)\\s+(?:the\\s+|different\\s+)?([a-z][a-z-]*(?:\\s+[a-z][a-z-]*)?))?")
  for (m in regmatches(text, gregexpr(re1, text, perl = TRUE))[[1]]) {
    if (any(vapply(p2_spans, function(sp) grepl(m, sp, fixed = TRUE), logical(1)))) next
    g <- regmatches(m, regexec(re1, m, perl = TRUE))[[1]]
    n <- .sf_num(g[2]); mods <- trimws(g[3]); noun <- g[4]; of_x <- if (length(g) >= 5) g[5] else ""
    if (is.na(n) || n < 2 || n > 5000) next
    if (grepl(paste0("^(", paste(.sf_list("genotype_noun_general"), collapse = "|"), ")$"), noun)) {
      out[[length(out) + 1]] <- list(name = "genotype", n = n, phrase = m); next
    }
    phrase <- if (nzchar(of_x) && grepl(.sf_cue("generic_level_noun"), noun)) of_x else
      trimws(paste(mods, noun))
    if (grepl(.sf_cue("not_a_level"), phrase)) next
    nm <- .sf_factor_name(phrase)
    if (is.na(nm) || grepl(.sf_cue("not_a_level"), nm)) next
    out[[length(out) + 1]] <- list(name = nm, n = n, phrase = m)
  }
  out
}

.sf_goal <- function(text) if (grepl(.sf_cue("analysis_intent"), text, perl = TRUE)) "analysis" else "design"

# phenotype / outcome exactly as written (shown for confirmation; never counted as a stated canonical outcome)
.sf_outcome_text <- function(text) {
  re <- .sf_cue("outcome_phrase")
  m <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
  if (length(m) < 2) return(NULL)
  v <- trimws(m[2])
  if (!nzchar(v) || grepl(.sf_cue("not_an_outcome"), v)) NULL else v
}

.sf_tissue_text <- function(text) {
  p <- tryCatch(.sf_practice_tables()$practice, error = function(e) NULL)
  vocab <- .sf_list("tissue_word")
  if (!is.null(p)) vocab <- unique(c(vocab, p$tissue[p$tissue != "all" & nchar(p$tissue) <= 20 & !grepl("[^a-z ]", p$tissue)]))
  words <- strsplit(gsub("[^a-z ]", " ", text), "\\s+")[[1]]
  words <- words[nzchar(words)]
  grams <- c(if (length(words) > 1) paste(utils::head(words, -1), utils::tail(words, -1)), words)
  norm <- vapply(grams, .sf_norm_tissue, "")
  hit <- norm[norm %in% vocab]
  if (length(hit)) unname(hit[1]) else NULL
}

# factor words specific enough to count as a stated factor even without a number
.sf_general_layer <- function(spec, text) {
  set <- function(path, value) if (!is.null(value) && !all(is.na(value))) spec <<- spec_set(spec, path, value)
  if (is.null(spec$organism)) {
    o <- .sf_find_all(text, "organism")
    if (length(o)) set("organism", o[1])
  }
  if (is.null(spec$assays)) {
    a <- .sf_find_all(text, "assay")
    if (!identical(spec$study_type, "functional_validation")) a <- setdiff(a, "heterologous")   # "benthamiana" is an organism
    if (length(a)) set("assays", a)
  }
  # the assay family is not a setting: with no setting stated, system stays open and is asked
  # factors: fill counts the hand rules missed or defaulted, add factors they never saw
  gen <- .sf_generic_factors(text)
  if (length(gen)) {
    fx <- spec$factors %||% list()
    canon_of <- function(nm) { c <- .sf_factor_name(nm); if (is.na(c)) nm else c }
    have <- vapply(fx, function(f) canon_of(f$name), "")
    for (g in gen) {
      i <- match(g$name, have)
      if (!is.na(i)) {
        cur <- fx[[i]]$n_levels
        if (is.null(cur) || (identical(as.numeric(cur), 2) && g$n != 2)) fx[[i]]$n_levels <- g$n
      } else {
        fx[[length(fx) + 1]] <- list(name = g$name, n_levels = g$n)
        have <- c(have, g$name)
      }
    }
    spec$factors <- fx
  }
  # factors whose levels are listed or counted ("at 0, 6 and 24 h", "at four times", "over time"): factor_levels rows
  lv <- .sf_level_factors(text)
  if (length(lv)) {
    fx <- spec$factors %||% list()
    have <- vapply(fx, function(f) f$name, "")
    # an arm list already read as another factor (infection vs mock, diet vs chow, dose vs vehicle) is not a treatment
    owned <- c("infection", "diet", "dose", "antibiotic", "injury", "disease", "phenotype_group")
    if ("treatment" %in% names(lv) && any(have %in% owned)) lv$treatment <- NULL
    # disease and phenotype_group are one group factor: the group_by_* cues pick the name, as for the reader
    for (g in intersect(names(lv), c("disease", "phenotype_group"))) {
      nm2 <- .sf_group_factor(g, text); if (!identical(nm2, g)) { lv[[nm2]] <- lv[[g]]; lv[[g]] <- NULL }
    }
    if (all(c("disease", "phenotype_group") %in% names(lv))) lv$phenotype_group <- NULL
    for (nm in names(lv)) {
      i <- match(nm, have); n <- lv[[nm]]
      if (is.na(i)) { fx[[length(fx) + 1]] <- if (is.na(n)) list(name = nm) else list(name = nm, n_levels = n); have <- c(have, nm) }
      else if (is.null(fx[[i]]$n_levels) && !is.na(n)) fx[[i]]$n_levels <- n
      # a counted list of more arms beats a two-level default ("normal, high-sugar or high-fat diet")
      else if (!is.na(n) && identical(as.numeric(fx[[i]]$n_levels), 2) && n > 2) fx[[i]]$n_levels <- n
    }
    spec$factors <- fx
  }
  # specific factor words stated without a count ("cold", "drought", "placebo"): factor with unknown levels
  fx <- spec$factors %||% list()
  have <- vapply(fx, function(f) { c <- .sf_factor_name(f$name); if (is.na(c)) f$name else c }, "")
  spec_words <- intersect(.sf_find_all(text, "factor"), .sf_list("specific_factor"))
  # one sex only ("male mice") is a constant, not a factor
  if (!grepl(.sf_cue("both_sexes"), text, perl = TRUE))
    spec_words <- setdiff(spec_words, "sex")
  # a mock or uninfected control next to a pathogen defines an infection factor, not a generic treatment
  if (grepl(.sf_cue("mock_control"), text, perl = TRUE) &&
      grepl(.sf_cue("infection_word"), text, perl = TRUE)) {
    spec_words <- union(spec_words, "infection")
  } else if (grepl(.sf_cue("placebo_control"), text, perl = TRUE)) {
    spec_words <- union(spec_words, "treatment")
  }
  for (w in setdiff(spec_words, have)) fx[[length(fx) + 1]] <- list(name = w)
  if (length(fx)) spec$factors <- fx
  if (is.null(spec$goal)) set("goal", .sf_goal(text))
  if (is.null(spec$primary_outcome$name)) set("outcome_text", .sf_outcome_text(text))
  if (is.null(spec$tissue)) set("tissue", .sf_tissue_text(text))
  if (is.null(spec$sequencing)) {
    sq <- .sf_sequencing(text)
    if (!is.null(sq)) spec$sequencing <- sq
  }
  spec
}

#' Correct what StudyForge understood and re-plan
#'
#' Every plan starts with the fields StudyForge extracted. Fix any of them here (dotted paths) and the plan is
#' rebuilt from the corrected spec; corrected values are treated as stated by the user.
#'
#' @param answer A `studyforge_answer` from studyforge_ask().
#' @param ... Fields to set, e.g. `organism = "Homo sapiens"`, `design.reps = 4`, `tissue = "root"`,
#'   `factors = "diet:5, sex:2"` (name:levels pairs) or a list of factor lists.
#' @return A new `studyforge_answer`.
#' @export
#' @examples
#' a <- studyforge_ask("i have some human rnaseq data in 5 condition of diets")
#' a2 <- studyforge_fix(a, design.reps = 4, tissue = "liver")
studyforge_fix <- function(answer, ...) {
  fix <- utils::modifyList(answer$fixes %||% list(), list(...))
  studyforge_ask(answer$question, provider = answer$provider, engine = answer$engine, fix = fix)
}

.sf_apply_fix <- function(spec, fix) {
  if (!length(fix)) return(spec)
  for (p in names(fix)) {
    v <- fix[[p]]
    if (p == "factors" && is.character(v)) {
      parts <- trimws(strsplit(paste(v, collapse = ","), ",")[[1]])
      v <- lapply(parts[nzchar(parts)], function(x) {
        kv <- trimws(strsplit(x, ":", fixed = TRUE)[[1]])
        f <- list(name = kv[1])
        if (length(kv) > 1 && !is.na(suppressWarnings(as.numeric(kv[2])))) f$n_levels <- as.numeric(kv[2])
        f
      })
    }
    if (p == "outcome") p <- "primary_outcome.name"
    spec <- spec_set(spec, p, v)
  }
  if (!is.null(spec$primary_outcome$name) && is.null(spec$primary_outcome$type)) {
    spec <- spec_set(spec, "primary_outcome.type", "continuous", assumption = TRUE)
  }
  spec
}

# the "here's what I understood" block at the top of every plan
.sf_skeleton_lines <- function(s, fixes = list()) {
  q <- function(x) if (is.null(x) || !length(x)) "?" else paste(unlist(x), collapse = ", ")
  fx <- if (length(s$factors)) paste(vapply(s$factors, function(f)
    paste0(f$name, if (!is.null(f$n_levels)) paste0(" (", f$n_levels, ")") else " (? levels)"), ""), collapse = "; ") else "?"
  outcome <- if (!is.null(s$primary_outcome$name)) s$primary_outcome$name else
    if (!is.null(s$outcome_text)) paste0("\"", s$outcome_text, "\" (as written; confirm)") else "?"
  hint <- function(what) { h <- tryCatch(.sf_practice_hint(s, what), error = function(e) NULL); if (is.null(h)) "?" else paste0("? (", h, ")") }
  tissue <- if (!is.null(s$tissue)) s$tissue else hint("tissue")
  omics <- length(s$assays) || isTRUE(s$system %in% .sf_systems_where(sequencing = TRUE))
  sq <- s$sequencing
  seqtxt <- if (!is.null(sq)) paste(c(sq$instrument, if (!is.null(sq$read_length)) paste0(sq$layout %||% "", if (!is.null(sq$layout)) " ", sq$read_length, " bp"),
                                      if (!is.null(sq$depth_m)) paste0(sq$depth_m, " M reads")), collapse = ", ") else hint("sequencing")
  rows <- c(
    Goal = if (identical(s$goal, "analysis")) "analyse data already collected" else "design a new study",
    Organism = q(s$organism), Setting = q(s$system), `Study type` = q(s$study_type), `Assay / data` = q(s$assays),
    `Method / resource` = q(s$method), Tissue = tissue,
    `Factors (levels)` = fx, `Outcome / phenotype` = outcome, `Experimental unit` = q(s$experimental_unit),
    `Replicates` = q(s$design$reps), `Locations / seasons` = paste(q(s$design$locations), "/", q(s$design$seasons)))
  if (omics) rows <- append(rows, c(Sequencing = seqtxt), after = 6)
  c(sprintf("  %-20s %s%s", paste0(names(rows), ":"), rows,
            ifelse(names(rows) %in% c("Organism", "Replicates", "Tissue") & names(rows) %in% names(fixes), "  (corrected)", "")))
}

# Factors whose levels are listed or counted in the text (rules.tsv category factor_levels, term "<factor>/<how>";
# {N} is the count_word cue). how says how to read a hit: list = one level per number in group 1 ("at 0, 6, 12 and 24 h"); count =
# group 1 is the number of levels ("at four times"); pair = two levels ("at baseline and 52 weeks"); wordlist = one
# level per listed item in group 1 that is a word of the table named in the note column's first word; open = the
# factor is there, its levels unknown ("sampled over time").
.sf_level_factors <- function(text) {
  r <- .sf_rules_rows("factor_levels")
  out <- list()
  how <- sub("^[^/]*/", "", r$term); r$term <- sub("/.*$", "", r$term); r$match <- how
  for (i in seq_len(nrow(r))) {
    nm <- r$term[i]; if (nm %in% names(out) && !is.na(out[[nm]])) next
    re <- gsub("{N}", .sf_cue("count_word"), r$pattern[i], fixed = TRUE)
    if (identical(r$match[i], "contrast")) {   # a vs/or run with a control arm: one level per arm
      vocab <- .sf_list(strsplit(r$note[i], "[: ]")[[1]][1])
      ctrl <- function(x) { w <- strsplit(x, "\\s+")[[1]]; g <- c(w, if (length(w) > 1) paste(utils::head(w, -1), utils::tail(w, -1)))
        any(g %in% vocab) || grepl("^(?:no|without)\\s", x, perl = TRUE) }
      # runs are searched one at a time; a run without vs/or ("per block, trays inoculated with") only moves the search
      # on by one word, so the contrast that starts inside it ("inoculated with p. sojae vs mock") is still found
      pos <- 1L
      repeat {
        m <- regexpr(re, substring(text, pos), perl = TRUE)
        if (m < 0) break
        run <- regmatches(substring(text, pos), m)
        if (!grepl("\\bvs\\.?\\s|\\bversus\\s|\\sor\\s", run, perl = TRUE)) {   # an "and" list is not a contrast
          sp <- regexpr("[\\s,]+", run, perl = TRUE)
          pos <- pos + m - 1L + (if (sp > 0) sp + attr(sp, "match.length") - 1L else nchar(run))
          next
        }
        pos <- pos + m - 1L + nchar(run)
        # a comma next to a bare "A vs B" (no "or" in the run) closes a clause, it does not add an arm:
        # "in a growth room, X vs mock, 3 plants pooled" keeps only "X vs mock"
        # (a list that runs into ", vs" is a list of arms: "air-dried, then rehydrated, vs untreated")
        if (!grepl("\\sor\\s|,\\s*(?:vs\\.?|versus)\\s", run, perl = TRUE)) {
          segs <- strsplit(run, "\\s*,\\s*", perl = TRUE)[[1]]
          # an extra control arm after the comma ("A vs B, plus normoxic controls"; rules.tsv cue extra_control_arm) stays
          xa <- tryCatch(.sf_cue("extra_control_arm"), error = function(e) "(?!)")
          keep <- grepl("\\bvs\\.?\\s|\\bversus\\s", segs, perl = TRUE) | grepl(xa, segs, perl = TRUE)
          run <- paste(segs[keep], collapse = " vs ")
        }
        items <- trimws(strsplit(run, "\\s*,\\s*(?:and\\s+|or\\s+|vs\\.?\\s+|versus\\s+)?|\\s+or\\s+|\\s+vs\\.?\\s+|\\s+versus\\s+", perl = TRUE)[[1]])
        items <- items[nzchar(items)]
        # a setting phrase caught by the list commas ("in a growth room, salt vs control") is not an arm
        lead <- tryCatch(.sf_list("not_arm_lead"), error = function(e) character())
        items <- items[!vapply(items, function(x) any(vapply(lead, grepl, logical(1), x = x, perl = TRUE)), logical(1))]
        if (length(items) >= 2 && any(vapply(items, ctrl, logical(1)))) { out[[nm]] <- length(items); break }
      }
      next
    }
    if (identical(r$match[i], "wordlist")) {   # every listed run in the text; the first with two or more table words
      vocab <- .sf_list(strsplit(r$note[i], "[: ]")[[1]][1])
      bad <- tryCatch(.sf_list("not_tissue_phrase"), error = function(e) character())
      named <- function(x) {
        if (any(vapply(bad, function(b) grepl(b, x, fixed = TRUE), logical(1)))) return(FALSE)
        w <- strsplit(x, "\\s+")[[1]]; grams <- c(w, if (length(w) > 1) paste(utils::head(w, -1), utils::tail(w, -1)))
        any(vapply(grams, .sf_norm_tissue, "") %in% vocab | grams %in% vocab)
      }
      runs <- regmatches(text, gregexpr(re, text, perl = TRUE))[[1]]
      for (run in runs) {
        items <- trimws(strsplit(run, "\\s*,\\s*(?:and\\s+|or\\s+)?|\\s+and\\s+|\\s+or\\s+|\\s+vs\\.?\\s+|\\s+versus\\s+|\\s*/\\s*", perl = TRUE)[[1]])
        k <- sum(vapply(items, named, logical(1)))
        if (k >= 2) { out[[nm]] <- k; break }
      }
      next
    }
    g <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
    if (!length(g)) next
    n <- switch(r$match[i],
      list = length(regmatches(g[2], gregexpr("\\d+(?:\\.\\d+)?(?:-\\d+(?:\\.\\d+)?)?", g[2], perl = TRUE))[[1]]),
      count = .sf_num(g[2]),
      sum = sum(vapply(g[-1][nzchar(g[-1])], .sf_num, numeric(1))),   # "four cultivars and two hybrids" = 6
      pair = 2,
      if (grepl("^\\d+$", r$match[i])) as.numeric(r$match[i]) else NA)   # a fixed count: "a hybrid and its two parents" = 3
    if (!is.na(n) && n < 2) next
    out[[nm]] <- n
  }
  out
}
