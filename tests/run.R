# ---- tests/run.R ------------------------------------------------------------
# Run from the project root:  Rscript tests/run.R  (or: make test)
if (!file.exists("app.R")) stop("run this from the project root")

source("tests/helper.R")
for (f in sort(list.files("tests", pattern = "^test-.*\\.R$", full.names = TRUE))) {
  cat("\n==", basename(f), "==\n")
  source(f, local = new.env())
}
quit(status = if (summarise() > 0) 1L else 0L)
