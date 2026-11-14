"""Turn tagged spans + system label into a StudySpec (mirrors R's extract_spec_local defaults)."""
import csv, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
         "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "this": 1, "single": 1, "a": 1, "no": 1}

_AL = None


def aliases():
    global _AL
    if _AL is None:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        import rulebook   # inst/python/rulebook.py: reads inst/agent/rules.tsv
        _AL = {}
        for r in rulebook.alias_rows():
            _AL.setdefault(r["category"], []).append((r["alias"].lower(), r["canonical_term"]))
        for k in _AL:
            _AL[k].sort(key=lambda x: -len(x[0]))  # longest alias first
    return _AL


def canon(text, *cats):
    # spans are tokens joined by spaces: "c . elegans", "v . vinifera" -> "c. elegans"
    t = " " + re.sub(r"\s+([.,])", r"\1", text.lower()) + " "
    for cat in cats:
        for a, c in aliases().get(cat, []):
            if re.search(r"(?<![a-z])" + re.escape(a) + r"(?![a-z])", t):
                return c
    return None


def num(text):
    t = text.lower().replace(",", "")
    m = re.search(r"\d+(?:\.\d+)?", t)
    if m:
        v = float(m.group())
        return int(v) if v.is_integer() else v
    for w in t.split():
        if w in WORDS:
            return WORDS[w]
    return None


def spans(tokens, tags):
    out, cur = [], None
    for i, (tok, tag) in enumerate(zip(tokens, tags)):
        if tag.startswith("B-") or (tag.startswith("I-") and (cur is None or cur[0] != tag[2:])):
            if cur:
                out.append(cur)
            cur = [tag[2:], [tok], i]
        elif tag.startswith("I-") and cur:
            cur[1].append(tok)
        else:
            if cur:
                out.append(cur)
            cur = None
    if cur:
        out.append(cur)
    return [(lab, " ".join(toks), start) for lab, toks, start in out]


APPLY_TO = {"main_plot": "main_plot", "distance_from_line": "distance_from_line", "cage": "cage", "dam": "dam",
            "chamber": "chamber", "vial": "vial", "individual": "mouse", "tray": "tray"}
APPLY_UNIT = {"cage": "cage", "dam": "litter", "chamber": "chamber", "individual": "mouse"}


