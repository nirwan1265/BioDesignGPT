#!/usr/bin/env python3
"""Print papers compactly for labelling: python show_batch.py START COUNT"""
import gzip, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
rows = [json.loads(l) for l in gzip.open(os.path.join(HERE, "raw", "papers_sample.jsonl.gz"), "rt")]
s, n = int(sys.argv[1]), int(sys.argv[2])
for r in rows[s:s + n]:
    md = "; ".join(" ".join(f"{k}={v}" for k, v in m.items() if k not in ("organism",))[:220] for m in r["study_metadata"][:2])
    mf = " ".join(f"{k}={v}" for k, v in r["method_fields"].items())[:250]
    print(f"\n### {r['id']} | {r['species']} | {r['technique']} | {'HELD-OUT ' if r['held_out_species'] else ''}{r['pmcid']}")
    print(f"T: {r['title'][:200]}")
    if md: print(f"M: {md}")
    if mf: print(f"F: {mf}")
    seen, sents = set(), []
    for x in __import__("re").split(r"(?<=[.!?])\s+", r["digest"]):
        if x not in seen:
            seen.add(x); sents.append(x)
    print(f"D: {' '.join(sents)[:1000]}")
