# Biodes

**Design the experiment before you run it.** Biodes is the experimental-design head of a small suite of free, offline tools for plant and biological research. You describe the experiment in plain language; Biodes asks the questions that actually change the design, audits your experimental units for pseudoreplication, runs simulation-based power analysis, and writes a randomized layout plus a metadata template.

**Free for everyone. No API key, no account, works offline.** Every number comes from deterministic R code (`agricolae` for layouts, `lme4`/`simr` for mixed-model power). A local AI model is optional, never required.

<p align="center">
  <img src="docs/bio_suite.svg" alt="BioCore at the center, shared by four heads: Biodes designs the experiment, Simitall simulates the data, Bioana analyzes the results, Biopaint makes the figures" width="860">
</p>

## The suite

One shared core, four heads. Each head reads the same StudySpec and cites the same rules, so the design, the simulation, the analysis and the figures can't contradict each other.

| Part | Job | Status |
|---|---|---|
| **BioCore** | Plain-language agent, the rules registry (the "truths", each with a source), published-practice evidence, and the StudySpec every head shares | Rules and evidence layer in progress |
| **Biodes** (this repo) | Design: unit audit, candidate designs, power, randomization, field/tray/cage/vial layouts | Available |
| **Simitall** | Simulate data under the planned design: effects, noise, batches | From SimItAll's simulation module; integration planned |
| **Bioana** | Analyze with the model that matches the design: QC, DE, mixed models, GWAS | From SimItAll's analysis module; integration planned |
| **Biopaint** | Figures: layout maps, power curves, publication-ready plots | Planned |

The flow follows a real project: **Biodes** hands a StudySpec and layout to **Simitall**, simulated data goes to **Bioana**, fitted results go to **Biopaint**, and what you learn feeds the next design.

**How the heads connect:** see [`docs/SUITE_INTEGRATION.md`](docs/SUITE_INTEGRATION.md). Biodes writes `study_spec.json` (now with the matching `analysis.model` and `handoff_version`), `field_layout.csv` and `sample_metadata_template.tsv`; Simitall and Bioana read only those files.

> The R package is still named `studyforge` (and its functions `studyforge_*`) while the rename to Biodes is in progress.

## Install

```r
install.packages(c("agricolae", "jsonlite", "lme4", "simr", "shiny", "remotes"))
remotes::install_github("nirwan1265/BioDesignGPT")
```

## Use it (free)

```r
library(studyforge)

# point-and-click app in your browser, runs on your own computer
launch_studyforge()

# or from R
studyforge_ask("I have 200 Arabidopsis accessions for flowering time and only 48-cell trays (6 x 8).")
```

From the shell: `Rscript inst/scripts/studyforge_cli.R "120 maize lines, drought, two locations, 3 reps"` (or `--app`).

