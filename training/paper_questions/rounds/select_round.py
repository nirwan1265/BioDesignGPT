#!/usr/bin/env python3
"""Pick the papers for one training round of the new study kinds.

Candidates are papers skipped in the training pool whose skip reason matches a kind in ../newkinds/kinds.tsv.
Never chosen: the new-kinds test candidates (../newkinds/selected.json), held-out species, and papers picked in
an earlier round. roundN.tsv says how many candidates to draw per kind (seed 2026 + N, round-robin over species,
as for the test set). Labels follow the candidates in rank order; papers that cannot give a fair question are
dropped with a reason, like the test set. Writes roundN.json; refuses to overwrite it.

    python3 select_round.py 1
"""
import collections, csv, glob, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PQ = os.path.dirname(HERE)
n = int(sys.argv[1])
OUT = os.path.join(HERE, f"round{n}.json")
if os.path.exists(OUT):
    sys.exit(f"{OUT} exists: the selection is fixed")
kinds = {r["kind"]: r for r in csv.DictReader(open(os.path.join(PQ, "newkinds", "kinds.tsv")), delimiter="\t")}
want = {r["kind"]: int(r["candidates"]) for r in csv.DictReader(open(os.path.join(HERE, f"round{n}.tsv")), delimiter="\t")}
blocked = {c["paper"] for c in json.load(open(os.path.join(PQ, "newkinds", "selected.json")))["papers"]}
for f in glob.glob(os.path.join(HERE, "round*.json")):
    blocked |= {c["paper"] for c in json.load(open(f))["papers"]}
skips = [r for f in sorted(glob.glob(os.path.join(PQ, "batches", "batch_*.jsonl")))
         for r in map(json.loads, open(f, encoding="utf-8")) if r.get("skip")]
skips = [r for r in skips if r["paper"] not in blocked and not r.get("held_out_species")]
rnd = random.Random(2026 + n)
out, taken = [], set()
for kind in kinds:                                   # kinds.tsv order, so a paper matching two kinds goes to the first
    k = kinds[kind]
    inc, exc = re.compile(k["include"]), re.compile(k["exclude"]) if k["exclude"] else None
    pool = [r for r in skips if r["paper"] not in taken and inc.search(r["skip"].lower())
            and not (exc and exc.search(r["skip"].lower()))]
    taken |= {r["paper"] for r in pool}              # the kind owns its matches even if this round leaves some
    if kind not in want:
        continue
    by_sp = collections.defaultdict(list)
    for r in sorted(pool, key=lambda r: r["paper"]):
        by_sp[r["species"]].append(r)
    for v in by_sp.values():
        rnd.shuffle(v)
    keys = sorted(by_sp); rnd.shuffle(keys)
    picked = []
    while len(picked) < want[kind] and any(by_sp.values()):
        for sp in keys:
            if by_sp[sp] and len(picked) < want[kind]:
                picked.append(by_sp[sp].pop())
    out += [{"paper": r["paper"], "kind": kind, "rank": i, "species": r["species"], "technique": r["technique"],
             "skip": r["skip"]} for i, r in enumerate(picked)]
    print(f"{kind:14s} pool {len(pool):4d}  picked {len(picked):3d}")
json.dump({"round": n, "seed": 2026 + n, "papers": out}, open(OUT, "w"), indent=1)
print(f"wrote {len(out)} candidates -> {OUT}")
