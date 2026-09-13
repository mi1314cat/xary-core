#!/usr/bin/env bash
set -uo pipefail
PREFIX="${XBD_PREFIX:-/opt/xray-browser-dialer}"
DIST="$PREFIX/xbd-dist"
ENVF="$PREFIX/config/panel.env"
HOST=127.0.0.1; PORT=18090; TOKEN=""
if [ -f "$ENVF" ]; then
  . "$ENVF"
  HOST="${PANEL_HOST:-127.0.0.1}"; PORT="${PANEL_PORT:-18090}"; TOKEN="${PANEL_TOKEN:-}"
fi
export XBD_PREFIX
exec /usr/bin/python3 "$DIST/lib/web/panel.py" --host "$HOST" --port "$PORT" ${TOKEN:+--token "$TOKEN"}
