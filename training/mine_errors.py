#!/usr/bin/env python3
"""Hard-example loop: find which sentence families the model gets wrong and upweight them.

    python training/mine_errors.py --model inst/models/sf-tiny --dev training/data/dev.jsonl --out training/data/family_weights.json
    python training/generate.py --n 8000 --weights training/data/family_weights.json --out training/data/train_r2.jsonl
    python training/train.py --train training/data/train_r2.jsonl ...
Repeat until dev errors stop improving. Always confirm on prompts the loop never saw.
"""
import argparse, collections, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "inst", "python"))
from generate import DEFAULT_WEIGHTS  # noqa: E402
from model import StudyForgeTagger  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True); ap.add_argument("--dev", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--boost", type=float, default=4.0, help="max multiplier for the worst family")
    a = ap.parse_args()
    tg = StudyForgeTagger(a.model)
    err, tot = collections.Counter(), collections.Counter()
    for line in open(a.dev):
        d = json.loads(line)
        _, tags, system, _ = tg.tag(" ".join(d["tokens"]))
        n = len(d["tags"])
        wrong = sum(p != g for p, g in zip(tags[:n], d["tags"])) + (system != d["system"]) * 3
        err[d["family"]] += wrong
        tot[d["family"]] += n
    rate = {f: err[f] / max(tot[f], 1) for f in tot}
    worst = max(rate.values()) or 1
    weights = {f: round(DEFAULT_WEIGHTS.get(f, 1) * (1 + (a.boost - 1) * rate[f] / worst), 3) for f in rate}
    for f in sorted(rate, key=rate.get, reverse=True):
        print(f"{f:22s} token error {100 * rate[f]:5.2f}%  weight {weights[f]}")
    json.dump(weights, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
