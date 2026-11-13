#!/bin/bash
#SBATCH --job-name=biodes-ft
#SBATCH --output=logs/biodes-ft.%j.out
#SBATCH --error=logs/biodes-ft.%j.err
#SBATCH --partition=gpu_partners
#SBATCH --qos=short_gpu
#SBATCH --gres=gpu:rtx_6000_pro:1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=160G
#SBATCH --time=02:00:00
# Fine-tune the reader end to end, in as many 2-hour jobs as it takes (each job resubmits the next):
#   1 sample labelled prompts          llm/make_sft.py prompts
#   2 base model reads them (distil)   llm/reader.py --examples prompts.jsonl
#   3 build training targets           llm/make_sft.py build
#   4 LoRA training (resumable)        llm/train_lora.py
#   5 evaluate base and fine-tuned     llm/reader.py on every test set -> WORK/eval_base, WORK/eval_ft
# Every finished step leaves a file, so a resubmitted job skips it.
#   sbatch llm/finetune.slurm                                   (32B on an RTX 6000 Pro, 96 GB)
#   READER=Qwen/Qwen2.5-14B-Instruct sbatch --gres=gpu:l40s:1 llm/finetune.slurm
set -euo pipefail
T0=$(date +%s); DEADLINE=$(( T0 + 115 * 60 ))
left() { echo $(( DEADLINE - $(date +%s) )); }
BASE=${BASE:-/gpfs_common/share01/maize/ntanduk}
READER=${READER:-Qwen/Qwen2.5-32B-Instruct}
WORK=${WORK:-$BASE/llm_ft/$(basename "$READER")}
ROUND=${ROUND:-1}; MAX_ROUNDS=${MAX_ROUNDS:-6}
export HF_HOME=$BASE/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1 TOKENIZERS_PARALLELISM=false
module load cuda 2>/dev/null || true
if command -v nvcc >/dev/null; then export CUDA_HOME=$(dirname "$(dirname "$(command -v nvcc)")"); fi
export VLLM_ATTENTION_BACKEND=${VLLM_ATTENTION_BACKEND:-FLASH_ATTN} VLLM_USE_FLASHINFER_SAMPLER=0
PY=$BASE/envs/biodes-gpu/bin/python
cd "$SLURM_SUBMIT_DIR"; mkdir -p logs "$WORK"
echo "== round $ROUND  reader $READER  work $WORK"; nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

next() {   # resubmit this pipeline with the same GPU request
  if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then echo "!! $MAX_ROUNDS rounds used; resubmit by hand to go on"; exit 0; fi
  G=$(scontrol show job "$SLURM_JOB_ID" | grep -oP 'TresPerNode=\K\S+' | sed 's#gres/##; s#gres:##' || true)
  sbatch --export=ALL,ROUND=$((ROUND + 1)),READER="$READER",WORK="$WORK" --gres="${G:-gpu:rtx_6000_pro:1}" llm/finetune.slurm
  exit 0
}
need() { if [ "$(left)" -lt "$1" ]; then echo "== $(( $(left) / 60 )) min left, not enough for $2: next round"; next; fi; }

SETS="inst/examples/study_examples.jsonl training/data/fresh_test.jsonl training/data/fresh_test_v2.jsonl
      training/data/fresh_test_v3.jsonl training/data/fresh_test_v4.jsonl training/data/grounded_eval.jsonl
      training/data/user_prompts_dev.jsonl"

# training prompts are generated (git-ignored); into WORK/gen so the committed test sets are never touched
EVIDENCE=${EVIDENCE:-$BASE/design/evidence}
export SFT_DATA=$WORK/gen; mkdir -p "$SFT_DATA"
[ -s "$SFT_DATA/train.jsonl" ] || $PY training/generate.py --n 14000 --seed 1 --out "$SFT_DATA/train.jsonl"
[ -s "$SFT_DATA/grounded_train.jsonl" ] || $PY training/grounded.py --evidence "$EVIDENCE" --out "$SFT_DATA" \
    --per-study 2 --seed 7 --holdout setaria,poplar,zebrafish,xenopus
[ -s "$WORK/prompts.jsonl" ] || $PY llm/make_sft.py prompts --out "$WORK"
if [ ! -s "$WORK/preds_llm_prompts_raw.json" ]; then
  need 1800 "distillation"; echo "== distil: base model reads the training prompts"
  $PY llm/reader.py --model "$READER" --examples "$WORK/prompts.jsonl" --out "$WORK" --raw
fi
[ -s "$WORK/train.jsonl" ] || $PY llm/make_sft.py build --work "$WORK"
if [ ! -s "$WORK/eval_base/preds_llm_fresh_test_v4.json" ]; then
  need 1500 "base evaluation"; echo "== evaluate the base model (no adapter)"
  $PY llm/reader.py --model "$READER" --examples $SETS --out "$WORK/eval_base" --raw
fi
if [ ! -s "$WORK/adapter/adapter_config.json" ]; then
  need 1800 "training"; echo "== LoRA training"
  set +e; $PY llm/train_lora.py --base "$READER" --work "$WORK" --deadline "$DEADLINE"; rc=$?; set -e
  if [ $rc -eq 3 ]; then next; elif [ $rc -ne 0 ]; then echo "!! training failed ($rc)"; exit $rc; fi
fi
if [ ! -s "$WORK/eval_ft/preds_llm_fresh_test_v4.json" ]; then
  need 1500 "fine-tuned evaluation"; echo "== evaluate the fine-tuned reader"
  $PY llm/reader.py --model "$READER" --adapter "$WORK/adapter" --examples $SETS --out "$WORK/eval_ft" --raw
fi
echo "== ALL DONE. Send:  tar czf ~/biodes_ft_eval.tgz -C $WORK eval_base eval_ft adapter/biodes_train.json"
