# Palah — Sanity Testing Guide

Run this checklist after every build or config change to confirm all capture methods are working.

---

## Setup

```bash
# 1. Confirm Palah is running (menu bar icon visible)
curl -s http://localhost:45678/health
# Expected: {"status":"ok","server":"palah","port":45678}

# 2. Clear log and start watching
> /tmp/palah.log && tail -f /tmp/palah.log
```

---

## Session Output Layout (classifier input)

Every captured prompt/response is written to a structured session tree. This is the
**input contract for the classifier LLM** (not yet implemented). The classifier will
**watch `/tmp/palah-sessions` for new/modified files** and process each `turn-NNN.ndjson`
as it appears. `/tmp/palah.log` is only a compact human-readable mirror — not the
classifier's source.

### Directory tree

```
/tmp/palah-sessions/
  <yyyy-MM-dd>/                      # e.g. 2026-06-29 — one folder per day
    <app-slug>/                     # capture source, see slug table below
      <session-id>/                 # see session-id format below
        meta.json                   # session-level metadata
        turn-001.ndjson             # full-content events for turn 1 (prompt [+ response] [+ tool chain])
        turn-001-meta.json          # turn-level rollup (tokens, tools, word counts, payload IDs)
        turn-002.ndjson             # turn 2 ...
        turn-002-meta.json
```

> `turn-NNN-meta.json` is finalized when the next turn starts (or the session ends).
> A single-turn browser capture may have only `turn-001.ndjson` until the turn is finalized.

### App slugs (`<app-slug>`)

| Capture source | Slug |
|---|---|
| Claude Code (CLI / VS Code) | `claude-code` |
| Cursor | `cursor` |
| VS Code (AX) | `vscode` |
| Claude Desktop | `claude-desktop` |
| Safari (AX or extension) | `safari` |
| Chrome extension | `chrome-<tool>` (e.g. `chrome-chatgpt`) |
| Web tools (ChatGPT/Claude.ai/Gemini/Perplexity) | `chatgpt` / `claude-ai` / `gemini` / `perplexity` |
| Anything else | lowercased, spaces/dots → `-` |

### Session-id formats

- **Hook sessions** (Claude Code, Cursor): the tool's own UUID — `3ab3770e-9148-4ab3-...`
- **Extension sessions**: datetime stamp — `20260629-125438` (`yyyyMMdd-HHmmss`)
- **AX sessions**: `ax-` + datetime — `ax-20260629-152044`

### `meta.json`

```json
{
  "app": "chrome-ChatGPT",
  "session_id": "20260629-125438",
  "source": "extension:enter",
  "start": "12:54:38",
  "end": "12:59:01",          // added on session close
  "url": "chatgpt.com",       // browser sessions
  "cwd": "/path",             // IDE/hook sessions
  "model": "",
  "turns": 4                  // added on session close
}
```

### `turn-NNN.ndjson` — full content (one JSON object per line)

Prompt event, then optional `ai_response`, then any tool events. **Full untruncated
text lives here** — this is what the classifier scans for PII / secrets / injection.

```json
{"event":"submit","source":"extension:enter","app":"chrome-ChatGPT","session_id":"20260629-125438","payload_id":"55C888A9-...","url":"chatgpt.com","text":"what is this picture about ?","attachments":[{"name":"openclaw.png","type":"png"}],"input_tokens":null,"output_tokens":null,"words":6,"ts":"12:54:38"}
{"event":"ai_response","source":"extension:response","app":"chrome-ChatGPT","session_id":"20260629-125438","payload_id":"37B60709-...","text":"If by \"advocate\" you mean ...","words":320,"ts":"12:54:55"}
```

### `turn-NNN-meta.json` — turn rollup (no raw text)

```json
{
  "turn": 1,
  "prompt_words": 16,
  "tools": [], "tool_count": 0,
  "attachments": [],
  "input_tokens": null, "output_tokens": null,
  "duration_ms_total": 0, "effort": "", "model": "",
  "payload_count": 1,
  "payload_ids": ["14419E0B-..."],   // join key → turn-NNN.ndjson / palah-payloads.ndjson
  "ts_start": "11:11:18", "ts_end": "11:12:01"
}
```

