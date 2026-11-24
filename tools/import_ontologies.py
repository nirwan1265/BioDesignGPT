#!/usr/bin/env python3
"""Build inst/agent/vocab/ontology_terms.tsv from anatomy, cell and organelle ontologies.

    python3 tools/import_ontologies.py ext.obo po.obo go-basic.obo

Inputs (OBO format, all CC-BY):
  ext.obo       UBERON extended (anatomy, all species) with the Cell Ontology (CL) merged in
  po.obo        Plant Ontology (plant anatomy)
  go-basic.obo  Gene Ontology (cellular component: organelles, for sample fractions)

Output rows use the rules.tsv columns (category, term, match, pattern, note, source) and the categories the reader
already has: tissue_word (UBERON anatomy, PO plant anatomy), cell_type_word (CL), fraction_word (GO organelles).
source is the ontology id, so every word can be traced back.

What is kept, and why (the reader only counts these words inside a list of two or more, but common words still
make false lists):
  - names and plain EXACT synonyms; no abbreviations, Latin, or other-language synonyms
  - one to three words, letters/digits/hyphen/space only
  - no developmental stages (UBERON life cycle stage subtree; PO stages are another namespace)
  - a one-word term only if it is uncommon English (wordfreq zipf < 4.0): "endometrium" in, "head" out. Common
    words stay in the hand-reviewed rows of rules.tsv, where a person decided
  - a multi-word term only if at least one word is uncommon (zipf < 4.5): "lower leg" out, "small intestine" in
  - a one-word synonym only when it is the first word of the term's name ("thyroid" for "thyroid gland",
    "semimembranosus" for "semimembranosus muscle"); "lunar" for the lunate bone is not
  - not a generic word (GENERIC below), not a word rejected in docs/vocab_review, not already in rules.tsv, and not
    a word another rules.tsv category owns (larva, pupa, blastocyst are stages; calf is an animal; a plant
    "... cell" is a cell type, not a tissue)
"""
import csv, glob, os, re, sys
from collections import defaultdict

from wordfreq import zipf_frequency

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "inst", "agent", "vocab", "ontology_terms.tsv")
GENERIC = {"entity", "structure", "part", "region", "system", "segment", "zone", "layer", "surface", "side", "organ",
           "tissue", "cell", "compartment", "subdivision", "cluster", "set", "group", "element", "material", "space",
           "cavity", "organism", "body", "portion", "unit", "complex", "component", "matrix", "junction", "process"}
GENERIC_START = ("anatomical ", "multicellular ", "material ", "acellular ", "portion of ", "organism ", "whole ",
                 "plant structure", "plant anatomical", "cardinal ", "native ", "obsolete ")
STAGE_ROOTS = {"UBERON:0000105"}            # life cycle stage
ORGANELLE_ROOTS = {"GO:0043226"}           # organelle
NAME_OK = re.compile(r"^[a-z0-9][a-z0-9 '-]*[a-z0-9]$")


def parse(path):
    terms, cur = {}, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line == "[Term]":
            cur = {"is_a": [], "syn": []}
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = None
            continue
        if cur is None or ": " not in line:
            continue
        k, v = line.split(": ", 1)
        if k == "id":
            cur["id"] = v; terms[v] = cur
        elif k == "name":
            cur["name"] = v
        elif k == "namespace":
            cur["ns"] = v
        elif k == "is_obsolete" and v == "true":
            cur["obsolete"] = True
        elif k == "is_a":
            cur["is_a"].append(v.split(" ", 1)[0])
        elif k == "synonym":
            m = re.match(r'"(.*)" (EXACT)(?: ([A-Za-z_:]+))? \[', v)
            if m and not m.group(3):          # plain EXACT only: no ABBREVIATION, LATIN, Spanish, ...
                cur["syn"].append(m.group(1))
    return terms


def descendants(terms, roots):
    kids = defaultdict(list)
    for t in terms.values():
        for p in t["is_a"]:
            kids[p].append(t["id"])
    seen, stack = set(), list(roots)
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x); stack.extend(kids[x])
    return seen


def ok(name):
    if not NAME_OK.match(name) or name.startswith(GENERIC_START):
        return False
    w = name.split()
    if not 1 <= len(w) <= 3 or len(name) < 4:
        return False
    if len(w) == 1:
        return name not in GENERIC and zipf_frequency(name, "en") < 4.0
    return min(zipf_frequency(x, "en") for x in w) < 4.5


def main(ext, po, go):
    existing, rejected, owner = set(), set(), defaultdict(set)
    sing = lambda w: re.sub(r"^(.+[^s])s$", r"\1", w)
    with open(os.path.join(ROOT, "inst", "agent", "rules.tsv"), encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            existing.add((r["category"], r["pattern"].lower()))
            if r["match"] in ("word", "value"):
                owner[sing(r["pattern"].lower())].add(r["category"])
    for f in glob.glob(os.path.join(ROOT, "docs", "vocab_review", "*rejected*.tsv")):
        for r in csv.DictReader(open(f, encoding="utf-8"), delimiter="\t"):
            rejected.add(r["word"].lower())

    rows, seen = [], set()

    def add(cat, t, label, note):
        for k, n in enumerate([t.get("name", "")] + t["syn"]):
            n = n.lower().strip()
            if n in rejected or (cat, n) in existing or (cat, n) in seen or not ok(n):
                continue
            if k > 0 and " " not in n and n != t.get("name", "").lower().split(" ")[0]:
                continue                        # odd one-word synonyms ("lunar") are where false matches come from
            if owner[sing(n)] - {cat} or (cat == "tissue_word" and n.endswith(" cell")):
                continue
            seen.add((cat, n))
            rows.append([cat, "", "value", n, note, t["id"]])

    u = parse(ext)
    stages = descendants(u, STAGE_ROOTS)
    for t in u.values():
        if t.get("obsolete") or "name" not in t:
            continue
        if t["id"].startswith("UBERON:") and t["id"] not in stages:
            add("tissue_word", t, "UBERON", "UBERON anatomy (CC-BY 3.0)")
        elif t["id"].startswith("CL:"):
            add("cell_type_word", t, "CL", "Cell Ontology (CC-BY 4.0)")
    p = parse(po)
    for t in p.values():
        if not t.get("obsolete") and t.get("ns") == "plant_anatomy" and "name" in t:
            add("tissue_word", t, "PO", "Plant Ontology anatomy (CC-BY 4.0)")
    g = parse(go)
    org = descendants(g, ORGANELLE_ROOTS)
    for t in g.values():
        if not t.get("obsolete") and t["id"] in org and "name" in t:
            add("fraction_word", t, "GO", "Gene Ontology organelle (CC-BY 4.0)")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("category\tterm\tmatch\tpattern\tnote\tsource\n")
        for r in sorted(rows, key=lambda r: (r[0], r[3])):
            f.write("\t".join(r) + "\n")
    counts = defaultdict(int)
    for r in rows:
        counts[r[0]] += 1
    print(OUT, dict(counts))


if __name__ == "__main__":
    main(*sys.argv[1:4])
