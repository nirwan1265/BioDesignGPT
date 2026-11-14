#!/usr/bin/env python3
"""Synthetic training data for the StudyForge prompt tagger.

Sentences are composed from clause templates whose labels are known, so the
token tags (BIO) and the StudySpec are correct by construction. Includes hard
negatives (numbers that are not counts, undecided counts, look-alike words).

    python training/generate.py --n 5000 --out training/data/train.jsonl --seed 1
    python training/generate.py --n 500  --out training/data/dev.jsonl   --seed 2
    python training/generate.py --weights training/data/family_weights.json ...   # hard-example loop
"""
import argparse, csv, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "inst", "python"))
import rulebook  # noqa: E402   inst/agent/rules.tsv

TAGS = ["ORG", "GENO_N", "CHECK_N", "REPS_N", "LOC_N", "SEASON_N", "SUB_N", "MEAS", "EXP",
        "FACTOR", "LEVELS_N", "APPLY", "OUTCOME", "BLOCK", "GEN_N", "PARENT_N", "MATING", "ASSAY", "ENV"]
SYSTEMS = ["field", "greenhouse", "growth_chamber", "mouse", "drosophila", "bulk_rnaseq",
           "metabolomics_lipidomics", "single_cell", "cell_culture", "breeding_genetics", "multi_environment",
           "multi_omics", "ribo_seq", "atac_seq", "functional_validation"]
TOKEN_RE = re.compile(r"\d+(?:[.,]\d+)*|[A-Za-z]+(?:[-'/][A-Za-z0-9]+)*|[^\sA-Za-z\d]")
WORDS = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven", 8: "eight",
         9: "nine", 10: "ten", 11: "eleven", 12: "twelve", 15: "fifteen", 20: "twenty"}


def tokenize(text):
    return TOKEN_RE.findall(text)


def load_aliases():
    by = {}
    for r in rulebook.alias_rows():
        by.setdefault((r["category"], r["canonical_term"]), []).append(r["alias"])
    return by


AL = load_aliases()


def aliases(cat, canon):
    return AL.get((cat, canon), [canon])


def numtxt(n, rng, allow_words=True):
    if allow_words and n in WORDS and rng.random() < 0.45:
        return WORDS[n]
    return f"{n:,}" if n >= 1000 and rng.random() < 0.7 else str(n)


class Ex:
    """Accumulates labelled segments and the StudySpec."""

    def __init__(self, rng, system, family):
        self.rng, self.segs, self.family = rng, [], family
        self.spec = {"system": system}

    def say(self, *parts):
        """parts: plain strings or (text, TAG) tuples."""
        for p in parts:
            self.segs.append(p if isinstance(p, tuple) else (p, None))

    def factor(self, name, n=None, applied_to=None):
        f = {"name": name}
        if n is not None:
            f["n_levels"] = n
        if applied_to:
            f["applied_to"] = applied_to
        self.spec.setdefault("factors", []).append(f)

    def design(self, k, v):
        self.spec.setdefault("design", {})[k] = v

    def render(self):
        tokens, tags = [], []
        for text, tag in self.segs:
            toks = tokenize(text)
            tokens += toks
            tags += ["O"] * len(toks) if tag is None else [("B-" if i == 0 else "I-") + tag for i in range(len(toks))]
        text = " ".join(t for t, _ in self.segs)
        text = re.sub(r"\s+([,.;:?)])", r"\1", text)
        text = re.sub(r"\(\s+", "(", text)
        return {"text": text, "tokens": tokens, "tags": tags, "system": self.spec["system"],
                "spec": self.spec, "family": self.family}


R = random.Random()


def pick(xs):
    return R.choice(xs)


def maybe(p=0.5):
    return R.random() < p


# ---------------------------------------------------------------- clause pieces
PLANTS = ["Sorghum bicolor", "Zea mays", "Triticum aestivum", "Hordeum vulgare", "Glycine max", "Oryza sativa",
          "Brassica napus", "Gossypium hirsutum", "Pennisetum glaucum", "Saccharum spp."]
POT_PLANTS = PLANTS[:7] + ["Solanum lycopersicum", "Arabidopsis thaliana"]
GENO_NOUNS = aliases("genotype_noun", "genotype")
FIELD_OUTCOMES = ["grain_yield", "flowering_time", "plant_height", "biomass", "forage_yield", "disease_severity", "lipid_content"]
GH_OUTCOMES = ["biomass", "plant_height", "flowering_time", "photosynthesis", "lipid_content", "gene_expression"]
MOUSE_OUTCOMES = ["body_weight", "behaviour", "gene_expression"]
OUTCOME_TYPE = {"lifespan": "survival"}


def org(e, pool):
    canon = pick(pool)
    e.spec["organism"] = canon
    return (pick(aliases("organism", canon)), "ORG")


def genotypes(e, pool, lo=10, hi=3000, noun=None):
    n = R.choice([R.randint(lo, max(lo, min(hi, 60))), R.randint(lo, hi), R.choice([100, 120, 200, 300, 324, 400, 500, 1000])])
    n = max(lo, min(n, hi))
    e.factor("genotype", n)
    noun = noun or pick(GENO_NOUNS)
    pre = pick(["", "", "about ", "around ", "roughly ", "a panel of ", "a set of "])
    if maybe(0.75):
        o = org(e, pool)
        if maybe(0.7):
            e.say(pre, (numtxt(n, R), "GENO_N"), o, noun)
        else:
            e.say(pre, (numtxt(n, R), "GENO_N"), noun, "of", o)
    else:
        e.say(pre, (numtxt(n, R), "GENO_N"), noun)


def outcome(e, pool, multi_p=0.2):
    if maybe(multi_p):
        a, b = R.sample(pool, 2)
        e.say(pick(["measuring", "for", "scoring"]), (pick(aliases("outcome", a)), "OUTCOME"), "and",
              (pick(aliases("outcome", b)), "OUTCOME"))
        return
    o = pick(pool)
    e.spec["primary_outcome"] = {"name": o, "type": OUTCOME_TYPE.get(o, "continuous")}
    lead = pick(["measuring", "for", "the main trait is", "primary outcome is", "looking at", "scoring", "to compare"])
    e.say(lead, (pick(aliases("outcome", o)), "OUTCOME"))


def reps(e, nouns=("reps", "replications", "replicates", "blocks")):
    if maybe(0.12):  # undecided -> must stay empty
        a = R.randint(2, 4)
        e.say("I can do", numtxt(a, R), "or", numtxt(a + 1, R), pick(nouns))
        return
    n = R.randint(2, 8)
    e.design("reps", n)
    e.say(pick(["with", "in", "", "using"]), (numtxt(n, R), "REPS_N"), pick(nouns), pick(["", "per site", "per location", ""]))


