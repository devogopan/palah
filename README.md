# Palah

**Endpoint-native AI governance for enterprises.**

Palah is a lightweight macOS menu bar agent that sits silently on every employee's laptop and acts as an intelligent gatekeeper for all AI interactions — intercepting prompts before they are sent to any AI tool.


---

## What it does

- Intercepts text from AI tools (ChatGPT, Claude, Gemini, Copilot) before submission
- Detects PII, secrets, and sensitive content at the endpoint
- Scores prompt quality and flags vague or accidental submissions
- Sends anonymised metadata to a control plane — raw prompts never leave the device

## Status

- [x] Accessibility API proof-of-concept — reads text from focused UI elements across apps
- [ ] AX tree traversal for browser contenteditable (ChatGPT, Claude.ai)
- [ ] Regex engine for PII and secret detection
- [ ] Prompt quality scoring (local SLM)
- [ ] Metrics packager and control plane

## Build & Run

Requires macOS 13+, Xcode 15+.

```bash
git clone git@github.com:devogopan/palah.git
cd palah
xcodebuild -scheme Palah -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Palah-*/Build/Products/Debug/Palah.app
```

Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility).

Logs are written to `/tmp/palah.log`. Watch with:

```bash
tail -f /tmp/palah.log
```

## Architecture

```
macOS Agent (menu bar)
  ├── AccessibilityReader   — polls frontmost app's focused AX element
  ├── RegexEngine           — PII / secret detection (coming)
  └── MetricsPackager       — strips raw prompt, sends metadata (coming)

Control Plane (coming)
  ├── Go API server
  ├── PostgreSQL + ClickHouse
  └── React admin dashboard
```

## Tech Stack

| Layer | Technology |
|---|---|
| App shell | Swift + SwiftUI |
| AX interception | macOS Accessibility API |
| Local inference | CoreML / ONNX (planned) |
| Control plane | Go, PostgreSQL, ClickHouse |
| Admin dashboard | React |
