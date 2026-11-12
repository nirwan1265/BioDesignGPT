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
  suppressWarnings(as.numeric(x))
}

.sf_num_re <- "(\\d[\\d,]*|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty)"

# first number found immediately before any of the given nouns
.sf_count_before <- function(text, nouns, prefix = "(?:about |around |roughly |~)?") {
  # up to two modifier words between the number and the noun, but never another
  # counted noun or a preposition ("three sites this season" is not 3 seasons)
  stop <- "(?!(?:sites?|locations?|reps?|replicates?|plots?|per|at|in|on|for|this|each|from|and|with|of|blocks?|trays?|cages?|vials?|pots?|benches)\\b)"
  re <- paste0(prefix, .sf_num_re, "\\s+(?:", stop, "[a-z-]+\\s+){0,2}?(?:", paste(nouns, collapse = "|"), ")\\b")
  m <- regmatches(text, regexpr(re, text, perl = TRUE))
  if (!length(m) || grepl("\\bor\\b", m)) return(NA_real_)  # "two or three reps" is undecided
  .sf_num(regmatches(m, regexpr(.sf_num_re, m, perl = TRUE)))
}

.sf_has <- function(text, pattern) grepl(pattern, text, perl = TRUE)

.sf_organisms <- list(
  "Sorghum bicolor" = "sorghum", "Zea mays" = "\\bmaize\\b|\\bcorn\\b", "Triticum aestivum" = "\\bwheat\\b",
  "Hordeum vulgare" = "\\bbarley\\b", "Glycine max" = "soybean", "Oryza sativa" = "\\brice\\b",
  "Arabidopsis thaliana" = "arabidopsis", "Solanum lycopersicum" = "tomato",
  "Brassica napus" = "oilseed rape|canola", "Mus musculus" = "\\bmice\\b|\\bmouse\\b|c57bl|balb",
  "Drosophila melanogaster" = "drosophila|\\bfl(?:y|ies)\\b|dahomey|canton-s|oregon-r|gal4|\\bvials?\\b",
  "Saccharomyces cerevisiae" = "yeast(?! concentration)"
)

.sf_systems <- list(
  functional_validation = "validat\\w* (?:them|candidates?|genes?|in vivo)|in silico and in vivo|crispr knockouts? in|complementation in|heterologous expression|confirm them",
  ribo_seq = "ribo-?seq|ribosome profiling|translation efficiency|translatome",
  atac_seq = "atac-?seq|chromatin accessibility|accessible chromatin",
  multi_omics = "gwas.*(?:rna-?seq|transcriptom|eqtl)|(?:rna-?seq|transcriptom).*gwas|eqtl|twas|coloc",
  breeding_genetics = "diallel|nc ?ii|north carolina design|\\brils?\\b|recombinant inbred|\\bnam\\b|nested association|doubled haploid|backcross|brother-sister|sib[- ]mating|single seed descent|\\bself(?:ed|ing)?\\b.*\\bf\\d|\\bf\\d\\b.*heterozyg|introgress|inbred yet|call it inbred|treat it as inbred",
  multi_environment = "(?:greenhouse|growth chamber|glasshouse).*(?:field)|yield stability|genotype by environment|\\bgxe\\b|\\bmet\\b",
  single_cell = "single[- ]?cell|scrna|\\bcells each\\b",
  bulk_rnaseq = "rna-?seq|transcriptom",
  metabolomics_lipidomics = "lipidomic|metabolomic|lc-?ms|gc-?ms",
  drosophila = "drosophila|\\bfl(?:y|ies)\\b|\\bvials?\\b|dahomey|canton-s|gal4|wing size",
  mouse = "\\bmice\\b|\\bmouse\\b|\\bcages?\\b|\\blitters?\\b|\\bdams?\\b|\\bpups?\\b|\\brats?\\b",
  cell_culture = "hela|cell line|\\bwells?\\b(?!-)|dmso|\\bneurons\\b",
  growth_chamber = "growth chambers?|\\bchambers?\\b|\\btrays?\\b|growth room",
  greenhouse = "greenhouse|glasshouse|\\bbench(?:es)?\\b|\\bpots?\\b|smarthouse|imaging platform|conveyor",
  field = "\\bfield\\b|\\bplots?\\b|\\bsites?\\b|locations?|environments|nursery|progeny rows|irrigation|sprinkler|drip|hybrids|varieties|cultivars"
)