def locations(e):
    n = R.randint(2, 8)
    e.design("locations", n)
    e.say(pick(["at", "across", "in", "over"]), (numtxt(n, R), "LOC_N"), pick(["sites", "locations", "environments", "field sites"]))


def seasons(e):
    if maybe(0.35):
        e.design("seasons", 1)
        e.say((pick(["this season", "one season", "a single season"]), "SEASON_N"))
    else:
        n = R.randint(2, 4)
        e.design("seasons", n)
        e.say(pick(["over", "for", "across"]), (numtxt(n, R), "SEASON_N"), pick(["years", "seasons", "growing seasons"]))


def subsamples(e, meas, exp, lo=2, hi=12):
    n = R.randint(lo, hi)
    e.spec.update({"measurement_unit": meas, "experimental_unit": exp, "subsamples_per_unit": n})
    m = pick(aliases("unit", meas)[:4]) if meas != "plant" else pick(["plants", "panicles", "tagged plants", "plants"])
    x = exp if exp not in ("mouse",) else "mouse"
    pat = pick(["{v} {n} {m} per {x}", "{v} {n} {m} in each {x}", "{v} {n} {m} from each {x}", "with {n} {m} per {x}"])
    v = pick(["I'll measure", "sampling", "tagging", "taking", "measuring"])
    parts = pat.split()
    out = []
    for w in parts:
        if w == "{n}":
            out.append((numtxt(n, R), "SUB_N"))
        elif w == "{m}":
            out.append((m, "MEAS"))
        elif w == "{x}":
            out.append((x, "EXP"))
        elif w == "{v}":
            out.append(v)
        else:
            out.append(w)
    e.say(*out)


def distractor(e, kind):
    pool = {
        "field": ["Plots are 3 m single rows", "rows are 0.75 m apart", "plots are 1.5 m wide", "with 2 m alleys",
                  "sown in May", "harvest after flowering", "plot size is 5 m by 1.5 m", "seed for 1.2 plots per line"],
        "pot": ["in 2 L pots", "pots of 5 L", "plants reach about 40 g dry mass", "at 25 C", "watered every 2 days",
                "under 600 umol light", "for 35 days"],
        "animal": ["at 8 weeks of age", "for 17 weeks", "on a 12 h light cycle", "starting at 6 weeks", "for 14 days"],
        "fly": ["at 25 C", "on standard food", "flipped every 2 days", "at 65% humidity"],
    }[kind]
    e.say(pick(pool))


def join(e, pieces):
    """Run clause functions in a shuffled-ish order with connectors."""
    first, rest = pieces[0], pieces[1:]
    R.shuffle(rest)
    first()
    for p in rest:
        e.say(pick([",", ",", ".", ";", " and", ","]))
        p()
    e.say(pick([".", ".", "?", ". How should I design it?", ". What design should I use?", ""]))


# ---------------------------------------------------------------- families
def fam_field_panel():
    e = Ex(R, "field", "field_panel")
    e.spec["experimental_unit"] = "plot"
    pieces = [lambda: (e.say(pick(["I have", "We have", "Testing", "I want to evaluate", ""])), genotypes(e, PLANTS))]
    if maybe(0.7): pieces.append(lambda: locations(e))
    if maybe(0.6): pieces.append(lambda: reps(e))
    if maybe(0.3): pieces.append(lambda: seasons(e))
    if maybe(0.35): pieces.append(lambda: subsamples(e, "plant", "plot", 3, 10))
    if maybe(0.6): pieces.append(lambda: outcome(e, FIELD_OUTCOMES))
    if maybe(0.3):
        def chk():
            n = R.randint(2, 12); e.factor("check", n)
            e.say("plus", (numtxt(n, R), "CHECK_N"), pick(aliases("check", "check")))
        pieces.append(chk)
    if maybe(0.5): pieces.append(lambda: distractor(e, "field"))
    join(e, pieces)
    return e


def fam_field_unreplicated():
    e = Ex(R, "field", "field_unreplicated")
    e.spec["experimental_unit"] = "plot"
    e.design("reps", 1)
    pieces = [lambda: (e.say(pick(["Progeny rows:", "Early-generation screen:", "I want to screen", "Testing"])), genotypes(e, PLANTS, 200, 5000)),
              lambda: e.say(pick(["only", "with only", "seed allows"]), ("one", "REPS_N"), pick(["plot per line", "plot each", "plot per entry", "row per line"]))]
    if maybe(0.6):
        def chk():
            n = R.randint(2, 10); e.factor("check", n)
            e.say("and", (numtxt(n, R), "CHECK_N"), pick(aliases("check", "check")), pick(["repeated many times", "in every block", "spread through the field"]))
        pieces.append(chk)
    if maybe(0.4): pieces.append(lambda: locations(e))
    join(e, pieces)
    return e


def fam_field_treatment():
    e = Ex(R, "field", "field_treatment")
    e.spec["experimental_unit"] = "plot"
    fac = pick(["water", "nitrogen", "phosphorus"])
    whole = maybe(0.6)
    n = R.randint(2, 5)
    apply_canon = None
    def trt():
        alias = pick(aliases("factor", fac)[:5])
        e.say((numtxt(n, R), "LEVELS_N"), (alias, "FACTOR"), pick(["levels", "treatments", "rates", "regimes"]))
    pieces = [lambda: (e.say(pick(["Comparing", "I want to test", "We'll test", ""])), genotypes(e, PLANTS, 3, 120)), trt]
    if whole:
        apply_canon = "main_plot"
        cue = pick(aliases("application", "main_plot"))
        pieces.append(lambda: e.say(pick([f"{fac if fac != 'water' else 'irrigation'} is applied with", "it comes from a", "applied by"]), (cue, "APPLY"),
                                    pick(["so it can't be randomized per plot", "", "to whole plots"])))
    e.factor(fac, n, apply_canon)
    if maybe(0.7): pieces.append(lambda: reps(e))
    if maybe(0.4): pieces.append(lambda: seasons(e))
    if maybe(0.5): pieces.append(lambda: outcome(e, FIELD_OUTCOMES))
    join(e, pieces)
    return e


def fam_field_line_source():
    e = Ex(R, "field", "field_line_source")
    e.spec["experimental_unit"] = "plot"
    e.factor("water", None, "distance_from_line")
    pieces = [lambda: (e.say("Testing"), genotypes(e, PLANTS, 2, 12)),
              lambda: e.say("across a range of", ("water levels", "FACTOR"), "using a", (pick(aliases("application", "distance_from_line")), "APPLY"),
                            pick(["down the middle of the field", "through the trial", ""]))]
    pieces.append(lambda: reps(e, ("blocks", "reps")))
    join(e, pieces)
    return e


