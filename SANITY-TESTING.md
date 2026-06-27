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

## Test 1 — AX Capture: Claude Desktop

**App:** Claude for Mac (`/Applications/Claude.app`)

| Step | Action |
|---|---|
| 1 | Open Claude Desktop, click the chat input |
| 2 | Type: `what is the capital of France ?` |
| 3 | Click Send (or press Enter) |

**Expected log entry:**
```json
{
  "event": "submit",
  "source": "ax",
  "app": "Claude",
  "interceptor": "VSCode Family",
  "words": 7,
  "preview": "what is the capital of France ?"
}
```

**Also verify:** type a few chars and delete them with backspace — nothing should log.

**Pass criteria:** entry appears within 1s of clicking Send
**Fail signal:** nothing logged, or `interceptor` is not `VSCode Family`

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

## Scorecard

| # | Method | App | Status | Notes |
|---|---|---|---|---|
| 1 | AX | Claude Desktop | ☐ Pass / ☐ Fail | |
| 2 | AX | VS Code | ☐ Pass / ☐ Fail | |
| 3 | AX | Safari | ☐ Pass / ☐ Fail | |
| 4 | Extension | Chrome (claude.ai) | ☐ Pass / ☐ Fail | |
| 4b | Extension | Chrome (chatgpt.com) | ☐ Pass / ☐ Fail | |
| 4c | Extension | Chrome (perplexity.ai) | ☐ Pass / ☐ Fail | |
| 5 | Cursor hook | Cursor chat | ☐ Pass / ☐ Fail | |
| 6 | Cursor hook | Cursor agent | ☐ Pass / ☐ Fail | |
| 7 | Claude Code hook | claude CLI | ☐ Pass / ☐ Fail | |
| 8 | Claude Code hook | VS Code extension | ☐ Pass / ☐ Fail | |

---

## Known Limitations

| Gap | Reason | Workaround |
|---|---|---|
| GitHub Copilot | No hooks API, no cert-free intercept | Enterprise gateway model only |
| Cursor built-in subscription AI (non-Sonnet) | Same process, no hook for non-API path | AX capture gets the prompt text |
| Short prompts < 3 chars via AX | Filtered to prevent backspace false positives | Hooks capture these correctly |
| AX capture requires app to be frontmost | macOS AX limitation | Hooks cover background sessions |

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
