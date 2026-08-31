# ---- tests/test-rendering.R -------------------------------------------------
# Loads app.R into its own environment, then drives each role's server function
# directly. MockShinySession hard-codes url_search, which is why the server is
# split into play_server / present_server / admin_server rather than branching
# on the query string inline.

library(shiny)

Sys.setenv(QUIZCAST_ADMIN_KEY = "test-admin", QUIZCAST_PRESENT_KEY = "test-screen")
.app <- new.env()
sys.source("app.R", envir = .app, keep.source = FALSE)
for (.n in ls(.app, all.names = TRUE)) assign(.n, get(.n, .app), globalenv())

group("Role routing")

eq("admin key admits",        resolve_role(list(role = "admin",   key = "test-admin")),  "admin")
eq("present key admits",      resolve_role(list(role = "present", key = "test-screen")), "present")
eq("wrong admin key falls back",   resolve_role(list(role = "admin",   key = "nope")), "play")
eq("wrong present key falls back", resolve_role(list(role = "present", key = "nope")), "play")
eq("no key falls back",       resolve_role(list(role = "admin")), "play")
eq("bare visit is a player",  resolve_role(list()), "play")
eq("unknown role is a player", resolve_role(list(role = "wizard", key = "test-admin")), "play")

group("Projector")

testServer(present_server, {
  shows("lobby invites a join", output$present_body, "Join from your phone")

  start_quiz(load_quiz("quizzes/demo-neuro"))
  for (a in c("Ada", "Grace", "Alan")) register_player(a)
  session$flushReact()
  shows("lobby lists arrivals", output$present_body, "chip")

  open_question(1L); session$flushReact()
  o <- output$present_body
  shows("shows the prompt",  o, "dopamine")
  shows("shows the options", o, "Reward prediction error")
  shows("has a HUD target for the tick channel", o, 'id="hud"')
  hides("no explanation before reveal", o, "Schultz")
  hides("no distribution before reveal", o, "distfill")

  GAME$opened_at <- Sys.time() - 4
  submit_answer("Ada", 2); submit_answer("Grace", 1); submit_answer("Alan", 2)
  reveal_answer(); session$flushReact()
  o <- output$present_body
  shows("reveal shows the explanation",  o, "Schultz")
  shows("reveal shows the distribution", o, "distfill")
  shows("reveal marks the right option", o, "right")

  show_standings(); session$flushReact()
  shows("standings render bars", output$present_body, "rbarfill")

  open_question(4L); session$flushReact()
  shows("external media renders", output$present_body, "upload.wikimedia.org")

  open_question(3L); session$flushReact()
  shows("five-option question renders", output$present_body, "Cerebellar vermis")

  finish_quiz(); session$flushReact()
  o <- output$present_body
  shows("final standings",  o, "Final standings")
  shows("winner is crowned", o, "crown")
})

group("Student")

testServer(play_server, {
  reset_game(FALSE); start_quiz(load_quiz("quizzes/demo-neuro")); session$flushReact()
  shows("name gate first", output$play_body, "Enter a name")

  session$setInputs(alias = "", join = 1); session$flushReact()
  shows("empty name refused", output$play_body, "Pick a name first")
  eq("nobody registered", length(GAME$players), 0L)

  session$setInputs(alias = "  Ada   Lovelace  ", join = 2); session$flushReact()
  eq("alias normalised on join", names(GAME$players), "Ada Lovelace")
  shows("waiting screen", output$play_body, "Watch the big screen")

  open_question(1L); session$flushReact()
  o <- output$play_body
  shows("timer bar",         o, "timerfill")
  shows("tappable options",  o, "opt ch2")
  shows("prompt on phone too", o, "dopamine")

  session$setInputs(opt_2 = 1); session$flushReact()
  shows("locks after answering", output$play_body, "Locked in")
  hides("options withdrawn once locked", output$play_body, "timerfill")

  reveal_answer(); session$flushReact()
  shows("correct verdict", output$play_body, "verdict hit")

  open_question(2L); session$flushReact()
  session$setInputs(opt_3 = 1); session$flushReact()
  reveal_answer(); session$flushReact()
  shows("wrong verdict", output$play_body, "verdict miss")

  open_question(3L); session$flushReact()
  shows("multi-select instructions", output$play_body, "Select every answer")
  session$setInputs(multi_sel = c("1", "2", "4"), multi_submit = 1); session$flushReact()
  ok("multi answer scored", isTRUE(GAME$answers[["Ada Lovelace"]]$correct))

  finish_quiz(); session$flushReact()
  shows("final screen", output$play_body, "Final. Nice work.")
})

