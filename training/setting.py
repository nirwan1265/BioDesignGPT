"""System convention for labels (rules from inst/agent/rules.tsv + the system registry), schema 4.

system is the setting the experimental units live in (field, greenhouse, growth chamber, mouse facility, livestock,
flies, cell culture); study_type is the kind of study (breeding, multi-environment, multi-omics, validation); the
assays are in assays. "RNA-seq of poplar leaves in the greenhouse": system "greenhouse", assays ["rnaseq"].
"RNA-seq of poplar leaves": no system (not stated, so it is asked). "RILs in field plots": study_type
"breeding_genetics", system "field". Older labels that used a study type or an assay family as the system are
converted here; a setting a person labelled is kept. R's rule extractor reads the same rule files.

    python3 training/setting.py FILE.jsonl ...     rewrite eval files in place (expected_spec.system), print changes
"""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules  # noqa: E402

# all from the rule files (training/rules.py): setting cues from inst/agent/rules.tsv, system kinds from the registry
ASSAY_SYSTEMS = rules.systems_where(kind="assay")
STATED = rules.patterns("setting")
PLANT_SITES = rules.systems_where(plant_site=True)
STUDY_BELOW_SITE = rules.systems_where(kind="study", keeps_type_over_setting=False)


def stated_setting(text):
    t = text.lower()
    for name, pat in STATED:
        if pat.search(t):
            return name
    return None


# a phenotyping location named outright also outranks breeding / multi-omics study types (registry:
# keeps_type_over_setting false); validation and multi-environment studies span settings and keep their type


STUDIES = rules.systems_where(kind="study")
SYSTEM_ASSAY = {i: sy.get("assay") for i, sy in rules.systems().items() if sy.get("kind") == "assay"}


def apply(spec, text):
    """Bring one gold spec to schema 4 in place. Returns the new system ("" when none) if it changed, else None."""
    old = spec.get("system")
    if old not in STUDIES and old not in ASSAY_SYSTEMS:
        return None
    if old in STUDIES and not spec.get("study_type"):
        spec["study_type"] = old
    if old in ASSAY_SYSTEMS and not spec.get("assays") and SYSTEM_ASSAY.get(old):
        spec["assays"] = [SYSTEM_ASSAY[old]]   # the assay the old system stood for
    s = stated_setting(text)
    if s:
        spec["system"] = s
    else:
        spec.pop("system", None)
    return spec.get("system", "")


if __name__ == "__main__":
    # rewrite label files in place (expected_spec or spec), one JSON object per line
    for path in sys.argv[1:]:
        lines = open(path, encoding="utf-8", newline="").read().split("\n")
        n = 0
        for i, line in enumerate(lines):
            if not line.strip():
                continue
            r = json.loads(line)
            key = "expected_spec" if isinstance(r.get("expected_spec"), dict) else "spec" if isinstance(r.get("spec"), dict) else None
            if key is None:
                continue
            old = r[key].get("system")
            if apply(r[key], r.get("prompt") or r.get("text") or "") is not None:
                lines[i] = json.dumps(r, ensure_ascii=False)
                n += 1
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(lines))
        print(f"{path}: {n} relabelled")
