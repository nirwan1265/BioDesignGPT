#!/usr/bin/env python3
"""Train the StudyForge prompt tagger.

Tiny model from scratch on CPU (no downloads):
    python training/train.py --train training/data/train.jsonl --dev training/data/dev.jsonl --out inst/models/sf-tiny
Fine-tune SciBERT (GPU recommended, e.g. on HPC):
    python training/train.py --base allenai/scibert_scivocab_uncased --epochs 4 --lr 3e-5 --out inst/models/sf-scibert ...
"""
import argparse, json, os, random, sys, time
import torch
from torch.nn.utils.rnn import pad_sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "inst", "python"))
from model import LABELS, SYSTEMS, Tagger, encode  # noqa: E402


def load(path):
    return [json.loads(l) for l in open(path)]


def build_tiny(train, out, vocab_size=4000, hidden=192, layers=3, heads=4):
    from tokenizers import Tokenizer, models, normalizers, pre_tokenizers, trainers
    from transformers import BertConfig, BertModel, PreTrainedTokenizerFast
    tk = Tokenizer(models.WordPiece(unk_token="[UNK]"))
    tk.normalizer = normalizers.BertNormalizer(lowercase=True)
    tk.pre_tokenizer = pre_tokenizers.BertPreTokenizer()
    trainer = trainers.WordPieceTrainer(vocab_size=vocab_size, special_tokens=["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"])
    # vocabulary from training text plus the alias table so unseen synonyms are still in-vocab
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "inst", "python"))
    import rulebook   # inst/agent/rules.tsv
    corpus = [d["text"] for d in train] + [r["alias"] for r in rulebook.alias_rows()] * 5
    tk.train_from_iterator(corpus, trainer)
    from tokenizers.processors import TemplateProcessing
    tk.post_processor = TemplateProcessing(single="[CLS] $A [SEP]", special_tokens=[("[CLS]", tk.token_to_id("[CLS]")), ("[SEP]", tk.token_to_id("[SEP]"))])
    hf = PreTrainedTokenizerFast(tokenizer_object=tk, unk_token="[UNK]", pad_token="[PAD]", cls_token="[CLS]", sep_token="[SEP]", mask_token="[MASK]")
    cfg = BertConfig(vocab_size=hf.vocab_size, hidden_size=hidden, num_hidden_layers=layers, num_attention_heads=heads,
                     intermediate_size=hidden * 4, max_position_embeddings=256)
    return hf, BertModel(cfg, add_pooling_layer=False), cfg, True


def batches(data, tok, bs, shuffle, lower):
    idx = list(range(len(data)))
    if shuffle:
        random.shuffle(idx)
    for i in range(0, len(idx), bs):
        items = [data[j] for j in idx[i:i + bs]]
        ids, mask, lab, sys_ = [], [], [], []
        for d in items:
            toks = [t.lower() for t in d["tokens"]] if lower else d["tokens"]
            a, m, l, _ = encode(tok, toks, d["tags"])
            ids.append(torch.tensor(a)); mask.append(torch.tensor(m)); lab.append(torch.tensor(l))
            sys_.append(SYSTEMS.index(d["system"]))
        yield (pad_sequence(ids, batch_first=True, padding_value=tok.pad_token_id),
               pad_sequence(mask, batch_first=True), pad_sequence(lab, batch_first=True, padding_value=-100),
               torch.tensor(sys_))


@torch.no_grad()
def evaluate(model, data, tok, lower, dev):
    model.eval()
    tp = fp = fn = 0
    sys_ok = 0
    for ids, mask, lab, sy in batches(data, tok, 64, False, lower):
        tl, sl = model(ids.to(dev), mask.to(dev))
        pred = tl.argmax(-1).cpu()
        sys_ok += (sl.argmax(-1).cpu() == sy).sum().item()
        keep = lab != -100
        p, g = pred[keep], lab[keep]
        tp += ((p == g) & (g != 0)).sum().item()
        fp += ((p != g) & (p != 0)).sum().item()
        fn += ((p != g) & (g != 0)).sum().item()
    model.train()
    prec = tp / max(tp + fp, 1); rec = tp / max(tp + fn, 1)
    return {"token_f1": 2 * prec * rec / max(prec + rec, 1e-9), "system_acc": sys_ok / len(data)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", required=True); ap.add_argument("--dev", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--base", default=None, help="HF model name/path; omit to train a tiny BERT from scratch")
    ap.add_argument("--epochs", type=int, default=6); ap.add_argument("--bs", type=int, default=32)
    ap.add_argument("--lr", type=float, default=None); ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    random.seed(a.seed); torch.manual_seed(a.seed)
    train, devset = load(a.train), load(a.dev)
    dev = "cuda" if torch.cuda.is_available() else "cpu"

    if a.base:
        from transformers import AutoConfig, AutoModel, AutoTokenizer
        tok = AutoTokenizer.from_pretrained(a.base)
        cfg = AutoConfig.from_pretrained(a.base)
        enc = AutoModel.from_pretrained(a.base, add_pooling_layer=False) if cfg.model_type == "bert" else AutoModel.from_pretrained(a.base)
        custom, lower = False, getattr(tok, "do_lower_case", True)
        lr = a.lr or 3e-5
    else:
        tok, enc, cfg, custom = build_tiny(train, a.out)
        lower, lr = True, a.lr or 5e-4

    model = Tagger(enc, cfg.hidden_size).to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.01)
    steps = a.epochs * ((len(train) + a.bs - 1) // a.bs)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=lr, total_steps=steps, pct_start=0.1)
    ce = torch.nn.CrossEntropyLoss(ignore_index=-100)
    t0 = time.time()
    for ep in range(a.epochs):
        tot = 0.0
        for ids, mask, lab, sy in batches(train, tok, a.bs, True, lower):
            ids, mask, lab, sy = ids.to(dev), mask.to(dev), lab.to(dev), sy.to(dev)
            tl, sl = model(ids, mask)
            loss = ce(tl.reshape(-1, len(LABELS)), lab.reshape(-1)) + 0.5 * ce(sl, sy)
            opt.zero_grad(); loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step(); sched.step()
            tot += loss.item()
        m = evaluate(model, devset, tok, lower, dev)
        print(f"epoch {ep + 1}: loss {tot:.1f}  dev token F1 {m['token_f1']:.3f}  dev system acc {m['system_acc']:.3f}  ({time.time() - t0:.0f}s)", flush=True)

    os.makedirs(a.out, exist_ok=True)
    tok.save_pretrained(a.out); cfg.save_pretrained(a.out)
    torch.save(model.state_dict(), os.path.join(a.out, "tagger.pt"))
    json.dump({"labels": LABELS, "systems": SYSTEMS, "custom_tokenizer": custom, "lowercase": lower, "base": a.base,
               "dev": m, "n_train": len(train)}, open(os.path.join(a.out, "meta.json"), "w"), indent=2)
    print("saved", a.out)


if __name__ == "__main__":
    main()
