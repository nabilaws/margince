#!/usr/bin/env bash
# Build the api, worker and web images and push them to this stack's registry.
#
#   scripts/build-images.sh local <image_tag> [--arch amd64|arm64] [--push]
#       Builds on this Mac and asks which architecture to build:
#         x86 (amd64)  build-local-amd64.sh: the images Azure Container Apps
#                      runs, pushed to the registry under <image_tag>. Needs
#                      this machine's public IP in operator_ip_allowlist.
#         ARM (arm64)  build-local-arm64.sh: native images for running on the
#                      Mac, loaded locally as margince/<role>:<tag>-arm64
#                      (--push also uploads them as <tag>-arm64). Never used
#                      by the Azure deployment.
#       --arch skips the question (for scripts and CI).
#
#   scripts/build-images.sh cloud <image_tag> [git_ref]
#       Builds on the jumpbox inside the VNet (jumpbox.tf) and pushes over the
#       registry's private endpoint with the VM's managed identity. Starts the
#       VM if it is stopped. Needs the repo cloned once at /opt/margince on the
#       jumpbox (README.md, "Build the images"). git_ref defaults to the tag.
#
# Run from deploy/terraform/azure after `terraform apply`; reads the registry
# and jumpbox names from `terraform output`. <image_tag> must equal
# var.image_tag.
set -euo pipefail

mode="${1:-}"
tag="${2:-}"
if [[ -z "$mode" || -z "$tag" ]]; then
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

tf_out() { terraform output -raw "$1"; }

case "$mode" in
local)
  shift 2
  arch=""
  push=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch) arch="${2:-}"; shift 2 ;;
      --push) push="--push"; shift ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done
  if [[ -z "$arch" ]]; then
    [[ -t 0 ]] || { echo "not interactive: pass --arch amd64 or --arch arm64" >&2; exit 2; }
    echo "Which images do you want to build?"
    echo "  1) x86 (amd64): for Azure Container Apps, pushed to the registry"
    echo "  2) ARM (arm64): for running on this Mac only"
    read -r -p "Choose 1 or 2 [1]: " choice
    case "${choice:-1}" in
      1) arch=amd64 ;;
      2) arch=arm64 ;;
      *) echo "no such choice: $choice" >&2; exit 2 ;;
    esac
  fi
  here="$(cd "$(dirname "$0")" && pwd)"
  case "$arch" in
    amd64|x86|x86_64) exec "$here/build-local-amd64.sh" "$tag" ;;
    arm64|arm|aarch64) exec "$here/build-local-arm64.sh" "$tag" $push ;;
    *) echo "unknown architecture: $arch (amd64 or arm64)" >&2; exit 2 ;;
  esac
  ;;

cloud)
  ref="${3:-$tag}"
  acr_server="$(tf_out acr_login_server)"
  acr_name="$(tf_out acr_name)"
  rg="$(tf_out resource_group_name)"
  vm="$(tf_out jumpbox_name)"
  admin="$(tf_out jumpbox_admin_username)"
  [[ -n "$vm" ]] || { echo "enable_jumpbox is false: no jumpbox to build on" >&2; exit 1; }

  state="$(az vm get-instance-view -g "$rg" -n "$vm" --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)"
  if [[ "$state" != "PowerState/running" ]]; then
    echo "==> starting $vm ($state)"
    az vm start -g "$rg" -n "$vm" --output none
  fi

  # Runs as root through the VM agent, then drops to the admin user who owns
  # the clone and is in the docker group. No SSH or public IP needed.
  echo "==> building $ref as $tag on $vm (this takes several minutes)"
  az vm run-command invoke -g "$rg" -n "$vm" --command-id RunShellScript \
    --parameters "$admin" "$ref" "$tag" "$acr_name" "$acr_server" \
    --scripts '
set -euo pipefail
admin="$1"; ref="$2"; tag="$3"; acr_name="$4"; acr_server="$5"
sudo -u "$admin" -H bash -s -- "$ref" "$tag" "$acr_name" "$acr_server" <<"BUILD"
set -euo pipefail
ref="$1"; tag="$2"; acr_name="$3"; acr_server="$4"
cd /opt/margince
test -d .git || { echo "no clone at /opt/margince: see README, Build the images" >&2; exit 1; }
git fetch --all --tags --prune
git checkout --detach "$ref"
az login --identity --output none
az acr login --name "$acr_name"
for role in api worker web; do
  echo "==> $role"
  docker buildx build --platform linux/amd64 --target "$role" \
    --build-arg "MARGINCE_RELEASE_VERSION=$tag" \
    -t "$acr_server/$role:$tag" --push .
done
BUILD
' --query 'value[].message' -o tsv
  ;;

*)
  echo "unknown mode: $mode (local or cloud)" >&2
  exit 2
  ;;
esac

echo "Pushed api, worker, web as $tag to $acr_server. Set image_tag = \"$tag\" and terraform apply."
