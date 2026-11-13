#!/usr/bin/env python3
"""Append labelled questions to batches/batch_NN.jsonl, filling paper metadata from the sample.
   python write_batch.py NN labels.py   (labels.py defines L = [dict(paper=..., style=..., prompt=..., spec=..., ask=..., gaps=..., note=...)])"""
import gzip, json, os, runpy, sys
HERE = os.path.dirname(os.path.abspath(__file__))
papers = {r["id"]: r for r in map(json.loads, gzip.open(os.path.join(HERE, "raw", "papers_sample.jsonl.gz"), "rt"))}
nn, src = sys.argv[1], sys.argv[2]
L = runpy.run_path(src)["L"]
out = os.path.join(HERE, "batches", f"batch_{int(nn):02d}.jsonl")
with open(out, "w", encoding="utf-8") as f:
    for x in L:
        p = papers[x["paper"]]
        rec = {"id": "pq_" + x["paper"].split("_")[1], "paper": x["paper"], "pmcid": p["pmcid"], "doi": p.get("doi"),
               "species": p["species"], "technique": p["technique"], "held_out_species": p["held_out_species"]}
        if x.get("skip"):
            rec["skip"] = x["skip"]
        else:
            rec.update({"style": x["style"], "prompt": x["prompt"], "expected_spec": x["spec"], "must_ask": x.get("ask", []),
                        "gaps": x.get("gaps", []), "paper_design": x.get("note", "")})
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
print(f"wrote {len(L)} -> {out}")
