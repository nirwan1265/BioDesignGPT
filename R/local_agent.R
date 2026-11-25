# Free, offline StudyForge backend: no LLM, no API key.
# Rule-based extraction of a StudySpec from plain language, then the same
# deterministic engine (unit audit, catalog, hazards, protocol notes, layouts)
# the LLM agent uses. Mirrors the "local" provider of SimItAll.

.sf_number_words <- c(one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7,
                      eight = 8, nine = 9, ten = 10, eleven = 11, twelve = 12, fifteen = 15,
                      twenty = 20, thirty = 30, forty = 40, fifty = 50, hundred = 100)

.sf_num <- function(x) {
  x <- tolower(gsub(",", "", x))
  if (x %in% names(.sf_number_words)) return(unname(.sf_number_words[x]))
  # words that state a count in other ways ("in triplicate"; rules.tsv count_word_value)
  cw <- tryCatch(.sf_map("count_word_value"), error = function(e) character())
  if (x %in% names(cw)) return(as.numeric(cw[[x]]))
  suppressWarnings(as.numeric(x))
}

.sf_num_re <- "(\\d[\\d,]*|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty)"

# spelled-out numbers above twelve ("thirty-six", "twenty one", "sixteen") -> digits before any pattern runs;
# one to twelve stay words, since the rules read "one plant per pot" and "two or three reps" as words
.sf_words_to_digits <- function(text) {
  units <- c(one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9)
  teens <- c(thirteen = 13, fourteen = 14, fifteen = 15, sixteen = 16, seventeen = 17, eighteen = 18, nineteen = 19)
  tens <- c(twenty = 20, thirty = 30, forty = 40, fifty = 50, sixty = 60, seventy = 70, eighty = 80, ninety = 90)
  re <- paste0("\\b(", paste(names(tens), collapse = "|"), ")(?:[- ](", paste(names(units), collapse = "|"), "))?\\b")
  m <- gregexpr(re, text, perl = TRUE)
  regmatches(text, m) <- lapply(regmatches(text, m), function(x) vapply(x, function(w) {
    p <- strsplit(w, "[- ]")[[1]]
    as.character(tens[[p[1]]] + if (length(p) > 1) units[[p[2]]] else 0)
  }, ""))
  for (k in names(teens)) text <- gsub(paste0("\\b", k, "\\b"), teens[[k]], text, perl = TRUE)
  text
}

# first number found immediately before any of the given nouns
.sf_count_before <- function(text, nouns, prefix = "(?:about |around |roughly |~)?") {
  # up to two modifier words between the number and the noun, but never another
  # counted noun or a preposition ("three sites this season" is not 3 seasons)
  stop <- "(?!(?:sites?|locations?|reps?|replicates?|plots?|per|at|in|on|for|this|each|from|and|with|of|blocks?|trays?|cages?|vials?|pots?|benches)\\b)"
  # a unit between the number and the noun means a measure, not a count ("at 30 kg to diets"; rules.tsv cue count_unit_word)
  unit <- tryCatch(.sf_cue("count_unit_word"), error = function(e) NULL)
  if (!is.null(unit)) stop <- paste0(stop, "(?!(?:", unit, ")\\b)")
  # a number glued to a name ("ago1-38 mutant", "zmzfp69 mutant") is part of the name, not a count
  re <- paste0(prefix, "(?<![a-z]\\d-)(?<![a-z]-)(?<![\\d.,])(?<![a-z])(?<![:/])", .sf_num_re, "\\s+(?:", stop, "[a-z][a-z0-9:-]*\\s+){0,2}?(?:", paste(nouns, collapse = "|"), ")\\b(?!",
               .sf_cue("count_within_rep"), ")")
  m <- regmatches(text, regexpr(re, text, perl = TRUE))
  if (!length(m) || grepl("\\bor\\b", m)) return(NA_real_)  # "two or three reps" is undecided
  .sf_num(regmatches(m, regexpr(.sf_num_re, m, perl = TRUE)))
}

.sf_has <- function(text, pattern) grepl(pattern, text, perl = TRUE)
# the question sentences of a prompt (those ending in "?") match a cue
.sf_asks <- function(question, cue) {
  qs <- regmatches(tolower(question), gregexpr("[^.?!]*\\?", tolower(question), perl = TRUE))[[1]]
  length(qs) > 0 && any(grepl(.sf_cue(cue), qs, perl = TRUE))
}
# the prompt leaves the replicate count open: the user asks for it, or the groups differ in size
.sf_reps_open <- function(question) .sf_asks(question, "asks_reps") || .sf_has(tolower(question), .sf_cue("unequal_groups"))

# Pattern tables (organism, system, setting, outcome, genotype nouns) live in inst/agent/rules.tsv and what each
# system is (setting / assay family / study type) in inst/registry/experimental_systems.json: see .sf_rules().

