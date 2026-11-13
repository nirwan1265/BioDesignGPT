#!/usr/bin/env python3
"""Check labelled batches against the StudySpec schema; print counts. python validate.py"""
import glob, json, os, re, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "llm"))
from reader import SYSTEMS, ASSAYS  # noqa: E402
FACTORS = {"age", "antibiotic", "co2", "diet", "disease", "genotype", "injury", "light", "nitrogen", "nutrient", "phosphorus",
           "salt", "sex", "stage", "temperature", "time", "tissue", "treatment", "water", "dose", "infection", "strain"}
OUTCOMES = {"behaviour", "biomass", "body_weight", "chromatin_accessibility", "disease_severity", "flowering_time",
            "forage_yield", "gca_sca", "gene_expression", "grain_yield", "leaf_growth", "lifespan", "lipid_content",
            "mechanical_threshold", "photosynthesis", "plant_height", "translation_efficiency", "wing_size"}
TOP = {"system", "organism", "organisms", "experimental_unit", "measurement_unit", "subsamples_per_unit", "factors", "design",
       "assays", "primary_outcome", "population", "environments", "blocking_factors"}
WORD = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "a dozen": 12, "dozen": 12, "a pair": 2, "pair": 2, "both": 2, "single": 1}
errs, n, skips = [], 0, 0
seen = set()
stats = collections.Counter()
for f in sorted(glob.glob(os.path.join(HERE, "batches", "batch_*.jsonl"))):
    for i, l in enumerate(open(f, encoding="utf-8")):
        r = json.loads(l)
        where = f"{os.path.basename(f)}:{i + 1} {r.get('paper')}"
        if r.get("paper") in seen: errs.append(f"{where}: duplicate paper")
        seen.add(r.get("paper"))
        if r.get("skip"):
            skips += 1; continue
        n += 1
        e, p = r["expected_spec"], r["prompt"]
        stats["style:" + str(r.get("style"))] += 1
        for k in e:
            if k not in TOP: errs.append(f"{where}: unknown field {k}")
        if e.get("system") and e["system"] not in SYSTEMS: errs.append(f"{where}: system {e['system']}")
        for a in e.get("assays", []):
            if a not in ASSAYS: errs.append(f"{where}: assay {a}")
        po = (e.get("primary_outcome") or {}).get("name")
        if po and po not in OUTCOMES: errs.append(f"{where}: outcome {po}")
        nums = set(re.findall(r"\d[\d,]*", p.lower()))
        nums = {x.replace(",", "") for x in nums} | {str(v) for w, v in WORD.items() if re.search(r"\b" + w + r"\b", p.lower())}
        for fct in e.get("factors", []):
            if fct["name"] not in FACTORS: stats["factor:" + fct["name"]] += 1
        for path in ("design.reps", "design.locations", "design.seasons", "subsamples_per_unit"):
            v = e
            for k in path.split("."): v = (v or {}).get(k) if isinstance(v, dict) else None
            if v is not None and str(v) not in nums:
                errs.append(f"{where}: {path}={v} not stated as a number in the prompt")
        for m in r.get("must_ask", []):
            v = e
            for k in m.split("."): v = (v or {}).get(k) if isinstance(v, dict) else None
            if v is not None: errs.append(f"{where}: must_ask {m} is also in expected_spec")
print(f"{n} questions, {skips} skipped papers; styles { {k[6:]: v for k, v in stats.items() if k.startswith("style:")} }")
other = {k: v for k, v in stats.items() if k.startswith("factor:")}
if other: print("factor names outside the core list:", other)
print("\n".join(errs) if errs else "no schema errors")
