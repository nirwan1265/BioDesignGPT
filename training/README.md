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
| `paraphrase_ollama.py` | Free local-LLM paraphrases that must keep every labelled span verbatim (others are discarded) |
| `train_scibert.slurm` | HPC job: 20k examples, SciBERT fine-tune, predictions on both test sets |
| `../inst/python/` | Inference (`model.py`, `decode.py`, `predict.py`), shared by training and the R package |
| `../data-raw/fresh_test.json` | 20 prompts written before round-2 results and never used for tuning |

## Results (tiny BERT from scratch, 3 layers, 192 hidden, 7 MB, trained on CPU in ~4 min)

Field recall from `evaluate_extraction()`; "invented" = examples where a must-ask value was filled.

| Extractor | 49 paper examples (used for error analysis) | 20 fresh prompts (untouched test) |
|---|---|---|
| Rules (`extract_spec_local`) | 92.1%, invented 0 | 76.0%, invented 0 |
| Tagger alone | 82.3%, invented 4 | 83.2%, invented 1 |
| **Hybrid** (rules first, tagger fills gaps, numbers must appear in the prompt) | **93.9%**, invented 3* | **92.0%, invented 0** |

\* The remaining cases are outcomes the user actually wrote ("behavior assay", "body weight") that the labels treated as must-ask.

Round 1 (5,000 examples, 19 families) scored only 65% on the 49 examples: the model memorised templates.
Round 2 added 9 families from the error analysis, fillers and noise (8,000 examples). Because round 2 was
designed from errors on the 49 examples, they are a development set; the 20 fresh prompts are the honest
test. Note: the merge guards (rep counts need a replication word; outcomes must be known terms) were added
after looking once at hybrid errors on all 69 prompts. A new, unseen set is needed for the next claim.

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
2. Run `paraphrase_ollama.py` to add natural variation, then another `mine_errors.py` round.
3. Collect 50-100 prompts written by labmates, label them once, and keep them as the permanent test set.
4. Export to ONNX for an in-browser version (transformers.js) so nothing needs installing.
5. Mine more papers: each methods section becomes a realistic test prompt and, where needed, a new template family.
