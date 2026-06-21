#!/usr/bin/env bash
# Build the OCI image and load it into podman.
#
# The image bakes config.yaml in via the LONGMONT_CONFIG_YAML env var (which
# the flake reads with builtins.getEnv at eval time). This means:
#   - nix build needs --impure
#   - editing config.yaml triggers a rebuild
#   - the credentials end up in the Nix store (chmod 0600 inside the image,
#     but world-readable in /nix/store as is standard for Nix builds)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config.yaml.example config.yaml" >&2
  exit 1
fi

# Sanity-check the installation ID before we bake it into an image we're
# about to spend minutes building.
INSTALL_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"
if [[ ! "$INSTALL_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ERROR: tidbyt_installation_id must be alphanumeric (a-z, A-Z, 0-9 only)." >&2
  echo "       Current value: ${INSTALL_ID}" >&2
  exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH. Install it on the host (it's not in the dev shell)." >&2
  exit 1
fi

export LONGMONT_CONFIG_YAML="$(cat config.yaml)"

echo "Building OCI image (this may take a few minutes the first time)…"
nix build --impure .#container

echo
echo "Loading image into podman…"
podman load < ./result

echo
echo "Image loaded:"
podman images longmontaq:latest

echo
echo "Next: ./scripts/run-container.sh"