# Extract a StudySpec from free text without any language model
#' Extract a StudySpec from plain language (offline, rule-based)
#'
#' Free and deterministic: regular expressions and keyword lists, no LLM and no
#' API key. Fields it cannot find stay empty, so it never invents effect sizes
#' or variances.
#'
#' @param question The researcher's description.
#' @return A StudySpec list (see new_spec()).
#' @export
extract_spec_local <- function(question) {
  text <- .sf_words_to_digits(tolower(question))
  spec <- new_spec()
  set <- function(path, value) if (!is.null(value) && !all(is.na(value))) spec <<- spec_set(spec, path, value)

  # system: the study type (validation, breeding, multi-environment, multi-omics) if one applies, else the setting
  # the question states (growth chamber, mice, a cell line ...), else the assay family, else weaker setting cues
  # (pots, plots, cages); the assays stay listed separately either way
  sys <- unique(names(.sf_rules("system"))[vapply(.sf_rules("system"), function(p) .sf_has(text, p), logical(1))])
  study <- intersect(sys, .sf_systems_where(kind = "study"))
  stated <- unique(names(.sf_rules("setting"))[vapply(.sf_rules("setting"), function(p) .sf_has(text, p), logical(1))])
  site <- intersect(stated, .sf_systems_where(plant_site = TRUE))
  # ctx: the registry entry that decides the rules below (study type, else the setting, else the assay family);
  # the spec itself keeps them apart: system is only the setting, study_type the kind of study, the assays in assays
  ctx <- if (length(intersect(study, .sf_systems_where(keeps_type_over_setting = TRUE)))) study[1] else
    if (length(study) && length(site)) site[1] else   # "RILs in an RCBD in the field": a field trial
    if (length(study)) study[1] else if (length(stated)) stated[1] else
    if (length(sys)) sys[1] else if (.sf_has(text, .sf_cue("animal_study_fallback"))) "mouse" else NULL
  if (length(study)) set("study_type", study[1])
  # the setting: the context when that is a setting; else a stated setting, and under a study type also the weak
  # setting cues ("plots" in a multi-site trial); under an assay alone the weak cues do not count ("RNA-seq of
  # cultivars" is not a field study)
  setting <- if (isTRUE(ctx %in% .sf_systems_where(kind = "setting"))) ctx else
    c(stated, if (length(study)) intersect(sys, .sf_systems_where(kind = "setting")))   # under a study type the weak cues too
  if (length(setting)) set("system", setting[1])
  spec$system_context <- ctx   # dropped before the spec is returned
  org <- .sf_first_named(text, "organism")
  if (length(org)) set("organism", org)

  # the primary outcome: a written outcome pattern anywhere, or a vocabulary outcome inside the phrase that frames
  # the outcome ("measure X", "effects on X", "outcome is X"); a trait merely mentioned is not the outcome
  orx <- .sf_regex_rows("outcome")
  out <- unique(orx$term[vapply(orx$pattern, function(p) .sf_has(text, p), logical(1))])
  phrase <- .sf_outcome_text(text)
  if (!length(out) && !is.null(phrase)) out <- unique(.sf_find_all(phrase, "outcome"))
  if (length(out) == 1) set("primary_outcome.name", out)
  # the outcome's type from rules.tsv outcome_type (outcome name, then the question); a named outcome with no
  # matching row is continuous
  otype <- .sf_outcome_type(text, if (length(out) == 1) out else NULL)
  if (!is.null(otype)) set("primary_outcome.type", otype) else if (length(out) == 1) set("primary_outcome.type", "continuous")

  # factors
  factors <- list()
  add_factor <- function(name, n = NA, applied_to = NULL) {
    f <- list(name = name)
    if (!is.na(n)) f$n_levels <- n
    if (!is.null(applied_to)) f$applied_to <- applied_to
    factors[[length(factors) + 1]] <<- f
  }
  n_geno <- .sf_count_before(text, .sf_list("genotype_count_noun"))
  if (!is.na(n_geno)) add_factor("genotype", n_geno)
  # a line or mutant named by a gene symbol with a number ("ago1-38 mutant", "mettl3 mutants") is a genotype factor
  # whose levels are not counted by that number
  if (is.na(n_geno) && .sf_has(text, paste0("[a-z]-?\\d+\\s+(?:[a-z-]+\\s+){0,2}?(?:", paste(.sf_list("genotype_count_noun"), collapse = "|"), ")\\b")))
    add_factor("genotype")
  n_chk <- .sf_count_before(text, .sf_group("count_noun", "check"))
  if (!is.na(n_chk)) add_factor("check", n_chk)
  whole_plot_water <- .sf_has(text, .sf_cue("whole_plot_irrigation"))
  if (.sf_has(text, .sf_cue("water_factor"))) {
    n <- .sf_count_before(text, .sf_group("count_noun", "water"))
    if (is.na(n) && .sf_has(text, .sf_cue("water_two_levels"))) n <- 2
    line_src <- .sf_has(text, .sf_cue("line_source"))
    add_factor("water", n, if (line_src) "distance_from_line" else if (whole_plot_water && spec$system_context %in% "field") "main_plot")
  }
  if (.sf_has(text, .sf_cue("nitrogen_factor"))) add_factor("nitrogen", .sf_count_before(text, .sf_group("count_noun", "nitrogen")) %|na|% 2)
  if (.sf_has(text, .sf_cue("temperature_factor"))) add_factor("temperature", 2, if (.sf_has(text, .sf_cue("chamber_word"))) "chamber")
  if (.sf_has(text, .sf_cue("co2_factor"))) add_factor("co2", 2, if (.sf_has(text, .sf_cue("chamber_word"))) "chamber")
  if (.sf_has(text, .sf_cue("nutrient_factor"))) {
    add_factor("nutrient", .sf_count_before(text, .sf_group("count_noun", "nutrient")))
  }
  if (.sf_has(text, .sf_cue("antibiotic_factor"))) add_factor("antibiotic", 2, if (.sf_has(text, .sf_cue("given_in_water_or_diet"))) "cage")
  if (.sf_has(text, .sf_cue("diet_factor"))) {
    n <- .sf_count_before(text, .sf_group("count_noun", "diet"))
    add_factor("diet", n %|na|% 2, if (.sf_has(text, .sf_cue("maternal"))) "dam" else if (isTRUE(spec$system_context %in% "drosophila")) "vial")
  }
  if (.sf_has(text, .sf_cue("dose_factor"))) add_factor("dose", .sf_count_before(text, .sf_group("count_noun", "dose")) %|na|% NA)
  if (.sf_has(text, .sf_cue("sex_factor"))) add_factor("sex", 2)
  if (.sf_has(text, .sf_cue("injury_factor"))) add_factor("injury", 2)
  n_trt_groups <- .sf_count_before(text, .sf_group("count_noun", "treatment"))
  if (!is.na(n_trt_groups)) {
    add_factor("treatment", n_trt_groups)
  } else if (.sf_has(text, .sf_cue("treatment_vs_control"))) {
    if (!any(vapply(factors, `[[`, "", "name") %in% c("dose", "antibiotic", "injury"))) {
      add_factor("treatment", 2, if (.sf_has(text, .sf_cue("dosed_per_animal"))) "mouse")
    }
  }
  # genotype contrasts stated without a count
  if (!any(vapply(factors, `[[`, "", "name") == "genotype")) {
    m <- regmatches(text, regexpr(.sf_cue("n_genotypes_vs_control"), text, perl = TRUE))
    if (length(m)) {
      add_factor("genotype", .sf_num(regmatches(m, regexpr(.sf_num_re, m, perl = TRUE))) + 1)
    } else if (.sf_has(text, .sf_cue("genotype_vs_wildtype"))) {
      add_factor("genotype", 2)
    }
  }
  if (length(factors)) set("factors", factors)

  # replication and environments
  reps_nouns <- c(.sf_list("reps_noun"), if (.sf_has(text, .sf_cue("greenhouse_word"))) .sf_list("reps_noun_greenhouse"))
  set("design.reps", .sf_count_before(text, reps_nouns))
  tc <- regmatches(text, regexpr(.sf_cue("n_treated_and_n_control"), text, perl = TRUE))
  if (length(tc)) set("design.reps", .sf_num(regmatches(tc, regexpr(.sf_num_re, tc, perl = TRUE))))
  # the field or bench layout when the text names one (rules.tsv design rows whose term is a design_layout; a
  # treatment structure such as "2 x 2 factorial" is not a layout and does not answer)
  lay <- .sf_first_named(text, "design", .sf_list("design_layout"))
  if (length(lay)) set("design.type", lay)
  set("design.locations", .sf_count_before(text, .sf_list("location_noun")))
  set("design.seasons", .sf_count_before(text, .sf_list("season_noun")))
  if (.sf_has(text, .sf_cue("one_season"))) set("design.seasons", 1)
  if (.sf_has(text, .sf_cue("unreplicated"))) set("design.reps", 1)
  # other ways of stating the replicates per group (rules.tsv reps_pattern; {N} is the count_word cue)
  if (is.null(spec$design$reps)) for (rp in .sf_rules_rows("reps_pattern")$pattern) {
    g <- regmatches(text, regexec(gsub("{N}", .sf_cue("count_word"), rp, fixed = TRUE), text, perl = TRUE))[[1]]
    if (!length(g)) next
    v <- g[-1][nzchar(g[-1])][1]
    n <- if (v %in% c("one", "a single")) 1 else .sf_num(v)
    if (!is.na(n) && n >= 2 && n <= 500) { set("design.reps", n); break }   # one per group: left to the unreplicated cue
  }

  # units: "<n> <meas> per <exp>"; take the first match that names real units
  per_re <- .sf_cue("n_units_per_unit")
  pers <- regmatches(text, gregexpr(per_re, text, perl = TRUE))[[1]]
  for (per in pers) {
    parts <- regmatches(per, regexec(per_re, per, perl = TRUE))[[1]]
    meas <- sub("(?<!s)s$", "", sub("ies$", "y", sub("aves$", "af", parts[3])), perl = TRUE)   # flies -> fly
    meas <- .sf_map("measured_unit_word")[meas] %|na|% meas
    exp <- sub("s$", "", parts[4])
    n_sub <- .sf_num(parts[2])
    # "N units per <treatment group>" ("6 pigs per diet", "15 vials per diet", "four trees per treatment")
    # states the replication, not subsampling: a factor word or group word after "per"
    al <- .sf_alias_table()
    group_word <- exp %in% .sf_list("group_word") ||
      exp %in% tolower(al$alias[al$category == "factor"])
    pooled <- .sf_has(text, gsub("{G}", .sf_re_escape(exp), .sf_cue("pooled_per_group"), fixed = TRUE))
    if (group_word && !pooled && !identical(n_sub, 1) && is.null(spec$design$reps) && !meas %in% c("sample", "replicate")) {
      set("design.reps", n_sub)
      next
    }
    if (group_word) next   # a treatment group is never the experimental unit
    if (exp %in% .sf_list("not_experimental_unit")) next
    if (meas %in% .sf_list("not_measurement_unit") || meas == exp) next
    if (identical(n_sub, 1)) next   # "one plant per pot" just defines the pot
    if (!is.null(spec$measurement_unit)) next   # units already read; keep looking only for "N units per group"
    set("measurement_unit", unname(meas))
    set("subsamples_per_unit", n_sub)
    set("experimental_unit", exp)
  }
  # other ways of stating the units pooled or measured per sample (rules.tsv subsample_pattern; {N} is the
  # count_word cue): "5 plants pooled per sample", "replicates of 30 pooled flies", "bulks of 20 plants".
  # They give the count only: what the experimental unit is stays a question
  if (is.null(spec$subsamples_per_unit)) for (sp in .sf_rules_rows("subsample_pattern")$pattern) {
    g <- regmatches(text, regexec(gsub("{N}", .sf_cue("count_word"), sp, fixed = TRUE), text, perl = TRUE))[[1]]
    if (!length(g)) next
    n <- .sf_num(g[-1][nzchar(g[-1])][1])
    if (!is.na(n) && n >= 2) { set("subsamples_per_unit", n); break }
  }
  # an animal kept on its own is the unit ("individually housed rats", "hens in single-bird cages"; rules.tsv
  # unit_pattern, group 1 is the animal noun)
  if (is.null(spec$experimental_unit)) for (up in .sf_rules_rows("unit_pattern")$pattern) {
    g <- regmatches(text, regexec(up, text, perl = TRUE))[[1]]
    if (length(g) < 2 || !nzchar(g[2])) next
    u <- sub("(?<!s)s$", "", g[2], perl = TRUE)
    set("experimental_unit", unname(.sf_map("measured_unit_word")[u] %|na|% u)); break
  }
  if (.sf_has(text, .sf_cue("one_plant_per_pot"))) set("experimental_unit", "pot")
  if (.sf_has(text, .sf_cue("housed_per_cage"))) {
    if (.sf_has(text, .sf_cue("given_to_whole_cage"))) {
      set("experimental_unit", "cage"); set("measurement_unit", "mouse")
      set("subsamples_per_unit", .sf_count_before(text, .sf_group("count_noun", "per_cage"), prefix = "(?:housed )?"))
    }
  }
  cells <- regmatches(text, regexpr(.sf_cue("n_cells_per_animal"), text, perl = TRUE))
  if (length(cells)) {
    set("measurement_unit", "cell")
    set("experimental_unit", if (.sf_has(text, .sf_cue("donor_word"))) "donor" else "mouse")
    set("subsamples_per_unit", .sf_num(regmatches(cells, regexpr(.sf_num_re, cells, perl = TRUE))))
    if (.sf_has(text, .sf_cue("from_one"))) set("design.reps", 1)
    r <- regmatches(text, regexpr(.sf_cue("n_and_n_mice"), text, perl = TRUE))
    if (length(r)) set("design.reps", .sf_num(regmatches(r, regexpr(.sf_num_re, r, perl = TRUE))))
  }
  if (.sf_has(text, .sf_cue("dosed_individually"))) {
    set("experimental_unit", "mouse"); set("measurement_unit", "mouse")
    if (.sf_has(text, .sf_cue("within_cages"))) set("blocking_factors", "cage")
  }
  if (.sf_has(text, .sf_cue("maternal_treatment")) &&
      !any(vapply(factors, `[[`, "", "name") %in% c("diet", "treatment"))) {
    factors[[length(factors) + 1]] <- list(name = "treatment", n_levels = 2, applied_to = "dam")
    spec$factors <- factors
  }
  # the litter is the unit only when the text says the treatment went through the mother; maternal words alone
  # ("pups kept with their dams") raise the question instead (.sf_text_questions)
  if (.sf_has(text, .sf_cue("delivered_via_mother"))) {
    set("experimental_unit", "litter")
    if (.sf_has(text, .sf_cue("pup_word"))) set("measurement_unit", "pup")
  }
  if (.sf_has(text, .sf_cue("one_chamber_per_treatment"))) set("experimental_unit", "chamber")
  # animals sharing a pen or fish sharing a tank share the treatment when it is given in feed, water or the tank itself
  if (is.null(spec$experimental_unit) && .sf_has(text, .sf_cue("pen_word")) && .sf_has(text, .sf_cue("pen_level_treatment"))) {
    set("experimental_unit", "pen"); set("measurement_unit", "animal")
    n_pen <- .sf_count_before(text, .sf_group("count_noun", "per_pen"), prefix = "(?:of )?")
    pens_of <- regmatches(text, regexpr(.sf_cue("pens_of_n"), text, perl = TRUE))
    if (is.na(n_pen) && length(pens_of)) n_pen <- .sf_num(sub("^pens? of ", "", pens_of))
    if (!is.na(n_pen) && n_pen > 1) set("subsamples_per_unit", n_pen)
  }
  if (is.null(spec$experimental_unit) && .sf_has(text, .sf_cue("tank_word")) && .sf_has(text, .sf_cue("aquatic_animal")) &&
      .sf_has(text, .sf_cue("tank_level_treatment"))) {
    set("experimental_unit", "tank"); set("measurement_unit", "fish")
  }
  if (is.null(spec$experimental_unit)) {
    if (identical(spec$system_context, "field")) set("experimental_unit", if (.sf_has(text, .sf_cue("single_plant_plots"))) "plant" else "plot")
    if (identical(spec$system_context, "greenhouse") && .sf_has(text, .sf_cue("greenhouse_pot_unit"))) set("experimental_unit", "pot")
    if (identical(spec$system_context, "growth_chamber") && .sf_has(text, .sf_cue("pots_word"))) set("experimental_unit", "pot")
    if (spec$system_context %in% c("growth_chamber", "greenhouse") && .sf_has(text, .sf_cue("cell_tray"))) set("experimental_unit", "cell")
    if (identical(spec$system_context, "drosophila") && .sf_has(text, .sf_cue("fly_vial_study"))) {
      set("experimental_unit", "vial"); set("measurement_unit", "fly")
    }
  }
  if (.sf_has(text, .sf_cue("bench_word"))) set("blocking_factors", "bench")
  if (.sf_has(text, .sf_cue("shelf_word"))) set("blocking_factors", "shelf")
  if (.sf_has(text, .sf_cue("experimenter_word"))) set("blocking_factors", "experimenter")
  if (.sf_has(text, .sf_cue("batch_word"))) set("blocking_factors", if (.sf_has(text, .sf_cue("library_word"))) "library_batch" else "injection_batch")
  if (identical(spec$system_context, "drosophila") && is.null(spec$organism)) set("organism", "Drosophila melanogaster")

  # round 3: populations, assays, extra organisms, environments (alias table, longest match first)
  find_all <- function(cat) .sf_find_all(text, cat)
  sys_now <- spec$system_context %||% ""
  orgs <- find_all("organism")
  if (length(orgs) > 1 && identical(spec$study_type, "functional_validation")) set("organisms", orgs)
  if (length(orgs) && identical(spec$study_type, "functional_validation")) set("organism", orgs[1])
  if (sys_now %in% .sf_systems_where(lists_assays = TRUE)) {
    as <- find_all("assay")
    # the assay that is the context ("RNA-seq of ...") is not listed on its own; next to another assay it is one
    # of the assays ("m6A-seq and RNA-seq"). find_all matches the longest phrase, so a generic label found here
    # was said in its own words and stays (the generic_assay rows matter for the reader, not here)
    ctx_as <- if (!sys_now %in% .sf_systems_where(rnaseq_gwas_are_assays = TRUE)) .sf_list("context_assay")
    if (!length(setdiff(as, ctx_as))) as <- setdiff(as, ctx_as)
    if (length(as)) set("assays", as)
  } else {
    # a field, greenhouse or animal study that maps a trait lists its assays too (mapping_assay in rules.tsv)
    as <- find_all("assay")
    if (length(intersect(as, .sf_list("mapping_assay")))) set("assays", as)
  }
  # breeding generation notation (BC3F2, F2:3, BC1F3:5, RIL F6) whatever the setting
  for (nm in names(gen <- .sf_generation_notation(text))) spec <- spec_set(spec, paste0("population.", nm), gen[[nm]])
  # the mating of a stated population (F2, backcross, RILs ...) whatever the setting
  if (!identical(sys_now, "breeding_genetics")) {
    mt <- find_all("mating")
    if (length(mt)) set("population.mating", mt[1])
  }
  if (identical(sys_now, "breeding_genetics")) {
    mt <- find_all("mating")
    if (length(mt)) {
      set("population.mating", mt[1])
      mp <- .sf_mating_props(mt[1])
      for (k in grep("^population\\.", names(mp), value = TRUE)) set(k, .sf_num_or_chr(mp[[k]]))
    }
    g <- regmatches(text, regexpr(.sf_cue("n_generations"), text, perl = TRUE))
    if (length(g)) set("population.generations", .sf_num(regmatches(g, regexpr(.sf_num_re, g, perl = TRUE))))
    fg <- regmatches(text, regexpr(.sf_cue("filial_generation"), text, perl = TRUE))
    if (length(fg)) set("population.filial_generation", as.numeric(sub(".*f", "", fg)))
    mf <- regmatches(text, regexec(.sf_cue("n_males_and_n_females"), text, perl = TRUE))[[1]]
    if (length(mf)) set("population.parents", .sf_num(mf[2]) + .sf_num(mf[3]))
    fo <- regmatches(text, regexec(.sf_cue("n_founders"), text, perl = TRUE))[[1]]
    if (length(fo)) set("population.parents", .sf_num(fo[2]) + 1)
    am <- regmatches(text, regexec(.sf_cue("among_n"), text, perl = TRUE))[[1]]
    if (length(am)) set("population.parents", .sf_num(am[2]))
    if (.sf_has(text, .sf_cue("combining_ability"))) {
      set("primary_outcome.name", "gca_sca"); set("primary_outcome.type", "continuous")
    }
  }
  if (identical(spec$study_type, "multi_environment") && .sf_has(text, .sf_cue("controlled_environment")) && .sf_has(text, .sf_cue("field_word"))) {
    set("environments", c("greenhouse", "field"))
  }
  if (.sf_rule_hit("system", "ribo_seq", text) && .sf_has(text, .sf_cue("translation_efficiency"))) {   # the assay, whatever the setting
    set("primary_outcome.name", "translation_efficiency"); set("primary_outcome.type", "continuous")
  }
  if (sys_now %in% c("multi_environment") && is.null(spec$primary_outcome) && .sf_has(text, .sf_cue("yield_stability"))) {
    set("primary_outcome.name", "grain_yield"); set("primary_outcome.type", "continuous")
  }

  spec <- .sf_general_layer(spec, text)
  spec <- .sf_panel_genotype(spec)
  spec <- .sf_genetics(spec, text)
  kinds <- .sf_assay_kinds(text); if (length(kinds)) spec$assay_kinds <- as.list(kinds)
  spec <- .sf_repeated_on_unit(spec, text)
  # analysis goals the question names (R/goals.R; rules.tsv analysis_goal) and time-course details
  g <- .sf_goals_from_text(text); if (length(g)) spec$analysis$goals <- as.list(g)
  tc <- .sf_time_course_detail(text); if (length(tc)) spec$analysis$time_course <- tc
  pu <- .sf_per_unit_effect(text); if (!is.null(pu)) spec$analysis$per_unit_effect <- pu
  spec$system_context <- NULL
  if (.sf_reps_open(question)) spec$design$reps <- NULL
  spec <- .sf_clear_asked(spec, question)   # what the user asks about stays open (questions.tsv)
  spec$question <- question
  spec
}

