# New-kinds test set

100 questions from study kinds that were skipped while labelling the training pool. They test whether the reader
handles kinds of question it has never been trained on, which dev and test cannot show: those come from the
same pool as the training questions.

| kind | n | what |
|---|---|---|
| mapping | 20 | GWAS, QTL, bulk segregant, eQTL, MAGIC, introgression lines |
| mutant_lines | 20 | knockouts, mutants, transgenic and overexpression lines |
| population | 15 | population genomics, experimental evolution, mutation accumulation |
| human_cohort | 15 | patient and observational cohorts, trials (and a few animal cohorts) |
| atlas | 15 | developmental series, time courses, tissue and cell atlases |
| cell_lines | 15 | cell lines, primary cultures, stem cells, in vitro screens |

- `kinds.tsv`: the kinds, their quotas and the skip-reason patterns.
- `select.py` drew the candidates with seed 2026 → `selected.json`. It drew 1.5x each quota, round-robin over
  species. Candidates are labelled in rank order. Those that can't give a fair design question are dropped,
  with the reason in the label file.
- `CONVENTIONS.md`: how each kind is labelled. The same conventions apply when training questions of these
  kinds are labelled later.
- `labels/nk_<kind>.py` → `python3 build.py` writes `../splits/test_newkinds.jsonl` and freezes its membership
  in `MANIFEST.json`.
- `validate.py` and `build.py` refuse any of these papers being labelled in `../batches`, so they never enter
  training. `llm/make_sft.py` also excludes the prompts.

Score it, but never tune on it:

    Rscript training/paper_questions/score.R test_newkinds llm/preds_newkinds_v2 llm/preds_newkinds_v4

Rules alone (2026-11-14): 64.7% field recall (dev 64.7%), invented a must-ask value in 5 of 100 questions
(dev 1 of 328). By kind: mapping 65.7, mutant lines 65.9, population 65.3, atlas 57.0, cell lines 52.9,
human cohort 33.8.
