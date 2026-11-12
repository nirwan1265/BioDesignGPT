#!/usr/bin/env bash
# One-time setup on the HPC LOGIN node (needs internet). Compute/GPU nodes then run fully offline.
#   bash retrieval/setup_cluster.sh /gpfs_common/share01/maize/ntanduk
# Creates:
#   <base>/envs/biodes-gpu      Python env with CUDA PyTorch, sentence-transformers, transformers, vLLM
#   <base>/hf                   model cache (HF_HOME): embedding model + reader LLM
set -euo pipefail
BASE=${1:?usage: setup_cluster.sh <base folder on shared storage>}
ENV=$BASE/envs/biodes-gpu
export HF_HOME=$BASE/hf
READER=${READER:-Qwen/Qwen2.5-14B-Instruct}       # 32B on an H100/H200: READER=Qwen/Qwen2.5-32B-Instruct
EMBED=${EMBED:-BAAI/bge-base-en-v1.5}
mkdir -p "$BASE/envs" "$HF_HOME"

if [ ! -x "$ENV/bin/python" ]; then
  echo "== creating $ENV"
  conda create -y -p "$ENV" python=3.11 >/dev/null
fi
echo "== installing packages (pip wheels bundle CUDA; no 'module load cuda' needed)"
"$ENV/bin/pip" install -q --upgrade pip
"$ENV/bin/pip" install -q vllm sentence-transformers transformers huggingface_hub numpy

echo "== downloading models into $HF_HOME"
"$ENV/bin/python" - <<EOF
from huggingface_hub import snapshot_download
for repo in ["$EMBED", "$READER"]:
    p = snapshot_download(repo_id=repo, allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "tokenizer*", "*.py"])
    print("  ", repo, "->", p)
EOF
du -sh "$HF_HOME"
echo "Done. Next: sbatch retrieval/build_index.slurm   (edit BASE/EVIDENCE at the top if your paths differ)"
