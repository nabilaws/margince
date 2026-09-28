#!/usr/bin/env bash
# ARM (linux/arm64) images, built natively on Apple silicon, for running and
# testing on the Mac. Azure Container Apps cannot run them, so they are loaded
# into the local Docker image store as margince/<role>:<tag>-arm64 and never
# pushed under the deployable tag.
#
# Called by build-images.sh; usage: build-local-arm64.sh <tag> [--push]
# --push also uploads them to the registry as <role>:<tag>-arm64 (for sharing
# with other ARM machines), which needs operator_ip_allowlist like the x86 path.
set -euo pipefail

tag="$1"
push="${2:-}"
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

command -v docker >/dev/null || { echo "docker not found (start Colima: colima start)" >&2; exit 1; }
docker buildx version >/dev/null

if [[ "$push" == "--push" ]]; then
  acr_server="$(terraform output -raw acr_login_server)"
  az acr login --name "$(terraform output -raw acr_name)"
fi

for role in api worker web; do
  echo "==> $role (linux/arm64)"
  args=(--platform linux/arm64 --target "$role"
    --build-arg "MARGINCE_RELEASE_VERSION=$tag-arm64"
    -t "margince/$role:$tag-arm64"
    -f "$repo_root/Dockerfile")
  if [[ "$push" == "--push" ]]; then
    args+=(-t "$acr_server/$role:$tag-arm64" --push)
  else
    args+=(--load)
  fi
  docker buildx build "${args[@]}" "$repo_root"
done

echo "Built margince/{api,worker,web}:$tag-arm64 for local use. These do not run on Azure Container Apps."