`%|na|%` <- function(a, b) if (length(a) == 0 || is.na(a)) b else a

# The study type, the setting and the families of the stated assays: the setting decides the layout, and the study
# type and each assay bring their own designs, hazards and questions (a greenhouse ATAC-seq study gets greenhouse
# and ATAC advice; a RIL trial in the field gets breeding and field advice).
.sf_system_set <- function(spec) {
  fam <- unname(.sf_map("system_by_assay")[unlist(spec$assays)])
  fam <- c(fam, unname(.sf_map("assay_advice_family")[unlist(spec$assays)]))
  s <- unique(c(spec$study_type, spec$system, fam[!is.na(fam)]))
  s[nzchar(s)]
}

# Replication floor: a stated n below 3 per condition is flagged. Not when the candidates are designs built
# for unreplicated entries (augmented, p-rep, diagonal checks), which estimate error from replicated checks.
.sf_replication_check <- function(spec, candidates = character()) {
  reps <- suppressWarnings(as.numeric(spec$design$reps %||% NA))
  if (length(reps) != 1 || is.na(reps) || reps >= 3) return(NULL)
  if (any(candidates %in% c("augmented", "prep", "diagonal_checks", "augmented_tray"))) return(NULL)
  why <- if (reps < 2) {
    "With one per condition there is no within-group variance, so no test or interval is possible."
  } else {
    "With two per condition the variance rests on 1 degree of freedom per group, so tests have little power and one outlier decides the result."
  }
  paste0(reps, " replicate", if (reps != 1) "s", " per condition is below the usual floor of 3 biological replicates. ", why,
         " Use at least 3, and set the final number by power; published studies often use more.")
}

