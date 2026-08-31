#!/usr/bin/env bash
# Deploy Quizcast to Azure Container Apps.
#
# The two settings that matter most are at the bottom:
#   --min-replicas 0   costs nothing when nobody is connected
#   --max-replicas 1   game state lives in one R process, so it must never split
#
# Two routes in. By default it builds the image into a private Azure Container
# Registry. Set IMAGE to deploy an already-published public image instead and
# skip the registry entirely, which is the route to take when ACR Tasks is off
# (student, free and sponsored subscriptions) and the GitHub Actions workflow
# is doing the building:
#
#   IMAGE=ghcr.io/dmattie/quizcast:latest LOC=canadacentral ./deploy.sh
#
# Rerun it any time. Everything here is create-or-update.
set -euo pipefail

RG=${RG:-quizcast-rg}
LOC=${LOC:-canadaeast}
ENVNAME=${ENVNAME:-quizcast-env}
ACR=${ACR:-quizcast$RANDOM}          # must be globally unique, lowercase
APP=${APP:-quizcast}
TAG=${TAG:-v1}
IMAGE=${IMAGE:-}                     # set = deploy this image, build nothing

# Set real values before a real class. Anything you can guess, a student can.
ADMIN_KEY=${ADMIN_KEY:-$(openssl rand -hex 12)}
PRESENT_KEY=${PRESENT_KEY:-$(openssl rand -hex 8)}

# A fresh subscription has none of these namespaces switched on, and each one
# fails a different step of this script if it is missing. Registering is
# idempotent and takes a minute or two the first time.
az extension add --name containerapp --upgrade --only-show-errors
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
[ -n "$IMAGE" ] || az provider register --namespace Microsoft.ContainerRegistry --wait

az group create -n "$RG" -l "$LOC" -o none

# --- registry and image ----------------------------------------------------
# "$@" carries the registry credentials into the create below, or nothing at
# all for a public image. Positional parameters rather than an array because
# macOS still ships bash 3.2, where an empty array trips `set -u`.
if [ -n "$IMAGE" ]; then
  echo "Deploying $IMAGE. No registry, no build."
  set --
else
  az acr create -g "$RG" -n "$ACR" --sku Basic --admin-enabled true -o none
  LOGIN=$(az acr show -g "$RG" -n "$ACR" --query loginServer -o tsv)
  ACR_USER=$(az acr credential show -g "$RG" -n "$ACR" --query username -o tsv)
  ACR_PASS=$(az acr credential show -g "$RG" -n "$ACR" --query 'passwords[0].value' -o tsv)
  IMAGE="$LOGIN/$APP:$TAG"

  # The cloud build (ACR Tasks) is switched off on student, free and sponsored
  # subscriptions, so fall back to building here and pushing. --platform is not
  # optional on an Apple Silicon Mac: Container Apps runs linux/amd64, and an
  # arm64 image fails at startup without saying why.
  if ! az acr build -g "$RG" -r "$ACR" -t "$APP:$TAG" . -o none; then
    echo
    echo "  Cloud build unavailable on this subscription. Building locally."
    if ! command -v docker >/dev/null 2>&1; then
      echo "  Docker is needed for the local build; see 'Building without ACR"
      echo "  Tasks' in README.md for the build-on-GitHub route instead." >&2
      exit 1
    fi
    echo "$ACR_PASS" | docker login "$LOGIN" -u "$ACR_USER" --password-stdin
    docker build --platform linux/amd64 -t "$IMAGE" .
    docker push "$IMAGE"
  fi
  set -- --registry-server "$LOGIN" \
         --registry-username "$ACR_USER" \
         --registry-password "$ACR_PASS"
fi

# --- environment -----------------------------------------------------------
az containerapp env create -g "$RG" -n "$ENVNAME" -l "$LOC" -o none

# --- app -------------------------------------------------------------------
# create fails if the app is already there, so update it instead. Rerunning
# this script after a half-finished attempt has to be safe.
if az containerapp show -g "$RG" -n "$APP" -o none 2>/dev/null; then
  echo "App exists; updating it to $IMAGE."
  az containerapp update -g "$RG" -n "$APP" --image "$IMAGE" -o none
  if [ $# -gt 0 ]; then
    az containerapp registry set -g "$RG" -n "$APP" "$@" -o none
  fi
  # Report the keys the app is really using. The randoms generated at the top
  # of this run belong to a first deployment, not to this one.
  ADMIN_KEY=$(az containerapp secret show -g "$RG" -n "$APP" \
                --secret-name adminkey --query value -o tsv 2>/dev/null || echo "$ADMIN_KEY")
  PRESENT_KEY=$(az containerapp secret show -g "$RG" -n "$APP" \
                  --secret-name presentkey --query value -o tsv 2>/dev/null || echo "$PRESENT_KEY")
else
  az containerapp create \
    -g "$RG" -n "$APP" \
    --environment "$ENVNAME" \
    --image "$IMAGE" \
    "$@" \
    --target-port 8000 \
    --ingress external \
    --transport auto \
    --cpu 0.5 --memory 1.0Gi \
    --min-replicas 0 \
    --max-replicas 1 \
    --secrets "adminkey=$ADMIN_KEY" "presentkey=$PRESENT_KEY" \
    --env-vars "QUIZCAST_ADMIN_KEY=secretref:adminkey" \
               "QUIZCAST_PRESENT_KEY=secretref:presentkey" \
    -o none
fi

FQDN=$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)

# Bake the public URL in so the lobby QR code points at the right host.
az containerapp update -g "$RG" -n "$APP" \
  --set-env-vars "QUIZCAST_BASE_URL=https://$FQDN" -o none

cat <<EOF

  Students   https://$FQDN
  Projector  https://$FQDN/?role=present&key=$PRESENT_KEY
  You        https://$FQDN/?role=admin&key=$ADMIN_KEY

  Save those two keys somewhere. Read them back later with:
    az containerapp secret show -g $RG -n $APP --secret-name adminkey

  Add a quiz: drop a zip of the quiz folder on the host page. No redeploy.
  Uploads live in the running container and are cleared by a restart; see
  "Keeping uploads across restarts" in README.md to mount a share instead.

  Ship a code change: push to GitHub if you build there, then rerun this
  script. It updates the running app in place and keeps the URL and keys.

  Cost: scaled to zero between classes, so nothing accrues while idle.
  Close every browser tab afterwards. An open websocket keeps a replica alive.
EOF
