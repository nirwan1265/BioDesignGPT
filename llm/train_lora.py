#!/usr/bin/env python3
"""Fine-tune the reader with LoRA on WORK/train.jsonl (from llm/make_sft.py). Resumable.

Only the answer tokens are trained (the instructions and question are masked out). Checkpoints go to
WORK/checkpoints every --save-steps; the run stops cleanly before --deadline (unix time) so a 2-hour
short_gpu job never dies mid-step, and the next job resumes from the last checkpoint. The finished
adapter is WORK/adapter (load it with reader.py --adapter WORK/adapter).

    python llm/train_lora.py --base Qwen/Qwen2.5-32B-Instruct --work WORK --deadline $(( $(date +%s) + 6000 ))
"""
import argparse, json, math, os, sys, time

import torch
from peft import LoraConfig, get_peft_model
from transformers import (AutoModelForCausalLM, AutoTokenizer, Trainer, TrainerCallback, TrainingArguments,
                          set_seed)
from transformers.trainer_utils import get_last_checkpoint


def encode(tok, msgs, max_len):
    full = tok.apply_chat_template(msgs, tokenize=False)
    prompt = tok.apply_chat_template(msgs[:-1], tokenize=False, add_generation_prompt=True)
    ids = tok(full, add_special_tokens=False)["input_ids"]
    n_prompt = len(tok(prompt, add_special_tokens=False)["input_ids"])
    if len(ids) > max_len:   # keep the whole answer; trim the front of the instructions if ever needed
        cut = len(ids) - max_len
        ids, n_prompt = ids[cut:], max(0, n_prompt - cut)
    labels = [-100] * n_prompt + ids[n_prompt:]
    return {"input_ids": ids, "labels": labels}


class Rows(torch.utils.data.Dataset):
    def __init__(self, path, tok, max_len):
        with open(path, encoding="utf-8") as f:
            self.rows = [encode(tok, json.loads(l)["messages"], max_len) for l in f if l.strip()]

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        return self.rows[i]


def collate(pad_id):
    def f(batch):
        n = max(len(b["input_ids"]) for b in batch)
        ids = torch.full((len(batch), n), pad_id, dtype=torch.long)
        lab = torch.full((len(batch), n), -100, dtype=torch.long)
        att = torch.zeros((len(batch), n), dtype=torch.long)
        for i, b in enumerate(batch):
            k = len(b["input_ids"])
            ids[i, :k] = torch.tensor(b["input_ids"])
            lab[i, :k] = torch.tensor(b["labels"])
            att[i, :k] = 1
        return {"input_ids": ids, "labels": lab, "attention_mask": att}
    return f


class Deadline(TrainerCallback):
    """Save and stop before the job's time runs out (resume in the next job)."""

    def __init__(self, deadline, margin_s=600):
        self.deadline, self.margin, self.t_step = deadline, margin_s, None
        self.hit = False

    def on_step_end(self, args, state, control, **kw):
        now = time.time()
        step_s = (now - self.t_step) if self.t_step else 60
        self.t_step = now
        if self.deadline and now + self.margin + 2 * step_s > self.deadline:
            print(f"[deadline] stopping at step {state.global_step}; resubmit to continue", flush=True)
            self.hit = True
            control.should_save = True
            control.should_training_stop = True
        return control


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=os.environ.get("READER", "Qwen/Qwen2.5-32B-Instruct"))
    ap.add_argument("--work", required=True)
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--alpha", type=int, default=32)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--epochs", type=float, default=1.0)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--accum", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=2048)
    ap.add_argument("--save-steps", type=int, default=40)
    ap.add_argument("--deadline", type=float, default=0, help="unix time by which to stop (0 = none)")
    ap.add_argument("--seed", type=int, default=11)
    a = ap.parse_args()
    set_seed(a.seed)
    out_adapter = os.path.join(a.work, "adapter")
    if os.path.exists(os.path.join(out_adapter, "adapter_config.json")):
        print(f"adapter already trained: {out_adapter}")
        return
    ck_dir = os.path.join(a.work, "checkpoints")
    tok = AutoTokenizer.from_pretrained(a.base)
    if tok.pad_token_id is None:
        tok.pad_token = tok.eos_token
    train = Rows(os.path.join(a.work, "train.jsonl"), tok, a.max_len)
    val = Rows(os.path.join(a.work, "val.jsonl"), tok, a.max_len)
    ntok = sum(len(r["input_ids"]) for r in train.rows)
    print(f"{len(train)} train / {len(val)} val examples, {ntok / 1e6:.1f}M tokens per epoch", flush=True)

    model = AutoModelForCausalLM.from_pretrained(a.base, torch_dtype=torch.bfloat16, attn_implementation="sdpa",
                                                 device_map={"": 0})
    model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    model.enable_input_require_grads()
    model.config.use_cache = False
    model = get_peft_model(model, LoraConfig(
        r=a.rank, lora_alpha=a.alpha, lora_dropout=0.05, bias="none", task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]))
    model.print_trainable_parameters()

    steps_per_epoch = math.ceil(len(train) / (a.batch * a.accum))
    args = TrainingArguments(
        output_dir=ck_dir, per_device_train_batch_size=a.batch, per_device_eval_batch_size=a.batch,
        gradient_accumulation_steps=a.accum, learning_rate=a.lr, num_train_epochs=a.epochs, lr_scheduler_type="cosine",
        warmup_ratio=0.03, weight_decay=0.0, bf16=True, logging_steps=5, save_strategy="steps", save_steps=a.save_steps,
        save_total_limit=2, eval_strategy="steps", eval_steps=max(a.save_steps, steps_per_epoch // 4),
        group_by_length=True, report_to="none", dataloader_num_workers=2, remove_unused_columns=False,
        gradient_checkpointing=False, seed=a.seed)   # checkpointing already enabled on the model
    dl = Deadline(a.deadline)
    tr = Trainer(model=model, args=args, train_dataset=train, eval_dataset=val, data_collator=collate(tok.pad_token_id),
                 callbacks=[dl])
    last = get_last_checkpoint(ck_dir) if os.path.isdir(ck_dir) else None
    if last:
        print(f"resuming from {last}", flush=True)
    tr.train(resume_from_checkpoint=last)
    if dl.hit:
        sys.exit(3)   # not finished: the slurm script resubmits
    metrics = tr.evaluate()
    model.save_pretrained(out_adapter)
    tok.save_pretrained(out_adapter)
    json.dump({"base": a.base, "rank": a.rank, "alpha": a.alpha, "lr": a.lr, "epochs": a.epochs, "train_examples": len(train),
               "val_loss": metrics.get("eval_loss"), "finished": time.strftime("%Y-%m-%d %H:%M")},
              open(os.path.join(out_adapter, "biodes_train.json"), "w"), indent=1)
    print(f"adapter saved: {out_adapter} (val loss {metrics.get('eval_loss')})", flush=True)


if __name__ == "__main__":
    main()
