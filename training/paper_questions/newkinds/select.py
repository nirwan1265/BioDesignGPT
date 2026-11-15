#!/usr/bin/env python3
"""Pick the new-kinds test papers: papers skipped while labelling the training pool because their study kind
was not covered (mapping populations, mutant lines, population/evolution studies, human cohorts, atlases,
cell lines). They test whether the reader handles kinds of question it was never trained on.

The kinds and their keyword patterns live in kinds.tsv (kind, quota, include regex, exclude regex), matched
against the skip reason. Candidates are drawn per kind (seed 2026), round-robin over species so no species
dominates, 1.5x the quota so papers that cannot give a fair question can be dropped in order (the drop and its
reason are recorded in the labels). Writes selected.json; refuses to overwrite it.

    python3 select.py
"""
import collections, csv, glob, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PQ = os.path.dirname(HERE)
OUT = os.path.join(HERE, "selected.json")
SEED = 2026

if os.path.exists(OUT):
    sys.exit(f"{OUT} exists: the selection is fixed")
kinds = [r for r in csv.DictReader(open(os.path.join(HERE, "kinds.tsv")), delimiter="\t")]
skips = []
for f in sorted(glob.glob(os.path.join(PQ, "batches", "batch_*.jsonl"))):
    skips += [r for r in map(json.loads, open(f, encoding="utf-8")) if r.get("skip")]
rnd = random.Random(SEED)
out, taken = [], set()
for k in kinds:
    inc, exc = re.compile(k["include"]), re.compile(k["exclude"]) if k["exclude"] else None
    pool = [r for r in skips if r["paper"] not in taken and inc.search(r["skip"].lower())
            and not (exc and exc.search(r["skip"].lower())) and r.get("held_out_species") is not True]
    by_sp = collections.defaultdict(list)
    for r in sorted(pool, key=lambda r: r["paper"]):
        by_sp[r["species"]].append(r)
    for v in by_sp.values():
        rnd.shuffle(v)
    keys = sorted(by_sp); rnd.shuffle(keys)
    want, picked = int(round(int(k["quota"]) * 1.5)), []
    while len(picked) < want and any(by_sp.values()):
        for sp in keys:
            if by_sp[sp] and len(picked) < want:
                picked.append(by_sp[sp].pop())
    for i, r in enumerate(picked):
        taken.add(r["paper"])
        out.append({"paper": r["paper"], "kind": k["kind"], "rank": i, "quota": int(k["quota"]),
                    "species": r["species"], "technique": r["technique"], "skip": r["skip"]})
    print(f"{k['kind']:14s} pool {len(pool):4d}  candidates {len(picked):3d}  quota {k['quota']}")
json.dump({"seed": SEED, "papers": out}, open(OUT, "w"), indent=1)
print(f"wrote {len(out)} candidates -> {OUT}")
