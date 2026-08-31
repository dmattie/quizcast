# ---- lib/quiz.R -------------------------------------------------------------
# Parsing quiz folders and markdown question files.

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || identical(a, "")) b else a

# Render a markdown fragment to HTML (inline links, emphasis, code).
md_html <- function(txt) {
  if (is.null(txt) || !nzchar(trimws(paste(txt, collapse = "")))) return("")
  commonmark::markdown_html(paste(txt, collapse = "\n"), extensions = TRUE)
}

# ---- one question -----------------------------------------------------------
# Expected shape (all parts except the prompt and options are optional):
#
#   ---
#   time_limit: 30
#   points: 1000
#   media: https://example.org/figure.png
#   ---
#
#   # Prompt text?
#
#   Optional context paragraph, may contain [links](https://...).
#
#   - [ ] Wrong option
#   - [x] Correct option
#
#   > Explanation shown at reveal.
#
# Question files get written on other people's laptops, so what arrives is not
# reliably UTF-8 with plain spaces and Unix line endings. Everything invisible
# is dealt with here, once, rather than in the matchers below where it would be
# easy to miss a case. A non-breaking space after the "#" is the usual one: it
# comes from anything that has been through a word processor, and it makes a
# heading look perfect while matching nothing.
read_question <- function(path) {
  bytes <- readBin(path, "raw", n = max(file.size(path), 1L))
  bom <- function(a, b) length(bytes) >= 2L && bytes[1] == as.raw(a) && bytes[2] == as.raw(b)
  enc <- if (bom(0xff, 0xfe)) "UTF-16LE" else if (bom(0xfe, 0xff)) "UTF-16BE" else "UTF-8"

  txt <- iconv(list(bytes), from = enc, to = "UTF-8")
  # Not UTF-8 after all. A file saved from Notepad or Excel is usually this.
  if (is.na(txt)) txt <- iconv(list(bytes), from = "windows-1252", to = "UTF-8")
  if (is.na(txt)) stop("file is not readable as text")

  lines <- strsplit(txt, "\r\n|\n|\r")[[1]]
  lines <- gsub("\\p{Cf}", "",  lines, perl = TRUE)   # BOM, zero-width, direction marks
  gsub("\\p{Zs}", " ", lines, perl = TRUE)            # NBSP and the other blank spaces
}

parse_question <- function(path) {
  lines <- read_question(path)
  meta <- list()

  # --- YAML frontmatter ---
  fence <- grepl("^---\\s*$", lines)
  if (length(lines) > 0 && fence[1]) {
    close_at <- which(fence)
    close_at <- close_at[close_at > 1][1]
    if (!is.na(close_at)) {
      if (close_at > 2) {
        parsed <- try(yaml::yaml.load(paste(lines[2:(close_at - 1)], collapse = "\n")),
                      silent = TRUE)
        if (!inherits(parsed, "try-error") && is.list(parsed)) meta <- parsed
      }
      lines <- if (close_at < length(lines)) lines[(close_at + 1):length(lines)] else character(0)
    }
  }

  opt_re <- "^\\s*[-*]\\s*\\[([ xX])\\]\\s*(.*)$"

  prompt <- NULL
  options <- character(0)
  correct <- logical(0)
  explain <- character(0)
  context <- character(0)

  for (ln in lines) {
    if (is.null(prompt) && grepl("^#{1,3}\\s+", ln)) {
      prompt <- trimws(sub("^#{1,3}\\s+", "", ln))
    } else if (grepl(opt_re, ln)) {
      mark <- sub(opt_re, "\\1", ln)
      text <- trimws(sub(opt_re, "\\2", ln))
      options <- c(options, text)
      correct <- c(correct, tolower(mark) == "x")
    } else if (grepl("^\\s*>", ln)) {
      explain <- c(explain, sub("^\\s*>\\s?", "", ln))
    } else {
      context <- c(context, ln)
    }
  }

  # Say what was actually seen. "No heading" on a file that plainly has one
  # sends the author looking in the wrong place.
  if (is.null(prompt)) {
    seen <- utils::head(trimws(lines[nzchar(trimws(lines))]), 1L)
    stop("question file has no '# prompt' heading",
         if (length(seen))
           sprintf(" (the first line reads: %s)", substr(seen, 1L, 60L))
         else " (the file is empty)")
  }
  if (length(options) < 2)
    stop(sprintf("question file needs at least two '- [ ]' options, found %d",
                 length(options)))
  if (!any(correct))
    stop("question file needs at least one option marked '- [x]'")

  list(
    id         = tools::file_path_sans_ext(basename(path)),
    prompt     = prompt,
    prompt_html = md_html(prompt),
    context_html = md_html(trimws(paste(context, collapse = "\n"))),
    options    = options,
    options_html = vapply(options, function(o) {
      h <- md_html(o)
      trimws(gsub("</?p>", "", h))            # options are inline, drop the <p>
    }, character(1), USE.NAMES = FALSE),
    correct    = which(correct),
    multi      = sum(correct) > 1,
    explain_html = md_html(explain),
    media      = meta$media %||% NULL,
    media_alt  = meta$media_alt %||% "Question figure",
    time_limit = as.numeric(meta$time_limit %||% 30),
    points     = as.numeric(meta$points %||% 1000)
  )
}

