#!/usr/bin/env python3
"""LLM reader: question -> StudySpec skeleton (JSON), with a local open model (no API, no training).

The model only *reads*: it fills the skeleton with what the researcher stated (plus the method/resource
it recognises, e.g. Cre-lox, EMS mutagenesis, DGRP). Numbers are checked later by the R package
(merge_specs keeps only numbers that appear in the question), and the deterministic engine does the rest.

    python llm/reader.py --examples training/data/fresh_test_v4.jsonl --out preds_llm_fresh_test_v4.json
    python llm/reader.py --text "I want to do a cre flux rat experiment for a gene of my choice"
    python llm/reader.py ... --model Qwen/Qwen2.5-32B-Instruct      # larger GPU

Output format matches inst/python/predict.py: {prompt: spec}, so the same scoring compares
rules, the tagger and this reader.
"""
import argparse, csv, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALIASES = os.path.join(HERE, "..", "inst", "agent", "aliases.tsv")

SYSTEMS = ["field", "greenhouse", "growth_chamber", "mouse", "drosophila", "cell_culture", "bulk_rnaseq", "single_cell",
           "ribo_seq", "atac_seq", "metabolomics_lipidomics", "multi_omics", "breeding_genetics", "multi_environment",
           "functional_validation"]
ASSAYS = ["rnaseq", "small_rnaseq", "single_cell", "atac_seq", "ribo_seq", "chip_seq", "methylation", "gwas", "eqtl",
          "qtl_mapping", "lipidomics", "metabolomics", "crispr", "overexpression", "complementation", "heterologous", "in_silico"]
ORGANISMS = ["Sorghum bicolor", "Zea mays", "Arabidopsis thaliana", "Oryza sativa", "Triticum aestivum", "Hordeum vulgare",
             "Glycine max", "Solanum lycopersicum", "Solanum tuberosum", "Gossypium hirsutum", "Medicago truncatula",
             "Brachypodium distachyon", "Setaria viridis", "Nicotiana benthamiana", "Physcomitrium patens", "Vitis vinifera",
             "Populus trichocarpa", "Eucalyptus grandis", "Pinus taeda", "Malus domestica", "Citrus sinensis",
             "Chlamydomonas reinhardtii", "Brassica napus", "Pennisetum glaucum", "Homo sapiens", "Mus musculus",
             "Rattus norvegicus", "Danio rerio", "Drosophila melanogaster", "Caenorhabditis elegans", "Xenopus laevis",
             "Gallus gallus", "Sus scrofa", "Bos taurus", "Macaca mulatta", "Saccharomyces cerevisiae"]

