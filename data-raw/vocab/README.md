# Organism vocabulary

`build_vocab.py` writes `inst/vocab/organism_names.tsv`: every name that identifies one of our 34 organisms,
built from sources instead of typed by hand.

| source | what it adds |
|---|---|
| NCBI Taxonomy (`taxdump.tar.gz`) | scientific names, synonyms, common names of each species and every taxon below it, "Z. mays" abbreviations |
| our harvested studies (BioSample/SRA) | strain, cultivar, ecotype, breed and cell-line values: B73, Col-0, C57BL/6J, Sprague-Dawley, HEK293T |
| `inst/agent/rules.tsv` | curated organism rows (word rows); they win any conflict |

The same filters apply to every organism: missing-value markers ("not applicable", "wild type") are dropped;
so are very short or numeric tokens ("SD", "X1"), descriptions over 5 words, values used as tissue, stage,
treatment or sex labels ("serum", "E14"), values seen in fewer than 2 studies, and values with under 90% of
their studies in one organism.

Who uses it: `retrieval/label_organisms.py` uses every name. The R extractor (`.sf_alias_table()`) uses
taxonomy names plus strain names that can't pass for everyday words (with a digit, hyphen, slash or space,
seen in at least 3 studies), so "Atlantic" or "Jack" in a prompt is never read as a cultivar.

Run on a login node (downloads the ~65 MB taxdump once):

    python data-raw/vocab/build_vocab.py --evidence <folder with all_species_*.tsv> --cache <folder>

Offline: `--taxdump path/to/taxdump.tar.gz`, or `--no-taxonomy` (the committed file may be built this way).
