# LLM reader

A local open model (Qwen2.5-14B-Instruct via vLLM, no fine-tuning) reads a prompt and fills the StudySpec
skeleton as JSON (`reader.py`). It runs offline on a GPU node (`sbatch llm/reader_eval.slurm`).

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
