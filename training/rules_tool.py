#!/usr/bin/env python3
"""Check and add proposed rows for inst/agent/rules.tsv (the one table of words and patterns).

    python3 training/rules_tool.py check proposed.tsv      report problems, add nothing
    python3 training/rules_tool.py add proposed.tsv        add the rows that pass (problems are skipped, listed)
    python3 training/rules_tool.py precision proposed.tsv  how often each row fires on labelled training prompts, and
                                                           how often the label agrees (catches rows that misfire)
    python3 training/rules_tool.py catalogue               markdown list of categories and their terms (for docs / AIs)

A proposed file has the same six tab-separated columns as rules.tsv (a header row is optional):
    category  term  match  pattern  note  source
After `add`, measure before committing:
    Rscript training/paper_questions/score.R            rules on the dev split (never the test split)
    Rscript -e 'pkgload::load_all(); testthat::test_file("tests/testthat/test-rules.R")'
"""
import collections, csv, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "inst", "python"))
import rulebook  # noqa: E402

COLS = ["category", "term", "match", "pattern", "note", "source"]
ROOT = os.path.join(HERE, "..")
# categories whose regex rows the code looks up by name: a new name does nothing until code asks for it
NAMED = {"cue"}
# categories whose terms are ids the engine acts on: a new term must be one the engine already knows
ID_REGISTRY = {"design": ("design_catalog", "designs"), "unit": ("experimental_units", "units"),
               "system": ("experimental_systems", "systems")}
ID_CATEGORIES = {"design", "unit", "system", "setting", "mating", "blocking", "environment", "check", "application",
                 "genotype_noun"}
# escapes a pattern may use; anything else (\r, \x, \t ...) is almost always a typo for \b or a missing letter
OK_ESCAPES = set("bBdDsSwW.-()[]{}|?*+^$/\\'\":,;!#%&<>=@~` ")


def known_ids(category, terms):
    ids = set(terms[category])
    if category in ID_REGISTRY:
        f, key = ID_REGISTRY[category]
        with open(os.path.join(ROOT, "inst", "registry", f + ".json"), encoding="utf-8") as fh:
            ids |= {e["id"] for e in json.load(fh)[key]}
    if category == "system":
        ids |= terms["setting"]
    return ids


def read(path):
    with open(path, encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if l.strip() and not l.startswith("#")]
    if lines and lines[0].split("\t")[:3] == COLS[:3]:
        lines = lines[1:]
    out = []
    for i, l in enumerate(lines, 1):
        c = l.split("\t")
        c += [""] * (6 - len(c))
        out.append((i, dict(zip(COLS, c[:6])), len(l.split("\t"))))
    return out


