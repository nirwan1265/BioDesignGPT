#!/usr/bin/env python3
"""Put one round's labels into the training pool.

rounds/labels/r<N>_<kind>.py hold the labels (same dict format as ../labels/bNN.py; dropped candidates carry
skip=...). They must follow roundN.json's candidates in rank order, with no gaps. Each labelled paper's skip entry
in ../labels/bNN.py is replaced by its question, then those batches are rewritten (write_batch.py), validated,
and train.jsonl is refreshed. The papers were skips in the frozen split, so they can only ever enter train.

    python3 rounds/apply_round.py 1
"""
import glob, json, os, re, runpy, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PQ = os.path.dirname(HERE)
n = int(sys.argv[1])
cands = json.load(open(os.path.join(HERE, f"round{n}.json")))["papers"]
labels, errs = {}, []
for lf in sorted(glob.glob(os.path.join(HERE, "labels", f"r{n}_*.py"))):
    kind = os.path.basename(lf)[len(f"r{n}_"):-3]
    L = runpy.run_path(lf)["L"]
    order = [c["paper"] for c in sorted((c for c in cands if c["kind"] == kind), key=lambda c: c["rank"])]
    if [x["paper"] for x in L] != order[:len(L)]:
        errs.append(f"{kind}: labels are not the candidates in rank order")
    for x in L:
        if not x.get("skip"):
            labels[x["paper"]] = dict(x, note=f"round {n}: " + x.get("note", ""))
if errs:
    sys.exit("\n".join(errs))
touched, found, where = set(), set(), {}
for f in sorted(glob.glob(os.path.join(PQ, "labels", "b*.py"))):
    s, changed = open(f).read(), False
    for pid, x in labels.items():
        # a skip entry, or this round's question from an earlier run (re-running applies edited labels)
        line = (re.search(r'^dict\(paper="' + pid + r'", skip="[^"]*"\),$', s, re.M)
                or re.search(r"^\{'paper': '" + pid + r"', .*\},$", s, re.M))
        if line and line.group(0) != repr(x) + ",":
            s = s[:line.start()] + repr(x) + "," + s[line.end():]
            changed = True
        if line:
            found.add(pid); where[pid] = f
    if changed:
        open(f, "w").write(s)
        touched.add(f)
touched |= set(where.values())
if found != set(labels):
    sys.exit(f"not found as skips in labels/: {sorted(set(labels) - found)[:5]}")
for f in sorted(touched):
    nn = re.search(r"b(\d+)\.py$", f).group(1)
    subprocess.run([sys.executable, os.path.join(PQ, "write_batch.py"), nn, f], check=True, cwd=PQ)
subprocess.run([sys.executable, os.path.join(PQ, "validate.py")], check=True, cwd=PQ)
subprocess.run([sys.executable, os.path.join(PQ, "freeze_split.py"), "--refresh"], check=True, cwd=PQ)
print(f"round {n}: {len(labels)} questions into the training pool from {len(touched)} label files")
