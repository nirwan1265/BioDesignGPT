#!/usr/bin/env python3
"""Training prompts grounded in real experiments (the evidence layer).

Every designed study harvested from ENA/SRA/GEO with a recovered factor structure
(BioSample attributes or sample names) becomes several prompts written the way a
researcher would describe that experiment: the real organism, assay, tissue, factors
and levels, replicates per cell, and growth environment from the paper. Tags are
correct by construction (same clause machinery as generate.py); the StudySpec label is
produced by the package's own decoder from the gold tags, so labels and decoder agree.

    python training/grounded.py --evidence path/to/evidence --out training/data \
        --per-study 2 --seed 7 --holdout setaria,poplar,zebrafish,xenopus

Writes grounded_train.jsonl, grounded_dev.jsonl (5% of training species' studies),
grounded_test.jsonl (held-out species, tagger format), grounded_eval.jsonl
(held-out species, evaluate_extraction() format), grounded_stats.json.
"""
import argparse, collections, csv, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "inst", "python"))
import generate as G          # noqa: E402  clause machinery, tokenizer, aliases
import decode as D            # noqa: E402  tags -> StudySpec, exactly as at inference

csv.field_size_limit(10 ** 9)

# technique -> (system, assay phrases)
TECH = {
    "Bulk RNA-seq": ("bulk_rnaseq", ["RNA-seq", "bulk RNA-seq", "RNA-seq", "transcriptome profiling", "mRNA-seq"]),
    "3' Tag-seq": ("bulk_rnaseq", ["3' Tag-seq", "QuantSeq 3' mRNA-seq", "Tag-seq"]),
    "small RNA-seq": ("bulk_rnaseq", ["small RNA-seq", "sRNA-seq", "miRNA-seq"]),
    "Long-read RNA (Iso-Seq/ONT)": ("bulk_rnaseq", ["RNA-seq"]),
    "scRNA/snRNA-seq": ("single_cell", ["scRNA-seq", "single-cell RNA-seq", "snRNA-seq"]),
    "scATAC-seq": ("single_cell", ["scATAC-seq"]),
    "Ribo-seq": ("ribo_seq", ["Ribo-seq", "ribosome profiling"]),
    "ATAC-seq": ("atac_seq", ["ATAC-seq", "ATAC-seq"]),
}

# the measured outcome each assay implies (decodes via the outcome aliases)
OUTCOME_BY_TECH = {t: ["gene expression", "differential expression", "transcript abundance"]
                   for t in ("Bulk RNA-seq", "3' Tag-seq", "Long-read RNA (Iso-Seq/ONT)")}
OUTCOME_BY_TECH["Ribo-seq"] = ["translation efficiency", "translational efficiency"]
OUTCOME_BY_TECH["ATAC-seq"] = ["accessible regions"]

# factor attribute -> role
ROLE = {}
for k in ["genotype", "cultivar", "strain", "ecotype", "line", "breed", "genetic_mod", "population", "variety",
          "accession", "genetic background", "background", "cell_line", "cell line"]:
    ROLE[k] = "genotype"
for k in ["treatment", "condition", "group", "stress", "compound", "stimulus", "growth condition", "growth_protocol",
          "sample group", "experiment", "agent", "drug", "infection", "diet", "temp", "temperature"]:
    ROLE[k] = "treatment"
for k in ["time", "timepoint", "time point", "collection_date", "sampling time point", "time after treatment"]:
    ROLE[k] = "time"
for k in ["dev_stage", "stage", "developmental stage", "generation"]:
    ROLE[k] = "stage"
ROLE["age"] = "age"
for k in ["tissue", "cell_type", "cell type", "sample_type", "cell_subtype", "isolation_source", "organism part", "organ"]:
    ROLE[k] = "tissue"
for k in ["disease", "disease_stage", "health_state", "phenotype", "disease state"]:
    ROLE[k] = "disease"
ROLE["sex"] = "sex"
ROLE["batch"] = "batch"
ROLE["geo_loc_name"] = "location"

NAME_RULES = [  # for name_partN factors, classify by the level values
    ("genotype", r"^(wt|wild[- ]?type|col-?0|ler|b73|mo17|ko|kd|oe|ox|mut|mutant|cr|crispr|ri|rnai|nil)\b|-\d+$|^[a-z]{2,5}\d{1,3}$"),
    ("time", r"^(\d+(\.\d+)?\s?(h|hr|hrs|d|dae|dap|dpa|dpi|hpi|hpa|wk|w|min|m|day|days|weeks?)|[tdh]\d{1,3}|day\s?\d+|0h|zt\d+)$"),
    ("treatment", r"^(ctrl|ck|control|mock|treat(ed)?|drought|ww|ds|wd|heat|ht|cold|ct|salt|nacl|aba|ja|meja|sa|eth|n\d|p\d|low|high|lp|hp|ln|hn|nn|sn|infected|uninfected|inf|pb|cd|as)$"),
    ("tissue", r"^(leaf|leaves|root|roots|stem|seed|seeds|flower|shoot|ear|tassel|bud|fruit|liver|brain|muscle|kidney|heart|lung|embryo|endosperm|anther|pollen|callus|panicle|silk|husk)$"),
]