def fam_greenhouse():
    e = Ex(R, "greenhouse", "greenhouse")
    pieces = [lambda: (e.say(pick(["Greenhouse study:", "In the greenhouse,", "Glasshouse experiment with", "Pot experiment:"])), genotypes(e, POT_PLANTS, 4, 60))]
    if maybe(0.6):
        fac = pick(["water", "nitrogen", "salt", "light"])
        if maybe(0.5):
            e.factor(fac, 2)
            pieces.append(lambda: e.say((pick(["well-watered vs water-stressed", "drought vs control", "control vs drought"]) if fac == "water" else f"high vs low {fac}", "FACTOR")))
        else:
            n = R.randint(2, 4); e.factor(fac, n)
            pieces.append(lambda: e.say((numtxt(n, R), "LEVELS_N"), (pick(aliases("factor", fac)[:4]), "FACTOR"), "levels"))
    if maybe(0.5):
        e.spec["experimental_unit"] = "pot"
        pieces.append(lambda: e.say("one plant per", ("pot", "EXP")))
    if maybe(0.4):
        if e.spec.get("experimental_unit") == "pot":
            pieces.append(lambda: subsamples(e, "leaf", "pot", 2, 6) if False else None)
        def leaves():
            n = R.randint(2, 6)
            e.spec.update({"measurement_unit": "leaf", "subsamples_per_unit": n})
            e.spec.setdefault("experimental_unit", "pot")
            e.say(pick(["sampling", "taking", "I'll measure"]), (numtxt(n, R), "SUB_N"), (pick(["leaves", "leaf discs"]), "MEAS"), "per", ("plant", "EXP") if False else "plant")
        pieces.append(leaves)
    if maybe(0.5):
        def benches():
            n = R.randint(2, 8); e.design("reps", n); e.spec["blocking_factors"] = ["bench"]
            e.say("on", (numtxt(n, R), "REPS_N"), (pick(["benches", "tables"]), "BLOCK"))
        pieces.append(benches)
    if maybe(0.5): pieces.append(lambda: outcome(e, GH_OUTCOMES))
    if maybe(0.5): pieces.append(lambda: distractor(e, "pot"))
    join(e, [p for p in pieces if p is not None])
    return e


def fam_chamber_between():
    e = Ex(R, "growth_chamber", "chamber_between")
    fac = pick(["temperature", "co2", "light"])
    e.factor(fac, 2, "chamber")
    e.spec["experimental_unit"] = "chamber"
    o = org(e, POT_PLANTS)
    lv = {"temperature": "22 C vs 30 C", "co2": "800 ppm vs ambient", "light": "long vs short days"}[fac]
    pieces = [lambda: e.say((pick(aliases("factor", fac)[:3]), "FACTOR"), lv, "on", o),
              lambda: e.say("I have", numtxt(R.randint(2, 6), R), pick(["growth chambers", "chambers", "walk-in chambers"]), (pick(aliases("application", "chamber")), "APPLY"), "level")]
    if maybe(0.5):
        def per():
            n = R.randint(10, 40)
            e.spec.update({"measurement_unit": "plant", "subsamples_per_unit": n})
            e.say((numtxt(n, R), "SUB_N"), ("plants", "MEAS"), "per", ("chamber", "EXP"))
        pieces.append(per)
    join(e, pieces)
    return e


def fam_chamber_trays():
    e = Ex(R, "growth_chamber", "chamber_trays")
    e.spec["experimental_unit"] = "cell"
    pieces = [lambda: (e.say("I have"), genotypes(e, ["Arabidopsis thaliana", "Oryza sativa", "Sorghum bicolor", "Hordeum vulgare"], 40, 400)),
              lambda: e.say("and only", pick(["48-cell", "72-cell", "32-cell", "24-cell"]), pick(["trays", "flats"]), pick(["", "(6 x 8)", "on 3 shelves"])),
              lambda: e.say(pick(["can't replicate everything", "can I put Col-0 in every tray", "only one plant per genotype fits"]))]
    if maybe(0.5): pieces.append(lambda: outcome(e, ["flowering_time", "biomass", "plant_height"], 0))
    join(e, pieces)
    return e


def fam_chamber_within():
    e = Ex(R, "growth_chamber", "chamber_within")
    n = R.randint(2, 6)
    e.factor(pick(["nutrient", "salt", "water"]), n)
    fac = e.spec["factors"][-1]["name"]
    e.spec["experimental_unit"] = "pot"
    o = org(e, POT_PLANTS)
    pieces = [lambda: e.say((numtxt(n, R), "LEVELS_N"), (pick(aliases("factor", fac)[:3]), "FACTOR"), pick(["treatments", "solutions", "levels"]), "on", o),
              lambda: e.say("all in one", pick(["growth chamber", "chamber", "growth room"]), ",", str(R.choice([24, 36, 48, 60])), ("pots", "EXP"))]
    if maybe(0.7):
        e.spec["blocking_factors"] = ["shelf"]
        pieces.append(lambda: e.say("on", numtxt(R.randint(2, 6), R), ("shelves", "BLOCK")))
    join(e, pieces)
    return e


def fam_mouse_cage():
    e = Ex(R, "mouse", "mouse_cage")
    e.spec["organism"] = "Mus musculus"
    fac = pick(["antibiotic", "diet"])
    e.factor(fac, 2, "cage")
    n = R.randint(2, 6)
    e.spec.update({"experimental_unit": "cage", "measurement_unit": "mouse", "subsamples_per_unit": n})
    pieces = [lambda: e.say((pick(["antibiotics vs control", "antibiotic cocktail vs water"]) if fac == "antibiotic" else pick(["high-fat vs low-fat diet", "high-fat diet vs chow"]), "FACTOR"),
                            pick(["given", "delivered", "provided"]), (pick(["in the drinking water", "in the diet", "in the chow"]), "APPLY")),
              lambda: e.say(numtxt(R.randint(6, 20), R), ("mice", "ORG") if False else "mice", "per group housed", (numtxt(n, R), "SUB_N"), "per", ("cage", "EXP"))]
    if maybe(0.4): pieces.append(lambda: (e.factor("sex", 2), e.say((pick(["male and female", "both sexes"]), "FACTOR"))))
    if maybe(0.4): pieces.append(lambda: outcome(e, MOUSE_OUTCOMES + ["gene_expression"]))
    if maybe(0.4): pieces.append(lambda: distractor(e, "animal"))
    join(e, pieces)
    return e


def fam_mouse_litter():
    e = Ex(R, "mouse", "mouse_litter")
    n = R.randint(2, 5); d = R.randint(3, 10)
    e.spec.update({"experimental_unit": "litter", "measurement_unit": "pup", "subsamples_per_unit": n})
    fac = pick(["diet", "treatment"])
    e.factor(fac, 2, "dam")
    e.design("reps", d)
    pieces = [lambda: e.say((pick(["maternal high-fat diet", "a drug", "valproic acid", "the compound"]), "FACTOR"), "given", (pick(["to pregnant dams", "during pregnancy", "to dams"]), "APPLY")),
              lambda: e.say("then I test", (numtxt(n, R), "SUB_N"), (pick(["pups", "offspring"]), "MEAS"), "per", ("litter", "EXP")),
              lambda: e.say((numtxt(d, R), "REPS_N"), pick(["dams per group", "litters per group", "dams per diet"]))]
    join(e, pieces)
    return e