# Questions the wording itself raises: a name that could mean several organisms (rules.tsv ambiguous_organism);
# animals sharing housing when the text does not say how the treatment was given (rules.tsv unit_question)
.sf_text_questions <- function(spec, text) {
  out <- character()
  t0 <- .sf_words_to_digits(tolower(text))
  if (is.null(spec$experimental_unit)) {
    q <- .sf_map("unit_question")
    has <- function(cue) .sf_has(t0, .sf_cue(cue))
    open <- c(litter = has("maternal") && !has("delivered_via_mother"),
              cage = has("housed_per_cage") && !has("given_to_whole_cage") && !has("dosed_individually"),
              pen = has("pen_word") && !has("pen_level_treatment"),
              tank = has("tank_word") && has("aquatic_animal") && !has("tank_level_treatment"))
    out <- c(out, unname(names(q)[match(names(open)[open], q)]))
  }
  if (is.null(spec$organism)) {
    amb <- .sf_rules_rows("ambiguous_organism")
    t <- tolower(text)
    for (w in unique(amb$pattern)) {
      if (grepl(paste0("(?<![a-z0-9])", .sf_re_escape(tolower(w)), "(?![a-z0-9])"), t, perl = TRUE)) {
        out <- c(out, sprintf("Which species do you mean by '%s': %s?", w, paste(amb$term[amb$pattern == w], collapse = " or ")))
      }
    }
  }
  out
}

# Choose candidate designs with simple, transparent rules
.sf_candidates <- function(spec) {
  # the entry whose designs come first: a study type that keeps its type over the setting (validation,
  # multi-environment), else the setting when it is a plant site, else the study type, else the setting, else the
  # family of the first assay
  st <- spec$study_type; se <- spec$system
  fam1 <- setdiff(.sf_system_set(spec), c(st, se))[1]
  sys <- if (!is.null(st) && (st %in% .sf_systems_where(keeps_type_over_setting = TRUE) || is.null(se) ||
                              !se %in% .sf_systems_where(plant_site = TRUE))) st else se %||% fam1 %||% ""
  if (is.na(sys)) sys <- ""
  f <- spec$factors %||% list()
  fname <- vapply(f, `[[`, "", "name")
  n_geno <- suppressWarnings(max(c(0, unlist(lapply(f, function(x) if (x$name == "genotype") x$n_levels)))))
  applied <- unlist(lapply(f, `[[`, "applied_to"))
  reps <- spec$design$reps %||% NA
  cand <- character()
  if (sys == "field") {
    q <- tolower(spec$question %||% "")
    if (any(applied %in% "distance_from_line")) cand <- c(cand, "line_source")
    if (any(applied %in% "main_plot") || .sf_has(q, .sf_cue("mixed_height"))) cand <- c(cand, "split")
    if (.sf_has(q, .sf_cue("early_generation_trial"))) cand <- c(cand, "prep", "augmented")
    if (!is.na(reps) && reps == 1) cand <- c(cand, if (n_geno >= 500) "diagonal_checks", "augmented", "prep")
    if (n_geno > 25 && (is.na(reps) || reps > 1)) cand <- c(cand, "alpha", "row_column")
    if (n_geno > 0 && n_geno <= 25) cand <- c(cand, "rcbd")
    cand <- c(cand, "spatial_analysis")
  } else if (sys == "greenhouse") {
    q <- tolower(spec$question %||% "")
    cand <- c(cand, if (length(f) > 1) "factorial", if (.sf_has(q, .sf_cue("repeated_over_time_plants"))) "repeated_measures",
              if (length(f) > 1 && .sf_has(q, .sf_cue("bench_mention"))) "split", if (n_geno > 20) "alpha", "rcbd", "row_column")
  } else if (sys == "growth_chamber") {
    if (any(applied %in% "chamber") || identical(spec$experimental_unit, "chamber")) cand <- c(cand, "chamber_runs")
    if (.sf_has(tolower(spec$question %||% ""), .sf_cue("tray_mention"))) cand <- c(cand, "augmented_tray", "prep")
    cand <- c(cand, "rcbd")
  } else if (sys == "mouse") {
    cand <- c(cand, if (length(f) > 1) "factorial", "rcbd", "crd")
  } else if (sys == "breeding_genetics") {
    mt <- spec$population$mating %||% ""
    q <- tolower(spec$question %||% "")
    mc <- unlist(.sf_mating_props(mt)[names(.sf_mating_props(mt)) == "candidate"])
    cand <- c(cand, mc[mc != "mapping_population"],
              if ("mapping_population" %in% mc || .sf_has(q, .sf_cue("mapping_intent"))) "mapping_population",
              if (!is.null(spec$design$locations)) "met_fa", "alpha")
  } else if (sys == "multi_environment") {
    cand <- c(cand, if (length(spec$environments) > 1 || .sf_has(tolower(spec$question %||% ""), .sf_cue("controlled_setting_mention"))) "gh_field_validation", "met_fa", "alpha", "spatial_analysis")
  } else if (sys == "multi_omics") {
    cand <- c(cand, "gwas_eqtl", if ("atac_seq" %in% spec$assays) "atac_replicated", if ("ribo_seq" %in% spec$assays) "riboseq_rnaseq", "alpha")
  } else if (sys == "ribo_seq") {
    cand <- c(cand, "riboseq_rnaseq", "rcbd")
  } else if (sys == "atac_seq") {
    cand <- c(cand, "atac_replicated", "rcbd")
  } else if (sys == "functional_validation") {
    cand <- c(cand, "cross_species_validation", "rcbd")
  } else if (sys == "livestock") {
    q <- tolower(spec$question %||% "")
    cand <- c(cand, if (length(f) > 1) "factorial", if (.sf_has(q, .sf_cue("repeated_over_time_animals"))) "repeated_measures", "rcbd", "crd")
  } else if (sys == "drosophila") {
    cand <- c(cand, if (identical(spec$primary_outcome$name, "lifespan") || .sf_has(tolower(spec$question %||% ""), .sf_cue("vial_lifespan_study"))) "vial_lifespan", "rcbd")
  } else {
    cand <- c(cand, "rcbd", "crd")
  }
  # assay families add their own designs after the setting's
  fam <- setdiff(.sf_system_set(spec), sys)
  if ("ribo_seq" %in% fam) cand <- c(cand, "riboseq_rnaseq")
  if ("atac_seq" %in% fam) cand <- c(cand, "atac_replicated")
  .sf_cover_factors(unique(cand), spec)
}

