# Survival (time-to-event) outcomes: the endpoint, competing events, analysis.survival options and event-based power,
# read from the question. Vocabulary and patterns are in rules.tsv (survival_event, time_unit_long, surv_* cues);
# the Bioana contract is docs/contracts/survival.md in the Bioana repo.

.sf_grab <- function(t, cue) {
  re <- tryCatch(.sf_expand_vocab(.sf_cue(cue)), error = function(e) "(?!)")
  regmatches(t, regexec(re, t, perl = TRUE))[[1]]
}

# a time unit as a word for the endpoint ("d" -> "days"; rules.tsv time_unit_long)
.sf_time_unit_long <- function(u) {
  if (is.null(u) || is.na(u) || !nzchar(u)) return(NULL)
  r <- .sf_rules_rows("time_unit_long")
  k <- which(vapply(r$pattern, grepl, logical(1), x = tolower(trimws(u)), perl = TRUE))
  if (length(k)) r$term[k[1]] else NULL
}

.sf_nums <- function(x) as.numeric(unlist(regmatches(x, gregexpr("\\d+(?:\\.\\d+)?", x, perl = TRUE))))

.sf_survival_from_text <- function(text) {
  t <- tolower(text)
  ep <- list(); sv <- list(); pw <- list()
  r <- .sf_rules_rows("survival_event")
  k <- which(vapply(r$pattern, grepl, logical(1), x = t, perl = TRUE))
  if (length(k)) ep$event <- r$term[k[1]]
  g <- .sf_grab(t, "surv_origin"); if (length(g)) ep$origin <- g[2]
  fu <- .sf_grab(t, "surv_followup")
  iv <- .sf_grab(t, "surv_interval")
  lm <- .sf_grab(t, "surv_landmark")
  units <- c(if (length(fu)) fu[3], if (length(iv) && nzchar(iv[3])) iv[3], if (length(iv) && nzchar(iv[4] %||% "")) "days",
             regmatches(t, regexpr("\\b(?:days?|weeks?|hours?|months?)\\b", t, perl = TRUE)))
  for (u in units) { ul <- .sf_time_unit_long(u); if (!is.null(ul)) { ep$unit <- ul; break } }
  loss <- .sf_grab(t, "surv_loss")
  ep$censoring <- paste0(
    if (length(fu)) sprintf("administrative at %s %s (end of follow-up)", fu[2], ep$unit %||% fu[3]) else "administrative at the end of the experiment",
    if (length(loss)) "; loss to follow-up" else "")
  ep$event_column <- "event"
  g <- .sf_grab(t, "surv_competing")
  if (length(g)) ep$event_codes <- list(`0` = "censored", `1` = ep$event %||% "event", `2` = trimws(gsub("\\s+(?:can|may|might|could|will|often)\\s+(?:occur|happen|set\\s+in)", "", gsub("\\s+", " ", g[2]), perl = TRUE)))
  if (length(lm)) sv$landmarks <- .sf_nums(paste(lm[-1], collapse = " "))
  g <- .sf_grab(t, "surv_rmst"); if (length(g)) sv$rmst_tau <- .sf_nums(paste(g[-1], collapse = " "))[1]
  if (length(.sf_grab(t, "surv_early_effect"))) sv$logrank_weight <- "fh_1_0"
  if (length(.sf_grab(t, "surv_delayed_effect"))) sv$logrank_weight <- "fh_0_1"   # a stated delay wins over "early"
  if (length(.sf_grab(t, "surv_aft"))) sv$aft <- TRUE
  if (length(iv)) sv$life_table <- if (nzchar(iv[2])) as.numeric(iv[2]) else 1
  g <- .sf_grab(t, "surv_hr"); if (length(g)) pw$target_hazard_ratio <- as.numeric(g[2])
  # in words: "halve the hazard" (rules.tsv hazard_phrase), "reduce the hazard by 30%" (cue surv_hr_reduction)
  if (is.null(pw$target_hazard_ratio)) {
    hp <- .sf_rules_rows("hazard_phrase"); k <- which(vapply(hp$pattern, grepl, logical(1), x = t, perl = TRUE))
    if (length(k)) pw$target_hazard_ratio <- as.numeric(hp$term[k[1]])
    g <- .sf_grab(t, "surv_hr_reduction"); if (length(g)) pw$target_hazard_ratio <- 1 - as.numeric(g[2]) / 100
    g <- .sf_grab(t, "surv_hr_increase"); if (length(g)) pw$target_hazard_ratio <- 1 + as.numeric(g[2]) / 100
  }
  g <- .sf_grab(t, "surv_event_prob"); if (length(g)) pw$event_probability <- as.numeric(g[2]) / 100
  if (length(loss)) pw$loss_fraction <- as.numeric(loss[2]) / 100
  list(endpoint = ep, survival = sv, power = pw)
}