def fam_mouse_individual():
    e = Ex(R, "mouse", "mouse_individual")
    e.spec.update({"experimental_unit": "mouse", "measurement_unit": "mouse"})
    k = R.randint(2, 5)
    e.factor("treatment", k, "mouse")
    pieces = [lambda: e.say((numtxt(k, R), "LEVELS_N"), (pick(["treatment groups", "dose groups", "drug groups"]), "FACTOR")) if k > 2 else
              e.say((pick(["drug vs vehicle", "drug injection versus saline", "compound vs vehicle"]), "FACTOR")),
              lambda: e.say(pick(["each mouse", "mice"]), (pick(aliases("application", "individual")), "APPLY"))]
    if maybe(0.5):
        e.spec["blocking_factors"] = ["cage"]
        pieces.append(lambda: e.say("randomized", ("within cages", "BLOCK"), "of", numtxt(R.randint(3, 5), R)))
    if maybe(0.5): pieces.append(lambda: outcome(e, MOUSE_OUTCOMES))
    if maybe(0.3):
        e.spec["blocking_factors"] = ["experimenter"]
        pieces.append(lambda: e.say("two", ("technicians", "BLOCK"), "will test them"))
    join(e, pieces)
    return e


def fam_mouse_factorial():
    e = Ex(R, "mouse", "mouse_factorial")
    pieces = [lambda: (e.factor("treatment", 2), e.say((pick(["drug vs vehicle", "treatment vs control"]), "FACTOR"))),
              lambda: (e.factor("sex", 2), e.say((pick(["male and female", "both sexes", "males and females"]), "FACTOR"), pick(["mice", "animals", ""])))]
    if maybe(0.5):
        pieces.append(lambda: (e.factor("genotype", 2), e.say(("two", "LEVELS_N"), ("strains", "FACTOR"))))
    join(e, pieces)
    return e


def fam_mouse_cells():
    e = Ex(R, "mouse", "mouse_cells")
    n = R.choice([20, 30, 50, 100])
    e.spec.update({"experimental_unit": "mouse", "measurement_unit": "cell", "subsamples_per_unit": n})
    e.design("reps", 1)
    e.factor("genotype", 2)
    e.say("I recorded", (numtxt(n, R), "SUB_N"), (pick(["neurons", "cells"]), "MEAS"), "from", ("one", "REPS_N"),
          (pick(["knockout", "mutant"]), "FACTOR"), ("mouse", "EXP"), "and", numtxt(n, R), "from one wild-type mouse.")
    return e


def fam_fly_lifespan():
    e = Ex(R, "drosophila", "fly_lifespan")
    e.spec.update({"organism": "Drosophila melanogaster", "experimental_unit": "vial", "measurement_unit": "fly",
                   "primary_outcome": {"name": "lifespan", "type": "survival"}})
    k = R.randint(2, 5)
    e.factor("diet", k, "vial")
    pieces = [lambda: e.say((pick(["lifespan", "survival", "longevity"]), "OUTCOME"), "of", (pick(["Dahomey females", "wild-type flies", "Canton-S males", "flies"]), "ORG"),
                            "on", (numtxt(k, R), "LEVELS_N"), (pick(["yeast concentrations", "diets", "food types"]), "FACTOR"))]
    if maybe(0.5):
        n = R.randint(8, 15)
        e.spec["subsamples_per_unit"] = n
        pieces.append(lambda: e.say((numtxt(n, R), "SUB_N"), ("flies", "MEAS"), "per", ("vial", "EXP")))
    if maybe(0.4):
        v = R.randint(5, 20); e.design("reps", v)
        pieces.append(lambda: e.say((numtxt(v, R), "REPS_N"), "vials per diet"))
    if maybe(0.4): pieces.append(lambda: distractor(e, "fly"))
    join(e, pieces)
    return e


def fam_fly_genotype():
    e = Ex(R, "drosophila", "fly_genotype")
    e.spec["organism"] = "Drosophila melanogaster"
    m = R.randint(1, 3)
    e.factor("genotype", m + 1)
    o = pick(["wing size", "body size", "lifespan"])
    canon = {"wing size": "wing_size", "body size": "wing_size", "lifespan": "lifespan"}[o]
    if o != "body size":
        e.spec["primary_outcome"] = {"name": canon, "type": OUTCOME_TYPE.get(canon, "continuous")}
    if m == 1:
        e.say("Comparing", (o, "OUTCOME") if o != "body size" else o, "of a", ("mutant", "FACTOR"), "line to", pick(["wild type", "Canton-S", "the control"]), "flies")
    else:
        e.say("Measuring", (o, "OUTCOME") if o != "body size" else o, "in", (numtxt(m, R), "GENO_N"), "mutants vs a control",
              pick([". I set up crosses with 8 females per vial", "", ". Eggs from cages"]))
    return e


def fam_rnaseq():
    e = Ex(R, "bulk_rnaseq", "rnaseq")
    o = org(e, ["Sorghum bicolor", "Zea mays", "Arabidopsis thaliana", "Saccharomyces cerevisiae", "Mus musculus"])
    k = R.randint(2, 3)
    pieces = [lambda: e.say(assay(e, "rnaseq", pick(["RNA-seq", "bulk RNA-seq", "transcriptome profiling"])), "of", o),
              lambda: (e.factor("genotype", k), e.say((numtxt(k, R), "GENO_N"), pick(["genotypes", "lines", "strains"]),
                                                         pick(["", "", "", "(drought-tolerant and susceptible)" if k == 2 else "", "(resistant and susceptible)" if k == 2 else ""])))]
    if maybe(0.6):
        f = pick(["water", "temperature", "nitrogen"]); e.factor(f, 2)
        pieces.append(lambda: e.say("under", (pick(["drought vs control", "heat vs control", "low vs high nitrogen"]), "FACTOR")))
    if maybe(0.7): pieces.append(lambda: reps(e, ("replicates", "biological replicates", "reps")))
    if maybe(0.3):
        e.spec["blocking_factors"] = ["library_batch"]
        pieces.append(lambda: e.say("libraries prepared in two", ("batches", "BLOCK")))
    join(e, pieces)
    return e


