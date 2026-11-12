#!/usr/bin/env python3
"""Label every paper (and passage) in the index with the organism its own methods text is about.

Papers reach a shard because they mention one of that organism's datasets, which also pulls in reanalyses
and papers about other organisms. This counts organism names in the text and writes, per passage,
`passage_organisms` and, per paper, `organism_main` / `organism_counts` into meta.jsonl. No re-embedding.

Names come from inst/vocab/organism_names.tsv (built by data-raw/vocab/build_vocab.py from NCBI Taxonomy,
the strains/cultivars/cell lines in our harvested studies, and the curated alias table). Three general rules,
the same for every organism:
  longest name wins           "guinea pig" is not "pig", "Sprague-Dawley rats" is one mention
  reagents are not organisms  an organism word next to a material/antibody word ("corn oil", "yeast extract",
                              "goat anti-rabbit IgG", "fetal bovine serum", "human ortholog") is skipped
  names must be specific      a name about as common in every shard as in its own organism's shard
                              (a generic sample label such as "seedling" that slipped into the vocabulary) is dropped,
                              unless it is in at least half its own organism's papers; the list is written to <index>/_names_dropped.tsv

    python retrieval/label_organisms.py --index index              # every shard
    python retrieval/label_organisms.py --index index --species rat
"""
import argparse, collections, csv, json, os, re, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
VOCAB = os.path.join(HERE, "..", "inst", "vocab", "organism_names.tsv")
ALIASES = os.path.join(HERE, "..", "inst", "agent", "aliases.tsv")
SHARD_ORGANISM = {"sorghum": "Sorghum bicolor", "maize": "Zea mays", "arabidopsis": "Arabidopsis thaliana", "rice": "Oryza sativa",
                  "wheat": "Triticum aestivum", "barley": "Hordeum vulgare", "soybean": "Glycine max",
                  "tomato": "Solanum lycopersicum", "potato": "Solanum tuberosum", "cotton": "Gossypium hirsutum",
                  "medicago": "Medicago truncatula", "brachypodium": "Brachypodium distachyon", "setaria": "Setaria viridis",
                  "nbenthamiana": "Nicotiana benthamiana", "physcomitrium": "Physcomitrium patens", "grape": "Vitis vinifera",
                  "poplar": "Populus trichocarpa", "eucalyptus": "Eucalyptus grandis", "loblolly_pine": "Pinus taeda",
                  "apple": "Malus domestica", "citrus": "Citrus sinensis", "chlamydomonas": "Chlamydomonas reinhardtii",
                  "human": "Homo sapiens", "mouse": "Mus musculus", "rat": "Rattus norvegicus", "zebrafish": "Danio rerio",
                  "fly": "Drosophila melanogaster", "worm": "Caenorhabditis elegans", "xenopus": "Xenopus laevis",
                  "chicken": "Gallus gallus", "pig": "Sus scrofa", "cattle": "Bos taurus", "macaque": "Macaca mulatta",
                  "yeast": "Saccharomyces cerevisiae"}

# words that turn an organism name into a reagent or a reference to another organism's gene
MATERIAL_AFTER = {"oil", "oils", "extract", "extracts", "serum", "sera", "agar", "albumin", "juice", "starch", "flour", "broth",
                  "gelatin", "gelatine", "meal", "bran", "chow", "peptone", "dextrose", "powder", "igg", "igg1", "igg2a", "igg2b",
                  "igm", "iga", "ige", "fab", "monoclonal", "polyclonal", "anti", "antibody", "antibodies", "antiserum",
                  "recombinant", "ortholog", "orthologs", "orthologue", "orthologues", "homolog", "homologs", "homologue",
                  "homologues", "swab", "swabs", "ball", "balls", "wool", "tip", "tips", "pad", "pads", "plug", "plugs"}
MATERIAL_BEFORE = {"anti", "fetal", "foetal", "guinea", "recombinant", "purified", "normal"}   # "normal goat serum"
SPECIFICITY = 3.0          # own-shard paper rate must be >= 3x the median rate in other shards ...
CLEARLY_OWN = 0.5          # ... unless the name is in half its own organism's papers (Arabidopsis, mice)
MIN_PAPERS_TO_JUDGE = int(os.environ.get("SF_MIN_PAPERS", 20))   # names seen in fewer papers overall are kept (too rare to judge)


def toks(s):
    return re.findall(r"[a-z0-9]+", s.lower())


def abbreviations(name):
    w = name.split()
    return {f"{w[0][0]}. {w[1]}".lower()} if len(w) == 2 else set()


