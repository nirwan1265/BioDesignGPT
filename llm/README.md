# LLM reader

A local open model (Qwen2.5 via vLLM) reads a prompt and fills the StudySpec skeleton as JSON (`reader.py`).
It runs offline on the cluster's GPU nodes; nothing leaves NCSU.

## One-time setup (login node, needs internet)

    READER=Qwen/Qwen2.5-32B-Instruct bash retrieval/setup_cluster.sh /gpfs_common/share01/maize/ntanduk

This adds peft/accelerate to the env and downloads the 32B model (~65 GB) into the HF cache.

## Fine-tune the big reader (LoRA)

    sbatch llm/finetune.slurm          # 32B on one RTX 6000 Pro (96 GB); resubmits itself until done (max 6 rounds of 2 h)

Steps (each leaves a file, so a resubmitted job skips what is done):
1. `make_sft.py prompts`: ~4,000 labelled prompts. All 755 paraphrases, synthetic study types balanced by
   type x organism, and prompts built from real studies. Test prompts and the held-out species are excluded.
2. The base model reads them (self-distillation for the fields we have no labels for: method, tissue,
   levels, outcome text, questions).
3. `make_sft.py build`: targets = our labels + the distilled fields. Experimental unit only when the unit word
   is in the prompt; environments only when settings are compared.
4. `train_lora.py`: LoRA r=16 on all projection layers, answer tokens only, 1 epoch, checkpoints every 40
   steps, stops before the 2-hour limit and resumes.
5. Base and fine-tuned readers on every test set: `WORK/eval_base`, `WORK/eval_ft`.

Then compare: `Rscript llm/score.R WORK/eval_base WORK/eval_ft`. Keep the adapter only if it beats the base
model on the clean sets (fresh v4, v1, v2) without inventing values.

## Use it from R

    sbatch llm/reader_server.slurm     # keeps the model (+ adapter if trained) loaded for up to 2 h

The server writes `~/.biodes/reader.json` (url + token, readable by you only). R on the cluster finds it:

    studyforge_ask("I want to do a cre flux rat experiment for a gene of my choice", engine = "llm")

`engine = "auto"` uses the reader whenever one is running. If it isn't reachable, R falls back to rules with a
message. From a laptop, open the tunnel printed in `logs/biodes-reader.<job>.out`, then
`Sys.setenv(BIODES_READER_URL = "http://localhost:8765", BIODES_READER_TOKEN = "<token>")`.

## How its output is used

`merge_specs(rules, llm, question)`: the rules stay first, and the reader fills gaps only with **stated
facts**:

- organism, assays, tissue, method ("Cre-lox conditional knockout", "DGRP reference panel", "mutagenesis"),
  factors and their levels, outcome text
- numbers only if they appear in the prompt; a level count also counts as stated when every named level is
  in the text ("medicine ... placibo" -> 2 levels)
- a replicate number only if it sits next to a replication word, and not when it's a range ("two or three reps")

**Design judgments are not taken from the reader.** It doesn't choose the experimental unit, and it doesn't
pick a primary outcome when the prompt names several. The deterministic engine decides those or asks the
user. (`judgments = TRUE` turns this off, for comparison only.)

## Results (Qwen2.5-14B, field recall %, examples with an invented must-ask value in brackets)

| set | n | rules | LLM alone | rules + LLM | tiny tagger hybrid (round 5b) |
|---|---|---|---|---|---|
| study_examples (dev) | 59 | 92.7 (0) | 77.6 (11) | **94.3 (0)** | 94.0 |
| fresh v1 | 20 | 78.4 (0) | 84.0 (1) | **87.2 (0)** | |
| fresh v2 | 22 | 95.8 (0) | 67.8 (0) | **98.3 (0)** | |
| fresh v3 (dev) | 12 | 77.0 (0) | 73.8 (0) | **90.2 (0)** | 83.6 |
| fresh v4 (clean test) | 21 | 79.8 (0) | 84.0 (0) | **89.9 (0)** | 88.2 |
| grounded (held-out species) | 300 | 92.7 (0) | 88.5 (0) | **92.9 (0)** | 88.9 |

On its own, the LLM scores lower because it names fields its own way and makes design judgments
(11 invented values on study_examples, mostly experimental units). Merged as facts only, it beats rules alone
and the tiny tagger everywhere, with no invented values.

Re-score: put `preds_llm_*.json` in `llm/preds/` and run `merge_specs()` over each set with
`evaluate_extraction()`.
