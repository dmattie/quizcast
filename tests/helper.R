# ---- tests/helper.R ---------------------------------------------------------
# A tiny harness so `make test` works with no packages beyond the app's own.
# If a check fails the runner exits non-zero, which is what CI and Claude Code
# need in order to tell a passing change from a broken one.

.RESULTS <- new.env(parent = emptyenv())
.RESULTS$pass <- 0L
.RESULTS$fail <- 0L
.RESULTS$notes <- character(0)
.RESULTS$group <- ""

group <- function(name) {
  .RESULTS$group <- name
  cat("\n", name, "\n", sep = "")
}

.record <- function(label, passed, detail = "") {
  if (isTRUE(passed)) {
    .RESULTS$pass <- .RESULTS$pass + 1L
    cat("  ok   ", label, "\n", sep = "")
  } else {
    .RESULTS$fail <- .RESULTS$fail + 1L
    .RESULTS$notes <- c(.RESULTS$notes, paste0(.RESULTS$group, " / ", label,
                                               if (nzchar(detail)) paste0("  (", detail, ")") else ""))
    cat("  FAIL ", label, if (nzchar(detail)) paste0("  ", detail) else "", "\n", sep = "")
  }
}

ok <- function(label, cond) .record(label, isTRUE(cond))

eq <- function(label, actual, expected) {
  .record(label, isTRUE(all.equal(actual, expected)),
          sprintf("got %s, wanted %s",
                  paste(utils::capture.output(str(actual)), collapse = ""),
                  paste(utils::capture.output(str(expected)), collapse = "")))
}

# Renderable output (renderUI returns a list carrying $html) flattened to text.
flatten <- function(x) {
  if (is.list(x) && !is.null(x$html)) x <- x$html
  paste(as.character(x), collapse = " ")
}

shows <- function(label, rendered, needle) {
  .record(label, grepl(needle, flatten(rendered), fixed = TRUE),
          sprintf("no '%s' in output", needle))
}

hides <- function(label, rendered, needle) {
  .record(label, !grepl(needle, flatten(rendered), fixed = TRUE),
          sprintf("'%s' leaked into output", needle))
}

errors <- function(label, expr) {
  .record(label, inherits(try(force(expr), silent = TRUE), "try-error"),
          "expected an error, got none")
}

summarise <- function() {
  cat("\n", strrep("-", 60), "\n", sep = "")
  cat(sprintf("%d passed, %d failed\n", .RESULTS$pass, .RESULTS$fail))
  if (.RESULTS$fail > 0) {
    cat("\nFailures:\n")
    for (n in .RESULTS$notes) cat("  - ", n, "\n", sep = "")
  }
  invisible(.RESULTS$fail)
}
