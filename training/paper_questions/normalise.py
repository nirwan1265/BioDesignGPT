"""Bring hand-written labels up to the current schema (applied by write_batch.py to every record).

The labels were written while the schema lacked some assays and a livestock setting; the gaps were logged per
question (`gaps`). Now that inst/agent/aliases.tsv and llm/reader.py have them, this fills them in, using the
same rule as the R extractor: an assay is added only when one of its aliases appears in the question, so the
gold spec still contains only what the question states.
    schema 2: new assays (amplicon, m6a_seq, long_read_rna, gbs, degradome, hic, scatac_seq, medip, mnase_seq,
              nascent_rna, spatial, targeted_capture, rip_clip, metagenomics, pool_seq, bsa_seq, trap_seq, wgs),
              system "livestock", factor names phenotype -> phenotype_group and strain -> genotype.
    schema 3: system is the stated setting (growth chamber, greenhouse, field, mice/rats, flies, farm animals,
              cell lines) rather than the assay family when the question names one (training/setting.py).
"""
import csv, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALIASES = os.path.join(HERE, "..", "..", "inst", "agent", "aliases.tsv")
sys.path.insert(0, os.path.join(HERE, ".."))
import setting  # noqa: E402
SCHEMA = 3
import rules  # noqa: E402   inst/agent/rules.tsv
NEW_ASSAYS = set(rules.keys("schema2_assay"))
# a specific assay replaces the generic label used for it before, unless the generic one is also stated on its own
STANDS_IN_FOR = {k: set(v) for k, v in rules.groups("generic_assay").items()}
FACTOR_RENAME = rules.mapping("factor_rename")
_TABLE = None


def _table(category):
    global _TABLE
    if _TABLE is None:
        with open(ALIASES, encoding="utf-8") as f:
            _TABLE = [(r["alias"].strip().lower(), r["canonical_term"].strip(), r["category"].strip())
                      for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE)]
    return sorted(((a, c) for a, c, cat in _TABLE if cat == category), key=lambda x: -len(x[0]))


def find_all(text, category):
    """Canonical terms of every alias found, longest alias first, no overlaps (same rule as R .sf_find_all)."""
    text = text.lower()
    taken = [False] * len(text)
    hits = []
    for alias, canon in _table(category):
        for m in re.finditer(r"(?<![a-z0-9])" + re.escape(alias) + r"(?![a-z0-9])", text):
            if any(taken[m.start():m.end()]):
                continue
            taken[m.start():m.end()] = [True] * (m.end() - m.start())
            hits.append((m.start(), canon))
    out = []
    for _, c in sorted(hits):
        if c not in out:
            out.append(c)
    return out


def normalise(rec):
    if rec.get("skip"):
        return rec
    spec = rec["expected_spec"]
    stated = set(find_all(rec["prompt"], "assay"))
    assays = list(spec.get("assays", []))
    for a in sorted(stated & NEW_ASSAYS):
        if a not in assays:
            assays.append(a)
        for g in STANDS_IN_FOR.get(a, ()):
            if g in assays and g not in stated:
                assays.remove(g)
    if assays:
        spec["assays"] = assays
    for f in spec.get("factors", []):
        f["name"] = FACTOR_RENAME.get(f["name"], f["name"])
    if not spec.get("system") and any(g.startswith("setting:livestock") for g in rec.get("gaps", [])):
        spec["system"] = "livestock"
    setting.apply(spec, rec["prompt"])
    rec["schema"] = SCHEMA
    return rec
