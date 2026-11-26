# Showcase: three experiments from question to analysis

Each folder starts from one plain-language question. Biodes asks what it needs, chooses the design and writes the
files; the same folder name continues in [Simitall](https://github.com/nirwan1265/simitall) (simulated data with known
truth), [Bioana](https://github.com/nirwan1265/Bioana) (the analysis that matches the design, scored against that truth)
and Biopaint (figures, in progress).

| Example | What it shows |
|---|---|
| [01 GWAS, sorghum panel](01_gwas_sorghum) | 300 accessions in an alpha lattice: incomplete blocks, a mixed model, a genotype panel handed on for association |
| [02 RNA-seq, genotype x drought](02_rnaseq_drought) | A factorial whose goal is the interaction (genes whose drought response differs in the mutant), level names kept, reference levels first |
| [03 Seed priming, time to germination](03_germination_survival) | A survival design: censoring, a competing event (seed rot), a stated delayed effect, trays as clusters, power in events |

Rebuild all three (seed 2026): `Rscript examples/showcase/make_showcase.R` from the repository root.
