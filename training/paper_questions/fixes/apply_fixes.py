#!/usr/bin/env python3
"""Apply reviewed label fixes to the label sources, then rebuild batches and splits.

fixes/*.tsv rows: id, factor, n_levels, evidence[, old]. Each row adds a level count the prompt states to a factor the
label left open; a row with `old` changes that existing count instead (a convention decided after labelling). `evidence` must appear verbatim in the prompt (checked here), so every fix can be audited
against the question text. Only tuning splits (dev, dev2, train) may be fixed; a row for a test split stops the run.

    python3 fixes/apply_fixes.py
"""
import csv, glob, json, os, re, runpy, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PQ = os.path.dirname(HERE)
TUNING = ("dev", "dev2", "train")

split_of, prompt_of = {}, {}
for f in glob.glob(os.path.join(PQ, "splits", "*.jsonl")):
    sp = os.path.basename(f)[:-6]
    for line in open(f):
        r = json.loads(line)
        split_of[r["id"]] = sp
        prompt_of[r["id"]] = r.get("prompt", "")

rows = [r for f in sorted(glob.glob(os.path.join(HERE, "*.tsv"))) for r in csv.DictReader(open(f), delimiter="\t")]
errs = []
for r in rows:
    if split_of.get(r["id"]) not in TUNING:
        errs.append(f"{r['id']}: in split {split_of.get(r['id'])}, only {TUNING} may be fixed")
    elif r["evidence"] not in prompt_of[r["id"]]:
        errs.append(f"{r['id']}: evidence not in prompt")
if errs:
    sys.exit("\n".join(errs))

touched, done = {}, set()
for f in sorted(glob.glob(os.path.join(PQ, "labels", "b*.py"))):
    s, changed = open(f).read(), False
    for r in rows:
        pid = "paper_" + r["id"].split("_")[1]
        m = re.search(r'^(dict\(paper="' + pid + r'"|\{\'paper\': \'' + pid + r"')", s, re.M)
        if not m:
            continue
        nxt = re.search(r"^(dict\(paper=|\{'paper':)", s[m.end():], re.M)
        a, b = m.start(), m.end() + (nxt.start() if nxt else len(s) - m.end())
        block, fac, n = s[a:b], re.escape(r["factor"]), r["n_levels"]
        o = (r.get("old") or "").strip()
        if o:
            new = re.sub(r'(dict\(name="' + fac + r'", n_levels=)' + o + r'\b', r'\g<1>' + n, block, count=1)
            new = re.sub(r"(\{'name': '" + fac + r"', 'n_levels': )" + o + r"\b", r"\g<1>" + n, new, count=1)
        else:
            new = re.sub(r'dict\(name="' + fac + r'"(?![^)]*n_levels)', f'dict(name="{r["factor"]}", n_levels={n}', block, count=1)
        if new == block and not o:
            new = re.sub(r"\{'name': '" + fac + r"'(?![^}]*'n_levels')", "{'name': '" + r["factor"] + "', 'n_levels': " + n, block, count=1)
        if new != block:
            s, changed = s[:a] + new + s[b:], True
            done.add(r["id"])
        elif re.search(r"""name['"]?[=:] ?['"]""" + fac + r"""['"][^)}]*n_levels['"]?[=:] ?""" + n + r"\b", block):
            done.add(r["id"])   # applied on an earlier run
    if changed:
        open(f, "w").write(s)
        touched[f] = True

missing = sorted({r["id"] for r in rows} - done)
if missing:
    sys.exit(f"factor not found open in the label source: {missing}")
for f in sorted(touched):
    nn = re.search(r"b(\d+)\w*\.py$", f).group(1)
    subprocess.run([sys.executable, os.path.join(PQ, "write_batch.py"), nn, f], check=True, cwd=PQ)
subprocess.run([sys.executable, os.path.join(PQ, "validate.py")], check=True, cwd=PQ)
subprocess.run([sys.executable, os.path.join(PQ, "freeze_split.py"), "--refresh"], check=True, cwd=PQ)
print(f"{len(rows)} fixes applied, {len(touched)} label files rewritten")
