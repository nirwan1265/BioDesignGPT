#!/usr/bin/env python3
"""Build the paper index: one shard per organism, searchable by technique.

Reads the open-access methods sections harvested by data-raw/evidence/enrich_evidence.R
(evidence/<species>/methods_text/PMC*.txt), labels each paper with its organism, technique(s),
DOI and year from the evidence tables, splits it into passages and embeds them.

    python retrieval/build_index.py --evidence evidence --out index                 # every species
    python retrieval/build_index.py --evidence evidence --out index --species sorghum,maize
    python retrieval/build_index.py ... --model BAAI/bge-base-en-v1.5 --device cuda --batch 256

Shards: index/<species>/{emb.npy, meta.jsonl, info.json}. A finished shard is skipped unless --force,
so new organisms are added by running again. No training: the embedding model is used as is.
Nothing here leaves your machine; full texts stay local (only DOIs and short quotes are shown to users).
"""
import argparse, csv, json, os, re, sys, time, zlib

csv.field_size_limit(10 ** 9)

# text after these headings is back matter, not methods (same rule as enrich_evidence.R)
BACKMATTER = re.compile(
    r"\b(Acknowledg(e)?ments?|Author [Cc]ontributions|Competing [Ii]nterests|Conflicts? of [Ii]nterest|"
    r"Declaration of ([Cc]ompeting )?[Ii]nterests?|Footnotes|Associated Data|Reporting [Ss]ummary|"
    r"Supplementary [Ii]nformation Supplementary|Supplementary [Mm]aterials? Supplementary)\b|\bReferences 1\. ")
SENT = re.compile(r"(?<=[.!?])\s+(?=[A-Z(])")


def cut_backmatter(t):
    hits = [m.start() for m in BACKMATTER.finditer(t) if m.start() > 300]
    return t[:min(hits)] if hits else t


def passages(text, target=900, max_len=1400):
    """Sentence-aligned passages of ~target characters, one sentence of overlap."""
    sents = [s.strip() for s in SENT.split(text) if len(s.strip()) > 20]
    out, cur = [], []
    for s in sents:
        if len(s) > max_len:
            s = s[:max_len]
        cur.append(s)
        if sum(len(x) + 1 for x in cur) >= target:
            out.append(" ".join(cur))
            cur = cur[-1:]
    if cur and (not out or " ".join(cur) != out[-1].split(" ", 1)[-1]):
        tail = " ".join(cur)
        if len(tail) > 200 or not out:
            out.append(tail)
    return out


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))


def paper_meta(spdir):
    """pmcid -> {doi, year, techniques, study_groups}"""
    tech = {}
    for r in read_tsv(os.path.join(spdir, "by_study.tsv")):
        tech.setdefault(r.get("study_group", ""), set()).add(r.get("technique", ""))
    meta = {}
    for r in read_tsv(os.path.join(spdir, "study_methods.tsv")):
        p = r.get("pmcid", "")
        if not p:
            continue
        m = meta.setdefault(p, {"doi": r.get("doi", ""), "year": r.get("year", ""), "techniques": set(), "study_groups": set()})
        m["techniques"] |= tech.get(r.get("study_group", ""), set())
        m["study_groups"].add(r.get("study_group", ""))
        if not m["doi"]:
            m["doi"] = r.get("doi", "")
    return meta


class HashEmbedder:
    """Dependency-free stand-in for tests (bag of hashed words); not for real use."""
    dim = 512

    def encode(self, texts, query=False):
        import numpy as np
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, t in enumerate(texts):
            for w in re.findall(r"[a-z0-9]+", t.lower()):
                out[i, zlib.crc32(w.encode()) % self.dim] += 1.0
        out /= np.maximum(np.linalg.norm(out, axis=1, keepdims=True), 1e-9)
        return out


