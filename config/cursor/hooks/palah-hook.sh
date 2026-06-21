#!/bin/bash
# Palah — Cursor hook forwarder
# Reads JSON event from stdin, POSTs to Palah asynchronously, returns allow.

payload=$(cat)

# Fire-and-forget to Palah — runs in background so Cursor isn't blocked
printf '%s' "$payload" | curl -sS -X POST "http://127.0.0.1:45678/hooks/cursor" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  --max-time 2 \
  >/dev/null 2>&1 &

# Allow all actions (Palah is monitor-only for now)
echo '{"permission":"allow"}'
