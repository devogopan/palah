'use strict';
// palah-session-watcher.js
//
// Watches session JSONL files for two AI tools and POSTs new turns to Palah:
//   OpenClaw  — ~/.openclaw/agents/*/sessions/*.jsonl
//   Claude Code — ~/.claude/projects/*/<session-uuid>.jsonl
//
// Uses per-file fs.watch so appends to existing files are caught on macOS
// (directory-level watch only fires for creation/rename, not content changes).

const fs   = require('fs');
const path = require('path');
const http = require('http');
const os   = require('os');

const PALAH_PORT   = 45678;
const OPENCLAW_DIR = path.join(os.homedir(), '.openclaw', 'agents');
const CLAUDE_DIR   = path.join(os.homedir(), '.claude', 'projects');

// byte-cursor per file — only process new bytes (never replay history)
const cursors = new Map();

// ─── Reporting ────────────────────────────────────────────────────────────────

function post(source, payload) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source, ...payload });
    const req  = http.request({
      hostname: '127.0.0.1', port: PALAH_PORT, path: '/prompt', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    });
    req.on('error', () => {});
    req.write(body);
    req.end();
  } catch (_) {}
}

// ─── OpenClaw JSONL parser ────────────────────────────────────────────────────
// Format: { type: "message", message: { role, content: [{type:"text",text}], usage:{input,output} } }

function processOpenClawLine(sessionId, obj) {
  if (obj.type !== 'message') return;
  const msg = obj.message;
  if (!msg) return;
  const content = msg.content ?? [];
  const text = (Array.isArray(content)
    ? content.filter(p => p.type === 'text').map(p => p.text).join(' ')
    : '').trim();
  if (!text) return;

  if (msg.role === 'user') {
    post('openclaw_session', {
      event_type: 'user_prompt', app: 'openclaw', text,
      words: text.split(/\s+/).length, session_id: sessionId, timestamp: Date.now(),
    });
  } else if (msg.role === 'assistant') {
    const usage = msg.usage ?? {};
    post('openclaw_session', {
      event_type: 'ai_response', app: 'openclaw', text,
      words: text.split(/\s+/).length, session_id: sessionId,
      model: msg.model ?? '', input_tokens: usage.input ?? null,
      output_tokens: usage.output ?? null, timestamp: Date.now(),
    });
  }
}

// ─── Claude Code JSONL parser ─────────────────────────────────────────────────
// Format: { parentUuid, message: { role, content: [{type:"text",text}], usage:{input_tokens,output_tokens,...} } }
// User prompts are already captured by the claude_hook (UserPromptSubmit).
// We only report assistant responses so there are no duplicates.

function processClaudeCodeLine(sessionId, obj) {
  const msg = obj.message;
  if (!msg || msg.role !== 'assistant') return;
  const content = msg.content ?? [];
  const text = (Array.isArray(content)
    ? content.filter(p => p.type === 'text').map(p => p.text).join('')
    : '').trim();
  if (!text) return;

  const usage = msg.usage ?? {};
  post('claude_session', {
    event_type:    'ai_response',
    app:           'ClaudeCode',
    text,
    words:         text.split(/\s+/).length,
    session_id:    sessionId,
    model:         msg.model ?? '',
    input_tokens:  usage.input_tokens  ?? null,
    output_tokens: usage.output_tokens ?? null,
    timestamp:     Date.now(),
  });
}

// ─── File tailing ─────────────────────────────────────────────────────────────

function readNewLines(filePath, processor) {
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
      if (line.trim()) try { processor(sessionId, JSON.parse(line)); } catch (_) {}
    }
  } catch (_) {}
}

// Watch a single file. fs.watch(directory) on macOS does not fire for content
// modifications to existing files — each file must be watched individually.
function watchFile(filePath, processor) {
  try { fs.watch(filePath, () => readNewLines(filePath, processor)); } catch (_) {}
}

// ─── Generic directory watcher ────────────────────────────────────────────────

function watchDir(dir, processor) {
  try { if (!fs.statSync(dir).isDirectory()) return; } catch (_) { return; }
  // Initialise cursors at EOF and watch each existing JSONL file
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.jsonl')) continue;
      const fp = path.join(dir, f);
      cursors.set(fp, fs.statSync(fp).size);
      watchFile(fp, processor);
    }
  } catch (_) {}
  // Watch for newly created session files
  try {
    fs.watch(dir, (_, filename) => {
      if (!filename?.endsWith('.jsonl')) return;
      const fp = path.join(dir, filename);
      if (!cursors.has(fp)) { cursors.set(fp, 0); watchFile(fp, processor); }
      readNewLines(fp, processor);
    });
    process.stderr.write('[palah-watcher] watching ' + dir + '\n');
  } catch (_) {}
}

// ─── OpenClaw — ~/.openclaw/agents/<agent>/sessions/ ─────────────────────────

function watchOpenClaw(agentsDir) {
  try { fs.statSync(agentsDir); } catch (_) {
    process.stderr.write('[palah-watcher] openclaw not found — idle\n');
    return;
  }
  try {
    for (const agent of fs.readdirSync(agentsDir))
      watchDir(path.join(agentsDir, agent, 'sessions'), processOpenClawLine);
  } catch (_) {}
  try {
    fs.watch(agentsDir, (_, agentName) => {
      if (agentName) watchDir(path.join(agentsDir, agentName, 'sessions'), processOpenClawLine);
    });
  } catch (_) {}
}

// ─── Claude Code — ~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl ─────────

function watchClaudeCode(projectsDir) {
  try { fs.statSync(projectsDir); } catch (_) {
    process.stderr.write('[palah-watcher] claude projects not found — idle\n');
    return;
  }
  try {
    for (const proj of fs.readdirSync(projectsDir))
      watchDir(path.join(projectsDir, proj), processClaudeCodeLine);
  } catch (_) {}
  try {
    fs.watch(projectsDir, (_, projName) => {
      if (projName) watchDir(path.join(projectsDir, projName), processClaudeCodeLine);
    });
  } catch (_) {}
}

// ─── Main ─────────────────────────────────────────────────────────────────────

process.stderr.write('[palah-watcher] starting\n');
watchOpenClaw(OPENCLAW_DIR);
watchClaudeCode(CLAUDE_DIR);
process.stderr.write('[palah-watcher] ready\n');