# put what was read into the spec; time is the outcome, so a time factor read from the stated times is not a design
# factor: its values become landmarks
.sf_apply_survival <- function(spec, text) {
  if (!identical(spec$primary_outcome$type, "survival")) return(spec)
  s <- .sf_survival_from_text(text)
  ep <- s$endpoint
  if (!is.null(spec$primary_outcome$unit)) ep$unit <- NULL
  for (k in names(ep)) spec$primary_outcome[[k]] <- ep[[k]]
  # a factor whose only evidence is the endpoint ("first lesion" -> injury, "after inoculation" -> infection) is the
  # outcome or its origin, not a design factor
  t <- tolower(text); rest <- t
  for (cue in c("surv_origin", "surv_competing")) rest <- gsub(.sf_expand_vocab(.sf_cue(cue)), " ", rest, perl = TRUE)
  r <- .sf_rules_rows("survival_event"); for (p in r$pattern) rest <- gsub(p, " ", rest, perl = TRUE)
  rest <- gsub("\\b(?:lesions?|symptoms?)\\b", " ", rest, perl = TRUE)
  ev_f <- .sf_find_all(paste(ep$event %||% "", ep$origin %||% "", t), "factor")
  keep <- vapply(spec$factors %||% list(), function(f) {
    if (length(f$levels) || !(f$name %in% ev_f)) return(TRUE)
    f$name %in% .sf_find_all(rest, "factor")
  }, logical(1))
  if (any(!keep)) {
    spec$assumptions[["factors.endpoint_words"]] <- sprintf("removed %s: named only in the endpoint (event or origin)",
      paste(vapply(spec$factors[!keep], `[[`, "", "name"), collapse = ", "))
    spec$factors <- spec$factors[keep]
  }
  tf <- which(vapply(spec$factors %||% list(), function(f) identical(f$name, "time"), logical(1)))
  # only stated times (values) become landmarks; repeated sampling without times keeps its time factor
  if (length(tf) && length(spec$factors[[tf[1]]]$values)) {
    v <- unlist(spec$factors[[tf[1]]]$values)
    if (is.null(s$survival$landmarks) && length(v)) s$survival$landmarks <- v
    spec$factors[[tf[1]]] <- NULL
    spec$assumptions[["factors.time"]] <- "removed: time is the outcome of a survival study; stated times are landmarks"
  }
  # a time factor with no count or values read where a follow-up is stated ("followed for 30 days") is the follow-up
  tf <- which(vapply(spec$factors %||% list(), function(f) identical(f$name, "time") && is.null(f$n_levels) && !length(f$values), logical(1)))
  if (length(tf) && length(.sf_grab(t, "surv_followup"))) {
    spec$factors[[tf[1]]] <- NULL
    spec$assumptions[["factors.time"]] <- "removed: the stated time is the follow-up of a survival study"
  }
  if (grepl(.sf_cue("blocks_stated"), tolower(text), perl = TRUE)) spec$analysis$sf_blocks_stated <- TRUE
  if (length(s$survival)) spec$analysis$survival <- utils::modifyList(spec$analysis$survival %||% list(), s$survival)
  for (k in names(s$power)) spec$power[[k]] <- s$power[[k]]
  spec
}

# at write time: the estimand (hazard ratio, time ratio, RMST difference), events needed (Schoenfeld), units needed,
# and clusters as a shared frailty (1 | block) or, with fewer than 10, strata
.sf_fill_survival <- function(spec, ge) {
  if (!identical(spec$primary_outcome$type, "survival") && !("survival" %in% names(ge))) return(list(spec = spec, ge = ge))
  sv <- spec$analysis$survival %||% list(); pw <- spec$power %||% list()
  if ("survival" %in% names(ge)) {
    e <- ge$survival
    e$scale <- if (isTRUE(sv$aft)) "time_ratio" else if (!is.null(sv$rmst_tau)) "rmst_difference" else "hazard_ratio"
    e$size <- if (identical(e$scale, "hazard_ratio")) pw$target_hazard_ratio else NULL
    if (identical(e$scale, "rmst_difference")) e$tau <- sv$rmst_tau
    # a stated early or delayed effect: hazards are not proportional, and the goal is tested with that weighted
    # log-rank, not one Cox hazard ratio (which averages the phases)
    if (!is.null(sv$logrank_weight)) { e$proportional_hazards <- FALSE; e$test <- paste0("logrank_", sv$logrank_weight) }
    e$definition <- switch(e$scale, hazard_ratio = "hazard ratio of a level vs the reference (Cox)",
      time_ratio = "ratio of survival times of a level vs the reference (AFT)",
      rmst_difference = "difference in restricted mean time to the event up to tau")
    ge$survival <- e[!vapply(e, is.null, logical(1))]
    spec$assumptions[["analysis.goal_effect.survival.size"]] <- if (is.null(e$size)) "not stated: asked" else NULL
  }
  hr <- pw$target_hazard_ratio
  if (!is.null(hr) && hr > 0 && hr != 1) {
    a <- pw$alpha %||% 0.05; b <- pw$power %||% pw$target_power %||% 0.8
    d <- ceiling((stats::qnorm(1 - a / 2) + stats::qnorm(b))^2 / (0.25 * log(hr)^2))   # 1:1 allocation
    spec$power$events_required <- d
    if (!is.null(pw$event_probability) && pw$event_probability > 0)
      spec$power$units_required <- ceiling(d / pw$event_probability / (1 - (pw$loss_fraction %||% 0)))
  }
  # clusters: blocks as a shared frailty (1 | block), or strata when there are few
  terms <- spec$analysis$terms %||% list()
  stated <- isTRUE(spec$analysis$sf_blocks_stated); spec$analysis$sf_blocks_stated <- NULL
  if (stated && !is.null(terms$block) && grepl("\\bblock\\b", spec$analysis$model %||% "")) {
    nb <- spec$design$blocks %||% spec$design$reps
    if (!is.null(nb) && nb < 10) {
      spec$analysis$survival$strata <- unique(c(unlist(sv$strata), terms$block))
      spec$analysis$note <- trimws(paste(spec$analysis$note %||% "", sprintf("Survival: %s blocks are strata (fewer than 10 for a frailty).", nb)))
    } else if (!is.null(nb)) {
      spec$analysis$model <- sub("\\+\\s*block\\b(?!\\))", "+ (1 | block)", spec$analysis$model, perl = TRUE)
      spec$analysis$note <- trimws(paste(spec$analysis$note %||% "", "Survival: (1 | block) is a shared frailty."))
    }
  }
  list(spec = spec, ge = ge)
}
