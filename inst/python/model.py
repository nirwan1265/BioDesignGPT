"""Multi-task BERT: token tagging (BIO over StudySpec slots) + system classification."""
import json, os, re
import torch
import torch.nn as nn

from decode import to_spec

TOKEN_RE = re.compile(r"\d+(?:[.,]\d+)*|[A-Za-z]+(?:[-'/][A-Za-z0-9]+)*|[^\sA-Za-z\d]")
TAGS = ["ORG", "GENO_N", "CHECK_N", "REPS_N", "LOC_N", "SEASON_N", "SUB_N", "MEAS", "EXP",
        "FACTOR", "LEVELS_N", "APPLY", "OUTCOME", "BLOCK", "GEN_N", "PARENT_N", "MATING", "ASSAY", "ENV"]
LABELS = ["O"] + [p + t for t in TAGS for p in ("B-", "I-")]
SYSTEMS = ["field", "greenhouse", "growth_chamber", "mouse", "drosophila", "bulk_rnaseq",
           "metabolomics_lipidomics", "single_cell", "cell_culture", "breeding_genetics", "multi_environment",
           "multi_omics", "ribo_seq", "atac_seq", "functional_validation"]


def words(text):
    return TOKEN_RE.findall(text)


class Tagger(nn.Module):
    def __init__(self, encoder, hidden):
        super().__init__()
        self.encoder = encoder
        self.drop = nn.Dropout(0.1)
        self.tok_head = nn.Linear(hidden, len(LABELS))
        self.sys_head = nn.Linear(hidden, len(SYSTEMS))

    def forward(self, input_ids, attention_mask):
        h = self.encoder(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        h = self.drop(h)
        return self.tok_head(h), self.sys_head(h[:, 0])


def encode(tokenizer, toks, labels=None, max_len=128):
    enc = tokenizer(toks, is_split_into_words=True, truncation=True, max_length=max_len)
    wid = enc.word_ids()
    lab = []
    prev = None
    for w in wid:
        if w is None or w == prev:
            lab.append(-100)
        else:
            lab.append(LABELS.index(labels[w]) if labels else 0)
        prev = w
    return enc["input_ids"], enc["attention_mask"], lab, wid


class StudyForgeTagger:
    """Load a trained model directory and turn prompts into StudySpecs."""

    def __init__(self, model_dir, device="cpu"):
        from transformers import AutoConfig, AutoModel, AutoTokenizer, PreTrainedTokenizerFast
        meta = json.load(open(os.path.join(model_dir, "meta.json")))
        if meta.get("custom_tokenizer"):
            self.tok = PreTrainedTokenizerFast.from_pretrained(model_dir)
        else:
            self.tok = AutoTokenizer.from_pretrained(model_dir)
        cfg = AutoConfig.from_pretrained(model_dir)
        enc = AutoModel.from_config(cfg, add_pooling_layer=False) if cfg.model_type == "bert" else AutoModel.from_config(cfg)
        self.model = Tagger(enc, cfg.hidden_size)
        self.model.load_state_dict(torch.load(os.path.join(model_dir, "tagger.pt"), map_location=device))
        self.model.eval()
        self.lower = meta.get("lowercase", True)

    @torch.no_grad()
    def tag(self, text):
        toks = words(text)
        inp = [t.lower() for t in toks] if self.lower else toks
        ids, mask, _, wid = encode(self.tok, inp)
        tl, sl = self.model(torch.tensor([ids]), torch.tensor([mask]))
        pred = tl[0].argmax(-1).tolist()
        tags, prev = ["O"] * len(toks), None
        for i, w in enumerate(wid):
            if w is not None and w != prev:
                tags[w] = LABELS[pred[i]]
            prev = w
        probs = sl[0].softmax(-1)
        return toks, tags, SYSTEMS[int(probs.argmax())], float(probs.max())

    def spec(self, text):
        toks, tags, system, conf = self.tag(text)
        s = to_spec(toks, tags, system, text)
        s["question"] = text
        s["_model"] = {"system_confidence": round(conf, 3), "tags": list(zip(toks, tags))}
        return s
