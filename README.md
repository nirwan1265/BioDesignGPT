# StudyForge

An experimental-design agent for plant and biological research. You describe the experiment in plain language; StudyForge asks the questions that actually change the design, audits your experimental units for pseudoreplication, runs simulation-based power analysis, and writes a randomized layout plus metadata template.

**Free for everyone. No API key, no account, works offline.** The default engine reads your description with transparent rules, and every number comes from deterministic R code (`agricolae` for layouts, `lme4`/`simr` for mixed-model power). A local AI model is optional, never required.

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
| `studyforge_chat()` | free with Ollama (default); paid if you pick `anthropic`/`openai` | `ellmer` + a tool-capable model (e.g. `qwen2.5`) | Multi-turn conversational agent calling the same 16 tools |

### Optional: trained prompt tagger

A small BERT-style model (7 MB, bundled) trained on synthetic, label-correct prompts. Used as `engine = "hybrid"`, the rules go first and the model fills gaps; numbers are accepted only if they appear in the prompt. On 20 fresh prompts never used for tuning: rules 76% → hybrid **92%** field recall, zero invented values. Needs Python with `torch` and `transformers` (`Sys.setenv(STUDYFORGE_PYTHON = "path/to/python")`); everything else keeps working without it. See [training/README.md](training/README.md).

```r
studyforge_ask("Cold stress on rice: 15 C vs 28 C, one chamber per temperature, 24 seedlings per chamber", engine = "hybrid")
studyforge_alias("milo")   # "Sorghum bicolor" -- 427 aliases, SimItAll-style
```

On the 49 paper-grounded examples the free `local` engine recovers **92% of expected spec fields**, suggests a matching design for **98%**, and fills **zero** must-ask values (it never invents effect sizes, variances or unit counts). Reproduce with `evaluate_extraction()` or `Rscript inst/scripts/eval_extraction.R`.

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

## What's inside

| Component | Purpose |
|---|---|
| `R/unit_audit.R` | Biological / experimental / measurement unit check, before any power calc |
| `R/power.R` | Simulation power: RCBD, split-plot (correct error strata), alpha-lattice (lme4), generic `simr` wrapper, sensitivity tables |
| `R/designs.R` | CRD, RCBD, alpha-lattice, split-plot, factorial, augmented layouts with a standard schema |
| `R/spec.R` | StudySpec with dotted paths, assumption tracking, schema validation |
| `R/layouts.R` | Tray (augmented-by-tray), field coordinates with borders, mouse cage and fly vial allocation, resource equation, hazard and protocol lookups |
| `R/local_agent.R` | Free offline engine: `extract_spec_local()`, `studyforge_ask()`, `launch_studyforge()` |
| `R/eval.R` | `evaluate_extraction()`: scores any extractor against the examples |
| `R/agent.R` | Optional ellmer agent (Ollama by default): system prompt + 16 tools |
| `inst/shiny/studyforge` | Local Shiny app (plan, setup checks, starter layout download, StudySpec) |
| `inst/registry/setup_hazards.json` | 38 setup hazards (field borders, irrigation lines, soil, greenhouse doors/pads/sprinklers, chamber corners and drift, trays, cages, housing, experimenter, fly density/background/Wolbachia...), each with mitigation, covariates to record and a source |
| `inst/registry/protocol_notes.json` | Notes from the methods of 30 published studies: what they did, the numbers, the lesson |
| `inst/registry/*.json` (other) | 15-design catalog, cited pseudoreplication rules, experimental units, systems and their questions, spec schema |
| `inst/examples/study_examples.jsonl` | 49 prompt → expected-spec cases grounded in published studies; 28 include a full reference plan (design, layout, replication, randomization, what to record, analysis, pitfalls) and the hazards the agent must raise |
| `inst/scripts/eval_extraction.R` | Scores the free extractor (default) or the Ollama agent against the examples |

## Example set

Each example pairs a user-style prompt with the spec the agent should extract, the fields it **must ask about** (and never fill in itself), the expected unit-audit verdict, and the designs it should recommend. The cases are built from published designs, including some that contain the mistakes StudyForge is meant to catch:

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