| Engine | Cost | Needs | What it does |
|---|---|---|---|
| `local` (default) | free | nothing | Rule-based extraction + the full deterministic engine: unit audit, candidate designs, setup checks, published-methods notes, starter layout code |
| `ollama` | free | [Ollama](https://ollama.com) installed locally | Same plan, rephrased by a local LLM that is told not to change any number |
| `llm` / `auto` | free | the local reader running on a GPU (`sbatch llm/reader_server.slurm`) | Rules first, then the fine-tuned Qwen2.5 reader fills stated facts the rules missed (see [How Biodes was built](#how-biodes-was-built-and-trained)) |
| `studyforge_chat()` | free with Ollama (default); paid if you pick `anthropic`/`openai` | `ellmer` + a tool-capable model (e.g. `qwen2.5`) | Multi-turn conversational agent calling the same 16 tools |

### Optional: trained prompt tagger

A small BERT-style model (bundled) trained on synthetic, label-correct prompts, local-LLM paraphrases, and prompts
grounded in ~19,000 real designed studies from public archives. Used as `engine = "hybrid"`, the rules go first and
the model fills gaps; numbers are accepted only if they appear in the prompt. On prompts written before the latest
round and scored once: **88.2%** field recall (up from 70.6%), and **88.9%** on real studies of species never seen in
training (up from 51.0%), with zero invented values (details and all test sets in [training/README.md](training/README.md)).
Needs Python with `torch` and `transformers` (`conda env create -f environment.yml`, or set
`Sys.setenv(STUDYFORGE_PYTHON = "path/to/python")`); everything else keeps working without it.

```r
studyforge_ask("Cold stress on rice: 15 C vs 28 C, one chamber per temperature, 24 seedlings per chamber", engine = "hybrid")
studyforge_alias("milo")   # "Sorghum bicolor" -- ~3,250 aliases in inst/agent/rules.tsv
```

On the 49 paper-grounded examples the free `local` engine recovers **92% of expected spec fields**, suggests a matching design for **98%**, and fills **zero** must-ask values (it never invents effect sizes, variances or unit counts). Reproduce with `evaluate_extraction()` or `Rscript inst/scripts/eval_extraction.R`.

### What Biodes understood, and fixing it

Every plan opens with the fields it extracted. Anything it could not find shows `?`, with a hint from published
studies where one exists; phenotypes are kept as written for you to confirm. Correct any field and the plan is rebuilt:

```r
a <- studyforge_ask("I want maize RNA-seq for drought vs control")
#> Here's what I understood (fix anything wrong: studyforge_fix(answer, organism = "...", factors = "name:levels")):
#>   Goal:                design a new study
#>   Organism:            Zea mays
#>   Setting:             bulk_rnaseq
#>   Assay / data:        rnaseq
#>   Tissue:              ? (most studied: leaf, root, endosperm, kernel)
#>   Sequencing:          ? (typical: Illumina NovaSeq 6000, ~24.1 M reads per sample)
#>   Factors (levels):    water (2)
#>   ...
a <- studyforge_fix(a, tissue = "leaf", design.reps = 6)

suggest_traits("roots", "cold", "Arabidopsis thaliana")   # "what can I measure?", with methods and sources
```

## Use the engine directly (no LLM)

```r
unit_audit("plant", "pot", "leaf", subsamples_per_unit = 3, units_per_group = 6)
#> pseudoreplication_risk: "high"; n = 6 pots per group, not 18 leaves

power_split_plot(n_main = 3, n_sub = 5, n_blocks = 4, delta = 1,
                 effect = "main", sd_whole = 1, sd_sub = 1)   # irrigation (whole plot)
power_split_plot(3, 5, 4, delta = 1, effect = "sub", sd_whole = 1, sd_sub = 1)  # cultivar

power_alpha_lattice(n_trt = 120, block_size = 10, reps = 2,
                    delta = 0.5, sd = 0.4, block_sd = 0.3)
#> power for a pairwise entry contrast, plus power if analysed as RCBD

book <- make_design("split", c("I0", "I1", "I2"), reps = 4,
                    treatments2 = paste0("C", 1:5), seed = 42)
write_design_package(book, new_spec(), "studyforge_run")
```

### Setup layouts (trays, field grids, cages, vials)

```r
# 200 accessions in 48-cell trays (6 x 8): Col-0 and Ler in every tray, edge cells as guards
trays <- make_tray_design(paste0("Acc", 1:200), c("Col-0", "Ler"), tray_rows = 6, tray_cols = 8)

# put an RCBD on a field grid with serpentine order and a border ring (for SpATS / AR1xAR1)
field <- add_field_coordinates(make_design("rcbd", paste0("G", 1:12), reps = 3), n_cols = 6)

# mice: diet in the cage makes the cage the unit
cages <- make_cage_allocation(c("LF", "HF"), n_per_group = 8, per_cage = 4, delivery = "cage")

# flies: every rearing bottle supplies one vial to each diet
vials <- make_vial_allocation(c("DR", "AL", "Rapa"), vials_per_treatment = 15, flies_per_vial = 10)

resource_equation_n(k = 4)            # 4-6 animals/group when no SD exists
setup_hazards("greenhouse")           # doors, pads, sprinklers, gradients, pot size...
protocol_notes("spatial sorghum")     # what published trials actually did
```

## Published-practice evidence (BioCore)

Rules say what is statistically correct; evidence says what published studies actually did. Biodes reports both:

```r
published_practice("sorghum", "RNA-seq", "leaf")
#> 55 designed Bulk RNA-seq studies of Sorghum bicolor (leaf) in public archives (2016-2026).
#> Replicates per condition: median 3 (IQR 2-3, from 46 studies); 22% used 6 or more.
#> Read depth: median 23.4 M reads per run (IQR 20-28.6).
#> Recent sequencers: Illumina NovaSeq 6000, Illumina HiSeq 2500, NextSeq 500.
#> Examples:
#>   PRJNA1137865 (2024; 3 reps; genotype[Tx430 transgenic, Tx430 WT]) doi:10.1111/pbi.14527 ...
published_practice("zebrafish")            # every technique with data for an organism
```

`studyforge_ask()` adds this section to plans automatically for omics designs (organism + assay, tissue taken from the
question), and flags replicate numbers below the published median, while still sending sample size to power analysis
("for differential expression, 6 or more biological replicates detect far more genes than 3"). It is descriptive:
most published studies are under-replicated, so it is context, never the recommendation.

The tables (`inst/extdata/published_*.tsv.gz`, under 1 MB) are built from public metadata and open-access papers:

| Script (`data-raw/evidence/`) | What it does |
|---|---|
| `harvest_evidence.R` | Run and sample metadata from ENA/SRA and GEO for 34 species (crops, trees, model animals, human, yeast); a technique classifier (Ribo-seq, CUT&Tag, scRNA-seq, DAP-seq, degradome, Hi-C, ATAC, ChIP, methylome, ...); per-study samples, conditions, reps per condition, sequencer, depth, kits, tissues |
| `enrich_evidence.R` | Links designed studies to papers (GEO, BioProject, Europe PMC), recovers the real factor structure from BioSample attributes or sample names (e.g. `treatment[2] x time point[3]`, reps per cell), and extracts growth conditions, design, replication, pooling and statistics from open-access methods sections |
| `build_practice.R` | Builds the shipped summary and example-study tables |
| `download_papers.R` | Saves the open-access full texts behind the evidence, for reading and checking (local only) |

Current harvest: 95,403 studies across 34 species; about 57,000 designed studies, 43,933 study-paper links, factor
structures for 36,732 studies, and methods extracted from 32,606 open-access papers. Only extracted facts and DOIs ship
with the package; full texts stay local.

## How Biodes was built and trained

Biodes reads a question with two readers and then hands a structured plan to deterministic statistics. The
language side was built from real studies and real papers; the numbers never come from a model.

```
question --> rule extractor (R, rules.tsv) ----------+
         \-> LLM reader (Qwen2.5-32B + LoRA, local) -+--> merge: rules first, reader fills stated facts only
                                                          --> StudySpec --> engine: unit audit, designs, power,
                                                                            randomization, layouts
```

### 1. Evidence: what published studies actually did

Public run and sample metadata (ENA/SRA, GEO) for 34 species: **95,403 studies**, about 57,000 of them designed
experiments. 43,933 were linked to their papers, the factor structure was recovered for 36,732, and growth
conditions, replication, pooling and statistics were extracted from **32,606 open-access methods sections**. This
layer supplies the published-practice tables above and the material for steps 3 and 4.

### 2. Rules and vocabulary: one table, no hard-coded words

Everything Biodes knows about words lives in [`inst/agent/rules.tsv`](inst/agent/rules.tsv): **4,030 rows** in 60
categories, covering 235 organisms, 319 outcomes, assays, factors, units, settings, the named patterns the rule
extractor uses, and the reader's vocabulary. R and Python read the same file; the statistics live in code.
Rows can be proposed by anyone, including other AIs: `training/rules_tool.py` checks them and fires each one on
~48,600 labelled training prompts, and rows that disagree with the labels are rejected. The latest batch of 2,804
ChatGPT/DeepSeek proposals gave 2,221 rows and 580 rejections, each with a reason
(`training/rules_review/`). See [`inst/agent/README.md`](inst/agent/README.md).

### 3. Paper questions: real studies, labelled by hand

**3,200 open-access papers** were sampled from the methods index, stratified by species x technique (34 species,
42 techniques). Each paper was read and, where it describes a designed study, turned into the question a researcher
would have asked *before* doing it ("RNA-seq of maize leaves under drought, how many replicates?"). The gold
StudySpec records only what the question states, and fields the question leaves open are marked must-ask. Papers
about methods, mechanisms or atlases were skipped, so about 60% of papers gave a question: **1,939 questions**.

| split | questions | use |
|---|---|---|
| dev | 328 | tuning rules, prompts and the reader |
| test | 764 | scored once, at the end |
| test, held-out species | 87 | Setaria, poplar, zebrafish and Xenopus: never used in any training |
| training pool | 760 | reader training only (never dev or test) |

The split is by paper and frozen with a manifest of hashes, and training data is leak-checked against it. Many
questions are design-teaching cases: pseudoreplication (cage, pen, tank, litter, plot, donor), unreplicated
designs, confounded site and cultivar, split-plot and augmented layouts.

### 4. Training data for the reader

About **5,300 labelled prompts**:

- 760 paper questions (step 3)
- 755 paraphrases written by a local Llama 3.1, kept only when every labelled span survived
- 2,474 synthetic prompts, balanced by study type x organism (from 14,000 generated with labels correct by construction)
- 1,350 prompts built from real designed studies (from ~33,000 generated from the evidence layer)

Every label follows one convention: the system is the stated setting, and assays are listed separately. Test
prompts and held-out species are excluded.

### 5. The reader: Qwen2.5-32B-Instruct with a LoRA adapter

The model runs locally with vLLM on one GPU (RTX 6000 Pro, 96 GB); nothing leaves the cluster. Training
(`llm/finetune.slurm`):

1. The base model reads every training prompt. This self-distillation supplies the fields we have no labels
   for: method, tissue, level names, outcome text.
2. Targets are built from our labels plus the distilled fields. The experimental unit is included only when the
   prompt names it.
3. LoRA (rank 16, all projection layers, loss on answer tokens only, 1 epoch), resumable across 2-hour GPU jobs.
4. The base and fine-tuned readers are evaluated on every set.

The first adapter was trained on 4,396 examples (validation loss 0.047). The second (v2), on 5,126 examples
including the hand-labelled paper-question training pool, reached validation loss 0.045. **The current reader is
Qwen2.5-32B-Instruct + the v2 adapter.**

It was chosen on paper-question dev only. Rules + reader: base 87.3%, v2 86.6%. Reader alone: base 85.6%, v2
86.0%. Neither gap is significant: a paired bootstrap over the 328 questions gives v2 - base = -0.7 points
(95% CI -1.8 to +0.4) merged and +0.4 (-1.1 to +1.9) alone. Two tie-breakers favour v2. On its own it invents a
must-ask value in 5 questions, against 13 for the base model. It also matches or beats the base model on the
clean sets (fresh v1, v2 and v4) with no invented values, which was the rule set in advance for keeping an
adapter. Where it is weaker: experimental unit (17/24 vs 20/24) and factor levels (73% vs 77%).

### 6. Merging: the reader states facts, the engine makes judgments

The rule extractor goes first. The reader fills gaps only with facts the question states: numbers must appear in
the text, and organisms, assays and outcomes must be named. The experimental unit, the primary outcome when
several are named, and anything a keyword cannot settle ("pups kept with their dams": treated through the mother
or each pup?) are decided by the engine or asked. Fewer than 3 replicates per condition is flagged.

### Results so far

Field recall: the share of the fields a question states that come out right. "Invented" counts must-ask fields
filled in anyway.

| set | rules alone | reader alone | rules + reader |
|---|---|---|---|
| paper questions, dev (328), merge of 2026-11-14 | 64.7% (4 invented) | 86.0% (5 invented) | 86.6% (8 invented) |
| paper questions, dev (328), **current merge** | 64.7% (1 invented) | 86.0% (5 invented) | **87.4%** (1 invented) |
| paper questions, **test** (764, scored once, merge of 2026-11-14) | 64.0% (18 invented) | 85.8% (13 invented) | **85.7%** (24 invented) |
| paper questions, **held-out species test** (87, scored once, merge of 2026-11-14) | 65.0% (5 invented) | 89.1% (3 invented) | **89.4%** (5 invented) |
| study examples, dev (59) | 92.7% | 85.8% | 94.9% |
| fresh v4, clean test (21) | 86.6% | 93.3% | **97.5%** |
| real studies of held-out species (300) | 98.2% | 98.1% | **99.1%** |

Reader = Qwen2.5-32B + v2 adapter. The two paper-question test sets were scored once, after the reader was fixed
on dev (2026-11-14). Test recall held at the dev level (85.7% vs 86.6%), and held-out species (zebrafish,
Xenopus, Setaria, poplar) did no worse. Those test numbers stay the official record. They are not re-scored for
the merge fixes below, which were tuned on dev only.

Two weak spots showed on dev and test alike. Both are now fixed on dev:
- **Merging lost factor levels the reader had right.** Lost factor keys went from 23 to 8, and name + levels
  merged went from 73.1% to 76.2% (reader alone 76.8%). A reader level count is now kept when the prompt lists
  that many items, or when its levels are named in the text. A rule count is dropped when the reader leaves the
  count open and the number isn't written on its own ("Mo17" doesn't state 17 genotypes).
- **The rules invented must-ask values.** Merged inventions on dev went from 8 to 1. The replicate count is left
  open when:
  - the question asks for it ("how many piglets per group", "should I have replicated");
  - the groups differ in size ("3 plants each, plus a single control");
  - the number is a total with a breakdown ("8 pigs (4 male, 4 female)");
  - it counts something inside each replicate ("32 incomplete blocks per replication");
  - the units are pooled per group.

  The one left is an engine judgment (maternal treatment -> litter as the unit). The cues are in
  `inst/agent/rules.tsv`.

Per-set details and the base-model comparison are in [`llm/README.md`](llm/README.md).

## What's inside

| Component | Purpose |
|---|---|
| `R/unit_audit.R` | Biological / experimental / measurement unit check, before any power calc |
| `R/power.R` | Simulation power: RCBD, split-plot (correct error strata), alpha-lattice (lme4), generic `simr` wrapper, sensitivity tables |
| `R/designs.R` | CRD, RCBD, alpha-lattice, split-plot, factorial, augmented layouts with a standard schema |
| `R/spec.R` | StudySpec with dotted paths, assumption tracking, schema validation |
| `R/layouts.R` | Tray (augmented-by-tray), field coordinates with borders, mouse cage and fly vial allocation, resource equation, hazard and protocol lookups |
| `R/local_agent.R` | Free offline engine: `extract_spec_local()`, `studyforge_ask()`, `launch_studyforge()` |
| `R/practice.R` | `published_practice()`: what designed studies did per organism x technique x tissue, with citable examples |
| `R/general_extract.R` | Table-driven extraction layer (any organism/assay/factor word in `rules.tsv`, generic counts), the plan skeleton, `studyforge_fix()` |
| `inst/agent/rules.tsv` | The one table of words and patterns (aliases, cues, word lists, lookups) read by R and Python |
| `llm/` | The local LLM reader: prompts, fine-tuning (`finetune.slurm`), the server R talks to |
| `training/paper_questions/` | Paper-grounded questions: sampler, labels, frozen dev/test/held-out split, scorer |
| `R/traits.R` + `inst/registry/traits.json` | `suggest_traits()`: traits by organ and stress with method, tools, design note and source |
| `R/eval.R` | `evaluate_extraction()`: scores any extractor against the examples |
| `R/agent.R` | Optional ellmer agent (Ollama by default): system prompt + 16 tools |
| `inst/shiny/studyforge` | Local Shiny app (plan, setup checks, starter layout download, StudySpec) |
| `inst/registry/setup_hazards.json` | 57 setup hazards (field borders, irrigation lines, soil, greenhouse doors/pads/sprinklers, chamber corners and drift, trays, cages, housing, experimenter, fly density/background/Wolbachia, inbreeding, crossing, GxE, greenhouse-to-field, GWAS/eQTL, Ribo-seq, ATAC-seq, validation...), each with mitigation, covariates to record and a source |
| `inst/registry/protocol_notes.json` | Notes from the methods of 40 published studies and standards: what they did, the numbers, the lesson |
| `inst/registry/*.json` (other) | 24-design catalog (incl. diallel, NC designs, mapping populations, MET with FA, GWAS+eQTL, Ribo-seq, ATAC-seq, two-organism validation), cited pseudoreplication rules, experimental units, systems and their questions, spec schema |
| `inst/examples/study_examples.jsonl` | 59 prompt → expected-spec cases grounded in published studies; 38 include a full reference plan (design, layout, replication, randomization, what to record, analysis, pitfalls) and the hazards the agent must raise |
| `inst/scripts/eval_extraction.R` | Scores the free extractor (default) or the Ollama agent against the examples |

## Example set

Each example pairs a user-style prompt with the spec the agent should extract, the fields it **must ask about** (and never fill in itself), the expected unit-audit verdict, and the designs it should recommend. The cases are built from published designs, including some that contain the mistakes Biodes is meant to catch:

- Alpha-lattice sorghum GWAS, 324 accessions, 3 sites, 2 reps (Enyew et al. 2022, doi:10.3389/fpls.2022.999692)
- Unreplicated plots with five panicles treated as replicates (Chakrabarty et al. 2021, doi:10.3389/fpls.2021.772177)
- Split-plot irrigation × forage cultivar (Bhattarai et al. 2020, doi:10.1002/csc2.20171)
- Greenhouse blocking vs pot rotation (Hartung et al. 2019, doi:10.1186/s13007-019-0527-4)
- RNA-seq replicate numbers (Schurch et al. 2016, doi:10.1261/rna.053959.115)
- Field drought RNA-seq time course with pooled plants (Varoquaux et al. 2019, doi:10.1073/pnas.1907500116)
- Litter effects (Lazic & Essioux 2013, doi:10.1186/1471-2202-14-37)
- Diet and drinking-water antibiotics delivered per cage (Stapleton et al. 2024, doi:10.1186/s13293-023-00580-1)
- Cells as replicates in single-cell DE (Squair et al. 2021, doi:10.1038/s41467-021-25960-2)
- LC-MS pooled QC and batch layout (Broadhurst et al. 2018, doi:10.1007/s11306-018-1367-3)
- p-rep designs (Cullis et al. 2006, doi:10.1198/108571106X154443), augmented designs (Federer 1956)
- ARRIVE 2.0 experimental unit (doi:10.1371/journal.pbio.3000410), technical vs biological replicates (Vaux et al. 2012, doi:10.1038/embor.2012.36), pseudoreplication (Hurlbert 1984, doi:10.2307/1942661), image-based phenotyping (Neilson et al. 2015, doi:10.1093/jxb/eru526)

Edit `data-raw/study_examples.json`, then rebuild with `Rscript data-raw/build_examples.R`. The tests check that every example cites a source, that must-ask fields aren't pre-filled, and that expected audit verdicts agree with `unit_audit()`.

## Tests

```r
testthat::test_local()
```

## Scope and caveats

- Animal-study output is a planning recommendation, not an ethics approval; final designs need statistician, veterinarian and IACUC review.
- Power for split-plot and alpha-lattice is simulation-based; report the Monte Carlo SE (`mcse`) with it.
- p-rep layouts are in the catalog but not generated yet (see FielDHub).
- Published-practice evidence describes what studies did, not what is correct; Biodes shows it next to the rule, never in place of it. Human and mouse coverage is limited to recent studies (2024 onward) for now.
