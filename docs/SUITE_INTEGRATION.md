# Linking Biodes to Simitall and Bioana

This is the hand-off contract for the suite. Biodes (this repo) is developed in its own chat/window; Simitall and
Bioana are built in another. Each head only needs this file and the files Biodes writes, not Biodes' internals.

## The one rule

**The StudySpec is the contract.** Biodes writes it; Simitall and Bioana read it and never re-ask what it already
answers. The schema lives in this repo at `inst/registry/study_spec.schema.json` (version `0.6.1`), and every
hand-off spec carries `handoff_version`. A head that needs a new field asks for it here (in Biodes), never adds its
own private copy of the design.

## What Biodes hands over

`write_design_package(book, spec, outdir)` writes one folder per study:

| File | What it is | Read by |
|---|---|---|
| `study_spec.json` | The StudySpec: system, organism, factors and levels, experimental unit, subsamples per unit, blocking factors, reps, design.chosen, randomization_seed, power settings, `analysis.model`, `analysis.terms`, `analysis.note`, `handoff_version` | Simitall, Bioana, Biopaint |
| `field_layout.csv` | One row per experimental unit: plot/pot/cage id, block, treatment (and row/col for spatial designs) | Simitall, Biopaint |
| `sample_metadata_template.tsv` | The layout plus `sample_id` (e.g. `SF_rcbd_0001`), `date_measured`, `primary_outcome`, `notes` left empty | Simitall fills it; Bioana reads it |
| `unit_audit.json` (optional) | Pseudoreplication audit: what the true unit is and why | Bioana |
| `power_sensitivity.tsv` (optional) | Power across effect sizes / reps | Biopaint |

Key fields for the other heads:

- `experimental_unit` and `subsamples_per_unit`: subsamples (leaves of one plant, birds in one pen) are **not**
  independent. Simitall simulates them nested in the unit; Bioana averages them or fits the unit as a random effect.
- `design.chosen` and `analysis.model`: the model that matches the design, from `inst/registry/design_catalog.json`
  (74 designs, e.g. RCBD `y ~ treatment + block`, alpha lattice `y ~ treatment + rep + (1 | rep:block)`,
  split plot `y ~ treatment * treatment2 + block + (1 | block:treatment)`). Every catalog model is an R formula
  `lm()`/`lme4::lmer()` fits as written (a test checks this), using only the generic terms in the catalog's
  `model_terms`: `y treatment treatment2 block rep row col unit subject time env period sequence check`.
- `analysis.terms`: the layout column each generic term uses in this study (e.g. `treatment = genotype`,
  `treatment2 = water`, `block = block`, `unit = plot`), `layout_columns` (those that are columns of
  `field_layout.csv`) and `uncovered_factors` (factors in the layout the catalog model does not hold, such as a third
  factor or tissue; add them as fixed effects). `y` is the primary
  outcome. `analysis.note` carries what the formula cannot say (spatial AR1, survival, GCA/SCA, count models).
- `blocking_factors`: blocks, litters, batches, benches. Simitall adds their variance; Bioana keeps them in the model.
- `power.minimum_detectable_difference`, `power.residual_sd`: the effect and noise Simitall should use by default.
- Fields recorded under `assumptions` were not stated by the user; treat them as defaults the user may change.

## Building the layout: `layout_from_spec(spec, seed)`

Simitall must not build its own layout from the spec. Biodes exports `layout_from_spec()` (R/designs.R):

- every factor in the spec ends up in the layout as a column with its own name (`genotype`, `water`, `time`, ...);
- two or more randomized factors are crossed (`factorial`, or `split` when a factor is `applied_to: main_plot`);
  the design choice (`.sf_candidates`) now puts a design whose catalog model holds the factors first;
- factors measured within a unit (rules.tsv `within_unit_factor`, e.g. tissue) repeat each unit's row;
- time as the only factor is randomized like a treatment (destructive sampling);
- alpha lattices try every valid block size and fall back to complete blocks with a note when none exists;
- every default it used is in `attr(book, "layout_notes")` (copied to `design.layout_notes` in the spec);
- when it cannot build, it stops with the missing field named: `missing: factors`, `missing: factors.n_levels`,
  `missing: design.reps`, `missing: design.checks`. Those are questions for the user, not simulator gaps.

