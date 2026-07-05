'use strict';
// openclaw-session-watcher.js
//
// Watches ~/.openclaw/agents/*/sessions/*.jsonl for new conversation turns
// and POSTs them to Palah (localhost:45678/prompt).
//
// How it works:
//   OpenClaw appends one JSON object per line to session JSONL files as the
//   conversation progresses. This script uses fs.watch to detect new writes,
//   then reads only the new bytes (tail-style cursor tracking), parses each
//   line, and reports user prompts and assistant responses to Palah.
//
// Run: node openclaw-session-watcher.js
// Or as a daemon via launchd alongside the OpenClaw gateway.

const fs   = require('fs');
const path = require('path');
const http = require('http');
const os   = require('os');

const PALAH_PORT   = 45678;
const AGENTS_DIR   = path.join(os.homedir(), '.openclaw', 'agents');

// byte-cursor per file so we only process new lines (never replay old ones)
const cursors = new Map();

// ─── Reporting ───────────────────────────────────────────────────────────────

function report(payload) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source: 'openclaw_session', ...payload });
    const req  = http.request({
      hostname: '127.0.0.1',
      port:     PALAH_PORT,
      path:     '/prompt',
      method:   'POST',
      headers: {
        'Content-Type':   'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    });
    req.on('error', () => {});
    req.write(body);
    req.end();
  } catch (_) {}
}

// ─── JSONL parsing ───────────────────────────────────────────────────────────

function processLine(sessionId, obj) {
  if (obj.type !== 'message') return;
  const msg = obj.message;
  if (!msg) return;

  const content  = msg.content ?? [];
  const textParts = Array.isArray(content)
    ? content.filter(p => p.type === 'text').map(p => p.text).join(' ').trim()
    : '';

  if (msg.role === 'user' && textParts) {
    report({
      event_type: 'user_prompt',
      app:        'openclaw',
      text:       textParts,
      words:      textParts.split(/\s+/).length,
      session_id: sessionId,
      timestamp:  Date.now(),
    });

  } else if (msg.role === 'assistant' && textParts) {
    const usage = msg.usage ?? {};
    report({
      event_type:    'ai_response',
      app:           'openclaw',
      text:          textParts,
      words:         textParts.split(/\s+/).length,
      session_id:    sessionId,
      model:         msg.model ?? '',
      input_tokens:  usage.input  ?? null,
      output_tokens: usage.output ?? null,
      timestamp:     Date.now(),
    });
  }
}

// ─── File tailing ────────────────────────────────────────────────────────────

function readNewLines(filePath) {
  try {
    const stat   = fs.statSync(filePath);
    const cursor = cursors.get(filePath) ?? 0;
    if (stat.size <= cursor) return;

    const newBytes = stat.size - cursor;
    const buf = Buffer.alloc(newBytes);
    const fd  = fs.openSync(filePath, 'r');
    fs.readSync(fd, buf, 0, newBytes, cursor);
    fs.closeSync(fd);
    cursors.set(filePath, stat.size);

    const sessionId = path.basename(filePath, '.jsonl');
    for (const line of buf.toString('utf8').split('\n')) {
      if (!line.trim()) continue;
      try { processLine(sessionId, JSON.parse(line)); } catch (_) {}
    }
  } catch (_) {}
}

// ─── Directory watching ──────────────────────────────────────────────────────

// Watch a single JSONL file for content changes.
// fs.watch(directory) on macOS fires for creation/rename but NOT for content
// modifications to existing files — so we must watch each file individually.
function watchFile(filePath) {
  try {
    fs.watch(filePath, () => readNewLines(filePath));
  } catch (_) {}
}

function watchSessionsDir(sessionsDir) {
  try {
    if (!fs.statSync(sessionsDir).isDirectory()) return;
  } catch (_) { return; }

  // Initialise cursors at current EOF and watch each existing file for appends
  try {
    for (const file of fs.readdirSync(sessionsDir)) {
      if (!file.endsWith('.jsonl')) continue;
      const fp   = path.join(sessionsDir, file);
      const stat = fs.statSync(fp);
      cursors.set(fp, stat.size);
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
    console.log(`[palah-openclaw] watching ${sessionsDir}`);
  } catch (_) {}
}

function watchAgentsDir(agentsDir) {
  try {
    if (!fs.statSync(agentsDir).isDirectory()) {
      console.error(`[palah-openclaw] agents dir not found: ${agentsDir}`);
      return;
    }
  } catch (_) {
    console.error(`[palah-openclaw] agents dir not found: ${agentsDir}`);
    return;
  }

  // Watch existing agents
  try {
    for (const agent of fs.readdirSync(agentsDir)) {
      watchSessionsDir(path.join(agentsDir, agent, 'sessions'));
    }
  } catch (_) {}

  // Watch for new agent directories being created
  fs.watch(agentsDir, (_, agentName) => {
    if (!agentName) return;
    watchSessionsDir(path.join(agentsDir, agentName, 'sessions'));
  });
}

// ─── Main ────────────────────────────────────────────────────────────────────

console.log(`[palah-openclaw] session watcher starting`);
console.log(`[palah-openclaw] reporting to localhost:${PALAH_PORT}`);
watchAgentsDir(AGENTS_DIR);
console.log(`[palah-openclaw] ready — Ctrl-C to stop`);
