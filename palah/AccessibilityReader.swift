//
//  AccessibilityReader.swift
//  Palah
//
//  Created by Gopakumar N on 03/06/26.
//
//  Handles prompt interception for native macOS apps and IDE AI plugins via the
//  Accessibility API. Browser-based AI tools (ChatGPT, Gemini, Claude.ai, etc.)
//  are handled by the Palah Chrome extension (palah-extension/).

import Cocoa
import ApplicationServices

// MARK: - Logging

let logPath = "/tmp/palah.log"

func log(_ message: String) {
    print(message)
    let line = message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logPath),
       let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

// Serialises a dictionary as a single JSON line and appends to the log.
// All capture events use this so downstream tooling gets consistent structure.
func logJSON(_ entry: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys),
          let line = String(data: data, encoding: .utf8) else { return }
    log(line)
}

// Writes a full-content payload to the current session's turn file for the classifier LLM.
// Routes to /tmp/palah-sessions/<session_id>/turn-NNN.ndjson using the session_id already
// present in the entry. Returns a payload_id UUID embedded in the compact palah.log entry.
@discardableResult
func logPayload(_ entry: [String: Any]) -> String {
    let id        = UUID().uuidString
    var full      = entry
    full["payload_id"] = id

    let sessionId = entry["session_id"] as? String ?? ""
    let app       = entry["app"]        as? String ?? "unknown"
    let path: String
    if !sessionId.isEmpty {
        path = sessions.payloadPath(sessionId: sessionId, app: app)
    } else {
        // Fallback: no session_id (should not happen after AX/browser wiring)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let slug = SessionManager.slug(for: app)
        let dir  = "\(sessionBaseDir)/\(slug)"
        sessions.ensureDir(dir)
        path = "\(dir)/ax-\(fmt.string(from: Date())).ndjson"
    }

    guard let data = try? JSONSerialization.data(withJSONObject: full, options: .sortedKeys),
          let line = String(data: data, encoding: .utf8) else { return id }
    let bytes = (line + "\n").data(using: .utf8)!
    if FileManager.default.fileExists(atPath: path),
       let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(bytes); fh.closeFile()
    } else {
        try? bytes.write(to: URL(fileURLWithPath: path))
    }
    return id
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - PromptInterceptor Protocol
//
// To add support for a new native app:
//   1. Create a struct conforming to PromptInterceptor
//   2. Implement canHandle() — return true for the relevant bundle IDs
//   3. Implement read() — return (text, role) for the focused element
//   4. Register it in AccessibilityReader.interceptors before GenericAXInterceptor

// Whether the assistant is still producing its answer. Lets the poller avoid
// finalising during a mid-response pause (e.g. while a web search runs, the
// visible text goes stable for seconds but the answer isn't done).
enum ResponseState {
    case streaming   // assistant still working — do not finalise
    case finished    // assistant done — safe to capture the final text
    case unknown     // no reliable signal — fall back to text-stability heuristic
}

// A per-app description of where the transcript lives and how to tell when the
// assistant has finished. Interceptors return one to opt an app into AX response
// capture; the generic machinery in AccessibilityReader does the scanning, so
// adding a new Electron app is just a new profile — no new traversal code.
struct ResponseProfile {
    var containerDesc:   String? = nil       // AXDescription to scope scanning to (nil = whole window)
    var finishedMarker:  String? = nil       // AXStaticText substring meaning "assistant done"
    var streamingMarker: String? = nil       // AXStaticText substring meaning "assistant still working"
    var chrome:          Set<String> = []    // app-specific non-content strings to drop
    // Turn markers enable transcript reconciliation — recovering a prompt+answer from
    // the built transcript when the live input read was missed (e.g. cold-launch tree
    // not ready). A transcript block starting with userTurnMarker begins a new turn.
    var userTurnMarker:      String? = nil   // e.g. "You said:"
    var assistantTurnMarker: String? = nil   // e.g. "Claude responded:"
}

protocol PromptInterceptor {
    var name: String { get }
    func canHandle(_ app: NSRunningApplication) -> Bool
    func read(from app: NSRunningApplication) -> (text: String?, role: String)
    // Return a profile to enable AX response capture for this app; nil disables it.
    func responseProfile(for app: NSRunningApplication) -> ResponseProfile?
}

extension PromptInterceptor {
    func responseProfile(for app: NSRunningApplication) -> ResponseProfile? { nil }
}

