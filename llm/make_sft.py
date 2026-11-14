#!/usr/bin/env python3
"""Training data for fine-tuning the reader (LoRA), in two steps.

1. prompts: a balanced sample of labelled prompts
     train.jsonl                        synthetic, ~60 study types (training/generate.py)
     grounded_train.jsonl               prompts built from real ENA/BioSample studies (training/grounded.py)
     training/data/para.jsonl           LLM paraphrases (the most natural wording we have)
     paper_questions/splits/train.jsonl questions written from real papers (hand-labelled training pool; all used)
   (found in $SFT_DATA or training/data). Excluded: every prompt in a test/dev set, and the held-out species (setaria, poplar, zebrafish, xenopus), so
   grounded_eval stays a test of unseen organisms. Paper-question dev/test/test_heldout prompts are excluded too.
   Every gold spec follows one system convention (training/setting.py): the stated setting (greenhouse, mice,
   flies, cell lines ...) is the system and the assay goes in assays, so older generated labels are converted.

2. build: the training targets. Our labels cover organism, system, assays, factors, counts, units, outcome,
   population. They don't cover method, tissue, levels, outcome text or the questions to ask. For those the
   target takes the base model's own answer (self-distillation from `reader.py --examples prompts.jsonl --raw`),
   so fine-tuning teaches our schema without unlearning what the base model already reads well.
   Design judgments are kept out of the targets: experimental_unit only when the unit word is in the prompt.

    python llm/make_sft.py prompts --out WORK [--n 4500]
    python llm/reader.py --model ... --examples WORK/prompts.jsonl --out WORK --raw     # distil (GPU)
    python llm/make_sft.py build --work WORK
"""
import argparse, collections, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reader  # noqa: E402
sys.path.insert(0, os.path.join(HERE, "..", "training"))
import setting  # noqa: E402
import rules  # noqa: E402

DATA = os.path.join(HERE, "..", "training", "data")
EVAL_FILES = ["fresh_test.jsonl", "fresh_test_v2.jsonl", "fresh_test_v3.jsonl", "fresh_test_v4.jsonl", "grounded_eval.jsonl",
              "user_prompts_dev.jsonl", os.path.join("..", "..", "inst", "examples", "study_examples.jsonl")]
PQ = os.path.join(HERE, "..", "training", "paper_questions", "splits")
PQ_EVAL = ["dev.jsonl", "test.jsonl", "test_heldout.jsonl"]
# vocabulary and system kinds come from the rule files (training/rules.py), never from lists in this script
SYSTEM_ASSAY = {i: sy["assay"] for i, sy in rules.systems().items() if sy.get("kind") == "assay"}   # old system -> its assay
HOLDOUT_ORGS = set(rules.mapping("held_out_species").values())
SYN = rules.mapping("factor_synonym")


def unit_stated(unit, text):
    """The unit word (or any alias of that unit in inst/agent/rules.tsv) is in the prompt."""
    words = set(rules.aliases("unit").get(unit, [])) | {unit.replace("_", " ")}
    return any(re.search(r"(?<![a-z0-9])" + re.escape(w) + r"(?:e?s)?(?![a-z0-9])", text) for w in words)


# generated training files (git-ignored) are looked for in SFT_DATA first (the slurm job regenerates them
# into WORK/gen, so the committed eval sets in training/data are never overwritten), then in training/data
DATA_DIRS = [d for d in os.environ.get("SFT_DATA", "").split(":") if d] + [DATA]


def load(name):
    for d in DATA_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                return [json.loads(l) for l in f if l.strip()]
    raise FileNotFoundError(f"{name} not in {DATA_DIRS}; generate it (see llm/finetune.slurm)")


