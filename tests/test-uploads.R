# ---- tests/test-uploads.R ---------------------------------------------------
# The upload path: a zip or a paste becomes a quiz folder without a redeploy.
# Everything here is pure file handling, so it needs lib/quiz.R and nothing
# else. Archive checks need a `zip` binary to build the fixture; the app itself
# only ever unpacks, and R's unzip is internal.

source("lib/quiz.R")

group("Slugs")

eq("lowercased and hyphenated", safe_slug("Week 3 Synapses.zip"), "week-3-synapses")
eq("punctuation collapses",     safe_slug("BSAD 495 -- lab #2!"),  "bsad-495-lab-2")
eq("path is dropped",           safe_slug("/etc/../passwd.zip"),  "passwd")
eq("nothing usable still names something", safe_slug("...."), "quiz")
ok("length is capped",          nchar(safe_slug(strrep("a", 200))) <= 48)

group("Pasted quizzes")

root <- file.path(tempdir(), "uploadroot")
unlink(root, recursive = TRUE)

paste_ok <- install_text(paste(c(
  "# First question?", "- [ ] no", "- [x] yes", "> Because.",
  "===",
  "# Second question?", "- [x] a", "- [ ] b"), collapse = "\n"),
  root, "pasted", "Pasted Quiz")

ok("paste installs",        isTRUE(paste_ok$ok))
eq("both questions land",   paste_ok$n, 2L)
eq("title comes from the field", paste_ok$title, "Pasted Quiz")
ok("folder is on disk",     dir.exists(file.path(root, "pasted")))

lib <- list_quizzes(c("quizzes", root))
ok("bundled quiz still listed", !is.null(lib[["demo-neuro"]]))
ok("uploaded quiz joins the library", !is.null(lib[["pasted"]]))

bad <- install_text("# A question with no options at all", root, "badpaste", "Bad")
ok("unparseable paste is refused", !isTRUE(bad$ok))
ok("refusal explains itself",      nzchar(bad$error))
ok("nothing written for a refusal", !dir.exists(file.path(root, "badpaste")))

empty <- install_text("   \n  \n", root, "emptypaste", "Empty")
ok("empty paste is refused", !isTRUE(empty$ok))

# A second upload under the same slug replaces the first outright.
again <- install_text("# Only one now?\n- [x] yes\n- [ ] no", root, "pasted", "Pasted Quiz")
ok("re-upload succeeds", isTRUE(again$ok))
eq("re-upload replaces rather than merges", again$n, 1L)

group("Zipped quizzes")

if (!nzchar(Sys.which("zip"))) {
  cat("  --   no zip binary here, archive checks skipped\n")
} else {
  src <- file.path(tempdir(), "zipsrc", "week3")
  unlink(dirname(src), recursive = TRUE)
  dir.create(src, recursive = TRUE)
  writeLines("title: Week 3", file.path(src, "quiz.yaml"))
  writeLines(c("# Zipped question?", "- [x] yes", "- [ ] no"), file.path(src, "01-a.md"))
  writeLines(c("# Another?", "- [x] yes", "- [ ] no"), file.path(src, "02-b.md"))
  writeLines("not a question", file.path(src, "notes.txt"))
  dir.create(file.path(dirname(src), "__MACOSX"))
  writeLines("junk", file.path(dirname(src), "__MACOSX", "._01-a.md"))

  zp <- file.path(tempdir(), "week3.zip")
  unlink(zp)
  wd <- setwd(dirname(src)); utils::zip(zp, c("week3", "__MACOSX"), flags = "-rq"); setwd(wd)

  res <- install_zip(zp, root, safe_slug("Week 3.zip"))
  ok("zip installs",          isTRUE(res$ok))
  eq("questions counted",     res$n, 2L)
  eq("title from quiz.yaml",  res$title, "Week 3")
  eq("slug from the filename", res$slug, "week-3")
  ok("nested folder is flattened",
     file.exists(file.path(root, "week-3", "01-a.md")))
  ok("non-quiz files are left out",
     !file.exists(file.path(root, "week-3", "notes.txt")))
  ok("__MACOSX junk is left out",
     !file.exists(file.path(root, "week-3", "._01-a.md")))
  ok("uploaded zip joins the library",
     !is.null(list_quizzes(c("quizzes", root))[["week-3"]]))

  # An archive with nothing the parser understands is refused before it is
  # unpacked anywhere near the quiz root.
  onlytxt <- file.path(tempdir(), "onlytxt.zip"); unlink(onlytxt)
  wd <- setwd(dirname(src)); utils::zip(onlytxt, "week3/notes.txt", flags = "-rq"); setwd(wd)
  res2 <- install_zip(onlytxt, root, "onlytxt")
  ok("archive with no questions is refused", !isTRUE(res2$ok))
  ok("nothing written for that refusal", !dir.exists(file.path(root, "onlytxt")))

  res3 <- install_zip(file.path(src, "01-a.md"), root, "notazip")
  ok("a non-zip file is refused", !isTRUE(res3$ok))

  # A traversal entry must not escape the staging directory. junkpaths keeps
  # only the basename, so the file lands inside the quiz folder or nowhere.
  trav <- file.path(tempdir(), "trav.zip"); unlink(trav)
  esc <- file.path(tempdir(), "zipsrc", "escape.md")
  writeLines(c("# Escaped?", "- [x] yes", "- [ ] no"), esc)
  wd <- setwd(src); utils::zip(trav, c("../escape.md", "01-a.md"), flags = "-q"); setwd(wd)
  res4 <- install_zip(trav, root, "trav")
  ok("traversal entry stays inside the quiz folder",
     !file.exists(file.path(root, "escape.md")) &&
       !file.exists(file.path(dirname(root), "escape.md")))
  ok("the archive still installs what was legal", isTRUE(res4$ok))
}

unlink(root, recursive = TRUE)
