# Paper index (retrieval)

Biodes answers "how did others do this?" from real methods sections, never from memory. The
~33,000 open-access methods sections collected by the evidence layer are split into passages and
embedded once; a question searches only the shard for its organism, filtered by technique, and the
plan quotes the closest passages with their DOIs. Nothing is trained on the papers.

```
index/
  sorghum/  emb.npy  meta.jsonl  info.json      # one shard per organism; technique is a filter inside it
  maize/ ...
  human/ ...
```

## On the NC State cluster

```bash
# 1. login node (internet), once: env + model downloads (~30 GB for the 14B reader)
git clone https://github.com/nirwan1265/BioDesignGPT.git /gpfs_common/share01/maize/ntanduk/BioDesignGPT
cd /gpfs_common/share01/maize/ntanduk/BioDesignGPT
bash retrieval/setup_cluster.sh /gpfs_common/share01/maize/ntanduk

# 2. GPU node (offline): build every shard (~1 h on one L40S; re-run to add organisms)
sbatch retrieval/build_index.slurm
SPECIES=sorghum sbatch retrieval/build_index.slurm      # one organism

# 3. search (any node)
/gpfs_common/share01/maize/ntanduk/envs/biodes-gpu/bin/python retrieval/search.py \
  --index /gpfs_common/share01/maize/ntanduk/index --organism maize --technique ChIP-seq \
  --query "field-grown plants, crosslinking leaf tissue, input controls, replicates"
```

Embedding model: `BAAI/bge-base-en-v1.5` (change with `--model`; rebuild shards with `--force`).
Full texts and the index stay local; only DOIs and short quotes appear in plans.

### Wrong-organism papers

Papers reach a shard because they mention one of its datasets, so the rat shard also holds mouse papers that
reanalyse rat data. After building, label each paper and passage with the organism its own text is about:

    python retrieval/label_organisms.py --index index

Names come from `inst/vocab/organism_names.tsv` (see `data-raw/vocab/`), not hand lists. Three general rules:
longest name wins ("guinea pig" is not pig); an organism word next to a material or antibody word is a reagent
("corn oil", "yeast extract", "goat anti-rabbit IgG"); a name about as common in every shard as in its own is
dropped (listed in `index/_names_dropped.tsv`). Search returns same-organism passages first and adds
other-organism ones, tagged `[Mus musculus study]`, only when too few match. A paper that uses two organisms
(rats for RNA-seq, mice for the knockout) is split by passage.