# ---- a quiz folder ----------------------------------------------------------
# quizzes/<slug>/quiz.yaml  +  NN-*.md  (sorted by filename)
load_quiz <- function(dir) {
  cfg <- list()
  cfg_path <- file.path(dir, "quiz.yaml")
  if (file.exists(cfg_path)) {
    parsed <- try(yaml::yaml.load_file(cfg_path), silent = TRUE)
    if (!inherits(parsed, "try-error") && is.list(parsed)) cfg <- parsed
  }
  files <- sort(list.files(dir, pattern = "\\.md$", full.names = TRUE))
  if (length(files) == 0) stop("no .md question files in ", dir)

  questions <- lapply(files, function(f) {
    out <- try(parse_question(f), silent = TRUE)
    if (inherits(out, "try-error")) {
      stop("could not parse ", basename(f), ": ", attr(out, "condition")$message)
    }
    out
  })

  list(
    slug      = basename(dir),
    title     = cfg$title %||% basename(dir),
    subtitle  = cfg$subtitle %||% "",
    audio     = cfg$audio %||% NULL,
    questions = questions,
    n         = length(questions)
  )
}

# Scan every quiz root. Broken quizzes are reported, not fatal. Roots are read
# in order and a later one shadows an earlier one on a slug collision, so an
# uploaded quiz wins over a bundled quiz of the same name.
list_quizzes <- function(roots = "quizzes") {
  out <- list()
  for (root in roots) {
    if (!nzchar(root) || !dir.exists(root)) next
    for (d in list.dirs(root, recursive = FALSE)) {
      q <- try(load_quiz(d), silent = TRUE)
      if (inherits(q, "try-error")) {
        out[[basename(d)]] <- list(
          slug = basename(d), title = basename(d), broken = TRUE,
          error = conditionMessage(attr(q, "condition")), n = 0
        )
      } else {
        q$broken <- FALSE
        out[[basename(d)]] <- q
      }
    }
  }
  out
}

# ---- uploads ----------------------------------------------------------------
# A quiz is a handful of small text files, so the whole payload is a zip of one
# folder, or a paste. None of this trusts the archive: entries are flattened to
# their basenames, only the extensions the parser understands are unpacked, and
# the result has to survive load_quiz before it replaces anything on disk.

QUIZ_FILE_RE   <- "[.](md|markdown|ya?ml)$"
MAX_QUIZ_FILES <- 200L
MAX_QUIZ_BYTES <- 4 * 1024^2

