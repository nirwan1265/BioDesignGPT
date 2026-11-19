# Linking Biodes to Simitall and Bioana

This is the hand-off contract for the suite. Biodes (this repo) is developed in its own chat/window; Simitall and
Bioana are built in another. Each head only needs this file and the files Biodes writes, not Biodes' internals.

## The one rule

**The StudySpec is the contract.** Biodes writes it; Simitall and Bioana read it and never re-ask what it already
answers. The schema lives in this repo at `inst/registry/study_spec.schema.json` (version `0.4.0`), and every
hand-off spec carries `handoff_version`. A head that needs a new field asks for it here (in Biodes), never adds its
own private copy of the design.

## What Biodes hands over

`write_design_package(book, spec, outdir)` writes one folder per study:

| File | What it is | Read by |
|---|---|---|
| `study_spec.json` | The StudySpec: system, organism, factors and levels, experimental unit, subsamples per unit, blocking factors, reps, design.chosen, randomization_seed, power settings, `analysis.model`, `handoff_version` | Simitall, Bioana, Biopaint |
| `field_layout.csv` | One row per experimental unit: plot/pot/cage id, block, treatment (and row/col for spatial designs) | Simitall, Biopaint |
| `sample_metadata_template.tsv` | The layout plus `sample_id` (e.g. `SF_rcbd_0001`), `date_measured`, `primary_outcome`, `notes` left empty | Simitall fills it; Bioana reads it |
| `unit_audit.json` (optional) | Pseudoreplication audit: what the true unit is and why | Bioana |
| `power_sensitivity.tsv` (optional) | Power across effect sizes / reps | Biopaint |

Key fields for the other heads:

- `experimental_unit` and `subsamples_per_unit`: subsamples (leaves of one plant, birds in one pen) are **not**
  independent. Simitall simulates them nested in the unit; Bioana averages them or fits the unit as a random effect.
- `design.chosen` and `analysis.model`: the model that matches the design, from `inst/registry/design_catalog.json`
  (e.g. RCBD `y ~ treatment + block`, alpha lattice `y ~ genotype + rep + (1 | rep:block)`,
  split plot `y ~ main * sub + block + (1 | block:main)`). `y` is the primary outcome; the other terms are columns of
  the layout.
- `blocking_factors`: blocks, litters, batches, benches. Simitall adds their variance; Bioana keeps them in the model.
- `power.minimum_detectable_difference`, `power.residual_sd`: the effect and noise Simitall should use by default.
- Fields recorded under `assumptions` were not stated by the user; treat them as defaults the user may change.

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
