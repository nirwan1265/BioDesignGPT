# Generated word tables

Same columns as `inst/agent/rules.tsv`; read after it (R/registry.R, inst/python/rulebook.py), so hand-written rows
keep priority. Do not edit by hand: change the filters in the generator and rebuild.

`ontology_terms.tsv` — `python3 tools/import_ontologies.py ext.obo po.obo go-basic.obo`
(filters and reasons are in the script's docstring; rejected words in `docs/vocab_review/`)

| Category | Source | Release | License |
|---|---|---|---|
| tissue_word | UBERON extended (`ext.obo`), anatomy, no life stages | 2026-11-05 | CC-BY 3.0 |
| tissue_word | Plant Ontology (`po.obo`), plant_anatomy | 2026-01-09 | CC-BY 4.0 |
| cell_type_word | Cell Ontology (in UBERON ext) | 2026-11-05 | CC-BY 4.0 |
| fraction_word | Gene Ontology (`go-basic.obo`), organelle subtree | 2026-07-26 | CC-BY 4.0 |

The `source` column holds each word's ontology id. Cite: Mungall et al. 2012 Genome Biol 13:R5 (UBERON);
Diehl et al. 2016 J Biomed Semantics 7:44 (CL); Cooper et al. 2013 Plant Cell Physiol 54:e1 (PO);
Gene Ontology Consortium 2023 Genetics 224:iyad031 (GO).
