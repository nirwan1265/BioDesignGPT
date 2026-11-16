# New-kinds test set: labelling conventions

These are the study kinds skipped while labelling the paper training pool. The same conventions apply later
when training questions of these kinds are labelled (step 2), so the test and the training labels agree.

The general rules of the training pool still hold:
- One question per paper, written as a researcher planning a similar study would ask it (style: terse,
  detailed, question, casual or typo).
- The gold spec holds only what the question states. Counts must appear as numbers or number words.
- `must_ask` lists what a planner would have to ask, including the replicate count when it isn't stated and
  `power.minimum_detectable_difference` when nothing about the effect is given.
- System: the stated setting (field, greenhouse, growth chamber, mice/rats, flies, farm animals, cell lines),
  otherwise the study family.
- The experimental unit is labelled only when the question writes the unit word and the design makes it the
  unit. When the question asks about the unit, it goes in `must_ask`.

A paper is dropped (with a reason) when no fair design question can be written from it. Examples: genome
feature mapping (fragile sites, origins, damage), a pure method, a single-sample resource, or a mechanism
paper with no planned comparison.

## mapping: GWAS, QTL, bulk segregant, eQTL, MAGIC, introgression lines
- System: `breeding_genetics`, unless a field, greenhouse or growth chamber is named. Then that setting is
  the system, and mapping goes in assays.
- Assays: `gwas`, `qtl_mapping`, `bsa_seq`, `eqtl`, plus the genotyping assay if stated (`gbs`, `wgs`).
  Bulk segregant studies (BSA-seq, QTL-seq, MutMap, pooled F2 bulks) are `bsa_seq`; add `qtl_mapping` only
  when a linkage or QTL analysis is also stated.
- Factor `genotype`: n_levels = the number of lines or accessions when stated. Bulks in BSA are not
  genotype levels.
- `population.mating`: one of the schema values (`biparental`, `backcross`, `ril`, `dh`, `nam`, `selfing`,
  `sib_mating`, `diallel`, `nc_design`) when stated. MAGIC and diversity panels have none. Generations and
  parents only when stated.
- design.reps = replicates per line. Locations and seasons as stated. The unit is the plot only for a stated
  field design with plots.
- Ask: `design.reps` if not stated. `factors.genotype.n_levels` when the question asks how many lines.

## mutant_lines: knockouts, mutants, transgenic, edited, overexpression lines
- System: the stated setting (mice, flies, greenhouse ...). Otherwise `functional_validation`.
- Assays: the readout (`rnaseq` ...), plus `crispr` / `overexpression` / `complementation` when stated.
- Factor `genotype`: n_levels = the number of genotypes compared, wild type included. Independent lines of
  one construct are separate levels only when the question says they are compared separately.
- design.reps = individuals or biological replicates per genotype.
- Ask: `design.reps` if not stated. `experimental_unit` when the question asks whether lines, plants or
  pools are the replicates.

## population: population genomics, wild sampling, experimental evolution, mutation accumulation
- Observational sampling: factor `population` (or `phenotype_group` / `species` as stated), with n_levels =
  the number of populations. design.reps = individuals per population.
- Experimental evolution and mutation accumulation: factor `treatment` (the regime). design.reps =
  replicate populations or lines per regime. The unit is the replicate population (`pool`) or `line` only
  when the question writes it. `population.generations` when stated.
- Assays: `wgs`, `pool_seq`, `gbs` as stated.
- Ask: `design.reps` if not stated. `experimental_unit` when asking whether populations or individuals are
  the replicates.

## human_cohort: patient cohorts, observational cohorts, trials
- Organism `Homo sapiens`. No system (none fits). Don't force one.
- Factor `disease` / `phenotype_group` / `treatment` (case vs control, arms), with n_levels as stated.
  `disease` when a health state formed the groups (patients vs healthy controls, affected vs unaffected,
  naturally infected vs healthy); `phenotype_group` when a ranked or scored trait did (high vs low,
  resistant vs susceptible, responders vs non-responders). The rules apply the same test
  (`group_by_trait`, then `group_by_health`, in `inst/agent/rules.tsv`).
  `time` for repeated visits.
- design.reps = participants per group. The unit is `donor` only when written that way.
- Ask: `design.reps` if not stated. Always ask `power.minimum_detectable_difference` unless an effect is given.

## atlas: developmental series, time courses, cell atlases
- Factor `stage` / `time` / `tissue` / `cell_type`, with n_levels as stated.
- design.reps = individuals or biological replicates per stage. Pooled embryos or animals per sample go to
  `subsamples_per_unit`.
- System: the stated setting. Otherwise the assay family (`single_cell`, `bulk_rnaseq`, `atac_seq`).
- Ask: `design.reps` if not stated. `factors.time.n_levels` / `factors.stage.n_levels` when asking how many
  time points.

## cell_lines: cell lines, primary cultures, stem cells, organoids, in vitro screens
- System `cell_culture`.
- Factor `treatment` / `genotype` / `cell_type` / `time` as stated.
- design.reps = independent biological replicates (separate cultures, passages or differentiations).
  Wells from one culture are technical, not reps.
- The unit is `culture_passage`, `well`, `dish` or `flask` only when written that way and the design makes
  it the unit.
- Ask: `experimental_unit` when the question asks whether wells or passages are replicates. `design.reps`
  if not stated.
