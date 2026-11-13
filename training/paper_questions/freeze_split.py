#!/usr/bin/env python3
"""Freeze the dev/test split of the paper questions, by paper, before any model is scored on them.

    dev.jsonl           ~30% of questions from trained species: for tuning rules, prompts and the reader
    test.jsonl          ~70% of questions from trained species: scored once, at the end
    test_heldout.jsonl  every question from the held-out species (setaria, poplar, zebrafish, xenopus): scored separately

Each paper gives at most one question, so splitting by question is splitting by paper. Within trained species
the split is stratified by species x technique: each stratum's questions are shuffled (seed 2026) and dealt
by systematic allocation, so every stratum gets within one question of 30% in dev and the total is 30%
(strata are visited in a random order so the rounding does not favour any species). A MANIFEST.json records counts and a sha256 of each file; the script
refuses to overwrite an existing split unless --force is given, so the split cannot drift once frozen.

    python3 freeze_split.py            # write splits/ (fails if it exists)
    python3 freeze_split.py --check    # verify the frozen files still match the manifest
    python3 freeze_split.py --refresh  # labels changed (e.g. schema update): rewrite the files from batches/
                                       # keeping exactly the same papers in each split

The manifest keeps two hashes per file: members_sha256 (the sorted question ids, i.e. which papers are in the
split; this must never change) and sha256 (the file contents, which change when labels are migrated).
"""
import argparse, collections, glob, hashlib, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "splits")
DEV_SHARE = 0.30
SEED = 2026


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def load():
    recs = []
    for f in sorted(glob.glob(os.path.join(HERE, "batches", "batch_*.jsonl"))):
        recs += [json.loads(l) for l in open(f, encoding="utf-8")]
    return [r for r in recs if not r.get("skip")]


def split(qs):
    rnd = random.Random(SEED)
    held = [q for q in qs if q.get("held_out_species")]
    strata = collections.defaultdict(list)
    for q in qs:
        if not q.get("held_out_species"):
            strata[(q["species"], q.get("technique") or "?")].append(q)
    keys = sorted(strata)
    rnd.shuffle(keys)                    # stratum order decides who gets the rounding, so randomise it
    dev, test, expected = [], [], 0.0
    for key in keys:                     # systematic allocation: each stratum within 1 of 30%, total on 30%
        items = sorted(strata[key], key=lambda q: q["id"])
        rnd.shuffle(items)
        expected += DEV_SHARE * len(items)
        k = min(len(items), max(0, round(expected) - len(dev)))
        dev += items[:k]
        test += items[k:]
    return dev, test, held


def members(rows):
    return hashlib.sha256("\n".join(sorted(r["id"] for r in rows)).encode()).hexdigest()


def write(name, rows):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        for r in sorted(rows, key=lambda r: r["id"]):
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    a = ap.parse_args()
    man = os.path.join(OUT, "MANIFEST.json")
    if a.check:
        m = json.load(open(man))
        bad = [n for n, v in m["files"].items() if sha(os.path.join(OUT, n)) != v["sha256"]]
        moved = [n for n, v in m["files"].items() if "members_sha256" in v and
                 members([json.loads(l) for l in open(os.path.join(OUT, n))]) != v["members_sha256"]]
        print("split intact" if not bad and not moved else f"CHANGED since freezing: contents {bad}, membership {moved}")
        sys.exit(1 if bad or moved else 0)
    if a.refresh:
        m = json.load(open(man))
        by_id = {q["id"]: q for q in load()}
        for n, v in m["files"].items():
            ids = [json.loads(l)["id"] for l in open(os.path.join(OUT, n))]
            if "members_sha256" in v and members([{"id": i} for i in ids]) != v["members_sha256"]:
                sys.exit(f"{n}: membership no longer matches the manifest; refusing to refresh")
            missing = [i for i in ids if i not in by_id]
            if missing:
                sys.exit(f"{n}: {len(missing)} frozen questions are no longer labelled (e.g. {missing[:3]})")
            p = write(n, [by_id[i] for i in ids])
            v.update({"sha256": sha(p), "members_sha256": members([{"id": i} for i in ids])})
        m["refreshed"] = m.get("refreshed", 0) + 1
        json.dump(m, open(man, "w"), indent=1)
        print("refreshed contents; membership unchanged:", {n: v["n"] for n, v in m["files"].items()})
        return
    if os.path.exists(man) and not a.force:
        sys.exit(f"{man} exists: the split is frozen (use --check to verify, --force only if you mean to re-freeze)")
    os.makedirs(OUT, exist_ok=True)
    dev, test, held = split(load())
    files = {}
    for name, rows in (("dev.jsonl", dev), ("test.jsonl", test), ("test_heldout.jsonl", held)):
        p = write(name, rows)
        files[name] = {"n": len(rows), "sha256": sha(p), "members_sha256": members(rows),
                       "species": dict(collections.Counter(r["species"] for r in rows).most_common()),
                       "styles": dict(collections.Counter(r["style"] for r in rows).most_common())}
    json.dump({"seed": SEED, "dev_share": DEV_SHARE, "unit": "paper (one question per paper)",
               "stratified_by": "species x technique", "files": files}, open(man, "w"), indent=1)
    for n, v in files.items():
        print(f"{n:20s} {v['n']:5d} questions, {len(v['species'])} species")


if __name__ == "__main__":
    main()
