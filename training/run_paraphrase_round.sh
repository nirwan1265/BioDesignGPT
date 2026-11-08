#!/usr/bin/env bash
# One full round: generate -> paraphrase with Ollama -> mix -> retrain -> score on held-out prompts.
# Run from the repo root on a laptop or an HPC node with Ollama installed.
#   bash training/run_paraphrase_round.sh            # defaults: 3000 sources x 2 variants, llama3.1
#   MODEL=qwen2.5:7b N=5000 WORKERS=4 bash training/run_paraphrase_round.sh
set -euo pipefail
MODEL=${MODEL:-llama3.1}
N=${N:-3000}
VARIANTS=${VARIANTS:-2}
WORKERS=${WORKERS:-2}
PY=${PY:-python}
D=training/data
mkdir -p "$D"

ollama list >/dev/null 2>&1 || { echo "Start Ollama first: ollama serve &"; exit 1; }
ollama pull "$MODEL"

$PY training/generate.py --n 14000 --seed 1 --out $D/train.jsonl
$PY training/generate.py --n 1200  --seed 2 --out $D/dev.jsonl
$PY training/paraphrase_ollama.py --inp $D/train.jsonl --out $D/para.jsonl --n "$N" --variants "$VARIANTS" --workers "$WORKERS" --model "$MODEL"

# mix: all template data + all paraphrases (shuffled)
$PY - <<'EOF'
import json, random
rows = [l for f in ("training/data/train.jsonl", "training/data/para.jsonl") for l in open(f)]
random.Random(0).shuffle(rows)
open("training/data/train_mix.jsonl", "w").writelines(rows)
print("training rows:", len(rows))
EOF

$PY training/train.py --train $D/train_mix.jsonl --dev $D/dev.jsonl --out inst/models/sf-tiny --epochs 8
for set in fresh_test fresh_test_v2; do
  $PY inst/python/predict.py --model inst/models/sf-tiny --examples $D/$set.jsonl --out $D/preds_$set.json
done
Rscript -e '
library(studyforge)
for (s in c("fresh_test", "fresh_test_v2")) {
  ex <- lapply(readLines(file.path("training/data", paste0(s, ".jsonl")), warn = FALSE), jsonlite::fromJSON, simplifyVector = FALSE)
  P <- jsonlite::read_json(file.path("training/data", paste0("preds_", s, ".json")))
  h <- evaluate_extraction(function(q) merge_specs(extract_spec_local(q), P[[q]], q), ex)
  cat(sprintf("%-14s hybrid recall %.1f%%, invented %d/%d\n", s, 100 * h$field_recall, h$examples_with_invented_values, length(ex)))
}'
echo "If both numbers beat the committed ones, commit inst/models/sf-tiny."
