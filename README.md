# Quizcast

A self-hosted live quiz for lecture halls. Students answer on their phones, the
questions go on the projector, you drive it from your laptop. R Shiny in a
container, scaled to zero between classes.

## Run it locally

```bash
make deps    # shiny, yaml, commonmark, qrcode
make run     # serves on :8000 and prints all three URLs
make test    # ~130 checks across parsing, scoring, and every rendered view
```

`qrcode` is optional. Without it the lobby shows the join URL on its own.

| Who | URL |
|---|---|
| Students | `http://localhost:8000` |
| Projector | `http://localhost:8000/?role=present&key=dev-screen` |
| You | `http://localhost:8000/?role=admin&key=dev-admin` |

A wrong or missing key silently returns the student view, so a student who
guesses the path finds nothing to indicate they were close.

## Writing questions

A quiz is a folder under `quizzes/`. Files are ordered by filename, so number
them. Everything except the `#` prompt and the options is optional.

```markdown
---
time_limit: 30
points: 1000
media: https://example.org/figure.png
media_alt: "What the figure shows"
---

# Which signal do midbrain dopamine neurons encode?

Optional context paragraph. Takes [links](https://example.org) and *emphasis*.

- [ ] Absolute reward magnitude
- [x] Reward prediction error
- [ ] Movement velocity

> Shown at reveal. Schultz, Dayan & Montague (1997).
```

`- [x]` marks the correct answer. Mark two or more and the question
automatically becomes select-all, scored on exact match. `media` can be any
external URL. Alongside the questions, a `quiz.yaml`:

```yaml
title: "Reward, Risk and the Business Brain"
subtitle: "Week 3"
audio: lobby-loop.mp3     # a file in www/audio/, or a full https:// URL
```

Broken question files are reported in the admin panel by name and reason
instead of taking down the whole app.

Files written elsewhere are normalised on the way in — UTF-16 and Windows
encodings, any line endings, and the invisible characters a word processor
leaves behind, including the non-breaking space after a `#` that makes a
heading look right while matching nothing.

## Adding a quiz without a redeploy

The admin panel has an **Add a quiz** box, so a quiz can go in from a laptop
that has never seen the repo:

- **Zip.** Zip the quiz folder and choose it. The zip's name becomes the slug
  (`Week 3 Synapses.zip` → `week-3-synapses`), the folder inside is flattened,
  and anything that isn't `.md` or `.yaml` is left out.
- **Paste.** Type a title and paste the questions into the box, separated by a
  line of `===`. Same markdown as a question file; `---` stays reserved for the
  frontmatter fence.

Either way the quiz is parsed before it is installed. A quiz that doesn't parse
is refused with the reason on screen and nothing is written, so a bad upload
can't damage the copy already there. Uploading under a slug that already exists
replaces it outright.

Uploads land in `QUIZCAST_QUIZ_DIR`. Unset — the default — that's a temporary
directory inside the running container, which means **uploads are cleared by a
restart**, including the scale-to-zero after class. That is usually what you
want: add the quiz on the day you teach it. To keep them, mount a share and
point the variable at it (see below). Quizzes committed under `quizzes/` are
always there either way.

## Running a class

Open the projector URL on the room machine and the admin URL on your laptop.
Pick a quiz, press **Load quiz**. The projector shows the join URL, a QR code,
and names arriving as students join.

**Start question 1** opens the first question. Answers stay open until you press
**Reveal answer**, which locks them and shows the distribution and explanation.
Then **Next question**, or **Show standings** first. After the last question you
get the podium, with confetti and ties handled: two people on the same score
both place first.

**Download results CSV** gives one row per student per question, with seconds
elapsed and points, ready for `read.csv()`.

Scoring is Kahoot-style: full points for an instant correct answer, decaying to
half points at the time limit. `time_limit` only affects scoring. You still
control when the question closes.

### Background music

Autoplay is blocked in every browser, so the projector has a **Play music**
button in the top right that you click once during setup. Volume is stored per
browser session and survives the re-renders between questions. Drop an mp3 in
`www/audio/` and name it in `quiz.yaml`.

## Deploying

```bash
ADMIN_KEY=... PRESENT_KEY=... ./deploy.sh
```

Builds the image in Azure Container Registry and creates a Container App. Two
flags matter:

- `--min-replicas 0` — nothing accrues while idle, so a forgotten deployment
  doesn't quietly bill you.
- `--max-replicas 1` — **do not raise this.** The entire game lives in one R
  process's memory. A second replica would split the leaderboard in half.

An open websocket counts as active traffic, so close the projector and admin
tabs after class or the replica stays up. Everything scales back on the next
request with a second or two of cold start; load the page once while you're
setting up.

Ship a code change by rebuilding:

```bash
az acr build -g quizcast-rg -r <registry> -t quizcast:v2 .
az containerapp update -g quizcast-rg -n quizcast --image <registry>.azurecr.io/quizcast:v2
```

Quizzes don't need any of that — upload them in the panel.

### Keeping uploads across restarts

Optional. Without it, uploaded quizzes vanish when the replica stops, which is
fine if you upload on the day. To make them stick, mount an Azure Files share
at a path and point `QUIZCAST_QUIZ_DIR` at it:

```bash
RG=quizcast-rg; ENVNAME=quizcast-env; APP=quizcast; SA=quizcaststore$RANDOM

az storage account create -g $RG -n $SA --sku Standard_LRS
KEY=$(az storage account keys list -g $RG -n $SA --query '[0].value' -o tsv)
az storage share-rm create -g $RG --storage-account $SA -n quizzes --quota 1

az containerapp env storage set -g $RG -n $ENVNAME \
  --storage-name quizshare --azure-file-account-name $SA \
  --azure-file-account-key "$KEY" --azure-file-share-name quizzes \
  --access-mode ReadWrite
```

Attaching the volume to the container needs the YAML form, because
`az containerapp update` has no flag for it:

```bash
az containerapp show -g $RG -n $APP -o yaml > app.yaml
```

In `app.yaml`, under `properties.template`, add the volume and mount it, then
set the variable:

```yaml
    volumes:
      - name: quizvol
        storageName: quizshare
        storageType: AzureFile
    containers:
      - name: quizcast
        # ...leave the rest of the container block as it is...
        volumeMounts:
          - volumeName: quizvol
            mountPath: /srv/quizcast/uploads
        env:
          - name: QUIZCAST_QUIZ_DIR
            value: /srv/quizcast/uploads
```

```bash
az containerapp update -g $RG -n $APP --yaml app.yaml
```

The share is then also reachable from the Azure Portal's storage browser, so
quizzes can be dropped in from there instead of the panel. A share costs a few
cents a month.

## Known limits

Shiny handles all sessions in a single R thread. Nothing here blocks for more
than a few milliseconds, so 50 students is well within reach, but that is the
one thing to watch as class size grows. If it ever strains, the fix is to move
answer submission off the reactive path, not to add replicas.

A student whose phone sleeps and drops the websocket can rejoin with the same
alias. The name is only held while a socket is open, which does mean aliases
are reclaimable by anyone who types them, fine for a classroom and not a
security boundary.

## Working on it with Claude Code

`CLAUDE.md` carries the project's invariants and the reasoning behind the
non-obvious ones. `.claude/settings.json` pre-approves the safe commands and
denies `az`, so nothing in a coding session can create billable Azure
resources. Two skills are included: `/new-question` scaffolds a question in the
house format, and `/run-quizcast` records how to launch and verify the app.