def check(path):
    rows = rulebook.rows()
    cats = collections.Counter(r["category"] for r in rows)
    terms = collections.defaultdict(set)
    have = {}
    for r in rows:
        terms[r["category"]].add(r["term"])
        have[(r["category"], r["match"], r["pattern"].lower())] = r["term"]
    good, problems, notes = [], [], []
    seen = {}
    for i, r, ncol in read(path):
        cat, term, match, pat = r["category"].strip(), r["term"].strip(), r["match"].strip(), r["pattern"].strip()
        where = f"row {i} ({cat} | {term} | {pat[:50]})"
        if ncol < 4:
            problems.append(f"{where}: needs at least 4 tab-separated columns (category, term, match, pattern)"); continue
        if cat not in cats:
            problems.append(f"{where}: unknown category '{cat}' (a new category needs code that reads it)"); continue
        if match not in ("word", "regex", "value"):
            problems.append(f"{where}: match must be word, regex or value"); continue
        if not pat:
            problems.append(f"{where}: empty pattern"); continue
        if match == "regex":
            try:
                re.compile(pat)
            except re.error as e:
                problems.append(f"{where}: regex does not compile: {e}"); continue
            if re.search(r"(?<!\\)[A-Z]", re.sub(r"\\[A-Za-z]", "", pat)):
                problems.append(f"{where}: uppercase letters never match (the text is lowercased first)"); continue
            bad = [m for m in re.findall(r"\\(.)", re.sub(r"\\\\", "", pat)) if m not in OK_ESCAPES]
            if bad:
                problems.append(f"{where}: escape \\{bad[0]} is almost surely a typo (\\b? a missing letter?)"); continue
            if re.fullmatch(r"\\b[a-z0-9]{1,3}s?\??\\b", pat):
                notes.append(f"{where}: very short abbreviation: check it is not also an ordinary word or another term")
        if cat in NAMED and term not in terms[cat]:
            problems.append(f"{where}: new {cat} name '{term}': the code has to ask for it by name, so propose it as a change "
                            f"to an existing {cat} or with the code that uses it"); continue
        key = (cat, match, pat.lower())
        if key in seen:
            if seen[key] != term:
                problems.append(f"{where}: the proposal maps this pattern to both '{seen[key]}' and '{term}'; keep one")
            else:
                notes.append(f"{where}: repeated in the proposal; kept once")
            continue
        if key in have:
            if have[key] == term:
                notes.append(f"{where}: already in rules.tsv; skipped")
            else:
                problems.append(f"{where}: conflicts with the existing row mapping it to '{have[key]}'")
            continue
        if cat in ID_CATEGORIES and term not in known_ids(cat, terms):
            problems.append(f"{where}: '{term}' is not a {cat} the engine knows; map the phrase to an existing term"); continue
        if cat == "tech_by_assay" and (pat not in terms["assay"]):
            problems.append(f"{where}: '{pat}' is not an assay id"); continue
        if term and term not in terms[cat] and match != "value":
            notes.append(f"{where}: new term '{term}' in {cat} (check the engine knows it: outcome types, trait registry ...)")
        seen[key] = term
        r = {k: r[k].strip() for k in COLS}
        r["source"] = r["source"] or "proposed"
        good.append(r)
    return good, problems, notes


def add(path):
    good, problems, notes = check(path)
    target = rulebook.path()
    rows = list(rulebook.rows())
    # insert each new row after the last row of its category, so categories stay together
    for g in good:
        last = max(i for i, r in enumerate(rows) if r["category"] == g["category"])
        rows.insert(last + 1, g)
    with open(target, "w", encoding="utf-8") as f:
        f.write("\t".join(COLS) + "\n")
        for r in rows:
            f.write("\t".join(r[k] for k in COLS) + "\n")
    rulebook.rows.cache_clear()
    return good, problems, notes


# labelled training prompts (never dev or test) and the gold field each category is checked against
CORPORA = ["training/data/train.jsonl", "training/data/para.jsonl", "training/data/grounded_train.jsonl",
           "training/paper_questions/splits/train.jsonl"]


def _gold(spec, cat):
    def as_list(x):
        return x if isinstance(x, list) else [x]
    d = spec.get("design") if isinstance(spec.get("design"), dict) else {}
    pop = spec.get("population") if isinstance(spec.get("population"), dict) else {}
    out = (spec.get("primary_outcome") or {}) if isinstance(spec.get("primary_outcome"), dict) else {}
    g = {"organism": lambda: [spec.get("organism")] + as_list(spec.get("organisms")),
         "assay": lambda: as_list(spec.get("assays")), "system": lambda: [spec.get("system")],
         "outcome": lambda: [out.get("name")],
         "factor": lambda: [f.get("name") for f in as_list(spec.get("factors")) if isinstance(f, dict)],
         "unit": lambda: [spec.get("experimental_unit"), spec.get("measurement_unit")],
         "blocking": lambda: as_list(spec.get("blocking_factors")),
         "environment": lambda: as_list(spec.get("environments")),
         "design": lambda: [d.get("type")], "mating": lambda: [pop.get("mating")]}.get(cat)
    return {str(x) for x in (g() if g else []) if x}


def matcher(row):
    if row["match"] == "regex":
        return re.compile(row["pattern"].replace("{N}", r"\d+"))
    return re.compile(r"(?<![a-z0-9])" + re.escape(row["pattern"].lower()) + r"(?:e?s)?(?![a-z0-9])")