Several locations or seasons (`design.locations`, `design.seasons`) give one independent randomization per
environment, with `location` / `season` columns (listed in `analysis.terms.uncovered_factors` when the model has no
`env` term). An augmented design without named checks uses the stated default number of checks, with a note.

### When numbers are missing (schema 0.5.0)

- `fill_layout_defaults(spec)`: a factor without a level count, and augmented checks, get the stated defaults in
  rules.tsv `layout_default` (time 3, genotype 3, genotype in a GWAS/eQTL/QTL/genomic-prediction panel 200, any
  other factor 3, checks 4). Each is recorded in `spec$assumptions` as "assumed default (rules.tsv
  layout_default)". Use it only after the user was asked (Biodes asks the level-count question first).
- Replicates are never defaulted. When reps are open, the spec says `power.solve_for = "reps"`,
  `power.reps_range = [3, 12]` and `power.solve_for_reason` = `asked` (the user asked how many) or `not_stated`.
  Simitall runs a power sweep over that range.
- `mark_asked(spec, question)`: applies the same to a spec built elsewhere (e.g. a reviewed spec): clears what the
  question asks about and sets `power.solve_for`.
- Panels: a GWAS/eQTL/QTL-mapping/genomic-prediction spec always has a `genotype` factor (count asked when missing).
- `spec$genetics` (also `analysis.terms.genetic_unit`): `unit` = `line` | `bulk` | `population`, and when stated
  `individuals_per_bulk`, `bulk_fraction` (percent tail), `generations`. Rules: rules.tsv `genetic_unit`,
  `genetic_field`.

### Outcome type, assay kinds, breeding generations (schema 0.5.1)

- `primary_outcome.type`: `survival` only for death/lifespan/time-to-event/censored wording; `ordinal` for scores and
  scales; `binary` for yes/no outcomes; `count` for counts; otherwise `continuous`. Flowering time stays
  `continuous` (days to flowering is a measured trait, not a censored event unless the user says so). Rules:
  rules.tsv `outcome_type`.
- `assay_kinds`: finer assay names (`dnase_seq`, `faire_seq`, `dap_seq`, `selex`, `amplicon_16s`, `amplicon_its`,
  `amplicon_genotyping`, `tcr_seq`, `bcr_seq`, `crispr_screen`, `proteomics`, `starr_seq`, `mpra`). `assays` keeps
  the coarse labels the scoring uses; simulate from `assay_kinds` when present. Rules: rules.tsv `assay_kind`.
- `population.backcross_generations`, `population.filial_generation`, `population.self_generations`,
  `population.derived_generation` from notation such as BC3F2, F2:3, BC1F3:5, RIL F6. Rules: rules.tsv
  `generation_notation`. A count after the colon (F2:3) is never read as a level count.
- WGS and GBS panels are panels (`panel_assay`), so they get a `genotype` factor like GWAS.

### Stage, and the same units at every occasion (schema 0.5.2)

- Named physiological states (gestation and lactation, anthesis and grain filling, before/at/after puberty) are a
  `stage` factor; numbered points (day 10 and day 70, 24/48/72 h) are `time`. Both, and `age`, are occasion factors
  (rules.tsv `occasion_factor`): the generic model term `time` maps to the first one present (time, then stage, then
  age) in `analysis.terms.time`.
