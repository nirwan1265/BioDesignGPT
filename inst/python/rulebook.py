"""Read inst/agent/rules.tsv, the one table of words and patterns (R reads it through R/registry.R).

Columns: category | term | match | pattern | note | source
  match = word   a literal phrase searched in the text (an alias: pattern -> term)
          regex  a regular expression searched in the text (pattern -> term)
          value  a literal value the code looks up or uses (lists, lookup maps, prompt phrases)
Order within a category is priority.
"""
import csv, functools, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = [os.path.join(HERE, "..", "agent", "rules.tsv"),            # installed package, or inst/ in the repo
              os.path.join(HERE, "..", "inst", "agent", "rules.tsv")]    # repo root layouts


def path():
    for p in CANDIDATES:
        if os.path.exists(p):
            return p
    raise FileNotFoundError("rules.tsv not found in " + ", ".join(CANDIDATES))


@functools.lru_cache(None)
def rows():
    with open(path(), encoding="utf-8") as f:
        return tuple(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def of(category, match=None):
    return [r for r in rows() if r["category"] == category and (match is None or r["match"] == match)]


def alias_rows():
    """word rows in the old alias-table shape: alias, canonical_term, category, source, confidence"""
    return [{"alias": r["pattern"], "canonical_term": r["term"], "category": r["category"], "source": r["source"],
             "confidence": "medium" if "confidence: medium" in r["note"] else "high"} for r in rows() if r["match"] == "word"]


def patterns(category):
    """[(term, compiled regex), ...] of a category's regex rows, in order"""
    return [(r["term"], re.compile(r["pattern"])) for r in of(category, "regex")]


def keys(category):
    """the patterns (items) of a list category, in order"""
    return [r["pattern"] for r in of(category)]


def pairs(category):
    """[(pattern, term), ...] in order"""
    return [(r["pattern"], r["term"]) for r in of(category)]


def mapping(category):
    """{pattern: term}"""
    return dict(pairs(category))


def groups(category):
    """{term: [pattern, ...]} (e.g. technique -> the phrases that name it)"""
    out = {}
    for p, t in pairs(category):
        out.setdefault(t, []).append(p)
    return out


def lookup_all(category):
    """{pattern: [term, ...]} (e.g. a specific assay -> the generic labels it stands in for)"""
    out = {}
    for p, t in pairs(category):
        out.setdefault(p, []).append(t)
    return out