NOUN = {  # (k, noun) phrasing per role -> FACTOR span text (aliases resolve these)
    "treatment": ["treatments", "conditions", "treatment groups", "stress treatments"],
    "time": ["time points", "timepoints", "harvest times", "sampling times"],
    "stage": ["developmental stages", "growth stages", "stages"],
    "age": ["ages", "age groups"],
    "tissue": ["tissues", "organs", "tissue types"],
    "disease": ["disease groups", "disease states"],
}
GENO_NOUN = {"plant": ["genotypes", "lines", "cultivars", "accessions"], "animal": ["strains", "genotypes", "lines", "breeds"],
             "cell": ["cell lines", "genotypes"], "micro": ["strains", "genotypes"]}
REP_NOUN = {"plant": ["biological replicates", "replicates", "reps", "biological reps", "replicate plants"],
            "animal": ["animals per group", "biological replicates", "replicates", "individuals per group"],
            "human": ["donors per group", "biological replicates", "replicates", "samples per group"],
            "micro": ["biological replicates", "replicate cultures", "replicates"]}
ORG_ALIASES = collections.defaultdict(list)
for (cat, canon), al in G.AL.items():
    if cat == "organism":
        ORG_ALIASES[canon] += al

CLEAN_TISSUE = {"leaves": "leaf", "roots": "root", "seedlings": "seedling", "seeds": "seed", "shoots": "shoot",
                "flowers": "flower", "fruits": "fruit", "stems": "stem", "whole plant": "whole plant", "whole plants": "whole plant",
                "embryos": "embryo", "buds": "bud", "panicles": "panicle", "berries": "berry", "tubers": "tuber"}


def kind(group, organism):
    if organism == "Homo sapiens":
        return "human"
    if group in ("plant", "tree", "alga"):
        return "plant"
    if organism == "Saccharomyces cerevisiae":
        return "micro"
    return "animal"


def clean_tissue(t):
    if not t:
        return None
    t = re.sub(r"\s*\(\d+\)$", "", t.split(";")[0]).strip().lower()
    if not t or len(t) > 30 or re.search(r"\d{3,}|[:/=_]|^(missing|not |na$|n/a|unknown|whole organism|sample|tissue)", t):
        return None
    return CLEAN_TISSUE.get(t, t)


def parse_factors(s):
    """'treatment[control, drought] x time point[3]' -> [(name, k, [levels])]"""
    out = []
    for part in (s or "").split(" x "):
        m = re.match(r"^(.+?)\[(.*)\]$", part.strip())
        if not m:
            continue
        name, inside = m.group(1).strip(), m.group(2)
        if re.fullmatch(r"\d+", inside):
            out.append((name, int(inside), []))
        else:
            lv = [v.strip() for v in inside.split(", ") if v.strip()]
            out.append((name, len(lv), lv))
    return out


def role_of(name, levels):
    r = ROLE.get(name.lower())
    if r:
        return r
    if name.startswith("name_part") and levels:
        for role, rx in NAME_RULES:
            if all(re.search(rx, v.strip().lower()) for v in levels):
                return role
    return None


def clean_levels(levels):
    """Levels fit to write out in a prompt (short, word-like, no IDs)."""
    if not levels or any(len(v) > 22 or re.search(r"[|;=]|\d{4,}|^(sample|rep|s)\d+$", v.lower()) for v in levels):
        return None
    return levels


def say_levels(levels):
    if len(levels) == 2:
        return f"{levels[0]} and {levels[1]}"
    return ", ".join(levels[:-1]) + " and " + levels[-1]


