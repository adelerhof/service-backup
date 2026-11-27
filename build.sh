#!/bin/bash
# Build k8s-backup on the laptop, push it to GHCR (needed for DR: Harbor
# runs inside the cluster) and Harbor (copy), and update the image tag in
# the manifests. Same pattern as service-pss-monitor/build.sh.
set -euo pipefail

GHCR_REGISTRY="ghcr.io/adelerhof"
HARBOR_ADDRESS="harbor.adelerhof.eu"
HARBOR_PROJECT="k8s-backup"
SERVICE_NAME="k8s-backup"
LOCAL_IMAGE="${SERVICE_NAME}-local"

cd "$(dirname "$0")"

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
	echo "❌ Error: Docker and Docker Compose V2 are required."
	exit 1
fi

echo "▶️  Building ${SERVICE_NAME}"
docker compose build --pull k8s-backup

echo "▶️  Smoke test (versions of every tool)"
docker run --rm "${LOCAL_IMAGE}"

TIMESTAMP=$(date +%Y%m%d%H%M%S)
IMAGES=(
	"${GHCR_REGISTRY}/${SERVICE_NAME}:latest"
	"${GHCR_REGISTRY}/${SERVICE_NAME}:${TIMESTAMP}"
	"${HARBOR_ADDRESS}/${HARBOR_PROJECT}/${SERVICE_NAME}:latest"
	"${HARBOR_ADDRESS}/${HARBOR_PROJECT}/${SERVICE_NAME}:${TIMESTAMP}"
)

for image in "${IMAGES[@]}"; do
	docker tag "${LOCAL_IMAGE}" "${image}"
done

echo "🚀 Pushing to GHCR"
docker push "${IMAGES[0]}"
docker push "${IMAGES[1]}"

echo "🚀 Pushing to Harbor"
docker push "${IMAGES[2]}" || echo "⚠️  WARNING: push of '${IMAGES[2]}' to Harbor failed."
docker push "${IMAGES[3]}" || echo "⚠️  WARNING: push of '${IMAGES[3]}' to Harbor failed."

# Manifests arrive with chapters 6-8; until then there is nothing to update.
if compgen -G "manifests/*.yaml" >/dev/null; then
	echo "📝 Updating the image tag in manifests/"
	sed -i "s|image: ${GHCR_REGISTRY}/${SERVICE_NAME}:.*|image: ${IMAGES[1]}|" manifests/*.yaml
fi

docker image rm -f "${LOCAL_IMAGE}" "${IMAGES[@]}" >/dev/null 2>&1 || true

echo "🎉 Done: ${IMAGES[1]}"
echo "   Commit and push manifests/ to deploy (once there are manifests)."