.sf_outcomes <- list(
  grain_yield = "grain yield|\\byield\\b(?! trial)", flowering_time = "flowering time|days to flowering",
  plant_height = "plant height", forage_yield = "forage yield", biomass = "biomass",
  lifespan = "lifespan|life span|longevity|lives? \\S+ longer", wing_size = "wing size", body_weight = "body weight",
  leptin = "leptin", microbiome = "microbiome(?! study)",
  fasting_blood_glucose = "blood glucose|glucose", firing_rate = "firing rate", viability = "viability",
  lipid_content = "lipid content", mechanical_threshold = "von frey|pain threshold", leaf_growth = "leaf growth"
)

.sf_genotype_nouns <- c("lines?", "accessions?", "genotypes?", "hybrids?", "test-cross hybrids", "varieties",
                        "cultivars?", "famil(?:y|ies)", "entries", "landraces", "strains?", "mutants?")

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
  text <- tolower(question)
  spec <- new_spec()
  set <- function(path, value) if (!is.null(value) && !all(is.na(value))) spec <<- spec_set(spec, path, value)

  # system: most specific first
  sys <- names(.sf_systems)[vapply(.sf_systems, function(p) .sf_has(text, p), logical(1))]
  if (length(sys)) set("system", sys[1]) else if (.sf_has(text, "vehicle|strains?|\\bmales?\\b|\\bfemales?\\b")) set("system", "mouse")
  org <- names(.sf_organisms)[vapply(.sf_organisms, function(p) .sf_has(text, p), logical(1))]
  if (length(org)) set("organism", org[1])

  out <- names(.sf_outcomes)[vapply(.sf_outcomes, function(p) .sf_has(text, p), logical(1))]
  if (length(out) == 1) {
    set("primary_outcome.name", out)
    set("primary_outcome.type", if (out == "lifespan") "survival" else "continuous")
  }

  # factors
  factors <- list()
  add_factor <- function(name, n = NA, applied_to = NULL) {
    f <- list(name = name)
    if (!is.na(n)) f$n_levels <- n
    if (!is.null(applied_to)) f$applied_to <- applied_to
    factors[[length(factors) + 1]] <<- f
  }
  n_geno <- .sf_count_before(text, .sf_genotype_nouns)
  if (!is.na(n_geno)) add_factor("genotype", n_geno)
  n_chk <- .sf_count_before(text, c("checks?", "check varieties", "commercial checks"))
  if (!is.na(n_chk)) add_factor("check", n_chk)
  whole_plot_water <- .sf_has(text, "linear-move|pivot|can't randomi|cannot randomi|drip|laterals?|sprinkler line|whole plots?")
  if (.sf_has(text, "irrigation|drought|water(?:ed|ing)? (?:levels?|regimes?|treatments?)|well-watered|water-stressed|water stress")) {
    n <- .sf_count_before(text, c("irrigation levels?", "water levels?", "water regimes?", "watering levels?", "water treatments?"))
    if (is.na(n) && .sf_has(text, "vs\\.? |versus|drought plots|control and drought|well-watered")) n <- 2
    line_src <- .sf_has(text, "sprinkler line|line-source|line source")
    add_factor("water", n, if (line_src) "distance_from_line" else if (whole_plot_water && spec$system %in% "field") "main_plot")
  }
  if (.sf_has(text, "nitrogen")) add_factor("nitrogen", .sf_count_before(text, c("nitrogen levels?", "n levels?")) %|na|% 2)
  if (.sf_has(text, "\\d+ ?c (?:vs|versus)|temperature|heat stress")) add_factor("temperature", 2, if (.sf_has(text, "chamber")) "chamber")
  if (.sf_has(text, "co2")) add_factor("co2", 2, if (.sf_has(text, "chamber")) "chamber")
  if (.sf_has(text, "nutrient solutions?|nutrient treatments?")) {
    add_factor("nutrient", .sf_count_before(text, c("nutrient solutions?", "nutrient treatments?")))
  }
  if (.sf_has(text, "antibiotic")) add_factor("antibiotic", 2, if (.sf_has(text, "drinking water|diet")) "cage")
  if (.sf_has(text, "high-fat|low-fat|maternal .*diet|diet")) {
    n <- .sf_count_before(text, c("yeast concentrations?", "diets?"))
    add_factor("diet", n %|na|% 2, if (.sf_has(text, "pregnan|maternal|dams")) "dam" else if (spec$system %in% "drosophila") "vial")
  }
  if (.sf_has(text, "\\bdoses?\\b")) add_factor("dose", .sf_count_before(text, c("groups?")) %|na|% NA)
  if (.sf_has(text, "male and female|both sexes|males? .* females?")) add_factor("sex", 2)
  if (.sf_has(text, "injur(?:ed|y) (?:and|vs\\.?|versus) (?:un-?injured|sham)|injured and uninjured")) add_factor("injury", 2)
  n_trt_groups <- .sf_count_before(text, c("treatment groups?"))
  if (!is.na(n_trt_groups)) {
    add_factor("treatment", n_trt_groups)
  } else if (.sf_has(text, "\\bdrug\\b|compound|treatment (?:vs|versus|with a) control|vs\\.? vehicle|versus vehicle|vs\\.? saline|versus saline")) {
    if (!any(vapply(factors, `[[`, "", "name") %in% c("dose", "antibiotic", "injury"))) {
      add_factor("treatment", 2, if (.sf_has(text, "dosed individually|individually dosed|injection|gavage")) "mouse")
    }
  }
  # genotype contrasts stated without a count
  if (!any(vapply(factors, `[[`, "", "name") == "genotype")) {
    m <- regmatches(text, regexpr(paste0(.sf_num_re, "\\s+(?:mutants?|lines|genotypes)\\s+(?:vs\\.?|versus|and)\\s+(?:a|the|one)\\s+(?:control|wild[- ]type)"), text, perl = TRUE))
    if (length(m)) {
      add_factor("genotype", .sf_num(regmatches(m, regexpr(.sf_num_re, m, perl = TRUE))) + 1)
    } else if (.sf_has(text, "knockout|mutant (?:line )?(?:lives|vs|versus|and)|than canton|than wild|(?:compare|vs\\.?|versus) (?:to )?wild[- ]type|overexpress")) {
      add_factor("genotype", 2)
    }
  }
  if (length(factors)) set("factors", factors)

  # replication and environments
  reps_nouns <- c("reps?", "replicates?", "replications?", "blocks", "dams per", if (.sf_has(text, "greenhouse")) "benches")
  set("design.reps", .sf_count_before(text, reps_nouns))
  tc <- regmatches(text, regexpr(paste0(.sf_num_re, "\\s+treated and\\s+", .sf_num_re, "\\s+control"), text, perl = TRUE))
  if (length(tc)) set("design.reps", .sf_num(regmatches(tc, regexpr(.sf_num_re, tc, perl = TRUE))))
  set("design.locations", .sf_count_before(text, c("locations?", "sites?", "environments?")))
  set("design.seasons", .sf_count_before(text, c("seasons?", "years?")))
  if (.sf_has(text, "this season|one season|single season")) set("design.seasons", 1)
  if (.sf_has(text, "one plot each|one plot per|no replication|unreplicated|can't replicate|cannot replicate")) set("design.reps", 1)

  # units: "<n> <meas> per <exp>"; take the first match that names real units
  per_re <- paste0(.sf_num_re, "\\s+(?:tagged |bagged |spaced )?([a-z]+)\\s+(?:per|each|in each|from each)\\s+([a-z]+)")
  pers <- regmatches(text, gregexpr(per_re, text, perl = TRUE))[[1]]
  for (per in pers) {
    parts <- regmatches(per, regexec(per_re, per, perl = TRUE))[[1]]
    meas <- sub("(ies)$", "y", sub("(?<!s)s$", "", sub("aves$", "af", parts[3]), perl = TRUE))
    meas <- c(panicle = "plant", pup = "pup", cell = "cell", leaf = "leaf", plant = "plant", mouse = "mouse",
              mice = "mouse", well = "well", neuron = "cell", fly = "fly")[meas] %|na|% meas
    exp <- sub("s$", "", parts[4])
    n_sub <- .sf_num(parts[2])
    if (exp %in% c("combination", "batch", "day", "week", "run", "group", "condition", "treatment", "time",
                   "site", "year", "season", "location", "genotype", "line", "entry")) next
    if (meas %in% c("female", "male", "parent", "injection", "egg", "replicate", "sample") || meas == exp) next
    if (identical(n_sub, 1)) next   # "one plant per pot" just defines the pot
    set("measurement_unit", unname(meas))
    set("subsamples_per_unit", n_sub)
    set("experimental_unit", exp)
    break
  }
  if (.sf_has(text, "one plant per pot")) set("experimental_unit", "pot")
  if (.sf_has(text, "per cage|mice per cage|housed \\d+ per cage")) {
    if (.sf_has(text, "drinking water|in the diet|chow")) {
      set("experimental_unit", "cage"); set("measurement_unit", "mouse")
      set("subsamples_per_unit", .sf_count_before(text, c("per cage"), prefix = "(?:housed )?"))
    }
  }
  cells <- regmatches(text, regexpr(paste0(.sf_num_re, "\\s+(?:neurons|cells)\\s+(?:from|per|each|of)\\s+(?:one\\s+)?(?:[a-z-]+\\s+)?(?:mouse|animal|donor|sample)|(?:about |~)?", .sf_num_re, "\\s+cells each"), text, perl = TRUE))
  if (length(cells)) {
    set("measurement_unit", "cell")
    set("experimental_unit", if (.sf_has(text, "donor")) "donor" else "mouse")
    set("subsamples_per_unit", .sf_num(regmatches(cells, regexpr(.sf_num_re, cells, perl = TRUE))))
    if (.sf_has(text, "from one ")) set("design.reps", 1)
    r <- regmatches(text, regexpr(paste0("(?:from )?", .sf_num_re, "\\s+[a-z-]+\\s+and\\s+\\d+\\s+[a-z-]+\\s+mice"), text, perl = TRUE))
    if (length(r)) set("design.reps", .sf_num(regmatches(r, regexpr(.sf_num_re, r, perl = TRUE))))
  }
  if (.sf_has(text, "dosed individually|individually dosed|each mouse dosed")) {
    set("experimental_unit", "mouse"); set("measurement_unit", "mouse")
    if (.sf_has(text, "within cages")) set("blocking_factors", "cage")
  }
  if (.sf_has(text, "given to pregnant|pregnant dams|maternal treatment") &&
      !any(vapply(factors, `[[`, "", "name") %in% c("diet", "treatment"))) {
    factors[[length(factors) + 1]] <- list(name = "treatment", n_levels = 2, applied_to = "dam")
    spec$factors <- factors
  }
  if (.sf_has(text, "pregnan|maternal|dams")) {
    set("experimental_unit", "litter")
    if (.sf_has(text, "pups?")) set("measurement_unit", "pup")
  }
  if (.sf_has(text, "one (?:set|chamber) (?:to|per) each|chambers?, one|one chamber per|identical chambers")) set("experimental_unit", "chamber")
  if (is.null(spec$experimental_unit)) {
    if (identical(spec$system, "field")) set("experimental_unit", if (.sf_has(text, "single-plant|spaced plants")) "plant" else "plot")
    if (identical(spec$system, "greenhouse") && .sf_has(text, "\\bpots?\\b|carts?|imaging platform")) set("experimental_unit", "pot")
    if (identical(spec$system, "growth_chamber") && .sf_has(text, "\\bpots\\b")) set("experimental_unit", "pot")
    if (spec$system %in% c("growth_chamber", "greenhouse") && .sf_has(text, "-cell trays?|cell trays?|\\btrays?\\b")) set("experimental_unit", "cell")
    if (identical(spec$system, "drosophila") && .sf_has(text, "lifespan|diet|yeast|wing")) {
      set("experimental_unit", "vial"); set("measurement_unit", "fly")
    }
  }
  if (.sf_has(text, "\\bbench(?:es)?\\b")) set("blocking_factors", "bench")
  if (.sf_has(text, "shelves")) set("blocking_factors", "shelf")
  if (.sf_has(text, "technicians?|experimenters?")) set("blocking_factors", "experimenter")
  if (.sf_has(text, "\\bbatch(?:es)?\\b")) set("blocking_factors", if (.sf_has(text, "librar")) "library_batch" else "injection_batch")
  if (identical(spec$system, "drosophila") && is.null(spec$organism)) set("organism", "Drosophila melanogaster")

  # round 3: populations, assays, extra organisms, environments (alias table, longest match first)
  find_all <- function(cat) .sf_find_all(text, cat)
  sys_now <- spec$system %||% ""
  orgs <- find_all("organism")
  if (length(orgs) > 1 && identical(spec$system, "functional_validation")) set("organisms", orgs)
  if (length(orgs) && identical(spec$system, "functional_validation")) set("organism", orgs[1])
  if (sys_now %in% c("multi_omics", "ribo_seq", "atac_seq", "functional_validation", "bulk_rnaseq", "breeding_genetics")) {
    as <- find_all("assay")
    as <- setdiff(as, if (!sys_now %in% c("multi_omics", "functional_validation", "ribo_seq", "atac_seq")) c("rnaseq", "gwas"))
    if (length(as)) set("assays", as)
  }
  if (identical(spec$system, "breeding_genetics")) {
    mt <- find_all("mating")
    if (length(mt)) {
      set("population.mating", mt[1])
      if (mt[1] %in% c("ril", "nam", "dh")) set("population.type", mt[1])
      if (mt[1] %in% c("ril", "dh", "biparental")) set("population.parents", 2)
    }
    g <- regmatches(text, regexpr(paste0("(?:for|after)\\s+", .sf_num_re, "\\s+generations"), text, perl = TRUE))
    if (length(g)) set("population.generations", .sf_num(regmatches(g, regexpr(.sf_num_re, g, perl = TRUE))))
    fg <- regmatches(text, regexpr("(?:to|until|the|at|in) (?:the )?f(\\d+)\\b", text, perl = TRUE))
    if (length(fg)) set("population.filial_generation", as.numeric(sub(".*f", "", fg)))
    mf <- regmatches(text, regexec(paste0(.sf_num_re, "\\s+males and\\s+", .sf_num_re, "\\s+females"), text, perl = TRUE))[[1]]
    if (length(mf)) set("population.parents", .sf_num(mf[2]) + .sf_num(mf[3]))
    fo <- regmatches(text, regexec(paste0(.sf_num_re, "\\s+founders"), text, perl = TRUE))[[1]]
    if (length(fo)) set("population.parents", .sf_num(fo[2]) + 1)
    am <- regmatches(text, regexec(paste0("among\\s+", .sf_num_re, "\\s+"), text, perl = TRUE))[[1]]
    if (length(am)) set("population.parents", .sf_num(am[2]))
    if (.sf_has(text, "gca|sca|combining ability|heterosis")) {
      set("primary_outcome.name", "gca_sca"); set("primary_outcome.type", "continuous")
    }
  }
  if (identical(spec$system, "multi_environment") && .sf_has(text, "greenhouse|growth chamber|glasshouse|controlled environment") && .sf_has(text, "field")) {
    set("environments", c("greenhouse", "field"))
  }
  if (identical(spec$system, "ribo_seq") && .sf_has(text, "translation(?:al)? efficiency")) {
    set("primary_outcome.name", "translation_efficiency"); set("primary_outcome.type", "continuous")
  }
  if (sys_now %in% c("multi_environment") && is.null(spec$primary_outcome) && .sf_has(text, "yield stability")) {
    set("primary_outcome.name", "grain_yield"); set("primary_outcome.type", "continuous")
  }

  spec <- .sf_general_layer(spec, text)
  spec$question <- question
  spec
}

