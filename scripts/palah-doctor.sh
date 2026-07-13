#!/bin/bash
# Checks health of all Palah components and restarts anything unhealthy.
#   - Palah.app       (macOS agent, :45678/health) — killed + relaunched from the
#                       latest Xcode DerivedData build if unresponsive.
#   - palah-relay.js  (:45679/health)              — killed + relaunched as a
#                       detached background process if unresponsive.
#   - openclaw-session-watcher.js                  — spawned internally by Palah.app;
#                       reported only, not restarted directly (restarting Palah.app
#                       brings it back as its child).
#
# Usage: scripts/palah-doctor.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PALAH_PORT=45678
RELAY_PORT=45679
RELAY_JS="$SCRIPT_DIR/palah-relay.js"
RELAY_LOG="/tmp/palah-relay.log"

STATUS=0

is_healthy() {
  local port="$1"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:${port}/health" 2>/dev/null)
  [ "$code" = "200" ]
}

kill_port() {
  local port="$1"
  local pids
  pids=$(lsof -ti "tcp:${port}" 2>/dev/null)
  if [ -n "$pids" ]; then
    echo "  killing stale process(es) on :${port} → $pids"
    kill -9 $pids 2>/dev/null
  fi
}

wait_for_health() {
  local port="$1"
  local timeout="$2"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if is_healthy "$port"; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

echo "== Palah.app (:${PALAH_PORT}) =="
if is_healthy "$PALAH_PORT"; then
  echo "  ok"
else
  echo "  unhealthy — restarting"
  kill_port "$PALAH_PORT"
  pkill -f "Palah.app/Contents/MacOS/Palah" 2>/dev/null

  APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/*/Palah.app" -maxdepth 6 2>/dev/null \
    | while read -r p; do stat -f "%m %N" "$p"; done | sort -rn | head -1 | cut -d' ' -f2-)

  if [ -z "$APP_PATH" ]; then
    echo "  ERROR: no built Palah.app found under Xcode DerivedData — build it in Xcode first"
    STATUS=1
  else
    echo "  launching $APP_PATH"
    open "$APP_PATH"
    if wait_for_health "$PALAH_PORT" 15; then
      echo "  ok (restarted)"
    else
      echo "  ERROR: still unhealthy after restart"
      STATUS=1
    fi
  fi
fi

echo "== palah-relay.js (:${RELAY_PORT}) =="
if is_healthy "$RELAY_PORT"; then
  echo "  ok"
else
  echo "  unhealthy — restarting"
  pkill -f "palah-relay.js" 2>/dev/null
  kill_port "$RELAY_PORT"
  sleep 0.3
  nohup node "$RELAY_JS" > "$RELAY_LOG" 2>&1 &
  disown
  if wait_for_health "$RELAY_PORT" 5; then
    echo "  ok (restarted)"
  else
    echo "  ERROR: still unhealthy after restart — see $RELAY_LOG"
    STATUS=1
  fi
fi

echo "== openclaw-session-watcher.js (child of Palah.app) =="
if pgrep -f "openclaw-session-watcher.js" > /dev/null; then
  echo "  ok"
else
  echo "  WARNING: not running — this is spawned internally by Palah.app on launch;"
  echo "           if Palah.app is healthy above, it should self-heal shortly."
fi

exit $STATUS
