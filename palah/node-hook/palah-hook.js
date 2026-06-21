'use strict';
// palah-hook.js — Palah Node.js interceptor

// Diagnostic: log every process that loads this hook.
// Check /tmp/palah-hook-loaded.log after restarting apps.
try {
  require('fs').appendFileSync('/tmp/palah-hook-loaded.log',
    `[${new Date().toISOString()}] pid=${process.pid} title="${process.title}" argv="${(process.argv[1]||'').split('/').pop()}"\n`
  );
} catch (_) {}
// Loaded into every Node.js process via NODE_OPTIONS=--require /path/to/palah-hook.js
//
// Intercepts outbound HTTPS calls to AI API endpoints before TLS encryption.
// Reports metadata to Palah's local server. Original request is never blocked or modified.

const https = require('https');
const http  = require('http');

const AI_HOSTS = new Set([
  'api.anthropic.com',
  'api.openai.com',
  'api.openai.azure.com',
  'generativelanguage.googleapis.com',
  'api.mistral.ai',
  'api.perplexity.ai',
  'api.cohere.ai',
  'api.groq.com',
  'openrouter.ai',
]);

// Only intercept these endpoint patterns — skip auth, billing, model-list endpoints
const CHAT_PATH_RE = /\/(messages|completions|chat)/;

const PALAH_HOST = '127.0.0.1';
const PALAH_PORT = 45678;

// ─── Reporting ───────────────────────────────────────────────────────────────
// Fire-and-forget POST to Palah. Uses http (not https) to avoid recursion.
// Silently drops if Palah is not running.

function report(entry) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source: 'node_options', ...entry });
    const req  = http.request({
      hostname: PALAH_HOST,
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

// ─── Helpers ─────────────────────────────────────────────────────────────────

function processLabel() {
  if (process.title && process.title !== 'node') return process.title;
  const arg = (process.argv[1] || '').split('/').pop();
  return arg || 'node';
}

function hostnameFrom(options) {
  if (typeof options === 'string') {
    try { return new URL(options).hostname; } catch (_) { return ''; }
  }
  return (options.hostname || options.host || '').replace(/:\d+$/, '');
}

function pathFrom(options) {
  if (typeof options === 'string') {
    try { return new URL(options).pathname; } catch (_) { return '/'; }
  }
  return options.path || options.pathname || '/';
}

// Parses an AI API JSON body and extracts the prompt text + metadata.
// Handles both OpenAI chat format and Anthropic messages format.
function parseAndReport(bodyStr, hostname, path) {
  try {
    const json     = JSON.parse(bodyStr);
    const messages = json.messages || [];

    const lastUser = [...messages].reverse().find(m => m.role === 'user');
    const content  = lastUser?.content ?? '';
    const text = typeof content === 'string'
      ? content
      : Array.isArray(content)
        ? content.filter(c => c.type === 'text').map(c => c.text).join(' ')
        : '';

    report({
      app:          processLabel(),
      pid:          process.pid,
      tool:         hostname,
      url:          hostname,
      endpoint:     path,
      model:        json.model || json.model_id || 'unknown',
      messageCount: messages.length,
      words:        text.trim() ? text.trim().split(/\s+/).length : 0,
      text:         text.slice(0, 500),
    });
  } catch (_) {
    // Non-JSON body (e.g. already-streaming request) — skip silently
  }
}

// ─── Patch https.request ─────────────────────────────────────────────────────

const _originalRequest = https.request.bind(https);

https.request = function palahRequest(options, callback) {
  const req = _originalRequest(options, callback);

  const hostname = hostnameFrom(options);
  const path     = pathFrom(options);

  if (!AI_HOSTS.has(hostname) || !CHAT_PATH_RE.test(path)) return req;

  // Wrap write/end to accumulate the request body before it's encrypted
  const chunks  = [];
  const _write  = req.write.bind(req);
  const _end    = req.end.bind(req);

  req.write = function (chunk, encoding, cb) {
    if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding || 'utf8'));
    return _write(chunk, encoding, cb);
  };

  req.end = function (chunk, encoding, cb) {
    if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding || 'utf8'));
    parseAndReport(Buffer.concat(chunks).toString('utf8'), hostname, path);
    return _end(chunk, encoding, cb);
  };

  return req;
};

// https.get delegates to https.request — patch it too for completeness
https.get = function palahGet(options, callback) {
  return https.request(options, callback);
};

// ─── Patch globalThis.fetch (Node.js 18+ / undici) ───────────────────────────
// Claude Code and the Anthropic SDK use the built-in fetch, which bypasses
// https.request entirely. This patch catches that path.

if (typeof globalThis.fetch === 'function') {
  const _originalFetch = globalThis.fetch;

  globalThis.fetch = async function palahFetch(input, init) {
    try {
      const url      = typeof input === 'string' ? input : (input?.url ?? String(input));
      const parsed   = new URL(url);
      const hostname = parsed.hostname;
      const path     = parsed.pathname;

      if (AI_HOSTS.has(hostname) && CHAT_PATH_RE.test(path) && init?.body) {
        // Only handle string bodies — ReadableStream bodies are left alone
        if (typeof init.body === 'string') {
          parseAndReport(init.body, hostname, path);
        }
      }
    } catch (_) {}

    return _originalFetch(input, init);
  };
}