def to_spec(tokens, tags, system, text=None):
    text = text or " ".join(tokens)
    low = text.lower()
    sp = spans(tokens, tags)
    spec = {"status": "needs_clarification", "system": system}
    factors = []

    def get(lab):
        return [(s, i) for l, s, i in sp if l == lab]

    org = [canon(s, "organism") for s, _ in get("ORG")]
    org = [o for o in org if o]
    if org:
        spec["organism"] = org[0]
    elif system == "drosophila":
        spec["organism"] = "Drosophila melanogaster"

    outs = {canon(s, "outcome") or s.lower().replace(" ", "_") for s, _ in get("OUTCOME")}
    if len(outs) == 1:
        o = outs.pop()
        spec["primary_outcome"] = {"name": o, "type": "survival" if o == "lifespan" else "continuous"}

    for s, i in get("GENO_N"):
        n = num(s)
        if n is not None:
            after = " ".join(tokens[i:i + 8]).lower()
            if re.search(r"mutants? (?:vs\.?|versus|and) (?:a|the|one) (?:control|wild[- ]type)", after):
                n += 1
            factors.append({"name": "genotype", "n_levels": n})
            break
    for s, _ in get("CHECK_N"):
        if num(s) is not None:
            factors.append({"name": "check", "n_levels": num(s)})
            break

    lev = [(num(s), i) for s, i in get("LEVELS_N")]
    for s, i in get("FACTOR"):
        name = canon(s, "factor") or ("genotype" if re.search(r"strain|knockout|mutant", s.lower()) else s.lower().split()[-1])
        if name == "genotype" and any(f["name"] == "genotype" for f in factors):
            continue
        n = None
        near = [(abs(j - i), v) for v, j in lev if v is not None and abs(j - i) <= 2]
        if near:
            n = min(near)[1]
        elif re.search(r"\b(?:vs\.?|versus|and|with)\b", s.lower()) or re.search(r"\b(?:vs\.?|versus|than|compare)\b", " ".join(tokens[i:i + 6]).lower()):
            n = 2
        elif name in ("sex", "treatment", "injury", "antibiotic", "co2"):
            n = 2
        if any(f["name"] == name for f in factors):
            continue
        f = {"name": name}
        if n is not None:
            f["n_levels"] = n
        factors.append(f)

    applies = [canon(s, "application") for s, _ in get("APPLY")]
    applies = [a for a in applies if a]
    if applies:
        a = applies[0]
        for f in factors:
            if f["name"] not in ("genotype", "check", "sex"):
                f["applied_to"] = APPLY_TO.get(a, a)
                break
        if a in APPLY_UNIT:
            spec["experimental_unit"] = APPLY_UNIT[a]
        if a == "individual":
            spec["measurement_unit"] = "mouse"
    if factors:
        spec["factors"] = factors

    design = {}
    for key, lab in (("reps", "REPS_N"), ("locations", "LOC_N"), ("seasons", "SEASON_N")):
        vals = [num(s) for s, _ in get(lab)]
        vals = [v for v in vals if v is not None]
        if vals:
            design[key] = vals[0]
    if design:
        spec["design"] = design

    sub = [num(s) for s, _ in get("SUB_N")]
    meas = [canon(s, "unit") for s, _ in get("MEAS")]
    exp = [canon(s, "unit") for s, _ in get("EXP")]
    if meas and meas[0]:
        spec["measurement_unit"] = meas[0]
    if sub and sub[0] is not None and meas:
        spec["subsamples_per_unit"] = sub[0]
    if exp and exp[0] and "experimental_unit" not in spec:
        spec["experimental_unit"] = {"litter": "litter"}.get(exp[0], exp[0])

    blocks = [canon(s, "blocking") for s, _ in get("BLOCK")]
    blocks = [b for b in blocks if b]
    if blocks:
        b = blocks[0]
        if b == "batch":
            b = "library_batch" if "librar" in low else "injection_batch"
        spec["blocking_factors"] = [b]

    # round 3: populations, assays, environments, extra organisms
    if len(org) > 1:
        spec["organisms"] = list(dict.fromkeys(org))
    pop = {}
    mats = [canon(s, "mating") for s, _ in get("MATING")]
    mats = [m for m in mats if m]
    if mats:
        pop["mating"] = mats[0]
        if mats[0] in ("ril", "nam", "dh", "biparental"):
            pop["type"] = mats[0]
        if mats[0] in ("ril", "biparental", "dh"):
            pop["parents"] = 2
    for s, _ in get("GEN_N"):
        m = re.match(r"\s*f\s*(\d+)", s.lower())
        if m:
            pop["filial_generation"] = int(m.group(1))
            if pop.get("mating") == "selfing" or "mating" not in pop:
                pop.setdefault("type", "ril")
                pop["parents"] = pop.get("parents", 2)
        elif num(s) is not None:
            pop["generations"] = num(s)
        break
    pn = [num(s) for s, _ in get("PARENT_N")]
    pn = [v for v in pn if v is not None]
    if pn:
        pop["parents"] = pn[0] + 1 if pop.get("mating") == "nam" else sum(pn)
    if pop:
        spec["population"] = pop
    assays = []
    for s, _ in get("ASSAY"):
        a = canon(s, "assay")
        if a and a not in assays:
            assays.append(a)
    if assays:
        spec["assays"] = assays
    envs = []
    for s, _ in get("ENV"):
        v = canon(s, "environment")
        if v and v not in envs:
            envs.append(v)
    if envs:
        spec["environments"] = envs

    if "experimental_unit" not in spec:  # same defaults as the rule engine
        if system == "field":
            spec["experimental_unit"] = "plant" if re.search(r"single-plant|spaced plants", low) else "plot"
        elif system in ("growth_chamber", "greenhouse") and re.search(r"\btrays?\b|\bflats?\b", low):
            spec["experimental_unit"] = "cell"
        elif system == "multi_environment" and re.search(r"\bplots?\b|locations?|sites?|environments", low):
            spec["experimental_unit"] = "plot"
        elif system in ("greenhouse", "growth_chamber") and re.search(r"\bpots?\b|carts?|imaging platform", low):
            spec["experimental_unit"] = "pot"
        elif system == "drosophila" and re.search(r"lifespan|diet|yeast|wing", low):
            spec["experimental_unit"] = "vial"
            spec.setdefault("measurement_unit", "fly")
    return spec
