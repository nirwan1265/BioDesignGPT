#!/usr/bin/env bash
# Round 5: add prompts grounded in ~19,000 real experiments (the evidence layer), retrain, and
# compare the new model against the committed one on every held-out set. Run from the repo root.
#
#   EVIDENCE=~/Downloads/evidence bash training/run_grounded_round.sh
#   EVIDENCE=... GROUNDED_N=20000 EPOCHS=10 PY=~/sfenv/bin/python bash training/run_grounded_round.sh
#
# EVIDENCE must contain all_species_by_study.tsv, all_species_study_factors.tsv,
# all_species_study_methods.tsv and all_species_papers.tsv (from enrich_evidence.R combine).
# The new model goes to inst/models/sf-tiny-r5; the committed sf-tiny is never overwritten here.
set -euo pipefail
EVIDENCE=${EVIDENCE:?set EVIDENCE to the folder with the all_species_*.tsv files}
PY=${PY:-python}
GROUNDED_N=${GROUNDED_N:-8000}     # how many grounded prompts to mix with the template data
EPOCHS=${EPOCHS:-8}
HOLDOUT=${HOLDOUT:-$($PY -c 'import sys; sys.path.insert(0, "training"); import rules; print(",".join(rules.keys("held_out_species")))')}   # inst/agent/rules.tsv
D=training/data
NEW=inst/models/sf-tiny-r5
mkdir -p "$D"

echo "== 1/5 template data"
$PY training/generate.py --n 14000 --seed 1 --out $D/train.jsonl
$PY training/generate.py --n 1200  --seed 2 --out $D/dev.jsonl

echo "== 2/5 grounded data (held-out species: $HOLDOUT)"
$PY training/grounded.py --evidence "$EVIDENCE" --out $D --per-study 2 --seed 7 --holdout "$HOLDOUT"

echo "== 3/5 mix"
GROUNDED_N=$GROUNDED_N $PY - <<'EOF'
import json, os, random
R = random.Random(0)
d = "training/data"
tmpl = open(f"{d}/train.jsonl").readlines()
para = open(f"{d}/para.jsonl").readlines() if os.path.exists(f"{d}/para.jsonl") else []
gr = open(f"{d}/grounded_train.jsonl").readlines()
gr = R.sample(gr, min(int(os.environ["GROUNDED_N"]), len(gr)))
rows = tmpl + para + gr
R.shuffle(rows)
open(f"{d}/train_r5.jsonl", "w").writelines(rows)
dev = open(f"{d}/dev.jsonl").readlines() + open(f"{d}/grounded_dev.jsonl").readlines()
open(f"{d}/dev_r5.jsonl", "w").writelines(dev)
print(f"train: {len(tmpl)} template + {len(para)} paraphrase + {len(gr)} grounded = {len(rows)}; dev {len(dev)}")
EOF

echo "== 4/5 train -> $NEW"
$PY training/train.py --train $D/train_r5.jsonl --dev $D/dev_r5.jsonl --out $NEW --epochs "$EPOCHS"

echo "== 5/5 predict + score (old sf-tiny vs new sf-tiny-r5)"
SETS="inst/examples/study_examples.jsonl $D/fresh_test.jsonl $D/fresh_test_v2.jsonl $D/fresh_test_v3.jsonl $D/fresh_test_v4.jsonl $D/grounded_eval.jsonl"
for m in sf-tiny sf-tiny-r5; do
  for s in $SETS; do
    $PY inst/python/predict.py --model inst/models/$m --examples "$s" --out "$D/preds_${m}_$(basename "$s" .jsonl).json"
  done
done
Rscript - <<'EOF'
suppressMessages(if (requireNamespace("pkgload", quietly = TRUE)) pkgload::load_all(".", quiet = TRUE) else library(studyforge))
sets <- c(study_examples = "inst/examples/study_examples.jsonl", fresh_v1 = "training/data/fresh_test.jsonl",
          fresh_v2 = "training/data/fresh_test_v2.jsonl", fresh_v3 = "training/data/fresh_test_v3.jsonl",
          fresh_v4 = "training/data/fresh_test_v4.jsonl",
          grounded_heldout = "training/data/grounded_eval.jsonl")
res <- NULL
for (s in names(sets)) {
  ex <- lapply(readLines(sets[[s]], warn = FALSE), jsonlite::fromJSON, simplifyVector = FALSE)
  for (m in c("sf-tiny", "sf-tiny-r5")) {
    P <- jsonlite::read_json(sprintf("training/data/preds_%s_%s.json", m, tools::file_path_sans_ext(basename(sets[[s]]))))
    h <- evaluate_extraction(function(q) merge_specs(extract_spec_local(q), P[[q]], q), ex)
    res <- rbind(res, data.frame(set = s, model = m, n = length(ex), hybrid_recall = round(100 * h$field_recall, 1),
                                 invented = h$examples_with_invented_values))
  }
}
print(res, row.names = FALSE)
write.csv(res, "training/data/round5_scores.csv", row.names = FALSE)
cat("\nfresh_v3 was used to find the round-5 regressions, so it is a dev set now; fresh_v4 is the clean test.",
    "\nKeep sf-tiny-r5 only if it is at least as good on fresh_v4 and study_examples, better on grounded_heldout,",
    "\nand invents nothing. Then: rm -r inst/models/sf-tiny && mv inst/models/sf-tiny-r5 inst/models/sf-tiny\n")
EOF