def fam_lipidomics():
    e = Ex(R, "metabolomics_lipidomics", "lipidomics")
    o = org(e, ["Sorghum bicolor", "Zea mays", "Glycine max", "Arabidopsis thaliana"])
    k = R.randint(10, 300)
    pieces = [lambda: e.say(pick(["Untargeted LC-MS lipidomics", "Lipidomics", "Metabolomics"]), "of leaves from", (numtxt(k, R), "GENO_N"), o, pick(GENO_NOUNS))]
    e.factor("genotype", k)
    if maybe(0.6):
        e.factor("water", 2)
        pieces.append(lambda: e.say("under", (pick(["two water treatments", "drought and control"]), "FACTOR")))
    if maybe(0.6): pieces.append(lambda: reps(e, ("replicates", "reps")))
    if maybe(0.5):
        e.spec["blocking_factors"] = ["injection_batch"]
        pieces.append(lambda: e.say("about 100 injections per", ("batch", "BLOCK")))
    join(e, pieces)
    return e


def fam_singlecell():
    e = Ex(R, "single_cell", "singlecell")
    n = R.choice([2, 3, 4, 5]); c = R.choice([2000, 5000, 8000])
    e.spec.update({"experimental_unit": "mouse", "measurement_unit": "cell", "subsamples_per_unit": c, "organism": "Mus musculus"})
    e.design("reps", n)
    e.factor("injury", 2)
    e.say(assay(e, "single_cell", pick(["scRNA-seq", "single-cell RNA-seq"])), "of", pick(["spinal cord", "liver", "lung"]), "from", (numtxt(n, R), "REPS_N"),
          ("injured and", "FACTOR"), numtxt(n, R), ("uninjured", "FACTOR"), ("mice", "EXP") if False else "mice", ",", "about",
          (f"{c:,}" if maybe() else str(c), "SUB_N"), ("cells", "MEAS"), "each")
    return e


def fam_cellculture():
    e = Ex(R, "cell_culture", "cellculture")
    n = R.randint(2, 6)
    e.spec.update({"experimental_unit": "culture_passage", "measurement_unit": "well", "subsamples_per_unit": n})
    e.design("reps", 1)
    e.factor("treatment", 2)
    e.say("Treating", pick(["HeLa cells", "HEK293 cells", "a cell line"]), "with", (pick(["compound vs DMSO", "drug vs vehicle"]), "FACTOR"), ",",
          (numtxt(n, R), "SUB_N"), ("wells", "MEAS"), "each on one plate,", ("one", "REPS_N"), "experiment")
    return e


# ---------------------------------------------------------------- round-2 families (from held-out error analysis)
def fam_mouse_housing():
    e = Ex(R, "mouse", "mouse_housing")
    k = R.randint(2, 5)
    e.factor("treatment", k)
    o = org(e, ["Mus musculus", "Rattus norvegicus"])
    e.say(pick(["Behaviour study in", "Anxiety study in", "Metabolic study in", "Study in"]), pick(["male", "female", ""]), o, "with",
          (numtxt(k, R), "LEVELS_N"), (pick(["treatment groups", "drug groups", "dose groups"]), "FACTOR"), ".",
          pick(["Should I single-house them?", "Should they be group-housed?", "Can I keep them 4 per cage?", "How many per cage?"]))
    return e


def fam_mouse_claim():
    e = Ex(R, "mouse", "mouse_claim")
    e.factor("treatment", 2); e.factor("sex", 2)
    a, b = R.sample(["males", "females"], 2)
    e.say("The", (pick(["drug", "treatment", "compound", "diet"]), "FACTOR"), pick(["worked in", "had an effect in", "reduced weight in"]), (a, "FACTOR"),
          f"(p < 0.0{R.randint(1, 5)})", "but not in", (b, "FACTOR"), f"(p = 0.{R.randint(1, 6)})", ".",
          pick(["Can we say the effect is sex-specific?", "Is that a sex difference?", "Can we claim it?"]))
    return e


def fam_mouse_behaviour():
    e = Ex(R, "mouse", "mouse_behaviour")
    e.spec["primary_outcome"] = {"name": "mechanical_threshold", "type": "continuous"}
    e.factor("injury", 2)
    e.spec["blocking_factors"] = ["experimenter"]
    e.say((pick(["Von Frey pain thresholds", "Mechanical thresholds", "Pain thresholds"]), "OUTCOME"), "after",
          (pick(["nerve injury vs sham", "injury vs sham surgery", "spinal injury vs sham"]), "FACTOR"), ".",
          pick(["Two", "Three"]), (pick(["technicians", "experimenters"]), "BLOCK"), pick(["will test the mice", ", one man and one woman, will score them", "share the testing"]), ".")
    return e


def fam_mouse_brief():
    e = Ex(R, "mouse", "mouse_brief")
    e.spec["organism"] = "Mus musculus"
    e.factor("treatment", 2); e.factor("sex", 2)
    e.say(pick(["I want to compare", "We plan to compare", "Comparing"]), (pick(["a treatment with a control", "treatment and control", "drug and vehicle"]), "FACTOR"),
          "in", (pick(["male and female", "both male and female"]), "FACTOR"), (pick(["mice", "C57BL/6 mice"]), "ORG"), ".")
    return e


def fam_fly_claim():
    e = Ex(R, "drosophila", "fly_claim")
    e.spec["organism"] = "Drosophila melanogaster"
    e.spec["primary_outcome"] = {"name": "lifespan", "type": "survival"}
    e.factor("genotype", 2)
    if maybe():
        e.say("Our", ("mutant", "FACTOR"), "line", ("lives", "OUTCOME"), f"{R.randint(10, 60)}% longer than", pick(["Canton-S", "w1118", "Oregon-R", "wild type"]), ".",
              pick(["Is that enough to publish?", "Is that real?", "Can we publish this?"]))
    else:
        e.say("We", ("overexpress", "FACTOR"), "a gene with", pick(["da-GAL4 > UAS-geneX", "tub-GAL4 > UAS-geneY", "an RNAi line"]), "and compare",
              (pick(["lifespan", "survival"]), "OUTCOME"), "to", pick(["wild type", "Canton-S", "the control"]), ".")
    return e


def fam_gh_layout():
    e = Ex(R, "greenhouse", "gh_layout")
    g = R.randint(6, 40); f = pick(["nitrogen", "water", "salt"]); r = R.randint(3, 6)
    e.factor("genotype", g); e.factor(f, 2); e.design("reps", r)
    o = org(e, POT_PLANTS)
    e.say(pick(["Greenhouse bay:", "Our glasshouse:", "Greenhouse layout:"]),
          pick(["door at the south end, cooling pad on the east wall, fans on the west", "door on the north side, heaters along one wall",
                "overhead sprinklers and a cooling pad at one end", "vents on the roof and a door next to bench 1"]), ".",
          numtxt(R.randint(4, 10), R), ("benches", "BLOCK"), ". Testing", (numtxt(g, R), "GENO_N"), o, "genotypes x", ("2", "LEVELS_N"),
          (pick(aliases("factor", f)[:3]), "FACTOR"), "levels,", (numtxt(r, R), "REPS_N"), "plants per combination.")
    e.spec["blocking_factors"] = ["bench"]
    return e


