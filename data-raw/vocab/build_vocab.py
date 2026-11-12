#!/usr/bin/env python3
"""Build the organism vocabulary from sources instead of hand-typed lists.

Every name that identifies one of our organisms -> inst/vocab/organism_names.tsv
(name, organism, kind, source, n_studies, share).

Sources
  NCBI Taxonomy   scientific names, synonyms, common names of each species and everything below it
                  (subspecies, groups, strains), plus the "Z. mays" abbreviation
  BioSample/SRA   strain / cultivar / ecotype / breed / cell-line values recorded in our harvested studies
                  (all_species_by_study.tsv `genotypes`, all_species_study_factors.tsv `fixed`)
  aliases.tsv     the curated organism rows (win any conflict)

General filters, applied the same way to every organism (no per-organism rules):
  missing-value markers ("not applicable", "wild type", "control") are not names
  short or purely numeric tokens ("SD", "X1", "42") are too ambiguous in text; values over 5 words are
    free-text descriptions, not names
  a value must be specific: >= MIN_STUDIES studies and >= MIN_SHARE of its studies in one organism
    (values used across organisms are generic labels, not names)
  a value used at least half as often as a tissue / stage / treatment / sex value ("serum", "leaf") is a
    sample label, not a strain; likewise a single token that starts stage / age values ("E14" from "E14.5")

Run on the login node (downloads ~65 MB taxdump once into --cache):
    python data-raw/vocab/build_vocab.py --evidence /path/to/evidence --cache /path/to/cache
Offline / tests: --taxdump path/to/taxdump.tar.gz, or --no-taxonomy.
"""
import argparse, collections, csv, io, os, re, sys, tarfile, urllib.request

csv.field_size_limit(10 ** 9)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
ALIASES = os.path.join(ROOT, "inst", "agent", "aliases.tsv")
OUT = os.path.join(ROOT, "inst", "vocab", "organism_names.tsv")
TAXDUMP_URL = "https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdump.tar.gz"

SPECIES = ["Sorghum bicolor", "Zea mays", "Arabidopsis thaliana", "Oryza sativa", "Triticum aestivum", "Hordeum vulgare",
           "Glycine max", "Solanum lycopersicum", "Solanum tuberosum", "Gossypium hirsutum", "Medicago truncatula",
           "Brachypodium distachyon", "Setaria viridis", "Nicotiana benthamiana", "Physcomitrium patens", "Vitis vinifera",
           "Populus trichocarpa", "Eucalyptus grandis", "Pinus taeda", "Malus domestica", "Citrus sinensis",
           "Chlamydomonas reinhardtii", "Homo sapiens", "Mus musculus", "Rattus norvegicus", "Danio rerio",
           "Drosophila melanogaster", "Caenorhabditis elegans", "Xenopus laevis", "Gallus gallus", "Sus scrofa", "Bos taurus",
           "Macaca mulatta", "Saccharomyces cerevisiae"]
TAX_CLASSES = {"scientific name", "synonym", "equivalent name", "common name", "genbank common name", "genbank synonym"}
GENO_KEYS = {"strain", "cultivar", "ecotype", "breed", "cell_line", "cell line", "strain background", "line", "variety"}
STAGE_KEYS = {"dev_stage", "age", "stage", "developmental stage", "time", "timepoint"}
MISSING = re.compile(r"^(n/?a|na|none|null|nan|unknown|unspecified|not (applicable|collected|provided|available|determined)|"
                     r"nor applicable|missing|other|mixed?|pool(ed)?|controls?|wild[ -]?types?|wt|mutants?|transgenic|"
                     r"knock[ -]?outs?|ko|normal|healthy|primary( cells?)?|cell lines?|cells?|tissues?|samples?|"
                     r"various|multiple|see .*|[-?.]+)$")
MIN_STUDIES, MIN_SHARE = 2, 0.9


def toks(s):
    return tuple(re.findall(r"[a-z0-9]+", s.lower()))


