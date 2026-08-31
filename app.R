# ---- app.R ------------------------------------------------------------------
# Quizcast: a self-hosted live quiz for lecture halls.
#   /                        student, phone
#   /?role=present&key=...   projector
#   /?role=admin&key=...     you

library(shiny)
library(yaml)
library(commonmark)

source("lib/quiz.R")
source("lib/state.R")

ADMIN_KEY   <- Sys.getenv("QUIZCAST_ADMIN_KEY",   "change-me-admin")
PRESENT_KEY <- Sys.getenv("QUIZCAST_PRESENT_KEY", "change-me-screen")
BASE_URL    <- Sys.getenv("QUIZCAST_BASE_URL",    "")
MAX_OPTIONS <- 12L

if (ADMIN_KEY == "change-me-admin") {
  message("!! QUIZCAST_ADMIN_KEY is unset. Set it before you use this in a real class.")
}

# Uploaded quizzes land here. Point QUIZCAST_QUIZ_DIR at a mounted share to
# keep them across restarts; the default lives and dies with the container,
# which is the "upload it at the start of class" model.
QUIZ_DIR   <- Sys.getenv("QUIZCAST_QUIZ_DIR", file.path(tempdir(), "quizcast-quizzes"))
dir.create(QUIZ_DIR, recursive = TRUE, showWarnings = FALSE)
QUIZ_ROOTS <- c("quizzes", QUIZ_DIR)
UPLOADS_OK <- dir.exists(QUIZ_DIR) && file.access(QUIZ_DIR, 2L) == 0L
UPLOADS_KEEP <- nzchar(Sys.getenv("QUIZCAST_QUIZ_DIR"))

.boot <- list_quizzes(QUIZ_ROOTS)
message(sprintf("Quizcast loaded %d quiz folder(s): %s",
                length(.boot), paste(names(.boot), collapse = ", ")))

# The library is reactive so an upload reaches the picker without a restart.
# start_quiz copies the quiz into GAME, so rescanning never disturbs a game
# already in progress.
CATALOG <- reactiveVal(.boot)
refresh_catalog <- function() CATALOG(list_quizzes(QUIZ_ROOTS))

resolve_role <- function(qs) {
  role <- qs$role %||% "play"
  key  <- qs$key  %||% ""
  if (role == "admin"   && identical(key, ADMIN_KEY))   return("admin")
  if (role == "present" && identical(key, PRESENT_KEY)) return("present")
  "play"   # wrong key or no key falls through to the student view, silently
}