def fam_gh_gradient():
    e = Ex(R, "greenhouse", "gh_gradient")
    t = R.randint(6, 30); b = R.randint(2, 6); s = R.randint(4, 20)
    e.factor("treatment", t); e.design("reps", b)
    e.spec.update({"experimental_unit": "pot", "measurement_unit": "plant", "subsamples_per_unit": s})
    o = org(e, POT_PLANTS)
    e.say(o, "pot experiment in a greenhouse", pick(["that has a strong north-south light and temperature gradient", "with a gradient from the door", "with uneven light"]), ".",
          (numtxt(t, R), "LEVELS_N"), ("treatments", "FACTOR"), ",", str(t * b), "pots on", (numtxt(b, R), "REPS_N"), pick(["tables", "benches"]), ",",
          (numtxt(s, R), "SUB_N"), ("plants", "MEAS"), "per", ("pot", "EXP"), ".", pick(["Should I keep rotating the pots or block them?", "Do I rotate or block?", ""]))
    return e


def fam_chamber_lab():
    e = Ex(R, "growth_chamber", "chamber_lab")
    k = R.randint(2, 6)
    o = org(e, ["Arabidopsis thaliana", "Oryza sativa", "Hordeum vulgare"])
    e.factor("genotype", k)
    oc = pick(["leaf_growth", "flowering_time", "biomass"])
    e.spec["primary_outcome"] = {"name": oc, "type": "continuous"}
    e.say(pick(["We compared", "We measured"]), (pick(aliases("outcome", oc)) if oc != "leaf_growth" else "leaf growth", "OUTCOME"), "of",
          (numtxt(k, R), "GENO_N"), o, pick(["accessions", "lines", "genotypes"]), pick(["in our growth chambers", "in a growth chamber", "in the growth room"]),
          "and got", pick(["a different ranking than another lab", "different results from last year", "results another lab could not reproduce"]), ".",
          pick(["How do I make the result robust?", "What should I change?", ""]))
    return e


def fam_field_nursery():
    e = Ex(R, "field", "field_nursery")
    f = R.randint(10, 80)
    e.spec["experimental_unit"] = "plant"
    e.factor("genotype", f); e.design("reps", 1)
    e.say(pick(["Single-plant selection nursery:", "Spaced-plant nursery:", "F2 nursery:"]), f"{R.choice([500, 1000, 2000, 3000]):,}", "spaced plants from",
          (numtxt(f, R), "GENO_N"), pick(["families", "crosses", "populations"]), ",", ("no", "REPS_N"), "replication.",
          pick(["Can I adjust for soil differences?", "How do I correct for soil?", ""]))
    return e



# ---------------------------------------------------------------- round-3 families: genetics, MET, multi-omics, validation
CROPS_GEN = ["Sorghum bicolor", "Zea mays", "Triticum aestivum", "Oryza sativa", "Glycine max", "Hordeum vulgare", "Arabidopsis thaliana", "Setaria viridis"]


def mating(e, canon, text=None):
    e.spec.setdefault("population", {})["mating"] = canon
    return (text or pick(aliases("mating", canon)), "MATING")


def assay(e, canon, text=None):
    a = e.spec.setdefault("assays", [])
    if canon not in a:
        a.append(canon)
    return (text or pick(aliases("assay", canon)[:4]), "ASSAY")


def fam_inbreeding_selfing():
    e = Ex(R, "breeding_genetics", "inbreeding_selfing")
    g = R.randint(4, 8)
    n = R.choice([150, 200, 250, 300, 400])
    e.spec["population"] = {"type": "ril", "parents": 2, "filial_generation": g}
    o = org(e, CROPS_GEN)
    e.factor("genotype", n)
    e.say(pick(["I crossed two", "We made a cross between two", "From a biparental cross of two"]), o, "parents", "and want to make",
          (numtxt(n, R), "GENO_N"), pick(["RILs", "recombinant inbred lines", "inbred lines"]), "by", mating(e, "selfing"), "to",
          (pick([f"F{g}", f"F{g} generation"]), "GEN_N"), ".", pick(["How homozygous will they be?", "How many lines should I start with?", "How do I phenotype them?", ""]))
    e.spec["population"]["parents"] = 2
    return e


def fam_inbreeding_sib():
    e = Ex(R, "breeding_genetics", "inbreeding_sib")
    g = R.randint(5, 25)
    o = org(e, ["Mus musculus", "Drosophila melanogaster", "Danio rerio"])
    e.spec["population"] = {"generations": g}
    e.say(pick(["We maintain a new", "Starting a new", "Our"]), o, pick(["line", "strain", "colony"]), "by", mating(e, "sib_mating"), "for",
          (numtxt(g, R) + " generations", "GEN_N"), ".", pick(["Is it inbred yet?", "When can we call it inbred?", "How much heterozygosity is left?", "How do we check it?"]))
    return e


def fam_backcross():
    e = Ex(R, "breeding_genetics", "backcross")
    g = R.randint(2, 7)
    o = org(e, CROPS_GEN + ["Mus musculus", "Drosophila melanogaster"])
    e.spec["population"] = {"generations": g}
    e.say(pick(["We are introgressing a mutation into", "Moving a transgene into", "Introgressing a QTL into",
                 "Introgressing a disease resistance gene into", "Moving a blight resistance locus into",
                 "Backcrossing a high-oil allele into", "Introgressing a drought tolerance QTL into"]), pick(["the elite background", "our lab background", "B73", "BTx623", "C57BL/6"]),
          "of", o, "by", mating(e, "backcross"), "for", (numtxt(g, R) + " generations", "GEN_N"), ".", pick(["Is that enough?", "How much donor genome remains?", "What controls do I need?"]))
    return e


def fam_diallel():
    e = Ex(R, "breeding_genetics", "diallel")
    p = R.randint(4, 12)
    e.spec["population"] = {"parents": p}
    o = org(e, ["Zea mays", "Sorghum bicolor", "Oryza sativa", "Gossypium hirsutum", "Pennisetum glaucum"])
    pieces = [lambda: e.say(pick(["I want a", "Planning a", "We'll make a"]), mating(e, "diallel"), "among", (numtxt(p, R), "PARENT_N"), o, pick(["inbred parents", "parents", "lines"]),
                            pick(["with reciprocals", "without reciprocals", "", "including selfs"])),
              lambda: e.say("to estimate", (pick(["combining ability", "GCA and SCA", "heterosis"]), "OUTCOME"))]
    e.spec["primary_outcome"] = {"name": "gca_sca", "type": "continuous"}
    if maybe(0.6): pieces.append(lambda: locations(e))
    if maybe(0.5): pieces.append(lambda: reps(e))
    join(e, pieces)
    return e


