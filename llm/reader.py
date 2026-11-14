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
           "functional_validation", "livestock"]
ASSAYS = ["rnaseq", "small_rnaseq", "single_cell", "atac_seq", "ribo_seq", "chip_seq", "methylation", "gwas", "eqtl",
          "qtl_mapping", "lipidomics", "metabolomics", "crispr", "overexpression", "complementation", "heterologous", "in_silico",
          "scatac_seq", "amplicon", "m6a_seq", "long_read_rna", "gbs", "degradome", "hic", "medip", "mnase_seq", "nascent_rna",
          "spatial", "targeted_capture", "rip_clip", "metagenomics", "pool_seq", "bsa_seq", "trap_seq", "wgs"]
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
- system: one of {SYSTEMS}. Decide in this order and stop at the first that applies:
  1. study type: validating candidate genes (CRISPR, complementation, another organism) -> functional_validation;
     GWAS together with expression/eQTL -> multi_omics; crosses, selfing, backcrossing, RILs, NAM, diallel, mutant
     populations -> breeding_genetics; the same entries over several locations/years for GxE or stability, or a
     greenhouse/chamber screen checked against the field -> multi_environment.
  2. the setting, when the text names it: growth chamber/room/climate chamber -> growth_chamber; greenhouse/glasshouse/
     net house -> greenhouse; field/paddy/orchard -> field; mice or rats -> mouse; flies/Drosophila -> drosophila;
     cell lines, ES/iPS cells, organoids, yeast or algal cultures -> cell_culture; farm animals (pigs, cattle, chickens,
     broilers, hens, sheep, goats) -> livestock. The assay still goes in assays: RNA-seq of leaves in a growth chamber
     is system growth_chamber with assays ["rnaseq"].
  3. only when no setting is named, the assay family: bulk/small/long-read RNA-seq -> bulk_rnaseq; scRNA/snRNA/scATAC
     -> single_cell; ATAC-seq -> atac_seq; Ribo-seq -> ribo_seq; lipidomics/metabolomics -> metabolomics_lipidomics.
  ChIP-seq, CUT&Tag and methylome have no system of their own: use the setting and list the assay.
- organism: scientific name, one of {ORGANISMS} or another scientific name. organisms: list when more than one.
- method: the genetic tool, resource or approach named, in a few words (e.g. "Cre-lox conditional knockout",
  "EMS mutagenesis", "DGRP reference panel", "CRISPR knockout", "RNAi"), else null.
- assays: list from {ASSAYS}.
  Synonyms: 3' Tag-seq/QuantSeq, lncRNA-seq, circRNA-seq -> rnaseq; CUT&Tag, CUT&RUN -> chip_seq; WGBS/RRBS -> methylation;
  MeDIP/hMeDIP -> medip; scATAC/snATAC/multiome -> scatac_seq; 16S/ITS amplicon -> amplicon; MeRIP/m6A-seq -> m6a_seq;
  Iso-Seq/nanopore direct RNA -> long_read_rna; GBS/RAD-seq/SLAF-seq -> gbs; degradome/PARE -> degradome; Hi-C/HiChIP -> hic;
  PRO-seq/GRO-seq/NET-seq -> nascent_rna; RIP-seq/CLIP-seq -> rip_clip; exome/sequence capture -> targeted_capture.
- tissue: tissue or organ sampled/measured, else null.
- factors: list of {{"name", "n_levels", "levels", "applied_to"}}. name: genotype (lines, cultivars, strains, mutants,
  accessions), treatment, water (drought/irrigation), temperature (cold/heat), salt, nitrogen, phosphorus, nutrient,
  diet, light, co2, sex, time (time points), stage, age, tissue, cell_type, disease, infection (pathogen or mock inoculation),
  injury, antibiotic, dose (dose series), species, generation, soil, phenotype_group (extreme groups chosen by phenotype,
  e.g. resistant vs susceptible animals), environment, or one short word. Breeds, strains and lines are genotype.
  n_levels only if a count is stated or the levels are listed (e.g. "drought vs control" = 2). levels: the level
  names if listed. applied_to: "main_plot" when a field treatment is applied to whole plots (irrigation system, can't
  randomize), "cage", "pen", "tank", "dam", "chamber", "mouse", "vial" when stated, else null.