# ---- shared head ------------------------------------------------------------
app_head <- function() {
  tags$head(
    tags$meta(name = "viewport",
              content = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"),
    tags$meta(name = "theme-color", content = "#10202B"),
    tags$title("Quizcast"),
    tags$link(rel = "icon", href = "favicon.ico", sizes = "any"),
    tags$link(rel = "preconnect", href = "https://fonts.googleapis.com"),
    tags$link(rel = "preconnect", href = "https://fonts.gstatic.com", crossorigin = NA),
    tags$link(rel = "stylesheet", href = paste0(
      "https://fonts.googleapis.com/css2?",
      "family=IBM+Plex+Sans+Condensed:wght@600;700&",
      "family=IBM+Plex+Sans:wght@400;500;600&",
      "family=IBM+Plex+Mono:wght@400;500;600&display=swap")),
    tags$link(rel = "stylesheet", href = "style.css"),
    tags$script(src = "quiz.js")
  )
}

fmt <- function(x) formatC(round(x), format = "d", big.mark = ",")

# ---- QR ---------------------------------------------------------------------
qr_svg <- function(url, px = 260) {
  out <- try({
    m <- as.matrix(qrcode::qr_code(url))
    n <- nrow(m)
    idx <- which(m, arr.ind = TRUE)
    rects <- sprintf('<rect x="%d" y="%d" width="1" height="1"/>',
                     idx[, "col"] - 1L, idx[, "row"] - 1L)
    HTML(sprintf(
      paste0('<svg viewBox="-2 -2 %d %d" width="%d" height="%d" ',
             'shape-rendering="crispEdges" role="img" aria-label="Join link">',
             '<rect x="-2" y="-2" width="%d" height="%d" fill="#E8E4DB"/>',
             '<g fill="#10202B">%s</g></svg>'),
      n + 4, n + 4, px, px, n + 4, n + 4, paste(rects, collapse = "")))
  }, silent = TRUE)
  if (inherits(out, "try-error")) NULL else out
}

# ---- option rendering -------------------------------------------------------
chan <- function(i) paste0("ch", ((i - 1L) %% 4L) + 1L)
tag_letter <- function(i) LETTERS[i]

# ---- UIs --------------------------------------------------------------------

player_ui <- function() {
  tagList(app_head(),
          div(class = "app play", uiOutput("play_body")))
}

present_ui <- function() {
  tagList(app_head(),
          div(class = "app present",
              uiOutput("present_body"),
              tags$canvas(id = "trace", class = "trace", `aria-hidden` = "true"),
              div(class = "audiobar",
                  tags$button(id = "bgm-toggle", class = "audiobtn",
                              type = "button", "Play music"),
                  tags$input(id = "bgm-vol", class = "vol", type = "range",
                             min = "0", max = "100", value = "35",
                             `aria-label` = "Music volume"),
                  uiOutput("audio_el"))))
}

admin_ui <- function() {
  tagList(app_head(),
          div(class = "app admin",
              div(class = "adminwrap",
                  div(class = "panel",
                      div(class = "eyebrow", "Quizcast control"),
                      uiOutput("admin_setup")),
                  div(class = "panel",
                      div(class = "eyebrow", "Transport"),
                      uiOutput("admin_transport")),
                  div(class = "panel",
                      div(class = "eyebrow", "Add a quiz"),
                      admin_add()),
                  div(class = "panel",
                      div(class = "eyebrow", "Room"),
                      uiOutput("admin_room")))))
}

# Static, deliberately: rebuilding a fileInput under the host's cursor loses
# whatever they were part-way through choosing.
admin_add <- function() {
  if (!UPLOADS_OK)
    return(div(class = "warn",
               sprintf("%s is not writable, so uploads are off.", QUIZ_DIR)))
  tagList(
    fileInput("quiz_zip", "Zip of a quiz folder", accept = c(".zip", "application/zip")),
    div(class = "hint", "Or paste questions below, separated by a line of ==="),
    textInput("paste_title", "Quiz title", placeholder = "Week 3 - Synapses"),
    textAreaInput("paste_body", NULL, rows = 6,
                  placeholder = "# First question?\n- [ ] no\n- [x] yes\n===\n# Second question?"),
    div(class = "ctlrow",
        actionButton("paste_load", "Add pasted quiz", class = "ctl"),
        actionButton("rescan", "Rescan", class = "ctl quiet")),
    uiOutput("upload_status"),
    if (!UPLOADS_KEEP)
      div(class = "hint",
          "Uploads live in this container. A restart clears them, so add the quiz on the day."))
}

ui <- function(req) {
  switch(resolve_role(parseQueryString(req$QUERY_STRING)),
         admin   = admin_ui(),
         present = present_ui(),
         player_ui())
}

# ---- server -----------------------------------------------------------------
# One function per role. Keeping them separate means each can be driven
# directly in tests without faking a query string.

join_url_of <- function(session) reactive({
  if (nzchar(BASE_URL)) return(BASE_URL)
  cd <- session$clientData
  port <- if (!is.null(cd$url_port) && nzchar(cd$url_port) &&
              !cd$url_port %in% c("80", "443")) paste0(":", cd$url_port) else ""
  paste0(cd$url_protocol, "//", cd$url_hostname, port, cd$url_pathname)
})

# ======================= STUDENT ============================================
play_server <- function(input, output, session) {
  {
    me <- reactiveVal(NULL)
    notice <- reactiveVal("")

    # The phone's device token, set from localStorage once the session is up.
    dev_token <- function() {
      t <- input$devtoken
      if (is.null(t)) "" else as.character(t)[1]
    }

    adopt <- function(a, tok) {
      a <- canonical_alias(a)
      if (!nzchar(tok)) tok <- new_token()
      if (!alias_taken(a)) register_player(a, tok) else claim_token(a, tok)
      mark_live(a, +1L)
      me(a)
      notice("")
      # The phone keeps the name and the token, so a reload after a screen lock
      # lands back in the game instead of at the name gate.
      session$sendCustomMessage("remember", list(alias = a, token = tok))
      session$onSessionEnded(function() mark_live(a, -1L))
    }

    observeEvent(input$join, {
      a <- clean_alias(input$alias)
      tok <- dev_token()
      if (!nzchar(a)) {
        notice("Pick a name first.")
      } else if (!may_claim(a, tok)) {
        notice(if (is_live(canonical_alias(a)))
                 "Someone in this room is already using that name."
               else sprintf("That name is taken. Try \"%s\".", suggest_alias(a)))
      } else {
        adopt(a, tok)
      }
    })

    # A phone that slept dropped its socket, so the page reloads itself and
    # offers its stored name and token back. The token is what separates
    # rejoining from taking over: without a match this is somebody else's name
    # and the phone is told to forget it.
    observeEvent(input$resume, {
      r <- input$resume
      a <- clean_alias(if (is.list(r)) r$alias else r)
      tok <- if (is.list(r)) as.character(r$token %||% "") else ""
      req(nzchar(a), is.null(me()))
      if (!may_claim(a, tok)) {
        session$sendCustomMessage("forget", list())
      } else {
        adopt(a, tok)
      }
    })

    lapply(seq_len(MAX_OPTIONS), function(i) {
      observeEvent(input[[paste0("opt_", i)]], {
        req(me())
        submit_answer(me(), i)
      }, ignoreInit = TRUE)
    })

    observeEvent(input$multi_submit, {
      req(me())
      submit_answer(me(), as.integer(input$multi_sel))
    }, ignoreInit = TRUE)

    output$play_body <- renderUI({
      if (is.null(me())) {
        return(div(class = "gate",
          div(class = "gatecard",
            div(class = "wordmark", "Quizcast"),
            p(class = "gatelead", "Enter a name for the leaderboard."),
            tags$input(id = "alias", type = "text", class = "aliasinput",
                       maxlength = MAX_ALIAS, autocomplete = "off",
                       autocapitalize = "words", placeholder = "Your name or alias"),
            actionButton("join", "Join", class = "bigbtn"),
            if (nzchar(notice())) div(class = "notice", notice()))))
      }

      alias <- me()
      p <- GAME$players[[alias]]
      score <- if (is.null(p)) 0 else p$score
      bar <- div(class = "playbar",
                 span(class = "who", alias),
                 span(class = "score mono", fmt(score)))

      if (GAME$phase %in% c("lobby", "standings")) {
        board <- leaderboard()
        mine <- board[board$alias == alias, , drop = FALSE]
        return(tagList(bar, div(class = "wait",
          if (GAME$phase == "lobby")
            tagList(div(class = "pulse"), p("You're in. Watch the big screen."))
          else
            tagList(
              div(class = "rankbig mono", if (nrow(mine)) paste0("#", mine$rank[1]) else "—"),
              p(class = "ranklead", "of ", length(GAME$players), " playing")))))
      }

      q <- current_q()
      if (is.null(q)) return(tagList(bar, div(class = "wait", p("Standing by."))))
      mine <- GAME$answers[[alias]]

      if (GAME$phase == "reveal") {
        if (is.null(mine)) {
          body <- div(class = "verdict miss",
                      div(class = "verdicttag", "No answer"),
                      p("You didn't lock one in for this question."))
        } else if (isTRUE(mine$correct)) {
          body <- div(class = "verdict hit",
                      div(class = "verdicttag", "Correct"),
                      div(class = "gain mono", paste0("+", fmt(mine$gained))),
                      p(sprintf("%.1f seconds", mine$at)))
        } else {
          body <- div(class = "verdict miss",
                      div(class = "verdicttag", "Not this time"),
                      p("The answer is on the screen."))
        }
        return(tagList(bar, body))
      }

      if (GAME$phase == "final") {
        board <- leaderboard()
        mine_r <- board[board$alias == alias, , drop = FALSE]
        return(tagList(bar, div(class = "wait",
          div(class = "rankbig mono", if (nrow(mine_r)) paste0("#", mine_r$rank[1]) else "—"),
          p(class = "ranklead", "Final. Nice work."))))
      }

      # phase == "question"
      if (!is.null(mine)) {
        picked <- paste(vapply(mine$sel, tag_letter, character(1)), collapse = " + ")
        return(tagList(bar, div(class = "wait",
          div(class = "lockedtag mono", picked),
          p(class = "ranklead", "Locked in."),
          if (nzchar(q$trivia_html))
            div(class = "trivia", HTML(q$trivia_html))
          else
            # No trivia in the file, so the phone goes looking for a joke on
            # its own. That fetch belongs in the browser and never here: one
            # blocking HTTP call in this single R thread would freeze all 50
            # phones. The fallback text is already in place, so a request that
            # is slow, refused or blocked simply leaves it standing.
            div(class = "trivia joke", `data-q` = GAME$idx,
                "Waiting for everyone else\u2026"))))
      }

      elapsed <- as.numeric(difftime(Sys.time(), GAME$opened_at, units = "secs"))
      timer <- div(class = "timer",
                   div(class = "timerfill",
                       style = sprintf("animation-duration:%ss;animation-delay:-%ss;",
                                       q$time_limit, min(elapsed, q$time_limit))))

      opts <- if (q$multi) {
        tagList(
          div(class = "multinote", "Select every answer that applies."),
          checkboxGroupInput("multi_sel", NULL,
                             choiceNames  = lapply(seq_along(q$options), function(i)
                               HTML(paste0("<b>", tag_letter(i), "</b> ", q$options_html[i]))),
                             choiceValues = seq_along(q$options)),
          actionButton("multi_submit", "Lock in", class = "bigbtn"))
      } else {
        div(class = "optgrid",
            lapply(seq_along(q$options), function(i)
              actionButton(paste0("opt_", i), HTML(paste0(
                "<span class='letter mono'>", tag_letter(i), "</span>",
                "<span class='opttext'>", q$options_html[i], "</span>")),
                class = paste("opt", chan(i)))))
      }

      tagList(bar, timer,
              div(class = "qmini", HTML(q$prompt_html)),
              opts)
    })
  }

}

# ======================= PROJECTOR ==========================================
present_server <- function(input, output, session) {
  join_url <- join_url_of(session)
  {
    output$audio_el <- renderUI({
      src <- if (!is.null(GAME$quiz)) GAME$quiz$audio else NULL
      if (is.null(src)) return(NULL)
      if (!grepl("^https?://", src)) src <- file.path("audio", src)
      tags$audio(id = "bgm", src = src, loop = NA, preload = "auto")
    })

    # One session polling twice a second is cheap; 50 phones polling would not be.
    observe({
      invalidateLater(500, session)
      session$sendCustomMessage("tick", list(
        answered = length(GAME$answers),
        phase    = GAME$phase,
        remaining = if (!is.null(GAME$opened_at) && GAME$phase == "question") {
          q <- current_q()
          max(0, round(q$time_limit -
                       as.numeric(difftime(Sys.time(), GAME$opened_at, units = "secs"))))
        } else NA
      ))
    })

    observeEvent(GAME$phase, {
      if (GAME$phase == "final") session$sendCustomMessage("celebrate", list())
    })

    output$present_body <- renderUI({
      if (is.null(GAME$quiz) || GAME$phase == "lobby") {
        url <- join_url()
        board <- names(GAME$players)
        return(div(class = "stage lobbystage",
          div(class = "lobbyleft",
              div(class = "eyebrow", if (is.null(GAME$quiz)) "Standing by" else GAME$quiz$title),
              h1(class = "joinhead", "Join from your phone"),
              div(class = "joinurl mono", url),
              div(class = "counter mono",
                  span(class = "cnum", length(GAME$players)),
                  span(class = "clab", if (length(GAME$players) == 1) "player" else "players"))),
          div(class = "lobbyright", qr_svg(url)),
          div(class = "roster",
              lapply(rev(utils::tail(board, 24)),
                     function(nm) span(class = "chip", nm)))))
      }

      if (GAME$phase == "final") {
        board <- leaderboard()
        winners <- board[board$rank == 1, , drop = FALSE]
        rest <- board[board$rank > 1 & board$rank <= 5, , drop = FALSE]
        return(div(class = "stage finalstage",
          div(class = "eyebrow", "Final standings"),
          div(class = "winners",
              lapply(seq_len(nrow(winners)), function(i)
                div(class = "winner",
                    div(class = "crown", "1"),
                    div(class = "wname", winners$alias[i]),
                    div(class = "wscore mono", fmt(winners$score[i]))))),
          div(class = "restlist",
              lapply(seq_len(nrow(rest)), function(i)
                div(class = "restrow",
                    span(class = "rrank mono", rest$rank[i]),
                    span(class = "rname", rest$alias[i]),
                    span(class = "rscore mono", fmt(rest$score[i])))))))
      }

      if (GAME$phase == "standings") {
        board <- utils::head(leaderboard(), 10)
        top <- if (nrow(board)) max(board$score, 1) else 1
        return(div(class = "stage",
          div(class = "eyebrow", sprintf("After question %d of %d", GAME$idx, GAME$quiz$n)),
          h1(class = "qtext", "Standings"),
          div(class = "boardlist",
              lapply(seq_len(nrow(board)), function(i)
                div(class = "boardrow",
                    span(class = "rrank mono", board$rank[i]),
                    span(class = "rname", board$alias[i]),
                    div(class = "rbar",
                        div(class = "rbarfill",
                            style = sprintf("width:%.1f%%", 100 * board$score[i] / top))),
                    span(class = "rscore mono", fmt(board$score[i])))))))
      }

      q <- current_q(); req(q)
      revealing <- GAME$phase == "reveal"
      # Only touch GAME$answers once they are frozen. Reading it during the
      # question would make this whole stage re-render 50 times, restarting the
      # media and animations under the room's nose. The live count reaches the
      # HUD over the tick channel instead.
      counts <- if (revealing) distribution() else integer(length(q$options))
      top <- max(c(counts, 1))

      div(class = "stage",
        div(class = "stagehead",
            span(class = "eyebrow mono", sprintf("%02d / %02d", GAME$idx, GAME$quiz$n)),
            span(class = "eyebrow", GAME$quiz$title),
            span(class = "eyebrow mono", id = "hud", "")),
        # The prompt column and the media sit side by side when there is media
        # to show, and the prompt runs the full width when there isn't. The
        # class carries that decision so the layout stays in the stylesheet.
        div(class = if (is.null(q$media)) "qzone" else "qzone withmedia",
            div(class = "qmain",
                h1(class = "qtext", HTML(q$prompt_html)),
                if (nzchar(q$context_html))
                  div(class = "qcontext", HTML(q$context_html))),
            if (!is.null(q$media)) div(class = "media",
                                       tags$img(src = q$media, alt = q$media_alt))),
        div(class = "optgrid big",
            lapply(seq_along(q$options), function(i) {
              cls <- paste("opt", chan(i))
              if (revealing) cls <- paste(cls, if (i %in% q$correct) "right" else "wrong")
              div(class = cls,
                  span(class = "letter mono", tag_letter(i)),
                  span(class = "opttext", HTML(q$options_html[i])),
                  if (revealing)
                    div(class = "distbar",
                        div(class = "distfill",
                            style = sprintf("width:%.1f%%", 100 * counts[i] / top)),
                        span(class = "distnum mono", counts[i])))
            })),
        if (revealing && nzchar(q$explain_html))
          div(class = "explain", HTML(q$explain_html)))
    })
  }

}

# ======================= HOST ===============================================
admin_server <- function(input, output, session) {
  {
    upload_note <- reactiveVal(NULL)
    last_added  <- reactiveVal(NULL)

    note_result <- function(res) {
      if (isTRUE(res$ok)) {
        refresh_catalog()
        last_added(res$slug)
        upload_note(list(ok = TRUE,
                         text = sprintf("Added %s - %d question%s.", res$title, res$n,
                                        if (res$n == 1) "" else "s")))
      } else {
        upload_note(list(ok = FALSE, text = res$error))
      }
    }

    output$admin_setup <- renderUI({
      lib <- CATALOG()
      ok <- Filter(function(q) !isTRUE(q$broken), lib)
      broken <- Filter(function(q) isTRUE(q$broken), lib)
      tagList(
        if (length(ok)) {
          tagList(
            selectInput("quiz_pick", "Quiz",
                        choices = setNames(names(ok),
                                           vapply(ok, function(q)
                                             sprintf("%s  (%d questions)", q$title, q$n),
                                             character(1))),
                        selected = last_added()),
            actionButton("load_quiz", "Load quiz", class = "ctl primary"))
        } else div(class = "warn", "No readable quizzes in quizzes/."),
        lapply(broken, function(q)
          div(class = "warn", sprintf("%s could not be read: %s", q$slug, q$error))),
        div(class = "links",
            div(class = "linkrow", span("Projector"),
                tags$code(sprintf("?role=present&key=%s", PRESENT_KEY)))),
        downloadButton("dl", "Download results CSV", class = "ctl"))
    })

    observeEvent(input$load_quiz, {
      q <- CATALOG()[[input$quiz_pick]]
      req(!is.null(q), !isTRUE(q$broken))
      start_quiz(q)
    })

    observeEvent(input$go_first,  open_question(1L))
    observeEvent(input$go_reveal, reveal_answer())
    observeEvent(input$go_next,   next_question())
    observeEvent(input$go_stand,  show_standings())
    observeEvent(input$go_final,  finish_quiz())
    observeEvent(input$go_reset,  reset_game(keep_players = TRUE))
    observeEvent(input$go_clear,  reset_game(keep_players = FALSE))
    observeEvent(input$kick, {
      req(input$who)
      drop_player(input$who)
    })

    # ---- adding a quiz without a redeploy ----
    observeEvent(input$quiz_zip, {
      f <- input$quiz_zip
      req(f, nrow(f) >= 1)
      note_result(install_zip(f$datapath[1], QUIZ_DIR, safe_slug(f$name[1])))
    })

    observeEvent(input$paste_load, {
      body <- input$paste_body %||% ""
      if (!nzchar(trimws(body))) return(upload_note(list(ok = FALSE, text = "Nothing pasted.")))
      title <- trimws(input$paste_title %||% "")
      if (!nzchar(title)) title <- "Pasted quiz"
      note_result(install_text(body, QUIZ_DIR, safe_slug(title), title))
    })

    observeEvent(input$rescan, {
      refresh_catalog()
      upload_note(list(ok = TRUE, text = "Library rescanned."))
    })

    output$upload_status <- renderUI({
      n <- upload_note()
      if (is.null(n)) return(NULL)
      div(class = if (isTRUE(n$ok)) "note" else "warn", n$text)
    })

    output$admin_transport <- renderUI({
      if (is.null(GAME$quiz)) return(div(class = "muted", "Load a quiz to begin."))
      phase <- GAME$phase
      q <- current_q()
      tagList(
        div(class = "statusline",
            span(class = "mono", toupper(phase)),
            span(class = "mono", sprintf("Q %d/%d", GAME$idx, GAME$quiz$n)),
            span(class = "mono", textOutput("admin_live", inline = TRUE))),
        if (!is.null(q)) div(class = "peek", HTML(q$prompt_html)),
        if (!is.null(q)) div(class = "peekkey mono",
                             paste("Key:", paste(vapply(q$correct, tag_letter, character(1)),
                                                 collapse = " + "))),
        div(class = "ctlrow",
            if (phase == "lobby")
              actionButton("go_first", "Start question 1", class = "ctl primary"),
            if (phase == "question")
              actionButton("go_reveal", "Reveal answer", class = "ctl primary"),
            if (phase %in% c("reveal", "standings"))
              actionButton("go_next",
                           if (GAME$idx >= GAME$quiz$n) "Go to results" else "Next question",
                           class = "ctl primary"),
            if (phase == "reveal")
              actionButton("go_stand", "Show standings", class = "ctl"),
            if (phase != "final") actionButton("go_final", "End now", class = "ctl")),
        div(class = "ctlrow",
            actionButton("go_reset", "Restart quiz, keep players", class = "ctl quiet"),
            actionButton("go_clear", "Clear everyone", class = "ctl quiet")))
    })

    output$admin_live <- renderText({
      sprintf("%d/%d answered", length(GAME$answers), length(GAME$players))
    })

    output$admin_room <- renderUI({
      board <- leaderboard()
      tagList(
        if (nrow(board) == 0) div(class = "muted", "Nobody has joined yet."),
        if (nrow(board)) div(class = "rosterlist",
          lapply(seq_len(nrow(board)), function(i)
            div(class = "rosterrow",
                span(class = "mono", board$rank[i]),
                span(board$alias[i]),
                span(class = "mono", fmt(board$score[i]))))),
        if (nrow(board)) tagList(
          selectInput("who", "Remove a player", choices = board$alias),
          actionButton("kick", "Remove", class = "ctl quiet")))
    })

    output$dl <- downloadHandler(
      filename = function() sprintf("quizcast-%s-%s.csv",
                                    GAME$quiz_slug %||% "session",
                                    format(Sys.time(), "%Y%m%d-%H%M")),
      content = function(file) utils::write.csv(results_frame(), file, row.names = FALSE))
  }
}

server <- function(input, output, session) {
  role <- resolve_role(parseQueryString(isolate(session$clientData$url_search)))
  handler <- switch(role, admin = admin_server, present = present_server, play_server)
  handler(input, output, session)
}

shinyApp(ui, server)
