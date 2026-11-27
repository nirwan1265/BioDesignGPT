library(studyforge)

a <- studyforge_ask("Field trial of 24 sorghum hybrids under two nitrogen rates (0 and 120 kg N/ha) and two irrigation regimes (full and deficit) at 3 locations over 2 seasons with 3 replicates; irrigation can only be applied to whole main plots; we measure grain yield and want to know whether the nitrogen response differs between hybrids.")
a

book <- layout_from_spec(a$spec, seed = 2026)
write_design_package(book, a$spec, "sorghum_trial")
spec <- jsonlite::fromJSON("sorghum_trial/study_spec.json")
spec$design$chosen
spec$analysis$model
unlist(spec$analysis$terms[c("treatment", "treatment2", "treatment3")])
spec$analysis$goal_terms$interaction
nrow(book)
head(book[, c("location", "season", "block", "plot", "subplot", "water", "genotype", "nitrogen")], 8)
