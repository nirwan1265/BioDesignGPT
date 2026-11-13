#!/bin/bash
#SBATCH --job-name=biodes-reader
#SBATCH --output=logs/biodes-reader.%j.out
#SBATCH --error=logs/biodes-reader.%j.err
#SBATCH --partition=gpu_partners
#SBATCH --qos=short_gpu
#SBATCH --gres=gpu:h200:1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=96G
#SBATCH --time=02:00:00
# Keep the big reader loaded and answer studyforge_ask(engine = "llm") from R.
# It writes ~/.biodes/reader.json (url + token, readable by you only); R on the cluster finds it there.
# From a laptop: the .out log prints the ssh tunnel command; then in R
#   Sys.setenv(BIODES_READER_URL = "http://localhost:8765", BIODES_READER_TOKEN = "<token from ~/.biodes/reader.json>")
# Uses the fine-tuned adapter when one exists (READER_ADAPTER=none to use the base model).
set -euo pipefail
BASE=${BASE:-/gpfs_common/share01/maize/ntanduk}
READER=${READER:-Qwen/Qwen2.5-32B-Instruct}
AD=${READER_ADAPTER:-$BASE/llm_ft/$(basename "$READER")/adapter}
[ "$AD" != none ] && [ -s "$AD/adapter_config.json" ] && ADARG="--adapter $AD" || ADARG=""
export HF_HOME=$BASE/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1
module load cuda 2>/dev/null || true
if command -v nvcc >/dev/null; then export CUDA_HOME=$(dirname "$(dirname "$(command -v nvcc)")"); fi
export VLLM_ATTENTION_BACKEND=${VLLM_ATTENTION_BACKEND:-FLASH_ATTN} VLLM_USE_FLASHINFER_SAMPLER=0
cd "$SLURM_SUBMIT_DIR"; mkdir -p logs
echo "== reader $READER ${ADARG:-(base model)} on $(hostname)"
exec $BASE/envs/biodes-gpu/bin/python llm/reader.py --serve --model "$READER" $ADARG --port 8765 --conn-file "$HOME/.biodes/reader.json"
