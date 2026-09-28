#!/usr/bin/env bash
# x86 (linux/amd64) images from a Mac, pushed to this stack's registry: the
# only images Azure Container Apps runs ("Linux-based (linux/amd64) container
# images are required", learn.microsoft.com/azure/container-apps/containers).
#
# On Apple silicon this cross-builds: the Dockerfile compiles Go and the SPA on
# the native build platform and only the thin runtime stages run under x86
# emulation. Called by build-images.sh; usage: build-local-amd64.sh <tag>.
# Needs this machine's public IP in operator_ip_allowlist.
set -euo pipefail

tag="$1"
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
acr_server="$(terraform output -raw acr_login_server)"
acr_name="$(terraform output -raw acr_name)"

command -v docker >/dev/null || { echo "docker not found (start Colima: colima start)" >&2; exit 1; }
docker buildx version >/dev/null

# The runtime stages need x86 emulation in the Docker VM. Colima provides it
# with `colima start --vm-type vz --vz-rosetta` (or qemu binfmt).
if ! docker run --rm --platform linux/amd64 alpine:3 true >/dev/null 2>&1; then
  echo "This Docker VM cannot run linux/amd64 containers." >&2
  echo "Restart Colima with emulation: colima stop && colima start --vm-type vz --vz-rosetta" >&2
  exit 1
fi

az acr login --name "$acr_name"
for role in api worker web; do
  echo "==> $role (linux/amd64)"
  docker buildx build \
    --platform linux/amd64 \
    --target "$role" \
    --build-arg "MARGINCE_RELEASE_VERSION=$tag" \
    -t "$acr_server/$role:$tag" \
    -f "$repo_root/Dockerfile" \
    --push \
    "$repo_root"
done

echo "Pushed api, worker, web as $tag to $acr_server. Set image_tag = \"$tag\" and terraform apply."
