//
//  SessionManager.swift
//  Palah
//
//  Manages per-session, per-turn payload storage.
//
//  Layout:
//    /tmp/palah-sessions/<session_id>/meta.json       — app, cwd, model, start/end, turn count
//    /tmp/palah-sessions/<session_id>/turn-001.ndjson — payloads for turn 1 (1st user prompt + tool chain)
//    /tmp/palah-sessions/<session_id>/turn-002.ndjson — payloads for turn 2, etc.
//
//  Each user prompt submit advances the turn counter. The classifier loads one
//  turn file at a time — tight context, predictable size.

import Foundation

let sessionBaseDir = "/tmp/palah-sessions"
let sessions       = SessionManager()

final class SessionManager {

    private var turnCounters: [String: Int] = [:]
    private let lock = NSLock()

    // MARK: - Turn management

    // Called on each user prompt submit. Must be called before logPayload so
    // tool outputs land in the correct turn file.
    // On first call for a session, counts existing turn files on disk so that
    // app restarts resume from the correct turn number rather than overwriting.
    func advanceTurn(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        lock.lock()
        if turnCounters[sessionId] == nil {
            // Release lock while doing disk I/O, then re-acquire
            lock.unlock()
            let dir = "\(sessionBaseDir)/\(sessionId)"
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { $0.hasPrefix("turn-") && $0.hasSuffix(".ndjson") }
                .count ?? 0
            lock.lock()
            if turnCounters[sessionId] == nil {
                turnCounters[sessionId] = existing
            }
        }
        turnCounters[sessionId]! += 1
        lock.unlock()
    }

    // Returns the ndjson path for the current turn, creating the session dir if needed.
    func payloadPath(sessionId: String) -> String {
        lock.lock()
        let turn = max(turnCounters[sessionId] ?? 0, 1)
        lock.unlock()
        let dir = "\(sessionBaseDir)/\(sessionId)"
        ensureDir(dir)
        return "\(dir)/turn-\(String(format: "%03d", turn)).ndjson"
    }

    // MARK: - Session lifecycle

    // Creates session directory and writes meta.json on first call for a session.
    // Safe to call multiple times — no-ops if meta already exists.
    func openSession(sessionId: String, meta: [String: Any]) {
        guard !sessionId.isEmpty else { return }
        let dir = "\(sessionBaseDir)/\(sessionId)"
        ensureDir(dir)
        let metaPath = "\(dir)/meta.json"
        guard !FileManager.default.fileExists(atPath: metaPath) else { return }
        var m = meta
        m["session_id"] = sessionId
        m["start"]      = timestamp()
        if let data = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: metaPath))
        }
    }

    // Updates meta.json with end time and turn count, clears in-memory state.
    func closeSession(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        lock.lock()
        let turns = turnCounters[sessionId] ?? 0
        turnCounters.removeValue(forKey: sessionId)
        lock.unlock()

        let metaPath = "\(sessionBaseDir)/\(sessionId)/meta.json"
        guard let data = FileManager.default.contents(atPath: metaPath),
              var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        meta["end"]   = timestamp()
        meta["turns"] = turns
        if let updated = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .prettyPrinted]) {
            try? updated.write(to: URL(fileURLWithPath: metaPath))
        }
    }

    // MARK: - Private

    private func ensureDir(_ path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
