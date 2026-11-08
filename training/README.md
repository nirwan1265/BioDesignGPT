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
| `train_scibert.slurm` | HPC job: 20k examples, SciBERT fine-tune, predictions on both test sets |
| `../inst/python/` | Inference (`model.py`, `decode.py`, `predict.py`), shared by training and the R package |
| `../data-raw/fresh_test.json` | 20 prompts written before round-2 results and never used for tuning |

## Results

Field recall from `evaluate_extraction()`; "invented" = examples where a value the user never stated (a must-ask field) was filled in.
Current model: round 3, tiny BERT (3 layers, 192 hidden, 7.5 MB), 14,000 synthetic sentences from 40 families, 8 epochs on 2 CPUs (~9 min).

| Set | What it is | Rules | Model alone | **Hybrid** |
|---|---|---|---|---|
| 59 paper examples | Used for error analysis (development) | 91.8% | 81.3% | **93.4%** (2 invented*) |
| fresh v1 (20) | Plants/animals; written before round 2 | 76.0% | 85.6% | **91.2%**, 0 invented |
| fresh v2 (22) | Genetics, MET, multi-omics, validation; written before round 3 | 94.1%** | 83.1% | **97.5%**, 0 invented |
| **fresh v3 (12)** | **Written after all code, scored once, no changes since** | 73.8% | 83.6% | **86.9%, 0 invented** |

\* Outcomes the user did write ("behavior assay", "body weight") that the labels treated as must-ask.
\*\* Not a clean number: some round-3 rule patterns were written after reading v2. v3 exists because of that, and it is the honest estimate for new wording (~87%).

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
