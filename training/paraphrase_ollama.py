#!/usr/bin/env python3
"""Paraphrase generated prompts with a free local LLM (Ollama) while keeping labels exact.

Each labelled span is wrapped in [[double brackets]]. The LLM must keep every bracketed
span verbatim; a paraphrase is kept only if
  * every span appears exactly once and unchanged,
  * no new numbers appear outside the spans,
  * it is not a copy of the input.
So the tags stay correct by construction.

    ollama pull llama3.1            # or qwen2.5:7b, mistral, gemma2 ...
    python training/paraphrase_ollama.py --inp training/data/train.jsonl --out training/data/para.jsonl --n 3000 --variants 2 --workers 4

Re-running with the same --out resumes where it stopped.
"""
import argparse, concurrent.futures as cf, json, os, random, re, sys, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "inst", "python"))
from decode import spans  # noqa: E402
from generate import tokenize  # noqa: E402

STYLES = [
    "as a busy PhD student typing quickly, casual and short",
    "as a careful postdoc writing a detailed email to a statistician",
    "as a non-native English speaker, simple words, slightly unusual word order",
    "as a lab manager listing the facts in a terse, note-like way",
    "as a PI asking for advice in a friendly tone",
    "as someone describing their experiment over chat, with a little context first",
]
PROMPT = """Rewrite the scientist's request below {style}.
Rules:
- Keep EVERY [[bracketed]] phrase exactly as written, brackets included, each exactly once.
- Do not add any new numbers, organisms, treatments or facts.
- You may reorder, add filler words, or turn it into a question.
- Reply with the rewritten request only, no preamble.

Request: {src}
Rewritten:"""


def bracketed(d):
    out, i = [], 0
    sp = spans(d["tokens"], d["tags"])
    for lab, text, start in sp:
        out += d["tokens"][i:start] + [f"[[{text}]]"]
        i = start + len(tokenize(text))
    return " ".join(out + d["tokens"][i:]), sp


def relabel(text, sp):
    want = {}
    for lab, t, _ in sp:
        want.setdefault(t, lab)
    parts = re.split(r"(\[\[.*?\]\])", text)
    seen = [p[2:-2] for p in parts if p.startswith("[[")]
    if sorted(seen) != sorted(t for _, t, _ in sp):
        return None
    outside = " ".join(p for p in parts if not p.startswith("[["))
    if re.search(r"\d", outside):  # no new numbers outside labelled spans
        return None
    toks, tags = [], []
    for part in parts:
        tt = tokenize(part[2:-2] if part.startswith("[[") else part)
        if part.startswith("[["):
            lab = want[part[2:-2]]
            tags += ["B-" + lab] + ["I-" + lab] * (len(tt) - 1)
        else:
            tags += ["O"] * len(tt)
        toks += tt
    return toks, tags


def ask(model, endpoint, prompt, temperature, retries=3):
    body = json.dumps({"model": model, "prompt": prompt, "stream": False,
                       "options": {"temperature": temperature, "num_predict": 200}}).encode()
    for k in range(retries):
        try:
            req = urllib.request.Request(endpoint, data=body, headers={"Content-Type": "application/json"})
            return json.loads(urllib.request.urlopen(req, timeout=180).read())["response"].strip()
        except Exception:
            if k == retries - 1:
                raise
            time.sleep(2 * (k + 1))


def work(job, a):
    idx, v, d = job
    src, sp = bracketed(d)
    style = STYLES[(idx + v) % len(STYLES)]
    para = ask(a.model, a.endpoint, PROMPT.format(style=style, src=src), a.temperature)
    para = para.strip().strip('"').splitlines()[0] if para else ""
    r = relabel(para, sp)
    if not r or re.sub(r"\[\[|\]\]", "", para).strip().lower() == d["text"].strip().lower():
        return idx, v, None
    toks, tags = r
    return idx, v, {**d, "text": re.sub(r"\[\[|\]\]", "", para), "tokens": toks, "tags": tags,
                    "family": d["family"] + "+para", "para_of": idx, "para_variant": v}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inp", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=3000, help="source sentences to paraphrase")
    ap.add_argument("--variants", type=int, default=2, help="paraphrases per source sentence")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--temperature", type=float, default=0.9)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--model", default=os.environ.get("STUDYFORGE_OLLAMA_MODEL", "llama3.1"))
    ap.add_argument("--endpoint", default="http://localhost:11434/api/generate")
    a = ap.parse_args()

    src = [json.loads(l) for l in open(a.inp)]
    random.Random(a.seed).shuffle(src)
    src = src[:a.n]
    done = set()
    if os.path.exists(a.out):
        for l in open(a.out):
            r = json.loads(l)
            done.add((r["para_of"], r["para_variant"]))
    jobs = [(i, v, d) for i, d in enumerate(src) for v in range(a.variants) if (i, v) not in done]
    try:
        ask(a.model, a.endpoint, "Say OK.", 0.0, retries=1)
    except Exception as e:
        sys.exit(f"Ollama not reachable at {a.endpoint} ({e}). Start it with `ollama serve` and `ollama pull {a.model}`.")

    kept = tried = 0
    t0 = time.time()
    with open(a.out, "a") as f, cf.ThreadPoolExecutor(a.workers) as ex:
        for idx, v, row in ex.map(lambda j: work(j, a), jobs):
            tried += 1
            if row:
                f.write(json.dumps(row) + "\n"); f.flush(); kept += 1
            if tried % 50 == 0:
                print(f"{tried}/{len(jobs)} tried, {kept} kept ({kept / tried:.0%}), {time.time() - t0:.0f}s", flush=True)
    print(f"done: kept {kept}/{tried} new paraphrases -> {a.out}")


if __name__ == "__main__":
    main()
