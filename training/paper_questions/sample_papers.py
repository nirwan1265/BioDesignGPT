#!/usr/bin/env python3
"""Sample real papers for a paper-grounded test set.

For each sampled paper: its title, the study metadata we harvested (technique, tissues, factors) and the
first methods passages (growth, animals, design) from the index. A question is then written from each paper
the way a researcher would ask *before* doing that study, with the gold StudySpec taken from what the paper
did. Labels come from the papers, not from our rules or the reader.

Only papers whose own text is about the shard's organism (label_organisms.py) are used, stratified by
species x technique. The held-out species (setaria, poplar, zebrafish, xenopus) are marked: no model was
trained on them.

    python training/paper_questions/sample_papers.py --index INDEX --evidence EVIDENCE --n 1300 --out papers_sample.jsonl

A later draw (e.g. a training pool) excludes papers already sampled and continues the ids:

    ... --n 1500 --seed 2027 --exclude papers_sample_1700.jsonl.gz --id-start 1700 --no-held-out --out papers_sample_train.jsonl

A draw aimed at the gaps (draw 4): papers are drawn with weights instead of round-robin. The weight of a paper is
the product of (a) its study kind, from regex rows over its methods text in a weights TSV (draws/draw4_weights.tsv),
and (b) how short we are of its species and technique, from the batches labelled so far: sqrt(median / labelled
questions), times the share of read papers that gave a question (so kinds we always skip are not fetched again).
The first --lock papers form a locked test part that rules are never written from; the rest are split into
--rounds parts of equal size:

    ... --n 2500 --seed 2028 --exclude batches/*.jsonl --id-start 5700 --no-held-out \
        --weights draws/draw4_weights.tsv --balance batches --lock 250 --rounds 5 --out papers_sample_draw4.jsonl
"""
import argparse, collections, csv, json, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "retrieval"))
from label_organisms import SHARD_ORGANISM  # noqa: E402

csv.field_size_limit(10 ** 9)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import rules  # noqa: E402
HELD_OUT = set(rules.keys("held_out_species"))   # inst/agent/rules.tsv


import re

# methods sentences that describe the design (what was grown/treated/sampled, how many, how randomised)
DESIGN_RX = re.compile(r"\b(grown|sown|planted|plants? were|seedlings?|mice|rats?|animals?|fish|larvae|embryos|flies|"
                       r"cells? were|treated|treatment|exposed|fed|diet|infected|inoculated|stress|control|"
                       r"replicat\w*|randomi[sz]\w*|blocks?|plots?|pots?|cages?|litters?|pooled|harvested|collected|"
                       r"sampled|dissected|\d+\s*(?:days?|weeks?|h|hours?)\b|°c|\bn\s*=\s*\d+|per (?:group|condition|treatment))",
                       re.I)
SENT = re.compile(r"(?<=[.!?])\s+(?=[A-Z(])")


def digest(text, limit=1600):
    """Up to `limit` characters of the design sentences, in reading order."""
    keep, n = [], 0
    for s in SENT.split(text):
        s = s.strip()
        if len(s) < 30 or len(DESIGN_RX.findall(s)) < 2:
            continue
        if n + len(s) > limit:
            break
        keep.append(s)
        n += len(s) + 1
    return " ".join(keep)


def read_tsv(p):
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def balance_weights(folder):
    """sqrt(median / labelled questions) x share of read papers that gave a question, per species and technique"""
    import glob, statistics
    read, kept = collections.Counter(), collections.Counter()
    for f in glob.glob(os.path.join(folder, "*.jsonl")):
        for l in open(f, encoding="utf-8"):
            if l.strip():
                r = json.loads(l)
                for key in (("species", r.get("species")), ("technique", r.get("technique"))):
                    read[key] += 1
                    kept[key] += 0 if r.get("skip") else 1
    w = {}
    for what in ("species", "technique"):
        ks = [k for k in read if k[0] == what]
        med = statistics.median([kept[k] for k in ks]) if ks else 1
        for k in ks:
            short = min(3.0, max(0.5, (med / max(kept[k], 1)) ** 0.5))
            yield_ = (kept[k] + 1) / (read[k] + 2)
            w[k] = short * yield_
    return w


