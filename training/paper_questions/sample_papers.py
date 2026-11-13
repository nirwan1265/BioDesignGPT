#!/usr/bin/env python3
"""Sample real papers for a paper-grounded test set.

For each sampled paper: its title, the study metadata we harvested (technique, tissues, factors) and the
first methods passages (growth, animals, design) from the index. A question is then written from each paper
the way a researcher would ask *before* doing that study, with the gold StudySpec taken from what the paper
did. Labels come from the papers, not from our rules or the reader.

Only papers whose own text is about the shard's organism (label_organisms.py) are used, stratified by
species x technique. The held-out species (setaria, poplar, zebrafish, xenopus) are marked: no model was
trained on them.

    python training/paper_questions/sample_papers.py --index INDEX --evidence EVIDENCE --n 240 --out papers_sample.jsonl
"""
import argparse, collections, csv, json, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "retrieval"))
from label_organisms import SHARD_ORGANISM  # noqa: E402

csv.field_size_limit(10 ** 9)
HELD_OUT = {"setaria", "poplar", "zebrafish", "xenopus"}


def read_tsv(p):
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--n", type=int, default=240)
    ap.add_argument("--passages", type=int, default=4, help="first N passages of each paper's methods")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--out", default="papers_sample.jsonl")
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    titles = {r["pmcid"]: r for r in read_tsv(os.path.join(a.evidence, "all_species_papers.tsv")) if r.get("pmcid")}
    studies = collections.defaultdict(list)
    for r in read_tsv(os.path.join(a.evidence, "all_species_by_study.tsv")):
        studies[(r["species"], r.get("study_group", ""))].append(r)
    cands = collections.defaultdict(list)   # (species, technique) -> papers
    for sp in sorted(os.listdir(a.index)):
        mpath = os.path.join(a.index, sp, "meta.jsonl")
        if not os.path.exists(mpath):
            continue
        by_paper = collections.defaultdict(list)
        with open(mpath, encoding="utf-8") as f:
            for l in f:
                m = json.loads(l)
                by_paper[m["pmcid"]].append(m)
        for pmcid, ms in by_paper.items():
            ms.sort(key=lambda m: m["chunk"])
            if ms[0].get("organism_main") != SHARD_ORGANISM.get(sp):
                continue   # only papers whose own methods are about this shard's organism (label_organisms.py)
            techs = ms[0].get("techniques") or ["?"]
            text = " ".join(m["text"] for m in ms[:a.passages])
            if len(text) < 1500:
                continue
            for t in techs[:1]:
                cands[(sp, t)].append({"pmcid": pmcid, "species": sp, "technique": t, "techniques": techs,
                                       "doi": ms[0].get("doi"), "year": ms[0].get("year"),
                                       "study_groups": ms[0].get("study_groups", []), "methods": text[:5000]})
    keys = list(cands)
    for k in keys:
        rnd.shuffle(cands[k])
    rnd.shuffle(keys)
    picked = []
    while len(picked) < a.n and any(cands[k] for k in keys):   # round-robin over species x technique
        for k in keys:
            if cands[k] and len(picked) < a.n:
                picked.append(cands[k].pop())
    with open(a.out, "w", encoding="utf-8") as f:
        for i, p in enumerate(picked):
            t = titles.get(p["pmcid"], {})
            meta = []
            for g in p["study_groups"][:2]:
                for r in studies.get((p["species"], g), [])[:2]:
                    meta.append({k: r.get(k) for k in ("technique", "organism", "tissues", "treatment", "dev_stage", "genotypes",
                                                         "n_samples", "n_runs", "instrument") if r.get(k)})
            p.update({"id": f"paper_{i:04d}", "title": t.get("title", ""), "journal": t.get("journal", ""),
                      "held_out_species": p["species"] in HELD_OUT, "study_metadata": meta})
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    c = collections.Counter(p["species"] for p in picked)
    print(f"wrote {len(picked)} papers from {len(c)} species -> {a.out}; held-out species: "
          f"{sum(p['species'] in HELD_OUT for p in picked)}")


if __name__ == "__main__":
    main()