// MARK: - Shared AX Helpers

private func axAppElement(for app: NSRunningApplication) -> AXUIElement {
    AXUIElementCreateApplication(app.processIdentifier)
}

private func focusedElement(in target: AXUIElement) -> AXUIElement? {
    var el: AnyObject?
    guard AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &el) == .success,
          let element = el else { return nil }
    return (element as! AXUIElement)
}

private func role(of el: AXUIElement) -> String {
    var r: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
    return r as? String ?? ""
}

// Reads text from an AX element.
// Tries kAXValueAttribute → kAXSelectedTextAttribute → child traversal.
// Child traversal handles editors that store text in nested AXStaticText children
// (e.g. VS Code chat panels using ProseMirror-style rendering).
private func textFrom(_ el: AXUIElement, depth: Int = 0) -> String? {
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
       let text = value as? String, !text.isEmpty { return text }

    var selected: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success,
       let text = selected as? String, !text.isEmpty { return text }

    guard depth < 5 else { return nil }
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return nil }

    let parts = childList.compactMap { textFrom($0, depth: depth + 1) }
    let joined = parts.joined(separator: "\n")
    return joined.isEmpty ? nil : joined
}

// MARK: - AI Tool Domain List
// Single source of truth — mirrors extensions/chrome-extension/manifest.json host_permissions.
// Add new AI tool domains here AND in the extension manifest to keep both in sync.

let aiToolDomains: Set<String> = [
    "chatgpt.com",
    "claude.ai",
    "gemini.google.com",
    "perplexity.ai",
    "www.perplexity.ai",
    "grok.com",
    "x.com",
    "deepseek.com",
    "chat.deepseek.com",
    "copilot.microsoft.com",
    "www.bing.com",
    "meta.ai",
    "poe.com",
    "you.com",
    "character.ai",
    "mistral.ai",
    "chat.mistral.ai",
    "huggingface.co",
]

// MARK: - Safari
// Uses WebKit's native AX tree — no special activation or extra permissions needed.
// URL-gated via kAXURLAttribute on the AXWebArea element: only reads text when the
// current page hostname is in aiToolDomains. Mirrors Chrome extension domain scoping.

struct SafariInterceptor: PromptInterceptor {
    let name = "Safari"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview"
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)

        var winObj: AnyObject?
        let searchRoot: AXUIElement
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
           let win = winObj { searchRoot = win as! AXUIElement }
        else { searchRoot = appEl }

        guard let webArea = findWebArea(in: searchRoot, depth: 0),
              let host = webAreaHost(webArea),
              aiToolDomains.contains(host) else { return (nil, "") }

        // Read directly from the prompt input element rather than the focused element.
        // This lets us detect the field clearing immediately after submit, even when
        // focus has moved to the response area (AXGroup) or send button (AXButton).
        if let inputEl = findEditableTextArea(in: webArea) {
            return (textFrom(inputEl), "AXTextArea")
        }

        return (nil, "")
    }

    // Searches the web area for the first editable AXTextArea — the prompt input.
    // AI tool pages typically have one editable text area: the prompt input.
    private func findEditableTextArea(in el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var roleObj: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj)
        if (roleObj as? String) == "AXTextArea" {
            var enabled: AnyObject?
            // kAXEnabledAttribute filters out read-only text areas
            if AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enabled) == .success,
               (enabled as? Bool) == true { return el }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return nil }
        for child in childList {
            if let found = findEditableTextArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // Reads kAXURLAttribute from an AXWebArea element.
    private func webAreaHost(_ webArea: AXUIElement) -> String? {
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &obj) == .success,
              let obj else { return nil }
        let urlStr: String?
        if let url = obj as? URL         { urlStr = url.absoluteString }
        else if let url = obj as? NSURL  { urlStr = url.absoluteString }
        else                             { urlStr = obj as? String }
        guard let urlStr, let host = URLComponents(string: urlStr)?.host else { return nil }
        return host
    }

    private func findWebArea(in el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        var roleObj: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj)
        if (roleObj as? String) == "AXWebArea" { return el }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return nil }
        for child in childList {
            if let found = findWebArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

// MARK: - VS Code Family (AI coding assistants)
// Covers: VS Code (Claude, Copilot, Cursor Chat), Cursor, Windsurf, Zed
// All are Electron-based; chat panels expose text via AXTextArea.

private let vscodeFamilyBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.todesktop.230313mzl4w4u92",    // Cursor
    "com.exafunction.windsurf",          // Windsurf
    "dev.zed.zed",                       // Zed
    "com.anthropic.claudefordesktop",   // Claude Desktop (Electron)
    "com.openai.chat",                   // ChatGPT Desktop (Electron)
]

