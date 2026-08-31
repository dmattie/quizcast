# ---- tests/test-parsing.R ---------------------------------------------------
source("lib/quiz.R")

group("Question parsing")

tmp <- file.path(tempdir(), "qtest"); dir.create(tmp, showWarnings = FALSE)
write_q <- function(name, text) {
  p <- file.path(tmp, name); writeLines(text, p); p
}

full <- write_q("full.md", c(
  "---", "time_limit: 20", "points: 800",
  "media: https://example.org/fig.png", "media_alt: A figure", "---",
  "", "# What is the answer?", "",
  "Some *context* with a [link](https://example.org).", "",
  "- [ ] Wrong one", "- [x] Right one", "- [ ] Also wrong", "",
  "> Because reasons."))

q <- parse_question(full)
eq("prompt text",            q$prompt, "What is the answer?")
eq("option count",           length(q$options), 3L)
eq("correct index",          q$correct, 2L)
ok("single-answer question", !q$multi)
eq("time limit from meta",   q$time_limit, 20)
eq("points from meta",       q$points, 800)
eq("media url",              q$media, "https://example.org/fig.png")
eq("media alt",              q$media_alt, "A figure")
shows("context renders emphasis", q$context_html, "<em>context</em>")
shows("context renders link",     q$context_html, "https://example.org")
shows("explanation captured",     q$explain_html, "Because reasons")
ok("options carry no <p> wrapper", !grepl("<p>", paste(q$options_html, collapse = "")))

group("Defaults and variants")

bare <- parse_question(write_q("bare.md", c(
  "# No frontmatter here", "", "- [x] Yes", "- [ ] No")))
eq("default time limit", bare$time_limit, 30)
eq("default points",     bare$points, 1000)
ok("media absent",       is.null(bare$media))
eq("explanation empty",  bare$explain_html, "")

multi <- parse_question(write_q("multi.md", c(
  "# Pick several", "", "- [x] A", "- [X] B", "- [ ] C", "- [x] D")))
ok("multi flagged",          multi$multi)
eq("all correct indices",    multi$correct, c(1L, 2L, 4L))
ok("uppercase X counts",     2L %in% multi$correct)

stars <- parse_question(write_q("stars.md", c(
  "# Asterisk bullets", "", "* [ ] A", "* [x] B")))
eq("asterisk bullets parse", stars$correct, 2L)

h2 <- parse_question(write_q("h2.md", c(
  "## Second-level heading works", "", "- [x] A", "- [ ] B")))
eq("h2 prompt", h2$prompt, "Second-level heading works")

group("Files from other people's laptops")

# The heading that looks right and matches nothing: a word processor put a
# non-breaking space after the hash. This is the one that cost an afternoon.
nbsp <- parse_question(write_q("nbsp.md", c(
  "#\u00a0Heading with a hard space", "", "- [x] A", "- [ ] B")))
eq("non-breaking space after the hash", nbsp$prompt, "Heading with a hard space")

wide <- parse_question(write_q("wide.md", c(
  "# Spaced\u2009out\u00a0heading", "", "-\u00a0[x] A", "- [ ] B")))
eq("unicode blanks inside a line", wide$prompt, "Spaced out heading")
eq("unicode blank before an option", wide$correct, 1L)

zw <- parse_question(write_q("zw.md", c(
  "\ufeff# Heading after a stray BOM", "", "- [x] A\u200b", "- [ ] B")))
eq("zero-width characters dropped", zw$prompt, "Heading after a stray BOM")

# Line endings. write_bytes so the fixture is exactly what the other machine
# would have produced, not whatever writeLines does here.
write_bytes <- function(name, txt, enc = "UTF-8") {
  p <- file.path(tmp, name)
  writeBin(iconv(txt, "UTF-8", enc, toRaw = TRUE)[[1]], p)
  p
}
body <- "# Ending test\n\n- [x] A\n- [ ] B"

eq("CRLF file", parse_question(write_bytes("crlf.md", gsub("\n", "\r\n", body)))$prompt,
   "Ending test")
eq("CR-only file", parse_question(write_bytes("cr.md", gsub("\n", "\r", body)))$prompt,
   "Ending test")
eq("UTF-8 BOM", parse_question(write_bytes("bom.md", paste0("\ufeff", body)))$prompt,
   "Ending test")
eq("UTF-16LE with BOM",
   parse_question(write_bytes("u16.md", paste0("\ufeff", body), "UTF-16LE"))$prompt,
   "Ending test")

# Windows-1252 is not UTF-8, and guessing wrong would mangle the explanation.
cp <- parse_question(write_bytes("cp1252.md",
  "# Costs \u00a35 \u2014 or 10 \u00d7 that\n\n- [x] A\n- [ ] B", "windows-1252"))
eq("windows-1252 recovered", cp$prompt, "Costs \u00a35 \u2014 or 10 \u00d7 that")

group("Malformed files are rejected, not silently accepted")

errors("no heading",     parse_question(write_q("noh.md",  c("- [x] A", "- [ ] B"))))

# An author looking at a file that plainly has a heading needs to be told what
# the parser actually saw, or they go hunting in the wrong place.
noh <- try(parse_question(write_q("noh2.md", c("Just a paragraph", "- [x] A", "- [ ] B"))),
           silent = TRUE)
shows("the heading error quotes the first line",
      conditionMessage(attr(noh, "condition")), "Just a paragraph")
few <- try(parse_question(write_q("few.md", c("# Q", "- [x] A"))), silent = TRUE)
shows("the option error counts what it found",
      conditionMessage(attr(few, "condition")), "found 1")
errors("one option",     parse_question(write_q("one.md",  c("# Q", "- [x] A"))))
errors("no correct mark", parse_question(write_q("nokey.md", c("# Q", "- [ ] A", "- [ ] B"))))

group("Quiz folders")

qz <- load_quiz("quizzes/demo-neuro")
eq("demo quiz question count", qz$n, 4L)
eq("title from quiz.yaml",     qz$title, "Reward, Risk and the Business Brain")
ok("questions ordered by filename",
   qz$questions[[1]]$id < qz$questions[[2]]$id)

all_q <- list_quizzes("quizzes")
ok("demo quiz discovered",  "demo-neuro" %in% names(all_q))
ok("demo quiz not broken",  !isTRUE(all_q[["demo-neuro"]]$broken))

# A bad question must degrade that one quiz, never the whole app.
bad <- file.path("quizzes", ".tmp-broken")
dir.create(bad, showWarnings = FALSE)
writeLines(c("# Missing its options"), file.path(bad, "01-bad.md"))
scanned <- list_quizzes("quizzes")
ok("broken quiz flagged",        isTRUE(scanned[[".tmp-broken"]]$broken))
ok("broken quiz reports reason", nzchar(scanned[[".tmp-broken"]]$error))
ok("good quiz still loads",      !isTRUE(scanned[["demo-neuro"]]$broken))
unlink(bad, recursive = TRUE)
