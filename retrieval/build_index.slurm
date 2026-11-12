#!/bin/bash
#SBATCH --job-name=paper-index
#SBATCH --output=logs/paper-index.%j.out
#SBATCH --error=logs/paper-index.%j.err
#SBATCH --partition=gpu
#SBATCH --gres=gpu:l40s:1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
# Embed every species' methods sections into index/<species>/ (offline; models were downloaded by
# setup_cluster.sh on the login node). Re-running skips finished shards, so new organisms are added
# by running it again. One species only: SPECIES=sorghum sbatch retrieval/build_index.slurm
set -euo pipefail
BASE=${BASE:-/gpfs_common/share01/maize/ntanduk}
EVIDENCE=${EVIDENCE:-$BASE/design/evidence}
INDEX=${INDEX:-$BASE/index}
export HF_HOME=$BASE/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
PY=$BASE/envs/biodes-gpu/bin/python
cd "$SLURM_SUBMIT_DIR"
mkdir -p logs
nvidia-smi --query-gpu=name,memory.total --format=csv
$PY retrieval/build_index.py --evidence "$EVIDENCE" --out "$INDEX" --device cuda --batch 256 ${SPECIES:+--species $SPECIES}
du -sh "$INDEX"