INSTRUCTIONS = f"""You read a researcher's description of an experiment and fill a fixed JSON skeleton.
Fill ONLY what the researcher stated or what follows directly from their words. Use null when it is not stated.
Never invent numbers: every count must appear in the text (digits or words). Do not give advice here.

Fields:
- goal: "design" (planning a new study) or "analysis" (data already collected; asks which test, how to analyse).
- system: the experimental setting, one of {SYSTEMS}.
  Choose by the main activity: outdoor plots -> field; greenhouse/glasshouse -> greenhouse; growth chamber/room/cabinet
  -> growth_chamber; mice or rats -> mouse; flies -> drosophila; cell lines -> cell_culture; bulk RNA-seq -> bulk_rnaseq;
  scRNA/snRNA-seq -> single_cell; ATAC-seq -> atac_seq; Ribo-seq -> ribo_seq; lipidomics/metabolomics ->
  metabolomics_lipidomics; GWAS together with expression/eQTL -> multi_omics; crosses, selfing, backcrossing, RILs, NAM,
  diallel, mutant populations -> breeding_genetics; the same entries over several locations/years for GxE or stability ->
  multi_environment; validating candidate genes (CRISPR, complementation, another organism) -> functional_validation.
  ChIP-seq, CUT&Tag and methylome have no system of their own: use the setting and list the assay.
- organism: scientific name, one of {ORGANISMS} or another scientific name. organisms: list when more than one.
- method: the genetic tool, resource or approach named, in a few words (e.g. "Cre-lox conditional knockout",
  "EMS mutagenesis", "DGRP reference panel", "CRISPR knockout", "RNAi"), else null.
- assays: list from {ASSAYS}.
- tissue: tissue or organ sampled/measured, else null.
- factors: list of {{"name", "n_levels", "levels", "applied_to"}}. name: genotype (lines, cultivars, strains, mutants,
  accessions), treatment, water (drought/irrigation), temperature (cold/heat), salt, nitrogen, phosphorus, nutrient,
  diet, light, co2, sex, time (time points), stage, age, tissue, disease, injury, antibiotic, environment, or one short word.
  n_levels only if a count is stated or the levels are listed (e.g. "drought vs control" = 2). levels: the level
  names if listed. applied_to: "main_plot" when a field treatment is applied to whole plots (irrigation system, can't
  randomize), "cage", "dam", "chamber", "mouse", "vial" when stated, else null.
- design: {{"reps", "locations", "seasons"}} (replicates/blocks per treatment, sites, years/seasons).
- experimental_unit, measurement_unit, subsamples_per_unit: e.g. 5 plants measured per plot -> "plot", "plant", 5.
- primary_outcome: {{"name", "type"}} only if the measured outcome is stated; type one of continuous, binary, count,
  ordinal, survival. Use snake_case names such as grain_yield, flowering_time, plant_height, biomass, body_weight,
  lifespan, gene_expression, photosynthesis, lipid_content, disease_severity, translation_efficiency.
- outcome_text: the phenotype as the researcher wrote it, if any.
- population: {{"mating", "generations", "filial_generation", "parents"}} for breeding/genetics, else null.
  mating one of selfing, sib_mating, backcross, diallel, nc_design, ril, nam, dh, biparental.
- environments: ["greenhouse", "field"] style list when several settings are compared, else null.
- blocking_factors: e.g. ["bench"], ["cage"], ["library_batch"] when stated, else null.
- sequencing: {{"instrument", "read_length", "layout", "depth_m"}} when stated, else null.
- missing_questions: up to 3 short questions about missing facts that would change the design.
Return one JSON object and nothing else."""

# worked examples written for this prompt (not from any test set)
SHOTS = [
    ("We'll grow 48 barley lines in the field at two sites with three blocks each and score heading date.",
     {"goal": "design", "system": "field", "organism": "Hordeum vulgare", "organisms": None, "method": None, "assays": [],
      "tissue": None, "factors": [{"name": "genotype", "n_levels": 48, "levels": None, "applied_to": None}],
      "design": {"reps": 3, "locations": 2, "seasons": None}, "experimental_unit": "plot", "measurement_unit": None,
      "subsamples_per_unit": None, "primary_outcome": {"name": "heading_date", "type": "continuous"},
      "outcome_text": "heading date", "population": None, "environments": None, "blocking_factors": None, "sequencing": None,
      "missing_questions": ["How many seasons?", "Plot size and seed per line?"]}),
    ("I already have liver RNA-seq from knockout and wild-type mice on two diets, 4 mice per group. Which model finds DE genes?",
     {"goal": "analysis", "system": "bulk_rnaseq", "organism": "Mus musculus", "organisms": None, "method": "knockout",
      "assays": ["rnaseq"], "tissue": "liver",
      "factors": [{"name": "genotype", "n_levels": 2, "levels": ["knockout", "wild-type"], "applied_to": None},
                  {"name": "diet", "n_levels": 2, "levels": None, "applied_to": None}],
      "design": {"reps": 4, "locations": None, "seasons": None}, "experimental_unit": "mouse", "measurement_unit": None,
      "subsamples_per_unit": None, "primary_outcome": {"name": "gene_expression", "type": "continuous"},
      "outcome_text": "DE genes", "population": None, "environments": None, "blocking_factors": None, "sequencing": None,
      "missing_questions": ["Were sexes mixed?", "Were libraries prepared in batches?"]}),
    ("Tamoxifen-inducible floxed allele in rats; I want to knock out my gene in adults and look at behaviour.",
     {"goal": "design", "system": "mouse", "organism": "Rattus norvegicus", "organisms": None,
      "method": "Cre-lox conditional knockout (tamoxifen-inducible CreERT2)", "assays": [], "tissue": None,
      "factors": [{"name": "genotype", "n_levels": None, "levels": None, "applied_to": None},
                  {"name": "treatment", "n_levels": None, "levels": ["tamoxifen", "vehicle"], "applied_to": None}],
      "design": {"reps": None, "locations": None, "seasons": None}, "experimental_unit": None, "measurement_unit": None,
      "subsamples_per_unit": None, "primary_outcome": None, "outcome_text": "behaviour", "population": None,
      "environments": None, "blocking_factors": None, "sequencing": None,
      "missing_questions": ["Which behaviour test is the primary outcome?", "Which control genotypes (Cre-only, flox-only)?",
                            "Both sexes?"]}),
    ("Salt stress on 20 rice accessions in hydroponics in a growth chamber, control vs 100 mM NaCl, 6 plants per tray, 4 trays.",
     {"goal": "design", "system": "growth_chamber", "organism": "Oryza sativa", "organisms": None, "method": None, "assays": [],
      "tissue": None, "factors": [{"name": "genotype", "n_levels": 20, "levels": None, "applied_to": None},
                                  {"name": "salt", "n_levels": 2, "levels": ["control", "100 mM NaCl"], "applied_to": None}],
      "design": {"reps": 4, "locations": None, "seasons": None}, "experimental_unit": "tray", "measurement_unit": "plant",
      "subsamples_per_unit": 6, "primary_outcome": None, "outcome_text": None, "population": None, "environments": None,
      "blocking_factors": None, "sequencing": None,
      "missing_questions": ["Is the salt level applied per tray?", "What is the primary trait?"]}),
]


