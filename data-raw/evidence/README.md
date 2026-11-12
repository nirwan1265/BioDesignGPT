# Evidence layer scripts

Collect what published experiments actually did (design, replication, sequencing, methods) from public
metadata and open-access papers. Run on a machine with internet (an HPC login node is fine); compute nodes
without internet can run only `--resummarise` and `combine`.

| Script | Step |
|---|---|
| `harvest_evidence.R` | ENA/SRA run metadata + GEO protocols for 34 species, technique classifier, per-study summaries. `--fill-skipped` fetches the newest months of strategies over `MAX_RUNS`; `--resummarise` rebuilds summaries offline |
| `enrich_evidence.R` | Papers (GEO, BioProject, Europe PMC; searches cached), BioSample factor structures (plus sample-name parsing), methods extraction from open-access full text |
| `download_papers.R` | Saves the open-access full texts behind the evidence (local use only) |

```bash
export ENTREZ_KEY=...                       # NCBI key
Rscript harvest_evidence.R all evidence     # or a species list / group
Rscript enrich_evidence.R all evidence
Rscript enrich_evidence.R combine evidence  # -> evidence/all_species_*.tsv
```

The combined tables feed `training/grounded.py` (prompts grounded in real studies). Full texts and raw tables
are not committed; only extracted facts and DOIs are meant to ship with the package.
