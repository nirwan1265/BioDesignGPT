# rules.tsv: the one table of words and patterns

`inst/agent/rules.tsv` is everything StudyForge knows about **words**: which organism a phrase names, which assay,
which setting, which outcome, which factor, which unit, and the named patterns ("cues") the rule extractor uses.
R and Python both read it; no word list lives in code. To teach StudyForge something new, add a row.

## What StudyForge does, and where this table sits

A researcher describes an experiment in plain language. StudyForge turns it into a **StudySpec** (system,
organism, assays, factors and levels, replicates, experimental unit, outcome ...), asks for what is missing, and
then a deterministic engine proposes designs, power, randomisation and layouts.

```
question ──► rule extractor (R) ─────────┐
         └─► LLM reader (Qwen, local) ───┴─► merge: rules first, reader fills gaps with stated facts only
                                              ──► StudySpec ──► engine: unit audit, designs, power, layouts
```

- The **rule extractor** reads the question with the patterns in this table. It is fast, free and never invents
  a number; it misses phrasings it has no row for.
- The **LLM reader** understands free language, but can guess. Its answer is checked against this table: an
  organism, assay or outcome it reports must be one the table knows and the question states.
- On the clean test set the reader alone scores 84-92 % field recall, rules + reader 95-96 %. Better rows here
  raise both.
- **Design judgments are not made from words.** A row says what the text *names*; whether that makes the cage
  or the mouse the experimental unit is the engine's job (or a question to the user).

## The table

Six tab-separated columns, one rule per row. Order within a category is priority.

| column | meaning |
|---|---|
| `category` | what kind of thing the row is about (`organism`, `assay`, `outcome`, `unit`, `cue`, ...) |
| `term` | the canonical result: `Zea mays`, `rnaseq`, `days_to_silking`, `pot` (for a cue: its name) |
| `match` | how `pattern` is used: `word`, `regex` or `value` (below) |
| `pattern` | the text to look for, or the value |
| `note` | why the row exists / what it detects |
| `source` | where it came from (curated terminology, paper questions, rules, chatgpt, ...) |

`match`:

- **`word`**: a literal phrase searched in the question (an alias). Case does not matter; it matches whole
  words only; the longest phrase wins an overlap. Spelling variants are just more rows. Most rows should be words.
- **`regex`**: a regular expression searched in the **lowercased** question, for when a word list is not enough
  (context, abbreviations, optional letters). `|` = or, `\b` = word boundary, `?` = previous character optional
  (`dams?` = dam or dams), `(?:...)` = group, `\d` = digit. Write `\bdta\b`, never `DTA` (uppercase never matches).
  In a `cue`, `{N}` stands for any number ("5", "five").
- **`value`**: a literal the code uses as is: word lists (which nouns count replicates), lookups (assay ->
  evidence technique label), the vocabulary shown to the LLM reader.

Examples:

```
outcome   flowering_time             word    days to flowering
outcome   days_to_silking            word    days to silking          maize female flowering
outcome   days_to_silking            regex   \bdts\b
organism  Zea mays                   word    maize
unit      pot                        word    cone-tainer
cue       housed_per_cage            regex   per cage|mice per cage|housed \d+ per cage    animals housed together
count_noun  water                    value   irrigation levels?        noun after a number that counts water levels
```

## Categories

