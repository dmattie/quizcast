# ---- tests/test-scoring.R ---------------------------------------------------
library(shiny)
source("lib/quiz.R")
source("lib/state.R")

isolate({

group("Aliases")

eq("whitespace collapsed", clean_alias("  Ada   Lovelace  "), "Ada Lovelace")
eq("length capped",        nchar(clean_alias(strrep("x", 40))), 18L)
eq("control chars removed", clean_alias("Ada\tLovelace"), "Ada Lovelace")
register_player("Ada")
ok("case-insensitive collision", alias_taken("ADA"))
ok("unrelated name free",        !alias_taken("Grace"))

group("Rejoin after a dropped socket")

ok("not live before connecting", !is_live("Ada"))
mark_live("Ada", +1L); ok("live while connected", is_live("Ada"))
mark_live("Ada", -1L); ok("free after disconnect", !is_live("Ada"))
mark_live("Ada", -1L); eq("count never goes negative", GAME$live[["Ada"]], 0L)

group("Speed scoring")

eq("instant correct earns full points", award(TRUE,  0, 30, 1000), 1000)
eq("half way costs a quarter",          award(TRUE, 15, 30, 1000),  750)
eq("at the limit earns half",           award(TRUE, 30, 30, 1000),  500)
eq("past the limit floors at half",     award(TRUE, 99, 30, 1000),  500)
eq("wrong answers earn nothing",        award(FALSE, 1, 30, 1000),    0)
eq("no limit means flat points",        award(TRUE, 99,  0, 1000), 1000)

group("Answer submission")

reset_game(FALSE)
start_quiz(load_quiz("quizzes/demo-neuro"))
for (a in c("Ada", "Grace", "Alan")) register_player(a)
open_question(1L)
key <- current_q()$correct

GAME$opened_at <- Sys.time() - 3
ok("correct answer accepted", submit_answer("Ada", key))
ok("second attempt refused",  !submit_answer("Ada", 1))
ok("empty selection refused", !submit_answer("Grace", integer(0)))
submit_answer("Grace", setdiff(1:4, key)[1])
eq("two responses recorded",  length(GAME$answers), 2L)
ok("scorer credits the right player",  GAME$players[["Ada"]]$score > 0)
ok("scorer withholds from the wrong one", GAME$players[["Grace"]]$score == 0)
eq("hit counter tracks accuracy", GAME$players[["Ada"]]$hits, 1)

d <- distribution()
eq("distribution sums to responses", sum(d), 2L)

reveal_answer()
ok("late answers refused after reveal", !submit_answer("Alan", key))
eq("reveal archives the question", length(GAME$tally), 1L)

group("Multi-select needs an exact match")

open_question(3L)
mq <- current_q()
ok("question 3 is multi", mq$multi)
GAME$opened_at <- Sys.time() - 1
submit_answer("Ada",   mq$correct)
submit_answer("Grace", mq$correct[1])
submit_answer("Alan",  c(mq$correct, setdiff(seq_along(mq$options), mq$correct)[1]))
ok("exact set scores",     GAME$answers[["Ada"]]$correct)
ok("partial set does not", !GAME$answers[["Grace"]]$correct)
ok("superset does not",    !GAME$answers[["Alan"]]$correct)
eq("no credit for partial", GAME$answers[["Grace"]]$gained, 0)

group("Phases")

reset_game(TRUE)
eq("reset returns to lobby", GAME$phase, "lobby")
eq("reset keeps players",    length(GAME$players), 3L)
eq("reset zeroes scores",    sum(vapply(GAME$players, function(p) p$score, numeric(1))), 0)

start_quiz(load_quiz("quizzes/demo-neuro"))
open_question(1L);        eq("open sets question phase", GAME$phase, "question")
reveal_answer();          eq("reveal sets reveal phase", GAME$phase, "reveal")
show_standings();         eq("standings phase", GAME$phase, "standings")
next_question();          eq("advances index", GAME$idx, 2L)
ok("advancing clears the previous answers", length(GAME$answers) == 0L)
GAME$idx <- GAME$quiz$n
next_question();          eq("past the last question lands on final", GAME$phase, "final")
ok("out-of-range open refused", !isTRUE(open_question(99L)))

group("Leaderboard and ties")

reset_game(FALSE)
for (a in c("Ada", "Grace", "Alan")) register_player(a)
p <- GAME$players
p[["Ada"]]$score <- 900; p[["Grace"]]$score <- 900; p[["Alan"]]$score <- 100
GAME$players <- p
b <- leaderboard()
eq("tied players share first place", sum(b$rank == 1), 2L)
eq("next player ranks second",       b$rank[b$alias == "Alan"], 2L)
ok("sorted by score",                b$score[1] >= b$score[nrow(b)])

drop_player("Alan")
eq("removed player gone from board", nrow(leaderboard()), 2L)
ok("removed player's live count cleared", is.null(GAME$live[["Alan"]]))

eq("empty board is still a data frame", nrow(leaderboard()[0, ]), 0L)

group("Results export")

reset_game(FALSE)
start_quiz(load_quiz("quizzes/demo-neuro"))
register_player("Ada"); register_player("Grace")
open_question(1L); GAME$opened_at <- Sys.time() - 2
submit_answer("Ada", current_q()$correct); submit_answer("Grace", 1)
reveal_answer()
open_question(2L); GAME$opened_at <- Sys.time() - 5
submit_answer("Ada", 1)
reveal_answer()

r <- results_frame()
eq("one row per answer", nrow(r), 3L)
ok("carries the columns needed for analysis",
   all(c("question","prompt","alias","selected","correct_key",
         "is_correct","seconds","points") %in% names(r)))
ok("seconds are plausible", all(r$seconds >= 0 & r$seconds < 60))
ok("correctness is logical", is.logical(r$is_correct))

reset_game(FALSE)
eq("export of an empty session is empty", nrow(results_frame()), 0L)

})
