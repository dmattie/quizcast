# Quizcast

Live classroom quiz. Students answer on phones, questions go on a projector, the
instructor drives from a laptop. R Shiny in one container on Azure Container
Apps, scaled to zero between classes. Roughly 50 students per session.

User-facing docs are in `README.md`. This file is the working context.

## Commands

| Command | What it does |
|---|---|
| `make test` | Full suite, ~130 checks. Exits non-zero on failure. **Run before claiming a change works.** |
| `make check` | Parse every `.R` file. Fast syntax gate. |
| `make run` | Serve on <http://localhost:8000> with dev keys. |
| `make deps` | Install the four R packages. |
| `make image` | Build the container locally. |
| `./deploy.sh` | Create or update the Azure deployment. |

There is no linter or formatter configured. Don't invent one.

## Layout

```
app.R            UI builders, role dispatch, three server functions
lib/quiz.R       markdown question parsing, quiz folder loading, uploads
lib/state.R      GAME state, scoring, phase transitions, export
www/style.css    all styling
www/quiz.js      response trace, confetti, audio controls
quizzes/<slug>/  quiz.yaml + NN-*.md question files
tests/           zero-dependency suite; helper.R defines ok/eq/shows/hides
```

## Invariants

These are load-bearing. Breaking one produces a failure that only shows up in
front of a room full of people.

1. **One replica, always.** All game state lives in `GAME`, a `reactiveValues`
   created once at startup in `lib/state.R` and shared across every session. A
   second replica would split the leaderboard. `--max-replicas 1` in
   `deploy.sh` is not a tuning knob.

2. **`present_body` must not read `GAME$answers` during the question phase.**
   Doing so makes the projector re-render on every one of 50 incoming answers,
   restarting media and animations mid-question. The live count reaches the
   screen through the `tick` custom message instead. The same reasoning put the
   host's answer counter in its own `renderText` (`admin_live`) rather than
   inside `admin_transport`, so transport buttons don't rebuild under a click.

3. **Keys come from the environment.** `QUIZCAST_ADMIN_KEY` and
   `QUIZCAST_PRESENT_KEY`. Never a literal in source, never rendered into a
   page a student can reach. A wrong key returns the student view silently
   rather than an error, so a guessed URL reveals nothing.

4. **Per-session polling stays off the student path.** The `invalidateLater`
   loop lives only in `present_server`, where exactly one session runs it.
   Student-side timing is a CSS animation. Shiny is single-threaded, so
   anything that makes 50 phones poll is a real cost.

5. **A broken question file degrades one quiz, not the app.** `list_quizzes`
   catches per-folder failures and surfaces them in the admin panel.

6. **An upload is parsed before it is installed.** `install_zip` /
   `install_text` unpack to a staging directory, run `load_quiz` there, and
   only then copy into `QUIZ_DIR`. A refused upload writes nothing, so the
   previous copy of that slug survives. Archive entries are flattened with
   `junkpaths`, which is what makes a `../` entry harmless rather than
   something to sanitise.

7. **A name belongs to the device that took it.** `new_token` mints a token on
   first join, the phone keeps it in `localStorage`, and `may_claim` is the
   single place that decides who may take a name: the token must match, or the
   record must carry no token and nobody be live on it. This is what stops a
   classmate typing "Anne" while Anne's phone is locked and walking off with
   her score — automatic reconnection would otherwise have widened that gap.
   It is not a security boundary: a student who clears storage mid-quiz loses
   their name, and the host's kick control is the manual override.

8. **Aliases are matched case-insensitively but scored by exact name.**
   `canonical_alias` resolves a claim to the spelling already on the roster.
   Skip it and "anne" claiming "Anne" plays against a player record that does
   not exist — `submit_answer` records the answer and silently scores nothing.

## Conventions

- The role split (`play_server` / `present_server` / `admin_server`) exists
  because `MockShinySession` hard-codes `url_search`, so branching on the query
  string inline would make the rendering untestable. Keep them separate.
- Dynamic option buttons are `opt_1` … `opt_12`, with observers created for all
  of `MAX_OPTIONS` up front. Raising the ceiling means raising `MAX_OPTIONS`.
- The quiz library is `CATALOG`, a `reactiveVal` refreshed by
  `refresh_catalog()` after an upload. `start_quiz` copies the quiz into
  `GAME`, so a rescan mid-class cannot disturb a game in progress. The upload
  controls are static in `admin_ui`, not in a `renderUI`, so the catalog
  changing doesn't rebuild a `fileInput` under the host's cursor.