class STEmbedder:
    """sentence-transformers model (e.g. BAAI/bge-base-en-v1.5), normalized embeddings."""
    QUERY_PREFIX = {"bge": "Represent this sentence for searching relevant passages: ", "e5": "query: "}

    def __init__(self, name, device, batch):
        from sentence_transformers import SentenceTransformer
        self.name, self.batch = name, batch
        self.m = SentenceTransformer(name, device=device)
        self.dim = self.m.get_sentence_embedding_dimension()
        self.prefix = next((v for k, v in self.QUERY_PREFIX.items() if k in name.lower()), "")
        self.doc_prefix = "passage: " if "e5" in name.lower() else ""

    def encode(self, texts, query=False):
        texts = [(self.prefix if query else self.doc_prefix) + t for t in texts]
        return self.m.encode(texts, batch_size=self.batch, normalize_embeddings=True, show_progress_bar=False,
                             convert_to_numpy=True).astype("float32")


def make_embedder(model, device="cuda", batch=128):
    return HashEmbedder() if model == "hash" else STEmbedder(model, device, batch)


def build_species(spdir, outdir, emb, model, min_chars=200):
    import numpy as np
    sp = os.path.basename(spdir.rstrip("/"))
    tdir = os.path.join(spdir, "methods_text")
    if not os.path.isdir(tdir):
        return None
    meta = paper_meta(spdir)
    rows, texts = [], []
    for fn in sorted(os.listdir(tdir)):
        if not fn.endswith(".txt") or fn.startswith("_"):
            continue
        pmcid = fn[:-4]
        with open(os.path.join(tdir, fn), encoding="utf-8", errors="replace") as f:
            t = cut_backmatter(" ".join(f.read().split()))
        if len(t) < min_chars:
            continue
        m = meta.get(pmcid, {"doi": "", "year": "", "techniques": set(), "study_groups": set()})
        for k, p in enumerate(passages(t)):
            rows.append({"species": sp, "pmcid": pmcid, "doi": m["doi"], "year": m["year"],
                         "techniques": sorted(x for x in m["techniques"] if x),
                         "study_groups": sorted(x for x in m["study_groups"] if x), "chunk": k, "text": p})
            texts.append(p)
    if not rows:
        return None
    vecs = emb.encode(texts)
    os.makedirs(outdir, exist_ok=True)
    np.save(os.path.join(outdir, "emb.npy"), vecs.astype("float16"))
    with open(os.path.join(outdir, "meta.jsonl"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    info = {"species": sp, "model": model, "dim": int(vecs.shape[1]), "passages": len(rows),
            "papers": len({r["pmcid"] for r in rows}), "built": time.strftime("%Y-%m-%d %H:%M")}
    json.dump(info, open(os.path.join(outdir, "info.json"), "w"), indent=1)
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", required=True)
    ap.add_argument("--out", default="index")
    ap.add_argument("--species", default="", help="comma list; default every species with methods_text/")
    ap.add_argument("--model", default="BAAI/bge-base-en-v1.5", help="sentence-transformers name/path, or 'hash' for tests")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    want = [s.strip() for s in a.species.split(",") if s.strip()]
    dirs = sorted(d for d in os.listdir(a.evidence) if os.path.isdir(os.path.join(a.evidence, d, "methods_text")))
    if want:
        dirs = [d for d in dirs if d in want]
    emb = make_embedder(a.model, a.device, a.batch)
    total = 0
    for sp in dirs:
        out = os.path.join(a.out, sp)
        if os.path.exists(os.path.join(out, "info.json")) and not a.force:
            print(f"== {sp}: shard exists (--force to rebuild)")
            continue
        t0 = time.time()
        info = build_species(os.path.join(a.evidence, sp), out, emb, a.model)
        if info:
            total += info["passages"]
            print(f"== {sp}: {info['papers']} papers -> {info['passages']} passages ({time.time() - t0:.0f}s)", flush=True)
        else:
            print(f"== {sp}: no methods text")
    print(f"done: {total} passages added")


if __name__ == "__main__":
    main()