def messages(question):
    m = [{"role": "system", "content": INSTRUCTIONS}]
    for q, a in SHOTS:
        m += [{"role": "user", "content": q}, {"role": "assistant", "content": json.dumps(a)}]
    m.append({"role": "user", "content": question})
    return m


def parse_json(text):
    """First complete JSON object in the model output (tolerates code fences and trailing commas)."""
    t = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    start = t.find("{")
    if start < 0:
        return None
    depth, instr, esc = 0, False, False
    for i, ch in enumerate(t[start:], start):
        if instr:
            esc = (ch == "\\" and not esc)
            if ch == '"' and not esc:
                instr = False
            continue
        if ch == '"':
            instr = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                blob = re.sub(r",\s*([}\]])", r"\1", t[start:i + 1])
                try:
                    return json.loads(blob)
                except json.JSONDecodeError:
                    return None
    return None


_ORG = None


def canon_organism(x):
    global _ORG
    if not x:
        return None
    if _ORG is None:
        _ORG = {}
        if os.path.exists(ALIASES):
            with open(ALIASES, encoding="utf-8") as f:
                for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                    if r["category"] == "organism":
                        _ORG[r["alias"].lower()] = r["canonical_term"]
        for o in ORGANISMS:
            _ORG[o.lower()] = o
    return _ORG.get(str(x).strip().lower(), str(x).strip())


_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
          "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100}


def _int(x):
    if isinstance(x, str) and x.strip().lower() in _WORDS:
        return _WORDS[x.strip().lower()]
    try:
        v = float(str(x).replace(",", ""))
        return int(v) if v.is_integer() and v > 0 else None
    except (TypeError, ValueError):
        return None