def norm(s):
    return " ".join(s.split()).strip(" .;,").lower()


def abbreviations(name):
    w = name.split()
    return {f"{w[0][0]}. {w[1]}".lower()} if len(w) == 2 else set()


def too_ambiguous(t):
    if not t:
        return True
    if len(t) == 1:
        x = t[0]
        return x.isdigit() or len(x) <= 2 or (x.isalpha() and len(x) <= 3)
    return all(x.isdigit() for x in t)


# ---------------------------------------------------------------- NCBI Taxonomy
def taxonomy_names(taxdump, species):
    """{name: (organism, kind)} for each species and all its descendant taxa."""
    want = {s.lower(): s for s in species}
    names_by_id, sci_id = collections.defaultdict(list), {}
    parent = {}
    with tarfile.open(taxdump, "r:gz") as tf:
        for member in tf:
            if member.name not in ("names.dmp", "nodes.dmp"):
                continue
            f = io.TextIOWrapper(tf.extractfile(member), encoding="utf-8", errors="replace")
            if member.name == "names.dmp":
                for line in f:
                    p = [x.strip() for x in line.split("|")]
                    tid, name, cls = p[0], p[1], p[3]
                    if cls in TAX_CLASSES:
                        names_by_id[tid].append((name, cls))
                        if cls == "scientific name" and name.lower() in want:
                            sci_id[want[name.lower()]] = tid
            else:
                for line in f:
                    p = line.split("|", 2)
                    parent[p[0].strip()] = p[1].strip()
    root_of = {tid: sp for sp, tid in sci_id.items()}
    missing = [s for s in species if s not in sci_id]
    if missing:
        print("  taxonomy: not found:", ", ".join(missing), file=sys.stderr)

    def species_of(tid):   # walk up until one of our species (or the root)
        seen = 0
        while tid in parent and seen < 60:
            if tid in root_of:
                return root_of[tid]
            if parent[tid] == tid:
                return None
            tid, seen = parent[tid], seen + 1
        return root_of.get(tid)

    out = {}
    for tid, names in names_by_id.items():
        sp = species_of(tid)
        if not sp:
            continue
        for name, cls in names:
            kind = "scientific" if cls == "scientific name" else ("common" if "common" in cls else "synonym")
            out.setdefault(norm(name), (sp, kind if tid == sci_id[sp] else "subtaxon_" + kind))
            for ab in abbreviations(name) if cls == "scientific name" and tid == sci_id[sp] else ():
                out.setdefault(ab, (sp, "abbreviation"))
    return out


def get_taxdump(cache):
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, "taxdump.tar.gz")
    if not os.path.exists(path):
        print("  downloading", TAXDUMP_URL)
        urllib.request.urlretrieve(TAXDUMP_URL, path + ".part")
        os.replace(path + ".part", path)
    return path


