#!/usr/bin/env python3
"""Check and add proposed rows for inst/agent/rules.tsv (the one table of words and patterns).

    python3 training/rules_tool.py check proposed.tsv      report problems, add nothing
    python3 training/rules_tool.py add proposed.tsv        add the rows that pass (problems are skipped, listed)
    python3 training/rules_tool.py catalogue               markdown list of categories and their terms (for docs / AIs)

A proposed file has the same six tab-separated columns as rules.tsv (a header row is optional):
    category  term  match  pattern  note  source
After `add`, measure before committing:
    Rscript training/paper_questions/score.R            rules on the dev split (never the test split)
    Rscript -e 'pkgload::load_all(); testthat::test_file("tests/testthat/test-rules.R")'
"""
import collections, csv, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "inst", "python"))
import rulebook  # noqa: E402

COLS = ["category", "term", "match", "pattern", "note", "source"]
# categories whose regex rows the code looks up by name: a new name does nothing until code asks for it
NAMED = {"cue"}


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
    seen = set()
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
        if cat in NAMED and term not in terms[cat]:
            problems.append(f"{where}: new {cat} name '{term}': the code has to ask for it by name, so propose it as a change "
                            f"to an existing {cat} or with the code that uses it"); continue
        key = (cat, match, pat.lower())
        if key in seen:
            notes.append(f"{where}: repeated in the proposal; kept once"); continue
        if key in have:
            if have[key] == term:
                notes.append(f"{where}: already in rules.tsv; skipped")
            else:
                problems.append(f"{where}: conflicts with the existing row mapping it to '{have[key]}'")
            continue
        if term and term not in terms[cat] and match != "value":
            notes.append(f"{where}: new term '{term}' in {cat} (check the engine knows it: outcome types, trait registry ...)")
        seen.add(key)
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
    if len(sys.argv) < 2 or sys.argv[1] not in ("check", "add", "catalogue"):
        sys.exit(__doc__)
    if sys.argv[1] == "catalogue":
        print(catalogue()); return
    good, problems, notes = (check if sys.argv[1] == "check" else add)(sys.argv[2])
    for p in problems:
        print("PROBLEM", p)
    for n in notes:
        print("note   ", n)
    print(f"{len(good)} rows {'would be added' if sys.argv[1] == 'check' else 'added'}; {len(problems)} problems; {len(notes)} notes")


if __name__ == "__main__":
    main()
