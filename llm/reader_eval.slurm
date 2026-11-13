#!/bin/bash
#SBATCH --job-name=llm-reader
#SBATCH --output=logs/llm-reader.%j.out
#SBATCH --error=logs/llm-reader.%j.err
#SBATCH --partition=gpu_partners
#SBATCH --qos=short_gpu
#SBATCH --gres=gpu:l40s:1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=01:00:00
# Run the LLM reader on every test set (offline; model downloaded by retrieval/setup_cluster.sh).
# short_gpu QOS (<2 h) is shared by everyone; if the l40s are all taken, other cards work too:
#   sbatch --gres=gpu:h200:1 llm/reader_eval.slurm         (141 GB; also fits READER=Qwen/Qwen2.5-32B-Instruct)
#   sbatch --gres=gpu:h100:1 llm/reader_eval.slurm         (80 GB)
# The 14B model needs ~30 GB, so not a10/a30 (24 GB) unless READER=Qwen/Qwen2.5-7B-Instruct.
set -euo pipefail
BASE=${BASE:-/gpfs_common/share01/maize/ntanduk}
export HF_HOME=$BASE/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1
# vLLM may JIT-compile FlashInfer kernels, which needs nvcc: load the cluster CUDA if there is one,
# and use the FlashAttention / PyTorch paths that need no compiler either way
module load cuda 2>/dev/null || true
if command -v nvcc >/dev/null; then export CUDA_HOME=$(dirname "$(dirname "$(command -v nvcc)")"); fi
export VLLM_ATTENTION_BACKEND=${VLLM_ATTENTION_BACKEND:-FLASH_ATTN} VLLM_USE_FLASHINFER_SAMPLER=0
PY=$BASE/envs/biodes-gpu/bin/python
cd "$SLURM_SUBMIT_DIR"; mkdir -p logs llm/preds
nvidia-smi --query-gpu=name,memory.total --format=csv
echo "nvcc: $(command -v nvcc || echo none)  attention: $VLLM_ATTENTION_BACKEND"
$PY llm/reader.py --out llm/preds --raw --examples \
  inst/examples/study_examples.jsonl training/data/fresh_test.jsonl training/data/fresh_test_v2.jsonl \
  training/data/fresh_test_v3.jsonl training/data/fresh_test_v4.jsonl training/data/grounded_eval.jsonl \
  training/data/user_prompts_dev.jsonl training/paper_questions/splits/dev.jsonl
ls -la llm/preds