def precision(path, out=None):
    """Fire each proposed row on the labelled training prompts. agree = share of hits (on prompts whose label fills
    that field) where the label holds the row's term; a row that fires often and disagrees often misreads text."""
    good, problems, _ = check(path)
    prompts = []
    for f in CORPORA:
        p = os.path.join(ROOT, f)
        if os.path.exists(p):
            for l in open(p, encoding="utf-8"):
                r = json.loads(l)
                prompts.append((" ".join((r.get("text") or r.get("prompt") or "").lower().split()), r.get("spec") or r.get("expected_spec") or {}))
    syn = rulebook.mapping("factor_synonym")
    rep = []
    for g in good:
        rx = matcher(g)
        hits = [s for t, s in prompts if rx.search(t)]
        gold = [_gold(s, g["category"]) for s in hits]
        if g["category"] == "factor":
            gold = [{syn.get(x, x) for x in s} for s in gold]
        labelled = [s for s in gold if s]
        agree = sum(g["term"] in s for s in labelled)
        others = collections.Counter(x for s in labelled if g["term"] not in s for x in s)
        rep.append(dict(g, hits=len(hits), labelled=len(labelled), agree=agree,
                        agree_rate=round(agree / len(labelled), 2) if labelled else None,
                        instead=", ".join(f"{k} ({v})" for k, v in others.most_common(3))))
    rep.sort(key=lambda r: (-(r["labelled"] - r["agree"]), -r["hits"]))
    if out:
        with open(out, "w", encoding="utf-8") as f:
            cols = COLS + ["hits", "labelled", "agree", "agree_rate", "instead"]
            f.write("\t".join(cols) + "\n")
            for r in rep:
                f.write("\t".join(str(r[c]) for c in cols) + "\n")
    return rep, len(prompts)


def catalogue():
    rows = rulebook.rows()
    by = collections.OrderedDict()
    for r in rows:
        by.setdefault(r["category"], []).append(r)
    out = ["| category | rows | match | terms / what it holds |", "|---|---|---|---|"]
    for cat, rs in by.items():
        matches = "/".join(sorted({r["match"] for r in rs}))
        ts = list(dict.fromkeys(r["term"] for r in rs if r["term"]))
        if cat == "cue":
            desc = f"{len(ts)} named patterns (see the file; each row's note says what it detects)"
        elif ts and len(ts) <= 40:
            desc = ", ".join(f"`{t}`" for t in ts)
        elif ts:
            desc = ", ".join(f"`{t}`" for t in ts[:25]) + f" ... ({len(ts)} terms)"
        else:
            desc = next((r["note"] for r in rs if r["note"]), "word list")
        out.append(f"| `{cat}` | {len(rs)} | {matches} | {desc} |")
    return "\n".join(out)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "add", "catalogue", "precision"):
        sys.exit(__doc__)
    if sys.argv[1] == "catalogue":
        print(catalogue()); return
    if sys.argv[1] == "precision":
        out = sys.argv[3] if len(sys.argv) > 3 else None
        rep, n = precision(sys.argv[2], out)
        flag = [r for r in rep if r["labelled"] >= 5 and r["agree_rate"] is not None and r["agree_rate"] < 0.5]
        print(f"{len(rep)} rows fired on {n} labelled training prompts; {len(flag)} disagree with the label more often than not:")
        for r in flag[:60]:
            print(f"  {r['category']:<10} {r['term']:<28} {r['pattern'][:40]:<40} hits {r['hits']:>5}  agree {r['agree']}/{r['labelled']}  label says: {r['instead']}")
        loud = [r for r in rep if r["hits"] > 0.02 * n]
        for r in loud:
            print(f"  fires on {r['hits']} prompts ({100 * r['hits'] / n:.1f}%): {r['category']} {r['term']} {r['pattern'][:50]}")
        return
    good, problems, notes = (check if sys.argv[1] == "check" else add)(sys.argv[2])
    for p in problems:
        print("PROBLEM", p)
    for n in notes:
        print("note   ", n)
    print(f"{len(good)} rows {'would be added' if sys.argv[1] == 'check' else 'added'}; {len(problems)} problems; {len(notes)} notes")


if __name__ == "__main__":
    main()