### `payload_id` is the join key

Each event carries a `payload_id` UUID. The same id appears in `turn-NNN.ndjson`,
`turn-NNN-meta.json`, and the compact `/tmp/palah.log` line. The classifier (which reads
`turn-NNN.ndjson` via the file watch above) will write verdicts keyed by `payload_id`, so
the dashboard can join verdicts back to the originating session/turn.

> `/tmp/palah-payloads.ndjson` is a separate flat append-log of full payloads (also keyed
> by `payload_id`). It is **not** the classifier's input under the current design — the
> classifier watches the `/tmp/palah-sessions` tree instead.

### Quick inspect

```bash
# Today's sessions by app
ls /tmp/palah-sessions/$(date +%Y-%m-%d)/

# Newest session's full content
D=$(ls -dt /tmp/palah-sessions/$(date +%Y-%m-%d)/*/*/ | head -1); echo "$D"; cat "$D"turn-*.ndjson
```

---

## Test 1 — AX Capture: Claude Desktop (prompt + response)

**App:** Claude for Mac (`/Applications/Claude.app`)

| Step | Action |
|---|---|
| 1 | Open Claude for Mac, open chat |
| 2 | Type: `what is the capital of france` |
| 3 | Press Enter to send |
| 4 | Wait for the answer to fully render |

**Expected log entries** — a `submit`, then an `ai_response` once Claude finishes:
```json
{"event":"submit","source":"ax","app":"Claude","interceptor":"VSCode Family","role":"AXTextArea"}
{"event":"ai_response","source":"ax","app":"Claude","words":42}
```
Full text lands in `/tmp/palah-sessions/<date>/claude/ax-<timestamp>/turn-001.ndjson`.

> **Status (2026-07-11):** Prompt **and response** capture WORKING.
> - **Prompts** capture via the input `AXTextArea` value.
> - **Responses** capture by scanning the `"Chat messages"` AX container (depth up
>   to 80 — the message text lives ~24+ levels deep) and finalising when Claude's
>   status line flips to `"finished the response"`. Emitted as `ai_response`,
>   the same event other sources use.
> - Capture continues **in the background** — you can switch apps mid-answer.
> - **Not captured:** tool *calls* as structured events. Tool activity only appears
>   as inline text in the response (e.g. `"Searched the web"`); there is no
>   AX-exposed tool_pre/tool_post for Claude Desktop.

**First-prompt-after-cold-launch (transcript reconciliation):** the very first prompt
after fully quitting + reopening Claude can't be read live — Chromium builds its AX
tree lazily and the input value stays frozen at the `"Write a message…"` placeholder
until the first response renders. Palah handles this by **reconciliation**: when it
sees you leave the input (a probable submit) but captured nothing live, it waits for
the answer to render, then recovers the prompt + answer from the transcript and logs
them with `source:"ax-recon"` (deduped against live captures). To verify: quit Claude,
reopen, immediately send a prompt, and **wait for the answer** — an `ax-recon` `submit`
and `ai_response` should appear in `/tmp/palah.log` a few seconds after the answer.

**Backspace test:** type `"lo"` and delete with backspace — no submit should log.

---

## Test 2 — AX Capture: VS Code Claude Extension

**App:** VS Code with Claude Code extension

| Step | Action |
|---|---|
| 1 | Open VS Code, open Claude chat panel |
| 2 | Type: `what does this file do ?` |
| 3 | Press Enter to send |

**Expected log entry:**
```json
{
  "event": "submit",
  "source": "ax",
  "app": "Code",
  "interceptor": "VSCode Family",
  "role": "AXTextArea"
}
```

**Backspace test:** type `"lo"` and delete with backspace — no submit should log.

---

## Test 3 — AX Capture: Safari

**App:** Safari

> This is the **primary, supported** Safari capture path. The Safari Web
> Extension (see Test 9) is parked pending code signing — AX covers Safari today.

| Step | Action |
|---|---|
| 1 | Open Safari, navigate to `claude.ai` |
| 2 | Type: `hello from Safari` |
| 3 | Press Enter to send |

