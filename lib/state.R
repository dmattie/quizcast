# ---- lib/state.R ------------------------------------------------------------
# One R process holds the whole game. GAME is created once at startup and shared
# by every connected session, so a change made by the host invalidates the
# reactive contexts of all 50 phones at once. This is why max-replicas must be 1.

GAME <- shiny::reactiveValues(
  phase     = "lobby",   # lobby | question | reveal | standings | final
  quiz      = NULL,
  quiz_slug = NULL,
  idx       = 0L,
  opened_at = NULL,
  locked    = FALSE,
  players   = list(),    # alias -> list(score, hits, joined)
  answers   = list(),    # alias -> list(sel, at, correct, gained)   (current q)
  tally     = list(),    # per-question archive for the final export
  live      = list(),    # alias -> open socket count
  started   = NULL
)

# A phone that locks its screen drops the websocket. Counting open sockets lets
# that student reclaim their alias on reload instead of being shut out.
mark_live <- function(alias, delta) {
  l <- isolate(GAME$live)
  n <- max(0L, (l[[alias]] %||% 0L) + delta)
  l[[alias]] <- n
  GAME$live <- l
  invisible(n)
}

is_live <- function(alias) (isolate(GAME$live)[[alias]] %||% 0L) > 0L

MAX_ALIAS <- 18L

clean_alias <- function(x) {
  x <- x %||% ""
  x <- gsub("[[:cntrl:]]", " ", x)   # a pasted tab is a word break, not nothing
  x <- gsub("\\s+", " ", x)
  substr(trimws(x), 1, MAX_ALIAS)
}

alias_taken <- function(alias) {
  tolower(alias) %in% tolower(names(GAME$players))
}

register_player <- function(alias) {
  p <- GAME$players
  p[[alias]] <- list(score = 0, hits = 0, joined = Sys.time())
  GAME$players <- p
  invisible(TRUE)
}

drop_player <- function(alias) {
  p <- GAME$players; p[[alias]] <- NULL; GAME$players <- p
  a <- GAME$answers; a[[alias]] <- NULL; GAME$answers <- a
  l <- GAME$live;    l[[alias]] <- NULL; GAME$live    <- l
}

current_q <- function() {
  if (is.null(GAME$quiz) || GAME$idx < 1 || GAME$idx > GAME$quiz$n) return(NULL)
  GAME$quiz$questions[[GAME$idx]]
}

# Kahoot-style speed bonus: full marks instantly, half marks at the time limit.
award <- function(is_correct, elapsed, limit, base) {
  if (!isTRUE(is_correct)) return(0)
  if (is.null(limit) || is.na(limit) || limit <= 0) return(round(base))
  round(base * (1 - 0.5 * min(1, elapsed / limit)))
}

submit_answer <- function(alias, sel) {
  q <- current_q()
  if (is.null(q) || GAME$phase != "question" || isTRUE(GAME$locked)) return(FALSE)
  if (!is.null(GAME$answers[[alias]])) return(FALSE)      # one shot per question
  if (length(sel) == 0) return(FALSE)

  elapsed <- as.numeric(difftime(Sys.time(), GAME$opened_at, units = "secs"))
  ok <- setequal(sort(as.integer(sel)), sort(as.integer(q$correct)))
  gained <- award(ok, elapsed, q$time_limit, q$points)

  a <- GAME$answers
  a[[alias]] <- list(sel = as.integer(sel), at = elapsed, correct = ok, gained = gained)
  GAME$answers <- a

  p <- GAME$players
  if (!is.null(p[[alias]])) {
    p[[alias]]$score <- p[[alias]]$score + gained
    p[[alias]]$hits  <- p[[alias]]$hits + as.integer(ok)
    GAME$players <- p
  }
  TRUE
}

# ---- host transitions -------------------------------------------------------

