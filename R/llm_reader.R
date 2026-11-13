# Client for the Biodes LLM reader (llm/reader.py --serve) running on a GPU node.
#
# The reader keeps a large model loaded and turns a question into a StudySpec skeleton. Its answer is
# merged into the rules' reading as stated facts only (merge_specs); design judgments stay with the engine.
#
# Where the reader is, in this order:
#   1. url/token arguments
#   2. BIODES_READER_URL + BIODES_READER_TOKEN (e.g. a laptop with an ssh tunnel)
#   3. the connection file the server writes (BIODES_READER_CONN, default ~/.biodes/reader.json); on the
#      cluster this is on shared storage, so R on a login node finds the running server by itself

.sf_reader_conf <- function(url = NULL, token = NULL,
                            conn = Sys.getenv("BIODES_READER_CONN", file.path("~", ".biodes", "reader.json"))) {
  url <- url %||% (if (nzchar(Sys.getenv("BIODES_READER_URL"))) Sys.getenv("BIODES_READER_URL"))
  token <- token %||% (if (nzchar(Sys.getenv("BIODES_READER_TOKEN"))) Sys.getenv("BIODES_READER_TOKEN"))
  if ((is.null(url) || is.null(token)) && file.exists(path.expand(conn))) {
    c <- jsonlite::fromJSON(path.expand(conn))
    url <- url %||% c$url
    token <- token %||% c$token
  }
  if (is.null(url) || is.null(token)) return(NULL)
  list(url = sub("/+$", "", url), token = token)
}

.sf_http_post_json <- function(url, body, headers = character(), timeout = 120) {
  payload <- jsonlite::toJSON(body, auto_unbox = TRUE)
  if (requireNamespace("curl", quietly = TRUE)) {
    h <- curl::new_handle(timeout = timeout)
    curl::handle_setopt(h, post = TRUE, postfields = payload)
    curl::handle_setheaders(h, .list = c("Content-Type" = "application/json", headers))
    r <- curl::curl_fetch_memory(url, handle = h)
    return(list(status = r$status_code, text = rawToChar(r$content)))
  }
  # no curl package: the curl command-line tool
  f <- tempfile(fileext = ".json"); writeLines(payload, f); on.exit(unlink(f))
  hdr <- unlist(lapply(names(c("Content-Type" = "application/json", headers)), function(k)
    c("-H", shQuote(paste0(k, ": ", c("Content-Type" = "application/json", headers)[[k]])))))
  out <- system2("curl", c("-s", "-m", timeout, "-w", shQuote("\n%{http_code}"), hdr, "--data-binary", paste0("@", f),
                           shQuote(url)), stdout = TRUE, stderr = FALSE)
  list(status = as.integer(utils::tail(out, 1)), text = paste(utils::head(out, -1), collapse = "\n"))
}

#' Read a question with the Biodes LLM reader
#'
#' Sends the question to the reader server (`llm/reader.py --serve`, started with
#' `sbatch llm/reader_server.slurm` on the cluster) and returns its StudySpec
#' skeleton. Returns NULL with a message when no reader is reachable, so callers
#' fall back to the rules.
#'
#' @param question Text.
#' @param url,token Reader address and token; by default from BIODES_READER_URL /
#'   BIODES_READER_TOKEN or the connection file the server writes.
#' @param timeout Seconds.
#' @return A StudySpec list (with `missing_questions` the reader would ask), or NULL.
#' @export
extract_spec_llm <- function(question, url = NULL, token = NULL, timeout = 120) {
  conf <- .sf_reader_conf(url, token)
  if (is.null(conf)) {
    message("No Biodes reader found (start one with: sbatch llm/reader_server.slurm); using rules only.")
    return(NULL)
  }
  r <- tryCatch(.sf_http_post_json(paste0(conf$url, "/read"), list(question = question),
                                   headers = c("X-Biodes-Token" = conf$token), timeout = timeout),
                error = function(e) list(status = 0L, text = conditionMessage(e)))
  if (!identical(as.integer(r$status), 200L)) {
    message("Biodes reader at ", conf$url, " did not answer (", r$status, "): ", substr(r$text, 1, 200),
            "\nIs the job still running (squeue -u $USER)? Using rules only.")
    return(NULL)
  }
  jsonlite::fromJSON(r$text, simplifyVector = FALSE)$spec
}
