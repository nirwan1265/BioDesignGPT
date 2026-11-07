withr_local_tempdir <- function(env = parent.frame()) {
  d <- tempfile("sf_")
  dir.create(d)
  do.call(on.exit, list(substitute(unlink(d, recursive = TRUE), list(d = d)), add = TRUE), envir = env)
  d
}