def weighted_draw(pool, a, rnd):
    """weighted sampling without replacement (key u^(1/w)); a paper's kind is the heaviest kind row it matches"""
    import math
    kinds = [(re.compile(r["match"], re.I), float(r["weight"]), r["name"])
             for r in read_tsv(a.weights) if r.get("what") == "kind"]
    bal = balance_weights(a.balance) if a.balance else {}
    keyed = []
    for p in pool:
        text = p["methods"]
        hits = [(w, name) for rx, w, name in kinds if rx.search(text)]
        wk, name = max(hits) if hits else (1.0, "other")
        w = wk * bal.get(("species", p["species"]), 1.0) * bal.get(("technique", p["technique"]), 1.0)
        p["kind"], p["weight"] = name, round(w, 3)
        keyed.append((math.log(rnd.random()) / w, p["pmcid"], p))
    keyed.sort(key=lambda x: (-x[0], x[1]))
    return [p for _, _, p in keyed[:a.n]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--n", type=int, default=1300)
    ap.add_argument("--passages", type=int, default=4, help="first N passages of each paper's methods")
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--out", default="papers_sample.jsonl")
    ap.add_argument("--exclude", nargs="*", default=[],
                    help="jsonl files (earlier samples or label batches) whose pmcids must not be drawn again")
    ap.add_argument("--no-held-out", action="store_true", help="skip the held-out species (for a training pool)")
    ap.add_argument("--id-start", type=int, default=0, help="first paper number, so ids continue past earlier samples")
    ap.add_argument("--weights", help="TSV of kind weights (what, name, match, weight, note): weighted draw instead of round-robin")
    ap.add_argument("--balance", help="folder of labelled batches: weight species and techniques we are short of")
    ap.add_argument("--lock", type=int, default=0, help="first N drawn papers form a locked test part")
    ap.add_argument("--rounds", type=int, default=1, help="split the rest into this many parts")
    a = ap.parse_args()
    seen = set()
    for path in a.exclude:
        opener = __import__("gzip").open if path.endswith(".gz") else open
        with opener(path, "rt", encoding="utf-8") as f:
            seen.update(json.loads(l).get("pmcid") for l in f if l.strip())
    seen.discard(None)
    rnd = random.Random(a.seed)
    titles = {r["pmcid"]: r for r in read_tsv(os.path.join(a.evidence, "all_species_papers.tsv")) if r.get("pmcid")}
    mfields = ("environment", "temperature", "photoperiod", "age_stage", "sampling_time", "design", "blocks_or_field_reps",
               "bio_reps", "independent_repeats", "tech_reps", "pooled", "pooled_n", "stats")
    methods_by = {}
    for r in read_tsv(os.path.join(a.evidence, "all_species_study_methods.tsv")):
        if r.get("pmcid"):
            methods_by.setdefault(r["pmcid"], {k: r[k] for k in mfields if r.get(k)})
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
            if a.no_held_out and sp in HELD_OUT:
                continue
            if pmcid in seen:
                continue   # already sampled for an earlier batch
            if ms[0].get("organism_main") != SHARD_ORGANISM.get(sp):
                continue   # only papers whose own methods are about this shard's organism (label_organisms.py)
            techs = ms[0].get("techniques") or ["?"]
            text = " ".join(m["text"] for m in ms[:a.passages])
            if len(text) < 1500 or len(digest(text)) < 400:   # too little design description to label
                continue
            for t in techs[:1]:
                cands[(sp, t)].append({"pmcid": pmcid, "species": sp, "technique": t, "techniques": techs,
                                       "doi": ms[0].get("doi"), "year": ms[0].get("year"),
                                       "study_groups": ms[0].get("study_groups", []), "methods": text[:5000]})
    keys = sorted(cands)
    for k in keys:
        rnd.shuffle(cands[k])
    rnd.shuffle(keys)
    if a.weights:
        picked = weighted_draw([p for k in keys for p in cands[k]], a, rnd)
    else:
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
            if a.weights:
                p["part"] = "test" if i < a.lock else 1 + (i - a.lock) * a.rounds // max(1, len(picked) - a.lock)
            p.update({"id": f"paper_{a.id_start + i:04d}", "title": t.get("title", ""), "journal": t.get("journal", ""),
                      "held_out_species": p["species"] in HELD_OUT, "study_metadata": meta,
                      "method_fields": methods_by.get(p["pmcid"], {}), "digest": digest(p["methods"])})
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    if a.weights:
        for part, n in sorted(collections.Counter(str(p["part"]) for p in picked).items()):
            print(f"part {part}: {n} papers")
        for k, n in collections.Counter(p["kind"] for p in picked).most_common():
            print(f"  kind {k:14s} {n}")
        for k, n in collections.Counter(p["technique"] for p in picked).most_common(12):
            print(f"  technique {k:28s} {n}")
    c = collections.Counter(p["species"] for p in picked)
    print(f"wrote {len(picked)} papers from {len(c)} species -> {a.out}; held-out species: "
          f"{sum(p['species'] in HELD_OUT for p in picked)}")


if __name__ == "__main__":
    main()