def load_names():
    names = {}
    src = VOCAB if os.path.exists(VOCAB) else ALIASES
    with open(src, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if src == ALIASES:
                if r["category"] != "organism":
                    continue
                name, org = r["alias"], r["canonical_term"]
            else:
                name, org = r["name"], r["organism"]
            t = tuple(toks(name))
            if t and not (len(t) == 1 and len(t[0]) <= 2):
                names.setdefault(t, org)
    if src == ALIASES:   # no vocab built yet: at least the scientific names and abbreviations
        for org in set(SHARD_ORGANISM.values()):
            for n in {org} | abbreviations(org):
                names.setdefault(tuple(toks(n)), org)
    return names, src


def mentions(text, names, maxn):
    """[(name_tuple, organism)] in reading order; longest match first; reagent uses skipped."""
    t, out, i = toks(text), [], 0
    while i < len(t):
        for L in range(min(maxn, len(t) - i), 0, -1):
            key = tuple(t[i:i + L])
            if key in names:
                prev = t[i - 1] if i else ""
                nxt = t[i + L] if i + L < len(t) else ""
                if prev not in MATERIAL_BEFORE and nxt not in MATERIAL_AFTER:
                    out.append((key, names[key]))
                i += L
                break
        else:
            i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default="index")
    ap.add_argument("--species", default="", help="comma list of shards to relabel (specificity still uses every shard)")
    a = ap.parse_args()
    names, src = load_names()
    maxn = max(len(k) for k in names)
    print(f"{len(names)} organism names from {os.path.relpath(src)}")
    shards = sorted(d for d in os.listdir(a.index) if os.path.exists(os.path.join(a.index, d, "meta.jsonl")))
    want = {s.strip() for s in a.species.split(",") if s.strip()} or set(shards)

    # pass 1: mentions per passage, and in how many papers of each shard each name occurs
    found, df, n_papers = {}, collections.defaultdict(collections.Counter), {}
    for sp in shards:
        with open(os.path.join(a.index, sp, "meta.jsonl"), encoding="utf-8") as f:
            meta = [json.loads(l) for l in f]
        per_paper = collections.defaultdict(set)
        hits = []
        for m in meta:
            h = mentions(m["text"], names, maxn)
            hits.append(h)
            per_paper[m["pmcid"]].update(k for k, _ in h)
        n_papers[sp] = max(len(per_paper), 1)
        for ks in per_paper.values():
            for k in ks:
                df[k][sp] += 1
        found[sp] = (meta, hits) if sp in want else (None, None)

    # names that are not specific to their organism's shard
    dropped = []
    for k, c in df.items():
        org = names[k]
        own = next((s for s, o in SHARD_ORGANISM.items() if o == org and s in n_papers), None)
        if own is None or sum(c.values()) < MIN_PAPERS_TO_JUDGE:
            continue
        own_rate = c[own] / n_papers[own]
        others = [c[s] / n_papers[s] for s in n_papers if s != own]
        ref = statistics.median(others) if others else 0
        if own_rate < SPECIFICITY * ref and own_rate < CLEARLY_OWN:
            dropped.append((" ".join(k), org, round(own_rate, 3), round(ref, 3)))
    bad = {tuple(d[0].split()) for d in dropped}
    with open(os.path.join(a.index, "_names_dropped.tsv"), "w", encoding="utf-8") as f:
        f.write("name\torganism\town_shard_paper_rate\tmedian_other_rate\n")
        for d in sorted(dropped, key=lambda d: -d[3]):
            f.write("\t".join(map(str, d)) + "\n")
    print(f"dropped {len(dropped)} non-specific names (see {a.index}/_names_dropped.tsv): "
          + ", ".join(d[0] for d in sorted(dropped, key=lambda d: -d[3])[:12]))

    # pass 2: write labels
    for sp in shards:
        meta, hits = found[sp]
        if meta is None:
            continue
        by_paper = collections.defaultdict(collections.Counter)
        for m, h in zip(meta, hits):
            here = collections.Counter(o for k, o in h if k not in bad)
            m["passage_organisms"] = dict(here)   # papers often use two organisms; the passage says which
            by_paper[m["pmcid"]].update(here)
        for m in meta:
            c = by_paper[m["pmcid"]]
            m["organism_main"] = c.most_common(1)[0][0] if c else None
            m["organism_counts"] = dict(c.most_common(4))
        mpath = os.path.join(a.index, sp, "meta.jsonl")
        with open(mpath + ".tmp", "w", encoding="utf-8") as f:
            for m in meta:
                f.write(json.dumps(m, ensure_ascii=False) + "\n")
        os.replace(mpath + ".tmp", mpath)
        papers = {m["pmcid"]: m["organism_main"] for m in meta}
        top = collections.Counter(papers.values()).most_common(3)
        print(f"== {sp}: {len(papers)} papers; main organism: " + ", ".join(f"{o or '?'} {n}" for o, n in top), flush=True)


if __name__ == "__main__":
    main()