# The factor structure decides first. A design covers two or more randomized factors when its catalog model has a
# second treatment term (treatment2), or time when one of the factors is time. Covering candidates move to the front;
# when none covers, split goes first if a factor is applied to main plots, else factorial.
.sf_cover_factors <- function(cand, spec) {
  rf <- .sf_randomized_factors(spec)
  if (length(rf) < 2) return(cand)
  models <- vapply(load_registry("design_catalog")$designs, function(d) d$model, "")
  names(models) <- vapply(load_registry("design_catalog")$designs, `[[`, "", "id")
  covers <- function(id) {
    m <- models[id]; if (is.na(m)) return(FALSE)
    v <- all.vars(stats::as.formula(m))
    "treatment2" %in% v || ("time" %in% v && "time" %in% rf && length(rf) == 2)
  }
  ok <- vapply(cand, covers, logical(1))
  if (any(ok)) return(c(cand[ok], cand[!ok]))
  applied <- unlist(lapply(spec$factors %||% list(), `[[`, "applied_to"))
  unique(c(if (any(applied %in% "main_plot")) "split" else "factorial", cand))
}

# Factors that are randomized to experimental units; factors measured within a unit (tissues of one plant, cue
# list within_unit_factor in rules.tsv) are not
.sf_randomized_factors <- function(spec) {
  nm <- vapply(spec$factors %||% list(), function(x) x$name %||% "", "")
  setdiff(nm[nzchar(nm)], .sf_within_factors(spec))
}

# factors measured within one experimental unit, not randomized to units: rules.tsv within_unit_factor (tissue, cell
# type, fraction) always; an occasion factor (rules.tsv occasion_factor: time, stage, age) when the same units are
# measured at every level (spec$repeated_factors, read from the text or answered by the user)
.sf_within_factors <- function(spec) {
  nm <- vapply(spec$factors %||% list(), function(x) x$name %||% "", "")
  intersect(nm, c(.sf_list("within_unit_factor"), unlist(spec$repeated_factors)))
}

# same units at every time / stage / age? TRUE (the text says so: cue same_units_over_occasions), FALSE (destructive:
# cue different_units_per_occasion), NULL (not stated: asked, rules.tsv occasion_question)
.sf_repeated_on_unit <- function(spec, text) {
  occ <- intersect(vapply(spec$factors %||% list(), function(x) x$name %||% "", ""), .sf_list("occasion_factor"))
  if (!length(occ)) return(spec)
  t <- tolower(text)
  # "embryos pooled from the same dam": the things measured are whole individuals (rules.tsv unit terms listed in
  # whole_individual_unit) that only share a source, so "the same dam" says nothing about repeated measurement; such
  # phrases are taken out before the same-units cue is read ("follicles from the same hen" stays)
  src <- gregexpr("\\b([a-z-]+)\\s+(?:from|of|born to|out of)\\s+the\\s+same\\s+[a-z-]+", t, perl = TRUE)
  hits <- regmatches(t, src)[[1]]
  whole <- .sf_list("whole_individual_unit")
  for (h in hits) if (length(intersect(.sf_find_all(sub("\\s.*$", "", h), "unit"), whole))) t <- sub(h, " ", t, fixed = TRUE)
  # an open question ("should I sample the same cows repeatedly?") and "the same rat as controls" (a within-unit
  # control, not an occasion) say nothing either (cues undecided_question, same_unit_as_control)
  for (cu in c("undecided_question", "same_unit_as_control")) t <- gsub(tryCatch(.sf_cue(cu), error = function(e) "(?!)"), " ", t, perl = TRUE)
  # "four age groups": that occasion factor is between units even when another one is repeated (cue occasion_groups)
  og <- tryCatch(.sf_cue("occasion_groups"), error = function(e) "(?!)")
  rep_occ <- occ[!vapply(occ, function(f) grepl(gsub("{F}", f, og, fixed = TRUE), t, perl = TRUE), logical(1))]
  # "the same X" counts only when X is the measured subject: "piglets produced by embryo transfer into the same
  # recipient sows" names the sows, not the piglets (subject = the first living-subject noun, cue living_subject;
  # a generic X like "animals" matches any subject, cue generic_individual)
  sing <- function(w) sub("(?<=[^s])s$", "", sub("ies$", "y", w, perl = TRUE), perl = TRUE)
  ts <- gsub(.sf_cue("donor_phrase"), " ", t, perl = TRUE)   # donors are a source, not the subject
  subj <- regmatches(ts, regexpr(.sf_cue("living_subject"), ts, perl = TRUE))
  if (!length(subj)) subj <- regmatches(ts, regexpr(.sf_cue("repeatable_unit"), ts, perl = TRUE))
  same_hits <- regmatches(t, gregexpr(.sf_cue("same_units_over_occasions"), t, perl = TRUE))[[1]]
  perennial <- .sf_has(t, tryCatch(.sf_cue("perennial_plant"), error = function(e) "(?!)"))
  same_ok <- vapply(same_hits, function(h) {
    # "sampled repeatedly" says the same units only for subjects that survive sampling (animals, people, vessels,
    # trees); for annual plants and organs it may be new plants each time, so it is asked (cue weak_repeat_phrase)
    if (grepl(tryCatch(.sf_cue("weak_repeat_phrase"), error = function(e) "(?!)"), h, perl = TRUE))
      return(length(subj) > 0 || perennial)
    if (!grepl("\\bsame\\b", h)) return(TRUE)
    x <- utils::tail(strsplit(trimws(h), "\\s+")[[1]], 1)
    !length(subj) || grepl(.sf_cue("generic_individual"), x, perl = TRUE) || !grepl(.sf_cue("living_subject"), x, perl = TRUE) ||
      sing(x) == sing(utils::tail(strsplit(subj, "\\s+")[[1]], 1))
  }, logical(1))
  # an explicit "same / again / repeatedly" wins over a kill word ("bled weekly, sacrificed at the end"); without
  # either, "before and after X" / "over time" on living subjects with a sample that does not kill them (blood,
  # faeces, milk, a biopsy) is the same subjects (cues repeat_occasion_phrase, nondestructive_sample, living_subject)
  if (any(same_ok)) spec$repeated_factors <- as.list(rep_occ)
  else if (.sf_has(t, .sf_cue("different_units_per_occasion"))) spec$repeated_factors <- list()
  else if (length(subj) && .sf_has(t, .sf_cue("repeat_occasion_phrase")) && .sf_has(t, .sf_cue("nondestructive_sample")) &&
           !.sf_has(t, .sf_cue("group_specific_occasion")))
    spec$repeated_factors <- as.list(rep_occ)
  spec
}