- design: {{"reps", "locations", "seasons"}} (replicates/blocks per treatment, sites, years/seasons).
- experimental_unit, measurement_unit, subsamples_per_unit: e.g. 5 plants measured per plot -> "plot", "plant", 5;
  25 chicks per pen with the diet given per pen -> "pen", "animal", 25; fish in tanks -> "tank", "fish".
- primary_outcome: {{"name", "type"}} only if the measured outcome is stated; type one of continuous, binary, count,
  ordinal, survival. Use snake_case names such as grain_yield, flowering_time, plant_height, biomass, body_weight,
  lifespan, gene_expression, photosynthesis, lipid_content, disease_severity, translation_efficiency.
- outcome_text: the phenotype as the researcher wrote it, if any.
- population: {{"mating", "generations", "filial_generation", "parents"}} for breeding/genetics, else null.
  mating one of selfing, sib_mating, backcross, diallel, nc_design, ril, nam, dh, biparental.
- environments: ["greenhouse", "field"] style list when several settings are compared, else null. "greenhouse" stands
  for any controlled environment (greenhouse, glasshouse, growth chamber or room).
- blocking_factors: e.g. ["bench"], ["cage"], ["litter"], ["donor"], ["clutch"], ["farm"], ["library_batch"] when stated, else null.
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
     {"goal": "analysis", "system": "mouse", "organism": "Mus musculus", "organisms": None, "method": "knockout",
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


def messages(question, shots=True):
    m = [{"role": "system", "content": INSTRUCTIONS}]
    for q, a in (SHOTS if shots else []):
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
    org = d.get("organism")
    listed = org if isinstance(org, list) else []
    o = canon_organism(listed[0] if listed else org) if (listed or isinstance(org, str)) else None
    if o and str(o).lower() not in ("null", "none", "unknown", "n/a"):
        s["organism"] = o
    orgs = [canon_organism(x) for x in ((d.get("organisms") or []) + listed) if isinstance(x, str) and x]
    orgs = list(dict.fromkeys(orgs))
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


class VLLMBackend:
    """Loads the model once (optionally with a LoRA adapter from llm/train_lora.py) and answers batches."""

    def __init__(self, model, adapter=None, max_len=8192, tp=1, eager=False):
        # GPU nodes often have no nvcc: avoid FlashInfer's JIT-compiled kernels unless the user chose otherwise
        os.environ.setdefault("VLLM_ATTENTION_BACKEND", "FLASH_ATTN")
        os.environ.setdefault("VLLM_USE_FLASHINFER_SAMPLER", "0")
        from vllm import LLM, SamplingParams
        kw = {"enable_lora": True, "max_lora_rank": 64} if adapter else {}
        self.llm = LLM(model=model, dtype="bfloat16", max_model_len=max_len, tensor_parallel_size=tp,
                       gpu_memory_utilization=0.90, enforce_eager=eager, **kw)
        self.tok = self.llm.get_tokenizer()
        self.params = SamplingParams(temperature=0.0, max_tokens=1200)
        self.lora = None
        if adapter:
            from vllm.lora.request import LoRARequest
            self.lora = LoRARequest("biodes", 1, os.path.abspath(adapter))
        self.shots = not adapter   # a fine-tuned reader learned the format; it is trained without the examples

    def generate(self, questions):
        prompts = [self.tok.apply_chat_template(messages(q, shots=self.shots), tokenize=False, add_generation_prompt=True)
                   for q in questions]
        outs = self.llm.generate(prompts, self.params, lora_request=self.lora)
        return [o.outputs[0].text for o in outs]


class ReplayBackend:
    """Answers from saved raw outputs ({prompt: text}); for testing the server and R client without a GPU."""

    def __init__(self, path):
        self.raw = json.load(open(path, encoding="utf-8"))

    def generate(self, questions):
        return [self.raw.get(q, "{}") for q in questions]


def make_backend(a):
    if a.backend.startswith("replay:"):
        return ReplayBackend(a.backend.split(":", 1)[1])
    return VLLMBackend(a.model, adapter=a.adapter, tp=a.tp, eager=a.eager)


def read(backend, questions):
    raw = backend.generate(questions)
    return [(to_spec(parse_json(t)), t) for t in raw]


def serve(backend, a):
    """Keep the model loaded and answer POST /read {"question": ...} -> {"spec": ..., "raw": ...}.
    Requests must carry the token from the connection file (X-Biodes-Token); GET /health needs none."""
    import secrets, socket, threading, time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    token = secrets.token_hex(16)
    lock = threading.Lock()
    host = socket.gethostname()

    class H(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                return self._send(200, {"ok": True, "model": a.model, "adapter": a.adapter})
            self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/read":
                return self._send(404, {"error": "not found"})
            if self.headers.get("X-Biodes-Token") != token:
                return self._send(403, {"error": "bad token"})
            try:
                n = int(self.headers.get("Content-Length", 0))
                q = json.loads(self.rfile.read(n) or b"{}").get("question", "")
            except (ValueError, json.JSONDecodeError):
                return self._send(400, {"error": "send JSON {\"question\": ...}"})
            if not q.strip():
                return self._send(400, {"error": "empty question"})
            with lock:   # one generation at a time on the GPU
                spec, raw = read(backend, [q])[0]
            self._send(200, {"spec": spec, "raw": raw, "model": a.model, "adapter": a.adapter})

        def log_message(self, fmt, *args):
            sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    try:
        srv = ThreadingHTTPServer(("0.0.0.0", a.port), H)
    except OSError:   # port taken on this node: any free port (the connection file says which)
        srv = ThreadingHTTPServer(("0.0.0.0", 0), H)
    conn = {"url": f"http://{host}:{srv.server_address[1]}", "token": token, "model": a.model, "adapter": a.adapter,
            "host": host, "port": srv.server_address[1], "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    if a.conn_file:
        os.makedirs(os.path.dirname(os.path.abspath(a.conn_file)), exist_ok=True)
        fd = os.open(a.conn_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)   # token readable by you only
        with os.fdopen(fd, "w") as f:
            json.dump(conn, f, indent=1)
    print(f"reader ready at {conn['url']}  (connection file: {a.conn_file or 'none'})", file=sys.stderr, flush=True)
    print(f"from your laptop:  ssh -N -L {conn['port']}:{host}:{conn['port']} <you>@login.hpc.ncsu.edu", file=sys.stderr,
          flush=True)
    try:
        srv.serve_forever()
    finally:
        if a.conn_file and os.path.exists(a.conn_file):
            os.remove(a.conn_file)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("READER", "Qwen/Qwen2.5-14B-Instruct"))
    ap.add_argument("--adapter", default=os.environ.get("READER_ADAPTER") or None, help="LoRA adapter folder (llm/train_lora.py)")
    ap.add_argument("--backend", default="vllm", help="vllm, or replay:<raw.json> for tests")
    ap.add_argument("--examples", nargs="*", default=[], help="jsonl files with a 'prompt' field")
    ap.add_argument("--text", default=None)
    ap.add_argument("--out", default=None, help="predictions json (one file) or folder (several example files)")
    ap.add_argument("--raw", action="store_true", help="also save raw model outputs")
    ap.add_argument("--tp", type=int, default=1, help="tensor parallel GPUs")
    ap.add_argument("--eager", action="store_true", help="no CUDA graphs / torch.compile (slower start-up problems)")
    ap.add_argument("--serve", action="store_true", help="keep the model loaded and answer HTTP requests")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--conn-file", default=os.environ.get("BIODES_READER_CONN"), help="where to write url + token")
    a = ap.parse_args()
    backend = make_backend(a)
    if a.serve:
        return serve(backend, a)
    sets = {}
    for f in a.examples:
        with open(f, encoding="utf-8") as fh:
            sets[f] = [json.loads(l)["prompt"] for l in fh if l.strip()]
    if a.text:
        sets["text"] = [a.text]
    allq = list(dict.fromkeys(q for qs in sets.values() for q in qs))
    res = dict(zip(allq, read(backend, allq)))
    specs = {q: r[0] for q, r in res.items()}
    raw = {q: r[1] for q, r in res.items()}
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