def clause_factor(e, role, k, levels, kd):
    """Emit one factor clause with tags; record the spec factor via the decoder later."""
    R = G.R
    lv = clean_levels(levels)
    n = G.numtxt(k, R)
    if role == "genotype":
        noun = G.pick(GENO_NOUN["cell" if kd == "human" else ("micro" if kd == "micro" else kd if kd in GENO_NOUN else "animal")])
        tail = f"({say_levels(lv)})" if lv and k <= 4 and G.maybe(0.6) else ""
        return lambda: e.say(G.pick(["", "in", "across", "comparing"]), (n, "GENO_N"), noun, tail)
    if role == "sex":
        return lambda: e.say(G.pick(["using", "in", "with", ""]), (G.pick(["males and females", "both sexes", "male and female"]), "FACTOR"),
                             G.pick(["", "animals"]) if kd != "human" else "")
    if role == "batch":
        return lambda: e.say(G.pick(["libraries prepared in", "libraries split across", "with libraries in"]), n, ("batches", "BLOCK"))
    if role == "location":
        return lambda: e.say("at", (n, "LOC_N"), G.pick(["sites", "locations", "field sites"]))
    if role in NOUN:
        # two named levels can be written "A vs B" only when the decoder can resolve the factor from them
        if lv and k == 2 and role == "treatment" and D.canon(f"{lv[0]} vs {lv[1]}", "factor") and G.maybe(0.6):
            return lambda: e.say(G.pick(["under", "comparing", "for"]), (f"{lv[1]} vs {lv[0]}", "FACTOR"))
        tail = f"({say_levels(lv)})" if lv and G.maybe(0.6) else ""
        return lambda: e.say(G.pick(["across", "at", "over", "with", "for"]), (n, "LEVELS_N"), (G.pick(NOUN[role]), "FACTOR"), tail)
    return None


def build(row, R, n_variants):
    """One study -> list of examples (or [] if it can't be described faithfully)."""
    sysname, assays = TECH[row["technique"]]
    organism = row["organism"]
    kd = kind(row["group"], organism)
    facs = []
    for name, k, levels in parse_factors(row["factors"]):
        role = role_of(name, levels)
        if role is None or k < 2 or k > 24:
            continue
        if role in ("tissue",) and sysname == "single_cell":
            continue
        if any(r == role for r, _, _ in facs):
            continue
        facs.append((role, k, levels))
    if not facs:
        return []
    rp = row.get("reps_per_cell") or ""
    reps = int(float(rp)) if re.fullmatch(r"\d+(\.0)?", rp) else None
    if reps is not None and not (1 <= reps <= 12):
        reps = None
    tissue = clean_tissue(row.get("tissues"))
    env = row.get("environment") or ""
    out = []
    for v in range(n_variants):
        G.R = R  # generate.py helpers use G.R
        e = G.Ex(R, sysname, "grounded_" + re.sub(r"[^a-z0-9]+", "_", row["technique"].lower()).strip("_"))
        al = [a for a in ORG_ALIASES.get(organism, [organism]) if len(a) > 2] or [organism]
        org_t = (G.pick(al), "ORG")
        assay_t = (G.pick(assays), "ASSAY")
        tis = f"{tissue} samples" if tissue and not any(r == "tissue" for r, _, _ in facs) and G.maybe(0.7) else ""
        lead = G.pick([
            lambda: e.say(G.pick(["Planning", "We want to do", "I'm designing", "Designing", "Setting up"]), assay_t, G.pick(["of", "on", "in"]), tis, org_t),
            lambda: e.say(org_t, tis, assay_t, G.pick(["experiment", "study", "project"])),
            lambda: e.say(assay_t, G.pick(["of", "on"]), org_t, tis),
        ])
        pieces = [lead]
        for role, k, levels in facs:
            c = clause_factor(e, role, k, levels, kd)
            if c:
                pieces.append(c)
        rep_said = False
        if reps is not None and G.maybe(0.85):
            nouns = REP_NOUN.get(kd, REP_NOUN["plant"])
            if reps == 1:
                pieces.append(lambda: e.say(G.pick(["with only", "only"]), ("one", "REPS_N"), G.pick(["sample per condition", "replicate each"])))
            else:
                pieces.append(lambda: e.say(G.pick(["with", "using", "", "n ="]), (G.numtxt(reps, R), "REPS_N"), G.pick(nouns),
                                            G.pick(["", "per condition", "each", ""])))
            rep_said = True
        oc = OUTCOME_BY_TECH.get(row["technique"])
        if oc and G.maybe(0.35):
            pieces.append(lambda: e.say(G.pick(["to look at", "to compare", "to measure", "for"]), (G.pick(oc), "OUTCOME")))
        sys_v = sysname
        if kd == "plant" and env and G.maybe(0.6):
            et = {"greenhouse": ["greenhouse", "glasshouse"], "growth_chamber": ["growth chamber", "growth chambers"],
                  "field": ["field", "the field"]}.get(env)
            if et:
                pieces.append(lambda: e.say(G.pick(["plants grown in a", "grown in the", "in a"]), (G.pick(et), "ENV")))
                sys_v = env   # a stated setting is the system; the assay stays in assays (training/setting.py)
        G.join(e, pieces)
        ex = e.render()
        ex["text"] = re.sub(r"\s{2,}", " ", ex["text"]).strip()
        spec = D.to_spec(ex["tokens"], ex["tags"], sys_v, ex["text"])
        spec.pop("status", None)
        ex["spec"] = spec
        ex["truth"] = {"species": row["species"], "study_group": row["study_group"], "technique": row["technique"],
                       "factors": row["factors"], "reps_per_cell": rp, "doi": row.get("doi") or None}
        ex["must_ask"] = [] if rep_said else ["design.reps"]
        out.append(ex)
    return out


