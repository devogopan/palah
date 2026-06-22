#!/bin/bash
# Palah — Claude Code hook forwarder (observe-only mode)
# Reads JSON event from stdin, POSTs to Palah asynchronously, exits 0 (allow).
# Safe when Palah is down — curl runs in background, Claude Code is never blocked.
#
# BLOCKING MODE: to enable prompt/tool blocking, replace the fire-and-forget
# section below with the sync section that reads Palah's response:
#
#   payload=$(cat)
#   response=$(printf '%s' "$payload" | curl -sS -X POST "http://127.0.0.1:45678/hooks/claude" \
#     -H "Content-Type: application/json" \
#     --data-binary @- \
#     --max-time 2 2>/dev/null)
#   if [ $? -ne 0 ] || [ -z "$response" ]; then
#     exit 0  # fail-open if Palah is down
#   else
#     echo "$response"  # Palah returns {} (allow) or {"decision":"block","reason":"..."}
#     exit 0
#   fi
#
# Also set async:false on the hook entry in settings.json when enabling blocking.

payload=$(cat)

# Fire-and-forget — Palah is observe-only. Remove & for blocking mode (see above).
printf '%s' "$payload" | curl -sS -X POST "http://127.0.0.1:45678/hooks/claude" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  --max-time 2 \
  >/dev/null 2>&1 &

# Exit 0 = allow in Claude Code hooks
exit 0