- `repeated_factors`: the occasion factors measured on the same units at every level. Read from the text (cues
  `same_units_over_occasions`, e.g. "from the same 7 boars at puberty and at maturity", and
  `different_units_per_occasion`, e.g. "sacrificed at each time"); `[]` means destructive sampling; absent means not
  stated, and Biodes asks "Are the same {unit}s sampled at every stage, or different {unit}s at each stage?" (rules.tsv
  `occasion_question`). "The same X" counts only when X is the measured subject (cue `living_subject`: "piglets ...
  into the same recipient sows" does not count); "before and after X" / "over time" on living subjects with a sample
  that does not kill them (cue `nondestructive_sample`: blood, faeces, milk, a biopsy) also means the same subjects;
  plant organs, cultured cells and destructive samples stay asked. Listed factors are within-unit in `layout_from_spec()` (each unit repeats across their
  levels), appear in `analysis.terms.repeated_factors`, and `analysis.note` says "add (1 | unit)" when the catalog
  model lacks it.
- `cell_type` and `fraction` are within-unit factors, like `tissue` (rules.tsv `within_unit_factor`).
- When an occasion factor is repeated, the layout's design is the repeated-measures form of what was built (rules.tsv
  `repeated_variant`: rcbd -> `randomized_complete_block_repeated` `y ~ treatment * time + (1 | block) + (1 | unit)`,
  crd -> `repeated_measures`, factorial -> `factorial_longitudinal`). `analysis.terms.unit_column` names the layout
  column that identifies one unit (`plot`), whose rows repeat across the occasion levels. When the repeated occasion
  is the only factor ("the same cows at 15 and 30 days postpartum"), it is the treatment of an rcbd and each block is
  one unit (a paired design): `analysis.terms.paired = true`, `unit_column = "block"`, and no extra random effect.
- Numeric levels (schema 0.5.3): "at 24, 48 and 72 h" gives `levels` ["24 h","48 h","72 h"], `values` [24,48,72],
  `unit` "h" (rules.tsv `time_unit_name`); the layout uses the labels.

### Analysis goals (schema 0.6.0; contract: Bioana `docs/contracts/analysis_goals.md`)

- Vocabulary: `inst/registry/analysis_goals.json` (Biodes owns it; Bioana keys `engine_selection.tsv` to its ids,
  Simitall plants truth for the primary goal). 17 goals: `treatment_effect`, `interaction`, `time_course`, `trend`,
  `transcript_usage`, `differential_abundance`, `community_composition`, `alpha_diversity`, `cell_composition`,
  `association`, `qtl_mapping`, `genomic_prediction`, `variance_components`, `ranking`, `survival`,
  `biomarker_classification`, `coexpression_network`. Each has `test` (wald | lrt | wald_or_lrt | other),
  `required_terms`, `data_types`, `replicate_multiplier`, `effect_definition`, `simulated`.
- Spec: `analysis.goals` (most important first), `analysis.primary_goal`, `analysis.goal_terms` (per goal, generic
  model terms: interaction two terms, time allowed, `env` for several locations/seasons; time_course the time term;
  trend the numeric term), `analysis.goal_effect` (per goal {size, scale, definition}; time_course adds shape, peak,
  half_time, scope when stated). `power.goal` = primary goal; the replicate sweep is widened by the registry
  multiplier (interaction x4), or `power.reps_note` warns when stated replicates are few for the goal.
- Where goals come from: the question (rules.tsv `analysis_goal`), else the data (`goal_default`: amplicon and
  metagenomics -> differential_abundance + community_composition; GWAS/eQTL -> association; survival outcome ->
  survival), else `treatment_effect`, recorded in `assumptions["analysis.goals"]` (assumptions is an object keyed by
  field path; the value says why). When the design can answer more than one goal and the question names none,
  Biodes asks (rules.tsv `goal_question`), e.g. "Do you want genes/features that differ between genotype levels,
  genes/features whose change over time differs between genotype levels, or genes/features that change over time at
  all?".
- The model holds what each goal tests: when the catalog model lacks the interaction, time or numeric term, Biodes
  adds it (noted in `analysis.note`). A goal the design cannot answer (interaction with one factor) is dropped with
  a note.
- Numeric levels of any factor: `values`, `unit` (time units, or rules.tsv `level_unit_name`: mg/kg, uM, %, Gy,
  ...) and `scale` (linear | log). A log-scaled factor with a zero level carries `log_offset` (the smallest positive
  level): fit log(x + log_offset).
- `goal_effect.scale` (schema 0.6.1) is the model scale for the data type (rules.tsv `effect_scale`): identity
  (continuous outcome), log2 (counts and intensities), M (methylation), logit (binary, ordinal), log (count outcome),
  log_hazard (survival). Truth and tests use that scale; an interaction is a difference of differences on it.