start_quiz <- function(quiz) {
  GAME$quiz      <- quiz
  GAME$quiz_slug <- quiz$slug
  GAME$idx       <- 0L
  GAME$tally     <- list()
  GAME$started   <- Sys.time()
  p <- GAME$players
  for (nm in names(p)) { p[[nm]]$score <- 0; p[[nm]]$hits <- 0 }
  GAME$players <- p
  GAME$phase <- "lobby"
}

open_question <- function(i) {
  if (is.null(GAME$quiz) || i < 1 || i > GAME$quiz$n) return(invisible(FALSE))
  GAME$idx       <- as.integer(i)
  GAME$answers   <- list()
  GAME$opened_at <- Sys.time()
  GAME$locked    <- FALSE
  GAME$phase     <- "question"
  invisible(TRUE)
}

reveal_answer <- function() {
  if (GAME$phase != "question") return(invisible(FALSE))
  q <- current_q()
  GAME$locked <- TRUE
  t <- GAME$tally
  t[[as.character(GAME$idx)]] <- list(
    idx = GAME$idx, prompt = q$prompt, answers = GAME$answers, correct = q$correct
  )
  GAME$tally <- t
  GAME$phase <- "reveal"
  invisible(TRUE)
}

next_question <- function() {
  if (is.null(GAME$quiz)) return(invisible(FALSE))
  if (GAME$idx >= GAME$quiz$n) { GAME$phase <- "final"; return(invisible(TRUE)) }
  open_question(GAME$idx + 1L)
}

show_standings <- function() GAME$phase <- "standings"
finish_quiz    <- function() GAME$phase <- "final"

reset_game <- function(keep_players = FALSE) {
  if (!keep_players) GAME$players <- list()
  else {
    p <- GAME$players
    for (nm in names(p)) { p[[nm]]$score <- 0; p[[nm]]$hits <- 0 }
    GAME$players <- p
  }
  GAME$answers <- list(); GAME$tally <- list()
  GAME$idx <- 0L; GAME$locked <- FALSE; GAME$opened_at <- NULL
  GAME$phase <- "lobby"
}

# ---- derived ----------------------------------------------------------------

leaderboard <- function() {
  p <- GAME$players
  if (length(p) == 0) {
    return(data.frame(alias = character(0), score = numeric(0),
                      hits = numeric(0), rank = integer(0)))
  }
  df <- data.frame(
    alias = names(p),
    score = vapply(p, function(x) as.numeric(x$score), numeric(1)),
    hits  = vapply(p, function(x) as.numeric(x$hits),  numeric(1)),
    stringsAsFactors = FALSE, row.names = NULL
  )
  df <- df[order(-df$score, df$alias), , drop = FALSE]
  # Dense rank, so genuine ties share first place and both get celebrated.
  df$rank <- as.integer(match(df$score, sort(unique(df$score), decreasing = TRUE)))
  df
}

# Count of responses per option for the current question.
distribution <- function() {
  q <- current_q(); if (is.null(q)) return(integer(0))
  counts <- integer(length(q$options))
  for (a in GAME$answers) for (s in a$sel) {
    if (s >= 1 && s <= length(counts)) counts[s] <- counts[s] + 1L
  }
  counts
}

# Long-format results for post-class analysis in R.
results_frame <- function() {
  rows <- list()
  for (key in names(GAME$tally)) {
    tq <- GAME$tally[[key]]
    for (alias in names(tq$answers)) {
      a <- tq$answers[[alias]]
      rows[[length(rows) + 1L]] <- data.frame(
        question   = tq$idx,
        prompt     = tq$prompt,
        alias      = alias,
        selected   = paste(a$sel, collapse = "|"),
        correct_key = paste(tq$correct, collapse = "|"),
        is_correct = a$correct,
        seconds    = round(a$at, 2),
        points     = a$gained,
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(rows) == 0) {
    return(data.frame(question = integer(0), prompt = character(0), alias = character(0),
                      selected = character(0), correct_key = character(0),
                      is_correct = logical(0), seconds = numeric(0), points = numeric(0)))
  }
  do.call(rbind, rows)
}
