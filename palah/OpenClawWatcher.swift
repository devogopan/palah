import Foundation
import os.log

private let palahLog = OSLog(subsystem: "com.devogopan.palah", category: "openclaw")

// Manages the OpenClaw session watcher child process.
//
// On start():
//  1. Writes the bundled watcher script to ~/.palah/ (always overwrites so
//     it stays in sync with the running Palah build).
//  2. Discovers the node binary by scanning nvm versions and common paths.
//  3. Launches node as a child process — no manual install step needed.
//
// The watcher tails ~/.openclaw/agents/*/sessions/*.jsonl and POSTs new
// turns to Palah (localhost:45678). It is a no-op if node is not installed.

class OpenClawWatcher {
    private var process: Process?

    // ── Node discovery ────────────────────────────────────────────────────────
    // GUI apps launch with a minimal PATH that omits nvm. We search known
    // locations directly rather than relying on PATH.

    private var nodeBinary: String? {
        let home = NSHomeDirectory()

        // 1. nvm — pick the highest-version installed
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = entries
                .filter { $0.hasPrefix("v") }
                .sorted { lhs, rhs in
                    let lv = lhs.dropFirst().split(separator: ".").compactMap { Int($0) }
                    let rv = rhs.dropFirst().split(separator: ".").compactMap { Int($0) }
                    for (a, b) in zip(lv, rv) { if a != b { return a > b } }
                    return lv.count > rv.count
                }
            for v in sorted {
                let p = "\(nvmRoot)/\(v)/bin/node"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }

        // 2. Homebrew (Apple Silicon and Intel)
        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }

        return nil
    }

    // ── Watcher script ────────────────────────────────────────────────────────
    // Embedded here so the script stays in sync with this build without any
    // separate install step. Written to ~/.palah/ on every launch.

    private static let watcherJS = #"""
'use strict';
// openclaw-session-watcher.js — auto-deployed by Palah.app on launch.
// Watches ~/.openclaw/agents/*/sessions/*.jsonl for new conversation turns
// and POSTs them to Palah (localhost:45678/prompt).

const fs   = require('fs');
const path = require('path');
const http = require('http');
const os   = require('os');

const PALAH_PORT = 45678;
const AGENTS_DIR = path.join(os.homedir(), '.openclaw', 'agents');

const cursors = new Map();

function report(payload) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source: 'openclaw_session', ...payload });
    const req  = http.request({
      hostname: '127.0.0.1', port: PALAH_PORT, path: '/prompt', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    });
    req.on('error', () => {});
    req.write(body);
    req.end();
  } catch (_) {}
}

function processLine(sessionId, obj) {
  if (obj.type !== 'message') return;
  const msg = obj.message;
  if (!msg) return;
  const content   = msg.content ?? [];
  const textParts = Array.isArray(content)
    ? content.filter(p => p.type === 'text').map(p => p.text).join(' ').trim()
    : '';
  if (msg.role === 'user' && textParts) {
    report({ event_type: 'user_prompt', app: 'openclaw', text: textParts,
             words: textParts.split(/\s+/).length, session_id: sessionId, timestamp: Date.now() });
  } else if (msg.role === 'assistant' && textParts) {
    const usage = msg.usage ?? {};
    report({ event_type: 'ai_response', app: 'openclaw', text: textParts,
             words: textParts.split(/\s+/).length, session_id: sessionId,
             model: msg.model ?? '', input_tokens: usage.input ?? null,
             output_tokens: usage.output ?? null, timestamp: Date.now() });
  }
}

function readNewLines(filePath) {
  try {
    const stat   = fs.statSync(filePath);
    const cursor = cursors.get(filePath) ?? 0;
    if (stat.size <= cursor) return;
    const buf = Buffer.alloc(stat.size - cursor);
    const fd  = fs.openSync(filePath, 'r');
    fs.readSync(fd, buf, 0, buf.length, cursor);
    fs.closeSync(fd);
    cursors.set(filePath, stat.size);
    const sessionId = path.basename(filePath, '.jsonl');
    for (const line of buf.toString('utf8').split('\n')) {
      if (line.trim()) try { processLine(sessionId, JSON.parse(line)); } catch (_) {}
    }
  } catch (_) {}
}

