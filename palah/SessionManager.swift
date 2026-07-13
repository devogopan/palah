//
//  SessionManager.swift
//  Palah
//
//  Manages per-session, per-turn payload storage organised by date and AI application.
//
//  Directory layout:
//    /tmp/palah-sessions/<yyyy-MM-dd>/<app-slug>/<session-id>/
//      meta.json              — session-level metadata (app, model, cwd, start/end, turns)
//      turn-001.ndjson        — full-content payloads: prompt + tool chain for turn 1
//      turn-001-meta.json     — turn-level metadata (tools used, tokens, duration, payload IDs)
//      turn-002.ndjson
//      turn-002-meta.json  ...
//
//  Browser and AX captures use a datetime pseudo-session (no tool-provided session ID):
//    /tmp/palah-sessions/2026-06-29/chatgpt/20260629-143200/turn-001.ndjson

import Foundation

let sessionBaseDir = "/tmp/palah-sessions"
let sessions       = SessionManager()

final class SessionManager {

    // MARK: - Internal types

    private struct SessionInfo {
        let dir: String
        let app: String
    }

    private struct TurnAccumulator {
        let turn:   Int
        let tsStart: String
        var tsEnd:   String = ""
        var promptWords:     Int    = 0
        var responseWords:   Int    = 0
        var model:           String = ""
        var effort:          String = ""
        var tools:           [String] = []
        var durationMsTotal: Int    = 0
        var payloadIds:      [String] = []
        var attachments:     [String] = []
    }

    // MARK: - State

    private var sessionInfos:  [String: SessionInfo]     = [:]
    private var turnCounters:  [String: Int]              = [:]
    private var accumulators:  [String: TurnAccumulator]  = [:]
    private let lock = NSLock()

    // MARK: - App slug