- The locked-in filler degrades in three steps: the question's own `trivia`,
  then a dad joke fetched **by the phone**, then the fallback text the element
  already contains. Nothing about it may touch the server — one blocking HTTP
  call in this single R thread stops all 50 students, and a third-party outage
  would take the lecture with it. `Jokes.scan` caches per question index
  because the student panel re-renders every time anyone else answers.
- Scoring: full points instantly, decaying to half at `time_limit`. The limit
  only affects scoring, never when a question closes. The host closes it.
- Multi-select requires an exact set match. No partial credit, deliberately.
- Ties share a rank, and every player at rank 1 is celebrated.
- CSS uses four channel colours (`--ch1`…`--ch4`) cycled across options. Visual
  identity is a lab instrument panel, not a game show. Don't add gradients or
  rounded pill buttons.

## Gotchas

- Browsers block autoplay. Background music always needs one deliberate click
  on the projector. Don't try to route around this.
- An open websocket keeps the Azure replica alive, so scale-to-zero only
  happens once the projector and admin tabs are closed.
- **Every `addCustomMessageHandler` handler must take exactly one argument.**
  Shiny checks `handler.length !== 1` and throws *during registration*, which
  aborts the rest of the block — so a zero-argument handler silently prevents
  every handler declared after it from ever being registered. That is how a
  no-argument `celebrate` stopped `remember` and `forget` from existing at all.
- **Shiny's client events arrive through jQuery, not the DOM.** `shiny.js`
  fires them as `$(document).trigger({type: "shiny:disconnected"})`, and a
  native `document.addEventListener("shiny:disconnected", ...)` never receives
  a jQuery synthetic event. It fails silently, which cost a deploy to find.
  Use `$(document).on(...)` inside `whenShiny`, which waits for `window.jQuery`
  as well as `window.Shiny`. `visibilitychange` is a real DOM event and is
  fine with `addEventListener`.
- **`shiny:connected` is too early to set an input.** It is triggered inside
  `socket.onopen` *before* Shiny sends its own `init` message, so a
  `setInputValue` there overtakes the handshake and is dropped. Anything that
  hands a value to the server on load belongs on `shiny:sessioninitialized`.
- A phone that sleeps drops its socket, and Shiny then lays
  `#shiny-disconnected-overlay` over the page, which dims it and swallows every
  tap. That overlay is hidden in CSS; `Recover` in `www/quiz.js` reloads
  instead, and the alias comes back from `localStorage` through the `resume`
  input, alongside the device token that makes the reclaim safe.
- `Recover` never reloads a page that isn't visible. A locked phone left in a
  pocket would otherwise wake the container and hold the Azure replica open all
  evening, billing. It also stops auto-reloading after four attempts in a
  minute and waits for a tap, so a room full of phones can't hammer a server
  that is actually down.
- `qrcode` is optional. `qr_svg` returns `NULL` on failure and the lobby falls
  back to showing the URL. Keep it degradable.
- Question files arrive from other people's machines, so `read_question`
  normalises before anything is matched: UTF-16 and windows-1252 are decoded,
  all three line endings are split, `\p{Cf}` (BOM, zero-width) is stripped and
  `\p{Zs}` (non-breaking and other blanks) becomes a plain space. A word
  processor's non-breaking space after the `#` is the classic failure — the
  heading looks perfect and matches nothing. Don't add whitespace handling to
  the individual matchers; fix it in the reader.
- `www/audio/*` is gitignored on purpose: real music is usually licensed and
  does not belong in a public image. A track that plays locally will 404 in
  Azure unless it was force-added or the quiz points at an `https://` URL. The
  projector button says "Track missing" rather than "Blocked" in that case.
- Shiny auto-sources a directory named `R/`. Helpers live in `lib/` and are
  sourced explicitly to avoid double-loading `GAME`.

## When changing things

Adding a question format field means touching `parse_question` in `lib/quiz.R`,
the renderers in `app.R`, and `tests/test-parsing.R`. Adding a phase means
touching `lib/state.R` and all three `render*` bodies, since each switches on
`GAME$phase`.

Tests use no packages beyond the app's own four. Keep it that way; `make test`
should run anywhere the app runs.