struct VSCodeFamilyInterceptor: PromptInterceptor {
    let name = "VSCode Family"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        vscodeFamilyBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }

    // Response-capture profiles, keyed by bundle ID. Adding a new Electron chat app
    // is just another entry here — the scanning/finalising logic is fully generic.
    // Claude Desktop exposes a "Chat messages" container plus a live status line
    // ("Claude is responding" → "…finished the response") that lets us finalise
    // precisely; other apps get best-effort capture via the stability heuristic.
    func responseProfile(for app: NSRunningApplication) -> ResponseProfile? {
        switch app.bundleIdentifier {
        case "com.anthropic.claudefordesktop":
            return ResponseProfile(
                containerDesc:   "Chat messages",
                finishedMarker:  "finished the response",
                streamingMarker: "Claude is responding",
                chrome: ["You said:", "Claude responded:", "Thought process"],
                userTurnMarker:      "You said:",
                assistantTurnMarker: "Claude responded:")
        case "com.openai.chat":
            // Best-effort, untested: whole-window scan + stability finalisation.
            // Add containerDesc/markers once verified against a live AX dump.
            return ResponseProfile()
        default:
            // Code editors in this family (VS Code, Cursor, Windsurf, Zed) capture
            // tool calls via hooks, not AX — don't scrape their editor as a response.
            return nil
        }
    }
}

// Deep scan for an AXStaticText whose value contains `needle`. Bounded like the
// other transcript scans so it can't stall the poll timer.
private func containsStaticText(_ needle: String, in el: AXUIElement, visited: inout Int, depth: Int = 0) -> Bool {
    guard depth < maxResponseDepth, visited < maxResponseScanNodes else { return false }
    visited += 1
    if role(of: el) == "AXStaticText",
       let v = stringAttr(el, kAXValueAttribute as String), v.contains(needle) {
        return true
    }
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return false }
    for child in childList {
        if containsStaticText(needle, in: child, visited: &visited, depth: depth + 1) { return true }
    }
    return false
}

// MARK: - Native AI Apps
// Covers: Claude Desktop, ChatGPT Desktop, Notion AI, etc.
// Add new native AI apps here by extending the bundle ID list.

private let nativeAIAppBundleIDs: Set<String> = [
    "notion.id",                         // Notion (native, no AXManualAccessibility needed)
]

struct NativeAIAppInterceptor: PromptInterceptor {
    let name = "Native AI"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        nativeAIAppBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }
}

// MARK: - Generic AX Fallback
// Catches anything not handled above: specialist AI tools, Slack AI, legal/medical AI apps, etc.
// This always returns true so it must be last in the registry.

struct GenericAXInterceptor: PromptInterceptor {
    let name = "Generic"

    func canHandle(_ app: NSRunningApplication) -> Bool { true }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }
}

// MARK: - Helpers

// Returns true for empty strings and VS Code-style hint/placeholder text.
// These appear after a submit: "Queue another message…", "⌘ Esc to focus…", etc.
// AX roles that represent editable text inputs. Only these update lastText.
// Responses and containers (AXGroup, AXScrollArea, AXStaticText) are excluded.
private let textInputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

// Known placeholder strings across major AI tools. Add new ones as discovered.
private let knownPlaceholders: Set<String> = [
    "Ask anything",           // ChatGPT
    "Message ChatGPT",        // ChatGPT
    "Reply to Claude...",     // Claude.ai
    "Enter a prompt here",    // Gemini
    "Message Gemini",         // Gemini
    "Ask Perplexity",         // Perplexity
]

private func isPlaceholder(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty || t.hasSuffix("…") || t.contains("⌘") || knownPlaceholders.contains(t)
}

// MARK: - Response Capture Helpers
// Generic AX transcript scanning, driven entirely by a ResponseProfile so the same
// code serves any Electron/native chat app.
//
// Depth cap is 80 (not 25): Electron transcript text lives very deep — in Claude
// Desktop the message nodes sit at AX depth ~24 and their rendered text is several
// levels below that. A shallow cap truncates exactly at the message boundary and
// returns empty, which earlier looked (wrongly) like "the app hides response text."