// Watch a single JSONL file for content changes.
// fs.watch(directory) on macOS fires for creation/rename but NOT for content
// modifications to existing files — so we must watch each file individually.
function watchFile(filePath) {
  try {
    fs.watch(filePath, () => readNewLines(filePath));
  } catch (_) {}
}

function watchSessionsDir(sessionsDir) {
  try { if (!fs.statSync(sessionsDir).isDirectory()) return; } catch (_) { return; }
  // Initialise cursors at current EOF and watch each existing file for appends
  try {
    for (const f of fs.readdirSync(sessionsDir)) {
      if (!f.endsWith('.jsonl')) continue;
      const fp = path.join(sessionsDir, f);
      cursors.set(fp, fs.statSync(fp).size);
      watchFile(fp);
    }
  } catch (_) {}
  // Watch directory for newly created session files
  try {
    fs.watch(sessionsDir, (_, filename) => {
      if (!filename?.endsWith('.jsonl')) return;
      const fp = path.join(sessionsDir, filename);
      if (!cursors.has(fp)) {
        cursors.set(fp, 0);
        watchFile(fp);
      }
      readNewLines(fp);
    });
    process.stderr.write('[palah-openclaw] watching ' + sessionsDir + '\n');
  } catch (_) {}
}

function watchAgentsDir(agentsDir) {
  try { fs.statSync(agentsDir); } catch (_) {
    process.stderr.write('[palah-openclaw] ~/.openclaw not found — watcher idle until OpenClaw is installed\n');
    return;
  }
  try {
    for (const agent of fs.readdirSync(agentsDir)) {
      watchSessionsDir(path.join(agentsDir, agent, 'sessions'));
    }
  } catch (_) {}
  try {
    fs.watch(agentsDir, (_, agentName) => {
      if (agentName) watchSessionsDir(path.join(agentsDir, agentName, 'sessions'));
    });
  } catch (_) {}
}

process.stderr.write('[palah-openclaw] session watcher starting\n');
watchAgentsDir(AGENTS_DIR);
process.stderr.write('[palah-openclaw] ready\n');
"""#

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    func start() {
        guard let node = nodeBinary else {
            os_log(.info, log: palahLog, "OpenClaw watcher: node not found — install Node.js 18+ to enable")
            return
        }

        let script = deployScript()
        guard let script else {
            os_log(.error, log: palahLog, "OpenClaw watcher: failed to write watcher script")
            return
        }

        let logPath = "/tmp/palah-openclaw-watcher.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)

        let p = Process()
        p.launchPath = node
        p.arguments  = [script]
        if let lh = logHandle {
            p.standardOutput = lh
            p.standardError  = lh
        }
        p.terminationHandler = { [weak self] proc in
            os_log(.info, log: palahLog, "OpenClaw watcher exited (status %d)", proc.terminationStatus)
            self?.process = nil
        }

        do {
            try p.run()
            process = p
            os_log(.default, log: palahLog, "OpenClaw watcher started — node: %{public}@ pid: %d", node, p.processIdentifier)
        } catch {
            os_log(.error, log: palahLog, "OpenClaw watcher failed to start: %{public}@", error.localizedDescription)
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    // ── Deploy ────────────────────────────────────────────────────────────────

    @discardableResult
    private func deployScript() -> String? {
        let palahDir = (NSHomeDirectory() as NSString).appendingPathComponent(".palah")
        let destPath = (palahDir as NSString).appendingPathComponent("openclaw-session-watcher.js")
        do {
            try FileManager.default.createDirectory(atPath: palahDir,
                                                    withIntermediateDirectories: true)
            // Always overwrite — keeps the script in sync with this Palah build
            try Self.watcherJS.write(toFile: destPath, atomically: true, encoding: .utf8)
            return destPath
        } catch {
            os_log(.error, log: palahLog, "OpenClaw watcher deploy failed: %{public}@",
                   error.localizedDescription)
            return nil
        }
    }
}
