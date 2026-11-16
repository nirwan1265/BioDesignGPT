# LLM reader

A local open model (Qwen2.5 via vLLM) reads a prompt and fills the StudySpec skeleton as JSON (`reader.py`).
It runs offline on the cluster's GPU nodes; nothing leaves NCSU.

## One-time setup (login node, needs internet)

    READER=Qwen/Qwen2.5-32B-Instruct bash retrieval/setup_cluster.sh /gpfs_common/share01/maize/ntanduk

This adds peft/accelerate to the env and downloads the 32B model (~65 GB) into the HF cache.

## Fine-tune the big reader (LoRA)

    sbatch llm/finetune.slurm          # 32B on one RTX 6000 Pro (96 GB); resubmits itself until done (max 6 rounds of 2 h)

Steps (each leaves a file, so a resubmitted job skips what is done):
1. `make_sft.py prompts`: ~5,300 labelled prompts. All 760 paper questions (hand-labelled training pool) and
   755 paraphrases, synthetic study types balanced by type x organism, and prompts built from real studies.
   Test prompts (including paper-question dev/test) and the held-out species are excluded. Every gold spec is
   put on one system convention (stated setting = system, assay in assays; `training/setting.py`).
2. The base model reads them (self-distillation for the fields we have no labels for: method, tissue,
   levels, outcome text, questions).
3. `make_sft.py build`: targets = our labels + the distilled fields. Experimental unit only when the unit word
   is in the prompt. A missing unit label is not a null, because most paper and real-study prompts were never
   labelled for the unit. There the target takes the base model's unit if that word is in the prompt, and stays
   null only when the unit is must-ask or no stated word names one. The build log prints the unit sources.
   Environments only when settings are compared.
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

## Current reader: 32B + v2 adapter (chosen on paper-question dev)

v2: LoRA r=16, alpha 32, lr 1e-4, 1 epoch on 5,126 examples (including the paper-question training pool),
val loss 0.045. Both readers were scored with today's labels and merge, so the columns compare directly.

| set | n | rules | base alone | base + rules | **v2 alone** | **v2 + rules** |
|---|---|---|---|---|---|---|
| paper questions dev | 328 | 64.7 | 85.6 | 87.3 | 86.0 | 86.6 |
| study_examples (dev) | 59 | 92.7 | 82.2 | 94.6 | 85.8 | 94.6 |
| fresh v1 | 20 | 83.2 | 85.6 | 90.4 | 88.8 | **96.0** |
| fresh v2 | 22 | 95.8 | 78.8 | 98.3 | 91.5 | 98.3 |
| fresh v3 (dev) | 12 | 77.0 | 82.0 | 91.8 | **96.7** | 93.4 |
| fresh v4 (clean test) | 21 | 86.6 | 89.9 | 96.6 | 93.3 | **97.5** |
| grounded (held-out species) | 300 | 98.2 | 81.7 | 99.0 | 98.1 | 99.1 |

Invented must-ask values on paper-question dev: rules 4; base 13 alone / 8 merged; v2 5 alone / 8 merged. On
every other set, the merged columns have 0, except base on study_examples (1).

Choice: on dev the two are within noise. Paired bootstrap over questions, v2 - base: merged -0.7 (95% CI -1.8 to
+0.4), alone +0.4 (-1.1 to +1.9). v2 is kept because it invents less on its own and because it meets the
keep-the-adapter rule (fresh v1/v2/v4 equal or better, 0 invented). v2 is weaker on the experimental unit
(17/24 vs 20/24 on dev) and on factor levels (73.1 vs 76.6 merged): the targets for the next training round.
The v1 numbers below were scored before the one-system label convention, so they don't compare directly with
this table.