# Folder names reach the filesystem and the URL-ish parts of the admin panel,
# so a slug is whatever survives being reduced to lowercase and hyphens.
safe_slug <- function(x) {
  s <- tolower(tools::file_path_sans_ext(basename(x)))
  s <- gsub("[^a-z0-9]+", "-", s)
  s <- gsub("^-+|-+$", "", s)
  if (!nzchar(s)) "quiz" else substr(s, 1L, 48L)
}

stage_dir <- function() {
  d <- tempfile("qstage-")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}

# Validate in the staging directory, then swap it into place. A quiz that does
# not parse never reaches the library, so a bad upload leaves whatever was
# under that slug already untouched.
finish_install <- function(staged, root, slug) {
  on.exit(unlink(staged, recursive = TRUE), add = TRUE)
  q <- try(load_quiz(staged), silent = TRUE)
  if (inherits(q, "try-error"))
    return(list(ok = FALSE, error = conditionMessage(attr(q, "condition"))))

  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(root)) return(list(ok = FALSE, error = paste("cannot write to", root)))

  dest <- file.path(root, slug)
  unlink(dest, recursive = TRUE)
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  copied <- file.copy(list.files(staged, full.names = TRUE), dest, overwrite = TRUE)
  if (!length(copied) || !all(copied)) {
    unlink(dest, recursive = TRUE)
    return(list(ok = FALSE, error = "could not write the quiz files"))
  }
  installed <- load_quiz(dest)
  list(ok = TRUE, slug = slug, title = installed$title, n = installed$n)
}

install_zip <- function(zip_path, root, slug) {
  listing <- try(utils::unzip(zip_path, list = TRUE), silent = TRUE)
  if (inherits(listing, "try-error") || !is.data.frame(listing) || !nrow(listing))
    return(list(ok = FALSE, error = "that file is not a readable zip archive"))

  keep <- listing$Name[
    grepl(QUIZ_FILE_RE, listing$Name, ignore.case = TRUE) &
      !grepl("/$", listing$Name) &
      !grepl("(^|/)[._]", listing$Name)]          # dotfiles and __MACOSX
  if (!length(keep))
    return(list(ok = FALSE, error = "no .md question files in that archive"))
  if (length(keep) > MAX_QUIZ_FILES)
    return(list(ok = FALSE, error = sprintf("more than %d files in that archive",
                                            MAX_QUIZ_FILES)))
  if (sum(listing$Length[listing$Name %in% keep]) > MAX_QUIZ_BYTES)
    return(list(ok = FALSE, error = "that archive unpacks to more than 4 MB"))

  staged <- stage_dir()
  # junkpaths flattens every entry to its basename, which is what makes an
  # entry named "../../etc/passwd" harmless rather than something to sanitise.
  out <- try(utils::unzip(zip_path, files = keep, exdir = staged, junkpaths = TRUE),
             silent = TRUE)
  if (inherits(out, "try-error")) {
    unlink(staged, recursive = TRUE)
    return(list(ok = FALSE, error = "could not unpack that archive"))
  }
  finish_install(staged, root, slug)
}

# The paste box: one textarea of questions separated by a line of ===, because
# --- is already spoken for by the frontmatter fence.
install_text <- function(text, root, slug, title = NULL) {
  lines <- strsplit(paste(text, collapse = "\n"), "\r?\n")[[1]]
  brk <- grepl("^\\s*={3,}\\s*$", lines)
  parts <- split(lines[!brk], cumsum(brk)[!brk])
  parts <- Filter(function(p) nzchar(trimws(paste(p, collapse = ""))), parts)
  if (!length(parts)) return(list(ok = FALSE, error = "nothing to load"))
  if (length(parts) > MAX_QUIZ_FILES)
    return(list(ok = FALSE, error = sprintf("more than %d questions", MAX_QUIZ_FILES)))

  staged <- stage_dir()
  writeLines(yaml::as.yaml(list(title = title %||% slug)),
             file.path(staged, "quiz.yaml"))
  for (i in seq_along(parts))
    writeLines(parts[[i]], file.path(staged, sprintf("%03d-q.md", i)))
  finish_install(staged, root, slug)
}
