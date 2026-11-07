#!/usr/bin/env python3
"""Predict StudySpecs with a trained tagger.

    python training/predict.py --model inst/models/sf-tiny --text "324 sorghum accessions at three sites, 2 reps"
    python training/predict.py --model inst/models/sf-tiny --examples inst/examples/study_examples.jsonl --out preds.json
"""
import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model import StudyForgeTagger  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--text"); ap.add_argument("--examples"); ap.add_argument("--out")
    ap.add_argument("--show-tags", action="store_true")
    a = ap.parse_args()
    tg = StudyForgeTagger(a.model)
    if a.text:
        s = tg.spec(a.text)
        if not a.show_tags:
            s.pop("_model", None)
        print(json.dumps(s, indent=None if a.out else 2))
        return
    prompts = [json.loads(l)["prompt"] for l in open(a.examples)]
    preds = {}
    for p in prompts:
        s = tg.spec(p)
        s.pop("_model", None)
        preds[p] = s
    json.dump(preds, open(a.out, "w"), indent=1)
    print(f"wrote {len(preds)} predictions to {a.out}")


if __name__ == "__main__":
    main()
