#!/usr/bin/env python3
"""Search the paper index: passages from real methods sections most similar to a question.

    python retrieval/search.py --index index --organism sorghum --technique "Bulk RNA-seq" \
        --query "drought stress leaf sampling replicates" --k 5
    python retrieval/search.py ... --json        # machine-readable, used by the R package

Organism: species key ("sorghum") or name ("Sorghum bicolor", "corn", "mice"; resolved via the alias table).
Technique: filters to papers linked to studies of that technique; if too few hits, falls back to all
techniques for the organism. At most --per-paper passages per paper, so results span several studies.
"""
import argparse, csv, json, os, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_index import make_embedder  # noqa: E402

SPECIES = {"Sorghum bicolor": "sorghum", "Zea mays": "maize", "Arabidopsis thaliana": "arabidopsis", "Oryza sativa": "rice",
           "Triticum aestivum": "wheat", "Hordeum vulgare": "barley", "Glycine max": "soybean", "Solanum lycopersicum": "tomato",
           "Solanum tuberosum": "potato", "Gossypium hirsutum": "cotton", "Medicago truncatula": "medicago",
           "Brachypodium distachyon": "brachypodium", "Setaria viridis": "setaria", "Nicotiana benthamiana": "nbenthamiana",
           "Physcomitrium patens": "physcomitrium", "Vitis vinifera": "grape", "Populus trichocarpa": "poplar",
           "Eucalyptus grandis": "eucalyptus", "Pinus taeda": "loblolly_pine", "Malus domestica": "apple",
           "Citrus sinensis": "citrus", "Chlamydomonas reinhardtii": "chlamydomonas", "Homo sapiens": "human",
           "Mus musculus": "mouse", "Rattus norvegicus": "rat", "Danio rerio": "zebrafish", "Drosophila melanogaster": "fly",
           "Caenorhabditis elegans": "worm", "Xenopus laevis": "xenopus", "Gallus gallus": "chicken", "Sus scrofa": "pig",
           "Bos taurus": "cattle", "Macaca mulatta": "macaque", "Saccharomyces cerevisiae": "yeast"}


SPECIES_NAME = {v: k for k, v in SPECIES.items()}


def species_key(organism, index_dir):
    o = organism.strip()
    if os.path.isdir(os.path.join(index_dir, o.lower())):
        return o.lower()
    if o in SPECIES:
        return SPECIES[o]
    al = os.path.join(HERE, "..", "inst", "agent", "aliases.tsv")
    if os.path.exists(al):
        with open(al, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                if r["category"] == "organism" and r["alias"].lower() == o.lower():
                    return SPECIES.get(r["canonical_term"], o.lower())
    return o.lower()


_CACHE = {}


def load_shard(index_dir, sp):
    if sp not in _CACHE:
        d = os.path.join(index_dir, sp)
        if not os.path.exists(os.path.join(d, "info.json")):
            return None
        emb = np.load(os.path.join(d, "emb.npy")).astype("float32")
        with open(os.path.join(d, "meta.jsonl"), encoding="utf-8") as f:
            meta = [json.loads(l) for l in f]
        _CACHE[sp] = (emb, meta, json.load(open(os.path.join(d, "info.json"))))
    return _CACHE[sp]


def search(index_dir, organism, query, technique=None, k=5, per_paper=2, embedder=None, min_hits=3):
    sp = species_key(organism, index_dir)
    sh = load_shard(index_dir, sp)
    if sh is None:
        return {"species": sp, "technique": technique, "hits": [], "note": f"no index shard for '{organism}'"}
    emb, meta, info = sh
    embedder = embedder or make_embedder(info["model"], "cuda" if _cuda() else "cpu")
    q = embedder.encode([query], query=True)[0]
    scores = emb @ q
    note = None
    idx = np.arange(len(meta))
    if technique:
        tl = technique.lower()
        sel = np.array([any(tl == t.lower() or tl in t.lower() for t in m["techniques"]) for m in meta])
        if sel.sum() >= min_hits:
            idx = idx[sel]
        else:
            note = f"few {technique} papers for {sp}; searched all techniques"
    order = idx[np.argsort(-scores[idx])]
    target = SPECIES_NAME.get(sp)
    labelled = any("organism_main" in m for m in meta[:50])

    def same(m):   # paper is about the shard's organism (unlabelled shards: trust the shard)
        if not labelled or m.get("organism_main") in (None, target):
            return True
        c = m.get("organism_counts") or {}   # a real second organism, not a passing mention
        return c.get(target, 0) >= 0.5 * c.get(m["organism_main"], 1)

    def pick(cands, limit):
        out, per = [], {}
        for i in cands:
            m = meta[i]
            if per.get(m["pmcid"], 0) >= per_paper:
                continue
            per[m["pmcid"]] = per.get(m["pmcid"], 0) + 1
            other = None if same(m) else m.get("organism_main")
            out.append({"score": round(float(scores[i]), 3), "pmcid": m["pmcid"], "doi": m["doi"], "year": m["year"],
                        "techniques": m["techniques"], "organism": other or target, "other_organism": bool(other),
                        "text": m["text"]})
            if len(out) >= limit:
                break
        return out

    hits = pick([i for i in order if same(meta[i])], k)
    if len(hits) < k:   # labelled fallback: same method in another organism
        extra = pick([i for i in order if not same(meta[i])], k - len(hits))
        if extra:
            note = ((note + "; ") if note else "") + f"only {len(hits)} {sp} papers matched; added {len(extra)} from other organisms"
        hits += extra
    return {"species": sp, "technique": technique, "hits": hits, "note": note}


def _cuda():
    try:
        import torch
        return torch.cuda.is_available()
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default="index")
    ap.add_argument("--organism", required=True)
    ap.add_argument("--technique", default=None)
    ap.add_argument("--query", required=True)
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    r = search(a.index, a.organism, a.query, a.technique, a.k)
    if a.json:
        print(json.dumps(r, ensure_ascii=False))
        return
    print(f"{r['species']} / {r['technique'] or 'all techniques'}" + (f"  ({r['note']})" if r["note"] else ""))
    for h in r["hits"]:
        tag = f"  [{h['organism']} study]" if h.get("other_organism") else ""
        print(f"\n[{h['score']}] {h['pmcid']} doi:{h['doi']} ({h['year']}; {', '.join(h['techniques']) or '?'}){tag}")
        print("  " + h["text"][:600] + ("..." if len(h["text"]) > 600 else ""))


if __name__ == "__main__":
    main()
