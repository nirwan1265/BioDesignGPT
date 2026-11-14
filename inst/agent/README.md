# Rule files

Everything the extractor, the label tools and the reader know about words lives in data, not code:

- `rules.tsv`: one rule per row (`table`, `key`, `value`, `note`). Order within a table is priority.
  `cue` rows are named patterns the code looks up by name; `{N}` in a cue means a number (digits or a word).
- `aliases.tsv`: vocabulary, alias -> canonical term, by category (organism, assay, factor, unit ...).
- `../registry/experimental_systems.json`: what each system is (setting / assay family / study type) and its flags.

R reads them through `.sf_rules()`, `.sf_cue()`, `.sf_list()`, `.sf_map()`, `.sf_group()`, `.sf_systems_where()`
(R/registry.R); Python through `training/rules.py`. To teach the system a new word, add a row; `tests/testthat/test-rules.R`
checks that every table and cue the code asks for exists and that every pattern compiles.

Kept in code on purpose: English grammar (number words, prepositions, plural endings) and the design engine's
decisions, which act on canonical ids (`field`, `rcbd`, `genotype`), not on words.

| table | rows | what it holds |
|---|---|---|
| `organism` | 12 | regex; first match in this order wins |
| `system` | 16 | regex cue for a system; order = priority |
| `setting` | 8 | regex: setting named outright; beats the assay family; order = priority |
| `outcome` | 16 | regex for a named primary outcome |
| `genotype_noun` | 12 | regex noun counted as genotype entries ("120 lines") |
| `factor_synonym` | 20 | factor name -> canonical factor name |
| `held_out_species` | 4 | species kept out of all training; scored as unseen organisms |
| `cue` | 95 | "two mutants vs the wild type" ({N} = a number) |
| `reps_noun` | 5 | noun after a number that states replicates |
| `reps_noun_greenhouse` | 1 | in a greenhouse, benches also state replicates |
| `location_noun` | 3 | noun after a number that states locations |
| `season_noun` | 2 | noun after a number that states seasons |
| `measured_unit_word` | 10 | word in "N <word> per ..." -> measured unit |
| `group_word` | 8 | "N per <group word>" states replicates, not subsamples |
| `not_experimental_unit` | 16 | word after "per" that is never the experimental unit |
| `not_measurement_unit` | 7 | word before "per" that is never the measured unit |
| `context_assay` | 2 | assays a system usually takes for granted; listed only where the registry says rnaseq_gwas_are_assays |
| `level_noun` | 50 | noun after a number that counts levels of a factor |
| `genotype_noun_general` | 15 | noun after a number that counts genotypes (general layer) |
| `tissue_word` | 32 | tissue words (plus tissues seen in the evidence tables) |
| `specific_factor` | 14 | factor words specific enough to count as stated without a number |
| `system_by_assay` | 9 | assay -> its assay-family system |
| `unit_word_extra` | 10 | units that are never factors (besides the unit registry) |
| `method_assay` | 6 | how genotypes were made or analysed, not a measured assay |
| `stress_from_factor` | 9 | factor -> the stress it implies (trait suggestions) |
| `sequencer_name` | 20 | instrument word -> display name |
| `tech_by_system` | 4 | system -> evidence-table technique label |
| `tech_by_assay` | 22 | assay -> evidence-table technique label |
| `technique_system` | 8 | evidence technique -> assay-family system (grounded prompts) |
| `technique_phrase` | 20 | how a prompt names the technique (one row per phrase; repeats weight the choice) |
| `technique_outcome` | 12 | outcome a technique implies (grounded prompts) |
| `attribute_role` | 57 | BioSample attribute -> factor role |
| `level_role` | 4 | regex on level values -> factor role (sample-name factors); order = priority |
| `role_noun` | 18 | how a prompt names a factor of this role |
| `genotype_phrase` | 12 | how a prompt names genotypes, by organism kind |
| `replicate_phrase` | 16 | how a prompt names replicates, by organism kind |
| `tissue_singular` | 15 | tissue word -> singular form |
| `reader_system` | 16 | systems shown to the LLM reader, in prompt order |
| `reader_assay` | 35 | assays shown to the LLM reader, in prompt order |
| `reader_organism` | 36 | organisms shown to the LLM reader, in prompt order |
| `count_noun` | 18 | noun after a number that counts check entries |
| `assay_advice_family` | 2 | assay -> system whose advice it brings (not used to set the system) |
| `generic_assay` | 7 | a specific assay stands in for this generic label (not both unless both are said) |
| `system_organism_group` | 8 | organism group a system implies (trait suggestions) |
| `taxon_group` | 4 | evidence-table taxon group -> trait group (anything else: animal) |
| `organ_also` | 4 | traits of these organs also apply |
| `schema2_assay` | 18 | assays added to the label schema in version 2 (filled into older labels when stated) |
| `factor_rename` | 2 | factor names renamed in label schema 2 |
