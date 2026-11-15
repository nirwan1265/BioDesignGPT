#!/usr/bin/env python3
"""Build and freeze the new-kinds test set: splits/test_newkinds.jsonl.

Reads labels/nk_*.py (same dict format as ../labels/bNN.py; dropped candidates carry skip=...), fills paper
metadata from ../raw, applies the same normalisation and schema checks as the training labels, and checks:
  - every labelled paper is a selected candidate (selected.json) of the kind its file names
  - each kind's labelled count equals its quota, taken in rank order (candidates after the quota are unused)
  - none of these papers is labelled in ../batches (they stay skips there, so never in training)
  - no prompt duplicates a dev/test/train prompt

The first run writes MANIFEST.json (counts, sha256 of the file, sha256 of the member ids). After that the
membership is frozen: a rerun may change labels (contents) but refuses to change which papers are in the set.

    python3 build.py            # build / rebuild, membership must match the manifest
    python3 build.py --check    # verify the file matches the manifest
"""
import argparse, collections, glob, gzip, hashlib, json, os, runpy, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PQ = os.path.dirname(HERE)
sys.path.insert(0, PQ)
from normalise import normalise  # noqa: E402
import validate  # noqa: E402

OUT = os.path.join(PQ, "splits", "test_newkinds.jsonl")
MAN = os.path.join(HERE, "MANIFEST.json")


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def members(ids):
    return hashlib.sha256("\n".join(sorted(ids)).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        m = json.load(open(MAN))
        ids = [json.loads(l)["id"] for l in open(OUT)]
        ok = sha(OUT) == m["sha256"] and members(ids) == m["members_sha256"]
        print("new-kinds split intact" if ok else "CHANGED since freezing")
        sys.exit(0 if ok else 1)

    sel = {c["paper"]: c for c in json.load(open(os.path.join(HERE, "selected.json")))["papers"]}
    papers = {r["id"]: r for f in sorted(glob.glob(os.path.join(PQ, "raw", "papers_sample*.jsonl.gz")))
              for r in map(json.loads, gzip.open(f, "rt"))}
    in_batches = {}
    for f in glob.glob(os.path.join(PQ, "batches", "batch_*.jsonl")):
        for r in map(json.loads, open(f, encoding="utf-8")):
            in_batches[r["paper"]] = r
    seen_prompts = set()
    for n in ("dev.jsonl", "test.jsonl", "test_heldout.jsonl", "train.jsonl"):
        p = os.path.join(PQ, "splits", n)
        if os.path.exists(p):
            seen_prompts |= {" ".join(json.loads(l)["prompt"].lower().split()) for l in open(p)}

    errs, stats, recs = [], collections.Counter(), []
    for lf in sorted(glob.glob(os.path.join(HERE, "labels", "nk_*.py"))):
        kind = os.path.basename(lf)[3:-3]
        L = runpy.run_path(lf)["L"]
        quota = None
        cands = sorted([c for c in sel.values() if c["kind"] == kind], key=lambda c: c["rank"])
        done = {x["paper"] for x in L}
        # labels follow the candidates in rank order with no gaps until the quota is filled
        order = [c["paper"] for c in cands][:len(L)]
        if [x["paper"] for x in L] != order:
            errs.append(f"{kind}: labels are not the candidates in rank order")
        n_lab = sum(1 for x in L if not x.get("skip"))
        quota = cands[0]["quota"] if cands else 0
        if n_lab != quota:
            errs.append(f"{kind}: {n_lab} labelled, quota {quota}")
        for x in L:
            if x["paper"] not in sel or sel[x["paper"]]["kind"] != kind:
                errs.append(f"{kind}: {x['paper']} is not a {kind} candidate"); continue
            b = in_batches.get(x["paper"])
            if b is None or not b.get("skip"):
                errs.append(f"{x['paper']}: must stay a skip in batches/")
            if x.get("skip"):
                continue
            p = papers[x["paper"]]
            rec = {"id": "nk_" + x["paper"].split("_")[1], "paper": x["paper"], "pmcid": p["pmcid"], "doi": p.get("doi"),
                   "species": p["species"], "technique": p["technique"], "held_out_species": p["held_out_species"],
                   "kind": kind, "style": x["style"], "prompt": x["prompt"], "expected_spec": x["spec"],
                   "must_ask": x.get("ask", []), "gaps": x.get("gaps", []), "paper_design": x.get("note", "")}
            rec = normalise(rec)
            validate.check(rec, f"{kind} {x['paper']}", errs, stats)
            if " ".join(rec["prompt"].lower().split()) in seen_prompts:
                errs.append(f"{x['paper']}: prompt duplicates a frozen or training prompt")
            recs.append(rec)
    if errs:
        sys.exit("\n".join(errs))
    recs.sort(key=lambda r: r["id"])
    ids = [r["id"] for r in recs]
    if os.path.exists(MAN):
        m = json.load(open(MAN))
        if members(ids) != m["members_sha256"]:
            sys.exit("membership differs from MANIFEST.json: the new-kinds set is frozen")
    with open(OUT, "w", encoding="utf-8") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    kinds = dict(collections.Counter(r["kind"] for r in recs))
    m = {"n": len(recs), "kinds": kinds, "sha256": sha(OUT), "members_sha256": members(ids),
         "species": dict(collections.Counter(r["species"] for r in recs).most_common()),
         "styles": dict(collections.Counter(r["style"] for r in recs).most_common())}
    json.dump(m, open(MAN, "w"), indent=1)
    other = {k[7:]: v for k, v in stats.items() if k.startswith("factor:")}
    print(f"wrote {len(recs)} questions -> {OUT}\n  kinds {kinds}")
    if other:
        print("  factor names outside the core list:", other)


if __name__ == "__main__":
    main()
