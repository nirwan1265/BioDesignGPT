"""System convention for labels: the setting, when the question states one; otherwise the assay family.

"RNA-seq of poplar leaves in the greenhouse" is a greenhouse study with an RNA-seq assay (system "greenhouse",
assays ["rnaseq"]); "RNA-seq of poplar leaves" stays "bulk_rnaseq". Validation and multi-environment
studies keep their type; breeding and multi-omics studies give way to a named field, greenhouse or growth chamber. The patterns mirror .sf_settings_stated in
R/local_agent.R, so labels and the rule extractor follow one convention.

    python3 training/setting.py FILE.jsonl ...     rewrite eval files in place (expected_spec.system), print changes
"""
import json, re, sys

ASSAY_SYSTEMS = {"bulk_rnaseq", "single_cell", "atac_seq", "ribo_seq", "metabolomics_lipidomics"}
# order matters: cell lines first ("mouse ES cells" is a culture), then animals, then plant settings
STATED = [
    ("cell_culture", r"\bcultures\b|\bprimary (?:[\w-]+ ){0,3}cells\b|\b(?:cells|macrophages|monocytes|pbmcs|neurons|astrocytes|fibroblasts|hepatocytes|keratinocytes|explants)\b(?:(?!\b(?:mice|rats?|pigs?|piglets|animals|cattle|cows|birds|chickens|patients|donors)\b)[^.;]){0,60}\b(?:treated|stimulated|infected|uninfected|pulsed|exposed|transfected|incubated|challenged)\b|\b(?:treating|stimulating|infecting|transfecting)\b[^.;]{0,40}\bcells\b|cell lines?|immortali[sz]ed|organoids?|\b(?:[a-z]+\d[\w.-]*|\d+[a-z][\w.-]*)(?: [a-z-]+){0,2} (?:cells|macrophages)\b|\bipscs?\b|(?<!live )(?<!dietary )(?<!fed )yeast(?! (?:concentrations?|extract|paste|food|diets?|media|medium|supplement\w*))|\b(?:es|ips|s2|hek293t?|hela|cho) cells\b|\bcells? (?:were |are )?(?:cultured|treated with)|\bhela\b"),
    ("mouse", r"\bmice\b|\bmouse\b|\brats?\b"),
    ("drosophila", r"\bflies\b|\bfly\b|drosophila"),
    ("livestock", r"\bpigs?\b|piglets?|\bsows?\b|broilers?|\bhens?\b|\bcocks?\b|\bchickens\b|\bcattle\b|\bcows?\b|\bcalves\b"
                  r"|\bsteers?\b|\bheifers?\b|\bsheep\b|\blambs?\b|\bgoats?\b"),
    ("growth_chamber", r"growth[- ]chambers?|growth rooms?|climate chambers?|phytotron|controlled[- ]environment chambers?"),
    ("greenhouse", r"greenhouses?|glasshouses?|net ?house|screen ?house|polytunnel"),
    ("field", r"\bfield[- ]grown\b|\bin (?:a |the )?(?:paddy )?field\b|\bfield (?:trials?|plots?|sites?|conditions|experiment)\b"
              r"|\bpaddy\b|\borchards?\b"),
    # lab growth systems (hydroponics, MS medium, aeroponics ...) when no facility is named
    ("growth_chamber", r"hydropon|aeroponic|\b(?:1/2 |half[- ]strength )?ms (?:medium|agar|plates?)\b|murashige|hoagland|yoshida|agar plates?|petri dish|paper rolls?"),
]


def stated_setting(text):
    t = text.lower()
    for name, pat in STATED:
        if re.search(pat, t):
            return name
    return None


# a phenotyping location named outright also outranks breeding / multi-omics study types ("RILs in an RCBD in the
# field" is a field trial); validation and multi-environment studies span settings and keep their type
PLANT_SITES = {"growth_chamber", "greenhouse", "field"}
STUDY_BELOW_SITE = {"breeding_genetics", "multi_omics"}


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
