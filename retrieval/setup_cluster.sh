#!/usr/bin/env bash
# One-time setup on the HPC LOGIN node (needs internet). Compute/GPU nodes then run fully offline.
#   bash retrieval/setup_cluster.sh /gpfs_common/share01/maize/ntanduk
# Creates:
#   $BIODES_ENV (required)   Python env with CUDA PyTorch, sentence-transformers, transformers, vLLM.
#       Kept on app storage, not the shared folder: an env is ~100k small files and the share caps the file count.
#   PIP_REQ=<file>  install exact versions from a 'pip list --format=freeze' file instead of the latest
#   SKIP_MODELS=1   do not touch the model cache
#   <base>/hf                   model cache (HF_HOME): embedding model + reader LLM
set -euo pipefail
BASE=${1:?usage: setup_cluster.sh <base folder on shared storage>}
ENV=${BIODES_ENV:?set BIODES_ENV to the env folder to create}
export HF_HOME=$BASE/hf
READER=${READER:-Qwen/Qwen2.5-14B-Instruct}       # the big reader: READER=Qwen/Qwen2.5-32B-Instruct (~65 GB)
EMBED=${EMBED:-BAAI/bge-base-en-v1.5}
mkdir -p "$(dirname "$ENV")" "$HF_HOME"
export PIP_NO_CACHE_DIR=1   # no pip cache in $HOME or on the share

if [ ! -x "$ENV/bin/python" ]; then
  echo "== creating $ENV"
  conda create -y -p "$ENV" -c conda-forge --override-channels python=3.11 pip
fi
if [ ! -x "$ENV/bin/pip" ]; then
  echo "== adding pip to $ENV"
  conda install -y -p "$ENV" -c conda-forge --override-channels pip || "$ENV/bin/python" -m ensurepip --upgrade
fi
PIP="$ENV/bin/python -m pip"
echo "== installing packages (pip wheels bundle CUDA; no 'module load cuda' needed)"
$PIP install -q --upgrade pip
if [ -n "${PIP_REQ:-}" ]; then
  $PIP install -r "$PIP_REQ"
else
  $PIP install vllm sentence-transformers transformers huggingface_hub numpy peft accelerate
fi
if [ "${SKIP_MODELS:-0}" = 1 ]; then echo "Done (models skipped). Python: $ENV/bin/python"; exit 0; fi

echo "== downloading models into $HF_HOME"
"$ENV/bin/python" - <<EOF
from huggingface_hub import snapshot_download
for repo in ["$EMBED", "$READER"]:
    p = snapshot_download(repo_id=repo, allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "tokenizer*", "*.py"])
    print("  ", repo, "->", p)
EOF
du -sh "$HF_HOME"
echo "Done. Next: sbatch retrieval/build_index.slurm   (edit BASE/EVIDENCE at the top if your paths differ)"