.sf_recipe <- function(spec, candidates) {
  f <- spec$factors %||% list()
  geno <- Filter(function(x) x$name == "genotype", f)
  # an open genotype count (a panel whose size the user has not given yet) uses the stated layout default
  n <- if (length(geno) && !is.null(geno[[1]]$n_levels)) geno[[1]]$n_levels else
    as.integer(.sf_layout_default("factor:genotype", spec) %||% 12)
  reps <- spec$design$reps %||% 3
  first <- candidates[1] %||% "rcbd"
  trt <- sprintf('paste0("G", 1:%s)', n)
  switch(first,
    alpha = {
      k <- .divisors(n)
      k <- if (length(k)) k[which.min(abs(k - sqrt(n)))] else n
      sprintf('book <- make_design("alpha", %s, reps = %s, block_size = %s, seed = 42)\nfield <- add_field_coordinates(book, n_cols = %s)', trt, max(2, reps), k, k)
    },
    split = sprintf('book <- make_design("split", c("wet", "dry"), reps = %s, treatments2 = %s, seed = 42)', reps, trt),
    augmented = sprintf('book <- make_design("augmented", %s, reps = 5, checks = c("Check1", "Check2"), seed = 42)\nfield <- add_field_coordinates(book, n_cols = 20)', trt),
    diagonal_checks = sprintf('book <- make_design("augmented", %s, reps = 10, checks = paste0("Check", 1:5), seed = 42)\nfield <- add_field_coordinates(book, n_cols = 30)', trt),
    augmented_tray = sprintf('trays <- make_tray_design(%s, checks = c("Col-0", "Ler"), tray_rows = 6, tray_cols = 8)', trt),
    vial_lifespan = 'vials <- make_vial_allocation(c("T1", "T2", "T3"), vials_per_treatment = 15, flies_per_vial = 10)',
    chamber_runs = 'book <- make_design("rcbd", c("level1", "level2"), reps = 4, seed = 42)  # reps = chamber-runs',
    factorial = 'book <- make_design("factorial", reps = 4, factor_levels = list(A = c("a1", "a2"), B = c("b1", "b2")), seed = 42)',
    sprintf('book <- make_design("rcbd", %s, reps = %s, seed = 42)', trt, reps)
  )
}

#' Ask StudyForge (free by default)
#'
#' The default provider, "local", is free and offline: rule-based extraction plus
#' the deterministic engine, no language model and no API key. "ollama" adds a
#' free local LLM (https://ollama.com) that only rephrases the deterministic
#' plan; it is told not to change any number.
#'
#' @param question Plain-language description of the planned experiment.
#' @param provider "local" (default) or "ollama".
#' @param engine How the prompt is read: "rules" (default, pure R), "hybrid" (rules +
#'   the bundled trained tagger; needs Python with torch and transformers, set
#'   STUDYFORGE_PYTHON), "llm" (rules + the Biodes LLM reader on a GPU node, see
#'   extract_spec_llm(); stated facts only), or "auto" (llm when a reader is reachable,
#'   else hybrid when STUDYFORGE_PYTHON is set, else rules).
#' @param model Ollama model name.
#' @param ollama_endpoint Ollama generate endpoint.
#' @param fix Named list of corrections applied to the extracted spec (see studyforge_fix()).
#' @return An object of class `studyforge_answer`.
#' @export
studyforge_ask <- function(question, provider = c("local", "ollama"), engine = c("rules", "hybrid", "llm", "auto"),
                           model = Sys.getenv("STUDYFORGE_OLLAMA_MODEL", "llama3.2"),
                           ollama_endpoint = Sys.getenv("STUDYFORGE_OLLAMA_ENDPOINT",
                                                        "http://localhost:11434/api/generate"),
                           fix = NULL) {
  provider <- match.arg(provider)
  engine <- match.arg(engine)
  if (engine == "auto") engine <- if (!is.null(.sf_reader_conf())) "llm" else if (nzchar(Sys.getenv("STUDYFORGE_PYTHON"))) "hybrid" else "rules"
  reader_questions <- NULL
  spec <- if (engine == "hybrid") extract_spec_hybrid(question) else extract_spec_local(question)
  if (engine == "llm") {
    llm <- extract_spec_llm(question)
    if (is.null(llm)) engine <- "rules" else {
      reader_questions <- unlist(llm$missing_questions)
      spec <- merge_specs(spec, llm, question)
    }
  }
  spec <- .sf_apply_fix(spec, fix)
  v <- validate_spec(spec)
  system <- spec$system %||% NA_character_

  audit <- if (!is.null(spec$experimental_unit) && !is.null(spec$measurement_unit)) {
    unit_audit(spec$organism %||% "organism", spec$experimental_unit, spec$measurement_unit,
               subsamples_per_unit = spec$subsamples_per_unit %||% 1)
  }
  candidates <- .sf_candidates(spec)
  designs <- lapply(candidates, lookup_design)
  # the candidates the engine proposed are the spec's design.candidates unless the user named their own
  if (length(candidates) && is.null(spec$design$candidates)) {
    spec$design$candidates <- as.list(candidates)
    v <- validate_spec(spec)
  }
  sysset <- .sf_system_set(spec)
  hazards <- if (length(sysset)) setup_hazards(sysset) else list()
  if (length(hazards)) {
    # most relevant first: hazards sharing words with the question
    qwords <- unique(strsplit(gsub("[^a-z ]", " ", tolower(question)), "\\s+")[[1]])
    qwords <- qwords[nchar(qwords) > 3]
    score <- vapply(hazards, function(h) {
      hay <- tolower(paste(h$id, h$hazard, paste(unlist(h$mitigation), collapse = " ")))
      sum(vapply(qwords, function(w) grepl(w, hay, fixed = TRUE), logical(1)))
    }, numeric(1))
    hazards <- hazards[order(-score)]
  }
  known <- vapply(load_registry("experimental_systems")$systems, `[[`, "", "id")
  questions <- unique(unlist(lapply(intersect(sysset, known), system_questions)))
  if (is.null(questions)) questions <- character()
  questions <- questions[!vapply(questions, .sf_question_answered, logical(1), spec = spec)]
  # a factor without a level count cannot be laid out: ask for the count first (wording: rules.tsv level_question)
  open_lv <- vapply(Filter(function(f) nzchar(f$name %||% "") && is.null(f$n_levels) && !length(f$levels),
                           spec$factors %||% list()), `[[`, "", "name")
  if (length(open_lv)) {
    lq <- .sf_rules_rows("level_question")
    ask_lv <- vapply(open_lv, function(nm) { q <- lq$pattern[lq$term == nm]; if (!length(q)) q <- lq$pattern[lq$term == "*"]
      gsub("{F}", nm, q[1], fixed = TRUE) }, "")
    questions <- unique(c(ask_lv, questions))
    v$missing <- unique(c(v$missing, paste0("factors.", open_lv, ".n_levels")))
  }
  # no goal named and the design can answer more than one: ask which (rules.tsv goal_question)
  if (!length(spec$analysis$goals)) { gq <- .sf_goal_question(spec); if (!is.null(gq)) questions <- unique(c(questions, gq)) }
  # an occasion factor (time, stage, age) without "same units at every level?" answered: ask it (rules.tsv
  # occasion_question; {F} factor, {U} experimental unit)
  occ <- intersect(vapply(spec$factors %||% list(), function(x) x$name %||% "", ""), .sf_list("occasion_factor"))
  if (length(occ) && is.null(spec$repeated_factors)) {
    oq <- .sf_rules_rows("occasion_question")
    ask_oc <- vapply(occ, function(nm) { q <- oq$pattern[oq$term == nm]; if (!length(q)) q <- oq$pattern[oq$term == "*"]
      gsub("{U}", spec$experimental_unit %||% "unit", gsub("{F}", nm, q[1], fixed = TRUE), fixed = TRUE) }, "")
    questions <- unique(c(questions, ask_oc))
  }
  if (!length(spec$factors)) {
    q0 <- .sf_rules_rows("level_question"); q0 <- q0$pattern[q0$term == "_none"]
    if (length(q0)) questions <- unique(c(q0[1], questions))
  }
  questions <- unique(c(.sf_text_questions(spec, question), questions))   # what the words leave open comes first
  notes <- if (length(sysset)) protocol_notes(system = sysset) else list()
  org_word <- tolower(strsplit(.sf_str1(spec$organism), " ")[[1]][1])
  if (!is.na(org_word) && nzchar(org_word)) {
    hits <- Filter(function(n) grepl(org_word, tolower(paste(n$citation, paste(unlist(n$tags), collapse = " "), n$lesson))), notes)
    if (length(hits)) notes <- c(hits, Filter(function(n) !n$id %in% vapply(hits, `[[`, "", "id"), notes))
  }

  ans <- structure(list(
    question = question, provider = provider, engine = engine, fixes = fix, spec = spec, validation = v, audit = audit,
    candidates = candidates, designs = designs, hazards = hazards, reader_questions = reader_questions,
    replication = .sf_replication_check(spec, candidates),
    questions = utils::head(questions, 3), all_questions = questions,
    notes = utils::head(notes, 3), recipe = .sf_recipe(spec, candidates),
    practice = tryCatch(.sf_practice_for_spec(spec, question), error = function(e) NULL),
    traits = tryCatch({
      omics <- length(spec$assays) || isTRUE(spec$system %in% .sf_systems_where(sequencing = TRUE))
      if (grepl(.sf_cue("asks_traits"), tolower(question), perl = TRUE) || (is.null(spec$primary_outcome$name) && !omics && !identical(spec$goal, "analysis")))
        suggest_traits(spec$tissue, .sf_stresses(spec, question), spec$organism, n = 6)
    }, error = function(e) NULL),
    disclaimer = if (identical(system, "mouse")) "Planning recommendation only; final designs need statistician, veterinarian and IACUC review."
  ), class = "studyforge_answer")

  if (provider == "ollama") ans$llm_text <- .sf_ollama(ans, model, ollama_endpoint)
  ans
}

