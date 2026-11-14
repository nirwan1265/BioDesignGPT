"""System convention for labels: the setting, when the question states one; otherwise the assay family.

"RNA-seq of poplar leaves in the greenhouse" is a greenhouse study with an RNA-seq assay (system "greenhouse",
assays ["rnaseq"]); "RNA-seq of poplar leaves" stays "bulk_rnaseq". Study types (functional_validation,
multi_omics, breeding_genetics, multi_environment) are left alone. The patterns mirror .sf_settings_stated in
R/local_agent.R, so labels and the rule extractor follow one convention.

    python3 training/setting.py FILE.jsonl ...     rewrite eval files in place (expected_spec.system), print changes
"""
import json, re, sys

ASSAY_SYSTEMS = {"bulk_rnaseq", "single_cell", "atac_seq", "ribo_seq", "metabolomics_lipidomics"}
# order matters: cell lines first ("mouse ES cells" is a culture), then animals, then plant settings
STATED = [
    ("cell_culture", r"cell lines?|immortali[sz]ed|organoids?|\b(?:[a-z]+\d[\w.-]*|\d+[a-z][\w.-]*) (?:cells|macrophages)\b|\bipscs?\b|yeast(?! (?:concentrations?|extract|paste|food|diets?|media|medium))|\b(?:es|ips|s2|hek293t?|hela|cho) cells\b|\bcells? (?:were |are )?(?:cultured|treated with)|\bhela\b"),
    ("mouse", r"\bmice\b|\bmouse\b|\brats?\b"),
    ("drosophila", r"\bflies\b|\bfly\b|drosophila"),
    ("livestock", r"\bpigs?\b|piglets?|\bsows?\b|broilers?|\bhens?\b|\bcocks?\b|\bchickens\b|\bcattle\b|\bcows?\b|\bcalves\b"
                  r"|\bsteers?\b|\bheifers?\b|\bsheep\b|\blambs?\b|\bgoats?\b"),
    ("growth_chamber", r"growth[- ]chambers?|growth rooms?|climate chambers?|phytotron|controlled[- ]environment chambers?"),
    ("greenhouse", r"greenhouses?|glasshouses?|net ?house|screen ?house|polytunnel"),
    ("field", r"\bfield[- ]grown\b|\bin (?:a |the )?(?:paddy )?field\b|\bfield (?:trials?|plots?|sites?|conditions|experiment)\b"
              r"|\bpaddy\b|\borchards?\b"),
]


def stated_setting(text):
    t = text.lower()
    for name, pat in STATED:
        if re.search(pat, t):
            return name
    return None


def apply(spec, text):
    """Return the setting that replaces an assay-family system, or None if the label stays."""
    if spec.get("system") in ASSAY_SYSTEMS:
        s = stated_setting(text)
        if s:
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