| category | rows | match | terms / what it holds |
|---|---|---|---|
| `organism` | 178 | regex/word | `Sorghum bicolor`, `Zea mays`, `Triticum aestivum`, `Hordeum vulgare`, `Glycine max`, `Oryza sativa`, `Arabidopsis thaliana`, `Solanum lycopersicum`, `Brassica napus`, `Mus musculus`, `Drosophila melanogaster`, `Saccharomyces cerevisiae`, `Saccharum spp.`, `Pennisetum glaucum`, `Gossypium hirsutum`, `Rattus norvegicus`, `Nicotiana benthamiana`, `Caenorhabditis elegans`, `Danio rerio`, `Setaria viridis`, `Brachypodium distachyon`, `Solanum tuberosum`, `Medicago truncatula`, `Physcomitrium patens`, `Vitis vinifera`, `Populus trichocarpa`, `Eucalyptus grandis`, `Pinus taeda`, `Malus domestica`, `Citrus sinensis`, `Chlamydomonas reinhardtii`, `Homo sapiens`, `Xenopus laevis`, `Gallus gallus`, `Sus scrofa`, `Bos taurus`, `Macaca mulatta` |
| `system` | 128 | regex/word | `functional_validation`, `ribo_seq`, `atac_seq`, `multi_omics`, `breeding_genetics`, `multi_environment`, `single_cell`, `bulk_rnaseq`, `metabolomics_lipidomics`, `drosophila`, `livestock`, `mouse`, `cell_culture`, `growth_chamber`, `greenhouse`, `field` |
| `setting` | 8 | regex | `cell_culture`, `mouse`, `drosophila`, `livestock`, `growth_chamber`, `greenhouse`, `field` |
| `environment` | 9 | word | `greenhouse`, `field` |
| `assay` | 246 | word | `gwas`, `rnaseq`, `eqtl`, `atac_seq`, `ribo_seq`, `chip_seq`, `methylation`, `crispr`, `overexpression`, `complementation`, `heterologous`, `in_silico`, `qtl_mapping`, `lipidomics`, `small_rnaseq`, `single_cell`, `scatac_seq`, `amplicon`, `m6a_seq`, `long_read_rna`, `gbs`, `degradome`, `hic`, `medip`, `mnase_seq`, `nascent_rna`, `spatial`, `targeted_capture`, `rip_clip`, `metagenomics`, `pool_seq`, `bsa_seq`, `trap_seq`, `wgs`, `metabolomics` |
| `outcome` | 85 | regex/word | `grain_yield`, `flowering_time`, `plant_height`, `forage_yield`, `biomass`, `lifespan`, `wing_size`, `body_weight`, `leptin`, `microbiome`, `fasting_blood_glucose`, `firing_rate`, `viability`, `lipid_content`, `mechanical_threshold`, `leaf_growth`, `gene_expression`, `photosynthesis`, `disease_severity`, `behaviour`, `translation_efficiency`, `chromatin_accessibility`, `gca_sca` |
| `factor` | 154 | word | `water`, `nitrogen`, `phosphorus`, `temperature`, `co2`, `salt`, `light`, `diet`, `antibiotic`, `treatment`, `dose`, `sex`, `genotype`, `nutrient`, `injury`, `time`, `stage`, `age`, `tissue`, `cell_type`, `disease`, `infection`, `species`, `generation`, `soil`, `phenotype_group` |
| `genotype_noun` | 20 | word | `genotype` |
| `unit` | 126 | word | `plot`, `main_plot`, `plant`, `leaf`, `pot`, `tray`, `cell`, `chamber`, `cage`, `mouse`, `litter`, `pup`, `vial`, `fly`, `well`, `pool`, `tank`, `pen`, `flask`, `dish`, `bucket`, `herd`, `room`, `bioreactor`, `fish`, `embryo`, `animal` |
| `blocking` | 39 | word | `bench`, `shelf`, `batch`, `experimenter`, `cage`, `rearing_bottle`, `litter`, `donor`, `clutch`, `farm`, `herd` |
| `design` | 28 | word | `alpha`, `rcbd`, `split`, `augmented`, `prep`, `row_column`, `factorial`, `crd` |
| `mating` | 42 | word | `selfing`, `sib_mating`, `backcross`, `diallel`, `nc_design`, `testcross`, `biparental`, `nam`, `ril`, `dh` |
| `application` | 36 | word | `main_plot`, `distance_from_line`, `cage`, `dam`, `chamber`, `vial`, `individual`, `tray` |
| `check` | 7 | word | `check` |
| `cue` | 95 | regex | 95 named patterns (see the file; each row's note says what it detects) |
| `genotype_count_noun` | 12 | regex | regex noun counted as genotype entries ("120 lines") |
| `factor_synonym` | 20 | value | `genotype`, `water`, `treatment`, `tissue`, `time`, `stage` |
| `held_out_species` | 4 | value | `Setaria viridis`, `Populus trichocarpa`, `Danio rerio`, `Xenopus laevis` |
| `reps_noun` | 5 | regex | noun after a number that states replicates |
| `reps_noun_greenhouse` | 1 | regex | in a greenhouse, benches also state replicates |
| `location_noun` | 3 | regex | noun after a number that states locations |
| `season_noun` | 2 | regex | noun after a number that states seasons |
| `measured_unit_word` | 10 | value | `plant`, `pup`, `cell`, `leaf`, `mouse`, `well`, `fly` |
| `group_word` | 8 | value | "N per <group word>" states replicates, not subsamples |
| `not_experimental_unit` | 16 | value | word after "per" that is never the experimental unit |
| `not_measurement_unit` | 7 | value | word before "per" that is never the measured unit |
| `context_assay` | 2 | value | assays a system usually takes for granted; listed only where the registry says rnaseq_gwas_are_assays |
| `level_noun` | 50 | regex | noun after a number that counts levels of a factor |
| `genotype_noun_general` | 15 | regex | noun after a number that counts genotypes (general layer) |
| `tissue_word` | 32 | value | tissue words (plus tissues seen in the evidence tables) |
| `specific_factor` | 14 | value | factor words specific enough to count as stated without a number |
| `system_by_assay` | 9 | value | `bulk_rnaseq`, `atac_seq`, `ribo_seq`, `single_cell` |
| `unit_word_extra` | 10 | value | units that are never factors (besides the unit registry) |
| `method_assay` | 6 | value | how genotypes were made or analysed, not a measured assay |
| `stress_from_factor` | 9 | value | `drought`, `salt`, `nutrient`, `diet`, `light`, `disease`, `any` |
| `sequencer_name` | 20 | value | `NovaSeq`, `HiSeq`, `NextSeq`, `MiSeq`, `DNBSEQ`, `BGISEQ`, `MGISEQ`, `PacBio`, `PromethION`, `GridION`, `MinION`, `Nanopore`, `AVITI`, `Element AVITI`, `Ion Torrent`, `Sequel`, `Revio`, `X`, `Plus`, `Ten` |
| `tech_by_system` | 4 | value | `Bulk RNA-seq`, `scRNA/snRNA-seq`, `Ribo-seq`, `ATAC-seq` |
| `tech_by_assay` | 22 | value | `Bulk RNA-seq`, `small RNA-seq`, `scRNA/snRNA-seq`, `Ribo-seq`, `ATAC-seq`, `ChIP-seq`, `Bisulfite / methylome`, `scATAC-seq`, `Amplicon`, `m6A / MeRIP-seq`, `Long-read RNA (Iso-Seq/ONT)`, `GBS / RAD-seq`, `Degradome / PARE`, `3D genome (Hi-C/HiChIP)`, `Methylation (enrichment)`, `MNase-seq`, `Nascent RNA (GRO/PRO/NET)`, `Spatial transcriptomics`, `Targeted capture`, `RIP / CLIP-seq`, `TRAP-seq`, `WGS / resequencing` |
| `technique_system` | 8 | value | `bulk_rnaseq`, `single_cell`, `ribo_seq`, `atac_seq` |
| `technique_phrase` | 20 | value | `Bulk RNA-seq`, `3' Tag-seq`, `small RNA-seq`, `Long-read RNA (Iso-Seq/ONT)`, `scRNA/snRNA-seq`, `scATAC-seq`, `Ribo-seq`, `ATAC-seq` |
| `technique_outcome` | 12 | value | `Bulk RNA-seq`, `3' Tag-seq`, `Long-read RNA (Iso-Seq/ONT)`, `Ribo-seq`, `ATAC-seq` |
| `attribute_role` | 57 | value | `genotype`, `treatment`, `time`, `stage`, `age`, `tissue`, `disease`, `sex`, `batch`, `location` |
| `level_role` | 4 | regex | `genotype`, `time`, `treatment`, `tissue` |
| `role_noun` | 18 | value | `treatment`, `time`, `stage`, `age`, `tissue`, `disease` |
| `genotype_phrase` | 12 | value | `plant`, `animal`, `cell`, `micro` |
| `replicate_phrase` | 16 | value | `plant`, `animal`, `human`, `micro` |
| `tissue_singular` | 15 | value | `leaf`, `root`, `seedling`, `seed`, `shoot`, `flower`, `fruit`, `stem`, `whole plant`, `embryo`, `bud`, `panicle`, `berry`, `tuber` |
| `reader_system` | 16 | value | systems shown to the LLM reader, in prompt order |
| `reader_assay` | 35 | value | assays shown to the LLM reader, in prompt order |
| `reader_organism` | 36 | value | organisms shown to the LLM reader, in prompt order |
| `count_noun` | 18 | regex | `check`, `water`, `nitrogen`, `nutrient`, `diet`, `dose`, `treatment`, `per_cage`, `per_pen` |
| `assay_advice_family` | 2 | value | `metabolomics_lipidomics` |
| `generic_assay` | 7 | value | `methylation`, `single_cell`, `atac_seq`, `rnaseq` |
| `system_organism_group` | 8 | value | `animal`, `plant` |
| `taxon_group` | 4 | value | `plant`, `other` |
| `organ_also` | 4 | value | `leaf`, `whole plant` |
| `schema2_assay` | 18 | value | assays added to the label schema in version 2 (filled into older labels when stated) |
| `factor_rename` | 2 | value | `phenotype_group`, `genotype` |


Cues are named patterns the code asks for by name (`.sf_cue("housed_per_cage")`); each row's note says what it
detects. Extend a cue by editing its pattern; a new cue name does nothing until code uses it.

## Adding rows (yourself or with another AI)

1. Write the rows in a separate file, `proposed.tsv`, same six columns.
2. Check them: `python3 training/rules_tool.py check proposed.tsv`
   (unknown category, regex that does not compile, uppercase in a regex, conflicts with existing rows, new terms).
3. Add them: `python3 training/rules_tool.py add proposed.tsv`
4. Measure on the dev split (never the test split): `Rscript training/paper_questions/score.R`
   and run `tests/testthat/test-rules.R`. Keep the rows if dev recall does not drop and nothing is invented.

What makes a good row:

- **States what the text names, not a conclusion.** "dams fed" names maternal treatment; "dams" alone does not.
- **Specific.** A short abbreviation needs `\b...\b` and should not collide with common words (`asi` is also a word
  in other contexts).
- **Keeps distinct things distinct.** Days to anthesis (male flowering), days to silking (female) and the
  anthesis-silking interval are different maize traits: separate terms, not all `flowering_time`.
- **Uses an existing term** when one fits; a new term (a new outcome, a new unit) also needs the engine to know it.
- **Never a new category** without the code that reads it.

## Prompt for another AI

Upload `inst/agent/rules.tsv` (or paste the categories table above) and give it this:

> You are helping build StudyForge, a tool that turns a researcher's plain-language description of an
> experiment (plants, animals, cell culture, sequencing assays) into a structured experimental design.
> The attached rules.tsv is its vocabulary: one row per rule, six tab-separated columns
> `category  term  match  pattern  note  source`.
> - `match = word`: a literal phrase (alias) that, when found in the question, means `term`.
> - `match = regex`: a regular expression run on the lowercased question (`\b` word boundary, `|` or; never
>   uppercase letters).
> - `match = value`: a literal used by the code (word lists, lookups).
>
> Task: propose NEW rows for the categories **[e.g. outcome, assay, unit, organism]** in the domain
> **[e.g. maize field phenotyping / mouse metabolic studies / single-cell sequencing]**: synonyms,
> abbreviations, spelling variants and common phrasings researchers actually write.
> Rules:
> 1. Use only the existing categories. Prefer existing terms; if you need a new term, say why in `note`.
> 2. Prefer `word` rows; use `regex` only for abbreviations (`\bdta\b`) or when context is needed.
> 3. A row must describe what the text names, never a design conclusion (do not map "cage" to an
>    experimental unit decision; map it to the unit `cage`).
> 4. Do not merge different things under one term (days to anthesis != days to silking).
> 5. No duplicates of rows already in the file.
> 6. Put your name in `source` (e.g. `chatgpt`) and a short reason or example sentence in `note`.
> Output ONLY the new rows as tab-separated lines, no header, no commentary.

Every proposal goes through `rules_tool.py check`, then a dev-split measurement, before it is committed.
