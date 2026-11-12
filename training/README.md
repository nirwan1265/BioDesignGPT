# Training the StudyForge prompt tagger

A small BERT-style model that reads a researcher's description and tags the pieces StudyForge needs
(organism, counts of genotypes/checks/reps/locations/seasons, subsamples, measurement and experimental
units, factors and their levels, how a treatment is applied, outcome, blocking) plus the experimental
system. Tags are decoded into a StudySpec with the alias table (`inst/agent/aliases.tsv`).

This is **supervised learning**: the generator writes each sentence from labelled clause templates, so
every tag is correct by construction. The improvement loop is hard-example mining, not reinforcement
learning: find the sentence families with the most errors, generate more of them, retrain.

## Files

| File | Purpose |
|---|---|
| `generate.py` | Compositional synthetic data, 28 sentence families, hard negatives ("3 m rows", "two or three reps", "after flowering", "well-watered"), filler and case noise |
| `train.py` | Multi-task model: token tags + system class. Tiny BERT from scratch (CPU, no downloads) or `--base allenai/scibert_scivocab_uncased` |
| `mine_errors.py` | Per-family error on dev, writes upweighting for the next `generate.py` round |
| `paraphrase_ollama.py` | Free local-LLM paraphrases in 6 writing styles; kept only if every labelled span survives verbatim and no new numbers appear; resumable, parallel |
| `run_paraphrase_round.sh` | One command: generate -> paraphrase (Ollama) -> mix -> retrain -> score on held-out sets |
| `grounded.py` | Prompts grounded in real designed studies from the evidence layer (organism, assay, factors/levels, reps, environment); held-out species for testing |
| `run_grounded_round.sh` | One command: template + paraphrase + grounded data -> retrain -> score old vs new on every test set |
| `train_scibert.slurm` | HPC job: 20k examples, SciBERT fine-tune, predictions on both test sets |
| `../inst/python/` | Inference (`model.py`, `decode.py`, `predict.py`), shared by training and the R package |
| `../data-raw/fresh_test.json` | 20 prompts written before round-2 results and never used for tuning |

## Results

Field recall from `evaluate_extraction()` in hybrid mode (rules first, model fills gaps); "invented" = examples where a
value the user never stated (a must-ask field) was filled in. Current model: **round 5b**, tiny BERT (3 layers, 192 hidden),
trained on 14,000 template sentences + 782 Llama 3.1 paraphrases + 8,000 prompts grounded in real experiments
(`grounded.py`, built from ~19,000 designed studies in ENA/SRA/GEO across 30 species).

| Set | What it is | Round 4 | **Round 5b** |
|---|---|---|---|
| 59 paper examples | Used for error analysis (development) | 93.7% (2 invented*) | **94.0%** (2 invented*) |
| fresh v1 (20) | Plants/animals; written before round 2 | 91.2% | **91.2%** |
| fresh v2 (22) | Genetics, MET, multi-omics, validation; written before round 3 | 97.5% | **97.5%** |
| fresh v3 (12) | Written before round 4; **now a dev set** (read to find round-5 regressions) | 88.5% | 83.6% |
| **fresh v4 (21)** | **Written before round 5b, scored once: new species, every system, trait words that are not factors** | 70.6% | **88.2%, 0 invented** |
| **Grounded held-out (300)** | **Real studies of species never seen in training: zebrafish, xenopus, poplar, setaria** | 51.0% | **88.9%, 0 invented** |

\* Outcomes the user did write ("behavior assay", "body weight") that the labels treated as must-ask.

Known weakness: three v3 prompts got worse in round 5 (a photosynthesis outcome not tagged; "disease resistance gene"
and "seed oil content" read as factors). Round 5b added trait-context templates and outcome clauses; v3 did not recover,
so v4 is the honest estimate for new wording (~88%). A labmate-written test set is the next clean test.

Round 3 -> round 4 (paraphrases only): model alone v2 83.1 -> 91.5, v3 83.6 -> 85.2; hybrid v3 86.9 -> 88.5.
Round 4 -> round 5b (grounded data): hybrid v4 70.6 -> 88.2, held-out species 51.0 -> 88.9.

History: round 1 (5k sentences, 19 families) memorised templates (65% on the paper set). Round 2 added 9 families from error analysis plus filler/noise. Round 3 added 12 families and 5 new tags
(`GEN_N`, `PARENT_N`, `MATING`, `ASSAY`, `ENV`) for inbreeding, sib mating, backcrossing, diallel / NC II, RIL / NAM / DH populations, multi-environment trials, greenhouse-to-field validation,
GWAS + RNA-seq/eQTL, Ribo-seq, ATAC-seq and two-organism validation.

Known boundary: multi-location yield trials can be labelled `field` or `multi_environment`; in hybrid mode the rules decide.

## Reproduce

```bash
python -m venv sfenv && source sfenv/bin/activate && pip install torch transformers tokenizers
python training/generate.py --n 8000 --seed 1 --out training/data/train.jsonl
python training/generate.py --n 800  --seed 2 --out training/data/dev.jsonl
python training/train.py --train training/data/train.jsonl --dev training/data/dev.jsonl --out inst/models/sf-tiny --epochs 8
python inst/python/predict.py --model inst/models/sf-tiny --examples training/data/fresh_test.jsonl --out preds_fresh.json
```

```r
library(studyforge)
P <- jsonlite::read_json("preds_fresh.json")
fresh <- lapply(readLines("training/data/fresh_test.jsonl"), jsonlite::fromJSON, simplifyVector = FALSE)
evaluate_extraction(function(q) merge_specs(extract_spec_local(q), P[[q]], q), fresh)$field_recall
```

## Next steps

1. Fine-tune SciBERT on HPC (`sbatch training/train_scibert.slurm`); its pretraining knows words the tiny model has never seen ("von Frey", "bay", strain names).
2. Run `bash training/run_paraphrase_round.sh` on a machine with Ollama (needs downloads, so it cannot run in the Claude sandbox), then another `mine_errors.py` round.
3. Collect 50-100 prompts written by labmates, label them once, and keep them as the permanent test set.
4. Export to ONNX for an in-browser version (transformers.js) so nothing needs installing.
5. Mine more papers: each methods section becomes a realistic test prompt and, where needed, a new template family.
