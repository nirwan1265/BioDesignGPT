# Draw 4: 2,500 more papers, aimed at the gaps

Plan: pick papers where the rules are weakest, lock 250 as a test the rules are never written from, then label and
mine the rest in rounds of about 500 (rules.tsv and questions.tsv, rescore dev after each round). Stop when a round
adds less than half a point on dev. Retrain the reader once at the end (v7).

The draw (login node, no GPU; reads the local index, no internet):

    cd /gpfs_common/share01/maize/ntanduk/BioDesignGPT/training/paper_questions && mkdir -p raw
    python3 sample_papers.py --index /gpfs_common/share01/maize/ntanduk/index \
        --evidence /gpfs_common/share01/maize/ntanduk/design/evidence \
        --n 2500 --seed 2028 --id-start 5700 --no-held-out \
        --exclude batches/*.jsonl \
        --weights draws/draw4_weights.tsv --balance batches --lock 250 --rounds 5 --out raw/papers_sample_draw4.jsonl
    gzip raw/papers_sample_draw4.jsonl

Weights (`draw4_weights.tsv`): a paper's study kind (the heaviest kind row its methods text matches: human cohorts
3, cell lines 2.5, mapping 2.5, mutant lines 1.5, population studies 1.5, stated layouts 1.3, else 1) times how
short we are of its species and technique, sqrt(median / labelled questions), times the share of read papers of
that species and technique that gave a question. Seed 2028.

Each paper gets `part`: `test` (the first 250; labelled into a locked split, never mined) or 1-5 (the rounds).
Every paper read so far is excluded by its pmcid in batches/ (all 5,700, labelled or skipped). Raw paper
text stays out of git (raw/ is ignored).
