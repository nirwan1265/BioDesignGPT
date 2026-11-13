#!/usr/bin/env python3
"""Tally the schema gaps logged while writing paper questions (the `gaps` field of each record).

Gap tags are written by hand as kind:value (assay:hic, unit:pen, synonym:breed->genotype ...), so the same gap
can be spelled two ways; NORMALISE folds the spellings together. Prints the gaps by kind, most frequent first,
with the species they came from, so schema additions can be decided by how often real papers need them.

    python3 gap_report.py            # all batches
    python3 gap_report.py --min 2    # only gaps seen at least twice
"""
import argparse, collections, glob, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
NORMALISE = {"assay:hi_c": "assay:hic", "assay:rip_clip_seq": "assay:rip_clip", "assay:spatial_transcriptomics": "assay:spatial",
             "system:livestock": "setting:livestock", "synonym:cut&run": "synonym:CUT&Tag", "unit:cage(poultry)": "unit:cage",
             "assay:virus_metagenomics": "assay:metagenomics",
             "assay:m6a": "assay:m6a_merip", "assay:long_read": "assay:long_read_rna"}


def key(g):
    g = g.split("->")[0].strip()
    return NORMALISE.get(g, g)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=int, default=1)
    a = ap.parse_args()
    by_kind = collections.defaultdict(collections.Counter)
    species = collections.defaultdict(set)
    n = 0
    for f in sorted(glob.glob(os.path.join(HERE, "batches", "batch_*.jsonl"))):
        for line in open(f, encoding="utf-8"):
            r = json.loads(line)
            if r.get("skip"):
                continue
            n += 1
            for g in r.get("gaps") or []:
                k = key(g)
                kind = k.split(":")[0] if ":" in k else "other"
                by_kind[kind][k] += 1
                species[k].add(r["species"])
    print(f"{n} questions")
    for kind, c in sorted(by_kind.items(), key=lambda kv: -sum(kv[1].values())):
        rows = [(k, v) for k, v in c.most_common() if v >= a.min]
        if not rows:
            continue
        print(f"\n== {kind} ({sum(c.values())})")
        for k, v in rows:
            print(f"  {v:3d}  {k.split(':', 1)[1] if ':' in k else k:28s} {', '.join(sorted(species[k]))}")


if __name__ == "__main__":
    main()