    static func slug(for app: String) -> String {
        switch app.lowercased() {
        case "claudecode", "claude code": return "claude-code"
        case "cursor":                    return "cursor"
        case "code":                      return "vscode"
        case "claude desktop":            return "claude-desktop"
        case "chatgpt":                   return "chatgpt"
        case "claude.ai", "claude-ai":    return "claude-ai"
        case "gemini":                    return "gemini"
        case "perplexity":                return "perplexity"
        case "safari":                    return "safari"
        case "chrome":                    return "chrome"
        default:
            return app.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: ".", with: "-")
        }
    }

    // MARK: - Session lifecycle

    // Creates the session directory and writes meta.json. Safe to call multiple times.
    func openSession(sessionId: String, app: String, meta: [String: Any]) {
        guard !sessionId.isEmpty else { return }
        let dir = makeDir(sessionId: sessionId, app: app)
        lock.lock()
        if sessionInfos[sessionId] == nil {
            sessionInfos[sessionId] = SessionInfo(dir: dir, app: app)
        }
        lock.unlock()
        ensureDir(dir)
        let metaPath = "\(dir)/meta.json"
        guard !FileManager.default.fileExists(atPath: metaPath) else { return }
        var m = meta
        m["session_id"] = sessionId
        m["app"]        = app
        m["start"]      = timestamp()
        writeJSON(m, to: metaPath, pretty: true)
    }

    // Updates meta.json with end time and total turn count.
    func closeSession(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        finalizeTurnMeta(sessionId: sessionId)
        lock.lock()
        let info  = sessionInfos[sessionId]
        let turns = turnCounters[sessionId] ?? 0
        sessionInfos.removeValue(forKey: sessionId)
        turnCounters.removeValue(forKey: sessionId)
        lock.unlock()
        guard let info else { return }
        let metaPath = "\(info.dir)/meta.json"
        guard let data = FileManager.default.contents(atPath: metaPath),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        meta["end"]   = timestamp()
        meta["turns"] = turns
        writeJSON(meta, to: metaPath, pretty: true)
    }

    // MARK: - Turn management

    // Finalises the previous turn's meta file, then increments the counter.
    // Must be called before logPayload so tool outputs land in the right turn file.
    func advanceTurn(sessionId: String, app: String) {
        guard !sessionId.isEmpty else { return }
        finalizeTurnMeta(sessionId: sessionId)
        lock.lock()
        if turnCounters[sessionId] == nil {
            // App restart: count existing turn files on disk to resume correctly.
            lock.unlock()
            let dir = sessionDir(sessionId: sessionId, app: app)
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasPrefix("turn-") && $0.hasSuffix(".ndjson") }
                .count ?? 0
            lock.lock()
            if turnCounters[sessionId] == nil { turnCounters[sessionId] = existing }
        }
        turnCounters[sessionId]! += 1
        let turn = turnCounters[sessionId]!
        accumulators[sessionId] = TurnAccumulator(turn: turn, tsStart: timestamp())
        lock.unlock()
    }

    // Returns the current turn number (used to echo back to the extension).
    func currentTurn(sessionId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return turnCounters[sessionId] ?? 1
    }

    // Returns the ndjson path for the current turn, creating dirs as needed.
    func payloadPath(sessionId: String, app: String) -> String {
        lock.lock()
        let turn = max(turnCounters[sessionId] ?? 0, 1)
        let dir  = sessionInfos[sessionId]?.dir ?? sessionDir(sessionId: sessionId, app: app)
        lock.unlock()
        ensureDir(dir)
        return "\(dir)/turn-\(String(format: "%03d", turn)).ndjson"
    }

    // MARK: - Event recording (feeds turn-NNN-meta.json)

    func recordPrompt(sessionId: String, words: Int, model: String, payloadId: String) {
        lock.lock(); defer { lock.unlock() }
        guard accumulators[sessionId] != nil else { return }
        accumulators[sessionId]!.promptWords = words
        if !model.isEmpty { accumulators[sessionId]!.model = model }
        accumulators[sessionId]!.payloadIds.append(payloadId)
    }

    func recordResponse(sessionId: String, words: Int, payloadId: String) {
        lock.lock(); defer { lock.unlock() }
        guard accumulators[sessionId] != nil else { return }
        accumulators[sessionId]!.responseWords = words
        accumulators[sessionId]!.payloadIds.append(payloadId)
    }

    func recordToolUse(sessionId: String, tool: String, durationMs: Int,
                       effort: String, payloadId: String) {
        lock.lock(); defer { lock.unlock() }
        guard accumulators[sessionId] != nil else { return }
        accumulators[sessionId]!.tools.append(tool)
        accumulators[sessionId]!.durationMsTotal += durationMs
        if !effort.isEmpty { accumulators[sessionId]!.effort = effort }
        accumulators[sessionId]!.payloadIds.append(payloadId)
    }

    // MARK: - Private helpers

    // Computes <sessionBaseDir>/<today>/<slug>/<sessionId>
    private func makeDir(sessionId: String, app: String) -> String {
        sessionDir(sessionId: sessionId, app: app)
    }

    private func sessionDir(sessionId: String, app: String) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return "\(sessionBaseDir)/\(fmt.string(from: Date()))/\(SessionManager.slug(for: app))/\(sessionId)"
    }

    // Writes turn-NNN-meta.json and removes the accumulator.
    private func finalizeTurnMeta(sessionId: String) {
        lock.lock()
        guard var acc = accumulators[sessionId] else { lock.unlock(); return }
        acc.tsEnd = timestamp()
        accumulators.removeValue(forKey: sessionId)
        let dir = sessionInfos[sessionId]?.dir
        lock.unlock()
        guard let dir else { return }
        let meta: [String: Any] = [
            "turn":              acc.turn,
            "ts_start":          acc.tsStart,
            "ts_end":            acc.tsEnd,
            "prompt_words":      acc.promptWords,
            "response_words":    acc.responseWords,
            "model":             acc.model,
            "effort":            acc.effort,
            "tools":             acc.tools,
            "tool_count":        acc.tools.count,
            "duration_ms_total": acc.durationMsTotal,
            "payload_count":     acc.payloadIds.count,
            "payload_ids":       acc.payloadIds,
            "input_tokens":      NSNull(),
            "output_tokens":     NSNull(),
            "attachments":       acc.attachments,
        ]
        writeJSON(meta, to: "\(dir)/turn-\(String(format: "%03d", acc.turn))-meta.json", pretty: true)
    }

    private func writeJSON(_ dict: [String: Any], to path: String, pretty: Bool) {
        let opts: JSONSerialization.WritingOptions = pretty
            ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: opts) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func ensureDir(_ path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
