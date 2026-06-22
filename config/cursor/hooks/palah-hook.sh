#!/bin/bash
# Palah — Cursor hook forwarder (observe-only mode)
# Reads JSON event from stdin, POSTs to Palah asynchronously, returns allow.
#
# BLOCKING MODE: to enable prompt/tool blocking, replace the fire-and-forget
# section below with the sync section that reads Palah's response:
#
#   payload=$(cat)
#   response=$(printf '%s' "$payload" | curl -sS -X POST "http://127.0.0.1:45678/hooks/cursor" \
#     -H "Content-Type: application/json" \
#     --data-binary @- \
#     --max-time 2 2>/dev/null)
#   if [ $? -ne 0 ] || [ -z "$response" ]; then
#     echo '{"permission":"allow"}'   # fail-open if Palah is down
#   else
#     echo "$response"                # Palah returns {"permission":"allow"} or {"permission":"deny",...}
#   fi
#
# Palah blocking response format:
#   {"permission":"deny","user_message":"Blocked: reason","agent_message":"Policy violation"}
# Events that support blocking: preToolUse, beforeShellExecution, beforeMCPExecution,
#                               beforeReadFile, subagentStart

payload=$(cat)

# Fire-and-forget — Palah is observe-only. Remove & for blocking mode (see above).
printf '%s' "$payload" | curl -sS -X POST "http://127.0.0.1:45678/hooks/cursor" \
  -H "Content-Type: application/json" \
  --data-binary @- \
  --max-time 2 \
  >/dev/null 2>&1 &

echo '{"permission":"allow"}'
