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
trivia: "Shown to a student who has locked in, while the room catches up."
---

# Which signal do midbrain dopamine neurons encode?

Optional context paragraph. Takes [links](https://example.org) and *emphasis*.

- [ ] Absolute reward magnitude
- [x] Reward prediction error
- [ ] Movement velocity

> Shown at reveal. Schultz, Dayan & Montague (1997).
```

`trivia` is what a student reads on their phone once they've answered and are
waiting for everyone else. Leave it out and the phone fetches a dad joke
instead; if that fails for any reason — offline, campus wifi, a slow API — it
says "Waiting for everyone else…" and nothing is lost. The request is made by
the phone, never by the server, so a slow third party can never hold up the
class. Each phone gets its own joke. To switch jokes off entirely, blank out
`JOKE_URL` at the top of `www/quiz.js`.

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

### Building without ACR Tasks

Student, free and sponsored subscriptions can hold images in a registry but
cannot use ACR Tasks, the cloud-side builder, so `az acr build` fails with
`TasksOperationsNotAllowed`. `deploy.sh` notices and builds locally instead,
which needs Docker running. Two things about that build:

- `--platform linux/amd64` is passed for you and matters on an Apple Silicon
  Mac. Container Apps runs amd64; an arm64 image is accepted by the registry
  and then fails at startup without explaining itself.
- Under emulation the R package layer takes a few minutes the first time. It
  is cached afterwards.

No Docker? `.github/workflows/publish.yml` builds the image on GitHub's
runners and publishes it to GHCR on every push to the default branch. It
builds `linux/amd64`, then starts the published image and waits for it to
serve a page, so a container that builds but doesn't boot fails in CI rather
than in a lecture theatre.

After the first successful run, make the package public — repository →
**Packages** → **quizcast** → **Package settings** → **Change visibility** —
then point the app at it:

```bash
az containerapp update -g quizcast-rg -n quizcast \
  --image ghcr.io/<you>/quizcast:latest
```

A public image needs no registry credentials on the app, which means the ACR
can be deleted along with its ~$5/month. Two caveats. A public image is
readable by anyone, and the image contains `quizzes/` — including the answer
keys; keep the package private (and give the app a PAT as registry
credentials) or keep the graded quizzes out of the image and upload them on
the day. And Container Apps caches by tag, so redeploying `:latest` may want
`--revision-suffix` or an explicit digest to force the pull.

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

A student whose phone sleeps and drops the websocket recovers on its own: the
page reloads when they unlock it and picks their name back up. Their score is
never in the phone — it lives on the server — so a reload costs nothing.

A name belongs to the phone that took it. The first join mints a token the
phone keeps, and only that phone can rejoin under that name, so a classmate
cannot type "Anne" while Anne's screen is locked and inherit her points; they
are refused and offered "Anne 2" instead. This is not a security boundary — a
student who clears their browser can start again under a new name, and one who
clears it mid-quiz loses their score, which is what the host's kick control is
for: drop the name and let them rejoin.