`%|na|%` <- function(a, b) if (length(a) == 0 || is.na(a)) b else a

# Choose candidate designs with simple, transparent rules
.sf_candidates <- function(spec) {
  sys <- spec$system %||% ""
  f <- spec$factors %||% list()
  fname <- vapply(f, `[[`, "", "name")
  n_geno <- suppressWarnings(max(c(0, unlist(lapply(f, function(x) if (x$name == "genotype") x$n_levels)))))
  applied <- unlist(lapply(f, `[[`, "applied_to"))
  reps <- spec$design$reps %||% NA
  cand <- character()
  if (sys == "field") {
    q <- tolower(spec$question %||% "")
    if (any(applied %in% "distance_from_line")) cand <- c(cand, "line_source")
    if (any(applied %in% "main_plot") || .sf_has(q, "tall .*short|short .*tall|mix of tall")) cand <- c(cand, "split")
    if (.sf_has(q, "early-generation|\\d\\.\\d plots? per")) cand <- c(cand, "prep", "augmented")
    if (!is.na(reps) && reps == 1) cand <- c(cand, if (n_geno >= 500) "diagonal_checks", "augmented", "prep")
    if (n_geno > 25 && (is.na(reps) || reps > 1)) cand <- c(cand, "alpha", "row_column")
    if (n_geno > 0 && n_geno <= 25) cand <- c(cand, "rcbd")
    cand <- c(cand, "spatial_analysis")
  } else if (sys == "greenhouse") {
    q <- tolower(spec$question %||% "")
    cand <- c(cand, if (length(f) > 1) "factorial", if (.sf_has(q, "every day|daily|over time|track growth|time course")) "repeated_measures",
              if (length(f) > 1 && .sf_has(q, "bench")) "split", if (n_geno > 20) "alpha", "rcbd", "row_column")
  } else if (sys == "growth_chamber") {
    if (any(applied %in% "chamber") || identical(spec$experimental_unit, "chamber")) cand <- c(cand, "chamber_runs")
    if (.sf_has(tolower(spec$question %||% ""), "tray")) cand <- c(cand, "augmented_tray", "prep")
    cand <- c(cand, "rcbd")
  } else if (sys == "mouse") {
    cand <- c(cand, if (length(f) > 1) "factorial", "rcbd", "crd")
  } else if (sys == "breeding_genetics") {
    mt <- spec$population$mating %||% ""
    q <- tolower(spec$question %||% "")
    cand <- c(cand, if (mt == "diallel") "diallel", if (mt == "nc_design") "nc_design",
              if (mt %in% c("nam", "ril", "dh", "biparental", "selfing", "sib_mating", "backcross") || .sf_has(q, "qtl|mapping|inbred")) "mapping_population",
              if (!is.null(spec$design$locations)) "met_fa", "alpha")
  } else if (sys == "multi_environment") {
    cand <- c(cand, if (length(spec$environments) > 1 || .sf_has(tolower(spec$question %||% ""), "greenhouse|chamber")) "gh_field_validation", "met_fa", "alpha", "spatial_analysis")
  } else if (sys == "multi_omics") {
    cand <- c(cand, "gwas_eqtl", if ("atac_seq" %in% spec$assays) "atac_replicated", if ("ribo_seq" %in% spec$assays) "riboseq_rnaseq", "alpha")
  } else if (sys == "ribo_seq") {
    cand <- c(cand, "riboseq_rnaseq", "rcbd")
  } else if (sys == "atac_seq") {
    cand <- c(cand, "atac_replicated", "rcbd")
  } else if (sys == "functional_validation") {
    cand <- c(cand, "cross_species_validation", "rcbd")
  } else if (sys == "drosophila") {
    cand <- c(cand, if (identical(spec$primary_outcome$name, "lifespan") || .sf_has(tolower(spec$question %||% ""), "lifespan|diet|yeast")) "vial_lifespan", "rcbd")
  } else {
    cand <- c(cand, "rcbd", "crd")
  }
  unique(cand)
}