def to_spec(d):
    """Model JSON -> StudySpec list structure (nulls dropped, enums enforced, counts as integers)."""
    if not isinstance(d, dict):
        return {}
    s = {}
    if d.get("goal") in ("design", "analysis"):
        s["goal"] = d["goal"]
    if d.get("system") in SYSTEMS:
        s["system"] = d["system"]
    o = canon_organism(d.get("organism"))
    if o:
        s["organism"] = o
    orgs = [canon_organism(x) for x in (d.get("organisms") or []) if x]
    if len(orgs) > 1:
        s["organisms"] = orgs
    for k in ("method", "tissue", "outcome_text", "experimental_unit", "measurement_unit"):
        if isinstance(d.get(k), str) and d[k].strip():
            s[k] = d[k].strip()
    a = [x for x in (d.get("assays") or []) if x in ASSAYS]
    if a:
        s["assays"] = list(dict.fromkeys(a))
    n = _int(d.get("subsamples_per_unit"))
    if n:
        s["subsamples_per_unit"] = n
    fx = []
    for f in d.get("factors") or []:
        if not isinstance(f, dict) or not f.get("name"):
            continue
        g = {"name": str(f["name"]).strip().lower().replace(" ", "_")}
        k = _int(f.get("n_levels"))
        lv = [str(v) for v in (f.get("levels") or []) if str(v).strip()]
        if k is None and len(lv) >= 2:
            k = len(lv)
        if k:
            g["n_levels"] = k
        if lv:
            g["levels"] = lv
        if f.get("applied_to") in ("main_plot", "cage", "dam", "chamber", "mouse", "vial", "tray"):
            g["applied_to"] = f["applied_to"]
        fx.append(g)
    if fx:
        s["factors"] = fx
    des = {k: _int((d.get("design") or {}).get(k)) for k in ("reps", "locations", "seasons")}
    des = {k: v for k, v in des.items() if v}
    if des:
        s["design"] = des
    po = d.get("primary_outcome")
    if isinstance(po, dict) and po.get("name"):
        s["primary_outcome"] = {"name": str(po["name"]).strip().lower().replace(" ", "_"),
                                "type": po.get("type") if po.get("type") in ("continuous", "binary", "count", "ordinal", "survival") else "continuous"}
    pop = d.get("population")
    if isinstance(pop, dict):
        p = {}
        if pop.get("mating") in ("selfing", "sib_mating", "backcross", "diallel", "nc_design", "ril", "nam", "dh", "biparental"):
            p["mating"] = pop["mating"]
        for k in ("generations", "filial_generation", "parents"):
            if _int(pop.get(k)):
                p[k] = _int(pop.get(k))
        if p:
            s["population"] = p
    for k in ("environments", "blocking_factors", "missing_questions"):
        v = [str(x) for x in (d.get(k) or []) if str(x).strip()]
        if v:
            s[k] = v
    sq = d.get("sequencing")
    if isinstance(sq, dict):
        q = {k: sq[k] for k in ("instrument", "layout") if isinstance(sq.get(k), str) and sq[k]}
        for k in ("read_length", "depth_m"):
            if sq.get(k) is not None:
                try:
                    q[k] = float(sq[k])
                except (TypeError, ValueError):
                    pass
        if q:
            s["sequencing"] = q
    return s


def run_vllm(questions, model, max_len=8192, tp=1):
    from vllm import LLM, SamplingParams
    llm = LLM(model=model, dtype="bfloat16", max_model_len=max_len, tensor_parallel_size=tp, gpu_memory_utilization=0.90)
    tok = llm.get_tokenizer()
    prompts = [tok.apply_chat_template(messages(q), tokenize=False, add_generation_prompt=True) for q in questions]
    outs = llm.generate(prompts, SamplingParams(temperature=0.0, max_tokens=1200))
    return [o.outputs[0].text for o in outs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("READER", "Qwen/Qwen2.5-14B-Instruct"))
    ap.add_argument("--examples", nargs="*", default=[], help="jsonl files with a 'prompt' field")
    ap.add_argument("--text", default=None)
    ap.add_argument("--out", default=None, help="predictions json (one file) or folder (several example files)")
    ap.add_argument("--raw", action="store_true", help="also save raw model outputs")
    ap.add_argument("--tp", type=int, default=1, help="tensor parallel GPUs")
    a = ap.parse_args()
    sets = {}
    for f in a.examples:
        with open(f, encoding="utf-8") as fh:
            sets[f] = [json.loads(l)["prompt"] for l in fh if l.strip()]
    if a.text:
        sets["text"] = [a.text]
    allq = list(dict.fromkeys(q for qs in sets.values() for q in qs))
    raw = dict(zip(allq, run_vllm(allq, a.model, tp=a.tp)))
    specs = {q: to_spec(parse_json(t)) for q, t in raw.items()}
    bad = sum(1 for q in allq if not specs[q])
    print(f"read {len(allq)} prompts; {bad} unparseable", file=sys.stderr)
    if a.text and not a.out:
        print(json.dumps(specs[a.text], indent=1))
        return
    for f, qs in sets.items():
        if f == "text":
            continue
        name = os.path.splitext(os.path.basename(f))[0]
        out = a.out if (a.out and len(sets) == 1 and a.out.endswith(".json")) else os.path.join(a.out or ".", f"preds_llm_{name}.json")
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        json.dump({q: specs[q] for q in qs}, open(out, "w"), indent=1)
        if a.raw:
            json.dump({q: raw[q] for q in qs}, open(out.replace(".json", "_raw.json"), "w"), indent=1)
        print(f"wrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
