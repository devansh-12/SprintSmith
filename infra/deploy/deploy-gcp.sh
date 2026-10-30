#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${GCP_REGION:-us-central1}"
ZONE="${GCP_ZONE:-us-central1-a}"
VM_NAME="${GCP_VM_NAME:-sprintsmith-backend}"
REPOSITORY="${ARTIFACT_REGISTRY_REPOSITORY:-devpilot-repo}"
TAG="$(git rev-parse --short=12 HEAD)-$(date -u +%Y%m%d%H%M%S)"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}"
if [[ -n "${GCP_IMAGE_TAG:-}" ]]; then
	TAG="$GCP_IMAGE_TAG"
fi

if [[ ! "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
	echo "GCP_IMAGE_TAG contains characters not valid in a Docker tag." >&2
	exit 1
fi

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
	echo "Set GOOGLE_CLOUD_PROJECT or configure a gcloud project." >&2
	exit 1
fi

gcloud compute ssh "$VM_NAME" \
	--project "$PROJECT_ID" \
	--zone "$ZONE" \
	--command='
		set -eu
		test -f /opt/sprintsmith/.env || {
			echo "Missing /opt/sprintsmith/.env on the VM." >&2
			exit 1
		}
		test -w /opt/sprintsmith && test -w /opt/sprintsmith/.env || {
			echo "The SSH user must own /opt/sprintsmith and be able to update its .env; see docs/deployment.md." >&2
			exit 1
		}
		command -v docker >/dev/null || {
			echo "Docker is not installed on the VM." >&2
			exit 1
		}
		docker compose version >/dev/null
		docker info >/dev/null 2>&1 || {
			echo "The SSH user cannot access Docker. Add it to the docker group, reconnect, and retry." >&2
			exit 1
		}'

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
	gcloud builds submit \
		--project "$PROJECT_ID" \
		--config infra/deploy/cloudbuild.yaml \
		--substitutions "_REGION=${REGION},_REPOSITORY=${REPOSITORY},_TAG=${TAG}" \
		.
fi

REMOTE_TMP="$(gcloud compute ssh "$VM_NAME" \
	--project "$PROJECT_ID" \
	--zone "$ZONE" \
	--command='mktemp -d /tmp/sprintsmith-deploy.XXXXXX')"

gcloud compute scp \
	infra/deploy/compose.production.yaml \
	infra/deploy/Caddyfile \
	infra/deploy/prepare-vm-env.py \
	infra/db/init.sql \
	"${VM_NAME}:${REMOTE_TMP}/" \
	--project "$PROJECT_ID" \
	--zone "$ZONE"

gcloud compute ssh "$VM_NAME" \
	--project "$PROJECT_ID" \
	--zone "$ZONE" \
	--command="set -e
		test -f /opt/sprintsmith/.env
		mkdir -p /opt/sprintsmith/infra/deploy /opt/sprintsmith/infra/db
		mv ${REMOTE_TMP}/compose.production.yaml /opt/sprintsmith/infra/deploy/
		mv ${REMOTE_TMP}/Caddyfile /opt/sprintsmith/infra/deploy/
		mv ${REMOTE_TMP}/prepare-vm-env.py /opt/sprintsmith/infra/deploy/
		mv ${REMOTE_TMP}/init.sql /opt/sprintsmith/infra/db/
		chmod 600 /opt/sprintsmith/.env
		python3 /opt/sprintsmith/infra/deploy/prepare-vm-env.py
		sed -i 's#^BACKEND_IMAGE=.*#BACKEND_IMAGE=${REGISTRY}/sprintsmith-backend-core:${TAG}#' /opt/sprintsmith/.env
		sed -i 's#^AI_ENGINE_IMAGE=.*#AI_ENGINE_IMAGE=${REGISTRY}/sprintsmith-ai-engine:${TAG}#' /opt/sprintsmith/.env
		gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet
		cd /opt/sprintsmith
		docker compose --env-file .env -f infra/deploy/compose.production.yaml pull
		docker compose --env-file .env -f infra/deploy/compose.production.yaml up -d
		curl --fail --retry 20 --retry-delay 5 http://localhost:8002/health
		if ! curl --fail --retry 20 --retry-delay 5 https://sprintsmith-api.rajmathuria.me/health; then
			echo 'Local API is healthy, but public HTTPS failed. Point sprintsmith-api.rajmathuria.me to the VM static IP and verify Cloudflare TLS mode is Full (strict).' >&2
			exit 1
		fi
		rmdir ${REMOTE_TMP}"

printf 'Deployed %s to %s\n' "$TAG" "$VM_NAME"