def fam_nc2():
    e = Ex(R, "breeding_genetics", "nc2")
    m, f = R.randint(3, 10), R.randint(3, 10)
    e.spec["population"] = {"parents": m + f}
    o = org(e, ["Zea mays", "Sorghum bicolor", "Oryza sativa", "Pennisetum glaucum"])
    nloc = R.randint(2, 5)
    e.design("locations", nloc)
    e.say(mating(e, "nc_design", pick(["North Carolina Design II", "NC II", "an NC II design"])), "with", (numtxt(m, R), "PARENT_N"), "males and", (numtxt(f, R), "PARENT_N"), "females of", o,
          pick([", hybrids tested at", "; F1s evaluated in"]), (numtxt(nloc, R), "LOC_N"), "locations")
    return e


def fam_mapping_pop():
    e = Ex(R, "breeding_genetics", "mapping_pop")
    kind = pick(["nam", "ril", "biparental", "dh"])
    o = org(e, CROPS_GEN)
    if kind == "nam":
        fam, per = R.randint(5, 30), R.choice([100, 150, 200])
        e.spec["population"] = {"type": "nam", "parents": fam + 1}
        e.factor("genotype", fam * per)
        e.say("A", mating(e, "nam", pick(["NAM", "nested association mapping"])), "population in", o, ":", (numtxt(fam, R), "PARENT_N"), "founders crossed to a common parent,",
              str(per), "RILs each, so", (f"{fam * per:,}" if fam * per >= 1000 else str(fam * per), "GENO_N"), "lines")
    else:
        n = R.choice([94, 150, 188, 200, 300])
        e.spec["population"] = {"type": kind, "parents": 2}
        e.factor("genotype", n)
        e.say((numtxt(n, R), "GENO_N"), mating(e, kind), "from", o, pick(["for QTL mapping", "to map drought tolerance", "to map flowering time"]))
    if maybe(0.6):
        e.say(","); locations(e)
    if maybe(0.5):
        e.say(","); reps(e)
    e.say(pick([".", ". How do I lay out the field?", ". What design for phenotyping?"]))
    return e


def fam_met():
    e = Ex(R, "multi_environment", "met")
    e.spec["experimental_unit"] = "plot"
    pieces = [lambda: (e.say(pick(["Yield trial of", "Testing", "Evaluating"])), genotypes(e, PLANTS, 10, 400)),
              lambda: locations(e), lambda: seasons(e)]
    if maybe(0.7): pieces.append(lambda: reps(e))
    e.spec["primary_outcome"] = {"name": "grain_yield", "type": "continuous"}
    pieces.append(lambda: e.say("to study", (pick(["yield stability", "yield", "grain yield"]), "OUTCOME"), pick(["and GxE", "across environments", "genotype by environment interaction", ""])))
    join(e, pieces)
    return e


def fam_gh_field():
    e = Ex(R, "multi_environment", "gh_field")
    e.spec["environments"] = ["greenhouse", "field"]
    o_trait = pick(["biomass", "photosynthesis", "plant_height"])
    e.spec["primary_outcome"] = {"name": o_trait, "type": "continuous"}
    pieces = [lambda: (e.say(pick(["Screen", "We screen", "Phenotyping"])), genotypes(e, POT_PLANTS, 6, 300)),
              lambda: e.say("in the", (pick(["greenhouse", "growth chamber", "glasshouse"]), "ENV"), "for", (pick(aliases("outcome", o_trait)[:3]), "OUTCOME"),
                            pick(["early in development", "at the seedling stage", "under drought", ""])),
              lambda: e.say(pick(["and then test whether it predicts", "then validate against", "and compare with"]), (pick(["field", "field trials", "the field"]), "ENV"),
                            pick(["yield", "performance", "drought response"]))]
    if maybe(0.5): pieces.append(lambda: locations(e))
    join(e, pieces)
    return e


def fam_gwas_rnaseq():
    e = Ex(R, "multi_omics", "gwas_rnaseq")
    n = R.choice([150, 200, 250, 300, 350, 400, 500])
    o = org(e, ["Sorghum bicolor", "Zea mays", "Oryza sativa", "Arabidopsis thaliana", "Glycine max"])
    e.factor("genotype", n)
    trait = pick(["lipid_content", "flowering_time", "plant_height"])
    e.spec["primary_outcome"] = {"name": trait, "type": "continuous"}
    pieces = [lambda: e.say(pick(["We have a", "Using a", "I have a"]), (numtxt(n, R), "GENO_N"), "-line", o, "diversity panel with", assay(e, "gwas"), "hits for",
                            (pick(aliases("outcome", trait)[:3]), "OUTCOME")),
              lambda: e.say(pick(["and want to add", "plan to run", "now want"]), assay(e, "rnaseq"), pick(["of leaves", "on one tissue", "at flowering", "in two tissues", ""]),
                            pick(["to find candidate genes", "for eQTL mapping", "to prioritize genes", "for TWAS",
                                 "to find genes behind seed oil content", "to find disease resistance genes", "behind drought tolerance"]))]
    if maybe(0.4): pieces.append(lambda: e.say(pick(["and", "then"]), assay(e, "eqtl"), pick(["colocalization", "analysis"])))
    if maybe(0.3): pieces.append(lambda: e.say(pick(["plus", "and maybe"]), assay(e, "lipidomics")))
    join(e, pieces)
    return e


def fam_riboseq():
    e = Ex(R, "ribo_seq", "riboseq")
    o = org(e, ["Arabidopsis thaliana", "Zea mays", "Saccharomyces cerevisiae", "Mus musculus", "Drosophila melanogaster", "Oryza sativa"])
    f = pick(["temperature", "water", "salt", "genotype"])
    e.factor(f, 2)
    txt = {"temperature": "heat vs control", "water": "drought vs control", "salt": "salt vs control", "genotype": "mutant vs wild type"}[f]
    pieces = [lambda: e.say(assay(e, "ribo_seq"), "on", o, "under", (txt, "FACTOR")),
              lambda: e.say("to measure", (pick(["translation efficiency", "translational regulation", "translation"]), "OUTCOME"))]
    if maybe(0.6): pieces.append(lambda: reps(e, ("replicates", "biological replicates")))
    if maybe(0.4): pieces.append(lambda: e.say(pick(["with matched", "alongside", "together with"]), assay(e, "rnaseq")))
    e.spec["primary_outcome"] = {"name": "translation_efficiency", "type": "continuous"}
    join(e, pieces)
    return e