**v3 (not adopted).** Same recipe on 5,951 examples (the 1,619-question paper pool), val loss 0.045. On dev it
is within noise of v2: merged 86.3 vs 86.6 (v3 - v2 = -0.3, 95% CI -1.0 to +0.4), alone 86.6 vs 86.0 (+0.6,
-0.3 to +1.6), 5 / 8 invented like v2. The merged columns on the other sets equal v2's to the decimal (94.6,
96.0, 98.3, 93.4, 97.5, 99.1). The extra paper questions did not move the reader, so v2 stays. What remains
is in the merge and the targets, not the amount of data:
- factor levels: reader alone 78.0 but merged 72.4 (v3 on dev). The merge drops levels the reader had right.
- experimental unit: base 21/24, v2 and v3 17/24. All 24 dev gold units are written in the prompt, so the
  cause was not the "stated only" rule. Of the 1,619 paper questions, 927 mention a unit word but carry no unit
  label, and so do all grounded prompts. Each of those became a null unit target, which taught the reader to
  leave stated units out. This is fixed in `make_sft.py` for v4 (step 3 above). The rules' "per two-row plot"
  read "two" as the unit; that is fixed too (dev unit, merged: 70.8 -> 75.0).

**Merge fixes (tuned on dev only, v2 reader).** Merged recall on dev went from 86.6 to 87.4. Invented values
went from 8 to 1, and rules alone from 4 to 1. Factor name + levels merged went from 73.1 to 76.2 (reader
alone 76.8). Replicates merged: 94.8. The other sets are unchanged or better: study_examples 94.9,
fresh v1 96.0, v2 98.3, v3 93.4, v4 97.5, held-out species 99.1, all with 0 invented. The test splits were not
re-scored.

**v4 (not adopted).** Same recipe on 5,951 examples, with the new unit targets (an unlabelled unit takes the
base model's unit when that word is in the prompt), val loss 0.047. Results on dev, current merge:

| | v2 | v4 |
|---|---|---|
| merged | 87.5 | 87.5 (v4 - v2 = +0.0, 95% CI -0.7 to +0.7) |
| alone | 86.0 | 87.0 (+1.0, CI +0.0 to +2.0) |
| experimental unit, merged | 18/24 | 21/24 |
| invented, alone | 5 (all replicate counts) | 9 (3 replicate counts, 6 units) |
| invented, merged | 1 | 2 |

The other sets are equal or slightly lower (fresh v1 95.2 vs 96.0, held-out species 99.0 vs 99.1). The unit
targets overshoot. A unit the prompt only mentions ("wells", "cage") is often the very thing the question
asks about, so v4 learned to fill it in. Next time, a distilled unit should be kept only when the prompt
counts it as the replicate ("3 pots per treatment"), which is the same test the merge applies.

**New-kinds test** (`training/paper_questions/newkinds/`: 100 questions from study kinds never trained on;
scored, never tuned on):

| | rules | base | v2 | v4 |
|---|---|---|---|---|
| alone | 64.7 | 82.7 (13 inv) | **84.8** (2 inv) | 83.4 (6 inv) |
| merged | | 83.2 (7 inv) | **84.1** (6 inv) | 82.2 (7 inv) |

The fine-tuned reader carries over to unseen kinds (v2 beats base and invents far less), but the new kinds are
harder than dev (v2 merged 84.1 vs 87.5). The weakest kinds are human cohorts (61) and mapping (78). That is
the case for labelling training questions of these kinds; the test set measures whether it helps.

**v5 (not adopted).** v4's recipe with two changes: a distilled unit is kept only when `unit_counted` passes,
and 289 round-1 training questions were added from the new kinds' study types (`training/paper_questions/rounds/`;
the 100 test papers are excluded). Val loss 0.049.

| | v2 | v5 |
|---|---|---|
| dev merged | 87.5 | 87.8 (v5 - v2 = +0.3, CI -0.5 to +1.0) |
| dev alone | 86.0 | 87.2 (+1.2, CI +0.2 to +2.2) |
| dev invented, alone / merged | 5 / 1 | 8 / 3 |
| new kinds merged | 84.1 | 82.9 (-1.2, CI -2.8 to +0.2) |
| new kinds, human cohorts merged | 61.0 | 55.8 |
| new kinds, mapping merged | 77.8 | 72.7 |

The other sets are equal or lower (fresh v2 97.5 vs 98.3). Round 1 did not help the kinds it targeted, so
round 2 is not worth doing. Most of the change on new kinds is in factor names, not facts: v5 says
`phenotype_group` where the label says `disease`, and the conventions allow either name. The misses in mapping
are mostly the assay (`qtl_mapping` / `bsa_seq` vs `wgs`) and `population.mating`. Those are naming conventions
the reader has to guess, and adding more papers does not teach them.