.sf_recipe <- function(spec, candidates) {
  f <- spec$factors %||% list()
  geno <- Filter(function(x) x$name == "genotype", f)
  n <- if (length(geno)) geno[[1]]$n_levels else 12
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
#'   STUDYFORGE_PYTHON), or "auto" (hybrid when STUDYFORGE_PYTHON is set, else rules).
#' @param model Ollama model name.
#' @param ollama_endpoint Ollama generate endpoint.
#' @param fix Named list of corrections applied to the extracted spec (see studyforge_fix()).
#' @return An object of class `studyforge_answer`.
#' @export
studyforge_ask <- function(question, provider = c("local", "ollama"), engine = c("rules", "hybrid", "auto"),
                           model = Sys.getenv("STUDYFORGE_OLLAMA_MODEL", "llama3.2"),
                           ollama_endpoint = Sys.getenv("STUDYFORGE_OLLAMA_ENDPOINT",
                                                        "http://localhost:11434/api/generate"),
                           fix = NULL) {
  provider <- match.arg(provider)
  engine <- match.arg(engine)
  if (engine == "auto") engine <- if (nzchar(Sys.getenv("STUDYFORGE_PYTHON"))) "hybrid" else "rules"
  spec <- if (engine == "hybrid") extract_spec_hybrid(question) else extract_spec_local(question)
  spec <- .sf_apply_fix(spec, fix)
  v <- validate_spec(spec)
  system <- spec$system %||% NA_character_

  audit <- if (!is.null(spec$experimental_unit) && !is.null(spec$measurement_unit)) {
    unit_audit(spec$organism %||% "organism", spec$experimental_unit, spec$measurement_unit,
               subsamples_per_unit = spec$subsamples_per_unit %||% 1)
  }
  candidates <- .sf_candidates(spec)
  designs <- lapply(candidates, lookup_design)
  hazards <- if (!is.na(system)) setup_hazards(system) else list()
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
  questions <- if (!is.na(system) && system %in% vapply(load_registry("experimental_systems")$systems, `[[`, "", "id")) system_questions(system) else character()
  notes <- protocol_notes(system = system)
  org_word <- tolower(strsplit(spec$organism %||% "", " ")[[1]][1])
  if (!is.na(org_word) && nzchar(org_word)) {
    hits <- Filter(function(n) grepl(org_word, tolower(paste(n$citation, paste(unlist(n$tags), collapse = " "), n$lesson))), notes)
    if (length(hits)) notes <- c(hits, Filter(function(n) !n$id %in% vapply(hits, `[[`, "", "id"), notes))
  }

  ans <- structure(list(
    question = question, provider = provider, engine = engine, fixes = fix, spec = spec, validation = v, audit = audit,
    candidates = candidates, designs = designs, hazards = hazards,
    questions = utils::head(questions, 3), all_questions = questions,
    notes = utils::head(notes, 3), recipe = .sf_recipe(spec, candidates),
    practice = tryCatch(.sf_practice_for_spec(spec, question), error = function(e) NULL),
    traits = tryCatch({
      omics <- length(spec$assays) || isTRUE(spec$system %in% c("bulk_rnaseq", "single_cell", "ribo_seq", "atac_seq", "multi_omics"))
      if (grepl(.SF_ASKS_TRAITS, tolower(question), perl = TRUE) || (is.null(spec$primary_outcome$name) && !omics && !identical(spec$goal, "analysis")))
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
  cat0("StudyForge (", x$provider, if (identical(x$engine, "hybrid")) " + trained tagger", ", free)\n")
  cat0("Here's what I understood (fix anything wrong: studyforge_fix(answer, organism = \"...\", factors = \"name:levels\")):")
  for (l in .sf_skeleton_lines(s, x$fixes %||% list())) cat0(l)
  if (identical(s$goal, "analysis")) {
    cat0("\nThis reads as analysis of data you already have. Analysis (Bioana) is coming; below is the design",
         " this data implies, which fixes the model it should be analysed with.")
  }
  cat0("")
  cat0("System: ", s$system %||% "unknown", if (!is.null(s$organism)) paste0(" | Organism: ", s$organism))
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
  if (length(x$validation$missing)) cat0("\nStill needed: ", paste(x$validation$missing, collapse = ", "))
  if (length(x$questions)) {
    cat0("\nQuestions that change the design:")
    for (q in x$questions) cat0("  - ", q)
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
