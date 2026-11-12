#!/bin/bash
#SBATCH --job-name=llm-reader
#SBATCH --output=logs/llm-reader.%j.out
#SBATCH --error=logs/llm-reader.%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:l40s:1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=01:00:00
# Run the LLM reader on every test set (offline; model downloaded by retrieval/setup_cluster.sh).
# 32B reader on an H100:  READER=Qwen/Qwen2.5-32B-Instruct sbatch --gres=gpu:h100:1 llm/reader_eval.slurm
set -euo pipefail
BASE=${BASE:-/gpfs_common/share01/maize/ntanduk}
export HF_HOME=$BASE/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1
PY=$BASE/envs/biodes-gpu/bin/python
cd "$SLURM_SUBMIT_DIR"; mkdir -p logs llm/preds
nvidia-smi --query-gpu=name,memory.total --format=csv
$PY llm/reader.py --out llm/preds --raw --examples \
  inst/examples/study_examples.jsonl training/data/fresh_test.jsonl training/data/fresh_test_v2.jsonl \
  training/data/fresh_test_v3.jsonl training/data/fresh_test_v4.jsonl training/data/grounded_eval.jsonl \
  training/data/user_prompts_dev.jsonl
ls -la llm/preds
