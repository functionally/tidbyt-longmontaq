#!/usr/bin/env bash
# Local browser preview.
#
# Pixlet serve binds to 127.0.0.1 by default, which doesn't work when serving
# from a rootless container. We bind to 0.0.0.0 so a browser on the host (or
# anywhere on the LAN) can reach it via host.containers.internal or the
# machine's hostname.
#
# pixlet v0.34 has two preview surfaces:
#   /         — React SPA. Sub-routes that aren't /, /oauth-callback, or
#               /static/* return 404 from this server.
#   /legacy   — Old preview page. Accepts config as URL query string, so we can
#               pre-fill the AirNow key and skip the schema form entirely.
#
# This script prints both URLs and lets you choose.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config.yaml.example config.yaml" >&2
  exit 1
fi

AIRNOW_API_KEY="$(yq -r '.airnow_api_key' config.yaml)"
if [[ -z "$AIRNOW_API_KEY" || "$AIRNOW_API_KEY" == "null" || "$AIRNOW_API_KEY" == YOUR-* ]]; then
  echo "ERROR: airnow_api_key not set in config.yaml" >&2
  exit 1
fi

PORT="${PIXLET_PORT:-8080}"

# Bind address for pixlet. 127.0.0.1 is fine when the browser is on the same
# host. Set PIXLET_HOST=0.0.0.0 to listen on all interfaces (needed when
# pixlet runs in a container and the browser is outside it, or when the
# browser is on a different machine).
HOST="${PIXLET_HOST:-127.0.0.1}"

# Host name the *browser* uses. Default localhost (same-host setup). Override
# with PIXLET_BROWSER_HOST=host.containers.internal (rootless podman),
# PIXLET_BROWSER_HOST=darter.local (LAN), or the machine's IP.
BROWSER_HOST="${PIXLET_BROWSER_HOST:-localhost}"

# URL-encode the AirNow key for the query string.
URL_KEY="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$AIRNOW_API_KEY")"

cat <<EOF

Pixlet serving on ${HOST}:${PORT}. Hot-reloads on main.star changes.

Open ONE of these URLs in your browser:

  Pre-filled preview (recommended):
    http://${BROWSER_HOST}:${PORT}/legacy?airnow_api_key=${URL_KEY}

  Raw rendered frame as WebP:
    http://${BROWSER_HOST}:${PORT}/api/v1/preview.webp?airnow_api_key=${URL_KEY}

  React SPA (schema form — paste the AirNow key manually):
    http://${BROWSER_HOST}:${PORT}/

Ctrl-C to stop.

EOF

exec pixlet serve -i "${HOST}" -p "${PORT}" main.star