On Biodes' dev, dev2 and train specs (3,379 questions), with defaults applied and the low end of the replicate range,
3,336 (99%) get a layout that keeps every factor; the other 43 have no factor at all and are asked "what do you
compare or map?".

## Simitall (simulate)

- **Reads:** `study_spec.json` + `field_layout.csv`.
- **Does:** simulates the primary outcome (and, for omics assays, a count matrix) per unit from `analysis.model`:
  treatment effect = minimum detectable difference, residual sd = `power.residual_sd`, a variance for each blocking
  factor, subsamples nested in the unit, attrition from `power.attrition`. Same seed in = same data out.
- **Writes:** `sample_metadata_template.tsv` with `primary_outcome` filled, plus `counts.tsv` (features x
  `sample_id`) for RNA-seq-type assays, plus `sim_truth.json` (the true effects used), so Bioana can be checked.
- **Starting point:** SimItAll's simulation module.

## Bioana (analyze)

- **Reads:** `study_spec.json`, the filled `sample_metadata_template.tsv`, and `counts.tsv` if present.
- **Does:** fits `analysis.model` (lm / lmer, or DESeq2 / edgeR / limma with the same design terms for counts),
  aggregates or nests subsamples by `experimental_unit`, keeps `blocking_factors`, runs QC. It refuses (or warns
  loudly) when asked to treat subsamples as replicates: that decision was made in Biodes.
- **Writes:** `results.tsv` (term, estimate, se, p, padj) and `fit_summary.json` (model actually fitted, n units,
  dropped samples, warnings). On simulated data it compares estimates with `sim_truth.json`.
- **Starting point:** SimItAll's analysis module. Analysis questions on already-collected data ("which test", "DE
  genes") belong here, not in Biodes.

## Biopaint (figures, later)

Reads the layout (map), `power_sensitivity.tsv` (power curve) and Bioana's `results.tsv` (effect and volcano plots).

## Shared conventions (same as Biodes)

- No hard-coding: vocabulary and patterns live in TSV/JSON rule files the code reads; code holds grammar and maths.
- Never delete a rule; narrow it with exceptions.
- Deterministic code computes every number (layouts, power, simulation, model fits); a language model only reads
  the user's text and explains.
- Commits to main as nirwan1265, no AI attribution lines.

## Status of Biodes at hand-off (2026-11-19)

Usable for: reading a plain-language design question into a StudySpec, unit/pseudoreplication audit, candidate
designs, power, randomized layouts and the files above. On held-out test questions the reader + rules fill 87-89%
of the fields a design needs. Fields the user did not state are marked must-ask; on the old test split about 2% of
questions still get one of those filled in without asking, so the other heads should show the spec to the user
before simulating or analyzing. Package name is still `studyforge` while the rename to Biodes is in progress.

## Prompt to start the Simitall / Bioana window

> We're building Simitall and Bioana, two heads of the Biodes suite (repo github.com/nirwan1265/BioDesignGPT,
> read `docs/SUITE_INTEGRATION.md` first). Biodes writes `study_spec.json`, `field_layout.csv` and
> `sample_metadata_template.tsv`; Simitall simulates data from them and Bioana analyzes it with
> `analysis.model`. Start from SimItAll's simulation and analysis modules. Same rules as Biodes: no hard-coding,
> vocabulary in rule files, deterministic code for numbers, commit to main as nirwan1265 with no attribution.
> First task: a Simitall function that takes a Biodes output folder and writes simulated `primary_outcome`,
> `counts.tsv` and `sim_truth.json`, then a Bioana function that fits `analysis.model` and recovers the truth.

## Adding designs

Designs live in `inst/registry/design_catalog.json` (not rules.tsv). One object per design: `id`, `name`, `engine`
(R generator or `not_implemented (see pkg::fn)`), `requires`, `constraints`, `use_when`, `strength`, `tradeoff`,
`model` (generic terms only, fittable as written), optional `analysis_note`, `systems`, `example_sources` (real DOIs
only). `tests/testthat/test-catalog.R` fails if a model does not fit or uses another term. A new design is only
proposed to users once a candidate rule points to it (`.sf_candidates` in `R/local_agent.R`).
