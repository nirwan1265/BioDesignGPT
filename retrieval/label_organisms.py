#!/usr/bin/env python3
"""Label every paper in the index with the organism its own methods text is about.

Papers reach a shard because they mention one of that organism's datasets, which also pulls in
reanalyses and citing papers about other organisms (mouse papers in the rat shard). This counts
organism mentions across each paper's passages (alias table + strain/breed names) and writes
`organism_main` and `organism_counts` into meta.jsonl. No re-embedding; runs on CPU in minutes.

    python retrieval/label_organisms.py --index index              # every shard
    python retrieval/label_organisms.py --index index --species rat
"""
import argparse, collections, csv, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ALIASES = os.path.join(HERE, "..", "inst", "agent", "aliases.tsv")

# extra strain / line names that identify an organism in methods text
EXTRA = {
    "Mus musculus": ["c57bl/6", "c57bl/6j", "c57bl/6n", "balb/c", "129/sv", "fvb", "cd-1", "jackson laboratory", "mice", "mouse",
                     "murine"],
    "Rattus norvegicus": ["sprague-dawley", "sprague dawley", "wistar", "long-evans", "fischer 344", "rats", "rat"],
    "Homo sapiens": ["patients", "participants", "donors", "human"],
    "Drosophila melanogaster": ["drosophila", "flies", "dgrp", "canton-s", "w1118"],
    "Danio rerio": ["zebrafish", "danio rerio"],
    "Caenorhabditis elegans": ["c. elegans", "worms", "nematodes", "n2 bristol"],
    "Arabidopsis thaliana": ["arabidopsis", "col-0", "columbia-0"],
    "Zea mays": ["maize", "b73", "mo17", "zea mays"],
    "Sorghum bicolor": ["sorghum", "btx623"],
    "Oryza sativa": ["rice", "nipponbare", "oryza sativa"],
    "Saccharomyces cerevisiae": ["yeast", "s. cerevisiae", "saccharomyces"],
}


# reagent mentions name an organism without being about it ("rat anti-mouse IgG", "human recombinant TNF")
REAGENT = re.compile(r"\b(?:rat|mouse|rabbit|goat|donkey|human|chicken|sheep|bovine|hamster|guinea pig)\s+(?:anti-?\s*\w+|"
                     r"monoclonal|polyclonal|igg\w*|igm|serum|recombinant|albumin|cdna|genome|reference)\b|"
                     r"\banti-?\s*(?:rat|mouse|rabbit|goat|human)\b|\b(?:fetal|foetal) (?:bovine|calf) serum\b")


def organism_patterns():
    terms = collections.defaultdict(set)
    if os.path.exists(ALIASES):
        with open(ALIASES, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                if r["category"] == "organism" and len(r["alias"]) >= 3:
                    terms[r["canonical_term"]].add(r["alias"].lower())
    for o, al in EXTRA.items():
        terms[o] |= set(al)
    # ambiguous everyday words that are not reliable organism signals in methods text
    for o in terms:
        terms[o] -= {"people", "corn", "apple", "orange", "moss", "frog", "chick", "pig", "cotton"} if o not in ("Sus scrofa",) else set()
    return {o: re.compile(r"(?<![a-z0-9])(?:" + "|".join(sorted(map(re.escape, t), key=len, reverse=True)) + r")(?![a-z0-9])")
            for o, t in terms.items() if t}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default="index")
    ap.add_argument("--species", default="")
    a = ap.parse_args()
    pats = organism_patterns()
    want = {s.strip() for s in a.species.split(",") if s.strip()}
    for sp in sorted(os.listdir(a.index)):
        mpath = os.path.join(a.index, sp, "meta.jsonl")
        if not os.path.exists(mpath) or (want and sp not in want):
            continue
        with open(mpath, encoding="utf-8") as f:
            meta = [json.loads(l) for l in f]
        by_paper = collections.defaultdict(collections.Counter)
        for m in meta:
            t = REAGENT.sub(" ", m["text"].lower())
            for o, p in pats.items():
                n = len(p.findall(t))
                if n:
                    by_paper[m["pmcid"]][o] += n
        main_of = {}
        for pmcid, c in by_paper.items():
            main_of[pmcid] = c.most_common(1)[0][0] if c else None
        for m in meta:
            m["organism_main"] = main_of.get(m["pmcid"])
            m["organism_counts"] = dict(by_paper[m["pmcid"]].most_common(4))
        tmp = mpath + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for m in meta:
                f.write(json.dumps(m, ensure_ascii=False) + "\n")
        os.replace(tmp, mpath)
        papers = {m["pmcid"]: m["organism_main"] for m in meta}
        top = collections.Counter(papers.values()).most_common(3)
        print(f"== {sp}: {len(papers)} papers; main organism: " + ", ".join(f"{o or '?'} {n}" for o, n in top))


if __name__ == "__main__":
    main()
