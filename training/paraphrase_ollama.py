#!/usr/bin/env python3
"""Paraphrase generated prompts with a free local LLM (Ollama) while keeping labels exact.

Each labelled span is wrapped in [[double brackets]]; the model must keep every bracketed
span verbatim. Paraphrases that drop or alter a span are discarded, so labels stay correct.

    ollama pull llama3.1
    python training/paraphrase_ollama.py --inp training/data/train.jsonl --out training/data/train_para.jsonl --n 2000
"""
import argparse, json, os, re, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "inst", "python"))
from decode import spans  # noqa: E402
from generate import tokenize  # noqa: E402

PROMPT = ("Rewrite this request from a scientist in different, natural wording (one or two sentences). "
          "Keep every [[bracketed]] phrase exactly as written, including the brackets. Do not add numbers. "
          "Reply with the rewritten text only.\n\n")


def bracketed(d):
    out, i = [], 0
    for lab, text, start in spans(d["tokens"], d["tags"]):
        out += d["tokens"][i:start] + [f"[[{text}]]"]
        i = start + len(tokenize(text))
    return " ".join(out + d["tokens"][i:]), spans(d["tokens"], d["tags"])


def relabel(text, sp):
    """Tokenize the paraphrase; tag each [[span]] with its original label."""
    want = {t: lab for lab, t, _ in sp}
    toks, tags = [], []
    for part in re.split(r"(\[\[.*?\]\])", text):
        if part.startswith("[["):
            inner = part[2:-2]
            if inner not in want:
                return None
            tt = tokenize(inner)
            toks += tt
            tags += ["B-" + want[inner]] + ["I-" + want[inner]] * (len(tt) - 1)
        else:
            tt = tokenize(part)
            toks += tt
            tags += ["O"] * len(tt)
    found = {t for _, t, _ in sp if f"[[{t}]]" in text}
    return (toks, tags) if len(found) == len(want) else None


def ask(model, endpoint, prompt):
    req = urllib.request.Request(endpoint, data=json.dumps({"model": model, "prompt": prompt, "stream": False}).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())["response"].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inp", required=True); ap.add_argument("--out", required=True); ap.add_argument("--n", type=int, default=1000)
    ap.add_argument("--model", default="llama3.1"); ap.add_argument("--endpoint", default="http://localhost:11434/api/generate")
    a = ap.parse_args()
    kept = 0
    with open(a.out, "w") as f:
        for i, line in enumerate(open(a.inp)):
            if i >= a.n:
                break
            d = json.loads(line)
            src, sp = bracketed(d)
            try:
                para = ask(a.model, a.endpoint, PROMPT + src)
            except Exception as e:
                sys.exit(f"Ollama not reachable at {a.endpoint}: {e}")
            r = relabel(para, sp)
            if r:
                toks, tags = r
                f.write(json.dumps({**d, "text": re.sub(r"\[\[|\]\]", "", para), "tokens": toks, "tags": tags,
                                    "family": d["family"] + "+para"}) + "\n")
                kept += 1
    print(f"kept {kept}/{min(a.n, i + 1)} paraphrases")


if __name__ == "__main__":
    main()
