#' System prompt for the StudyForge agent
#' @export
studyforge_system_prompt <- function() {
  paste(
    "You are StudyForge, an experimental design assistant for plant and biological research.",
    "Workflow: identify the system -> define experimental unit and primary outcome ->",
    "ask the consequential missing questions -> propose 2-3 candidate designs ->",
    "run power/sensitivity -> generate the randomized layout and design package.",
    "",
    "Rules:",
    "1. Record each user-stated fact with spec_update (assumption = false).",
    "   Values you propose (effect sizes, SDs, attrition) must be stored with assumption = true and said aloud as assumptions.",
    "2. Call system_questions for the system and ask at most 3 questions per turn, the ones that change the design most.",
    "3. Call unit_audit before any power calculation. If risk is high, say so plainly and explain the correct n.",
    "4. Never invent effect sizes or variances. If unknown, ask for pilot data/literature, or run power_sensitivity over a clearly labelled range.",
    "5. Every number you report must come from a tool result. Quote the settings used.",
    "6. Use lookup_design to explain strengths and tradeoffs; only propose designs in the catalog.",
    "7. Call spec_validate before make_design. Generate the layout only once consequential fields are set or flagged as assumptions.",
    "8. For animal studies, state that this is a planning recommendation and needs statistician, veterinarian and IACUC review.",
    "9. Call setup_hazards for the system and ask about the physical setup (irrigation lines, field edges, doors, pads, sprinklers,",
    "   chamber corners, trays, cages, vials, rearing). Put the relevant hazards and the covariates to record into the plan.",
    "10. Use protocol_notes to ground advice in what published studies actually did, and cite them.",
    sep = "\n"
  )
}

#' Build the conversational StudyForge agent (optional; requires ellmer)
#'
#' Most users do not need this: studyforge_ask() and launch_studyforge() are free
#' and offline. This tool-calling agent defaults to a free local model through
#' Ollama (https://ollama.com; pick a model with tool support, e.g. "qwen2.5" or
#' "llama3.1"). Paid providers are available only if you choose them.
#'
#' @param provider "ollama" (default, free and local), "anthropic" or "openai" (paid API keys).
#' @param model Model id; defaults depend on provider.
#' @param outdir Where layouts and the design package are written.
#' @param chat Optional pre-built ellmer Chat object (any provider).
#' @return An ellmer Chat with StudyForge tools registered. Run it with
#'   ellmer::live_console(chat) or ellmer::live_browser(chat).
#' @export
studyforge_chat <- function(provider = c("ollama", "anthropic", "openai"), model = NULL,
                            outdir = "studyforge_run", chat = NULL) {
  if (!requireNamespace("ellmer", quietly = TRUE)) {
    stop("Install ellmer to use the conversational agent (install.packages('ellmer')), ",
         "or use the free offline studyforge_ask() / launch_studyforge().", call. = FALSE)
  }
  provider <- match.arg(provider)
  state <- new.env()
  state$spec <- new_spec()
  state$audit <- NULL
  state$power <- NULL

  if (is.null(chat)) {
    sp <- studyforge_system_prompt()
    chat <- switch(provider,
      ollama = ellmer::chat_ollama(model = model %||% Sys.getenv("STUDYFORGE_OLLAMA_MODEL", "qwen2.5"),
                                   system_prompt = sp),
      anthropic = ellmer::chat_anthropic(model = model, system_prompt = sp),
      openai = ellmer::chat_openai(model = model, system_prompt = sp))
  }
  for (t in studyforge_tools(state, outdir)) chat$register_tool(t)
  attr(chat, "studyforge_state") <- state
  chat
}