**Expected log entry:**
```json
{
  "event": "submit",
  "source": "ax",
  "app": "Safari",
  "interceptor": "Safari"
}
```

**Note:** only fires when the active page is in the `aiToolDomains` list (claude.ai, chatgpt.com, etc.)

---

## Test 4 — Chrome Extension: Web AI Tools

**App:** Chrome

| Step | Action |
|---|---|
| 1 | Navigate to `claude.ai`, send `"hello from Chrome"` |
| 2 | Navigate to `chatgpt.com`, send any message |
| 3 | Navigate to `perplexity.ai`, send any message |

**Expected log entry (per site):**
```json
{
  "event": "submit",
  "source": "extension:claude.ai",
  "app": "claude.ai"
}
```

**Source pattern:** `extension:<hostname>` (e.g. `extension:chatgpt.com`)

---

## Test 5 — Cursor Hooks: Prompt Capture

**App:** Cursor IDE

| Step | Action |
|---|---|
| 1 | Open Cursor, open a project |
| 2 | Open Cursor chat, type: `explain this codebase` |
| 3 | Press Enter |

**Expected log entry:**
```json
{
  "event": "submit",
  "source": "cursor_hook",
  "app": "Cursor",
  "cursor_version": "x.x.x"
}
```

**Key field to check:** `cursor_version` must be present (confirms common base fields are parsed).

---

## Test 6 — Cursor Hooks: Tool Call Capture

**App:** Cursor IDE (agent mode)

| Step | Action |
|---|---|
| 1 | Switch to Cursor agent mode |
| 2 | Ask: `create a file called test-palah.txt with the text hello world` |
| 3 | Wait for agent to complete |
| 4 | Delete `test-palah.txt` afterward |

**Expected log sequence:**
```
event: tool_pre    tool: <WriteFile or similar>   input: {file_path: "test-palah.txt", ...}
event: tool_post   tool: <WriteFile or similar>
```

**For shell commands** — ask agent to `run ls -la` and check:
```
event: shell_pre   cmd_preview: "ls -la"
event: shell_post  cmd_preview: "ls -la"
```

---

## Test 7 — Claude Code Hooks: Full Session

**App:** Claude Code CLI (terminal)

| Step | Action |
|---|---|
| 1 | Open a terminal, `cd` to any project |
| 2 | Run `claude` to start a session |
| 3 | Ask: `what is in the current directory ?` |
| 4 | Wait for it to run a command and respond |
| 5 | Type `/exit` |

**Expected log sequence:**
```json
{"event": "session_start", "source": "claude_hook", "app": "ClaudeCode", "cwd": "/your/path"}
{"event": "submit",        "source": "claude_hook", "app": "ClaudeCode", "words": 8}
{"event": "tool_pre",      "source": "claude_hook", "app": "ClaudeCode", "tool": "Bash", "input": {"command": "ls ..."}}
{"event": "tool_post",     "source": "claude_hook", "app": "ClaudeCode", "tool": "Bash"}
{"event": "session_end",   "source": "claude_hook", "app": "ClaudeCode"}
```

**Key fields:** `cwd` must match your terminal's working directory. `tool_pre.input.command` must show the exact shell command Claude ran.

---

## Test 8 — Claude Code Hooks: VS Code Extension

**App:** VS Code with Claude Code extension

Same as Test 7, but triggered from the VS Code Claude panel instead of the CLI.

**Note:** Hooks fire from the extension host process. The session should show `cwd` matching the VS Code workspace root.

---

## Test 9 — Safari Web Extension (PARKED — needs code signing)

**Status:** ⏸️ Not active. Code is complete and retained, but blocked by Safari's
unsigned-extension friction. Safari prompt capture is covered by AX (Test 3) today.
Resume this once the extension is signed with an Apple Developer identity.

**What's built (all retained, does not affect other paths):**

