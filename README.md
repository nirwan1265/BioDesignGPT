# Biodes

<p align="center">
  <img src="docs/bio_suite.svg" alt="Biodes suite: design, simulate, analyze, figures" width="860">
</p>

<p align="center"><b><a href="https://nirwan1265.github.io/BioDesignGPT/try/">▶ Try it in your browser</a></b> (no install: R runs on the page)</p>

## Prompt

> Field trial of 24 sorghum hybrids under two nitrogen rates (0 and 120 kg N/ha) and two irrigation regimes (full and deficit) at 3 locations over 2 seasons with 3 replicates; irrigation can only be applied to whole main plots; we measure grain yield and want to know whether the nitrogen response differs between hybrids.

## Output (R)

```r
> library(studyforge)

> a <- studyforge_ask("Field trial of 24 sorghum hybrids under two nitrogen rates (0 and 120 kg N/ha) and two irrigation regimes (full and deficit) at 3 locations over 2 seasons with 3 replicates; irrigation can only be applied to whole main plots; we measure grain yield and want to know whether the nitrogen response differs between hybrids.")

> a
Biodes (local, free)

Here's what I understood (fix anything wrong: studyforge_fix(answer, organism = "...", factors = "name:levels")):
  Goal:                design a new study
  Organism:            Sorghum bicolor
  Setting:             field
  Study type:          multi_environment
  Assay / data:        ?
  Method / resource:   ?
  Tissue:              whole
  Factors (levels):    genotype (24); water (2); nitrogen (2)
  Outcome / phenotype: grain_yield
  Experimental unit:   ?
  Replicates:          3
  Locations / seasons: 3 / 2

System: field | Study: multi_environment
Primary outcome: grain_yield
Design facts: reps = 3, locations = 3, seasons = 2

Still needed: experimental_unit, power.minimum_detectable_difference, power.residual_sd

Questions that change the design:
  - Which environments (locations x years x managements), and are they chosen to represent the target population of environments?
  - Same entries in every environment, or partially overlapping sets?
  - Will environmental covariates (weather, soil, water input) be recorded for each environment?

Candidate designs:
  - Split-plot design (whole plots in RCBD): One factor is hard to randomize at small scale (irrigation, temperature chamber, tillage) and is applied to whole plots; the other factor (genotype) is randomized within them. Tradeoff: Whole-plot factor has its own, larger error term and few df; power for it is low unless many blocks.
  - Multi-environment trial with factor-analytic GxE model: Same entries in several locations/years; interest in stability and GxE. Tradeoff: Needs enough environments (>= 5-6) for FA structures; complex fitting.
  - Alpha-lattice (resolvable incomplete block) design: Many genotypes (tens to hundreds) so complete blocks would be heterogeneous. Tradeoff: Requires mixed-model analysis; block size must divide the number of entries.
  - Spatial analysis of a gridded trial (SpATS / AR1xAR1): Any field or bench trial laid out on a row x column grid; especially large or low-input trials. Tradeoff: Needs coordinates for every plot; model checking required.

Setup checks (12):
  - Plots on the outside edge of the trial (and next to alleys, roads, tree lines) get more light, water and nutrients and less competition. -> Surround the trial with at least one ring of border (filler) plots that are not measured
  - Water is not uniform: distance from drip laterals, pipe mains, sprinkler lines or the low end of a furrow creates a gradient. -> Lay out each block so it sits at a constant distance from the water source (blocks parallel to the line, plots within block spread along it)
  - Plots are lost to poor emergence, lodging, animals, flooding or harvest errors (3-29% missing per trial in large sorghum p-rep trials). -> Plan extra replication of key entries and checks
  - Patchy soil fertility, texture or nutrient availability (plant-available P varied with CV 39% within one Malian sorghum field). -> Map apparent electrical conductivity (EM38) or a soil grid before or shortly after planting
  - Large trials (hundreds of plots) almost always have smooth trends and patchiness that blocks miss. -> Plan a rectangular row x column grid and keep coordinates for every plot
  - Early-generation trials with one plot per entry have no direct error estimate. -> Repeat check varieties throughout the field (augmented, diagonal or p-rep arrangements)
  ... see answer$hazards for all

What published studies did:
  - Enyew et al. 2022, Front Plant Sci 13:999692: Block size 27 divides 324 evenly; tagged plants are subsamples averaged per plot.
  - Velazco et al. 2017, Theor Appl Genet 130:1375-1392: Spatial models reduced residual variance 49% (yield) and 22% (height); one general SpATS model worked for every trial.
  - Leiser et al. 2012, J Agron Crop Sci: Spatial models raised yield heritability ~10 points over RCB and 6 over lattice; block placement and orientation matter.

Starter code:
book <- layout_from_spec(a$spec, seed = 2026)   # randomized layout for this design
write_design_package(book, a$spec, "my_design")   # study_spec.json, field_layout.csv, sample sheet

Power: give a minimum detectable difference and residual SD (pilot data or literature); Biodes never assumes them. Then run power_rcbd(), power_split_plot() or power_alpha_lattice().

> book <- layout_from_spec(a$spec, seed = 2026)

> write_design_package(book, a$spec, "sorghum_trial")
[1] "sorghum_trial/field_layout.csv"             "sorghum_trial/sample_metadata_template.tsv"
[3] "sorghum_trial/study_spec.json"             

> spec <- jsonlite::fromJSON("sorghum_trial/study_spec.json")

> spec$design$chosen
[1] "split_plot_factorial"

> spec$analysis$model
[1] "y ~ treatment * treatment2 * treatment3 + block + (1 | block:treatment)"

> unlist(spec$analysis$terms[c("treatment", "treatment2", "treatment3")])
 treatment treatment2 treatment3 
   "water" "genotype" "nitrogen" 

> spec$analysis$goal_terms$interaction
[1] "treatment3" "treatment2"

> nrow(book)
[1] 1728

> head(book[, c("location", "season", "block", "plot", "subplot", "water", "genotype", "nitrogen")], 8)
    location   season block plot subplot water    genotype    nitrogen
1 location_1 season_1     1  101       1  full  genotype_2   0 kg N/ha
2 location_1 season_1     1  101       2  full genotype_19 120 kg N/ha
3 location_1 season_1     1  101       3  full genotype_19   0 kg N/ha
4 location_1 season_1     1  101       4  full  genotype_1   0 kg N/ha
5 location_1 season_1     1  101       5  full genotype_24   0 kg N/ha
6 location_1 season_1     1  101       6  full genotype_20 120 kg N/ha
7 location_1 season_1     1  101       7  full  genotype_2 120 kg N/ha
8 location_1 season_1     1  101       8  full  genotype_8   0 kg N/ha
```

## Install

```r
remotes::install_github("nirwan1265/BioDesignGPT")
library(studyforge)
```

[Full documentation](docs/README_DETAILED.md) · [Simitall](https://github.com/nirwan1265/simitall) · [Bioana](https://github.com/nirwan1265/Bioana)