.sf_ollama <- function(ans, model, endpoint) {
  if (!requireNamespace("httr2", quietly = TRUE)) {
    return("Install httr2 to use the Ollama provider; showing the free local plan only.")
  }
  plan <- paste(utils::capture.output(print(ans, llm = FALSE)), collapse = "\n")
  prompt <- paste0(
    "You are StudyForge. Rewrite the deterministic experimental-design plan below as a short, friendly answer ",
    "to the researcher. Do NOT add, change or invent any numbers, sample sizes, effect sizes or designs. ",
    "Keep every warning about pseudoreplication and every question.\n\nQUESTION:\n", ans$question,
    "\n\nPLAN:\n", plan)
  res <- tryCatch(
    httr2::request(endpoint) |>
      httr2::req_body_json(list(model = model, prompt = prompt, stream = FALSE)) |>
      httr2::req_perform() |>
      httr2::resp_body_json(),
    error = function(e) NULL)
  if (is.null(res)) {
    return(paste0("Could not reach Ollama at ", endpoint, ". Start it with `ollama serve` and `ollama pull ", model,
                  "`. Showing the free local plan only."))
  }
  res$response
}

#' @export
print.studyforge_answer <- function(x, llm = TRUE, ...) {
  cat0 <- function(...) cat(..., "\n", sep = "")
  if (llm && !is.null(x$llm_text)) {
    cat0(x$llm_text)
    cat0("\n---- deterministic plan ----")
  }
  s <- x$spec
  cat0("StudyForge (", x$provider, if (identical(x$engine, "hybrid")) " + trained tagger",
       if (identical(x$engine, "llm")) " + LLM reader", ", free)\n")
  cat0("Here's what I understood (fix anything wrong: studyforge_fix(answer, organism = \"...\", factors = \"name:levels\")):")
  for (l in .sf_skeleton_lines(s, x$fixes %||% list())) cat0(l)
  if (identical(s$goal, "analysis")) {
    cat0("\nThis reads as analysis of data you already have. Analysis (Bioana) is coming; below is the design",
         " this data implies, which fixes the model it should be analysed with.")
  }
  cat0("")
  cat0("System: ", s$system %||% "unknown", if (!is.null(s$study_type)) paste0(" | Study: ", s$study_type),
       if (!is.null(s$organism)) paste0(" | Organism: ", s$organism))
  if (length(s$factors)) {
    fx <- vapply(s$factors, function(f) paste0(f$name, if (!is.null(f$n_levels)) paste0(" (", f$n_levels, ")"),
                                               if (!is.null(f$applied_to)) paste0(" on ", f$applied_to)), "")
    cat0("Factors: ", paste(fx, collapse = "; "))
  }
  if (!is.null(s$primary_outcome$name)) cat0("Primary outcome: ", s$primary_outcome$name)
  if (!is.null(s$experimental_unit)) cat0("Experimental unit: ", s$experimental_unit)
  if (!is.null(s$design)) cat0("Design facts: ", paste(names(s$design), unlist(s$design), sep = " = ", collapse = ", "))
  if (!is.null(x$audit)) {
    cat0("\nUnit audit: risk ", toupper(x$audit$pseudoreplication_risk))
    cat0("  ", x$audit$resolution)
  }
  if (!is.null(x$replication)) cat0("\nReplication: ", x$replication)
  if (length(x$validation$missing)) cat0("\nStill needed: ", paste(x$validation$missing, collapse = ", "))
  if (length(x$questions)) {
    cat0("\nQuestions that change the design:")
    for (q in x$questions) cat0("  - ", q)
  }
  if (length(x$reader_questions)) {
    cat0("\nThe reader would also ask:")
    for (q in utils::head(x$reader_questions, 4)) cat0("  - ", q)
  }
  if (length(x$designs)) {
    cat0("\nCandidate designs:")
    for (d in x$designs) cat0("  - ", d$name, ": ", d$use_when, " Tradeoff: ", d$tradeoff)
  }
  if (length(x$hazards)) {
    cat0("\nSetup checks (", length(x$hazards), "):")
    for (h in utils::head(x$hazards, 6)) cat0("  - ", h$hazard, " -> ", h$mitigation[[1]])
    if (length(x$hazards) > 6) cat0("  ... see answer$hazards for all")
  }
  if (length(x$notes)) {
    cat0("\nWhat published studies did:")
    for (n in x$notes) cat0("  - ", n$citation, ": ", n$lesson)
  }
  if (!is.null(x$traits) && nrow(x$traits)) {
    cat0("\nTraits you could measure", if (!is.null(s$tissue)) paste0(" (", s$tissue, ")"), " -- pick one primary outcome; the rest are secondary:")
    for (i in seq_len(nrow(x$traits))) {
      t <- x$traits[i, ]
      cat0("  - ", t$trait, ": ", t$measured_by, " [", t$tools, "]", if (t$destructive) " (destructive)",
           if (nzchar(t$doi)) paste0(" (", t$source, ", doi:", t$doi, ")"))
      if (nzchar(t$note)) cat0("      ", t$note)
    }
  }
  if (!is.null(x$practice)) {
    cat0("\nPublished practice (what designed studies in ENA/SRA/GEO did; descriptive, not a recommendation):")
    for (l in .sf_practice_lines(x$practice)) cat0("  ", l)
    sm <- x$practice$summary
    reps <- s$design$reps
    if (!is.null(reps) && !is.na(sm$reps_median) && reps < sm$reps_median) {
      cat0("  Your ", reps, " replicate(s) per condition is fewer than the median of these studies (",
           .sf_fmt(sm$reps_median), ").")
    }
    if (x$practice$technique %in% c("Bulk RNA-seq", "3' Tag-seq", "small RNA-seq")) {
      cat0("  For differential expression, 6 or more biological replicates detect far more genes than 3 ",
           "(Schurch et al. 2016, doi:10.1261/rna.053959.115); base n on power, not on the median.")
    }
  }
  cat0("\nStarter code:\n", x$recipe)
  cat0("\nPower: give a minimum detectable difference and residual SD (pilot data or literature); ",
       "StudyForge never assumes them. Then run power_rcbd(), power_split_plot() or power_alpha_lattice().")
  if (!is.null(x$disclaimer)) cat0("\n", x$disclaimer)
  invisible(x)
}

#' Launch the StudyForge app (free, runs locally)
#' @param ... Passed to shiny::runApp().
#' @export
launch_studyforge <- function(...) {
  if (!requireNamespace("shiny", quietly = TRUE)) stop("Install shiny: install.packages('shiny')", call. = FALSE)
  app_dir <- system.file("shiny", "studyforge", package = "studyforge")
  if (!nzchar(app_dir)) stop("App not found; reinstall studyforge.", call. = FALSE)
  shiny::runApp(app_dir, ...)
}