| Piece | File | Role |
|---|---|---|
| Content script | `extensions/safari-extension/content.js` | Detects prompt/response in the page, relays via `chrome.runtime.sendMessage` |
| Service worker | `extensions/safari-extension/background.js` | Receives the message, calls `browser.runtime.sendNativeMessage` |
| Manifest | `extensions/safari-extension/manifest.json` | MV3 + `nativeMessaging` permission (the key difference from the Chrome manifest) |
| Native handler | `Palah Safari Extension/Shared (Extension)/SafariWebExtensionHandler.swift` | Receives the native message, `URLSession` POSTs to `localhost:45678/prompt` |
| Entitlements | `macOS (Extension)/Palah_Safari_Extension_Extension.entitlements` | `network.client` so the handler can reach localhost |
| ATS exception | `macOS (Extension)/Info.plist` | Allows the http (non-TLS) localhost POST |

**Relay flow (when signed):**
```
content.js → sendMessage → background.js → sendNativeMessage
  → SafariWebExtensionHandler (native Swift) → URLSession POST :45678/prompt
  → PromptServer /prompt handler (same endpoint Chrome uses)
```
The POST payload is identical to Chrome's (`type: "PROMPT_CAPTURED"`), so captures
appear as `source: "extension:<hostname>"` — same as Test 4.

**Why it's parked:** the build is ad-hoc signed (`Signature=adhoc`, no team). Safari
then hides the real install unless **Develop → Allow Unsigned Extensions** is on, and
that resets every Safari restart. Temporary-extension loading does **not** support
native messaging, so it can't be used as a substitute. A real signing identity removes
all of this.

**To resume / verify once signed:**
```bash
# Watch the native handler directly (works regardless of the JS inspector):
log stream --predicate 'subsystem == "com.devogopan.palah.safari"' --info
```
| Log line | Meaning |
|---|---|
| `PALAH: beginRequest invoked` | native message reached the handler |
| `PALAH: POSTing N bytes ...` → `POST ok, status 200` | full relay working — check `/tmp/palah.log` |
| `PALAH: POST failed: ...` | bridge works, localhost POST blocked (check entitlement/ATS) |
| (nothing) | `sendNativeMessage` not reaching native — extension not installed/signed properly |

---

## Test 11 — OpenClaw: Session Capture

**No install needed.** Palah deploys and starts the watcher automatically on launch.
Verify watcher started:
```bash
cat /tmp/palah-openclaw-watcher.log   # should show "[palah-openclaw] ready"
```

**GitHub skill test (read-only):**
```bash
# Install skill once
mkdir -p /tmp/openclaw-github-skill
curl -sL "https://raw.githubusercontent.com/openclaw/openclaw/main/skills/github/SKILL.md" \
  -o /tmp/openclaw-github-skill/SKILL.md
openclaw skills install /tmp/openclaw-github-skill

# Start gateway (no NODE_OPTIONS needed — watcher handles capture)
openclaw gateway --port 18789 --verbose &

# Send a read-only GitHub prompt
openclaw agent --agent main --message "list the open issues in openclaw/openclaw repo"
```

**Expected session output:**
```bash
D=$(ls -dt /tmp/palah-sessions/$(date +%Y-%m-%d)/openclaw/*/ | head -1)
cat "$D"turn-*.ndjson | python3 -c "import sys,json; [print(o['event'], o.get('words',''), o.get('source','')) for o in [json.loads(l) for l in sys.stdin]]"
# submit   7   openclaw_session
# ai_response  463  openclaw_session:response
```

**What's captured:** user prompt, full AI response text, input/output token counts, OpenClaw session UUID (consistent across multi-turn conversations).
**What's not captured:** individual tool calls inside OpenClaw (e.g. the `gh issue list` invocation) — only the final assistant reply. Tool-level capture requires the OpenClaw plugin SDK.

---

## Test 10 — MCP Tool Capture: GitHub Server

**Claude Code:** Ask `list open PRs in <owner>/<repo>` in a `claude` session.
Check: `grep -o '"tool":"mcp__[^"]*"' /tmp/palah-sessions/$(date +%Y-%m-%d)/claude-code/*/turn-*.ndjson`
Expected: `"tool":"mcp__github__list_pull_requests"` (or similar) in the turn file.

