"""The rule files, read the same way R reads them (R/registry.R: .sf_rules, .sf_systems_where).

    inst/agent/rules.tsv                       pattern tables (organism, system, setting, outcome, genotype_noun)
                                               and factor synonyms; order within a table is priority
    inst/agent/aliases.tsv                     vocabulary: alias -> canonical term, by category
    inst/registry/experimental_systems.json    what each system is: setting / assay family (+ its assay) / study

Python code reads vocabulary and system kinds from here instead of keeping its own lists.
"""
import csv, functools, json, os, re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RULES = os.path.join(ROOT, "inst", "agent", "rules.tsv")
ALIASES = os.path.join(ROOT, "inst", "agent", "aliases.tsv")
SYSTEMS = os.path.join(ROOT, "inst", "registry", "experimental_systems.json")


@functools.lru_cache(None)
def _rows():
    with open(RULES, encoding="utf-8") as f:
        return tuple(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def table(name):
    """[(key, value), ...] of one rule table, in file order."""
    return [(r["key"], r["value"]) for r in _rows() if r["table"] == name]


def patterns(name):
    """[(key, compiled regex), ...]; R uses perl regexes, written so Python's re reads them the same."""
    return [(k, re.compile(v)) for k, v in table(name)]


def mapping(name):
    return dict(table(name))


@functools.lru_cache(None)
def systems():
    with open(SYSTEMS, encoding="utf-8") as f:
        return {s["id"]: s for s in json.load(f)["systems"]}


def systems_where(**want):
    return {i for i, s in systems().items() if all(s.get(k) == v for k, v in want.items())}


@functools.lru_cache(None)
def aliases(category):
    """{canonical: [alias, ...]} for one alias category."""
    out = {}
    with open(ALIASES, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            if r["category"].strip() == category:
                out.setdefault(r["canonical_term"].strip(), []).append(r["alias"].strip().lower())
    return out
