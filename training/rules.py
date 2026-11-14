"""The rule files, read the same way R reads them (R/registry.R).

    inst/agent/rules.tsv                       every word and pattern: vocabulary (aliases), named cues, word lists,
                                               lookup maps (read by inst/python/rulebook.py)
    inst/registry/experimental_systems.json    what each system is: setting / assay family (+ its assay) / study

Python code reads vocabulary and system kinds from here instead of keeping its own lists.
"""
import functools, json, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "inst", "python"))
from rulebook import (rows, of, alias_rows, patterns, keys, pairs, mapping, groups, lookup_all)  # noqa: E402,F401
SYSTEMS = os.path.join(ROOT, "inst", "registry", "experimental_systems.json")


@functools.lru_cache(None)
def systems():
    with open(SYSTEMS, encoding="utf-8") as f:
        return {s["id"]: s for s in json.load(f)["systems"]}


def systems_where(**want):
    return {i for i, s in systems().items() if all(s.get(k) == v for k, v in want.items())}


@functools.lru_cache(None)
def aliases(category):
    """{canonical: [alias, ...]} for one vocabulary category (lowercased aliases)"""
    out = {}
    for r in alias_rows():
        if r["category"] == category:
            out.setdefault(r["canonical_term"].strip(), []).append(r["alias"].strip().lower())
    return out