#' StudyForge tool definitions (ellmer ToolDef objects)
#'
#' @param state Environment holding spec/audit/power across tool calls.
#' @param outdir Output directory for design packages.
#' @export
studyforge_tools <- function(state, outdir = "studyforge_run") {
  T <- ellmer::tool
  str <- ellmer::type_string
  int <- ellmer::type_integer
  num <- ellmer::type_number
  json <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE, null = "null")
  # Wrap the body (not the function) so formals survive: ellmer matches
  # argument types against formals(fun). Errors go back to the model as text.
  safely <- function(f) {
    body(f) <- bquote(tryCatch(.(body(f)),
                               error = function(e) paste("ERROR:", conditionMessage(e))))
    f
  }
  split_csv <- function(x) trimws(strsplit(x, ",")[[1]])

  list(
    T(safely(function(path, value, assumption = FALSE) {
        v <- tryCatch(jsonlite::fromJSON(value), error = function(e) value)
        state$spec <- spec_set(state$spec, path, v, assumption = assumption)
        json(state$spec)
      }), name = "spec_update",
      description = "Set one dotted field of the StudySpec (e.g. 'power.residual_sd'). value may be JSON (numbers, arrays).",
      arguments = list(path = str(), value = str(),
                       assumption = ellmer::type_boolean("TRUE if Claude proposed the value", required = FALSE))),

    T(safely(function() json(c(validate_spec(state$spec), list(spec = state$spec)))),
      name = "spec_validate",
      description = "Validate the StudySpec; returns missing consequential fields and status."),

    T(safely(function(system) json(system_questions(system))), name = "system_questions",
      description = "Consequential questions to ask for an experimental system.",
      arguments = list(system = ellmer::type_enum(
        values = c("field", "greenhouse", "growth_chamber", "mouse", "drosophila", "bulk_rnaseq",
                   "metabolomics_lipidomics", "single_cell", "breeding_genetics", "multi_environment",
                   "multi_omics", "ribo_seq", "atac_seq", "functional_validation")))),

    T(safely(function(system) json(setup_hazards(system))), name = "setup_hazards",
      description = "Setup problems for a system (borders, irrigation lines, doors, chamber corners, cages, fly density...) with mitigations and covariates to record.",
      arguments = list(system = ellmer::type_enum(
        values = c("field", "greenhouse", "growth_chamber", "mouse", "drosophila", "breeding_genetics",
                   "multi_environment", "multi_omics", "ribo_seq", "atac_seq", "functional_validation")))),

    T(safely(function(query = "", system = NULL) json(protocol_notes(query, system))),
      name = "protocol_notes",
      description = "Search notes from published methods (what they did, numbers, lessons). Query words are ANDed.",
      arguments = list(query = str("e.g. 'spatial sorghum', 'cage', 'larval density'", required = FALSE),
                       system = str(required = FALSE))),

    T(safely(function(entries, checks, tray_rows, tray_cols, check_copies = 1L, guard_edges = TRUE) {
        book <- make_tray_design(split_csv(entries), split_csv(checks), tray_rows, tray_cols,
                                 check_copies = check_copies, guard_edges = guard_edges)
        files <- write_design_package(book, state$spec, outdir, state$audit, state$power)
        paste0("Trays: ", max(book$tray), ". Wrote: ", paste(files, collapse = ", "), "\n",
               paste(utils::capture.output(print(table(book$tray, book$role))), collapse = "\n"))
      }), name = "make_tray_design",
      description = "Augmented-by-tray layout: every tray gets the checks, entries spread across trays, optional guard edge cells.",
      arguments = list(entries = str("Comma-separated entries"), checks = str("Comma-separated checks"),
                       tray_rows = int(), tray_cols = int(),
                       check_copies = int(required = FALSE),
                       guard_edges = ellmer::type_boolean(required = FALSE))),

    T(safely(function(groups, n_per_group, per_cage, delivery, sexes = "F,M") {
        d <- make_cage_allocation(split_csv(groups), n_per_group, per_cage, delivery, split_csv(sexes))
        files <- write_design_package(d, state$spec, outdir, state$audit, state$power)
        sprintf("Unit: %s; experimental units per group per sex: %s; cages: %d. Wrote: %s",
                attr(d, "unit"), attr(d, "true_n"), length(unique(d$cage)), paste(files, collapse = ", "))
      }), name = "make_cage_allocation",
      description = "Allocate mice to cages: individual dosing mixes groups within cages (cage = block); cage delivery assigns whole cages (cage = unit).",
      arguments = list(groups = str(), n_per_group = int("Animals per group per sex"), per_cage = int(),
                       delivery = ellmer::type_enum(values = c("individual", "cage")),
                       sexes = str("Comma-separated, default F,M", required = FALSE))),

    T(safely(function(treatments, vials_per_treatment, flies_per_vial = 10L) {
        d <- make_vial_allocation(split_csv(treatments), vials_per_treatment, flies_per_vial)
        files <- write_design_package(d, state$spec, outdir, state$audit, state$power)
        sprintf("%d vials; %d flies per treatment. Wrote: %s", nrow(d),
                attr(d, "flies_per_treatment"), paste(files, collapse = ", "))
      }), name = "make_vial_allocation",
      description = "Drosophila vial layout: each rearing bottle supplies one vial to every treatment; random tray positions.",
      arguments = list(treatments = str(), vials_per_treatment = int(),
                       flies_per_vial = int(required = FALSE))),

    T(safely(function(k, attrition = 0) json(resource_equation_n(k, attrition))),
      name = "resource_equation_n",
      description = "Animals per group by the resource equation when no SD is available (planning fallback, not a power analysis).",
      arguments = list(k = int("Number of groups"), attrition = num(required = FALSE))),

    T(safely(function(system) json(lapply(designs_for_system(system), lookup_design))),
      name = "designs_for_system",
      description = "Catalog designs suitable for a system, with strengths, tradeoffs and models.",
      arguments = list(system = str())),

    T(safely(function(id) json(lookup_design(id))), name = "lookup_design",
      description = "Look up one design (crd, rcbd, alpha, split, factorial, augmented, prep, repeated_measures).",
      arguments = list(id = str())),

    T(safely(function(biological_unit, experimental_unit, measurement_unit,
                      subsamples_per_unit = 1, units_per_group = NA) {
        state$audit <- unit_audit(biological_unit, experimental_unit, measurement_unit,
                                  subsamples_per_unit, units_per_group)
        json(state$audit)
      }), name = "unit_audit",
      description = "Check experimental vs measurement unit for pseudoreplication. Call before power.",
      arguments = list(biological_unit = str(), experimental_unit = str(), measurement_unit = str(),
                       subsamples_per_unit = int(required = FALSE),
                       units_per_group = int(required = FALSE))),

    T(safely(function(n_trt, n_blocks, delta, sd, block_sd = 0) {
        state$power <- power_rcbd(n_trt, n_blocks, delta, sd, block_sd, nsim = 1000)
        json(state$power)
      }), name = "power_rcbd",
      description = "Simulated power, one-way treatment test in an RCBD.",
      arguments = list(n_trt = int(), n_blocks = int(), delta = num(), sd = num(),
                       block_sd = num(required = FALSE))),

    T(safely(function(n_main, n_sub, n_blocks, delta, effect, sd_whole, sd_sub) {
        state$power <- power_split_plot(n_main, n_sub, n_blocks, delta, effect,
                                        sd_whole, sd_sub, nsim = 500)
        json(state$power)
      }), name = "power_split_plot",
      description = "Simulated power in a split-plot (main = whole-plot factor such as irrigation).",
      arguments = list(n_main = int(), n_sub = int(), n_blocks = int(), delta = num(),
                       effect = ellmer::type_enum(values = c("main", "sub", "interaction")),
                       sd_whole = num("Whole-plot error SD"), sd_sub = num("Residual SD"))),

    T(safely(function(n_trt, block_size, reps, delta, sd, block_sd) {
        state$power <- power_alpha_lattice(n_trt, block_size, reps, delta, sd, block_sd, nsim = 200)
        json(state$power)
      }), name = "power_alpha_lattice",
      description = "Simulated power for a pairwise entry difference in an alpha-lattice (mixed model), with RCBD comparison.",
      arguments = list(n_trt = int(), block_size = int(), reps = int(), delta = num(),
                       sd = num(), block_sd = num("Incomplete-block SD"))),

    T(safely(function(design, treatments, reps, block_size = NULL, treatments2 = NULL, checks = NULL) {
        book <- make_design(design, split_csv(treatments), reps,
                            block_size = block_size,
                            treatments2 = if (!is.null(treatments2)) split_csv(treatments2),
                            checks = if (!is.null(checks)) split_csv(checks))
        files <- write_design_package(book, state$spec, outdir, state$audit, state$power)
        paste0("Wrote: ", paste(files, collapse = ", "), "\nFirst rows:\n",
               paste(utils::capture.output(print(utils::head(book, 8))), collapse = "\n"))
      }), name = "make_design",
      description = "Generate a randomized layout and write the design package.",
      arguments = list(
        design = ellmer::type_enum(values = c("crd", "rcbd", "alpha", "split", "augmented")),
        treatments = str("Comma-separated treatments (whole-plot levels for split; new entries for augmented)"),
        reps = int(),
        block_size = int("alpha only", required = FALSE),
        treatments2 = str("split only: comma-separated subplot levels", required = FALSE),
        checks = str("augmented only: comma-separated checks", required = FALSE)))
  )
}
