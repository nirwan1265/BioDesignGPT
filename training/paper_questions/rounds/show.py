#!/usr/bin/env python3
"""Print round candidates for labelling: python3 rounds/show.py N KIND [FROM TO] [CHARS]"""
import glob, gzip, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
papers = {r["id"]: r for f in sorted(glob.glob(os.path.join(HERE, "..", "raw", "papers_sample*.jsonl.gz")))
          for r in map(json.loads, gzip.open(f, "rt"))}
n, kind = sys.argv[1], sys.argv[2]
lo, hi = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (0, 999)
nm = int(sys.argv[5]) if len(sys.argv) > 5 else 450
for c in json.load(open(os.path.join(HERE, f"round{n}.json")))["papers"]:
    if c["kind"] != kind or not lo <= c["rank"] < hi: continue
    r = papers[c["paper"]]
    md = r["study_metadata"]; md = eval(md) if isinstance(md, str) else md
    seen, sents = set(), []
    for x in re.split(r"(?<=[.!?])\s+", r["digest"] or ""):
        if x not in seen: seen.add(x); sents.append(x)
    print(f"\n### {c['rank']} {r['id']} | {r['species']} | {r['technique']} | skip: {c['skip']}")
    print(f"T: {r['title'][:180]}")
    print(f"M: {'; '.join(str(m)[:150] for m in md[:2])[:220]}")
    print(f"D: {' '.join(sents)[:420]}")
    print(f"X: {re.sub(chr(92)+'s+', ' ', r['methods'] or '')[:nm]}")
