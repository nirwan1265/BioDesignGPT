library(studyforge)

# 1. Describe the experiment in plain English
a <- studyforge_ask("RNA-seq of leaves from wild type and mutant Arabidopsis under drought and well-watered conditions, 4 plants per genotype per treatment; we want genes whose drought response differs between genotypes.")
a

# 2. Answer the questions Biodes asked
a <- studyforge_fix(a, experimental_unit = "plant", primary_outcome.name = "gene expression")

# 3. Randomized layout and the files the next tools read
book <- layout_from_spec(a$spec, seed = 2026)
book[1:8, c("plot", "block", "genotype", "water")]
write_design_package(book, a$spec, "rnaseq_design")

# 4. The design Biodes wrote
spec <- jsonlite::fromJSON("rnaseq_design/study_spec.json")
spec$design$chosen
spec$analysis$model
spec$analysis$primary_goal
spec$analysis$goal_terms$interaction