**Cursor:** Ask the same in Cursor agent mode.
Check: `grep -E '"event":"mcp_(pre|post)"' /tmp/palah-sessions/$(date +%Y-%m-%d)/cursor/*/turn-*.ndjson`
Expected: `mcp_pre` / `mcp_post` events with `"mcp_server":"github"`.

---

## Scorecard

| # | Method | App | Status | Notes |
|---|---|---|---|---|
| 1 | AX | Claude Desktop | ✅ Pass | Prompt + response (`ai_response`) captured; first-prompt-after-launch fixed 2026-07-11. Tool calls not captured (activity text only) |
| 2 | AX | VS Code | ☐ Pass / ☐ Fail | |
| 3 | AX | Safari | ☐ Pass / ☐ Fail | |
| 4 | Extension | Chrome (claude.ai) | ☐ Pass / ☐ Fail | |
| 4b | Extension | Chrome (chatgpt.com) | ☐ Pass / ☐ Fail | |
| 4c | Extension | Chrome (perplexity.ai) | ☐ Pass / ☐ Fail | |
| 5 | Cursor hook | Cursor chat | ☐ Pass / ☐ Fail | |
| 6 | Cursor hook | Cursor agent | ☐ Pass / ☐ Fail | |
| 7 | Claude Code hook | claude CLI | ☐ Pass / ☐ Fail | |
| 8 | Claude Code hook | VS Code extension | ☐ Pass / ☐ Fail | |
| 9 | Safari Web Extension | Safari | ⏸️ Parked | Needs code signing; AX (Test 3) covers Safari for now |
| 10a | MCP hook | Claude Code + GitHub MCP | ☐ Pass / ☐ Fail | |
| 10b | MCP hook | Cursor + GitHub MCP | ☐ Pass / ☐ Fail | |
| 11 | Session watcher | OpenClaw (any skill) | ☐ Pass / ☐ Fail | Tool calls not captured, only prompt+response |

---

## Known Limitations

| Gap | Reason | Workaround |
|---|---|---|
| Claude Desktop — tool calls | Electron/Chromium exposes no AX tool_pre/tool_post; tool use only appears as inline activity text (e.g. "Searched the web") | Use Claude Code hooks for structured tool events; AX captures prompt + response text |
| GitHub Copilot | No hooks API, no cert-free intercept | Enterprise gateway model only |
| Cursor built-in subscription AI (non-Sonnet) | Same process, no hook for non-API path | AX capture gets the prompt text |
| Short prompts < 3 chars via AX | Filtered to prevent backspace false positives | Hooks capture these correctly |
| AX prompt capture requires app to be frontmost at submit | macOS AX polls the frontmost app | Response capture then continues in the background (polled by pid); hooks cover fully-background sessions |
| Safari Web Extension (responses, tokens) | Unsigned-extension friction blocks native messaging | AX (Test 3) captures Safari prompts; sign the extension to enable richer capture |

---

## Troubleshooting

**Nothing logging at all:**
```bash
curl http://localhost:45678/health   # Is Palah running?
ls /tmp/palah.log                    # Does log file exist?
```

**AX capture not firing:**
- Check System Settings → Privacy & Security → Accessibility → Palah is listed and enabled
- Palah must be the active (frontmost) app's observer — it polls every 200ms

**Cursor hooks not firing:**
```bash
cat ~/.cursor/hooks.json             # Hooks registered?
ls -la ~/.cursor/hooks/palah-hook.sh # Script exists and is executable?
curl http://localhost:45678/health   # Palah running?
```

**Claude Code hooks not firing:**
```bash
cat ~/.claude/settings.json          # hooks key present?
ls -la ~/.claude/hooks/palah-hook.sh # Script exists and is executable?
```

**Chrome extension not capturing:**
- Check `chrome://extensions` — Palah extension is enabled
- Check the extension has host permissions for the site
- Open DevTools console on the page and look for extension errors

**Safari Web Extension (parked):**
- Safari prompt capture is expected via AX (Test 3), not the extension.
- If resuming the extension: it must be **signed** (ad-hoc/temporary loading
  does not support native messaging). See Test 9 for the `log stream` diagnostic.
