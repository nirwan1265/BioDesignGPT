#!/bin/bash
#SBATCH --job-name=sf-scibert
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=sf-scibert-%j.log
# Fine-tune SciBERT on the synthetic StudyForge data (edit partition/modules for your cluster).
set -euo pipefail
cd "$SLURM_SUBMIT_DIR"
# python -m venv sfenv && source sfenv/bin/activate && pip install torch transformers tokenizers
source sfenv/bin/activate

python training/generate.py --n 20000 --seed 1 --out training/data/train.jsonl
python training/generate.py --n 2000  --seed 2 --out training/data/dev.jsonl
python training/train.py --base allenai/scibert_scivocab_uncased --epochs 4 --bs 32 --lr 3e-5 \
  --train training/data/train.jsonl --dev training/data/dev.jsonl --out inst/models/sf-scibert
python inst/python/predict.py --model inst/models/sf-scibert --examples inst/examples/study_examples.jsonl --out preds_scibert_49.json
python inst/python/predict.py --model inst/models/sf-scibert --examples training/data/fresh_test.jsonl --out preds_scibert_fresh.json
