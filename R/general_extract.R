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
  re1 <- paste0("(?<![\\w.:/])", .sf_num_re, "\\s+((?:", stop, "[a-z][a-z-]*\\s+){0,2}?)(", nouns, ")\\b",
                "(?:\\s+(?:of|for)\\s+(?:the\\s+|different\\s+)?([a-z][a-z-]*(?:\\s+[a-z][a-z-]*)?))?")
  for (m in regmatches(text, gregexpr(re1, text, perl = TRUE))[[1]]) {
    if (any(vapply(p2_spans, function(sp) grepl(m, sp, fixed = TRUE), logical(1)))) next
    g <- regmatches(m, regexec(re1, m, perl = TRUE))[[1]]
    n <- .sf_num(g[2]); mods <- trimws(g[3]); noun <- g[4]; of_x <- if (length(g) >= 5) g[5] else ""
    if (is.na(n) || n < 2 || n > 5000) next
    # a measuring unit right after the number makes it a measure, not a count ("24 h after inoculation")
    if (grepl(paste0("^(?:", .sf_cue("count_unit_word"), ")\\b"), mods, perl = TRUE)) next
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

# A panel or population assay (rules.tsv panel_assay: GWAS, eQTL, QTL mapping, genomic prediction) always varies
# genotype: add the factor when no rule did, with its level count left open to be asked
.sf_panel_genotype <- function(spec) {
  if (!length(intersect(unlist(spec$assays), .sf_list("panel_assay")))) return(spec)
  have <- vapply(spec$factors %||% list(), function(f) f$name %||% "", "")
  if (!any(have %in% c("genotype", "population", "phenotype_group"))) spec$factors <- c(spec$factors %||% list(), list(list(name = "genotype")))
  spec
}

# What the genetic unit is (rules.tsv genetic_unit: bulk, population; a panel assay without either is line) and the
# numbers that go with it (genetic_field: individuals_per_bulk, bulk_fraction, generations), in spec$genetics
.sf_genetics <- function(spec, text) {
  gu <- .sf_rules_rows("genetic_unit")
  unit <- NULL
  for (i in seq_len(NROW(gu))) if (grepl(gu$pattern[i], text, perl = TRUE)) { unit <- gu$term[i]; break }
  if (is.null(unit) && length(intersect(unlist(spec$assays), .sf_list("panel_assay")))) unit <- "line"
  if (is.null(unit)) return(spec)
  spec$genetics$unit <- unit
  gf <- .sf_rules_rows("genetic_field")
  for (i in seq_len(NROW(gf))) {
    if (!is.null(spec$genetics[[gf$term[i]]])) next
    re <- gsub("{N}", .sf_cue("count_word"), gf$pattern[i], fixed = TRUE)
    g <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
    if (length(g)) { v <- g[-1][nzchar(g[-1])][1]; n <- suppressWarnings(as.numeric(v)); if (is.na(n)) n <- .sf_num(v)
      if (!is.na(n)) spec$genetics[[gf$term[i]]] <- n }
  }
  spec
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
  summed <- attr(lv, "summed")
  if (length(lv)) {
    fx <- spec$factors %||% list()
    have <- vapply(fx, function(f) f$name, "")
    # an arm list already read as another factor (infection vs mock, diet vs chow, dose vs vehicle) is not a treatment
    owned <- .sf_list("arm_factor")
    if ("treatment" %in% names(lv) && any(have %in% owned)) lv$treatment <- NULL
    # a treatment read from arms that name another factor already in the spec ("drought vs control" is water) is
    # that factor, not a second one: the count goes to it
    # (only a two-arm contrast, one arm a control, the other naming exactly one factor already in the spec; a list of
    # several stresses "control, drought, heat or both" stays a treatment)
    ar <- attr(lv, "arms")$treatment
    if ("treatment" %in% names(lv) && length(ar) == 2) {
      cv <- .sf_list("treatment_control")
      isc <- vapply(ar, function(x) any(strsplit(x, "\\s+")[[1]] %in% cv) || grepl("^(?:no|without)\\s", x, perl = TRUE), logical(1))
      if (sum(isc) == 1) {
        # the arm's own words: what follows its setting preposition ("maize lines under drought" -> "drought"; cue arm_head)
        head <- sub(tryCatch(.sf_cue("arm_head"), error = function(e) "(?!)"), "", ar[!isc], perl = TRUE)
        fw <- setdiff(.sf_find_all(head, "factor"), "treatment")
        if (length(fw) == 1 && fw %in% have) {
          k <- match(fw, have)
          if (is.null(fx[[k]]$n_levels) && !is.na(lv$treatment)) fx[[k]]$n_levels <- lv$treatment
          lv$treatment <- NULL
        }
      }
    }
    # a generic numeric factor (rules.tsv generic_level_factor: dose) whose list names another factor already in
    # the spec ("0, 100 or 150 mM NaCl" is salt) gives that factor its levels and values instead
    for (gn in intersect(.sf_list("generic_level_factor"), names(lv))) {
      fw <- setdiff(.sf_find_all(attr(lv, "spans")[[gn]] %||% "", "factor"), c(gn, "treatment"))
      # no factor word in the list: its unit may name the factor (rules.tsv unit_factor: kg N/ha is nitrogen)
      un <- attr(lv, "values")[[gn]]$unit
      if (!length(fw) && !is.null(un)) { uf <- .sf_rules_rows("unit_factor")
        k <- which(vapply(uf$pattern, grepl, logical(1), x = un, perl = TRUE)); if (length(k)) fw <- uf$term[k[1]] }
      if (length(fw) == 1 && !(fw %in% names(lv))) {
        a_v <- attr(lv, "values"); a_s <- attr(lv, "spans"); a_m <- attr(lv, "summed")
        k <- match(fw, have)
        if (!is.na(k)) {
          if (is.null(fx[[k]]$n_levels) && !is.na(lv[[gn]])) fx[[k]]$n_levels <- lv[[gn]]
          if (identical(as.numeric(fx[[k]]$n_levels), as.numeric(lv[[gn]]))) a_v[[fw]] <- a_v[[gn]]
        } else lv[[fw]] <- lv[[gn]]   # not in the spec yet: the count is read under the factor the list names
        a_v[[fw]] <- a_v[[fw]] %||% a_v[[gn]]; a_v[[gn]] <- NULL
        lv[[gn]] <- NULL
        attr(lv, "values") <- a_v; attr(lv, "spans") <- a_s; attr(lv, "summed") <- a_m
      }
    }
    vals <- attr(lv, "values")
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
      # a summed list of groups beats the first count alone ("four cultivars and two hybrids": 6, not 4)
      else if (!is.na(n) && nm %in% summed && n > as.numeric(fx[[i]]$n_levels)) fx[[i]]$n_levels <- n
      # numeric levels read with their unit: values, unit and level labels ("24 h", "48 h", "72 h")
      j <- match(nm, have); vv <- vals[[nm]]
      if (!is.na(j) && !is.null(vv) && identical(as.numeric(fx[[j]]$n_levels), as.numeric(length(vv$values))) && is.null(fx[[j]]$levels)) {
        fx[[j]]$values <- vv$values
        if (!is.null(vv$unit)) fx[[j]]$unit <- vv$unit
        fx[[j]]$scale <- .sf_level_scale(vv$values)   # linear, or log for equal ratios (1, 10, 100)
        if (identical(fx[[j]]$scale, "log")) {   # log10(x + offset) when 0 is a level; base written so all heads agree
          fx[[j]]$log_base <- 10
          fx[[j]]$log_offset <- .sf_log_offset(vv$values)
        }
        fx[[j]]$levels <- trimws(paste(format(vv$values, trim = TRUE, drop0trailing = TRUE), vv$unit %||% ""))
      }
      # a pair that names its two levels ("wild type and mutant")
      nn <- attr(lv, "named")[[nm]]
      if (!is.na(j) && length(nn) == 2 && identical(as.numeric(fx[[j]]$n_levels), 2) && is.null(fx[[j]]$levels)) fx[[j]]$levels <- nn
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
# {N} is the count_word cue). coord = a coordinated list of groups, each conjunct adds its own number or 1 ({HEAD} is
# the noun list named by the note). how says how to read a hit: list = one level per number in group 1 ("at 0, 6, 12 and 24 h"); count =
# group 1 is the number of levels ("at four times"); pair = two levels ("at baseline and 52 weeks"); wordlist = one
# level per listed item in group 1 that is a word of the table named in the note column's first word; open = the
# factor is there, its levels unknown ("sampled over time").
.sf_level_factors <- function(text) {
  spans <- list(); vals <- list(); arms <- list(); pair_names <- list()   # text each count was read from; numeric levels; contrast arms; named pair levels
  r <- .sf_rules_rows("factor_levels")
  out <- list()
  how <- sub("^[^/]*/", "", r$term); r$term <- sub("/.*$", "", r$term); r$match <- how
  for (i in seq_len(nrow(r))) {
    nm <- r$term[i]; if (nm %in% names(out) && !is.na(out[[nm]])) next
    re <- .sf_expand_vocab(gsub("{N}", .sf_cue("count_word"), r$pattern[i], fixed = TRUE))
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
        # a list does not run back across a verb that applies something ("..., sprayed with conidia or water"; rules.tsv
        # list_breaking_verb followed by a preposition): the arms start after it
        brk <- .sf_expand_vocab("\\b(?:{vocab:list_breaking_verb})\\s+(?:with|to|in|on|onto|into|under|at|by|for|from)\\s+")
        core <- regexpr("(?:^|\\s)(?:or|vs\\.?|versus)\\s", run, perl = TRUE)
        # not when the verb phrase is itself an arm, parallel to a participle arm ("inoculated with a fungus or left
        # untreated"), and not "with vs without"
        bm <- regexpr(brk, substr(run, 1, core), perl = TRUE)
        if (bm > 0) {
          rest <- substring(run, bm + attr(bm, "match.length"))
          other <- sub("^.*?(?:^|\\s)(?:or|vs\\.?|versus)\\s+", "", rest, perl = TRUE)
          if (!grepl("^(?:or|vs\\.?|versus)\\s", rest, perl = TRUE) && !grepl("^(?:left|kept|not)\\b|^[a-z-]+ed\\b", other, perl = TRUE)) run <- rest
        }
        # comma segments after the last vs/or segment start a new clause (", pigs allocated in blocks"), unless they
        # add a control arm (cue extra_control_arm)
        segs0 <- strsplit(run, "\\s*,\\s*", perl = TRUE)[[1]]
        kc <- suppressWarnings(max(which(grepl("(?:^|\\s)(?:or|vs\\.?|versus)\\s", segs0, perl = TRUE))))
        if (is.finite(kc) && kc < length(segs0)) {
          xa0 <- tryCatch(.sf_cue("extra_control_arm"), error = function(e) "(?!)")
          tl <- segs0[-seq_len(kc)]
          run <- paste(c(segs0[seq_len(kc)], tl[grepl(xa0, tl, perl = TRUE) | grepl("^plus\\s", tl, perl = TRUE)]), collapse = ", ")
        }
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
        # " / " with spaces separates arms ("vehicle or Wnt / TGF-beta inhibitors"); "Wnt/beta-catenin" is one name
        items <- trimws(strsplit(run, "\\s*,\\s*(?:and\\s+|or\\s+|vs\\.?\\s+|versus\\s+)?|\\s+or\\s+|\\s+vs\\.?\\s+|\\s+versus\\s+|\\s+/\\s+", perl = TRUE)[[1]])
        items <- items[nzchar(items)]
        # a setting phrase caught by the list commas ("in a growth room, salt vs control") is not an arm
        lead <- tryCatch(.sf_list("not_arm_lead"), error = function(e) character())
        items <- items[!vapply(items, function(x) any(vapply(lead, grepl, logical(1), x = x, perl = TRUE)), logical(1))]
        # an extra control arm after the run in the same clause (", plus sham-operated rats"; cue extra_control_arm)
        if (grepl("\\sor\\s", run, perl = TRUE)) {
          tail_cl <- sub("[.;?].*$", "", substring(text, pos))
          xa <- tryCatch(.sf_cue("extra_control_arm"), error = function(e) "(?!)")
          nx <- regmatches(tail_cl, regexpr("^[^,]*,\\s*\\K(?:plus|and)\\s+[^,]+", tail_cl, perl = TRUE))
          if (length(nx) && grepl(xa, trimws(nx), perl = TRUE)) items <- c(items, trimws(nx))
        }
        # an arm that names several groups at once ("a series of strains", "different isolates"): levels open
        oq <- tryCatch(.sf_cue("open_quantifier"), error = function(e) "(?!)")
        if (length(items) >= 2 && any(vapply(items, ctrl, logical(1)))) {
          # a trailing when-phrase belongs to time, not to the arm ("salt vs control at several times")
          heads <- sub("\\s+(?:at|over|during|across|throughout|sampled)\\b.*$", "", items, perl = TRUE)
          out[[nm]] <- if (any(grepl(oq, heads, perl = TRUE))) NA else length(items); spans[[nm]] <- run; arms[[nm]] <- items; break }
      }
      next
    }
    if (identical(r$match[i], "coord")) {   # a coordinated list of groups: each conjunct adds its own number, or 1
      # {HEAD} is the noun list named by the note's first word; the first run with two or more conjuncts counts
      head <- paste(.sf_list(strsplit(r$note[i], "[: ]")[[1]][1]), collapse = "|")
      re <- gsub("{HEAD}", paste0("(?:", head, ")"), re, fixed = TRUE)
      num <- paste0("(?<![\\w.-])", .sf_cue("count_word"), "(?![\\w-])")
      hits <- gregexpr(re, text, perl = TRUE)[[1]]
      runs <- regmatches(text, list(hits))[[1]]
      for (h in seq_along(runs)) {
        run <- runs[h]
        # a list right after "blocks of" or "plots (" is one block's contents, not the total (cue coord_not_total)
        if (grepl(.sf_cue("coord_not_total"), substr(text, max(1, hits[h] - 40), hits[h] - 1), perl = TRUE)) next
        items <- trimws(strsplit(run, "\\s*,\\s*(?:and\\s+|or\\s+|plus\\s+)?|\\s+(?:and|or|plus)\\s+", perl = TRUE)[[1]])
        items <- items[nzchar(items)]
        if (length(items) < 2) next
        # a conjunct without the noun shares the last one's ("9 wild and 9 cultivated accessions"): only when that has a number
        noun <- grepl(paste0("\\b(?:", head, ")\\b"), items, perl = TRUE)
        if (!all(noun) && !grepl(num, items[length(items)], perl = TRUE)) next
        # a conjunct without a number is one level, unless its noun is plural ("lines and their hybrids": not counted)
        k <- sum(vapply(items, function(x) { m <- regmatches(x, regexpr(num, x, perl = TRUE))
          if (length(m)) .sf_num(m) else if (grepl("[^s]s$|ies$", x, perl = TRUE)) NA_real_ else 1 }, numeric(1)))
        if (!is.na(k) && k >= 2) { out[[nm]] <- k; attr(out, "summed") <- c(attr(out, "summed"), nm)
          # two unnumbered conjuncts name the two levels ("wild type and mutant")
          if (k == 2 && length(items) == 2 && !any(grepl(num, items, perl = TRUE)))
            pair_names[[nm]] <- trimws(sub("^(?:the|a|an|its|their)\\s+", "", items, perl = TRUE))
          break }
      }
      next
    }
    if (identical(r$match[i], "grouplist")) {   # "split into sham, I-R, and IPC plus I-R groups" = 3
      g <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
      if (!length(g)) next
      items <- trimws(strsplit(g[2], "\\s*,\\s*(?:and\\s+|or\\s+)?|\\s+or\\s+|\\s+and\\s+(?=(?:an?\\s+)?[a-z0-9-]+\\s*(?:,|$))|\\s+vs\\.?\\s+|\\s+versus\\s+", perl = TRUE)[[1]])
      items <- items[nzchar(items)]
      # an item naming several groups at once ("several doses", "different strains") leaves the count open
      openw <- tryCatch(.sf_cue("open_group_item"), error = function(e) "(?!)")
      if (length(items) >= 2 && !any(grepl(openw, items, perl = TRUE))) { out[[nm]] <- length(items); spans[[nm]] <- g[1] }
      next
    }
    if (identical(r$match[i], "wordlist")) {   # every listed run in the text; the first with two or more table words
      vocab <- .sf_list(strsplit(r$note[i], "[: ]")[[1]][1])
      bad <- tryCatch(.sf_list("not_tissue_phrase"), error = function(e) character())
      period <- tryCatch(.sf_cue("exposure_period"), error = function(e) "(?!)")
      named <- function(x) {
        if (any(vapply(bad, function(b) grepl(b, x, fixed = TRUE), logical(1)))) return(FALSE)
        w <- strsplit(x, "\\s+")[[1]]; n <- length(w)
        grams <- c(w, if (n > 1) paste(w[-n], w[-1]), if (n > 2) paste(w[1:(n - 2)], w[2:(n - 1)], w[3:n]))
        any(vapply(grams, .sf_norm_tissue, "") %in% vocab | grams %in% vocab)
      }
      # a bare modifier shares the head of a later item when the joined phrase is in the table: "caruncular and
      # intercaruncular endometrium", "right and left ventricle", "CD4 and CD8 T cells"; "male and female liver" is not
      # (the item's last word is the modifier; the joined phrase must itself be a table entry, not merely contain one)
      in_vocab <- function(p) p %in% vocab || .sf_norm_tissue(p) %in% vocab
      shares_head <- function(x, later) {
        x <- utils::tail(strsplit(x, "\\s+")[[1]], 1)
        for (y in later) {
          w <- strsplit(y, "\\s+")[[1]]
          for (s in seq_along(w)[-1]) for (e in s:length(w)) if (in_vocab(paste(x, paste(w[s:e], collapse = " ")))) return(TRUE)
          if (named(y)) break
        }
        FALSE
      }
      # a phrase that says when a treatment ran ("fed low protein during gestation and lactation") is the exposure
      # window, not groups: it is taken out before the lists are read (cue exposure_period)
      wtext <- gsub(period, " , ", text, perl = TRUE)
      # "late gestation and again in early lactation": filler between list items (cue list_filler) is dropped
      wtext <- gsub(tryCatch(.sf_cue("list_filler"), error = function(e) "(?!)"), "", wtext, perl = TRUE)
      runs <- regmatches(wtext, gregexpr(re, wtext, perl = TRUE))[[1]]
      for (run in runs) {
        items <- trimws(strsplit(run, "\\s*,\\s*(?:and\\s+|or\\s+)?|\\s+and\\s+|\\s+or\\s+|\\s+vs\\.?\\s+|\\s+versus\\s+|\\s*/\\s*", perl = TRUE)[[1]])
        ok <- vapply(items, named, logical(1))
        for (j in which(!ok)) if (j < length(items)) ok[j] <- shares_head(items[j], items[(j + 1):length(items)])
        k <- sum(ok)
        if (k >= 2) { out[[nm]] <- k; spans[[nm]] <- run; break }
      }
      next
    }
    g <- regmatches(text, regexec(re, text, perl = TRUE))[[1]]
    if (!length(g)) next
    # a named event after a list is one more level ("at 6, 24 and 72 h and after recovery"; cue list_extra_event)
    extra <- 0
    if (identical(r$match[i], "list")) {
      mm <- regexpr(re, text, perl = TRUE)
      after <- substring(text, mm + attr(mm, "match.length"))
      ev <- tryCatch(.sf_expand_vocab(.sf_cue("list_extra_event")), error = function(e) "(?!)")
      if (grepl(ev, after, perl = TRUE)) extra <- 1
    }
    n <- extra + switch(r$match[i],
      list = length(regmatches(g[2], gregexpr("\\d+(?:\\.\\d+)?(?:-\\d+(?:\\.\\d+)?)?", g[2], perl = TRUE))[[1]]),
      count = .sf_num(g[2]),
      # "four cultivars and two hybrids" = 6; a group that is not a number counts its named conjuncts
      # ("30 strains and their BN and SHR parents" = 32)
      sum = sum(vapply(g[-1][nzchar(g[-1])], function(x) { v <- .sf_num(x)
        if (is.na(v)) length(strsplit(trimws(x), "\\s*,\\s*(?:and\\s+)?|\\s+and\\s+", perl = TRUE)[[1]]) else v }, numeric(1))),
      pair = 2,
      # "high-fat diet, with or without diabetes, vs chow" = 3: the group before "with or without" splits in two, the
      # groups after vs are added (groups: arm, the with-or-without item, the other arms)
      splitarm = 2 + length(strsplit(trimws(g[4]), "\\s*,\\s*(?:and\\s+|or\\s+)?|\\s+and\\s+|\\s+or\\s+", perl = TRUE)[[1]]),
      # "every 4 h over 24 h" = 6, "every 4 h over two days" = 12: span / step, the start point is not counted again;
      # groups: step, step unit, span (empty for "a day" / "the day" = 1), span unit; hours per unit in time_unit
      interval = {
        u <- .sf_rules_rows("time_unit")
        hrs <- function(x) { k <- which(vapply(u$pattern, grepl, logical(1), x = x, perl = TRUE))[1]
          if (is.na(k)) NA_real_ else as.numeric(u$term[k]) }
        span <- if (nzchar(g[4])) .sf_num(g[4]) else 1
        floor(span * hrs(g[5]) / (.sf_num(g[2]) * hrs(g[3])) + 1e-9)
      },
      # "0 to 3 copies" = 4, "BC1 to BC6 and W22" = 7: the first two numeric groups bound an inclusive range, each
      # later non-numeric group is one more named level
      range = {
        x <- g[-1]; num <- grepl("^\\d+$", x)
        if (sum(num) < 2) NA else {
          k <- which(num)[1:2]; extra <- x[-seq_len(k[2])]
          as.numeric(x[k[2]]) - as.numeric(x[k[1]]) + 1 + sum(nzchar(extra) & !grepl("^\\d+$", extra))
        }
      },
      if (grepl("^\\d+$", r$match[i])) as.numeric(r$match[i]) else NA)   # a fixed count: "a hybrid and its two parents" = 3
    if (!is.na(n) && n < 2) next
    out[[nm]] <- n; spans[[nm]] <- g[1]
    # a pair written "X and Y" / "X vs Y" names its two levels ("wild type and mutant")
    if (r$match[i] %in% c("pair", "coord") && identical(as.numeric(n), 2)) {
      pp <- trimws(sub("^(?:the|a|an|its|their)\\s+", "", strsplit(trimws(g[1]), "\\s+(?:and|vs\\.?|versus)\\s+", perl = TRUE)[[1]], perl = TRUE))
      if (length(pp) == 2 && all(nzchar(pp)) && all(lengths(strsplit(pp, "\\s+")) <= 3)) pair_names[[nm]] <- pp
    }
    if (r$match[i] %in% c("sum", "range")) attr(out, "summed") <- c(attr(out, "summed"), nm)
    # a list of numbers keeps its values and unit ("at 24, 48 and 72 h": 24 48 72, h; units: rules.tsv time_unit_name)
    if (identical(r$match[i], "list") && !extra) {
      v <- as.numeric(regmatches(g[2], gregexpr("(?<![\\d.-])\\d+(?:\\.\\d+)?(?![\\d.]*-)", g[2], perl = TRUE))[[1]])
      if (length(v) == n) {
        mm <- regexpr(re, text, perl = TRUE)
        ctx <- substr(text, mm, mm + attr(mm, "match.length") + 15)
        # the list with the rest of its clause: "... mM NaCl in a growth chamber" (not the next clause)
        e <- mm + attr(mm, "match.length")
        spans[[nm]] <- paste0(substr(text, mm, e - 1), sub("[,;.].*$", "", substr(text, e, e + 40), perl = TRUE))
        un <- .sf_unit_name(regmatches(ctx, gregexpr("[a-z\u00b5\u00b0%/]+", ctx, perl = TRUE))[[1]])
        vals[[nm]] <- list(values = v, unit = un)
      }
    }
  }
  attr(out, "spans") <- spans; attr(out, "values") <- vals; attr(out, "arms") <- arms; attr(out, "named") <- pair_names
  out
}

# the first word that names a time unit (rules.tsv time_unit_name: canonical name, word pattern), else NULL
.sf_unit_name <- function(words, outcome = FALSE) {
  # time units first, then other level units (rules.tsv level_unit_name: dose, concentration, temperature, ...)
  u <- tryCatch(rbind(.sf_rules_rows("time_unit_name"), .sf_rules_rows("level_unit_name"),
    if (isTRUE(outcome)) .sf_rules_rows("outcome_unit_name")), error = function(e) NULL)
  if (is.null(u)) return(NULL)
  # a unit written as two words ("kg N/ha") is tried joined first, then each word alone
  if (length(words) >= 2) words <- c(rbind(paste0(words[-length(words)], words[-1]), words[-length(words)]), words[length(words)])
  for (w in words) { k <- which(vapply(u$pattern, function(p) grepl(p, w, perl = TRUE), logical(1)))
    if (length(k)) return(u$term[k[1]]) }
  NULL
}

# {vocab:category} in a rule pattern stands for that rules.tsv category's words, as literal alternatives (longest first)
.sf_expand_vocab <- function(re) {
  m <- regmatches(re, gregexpr("\\{vocab:([a-z_]+)\\}", re, perl = TRUE))[[1]]
  for (tok in unique(m)) {
    w <- tryCatch(.sf_list(sub("^\\{vocab:([a-z_]+)\\}$", "\\1", tok)), error = function(e) character())
    w <- unique(w[nzchar(w)]); w <- w[order(-nchar(w))]
    alt <- if (length(w)) paste(gsub("([.\\\\|()\\[\\]{}^$*+?/-])", "\\\\\\1", w, perl = TRUE), collapse = "|") else "(?!)"
    re <- gsub(tok, alt, re, fixed = TRUE)
  }
  re
}
