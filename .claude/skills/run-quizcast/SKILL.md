---
name: run-quizcast
description: How to build, launch, and verify Quizcast locally. Use when running the app, checking a change against the running app, or debugging why it won't start.
allowed-tools: Bash(make:*), Bash(Rscript:*)
---

## Prerequisites

R with `shiny`, `yaml`, `commonmark`, and optionally `qrcode`. Install with
`make deps`. Nothing else is needed; there is no npm step and no build step.

## Launch

```bash
make run
```

Serves on port 8000 and prints all three URLs. Override with `make run PORT=8080`.
The app reads `QUIZCAST_ADMIN_KEY` and `QUIZCAST_PRESENT_KEY` from the
environment; `make run` sets `dev-admin` and `dev-screen` for you.

Shiny runs in the foreground and does not daemonize. Start it as a background
task and give it about 10 seconds before the first request. Each shell
invocation is separate, so a server started in one call is gone by the next
unless it is backgrounded and kept alive within the same call.

## The three roles

| Role | URL |
|---|---|
| Student | `http://localhost:8000` |
| Projector | `http://localhost:8000/?role=present&key=dev-screen` |
| Host | `http://localhost:8000/?role=admin&key=dev-admin` |

A wrong key returns the student page. That is intentional, not a bug.

## Verifying a change

Prefer the test suite over the browser. `make test` drives all three role
servers through every phase with `shiny::testServer` and covers parsing,
scoring, transitions, and rendered output.

```bash
make check   # parse gate, about a second
make test    # ~130 checks, exits non-zero on failure
```

Curl only confirms that the shell HTML is served. Everything inside a
`uiOutput` renders over the websocket after the client connects, so `curl` will
not show question text, buttons, or the leaderboard. Their absence from a curl
response means nothing. Use `make test` to check rendered content.

A quick sanity check that the server is up and routing by role:

```bash
for u in "/" "/?role=admin&key=dev-admin"; do
  curl -s -o /dev/null -w "%{http_code} %{size_download}\n" "http://localhost:8000$u"
done
```

Both should return 200. The admin response is larger. If they are the same
size, the key is not reaching the app.

## If it won't start

- `could not find function "%||%"` — `lib/quiz.R` must be sourced before
  `lib/state.R`. Check the `source()` order at the top of `app.R`.
- `no .md question files in ...` — an empty folder under `quizzes/`.
- Port already held by an earlier run: `pkill -f "shiny::runApp"`.
- Startup logs which quiz folders loaded. If a quiz is missing from the admin
  selector, that line will say why.
