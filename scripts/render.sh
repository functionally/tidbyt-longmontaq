#!/usr/bin/env bash
# Render one frame to out.webp
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

AIRNOW_API_KEY="$(yq -r '.airnow_api_key' config.yaml)"
LAT="$(yq -r '.latitude' config.yaml)"
LON="$(yq -r '.longitude' config.yaml)"
if [[ -z "$AIRNOW_API_KEY" || "$AIRNOW_API_KEY" == "null" || "$AIRNOW_API_KEY" == YOUR-* ]]; then
  echo "ERROR: airnow_api_key not set in config.yaml" >&2
  exit 1
fi

pixlet render main.star \
  "airnow_api_key=${AIRNOW_API_KEY}" \
  "latitude=${LAT}" \
  "longitude=${LON}" \
  -o out.webp
echo "Rendered: $PWD/out.webp"