def eval_prompts():
    seen = set()
    for name in EVAL_FILES:
        p = os.path.join(DATA, name)
        if os.path.exists(p):
            seen |= {norm(json.loads(l)["prompt"]) for l in open(p, encoding="utf-8") if l.strip()}
    for name in PQ_EVAL:
        p = os.path.join(PQ, name)
        if os.path.exists(p):
            seen |= {norm(json.loads(l)["prompt"]) for l in open(p, encoding="utf-8") if l.strip()}
    return seen


def paper_questions():
    """The hand-labelled paper-question training pool, in the same row shape as the generated files."""
    p = os.path.join(PQ, "train.jsonl")
    if not os.path.exists(p):
        return []
    rows = [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]
    return [{"text": r["prompt"], "spec": r["expected_spec"], "family": f"paper:{r.get('technique')}"}
            for r in rows if not r.get("held_out_species")]


def convention(spec, text):
    """Gold spec under the current system convention (setting.apply), keeping the assay the old system implied."""
    spec = json.loads(json.dumps(spec))
    old = spec.get("system")
    if setting.apply(spec, text) and old in SYSTEM_ASSAY and not spec.get("assays"):
        spec["assays"] = [SYSTEM_ASSAY[old]]
    return spec


def norm(t):
    return " ".join(t.lower().split())


def held_out(spec):
    orgs = {spec.get("organism")} | set(spec.get("organisms") or [])
    return bool(orgs & HOLDOUT_ORGS)


def sample_prompts(n, seed):
    rnd = random.Random(seed)
    banned = eval_prompts()
    # paraphrases first: they are also inside train_r5, and they are the most natural wording we have
    pools = {"paper": paper_questions(),
             "paraphrase": load("para.jsonl"),
             "synthetic": [r for r in load("train.jsonl") if not str(r.get("family", "")).startswith("grounded")],
             "grounded": load("grounded_train.jsonl")}
    # shares of the sample: paraphrases all (most natural), then synthetic study types, then real-study prompts
    want = {"paper": None, "paraphrase": None, "synthetic": int(n * 0.55), "grounded": int(n * 0.30)}
    out, used = [], set()
    for src, rows in pools.items():
        rows = [r for r in rows if norm(r["text"]) not in banned and not held_out(r["spec"])]
        by_fam = collections.defaultdict(list)
        for r in rows:
            by_fam[(r.get("family") or r["spec"].get("system"), r["spec"].get("organism"))].append(r)
        for v in by_fam.values():
            rnd.shuffle(v)
        # round-robin over (study type, organism) so no family or species dominates
        k, picked, keys = want[src] or len(rows), [], list(by_fam)
        rnd.shuffle(keys)
        while len(picked) < k and any(by_fam.values()):
            for key in keys:
                if by_fam[key] and len(picked) < k:
                    picked.append(by_fam[key].pop())
        for r in picked:
            t = norm(r["text"])
            if t in used:
                continue
            used.add(t)
            out.append({"id": f"sft_{len(out):05d}", "prompt": " ".join(r["text"].split()), "gold": convention(r["spec"], r["text"]),
                        "family": r.get("family"), "source": src})
    rnd.shuffle(out)
    return out


def canon(name):
    n = str(name).strip().lower().replace(" ", "_")
    return SYN.get(n, n)