**Naming conventions (rules, no retraining).** Three fixes, tuned on dev and train, then the new-kinds test
scored once:
- Subject groups: a factor of groups is `disease` when a health state formed them and `phenotype_group` when a
  ranked trait did (`group_by_health` / `group_by_trait` cues). 33 training labels that broke this were
  relabelled; dev and the test splits are unchanged.
- Mapping assays: "mapping" in a segregating population is `qtl_mapping`; sequenced bulks or pools of progeny
  are `bsa_seq`; these are listed in any setting, not only breeding studies.
- Mating: the stated population (F2, backcross, RILs, DH ...) sets `population.mating` in any setting.

| | before | after |
|---|---|---|
| dev, v2 merged | 87.5 | 87.8 |
| train, rules: population.mating | 20.0 | 95.0 |
| new kinds, v2 merged | 84.1 | **86.2** |
| new kinds, human cohorts (v2 merged) | 61.0 | 72.7 |
| new kinds, mapping (v2 merged) | 77.8 | 82.8 |
| new kinds, rules alone | 64.7 | 66.6 |

"self" is kept as a selfing cue, minus the forms that are not a selfing population (self-administration, self-grafted, self-sampled, self-renewal, self-compatibility); the exclusions are in the rule itself. Fresh v3 is back to 93.4.

    Rscript training/paper_questions/score.R dev llm/preds WORK/eval_base WORK/eval_ft   # dev, field by field
    Rscript llm/score.R WORK/eval_base WORK/eval_ft                                      # the other sets

## v1 results (field recall %; every merged column has 0 invented must-ask values)

| set | n | rules | 14B alone | 14B + rules | 32B alone | 32B + rules | **32B fine-tuned alone** | **32B fine-tuned + rules** |
|---|---|---|---|---|---|---|---|---|
| study_examples (dev) | 59 | 92.7 | 77.6 | 94.3 | 80.4 | 94.0 | 90.6 | 94.0 |
| fresh v1 | 20 | 80.0 | 84.0 | 88.0 | 83.2 | 88.8 | 92.0 | **94.4** |
| fresh v2 | 22 | 95.8 | 67.8 | 98.3 | 77.1 | 98.3 | 94.9 | 97.5 |
| fresh v3 (dev) | 12 | 77.0 | 73.8 | 90.2 | 80.3 | 90.2 | **96.7** | 91.8 |
| fresh v4 (clean test) | 21 | 84.9 | 84.0 | 95.0 | 92.4 | 95.8 | 95.0 | 95.8 |
| grounded (held-out species) | 300 | 97.8 | 88.5 | 98.7 | 92.3 | 98.6 | 98.6 | 98.6 |

Fine-tuning (LoRA r=16, 4,396 examples, 1 epoch, val loss 0.047) mostly helps the reader **on its own**
(v2 77 -> 95, v3 80 -> 97, held-out species 92 -> 99). With the rules, the test sets go v1 +5.6, v4 equal,
v2 -0.8. **Rules-first stays:** reader-first wins on the dev sets (study_examples 94.9, v3 96.7) but loses on
v2/v4, so it doesn't generalise yet.

The fine-tuned reader added two kinds of judgments the facts-only merge now refuses:
- an outcome it inferred ("track growth" -> biomass): an outcome must be named in the question
- a setting that doesn't fit the organism (a hospital trial as the animal-facility "mouse" system): plant
  settings aren't for animals, the animal facility isn't for people or plants, vials are for flies

The base 32B (no fine-tuning) reads much better on its own than the 14B (v4 92.4 vs 84.0). Where it beat the
merge, the rules had real bugs, fixed as general rules:
- spelled numbers above twelve ("thirty-six")
- "N units per <treatment group>" states replication ("6 pigs per diet")
- every "per" phrase is read ("15 flies per vial and 10 vials per diet")
- flies -> fly

Re-score: put `preds_llm_*.json` in `llm/preds/` and run `merge_specs()` over each set with
`evaluate_extraction()`.
