#!/usr/bin/env python3
"""Print the new-kinds candidates of one kind for labelling: python3 show.py KIND [METHODS_CHARS]"""
import glob, gzip, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
papers = {r["id"]: r for f in sorted(glob.glob(os.path.join(HERE, "..", "raw", "papers_sample*.jsonl.gz")))
          for r in map(json.loads, gzip.open(f, "rt"))}
kind, nm = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 900
for c in [c for c in json.load(open(os.path.join(HERE, "selected.json")))["papers"] if c["kind"] == kind]:
    r = papers[c["paper"]]
    md = "; ".join(str(m)[:200] for m in (eval(r["study_metadata"]) if isinstance(r["study_metadata"], str) else r["study_metadata"])[:2])
    print(f"\n### {c['rank']:2d} {r['id']} | {r['species']} | {r['technique']} | skip: {c['skip']}")
    print(f"T: {r['title'][:220]}")
    print(f"M: {md[:300]}")
    sents, seen = [], set()
    for x in re.split(r"(?<=[.!?])\s+", r["digest"] or ""):
        if x not in seen: seen.add(x); sents.append(x)
    print(f"D: {' '.join(sents)[:700]}")
    print(f"X: {re.sub(r'\s+', ' ', r['methods'] or '')[:nm]}")
