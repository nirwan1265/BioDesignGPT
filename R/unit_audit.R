#' Audit experimental, measurement and analysis units
#'
#' Run before any power calculation. Flags pseudoreplication when the
#' measured entity is nested inside the unit that received the treatment.
#'
#' @param biological_unit The organism-level entity (e.g. "plant", "mouse").
#' @param experimental_unit The entity independently assigned to treatment.
#' @param measurement_unit The entity actually measured.
#' @param subsamples_per_unit Measurements per experimental unit.
#' @param units_per_group Experimental units per treatment group (optional).
#' @return A list with risk level, resolution, effective n and matching rules.
#' @export
unit_audit <- function(biological_unit, experimental_unit, measurement_unit,
                       subsamples_per_unit = 1, units_per_group = NA_integer_) {
  stopifnot(is.numeric(subsamples_per_unit), subsamples_per_unit >= 1)
  same <- tolower(measurement_unit) == tolower(experimental_unit)
  rules <- match_pseudoreplication_rules(measurement_unit, experimental_unit)

  risk <- if (same) {
    "none"
  } else if (subsamples_per_unit > 1 || length(rules) > 0) {
    "high"
  } else {
    "check"
  }

  resolution <- switch(risk,
    none = "Measurement unit equals experimental unit; n = number of experimental units.",
    high = sprintf(
      "Each %s is a subsample: average within each %s, or fit (1 | %s). n = number of %s units, not %s measurements.",
      measurement_unit, experimental_unit, experimental_unit,
      experimental_unit, measurement_unit),
    check = sprintf(
      "Measurement unit (%s) differs from experimental unit (%s); confirm each %s is independently randomized.",
      measurement_unit, experimental_unit, measurement_unit)
  )

  list(
    biological_unit = biological_unit,
    experimental_unit = experimental_unit,
    measurement_unit = measurement_unit,
    analysis_unit = if (risk == "high") paste0(experimental_unit, "_mean") else experimental_unit,
    subsamples_per_unit = subsamples_per_unit,
    effective_n_per_group = units_per_group,
    nominal_n_per_group = if (is.na(units_per_group)) NA_integer_ else units_per_group * subsamples_per_unit,
    pseudoreplication_risk = risk,
    resolution = resolution,
    rules = lapply(rules, function(r) r[c("id", "message", "source")])
  )
}