def fam_atac():
    e = Ex(R, "atac_seq", "atac")
    o = org(e, ["Arabidopsis thaliana", "Zea mays", "Sorghum bicolor", "Oryza sativa", "Mus musculus"])
    f = pick(["water", "temperature", "genotype", "treatment"])
    k = R.randint(2, 4)
    e.factor(f, k)
    pieces = [lambda: e.say(assay(e, "atac_seq"), "of", o, pick(["roots", "leaves", "seedlings", "liver", "shoot apex"]), "across", (numtxt(k, R), "LEVELS_N"),
                            (pick({"water": ["water treatments", "drought levels"], "temperature": ["temperatures"], "genotype": ["genotypes", "lines"], "treatment": ["treatments"]}[f]), "FACTOR"))]
    if maybe(0.6): pieces.append(lambda: reps(e, ("replicates", "biological replicates")))
    if maybe(0.5): pieces.append(lambda: e.say(pick(["with matched", "plus", "and"]), assay(e, "rnaseq"), pick(["from the same tissue", "", "to link peaks to expression"])))
    if maybe(0.3): pieces.append(lambda: e.say("I have only", pick(["crude nuclei", "a few thousand nuclei", "no sorter"])))
    join(e, pieces)
    return e


def fam_validation():
    e = Ex(R, "functional_validation", "validation")
    c = R.randint(1, 10)
    o1 = org(e, ["Sorghum bicolor", "Zea mays", "Oryza sativa", "Mus musculus", "Glycine max"])
    first = e.spec["organism"]
    o2canon = pick({"Sorghum bicolor": ["Arabidopsis thaliana", "Setaria viridis", "Nicotiana benthamiana", "Oryza sativa"],
                    "Zea mays": ["Arabidopsis thaliana", "Setaria viridis", "Nicotiana benthamiana"],
                    "Oryza sativa": ["Arabidopsis thaliana", "Brachypodium distachyon"],
                    "Glycine max": ["Arabidopsis thaliana", "Nicotiana benthamiana"],
                    "Mus musculus": ["Drosophila melanogaster", "Danio rerio", "Caenorhabditis elegans"]}[first])
    o2 = (pick(aliases("organism", o2canon)), "ORG")
    e.spec["organisms"] = [first, o2canon]
    e.spec["candidates"] = c
    pieces = [lambda: e.say(pick(["We found", "GWAS gave us", "Our eQTL analysis prioritized"]), numtxt(c, R),
                            pick(["candidate genes", "candidates", "genes"]), "in", o1),
              lambda: e.say(pick(["and want to validate them", "How do we validate them", "We want to confirm them"]), assay(e, "in_silico", pick(["in silico", "computationally"])), "and in vivo"),
              lambda: e.say("using", assay(e, pick(["crispr", "overexpression", "complementation"])), "in", pick(["the crop", "it", "the original species"]),
                            "and", assay(e, pick(["heterologous", "crispr", "overexpression"])), "in", o2)]
    join(e, pieces)
    return e


FAMILIES = {f.__name__[4:]: f for f in [fam_inbreeding_selfing, fam_inbreeding_sib, fam_backcross, fam_diallel, fam_nc2, fam_mapping_pop, fam_met, fam_gh_field,
                                         fam_gwas_rnaseq, fam_riboseq, fam_atac, fam_validation, fam_mouse_housing, fam_mouse_claim, fam_mouse_behaviour, fam_mouse_brief, fam_fly_claim,
                                         fam_gh_layout, fam_gh_gradient, fam_chamber_lab, fam_field_nursery,fam_field_panel, fam_field_unreplicated, fam_field_treatment, fam_field_line_source,
                                         fam_greenhouse, fam_chamber_between, fam_chamber_trays, fam_chamber_within,
                                         fam_mouse_cage, fam_mouse_litter, fam_mouse_individual, fam_mouse_factorial, fam_mouse_cells,
                                         fam_fly_lifespan, fam_fly_genotype, fam_rnaseq, fam_lipidomics, fam_singlecell, fam_cellculture]}
DEFAULT_WEIGHTS = {"field_panel": 4, "field_unreplicated": 2, "field_treatment": 3, "field_line_source": 1, "greenhouse": 3,
                   "chamber_between": 2, "chamber_trays": 1.5, "chamber_within": 1.5, "mouse_cage": 1.5, "mouse_litter": 1,
                   "mouse_individual": 1.5, "mouse_factorial": 1, "mouse_cells": 0.7, "fly_lifespan": 1.5, "fly_genotype": 1,
                   "rnaseq": 1.5, "lipidomics": 1, "singlecell": 0.7, "cellculture": 0.7,
                   "mouse_housing": 1, "mouse_claim": 1, "mouse_behaviour": 1, "mouse_brief": 1, "fly_claim": 1.2,
                   "gh_layout": 1.2, "gh_gradient": 1.2, "chamber_lab": 1, "field_nursery": 1,
                   "inbreeding_selfing": 1.5, "inbreeding_sib": 1, "backcross": 1, "diallel": 1.5, "nc2": 1, "mapping_pop": 1.5,
                   "met": 2, "gh_field": 1.5, "gwas_rnaseq": 1.5, "riboseq": 1.2, "atac": 1.2, "validation": 1.5}

FILLERS = ["I'm planning my next experiment.", "My advisor wants a defensible design.", "Budget is tight.", "This is for a grant proposal.",
           "Any advice?", "Help me plan this.", "I'm new to experimental design.", "We had problems last season.", "Reviewers asked about our design.",
           "What do you think?", "I need this for my thesis.", "Thanks!", "Quick question:", "Hi,", "So,", "Okay, here's the setup:"]


def noise(d):
    """Fillers, case changes: all unlabeled, so the model learns to ignore them."""
    if R.random() < 0.35:
        f = tokenize(pick(FILLERS))
        if R.random() < 0.5:
            d["tokens"], d["tags"], d["text"] = f + d["tokens"], ["O"] * len(f) + d["tags"], " ".join(f) + " " + d["text"]
        else:
            d["tokens"], d["tags"], d["text"] = d["tokens"] + f, d["tags"] + ["O"] * len(f), d["text"] + " " + " ".join(f)
    r = R.random()
    if r < 0.25:
        d["tokens"] = [t.lower() for t in d["tokens"]]; d["text"] = d["text"].lower()
    elif r < 0.35:
        d["tokens"] = [t[:1].upper() + t[1:] if R.random() < 0.3 else t for t in d["tokens"]]
    return d


lowercase_noise = noise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--weights", help="JSON of family -> weight (from mine_errors.py)")
    a = ap.parse_args()
    R.seed(a.seed)
    w = dict(DEFAULT_WEIGHTS)
    if a.weights and os.path.exists(a.weights):
        w.update(json.load(open(a.weights)))
    names = list(FAMILIES)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    seen = set()
    with open(a.out, "w") as f:
        k = 0
        while k < a.n:
            fam = R.choices(names, weights=[w[n] for n in names])[0]
            d = lowercase_noise(FAMILIES[fam]().render())
            if d["text"] in seen:
                continue
            seen.add(d["text"])
            assert len(d["tokens"]) == len(d["tags"])
            f.write(json.dumps(d) + "\n")
            k += 1
    print(f"wrote {a.n} examples to {a.out}")


if __name__ == "__main__":
    main()
