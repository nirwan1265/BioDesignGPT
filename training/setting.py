"""System convention for labels (rules from inst/agent/rules.tsv + the system registry): the setting, when the question states one; otherwise the assay family.

"RNA-seq of poplar leaves in the greenhouse" is a greenhouse study with an RNA-seq assay (system "greenhouse",
assays ["rnaseq"]); "RNA-seq of poplar leaves" stays "bulk_rnaseq". Validation and multi-environment
studies keep their type; breeding and multi-omics studies give way to a named field, greenhouse or growth chamber. R's
rule extractor reads the same rule files, so labels and extractor follow one convention.

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


def apply(spec, text):
    """Return the setting that replaces the label's system, or None if the label stays."""
    s = stated_setting(text)
    if s and (spec.get("system") in ASSAY_SYSTEMS or (spec.get("system") in STUDY_BELOW_SITE and s in PLANT_SITES)):
        spec["system"] = s
        return s
    return None


if __name__ == "__main__":
    # edit the one "system" value in place so each file keeps its own JSON formatting
    for path in sys.argv[1:]:
        lines = open(path, encoding="utf-8", newline="").read().split("\n")
        n = 0
        for i, line in enumerate(lines):
            if not line.strip():
                continue
            r = json.loads(line)
            old = r["expected_spec"].get("system")
            new = apply(r["expected_spec"], r["prompt"])
            if new:
                lines[i] = re.sub(r'("system"\s*:\s*")' + re.escape(old) + '"', lambda m: m.group(1) + new + '"', line, count=1)
                assert json.loads(lines[i])["expected_spec"]["system"] == new
                n += 1
                print(f"  {old} -> {new}: {r['prompt'][:100]}")
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write("\n".join(lines))
        print(f"{path}: {n} relabelled")
