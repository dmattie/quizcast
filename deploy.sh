#!/usr/bin/env bash
# Deploy Quizcast to Azure Container Apps.
#
# The two settings that matter most are at the bottom:
#   --min-replicas 0   costs nothing when nobody is connected
#   --max-replicas 1   game state lives in one R process, so it must never split
#
# Run once to create, then rerun `az containerapp update` (last block) to ship
# a new quiz.
set -euo pipefail

RG=${RG:-quizcast-rg}
LOC=${LOC:-canadaeast}
ENVNAME=${ENVNAME:-quizcast-env}
ACR=${ACR:-quizcast$RANDOM}          # must be globally unique, lowercase
APP=${APP:-quizcast}
TAG=${TAG:-v1}

# Set real values before a real class. Anything you can guess, a student can.
ADMIN_KEY=${ADMIN_KEY:-$(openssl rand -hex 12)}
PRESENT_KEY=${PRESENT_KEY:-$(openssl rand -hex 8)}

# A fresh subscription has none of these namespaces switched on, and each one
# fails a different step of this script if it is missing. Registering is
# idempotent and takes a minute or two the first time.
az extension add --name containerapp --upgrade --only-show-errors
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait

az group create -n "$RG" -l "$LOC" -o none

# --- registry --------------------------------------------------------------
az acr create -g "$RG" -n "$ACR" --sku Basic --admin-enabled true -o none
LOGIN=$(az acr show -g "$RG" -n "$ACR" --query loginServer -o tsv)
ACR_USER=$(az acr credential show -g "$RG" -n "$ACR" --query username -o tsv)
ACR_PASS=$(az acr credential show -g "$RG" -n "$ACR" --query 'passwords[0].value' -o tsv)

# --- image -----------------------------------------------------------------
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
  docker build --platform linux/amd64 -t "$LOGIN/$APP:$TAG" .
  docker push "$LOGIN/$APP:$TAG"
fi

# --- environment -----------------------------------------------------------
az containerapp env create -g "$RG" -n "$ENVNAME" -l "$LOC" -o none

# --- app -------------------------------------------------------------------
az containerapp create \
  -g "$RG" -n "$APP" \
  --environment "$ENVNAME" \
  --image "$LOGIN/$APP:$TAG" \
  --registry-server "$LOGIN" \
  --registry-username "$ACR_USER" \
  --registry-password "$ACR_PASS" \
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

  Ship a code change:
    az acr build -g $RG -r $ACR -t $APP:v2 .
    az containerapp update -g $RG -n $APP --image $LOGIN/$APP:v2

  Cost: scaled to zero between classes, so nothing accrues while idle.
  Close every browser tab afterwards. An open websocket keeps a replica alive.
EOF