def target(prompt, gold, distilled):
    """Reader JSON: our labels where we have them, the base model's reading elsewhere."""
    d = distilled if isinstance(distilled, dict) else {}
    text = prompt.lower()
    dfac = {canon(f.get("name")): f for f in (d.get("factors") or []) if isinstance(f, dict) and f.get("name")}
    factors = []
    for f in gold.get("factors") or []:
        g = {"name": f["name"], "n_levels": f.get("n_levels"), "levels": None, "applied_to": f.get("applied_to")}
        lv = (dfac.get(canon(f["name"])) or {}).get("levels")
        if isinstance(lv, list) and f.get("n_levels") and len(lv) == f["n_levels"]:
            g["levels"] = [str(x) for x in lv]
        factors.append(g)
    unit = gold.get("experimental_unit")
    if unit and not unit_stated(unit, text):
        unit = None   # inferred, not stated: a design judgment the reader must leave to the engine
    des = gold.get("design") or {}
    pop = gold.get("population") or {}
    po = gold.get("primary_outcome")
    goal = d.get("goal") if d.get("goal") in ("design", "analysis") else "design"
    return {
        "goal": goal, "system": gold.get("system"), "organism": gold.get("organism"),
        "organisms": gold.get("organisms"), "method": d.get("method") if isinstance(d.get("method"), str) else None,
        "assays": gold.get("assays") or [], "tissue": d.get("tissue") if isinstance(d.get("tissue"), str) else None,
        "factors": factors,
        "design": {"reps": des.get("reps"), "locations": des.get("locations"), "seasons": des.get("seasons")},
        "experimental_unit": unit, "measurement_unit": gold.get("measurement_unit"),
        "subsamples_per_unit": gold.get("subsamples_per_unit"),
        "primary_outcome": {"name": po["name"], "type": po.get("type", "continuous")} if isinstance(po, dict) and po.get("name") else None,
        "outcome_text": d.get("outcome_text") if isinstance(d.get("outcome_text"), str) else None,
        "population": {k: pop.get(k) for k in ("mating", "generations", "filial_generation", "parents")} if pop else None,
        # environments only when settings are compared (greenhouse screen vs field); one setting is the system
        "environments": gold.get("environments") if len(gold.get("environments") or []) > 1 else None,
        "blocking_factors": gold.get("blocking_factors"),
        "sequencing": d.get("sequencing") if isinstance(d.get("sequencing"), dict) else None,
        "missing_questions": [str(x) for x in (d.get("missing_questions") or [])][:4],
    }


def build(work, val_frac, seed):
    prompts = [json.loads(l) for l in open(os.path.join(work, "prompts.jsonl"), encoding="utf-8")]
    raw_path = os.path.join(work, "preds_llm_prompts_raw.json")
    raw = json.load(open(raw_path, encoding="utf-8")) if os.path.exists(raw_path) else {}
    if not raw:
        print(f"warning: no distilled answers at {raw_path}; method/tissue/levels/questions will be empty", file=sys.stderr)
    rows = []
    for p in prompts:
        t = target(p["prompt"], p["gold"], reader.parse_json(raw.get(p["prompt"], "")) or {})
        msgs = reader.messages(p["prompt"], shots=False) + [{"role": "assistant", "content": json.dumps(t)}]
        rows.append({"id": p["id"], "source": p["source"], "messages": msgs})
    random.Random(seed).shuffle(rows)
    nv = max(50, int(len(rows) * val_frac))
    for name, part in (("val.jsonl", rows[:nv]), ("train.jsonl", rows[nv:])):
        with open(os.path.join(work, name), "w", encoding="utf-8") as f:
            for r in part:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(rows) - nv} train / {nv} val examples to {work}; distilled answers for "
          f"{sum(1 for p in prompts if p['prompt'] in raw)}/{len(prompts)} prompts")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a1 = sub.add_parser("prompts")
    a1.add_argument("--out", required=True)
    a1.add_argument("--n", type=int, default=4500)
    a1.add_argument("--seed", type=int, default=11)
    a2 = sub.add_parser("build")
    a2.add_argument("--work", required=True)
    a2.add_argument("--val-frac", type=float, default=0.04)
    a2.add_argument("--seed", type=int, default=11)
    a = ap.parse_args()
    if a.cmd == "prompts":
        os.makedirs(a.out, exist_ok=True)
        rows = sample_prompts(a.n, a.seed)
        with open(os.path.join(a.out, "prompts.jsonl"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"wrote {len(rows)} prompts: {dict(collections.Counter(r['source'] for r in rows))}")
    else:
        build(a.work, a.val_frac, a.seed)


if __name__ == "__main__":
    main()