private let minResponseBlockLength = 12
private let maxResponseScanNodes = 6000
private let maxResponseDepth = 80

// UI chrome present in every profile's transcript that is never message content.
private let universalChromeStrings: Set<String> = [
    "Use the up and down arrow keys to move between messages.",
    "Claude is responding",
    "Claude finished the response",
    "Claude is AI and can make mistakes. Please double-check responses.",
    "Claude is AI and can make mistakes. Please double-check responses",
]

// Returns the app's focused window element, or the app element itself as a fallback.
// Works for background apps: AX focused-window is per-app, independent of system focus.
private func focusedWindow(of appEl: AXUIElement) -> AXUIElement {
    var winObj: AnyObject?
    if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
       let win = winObj { return (win as! AXUIElement) }
    return appEl
}

// Reads transcript text blocks for `profile`, scoped to its container when set.
// Enables Chromium's web-content AX tree first (deep text nodes).
func readTranscriptBlocks(from app: NSRunningApplication, profile: ResponseProfile) -> [String] {
    let appEl = axAppElement(for: app)
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
    let root = focusedWindow(of: appEl)
    let scanRoot = profile.containerDesc.flatMap { findByDescription($0, in: root) } ?? root
    var blocks: [String] = []
    var visited = 0
    collectResponseBlocks(in: scanRoot, depth: 0, visited: &visited, into: &blocks)
    return blocks
}

// A reconstructed conversation turn parsed from the transcript.
struct TranscriptTurn {
    let prompt: String
    let answer: String
}