# ---------------------------------------------------------------- our harvested studies
def evidence_names(evidence):
    """{value: Counter(organism -> n studies)} for strain/cultivar/... values, and the set of stage first tokens."""
    seen = collections.defaultdict(lambda: collections.defaultdict(set))   # value -> organism -> study ids
    stage_first = collections.Counter()
    other_use = collections.Counter()   # values recorded as tissue / stage / treatment / sex
    bs = os.path.join(evidence, "all_species_by_study.tsv")
    org_of = {}
    with open(bs, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            org, sid = r["organism"], r["study_group"] or r["study"]
            org_of[(r["species"], r["study_group"])] = org
            if org not in SPECIES:   # other organisms that share a species folder are not ours to name
                continue
            for v in re.findall(r"([^;]+?) \(\d+\)", r.get("genotypes") or ""):
                seen[norm(v)][org].add(sid)
            for col in ("tissues", "dev_stage", "treatment", "sex"):
                for v in re.findall(r"([^;]+?) \(\d+\)", r.get(col) or ""):
                    other_use[norm(v)] += 1
                    t = toks(v)
                    if t and col == "dev_stage":
                        stage_first[t[0]] += 1
    sf = os.path.join(evidence, "all_species_study_factors.tsv")
    if os.path.exists(sf):
        with open(sf, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                org = org_of.get((r["species"], r["study_group"]))
                for kv in (r.get("fixed") or "").split("; "):
                    if "=" not in kv:
                        continue
                    k, v = kv.split("=", 1)
                    k = k.strip().lower()
                    if k in GENO_KEYS and org in SPECIES:
                        for part in v.split("/") if " / " in v else [v]:
                            seen[norm(part)][org].add(r["study_group"])
                    elif k in STAGE_KEYS or k in ("tissue", "treatment", "sex", "cell_type"):
                        other_use[norm(v)] += 1
                        t = toks(v) if k in STAGE_KEYS else ()
                        if t:
                            stage_first[t[0]] += 1
    counts = {v: collections.Counter({o: len(s) for o, s in d.items()}) for v, d in seen.items()}
    return counts, stage_first, other_use


def curated_aliases():
    out = {}
    if os.path.exists(ALIASES):
        with open(ALIASES, encoding="utf-8") as f:
            for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                if r["category"] == "organism":
                    out[norm(r["alias"])] = r["canonical_term"]
    return out


def build(evidence, taxdump):
    rows, dropped = {}, collections.Counter()
    by_tokens = {}

    def add(name, org, kind, source, n="", share=""):
        t = toks(name)
        if t in by_tokens:                      # first source wins: aliases > taxonomy > studies
            if by_tokens[t] != org:
                dropped["conflict"] += 1
            return
        by_tokens[t] = org
        rows[name] = (name, org, kind, source, n, share)

    for name, org in curated_aliases().items():
        add(name, org, "alias", "aliases.tsv")
    if taxdump:
        for name, (org, kind) in taxonomy_names(taxdump, SPECIES).items():
            if too_ambiguous(toks(name)):
                dropped["ambiguous"] += 1
                continue
            add(name, org, kind, "ncbi_taxonomy")
    if evidence:
        counts, stages, other_use = evidence_names(evidence)
        for v, c in counts.items():
            t = toks(v)
            total = sum(c.values())
            org, n = c.most_common(1)[0]
            why = ("missing" if MISSING.match(v) else
                   "free_text" if len(t) > 5 else
                   "ambiguous" if too_ambiguous(t) else
                   "sample_label" if other_use[v] >= max(2, 0.5 * n) else
                   "stage" if len(t) == 1 and stages[t[0]] >= max(2, 0.5 * n) else
                   "rare" if n < MIN_STUDIES else
                   "generic" if n / total < MIN_SHARE else None)
            if why:
                dropped[why] += 1
                continue
            add(v, org, "strain_or_line", "biosample", n, round(n / total, 2))
    return sorted(rows.values(), key=lambda r: (r[1], r[3], r[0])), dropped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", help="folder with all_species_by_study.tsv and all_species_study_factors.tsv")
    ap.add_argument("--cache", default="vocab_cache", help="where taxdump.tar.gz is downloaded")
    ap.add_argument("--taxdump", help="use this taxdump.tar.gz instead of downloading")
    ap.add_argument("--no-taxonomy", action="store_true")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    taxdump = None if a.no_taxonomy else (a.taxdump or get_taxdump(a.cache))
    rows, dropped = build(a.evidence, taxdump)
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow(["name", "organism", "kind", "source", "n_studies", "share"])
        w.writerows(rows)
    by_src = collections.Counter(r[3] for r in rows)
    by_org = collections.Counter(r[1] for r in rows)
    print(f"wrote {len(rows)} names -> {a.out}  ({', '.join(f'{k} {v}' for k, v in by_src.items())})")
    print("dropped:", dict(dropped))
    print("per organism:", ", ".join(f"{o.split()[0][0]}. {o.split()[1]} {n}" for o, n in by_org.most_common()))


if __name__ == "__main__":
    main()
