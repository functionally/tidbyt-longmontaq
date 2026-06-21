#!/usr/bin/env bash
# Run the longmontaq daemon.
#
# By default, runs in the foreground (Ctrl-C to stop) so you can see the
# render+push log as it goes. For a backgrounded run, pass --detach.
#
# Environment overrides:
#   PUSH_INTERVAL_S   seconds between pushes (default 600 = 10 min)
#   CONTAINER_NAME    podman container name (default: longmontaq)
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-longmontaq}"
PUSH_INTERVAL_S="${PUSH_INTERVAL_S:-600}"

DETACH=""
RESTART_POLICY="no"
for arg in "$@"; do
  case "$arg" in
    --detach|-d)
      DETACH="--detach"
      RESTART_POLICY="always"
      ;;
    --once)
      # One-shot push (override the loop with a single render+push) — useful
      # for verifying the image works before starting the daemon.
      PUSH_INTERVAL_S=999999999
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      echo "Usage: $0 [--detach|-d] [--once]" >&2
      exit 1
      ;;
  esac
done

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is not on PATH." >&2
  exit 1
fi

if ! podman image exists longmontaq:latest; then
  echo "ERROR: longmontaq:latest is not loaded. Run ./scripts/build-container.sh first." >&2
  exit 1
fi

# Replace any existing container with the same name so re-runs are idempotent.
if podman container exists "$CONTAINER_NAME"; then
  echo "Removing existing container ${CONTAINER_NAME}…"
  podman rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting ${CONTAINER_NAME} (push every ${PUSH_INTERVAL_S}s)…"
exec podman run \
  --name "$CONTAINER_NAME" \
  --rm \
  ${DETACH} \
  --restart="$RESTART_POLICY" \
  -e "PUSH_INTERVAL_S=${PUSH_INTERVAL_S}" \
  longmontaq:latest