def load(evdir):
    def rd(name):
        p = os.path.join(evdir, name)
        return list(csv.DictReader(open(p, encoding="utf-8"), delimiter="\t")) if os.path.exists(p) else []
    bs = {(r["species"], r["study_group"], r["technique"]): r for r in rd("all_species_by_study.tsv")}
    env = {}
    for r in rd("all_species_study_methods.tsv"):
        e = (r.get("environment") or "").split(";")[0].strip()
        if e in ("greenhouse", "growth_chamber", "field"):
            env.setdefault((r["species"], r["study_group"]), e)
    doi = {}
    for r in rd("all_species_papers.tsv"):
        if r.get("confidence") == "linked" and r.get("doi"):
            doi.setdefault((r["species"], r["study_group"]), r["doi"])
    rows = []
    for f in rd("all_species_study_factors.tsv"):
        if f["technique"] not in TECH or f["n_factors"] in ("", "0"):
            continue
        b = bs.get((f["species"], f["study_group"], f["technique"]))
        if not b:
            continue
        r = dict(f)
        r.update({"organism": b["organism"], "group": b["group"], "tissues": b.get("tissues", ""),
                  "environment": env.get((f["species"], f["study_group"]), ""),
                  "doi": doi.get((f["species"], f["study_group"]), "")})
        rows.append(r)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "data"))
    ap.add_argument("--per-study", type=int, default=2)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--holdout", default="setaria,poplar,zebrafish,xenopus")
    ap.add_argument("--max-per-species", type=int, default=1500, help="cap so mouse/human don't dominate")
    ap.add_argument("--eval-n", type=int, default=300)
    a = ap.parse_args()
    R = random.Random(a.seed)
    hold = set(x.strip() for x in a.holdout.split(",") if x.strip())
    rows = load(a.evidence)
    by_sp = collections.defaultdict(list)
    for r in rows:
        by_sp[r["species"]].append(r)
    train, dev, test = [], [], []
    stats = collections.Counter()
    for sp, rs in sorted(by_sp.items()):
        R.shuffle(rs)
        rs = rs[:a.max_per_species]
        for r in rs:
            exs = build(r, R, a.per_study)
            if not exs:
                stats["skipped_no_usable_factor"] += 1
                continue
            stats["studies_used"] += 1
            stats["tech:" + r["technique"]] += 1
            if sp in hold:
                test += exs[:1]
            elif R.random() < 0.05:
                dev += exs[:1]
            else:
                train += exs
    os.makedirs(a.out, exist_ok=True)
    for name, data in (("grounded_train", train), ("grounded_dev", dev), ("grounded_test", test)):
        with open(os.path.join(a.out, name + ".jsonl"), "w") as f:
            for ex in data:
                f.write(json.dumps(ex) + "\n")
    # balance the evaluation set across held-out species (zebrafish would otherwise dominate)
    per = collections.defaultdict(list)
    for ex in test:
        per[ex["truth"]["species"]].append(ex)
    ev, quota = [], max(1, a.eval_n // max(1, len(per)))
    for sp in sorted(per):
        ev += R.sample(per[sp], min(quota, len(per[sp])))
    rest = [ex for ex in test if ex not in ev]
    ev += R.sample(rest, min(max(0, a.eval_n - len(ev)), len(rest)))
    with open(os.path.join(a.out, "grounded_eval.jsonl"), "w") as f:
        for i, ex in enumerate(ev):
            f.write(json.dumps({"id": f"g_{i:03d}", "prompt": ex["text"], "expected_spec": ex["spec"],
                                "must_ask": ex["must_ask"], "source": ex["truth"]}) + "\n")
    stats.update({"train": len(train), "dev": len(dev), "test_heldout": len(test), "eval": len(ev),
                  "species_train": len([s for s in by_sp if s not in hold]), "species_heldout": len(hold & set(by_sp))})
    json.dump(dict(stats), open(os.path.join(a.out, "grounded_stats.json"), "w"), indent=1)
    print(json.dumps(dict(stats), indent=1))


if __name__ == "__main__":
    main()