// Parses transcript blocks into (prompt, answer) turns using the profile's turn
// markers. A block beginning with userTurnMarker starts a new turn; blocks up to the
// next such marker are its content. Within a turn, the prompt is the text after the
// marker; the answer is the remaining content (minus prompt echo, chrome, timestamps).
func parseTranscriptTurns(_ blocks: [String], profile: ResponseProfile) -> [TranscriptTurn] {
    guard let userMark = profile.userTurnMarker else { return [] }
    let chrome = universalChromeStrings.union(profile.chrome)
    let asstMark = profile.assistantTurnMarker

    var turns: [TranscriptTurn] = []
    var curPrompt: String? = nil
    var curAnswer: [String] = []

    func flush() {
        guard let p = curPrompt else { return }
        turns.append(TranscriptTurn(prompt: p, answer: curAnswer.joined(separator: "\n\n")))
        curPrompt = nil; curAnswer = []
    }

    for raw in blocks {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(userMark) {
            flush()
            curPrompt = String(t.dropFirst(userMark.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            continue
        }
        guard curPrompt != nil else { continue }               // preamble before first turn
        if isTranscriptNoise(t) || chrome.contains(t) { continue }
        if t == curPrompt { continue }                          // prompt echoed as its own block
        var line = t
        if let am = asstMark, line.hasPrefix(am) {              // strip "Claude responded:" prefix
            line = String(line.dropFirst(am.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !line.isEmpty { curAnswer.append(line) }
    }
    flush()
    return turns
}

// Reads the assistant's streaming state from the profile's marker strings.
func responseState(of app: NSRunningApplication, profile: ResponseProfile) -> ResponseState {
    guard profile.finishedMarker != nil || profile.streamingMarker != nil else { return .unknown }
    let root = focusedWindow(of: axAppElement(for: app))
    if let fm = profile.finishedMarker {
        var v = 0
        if containsStaticText(fm, in: root, visited: &v) { return .finished }
    }
    if let sm = profile.streamingMarker {
        var v = 0
        if containsStaticText(sm, in: root, visited: &v) { return .streaming }
    }
    return .unknown
}

// True for blocks that are transcript furniture rather than message content:
// relative timestamps ("14 minutes ago", "just now") that update on every read.
private func isTranscriptNoise(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t == "just now" { return true }
    let parts = t.split(separator: " ")
    if parts.count == 3, Int(parts[0]) != nil, parts[2] == "ago",
       ["second","seconds","minute","minutes","hour","hours","day","days"].contains(String(parts[1])) {
        return true
    }
    return false
}

private func collectResponseBlocks(in el: AXUIElement, depth: Int, visited: inout Int,
                                    into blocks: inout [String]) {
    guard depth < maxResponseDepth, visited < maxResponseScanNodes else { return }
    visited += 1

    let r = role(of: el)
    if textInputRoles.contains(r) { return }   // never descend into the prompt input

    if r == "AXStaticText" {
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String, text.count >= minResponseBlockLength {
            blocks.append(text)
        }
    }

    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return }
    for child in childList {
        collectResponseBlocks(in: child, depth: depth + 1, visited: &visited, into: &blocks)
    }
}

// Finds the first descendant whose AXDescription matches `desc` (e.g. "Chat messages").
// Scoping the transcript scan to this container excludes the sidebar chat-history
// list and onboarding cards, which otherwise leak in as false "responses".
private func findByDescription(_ desc: String, in el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < maxResponseDepth else { return nil }
    if stringAttr(el, kAXDescriptionAttribute as String) == desc { return el }
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return nil }
    for child in childList {
        if let found = findByDescription(desc, in: child, depth: depth + 1) { return found }
    }
    return nil
}

// Reads a single string AX attribute (value/description/title/…). Used by the
// container-finder and marker scans.
private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? String
}

// MARK: - AccessibilityReader

class AccessibilityReader {
    // Registry — evaluated top-to-bottom, first match wins.
    // GenericAXInterceptor must stay last.
    private let interceptors: [PromptInterceptor] = [
        VSCodeFamilyInterceptor(),
        SafariInterceptor(),
        NativeAIAppInterceptor(),
        GenericAXInterceptor(),
    ]

    private var lastText = ""
    private var lastCaptured = ""   // last text we actually logged (dedup)
    private var lastAppName = ""
    private var lastRole = ""
    private var lastInputRole = ""  // role when user was last actively typing
    private var wasInInput = false  // was previous tick focused on a text input role?
    private var timer: Timer?

    // Response-capture state. Watching starts on submit and continues in the
    // BACKGROUND — keyed to the app that was submitted to, not the frontmost app —
    // so switching away mid-answer doesn't lose the capture. It ends when the
    // assistant signals finished (or the text stabilises), the watchdog fires, or
    // the watched app quits.
    private var awaitingResponseSessionId = ""
    private var awaitingResponseApp = ""                 // display name, for logging
    private var awaitingResponseRunningApp: NSRunningApplication?  // polled in background
    private var awaitingResponseProfile: ResponseProfile?
    private var awaitingResponsePrompt = ""              // submitted prompt, to strip its echo
    private var baselineBlocks: Set<String> = []         // transcript blocks present at submit
    private var lastResponseText = ""
    private var lastResponseCaptured = ""                // last response text logged (dedup)
    private var responseStablePolls = 0                  // consecutive unchanged polls
    private var responseWatchPolls = 0                   // total polls since watch began

    // Response polling runs at ~1 Hz (every 5th 0.2s tick) rather than 5 Hz — an
    // answer streams over seconds, so 1 Hz is ample and cuts the deep-scan cost 5×.
    private var pollDivider = 0
    private let responsePollEveryNTicks = 5
    private let responseFinishedStability = 2    // polls (~2s) once state == .finished
    private let responseUnknownStability = 4     // polls (~4s) for apps with no finished-signal
    private let responseMaxWatchPolls = 240      // ~240s hard cap, then finalise anyway
    private let minResponseLength = 20

    // Transcript reconciliation — recovers a prompt+answer that the live path missed
    // (e.g. the first prompt after a cold Claude launch, when the AX tree wasn't built
    // and the input value read back empty). Palah isn't a real-time blocker, so
    // capturing the turn a few seconds late — once the answer renders and the tree is
    // fully built — is fine.
    private var capturedPromptKeys: Set<String> = []   // normalised prompts already captured
    private var pendingReconcileApp: NSRunningApplication?
    private var pendingReconcileProfile: ResponseProfile?
    private var pendingReconcileName = ""
    private var pendingReconcilePolls = 0
    private let reconcileMaxPolls = 120                 // ~120s to give up waiting for the answer

    // Normalises a prompt into a dedup key (trim + collapse whitespace + lowercase).
    private func promptKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func start() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        log("[\(timestamp())] Palah started — watching native AI apps and IDE plugins")

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Enable Chromium's accessibility tree early for Electron AI apps, so it's
        // fully built before the user types. Without this, the FIRST prompt after an
        // app (re)launch is missed — the input's AX value stays frozen at the
        // placeholder for several seconds until the tree finishes building.
        // (No-op if permission isn't granted yet; re-run on permission grant below.)
        warmUpElectronAccessibility()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // The app's window isn't rendered the instant it launches, so a single
            // warm-up can miss. Retry across the first ~3s so the tree is force-built
            // before the user clicks in and types their first prompt.
            for delay in [0.0, 0.5, 1.0, 1.5, 2.2, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.enableElectronAccessibility(for: app)
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard AXIsProcessTrusted() else {
                log("[\(timestamp())] waiting for Accessibility permission...")
                return
            }
            // AX calls are no-ops without permission, so the startup warm-up above
            // does nothing when Palah launches unauthorised (e.g. after a tccutil
            // reset). Re-run it the moment permission is first granted, so already-
            // running Electron apps get their tree built before the first prompt.
            if !self.didWarmUpOnTrust {
                self.didWarmUpOnTrust = true
                self.warmUpElectronAccessibility()
            }
            self.tick()
        }
    }

    private var didWarmUpOnTrust = false

    // Sets AXManualAccessibility on every currently-running Electron AI app.
    private func warmUpElectronAccessibility() {
        for app in NSWorkspace.shared.runningApplications {
            enableElectronAccessibility(for: app)
        }
    }

    // Enables AND force-builds Chromium's AX tree for an Electron AI app. Setting
    // AXManualAccessibility only *enables* accessibility; Chromium builds the tree
    // lazily, when something actually reads it. So we also traverse the tree here to
    // force serialization now — otherwise the first prompt after launch races the
    // build and its input value comes back empty/placeholder (text not yet in tree).
    // Called at startup, on permission grant, on app launch, and on switch-to.
    private func enableElectronAccessibility(for app: NSRunningApplication) {
        guard vscodeFamilyBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
        // Read the tree to force the build (result discarded).
        var blocks: [String] = []
        var visited = 0
        collectResponseBlocks(in: focusedWindow(of: appEl), depth: 0, visited: &visited, into: &blocks)
    }

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? "unknown"

        let interceptor = interceptors.first { $0.canHandle(app) }!
        let (text, role) = interceptor.read(from: app)

        if appName != lastAppName {
            log("[\(timestamp())] → \(appName)  [\(interceptor.name)]")
            lastAppName = appName
            lastRole = ""
            lastInputRole = ""
            lastText = ""
            wasInInput = false
            // Force-build the tree on switch-to, covering the case where the window
            // was reopened without a fresh process launch (no didLaunch event).
            enableElectronAccessibility(for: app)
            // NB: response-watch state is intentionally NOT reset here — a response
            // is polled in the background against its own app, so switching focus
            // away (or to another AI app) must not drop the in-flight capture.
        }

        if !role.isEmpty, role != lastRole {
            log("[\(timestamp())]   field: \(role)")
            lastRole = role
        }

        let captured = text ?? ""
        let inInput  = textInputRoles.contains(role)

        // Require at least 3 chars to avoid false submits from backspace (e.g. "l", "lo").
        let hadContent = !isPlaceholder(lastText)
                      && lastText != lastCaptured
                      && lastText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3

        // Submit detection — two patterns:
        // A) Field clears while still focused (VS Code chat, ChatGPT web)
        // B) Focus leaves the input entirely (Claude Desktop: AXTextArea → AXButton → AXWebArea)
        let fieldCleared = inInput  && isPlaceholder(captured)
        let leftInput    = !inInput && wasInInput
        var firedRealtimeSubmit = false
        if hadContent {
            if fieldCleared || leftInput {
                let text  = lastText
                let words = text.split(separator: " ").count
                // Datetime pseudo-session: each AX capture gets a unique session (no app-provided ID).
                // Prefixed "ax-" so AX sessions are visually distinct from hook-based UUID sessions
                // in the same app folder (e.g. cursor/ax-20260629-143200 vs cursor/35c770d6-...).
                let tsFmt = DateFormatter(); tsFmt.dateFormat = "yyyyMMdd-HHmmss"
                let pseudoSessionId = "ax-\(tsFmt.string(from: Date()))"
                // FUTURE: For Safari (and Chrome when not using the extension), enrich the session
                // with file attachment metadata by walking the AX tree for file-upload UI elements
                // (e.g. AXButton with label containing "attach" or "upload", AXStaticText with
                // filenames). Currently attachments are always empty for AX-captured sessions.
                sessions.openSession(sessionId: pseudoSessionId, app: appName, meta: [
                    "source": "ax", "interceptor": interceptor.name,
                ])
                sessions.advanceTurn(sessionId: pseudoSessionId, app: appName)
                let pid = logPayload([
                    "ts":         timestamp(),
                    "event":      "submit",
                    "source":     "ax",
                    "app":        appName,
                    "session_id": pseudoSessionId,
                    "words":      words,
                    "text":       text,
                ])
                sessions.recordPrompt(sessionId: pseudoSessionId, words: words,
                                      model: "", payloadId: pid)
                logJSON([
                    "ts":          timestamp(),
                    "event":       "submit",
                    "source":      "ax",
                    "app":         appName,
                    "session_id":  pseudoSessionId,
                    "interceptor": interceptor.name,
                    "role":        lastInputRole,
                    "words":       words,
                    "preview":     String(text.prefix(120)),
                ])
                lastCaptured = text
                capturedPromptKeys.insert(promptKey(text))
                firedRealtimeSubmit = true

                // Begin a background response watch for this app, if it opts in via a
                // profile. Snapshot the transcript blocks now (pre-answer baseline) so
                // later reads can isolate just the newly-added turn.
                if let profile = interceptor.responseProfile(for: app) {
                    baselineBlocks = Set(readTranscriptBlocks(from: app, profile: profile))
                    awaitingResponseSessionId = pseudoSessionId
                    awaitingResponseApp = appName
                    awaitingResponseRunningApp = app
                    awaitingResponseProfile = profile
                    awaitingResponsePrompt = text
                    lastResponseText = ""
                    responseStablePolls = 0
                    responseWatchPolls = 0
                }
            }
        }

        // Missed-submit → reconciliation. Focus left the input but we captured nothing
        // live (e.g. cold-launch: the input value read back as the placeholder). Flag a
        // reconcile so we recover the turn from the transcript once the answer renders.
        if leftInput, !firedRealtimeSubmit,
           let profile = interceptor.responseProfile(for: app), profile.userTurnMarker != nil {
            pendingReconcileApp = app
            pendingReconcileProfile = profile
            pendingReconcileName = appName
            pendingReconcilePolls = 0
        }

        // Update prompt-tracking state before the (throttled) background response poll.
        // Only update lastText when focused on an input — freeze it while in the
        // response area so the prompt survives until we can detect the submit.
        if inInput {
            lastText = captured
            lastInputRole = role
        }
        wasInInput = inInput

        // Response polling is throttled to ~1 Hz and runs against the watched app,
        // independent of which app is currently frontmost.
        pollDivider += 1
        if pollDivider % responsePollEveryNTicks == 0 {
            pollResponse()
            pollReconcile()
        }
    }

    // Polls the watched app's transcript in the background (~1 Hz) and logs the new
    // turn once the assistant signals it has finished (or the text stabilises for an
    // app without a finished-signal). Isolates the new turn by set-differencing the
    // current transcript blocks against the pre-submit baseline, so prior turns and
    // stable chrome are excluded and only the fresh answer remains.
    private func pollResponse() {
        guard !awaitingResponseSessionId.isEmpty,
              let app = awaitingResponseRunningApp,
              let profile = awaitingResponseProfile else { return }

        // Watched app quit — abandon the watch.
        if app.isTerminated { endResponseWatch(); return }

        responseWatchPolls += 1

        // New turn = blocks not present at submit, minus timestamps, chrome, and the
        // echoed prompt. Order-preserved.
        let promptTrimmed = awaitingResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let chrome = universalChromeStrings.union(profile.chrome)
        let newBlocks = readTranscriptBlocks(from: app, profile: profile).filter { block in
            let t = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return !baselineBlocks.contains(block)
                && !isTranscriptNoise(block)
                && !chrome.contains(t)
                && t != promptTrimmed
        }
        let candidate = newBlocks.joined(separator: "\n\n")

        // Track stability.
        if candidate == lastResponseText {
            responseStablePolls += 1
        } else {
            lastResponseText = candidate
            responseStablePolls = 0
        }

        // Finalise based on the assistant's own state where available.
        let watchdogHit = responseWatchPolls >= responseMaxWatchPolls
        let readyToFinalise: Bool
        switch responseState(of: app, profile: profile) {
        case .streaming:
            readyToFinalise = watchdogHit            // never finalise mid-stream
        case .finished:
            readyToFinalise = responseStablePolls >= responseFinishedStability || watchdogHit
        case .unknown:
            readyToFinalise = responseStablePolls >= responseUnknownStability || watchdogHit
        }

        guard readyToFinalise, candidate.count >= minResponseLength,
              candidate != lastResponseCaptured else { return }

        let sessionId = awaitingResponseSessionId
        let appName = awaitingResponseApp
        let words = candidate.split(separator: " ").count
        // Canonical answer schema — matches the hook/extension "ai_response" event
        // (PromptServer) so downstream tooling sees one shape across all sources.
        // Tokens/url aren't exposed via AX, so they're null/empty here.
        let base: [String: Any] = [
            "ts":            timestamp(),
            "event":         "ai_response",
            "source":        "ax",
            "app":           appName,
            "session_id":    sessionId,
            "url":           "",
            "words":         words,
            "input_tokens":  NSNull(),
            "output_tokens": NSNull(),
        ]
        let pid = logPayload(base.merging(["text": candidate]) { $1 })
        sessions.recordResponse(sessionId: sessionId, words: words, payloadId: pid)
        logJSON(base.merging([
            "preview":    String(candidate.prefix(120)),
            "payload_id": pid,
        ]) { $1 })
        lastResponseCaptured = candidate
        endResponseWatch()
    }

    private func endResponseWatch() {
        awaitingResponseSessionId = ""
        awaitingResponseRunningApp = nil
        awaitingResponseProfile = nil
        baselineBlocks = []
    }

    // Recovers a missed turn from the built transcript. Runs after a submit we couldn't
    // capture live (pendingReconcile*). Waits until the assistant has finished, then
    // parses the last transcript turn; if its prompt is new (not already captured live),
    // logs both the prompt and the answer. Deduped by promptKey so it never duplicates.
    private func pollReconcile() {
        guard let app = pendingReconcileApp, let profile = pendingReconcileProfile else { return }
        if app.isTerminated { clearPendingReconcile(); return }
        pendingReconcilePolls += 1
        if pendingReconcilePolls > reconcileMaxPolls { clearPendingReconcile(); return }

        // Let the answer finish rendering so it's fully in the transcript.
        if responseState(of: app, profile: profile) == .streaming { return }

        let turns = parseTranscriptTurns(readTranscriptBlocks(from: app, profile: profile), profile: profile)
        guard let last = turns.last else { return }   // tree not built / transcript empty yet — keep waiting
        let key = promptKey(last.prompt)
        guard !key.isEmpty, last.prompt.count >= 3 else { clearPendingReconcile(); return }
        if capturedPromptKeys.contains(key) { clearPendingReconcile(); return }   // live path got it
        guard !last.answer.isEmpty else { return }    // answer not rendered yet — keep waiting

        // Log the recovered turn as its own AX session (source "ax-recon").
        let tsFmt = DateFormatter(); tsFmt.dateFormat = "yyyyMMdd-HHmmss"
        let sessionId = "ax-recon-\(tsFmt.string(from: Date()))"
        sessions.openSession(sessionId: sessionId, app: pendingReconcileName,
                             meta: ["source": "ax-recon"])
        sessions.advanceTurn(sessionId: sessionId, app: pendingReconcileName)

        let pWords = last.prompt.split(separator: " ").count
        let pPid = logPayload(["ts": timestamp(), "event": "submit", "source": "ax-recon",
                               "app": pendingReconcileName, "session_id": sessionId,
                               "words": pWords, "text": last.prompt])
        sessions.recordPrompt(sessionId: sessionId, words: pWords, model: "", payloadId: pPid)
        logJSON(["ts": timestamp(), "event": "submit", "source": "ax-recon",
                 "app": pendingReconcileName, "session_id": sessionId,
                 "words": pWords, "preview": String(last.prompt.prefix(120))])

        let aWords = last.answer.split(separator: " ").count
        let aBase: [String: Any] = ["ts": timestamp(), "event": "ai_response", "source": "ax-recon",
                                    "app": pendingReconcileName, "session_id": sessionId, "url": "",
                                    "words": aWords, "input_tokens": NSNull(), "output_tokens": NSNull()]
        let aPid = logPayload(aBase.merging(["text": last.answer]) { $1 })
        sessions.recordResponse(sessionId: sessionId, words: aWords, payloadId: aPid)
        logJSON(aBase.merging(["preview": String(last.answer.prefix(120)), "payload_id": aPid]) { $1 })

        capturedPromptKeys.insert(key)
        clearPendingReconcile()
    }

    private func clearPendingReconcile() {
        pendingReconcileApp = nil
        pendingReconcileProfile = nil
        pendingReconcilePolls = 0
    }
}