# What the user asks about (inst/agent/questions.tsv). Each question sentence (ending in "?") is cut at its question
# frames ("how many", "which", "is/are/should ...") into spans ({N} in a pattern is the count_word cue of rules.tsv); the first target pattern that fits the span's frame
# kind names the field being asked. A field the user asks about is left open (never filled), so it is asked back.
.sf_questions <- local({
  tbl <- NULL
  function() {
    if (is.null(tbl)) {
      f <- system.file("agent", "questions.tsv", package = "studyforge")
      if (!nzchar(f)) f <- file.path("inst", "agent", "questions.tsv")
      tbl <<- utils::read.delim(f, quote = "", comment.char = "", colClasses = "character", na.strings = character())
      tbl$pattern <<- gsub("{N}", .sf_cue("count_word"), tbl$pattern, fixed = TRUE)   # {N}: a number or number word
    }
    tbl
  }
})
.sf_asked_fields <- function(question) {
  q <- .sf_questions(); fr <- q[q$table == "frame", ]; tg <- q[q$table == "target", ]
  t <- tolower(question)
  sents <- regmatches(t, gregexpr("[^.?!]*\\?", t, perl = TRUE))[[1]]
  out <- character()
  for (s in trimws(sents)) {
    starts <- integer(); kinds <- character()
    for (i in seq_len(nrow(fr))) {
      m <- gregexpr(fr$pattern[i], s, perl = TRUE)[[1]]
      if (m[1] > 0) { starts <- c(starts, as.integer(m)); kinds <- c(kinds, rep(fr$kinds[i], length(m))) }
    }
    # a bare question with no frame is read only in the short "<what> per <group>?" form ("Rats per region?",
    # "Birds per pool?"); other frameless sentences ending in "?" are statements
    if (!length(starts)) {
      if (!grepl("^\\s*(?:[a-z0-9:-]+\\s+){1,2}(?:per|in each|for each|each)\\b", s, perl = TRUE)) next
      starts <- 1L; kinds <- "count,choice,yesno"
    }
    o <- order(starts); starts <- starts[o]; kinds <- kinds[o]
    keep <- !duplicated(starts); starts <- starts[keep]; kinds <- kinds[keep]
    ends <- c(starts[-1] - 1L, nchar(s))
    for (j in seq_along(starts)) {
      span <- substr(s, starts[j], ends[j]); k <- strsplit(kinds[j], ",")[[1]]
      ok <- vapply(strsplit(tg$kinds, ","), function(x) any(k %in% x), logical(1))
      pos <- vapply(tg$pattern, function(p) as.integer(regexpr(p, span, perl = TRUE)), integer(1), USE.NAMES = FALSE)
      # pass 1 rows win in table order (which thing is the unit, what goes in a pool, "is N enough");
      # otherwise the target named first in the span wins ("how many replicates of the mutants" asks replicates)
      hit <- which(ok & pos > 0 & tg$pass == "1")[1]
      if (is.na(hit)) { c2 <- which(ok & pos > 0); if (length(c2)) hit <- c2[which.min(pos[c2])] }
      if (!is.na(hit) && nzchar(tg$field[hit])) out <- c(out, tg$field[hit])
    }
  }
  unique(out)
}
# leave the asked fields open; factors.<name>.n_levels drops that factor's level count
.sf_clear_asked <- function(spec, question) {
  for (p in .sf_asked_fields(question)) {
    k <- strsplit(p, ".", fixed = TRUE)[[1]]
    if (k[1] == "factors" && length(k) == 3) {
      for (i in seq_along(spec$factors)) if (identical(spec$factors[[i]]$name, k[2])) spec$factors[[i]][[k[3]]] <- NULL
    } else if (length(k) == 1) spec[[k]] <- NULL
    else if (length(k) == 2 && is.list(spec[[k[1]]])) spec[[k[1]]][[k[2]]] <- NULL
  }
  .sf_mark_solve_for(spec, question)
}

# A replicate count the user asks for ("how many per group?"), or never states, is solved for, not assumed:
# power.solve_for = "reps" (solve_for_reason "asked" or "not_stated") with the range to sweep (rules.tsv
# layout_default power.reps_range), so a simulator runs a power sweep.
.sf_mark_solve_for <- function(spec, question) {
  if (is.null(spec$design$reps)) {
    asked <- "design.reps" %in% .sf_asked_fields(question) || .sf_reps_open(question)
    spec$power$solve_for <- "reps"
    spec$power$solve_for_reason <- if (asked) "asked" else "not_stated"
    rr <- as.integer(strsplit(.sf_layout_default("power.reps_range", spec) %||% "3-12", "-", fixed = TRUE)[[1]])
    spec$power$reps_range <- as.list(rr)
  }
  spec
}

#' Mark what the user's question leaves open
#'
#' Clears the fields the question asks about (questions.tsv) and, when it asks for the replicate count, sets
#' `power.solve_for = "reps"` and `power.reps_range` so a simulator sweeps replicate numbers instead of assuming one.
#' Use it on a spec built elsewhere (e.g. a reviewed spec) together with the user's question.
#' @param spec A StudySpec.
#' @param question The user's question text.
#' @return The spec.
#' @export
mark_asked <- function(spec, question) .sf_clear_asked(spec, question)

# A checklist question is already answered when an answered_by row (rules.tsv) matches its text and every field the
# row names is stated in the spec by the user, not filled in as an assumption. factor:NAME means a factor called NAME
# with levels (for time, the factor itself).
.sf_question_answered <- function(q, spec) {
  r <- .sf_rules_rows("answered_by")
  if (!NROW(r)) return(FALSE)
  hit <- which(vapply(r$pattern, function(p) grepl(p, tolower(q), perl = TRUE), logical(1)))
  stated <- function(path) {
    if (startsWith(path, "factor:")) {
      nm <- sub("^factor:", "", path)
      f <- Filter(function(x) identical(x$name, nm), spec$factors %||% list())
      return(length(f) > 0 && (nm %in% .sf_list("occasion_factor") || !is.null(f[[1]]$n_levels)))
    }
    !is.null(spec_get(spec, path)) && is.null(spec$assumptions[[path]])
  }
  any(vapply(hit, function(i) all(vapply(strsplit(r$term[i], " ")[[1]], stated, logical(1))), logical(1)))
}

# One string from a spec field that may be NULL, NA, a list or several values (a spec from another tool, or several
# organisms): the first non-missing value as character, else "". strsplit()/tolower() on NA would stop with
# "non-character argument".
.sf_str1 <- function(x) {
  x <- unlist(x)
  x <- x[!is.na(x)]
  if (!length(x)) "" else as.character(x[1])
}

# primary_outcome.type: the first rules.tsv outcome_type row matching the outcome name or the question
.sf_outcome_type <- function(text, outcome = NULL) {
  r <- .sf_rules_rows("outcome_type")
  for (i in seq_len(NROW(r)))
    if ((!is.null(outcome) && grepl(r$pattern[i], outcome, perl = TRUE)) || grepl(r$pattern[i], text, perl = TRUE))
      return(r$term[i])
  NULL
}

# finer assay kinds (rules.tsv assay_kind), every match kept
.sf_assay_kinds <- function(text) {
  r <- .sf_rules_rows("assay_kind")
  unique(r$term[vapply(r$pattern, function(p) grepl(p, text, perl = TRUE), logical(1))])
}

# breeding generation notation (rules.tsv generation_notation): the first matching row names its captured numbers
# (bc, f, fl); the filial generation is the later one, self generations are filial - 1
.sf_generation_notation <- function(text) {
  r <- .sf_rules_rows("generation_notation")
  for (i in seq_len(NROW(r))) {
    g <- regmatches(text, regexec(r$pattern[i], text, perl = TRUE))[[1]]
    if (!length(g)) next
    v <- suppressWarnings(as.numeric(g[-1])); v <- v[!is.na(v)]
    nm <- strsplit(r$term[i], ",", fixed = TRUE)[[1]]
    if (length(v) < length(nm)) next
    x <- setNames(as.list(v[seq_along(nm)]), nm)
    out <- list()
    if (!is.null(x$bc)) out$backcross_generations <- x$bc
    f <- x$fl %||% x$f
    if (!is.null(f)) { out$filial_generation <- f; out$self_generations <- f - 1 }
    if (!is.null(x$fl)) out$derived_generation <- x$f
    return(out)
  }
  list()
}

# what a stated mating implies (rules.tsv mating_property: "key=value" rows); repeated keys (candidate) all kept
.sf_mating_props <- function(mating) {
  r <- tryCatch(.sf_rules_rows("mating_property"), error = function(e) NULL)
  if (is.null(r) || !length(mating) || !nzchar(mating[1])) return(list())
  kv <- r$pattern[r$term == mating[1]]
  stats::setNames(as.list(sub("^[^=]*=", "", kv)), sub("=.*", "", kv))
}

.sf_num_or_chr <- function(x) if (grepl("^-?[0-9.]+$", x)) as.numeric(x) else x