group("Coming back from a locked phone")

testServer(play_server, {
  reset_game(FALSE); start_quiz(load_quiz("quizzes/demo-neuro"))
  register_player("Ada"); mark_live("Ada", +1L)

  # Still holding an open socket: the name is not up for grabs.
  session$setInputs(resume = "Ada"); session$flushReact()
  shows("a live name is not resumable", output$play_body, "Enter a name")

  # The phone slept, so that socket closed.
  mark_live("Ada", -1L)
  session$setInputs(resume = "Ada"); session$flushReact()
  hides("resumed straight past the gate", output$play_body, "Enter a name")
  shows("back under the same name", output$play_body, "Ada")
  eq("no duplicate player", length(GAME$players), 1L)

  # Score and answers survive, because they never lived in the session.
  open_question(1L); GAME$opened_at <- Sys.time() - 1
  session$setInputs(opt_2 = 1); session$flushReact()
  ok("can answer after resuming", isTRUE(GAME$answers[["Ada"]]$correct))
})

testServer(play_server, {
  reset_game(FALSE)
  session$setInputs(resume = "   "); session$flushReact()
  shows("a blank stored name is ignored", output$play_body, "Enter a name")
  eq("and registers nobody", length(GAME$players), 0L)
})

group("Host")

testServer(admin_server, {
  reset_game(FALSE); GAME$quiz <- NULL; session$flushReact()
  shows("quiz selector lists the demo", output$admin_setup, "Reward, Risk")
  shows("prompts to load first", output$admin_transport, "Load a quiz")

  session$setInputs(quiz_pick = "demo-neuro", load_quiz = 1); session$flushReact()
  shows("start control appears", output$admin_transport, "Start question 1")

  session$setInputs(go_first = 1); session$flushReact()
  o <- output$admin_transport
  shows("reveal control", o, "Reveal answer")
  shows("answer key visible to host only", o, "Key: B")

  register_player("Ada"); GAME$opened_at <- Sys.time() - 2
  submit_answer("Ada", 2); session$flushReact()
  eq("live counter", output$admin_live, "1/1 answered")
  shows("roster lists players", output$admin_room, "Ada")

  session$setInputs(go_reveal = 1); session$flushReact()
  shows("advance control", output$admin_transport, "Next question")
  shows("standings control", output$admin_transport, "Show standings")

  session$setInputs(who = "Ada", kick = 1); session$flushReact()
  eq("player removed", length(GAME$players), 0L)

  for (i in 1:6) session$setInputs(go_next = i)
  session$flushReact()
  eq("running off the end is safe", GAME$phase, "final")
})

group("Adding a quiz from the panel")

testServer(admin_server, {
  session$setInputs(paste_title = "Pop Quiz",
                    paste_body = "# Is this live?\n- [x] yes\n- [ ] no",
                    paste_load = 1)
  session$flushReact()
  shows("panel confirms the add", output$upload_status, "Added Pop Quiz")
  shows("new quiz reaches the picker", output$admin_setup, "Pop Quiz")

  session$setInputs(quiz_pick = "pop-quiz", load_quiz = 1); session$flushReact()
  eq("the uploaded quiz can be run", GAME$quiz$title, "Pop Quiz")

  # A quiz already in play is a copy, so a later upload cannot disturb it.
  session$setInputs(paste_title = "Later Quiz",
                    paste_body = "# Another?\n- [x] yes\n- [ ] no",
                    paste_load = 2)
  session$flushReact()
  eq("the running game is untouched", GAME$quiz$title, "Pop Quiz")

  session$setInputs(paste_title = "Broken", paste_body = "# No options here",
                    paste_load = 3)
  session$flushReact()
  shows("a bad paste is explained, not thrown", output$upload_status, "options")
  hides("and never reaches the picker", output$admin_setup, "Broken")
})

unlink(QUIZ_DIR, recursive = TRUE)

group("Secrets stay server-side")

hides("student HTML has no admin key",   as.character(player_ui()), "test-admin")
hides("student HTML has no screen key",  as.character(player_ui()), "test-screen")
hides("projector HTML has no admin key", as.character(present_ui()), "test-admin")
