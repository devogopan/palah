'use strict';
// palah-hook.js — Palah Node.js interceptor

try {
  require('fs').appendFileSync('/tmp/palah-hook-loaded.log',
    `[${new Date().toISOString()}] pid=${process.pid} title="${process.title}" argv="${(process.argv[1]||'').split('/').pop()}"\n`
  );
} catch (_) {}

const https = require('https');
const http  = require('http');
const { randomBytes } = require('crypto');

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

// Covers: Anthropic /messages, OpenAI /completions|/chat, Google /generateContent|/streamGenerateContent
const CHAT_PATH_RE = /\/(messages|completions|chat|generateContent|streamGenerateContent)/;

const PALAH_HOST = '127.0.0.1';
const PALAH_PORT = 45678;
const MAX_RESPONSE_BYTES = 1_048_576; // 1 MB cap on SSE buffer

// ─── Request correlation ──────────────────────────────────────────────────────
// Links an outbound AI request (prompt POST → Palah session_id) with the
// inbound SSE response. The SSE stream and the Palah response race each other;
// whichever finishes last triggers the final reportResponse() call.

const pendingRequests = new Map();

function genId() {
  return randomBytes(4).toString('hex') + Date.now().toString(36);
}

// ─── Reporting ────────────────────────────────────────────────────────────────

// POST to Palah. onResponse callback receives the parsed JSON reply.
function post(entry, onResponse) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source: 'node_options', ...entry });
    const reqOpts = {
      hostname: PALAH_HOST, port: PALAH_PORT, path: '/prompt', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    };
    const palahReq = http.request(reqOpts, onResponse ? (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        try { onResponse(JSON.parse(Buffer.concat(chunks).toString('utf8'))); } catch (_) {}
      });
    } : undefined);
    palahReq.on('error', () => {});
    palahReq.write(body);
    palahReq.end();
  } catch (_) {}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

// ─── Request body parsing ─────────────────────────────────────────────────────

function parseRequestBody(bodyStr, hostname, reqPath) {
  try {
    const json = JSON.parse(bodyStr);
    let text = '', messages = [];

    if (json.messages) {
      // OpenAI chat / Anthropic messages format
      messages       = json.messages;
      const lastUser = [...messages].reverse().find(m => m.role === 'user');
      const content  = lastUser?.content ?? '';
      text = typeof content === 'string'
        ? content
        : Array.isArray(content) ? content.filter(c => c.type === 'text').map(c => c.text).join(' ') : '';
    } else if (json.contents) {
      // Google Gemini format: { contents: [{ role, parts: [{ text }] }] }
      messages       = json.contents;
      const lastUser = [...messages].reverse().find(m => m.role === 'user');
      text = (lastUser?.parts ?? []).filter(p => p.text).map(p => p.text).join(' ');
    }

    return {
      event_type:   'user_prompt',
      app:          processLabel(),
      pid:          process.pid,
      tool:         hostname,
      url:          hostname,
      endpoint:     reqPath,
      model:        json.model || json.model_id || 'unknown',
      messageCount: messages.length,
      words:        text.trim() ? text.trim().split(/\s+/).length : 0,
      text:         text.slice(0, 500),
    };
  } catch (_) { return null; }
}

// ─── SSE response parsing ─────────────────────────────────────────────────────
// Parses Server-Sent Events from Anthropic, OpenAI, and Gemini into plain text.

function parseSSE(rawBody) {
  let text = '', inputTokens = null, outputTokens = null;
  for (const line of rawBody.split('\n')) {
    if (!line.startsWith('data:')) continue;
    const jsonStr = line.slice(5).trim();
    if (!jsonStr || jsonStr === '[DONE]') continue;
    try {
      const chunk = JSON.parse(jsonStr);
      // Anthropic
      if (chunk.type === 'content_block_delta' && chunk.delta?.text)
        text += chunk.delta.text;
      if (chunk.type === 'message_start' && chunk.message?.usage)
        inputTokens = chunk.message.usage.input_tokens ?? inputTokens;
      if (chunk.type === 'message_delta' && chunk.usage)
        outputTokens = chunk.usage.output_tokens ?? outputTokens;
      // OpenAI
      if (chunk.choices?.[0]?.delta?.content)
        text += chunk.choices[0].delta.content;
      if (chunk.usage) {
        if (chunk.usage.prompt_tokens     != null) inputTokens  = chunk.usage.prompt_tokens;
        if (chunk.usage.completion_tokens != null) outputTokens = chunk.usage.completion_tokens;
      }
      // Gemini
      if (chunk.candidates?.[0]?.content?.parts)
        for (const p of chunk.candidates[0].content.parts) { if (p.text) text += p.text; }
      if (chunk.usageMetadata) {
        inputTokens  = chunk.usageMetadata.promptTokenCount     ?? inputTokens;
        outputTokens = chunk.usageMetadata.candidatesTokenCount ?? outputTokens;
      }
    } catch (_) {}
  }
  return { text, inputTokens, outputTokens };
}

function reportResponse(sessionId, hostname, text, inputTokens, outputTokens) {
  if (!text || text.length < 5) return;
  post({
    event_type:    'ai_response',
    app:           processLabel(),
    text:          text.slice(0, 2000),
    words:         text.trim().split(/\s+/).length,
    session_id:    sessionId,
    url:           hostname,
    input_tokens:  inputTokens,
    output_tokens: outputTokens,
    timestamp:     Date.now(),
  });
}

// Intercept the inbound HTTP response for SSE capture.
// node.js http.IncomingMessage is an EventEmitter — adding our own 'data'
// listener here is safe and doesn't interfere with the application's listener.
function interceptResponse(res, requestId, hostname) {
  if (res.statusCode < 200 || res.statusCode >= 300) {
    pendingRequests.delete(requestId);
    return;
  }
  const sseChunks = [];
  let   totalBytes = 0;
  res.on('data', (chunk) => {
    if (totalBytes >= MAX_RESPONSE_BYTES) return;
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    sseChunks.push(buf);
    totalBytes += buf.length;
  });
  res.on('end', () => {
    const ctx = pendingRequests.get(requestId);
    const raw = Buffer.concat(sseChunks).toString('utf8');

    const finalize = (sid) => {
      if (!sid) return;
      const { text, inputTokens, outputTokens } = parseSSE(raw);
      reportResponse(sid, hostname, text, inputTokens, outputTokens);
    };

    if (ctx?.sessionId) {
      // Normal case: Palah responded before the stream ended
      pendingRequests.delete(requestId);
      finalize(ctx.sessionId);
    } else if (ctx) {
      // SSE ended before Palah responded — store callback to fire when session_id arrives
      ctx.onSessionId = finalize;
    }
  });
}

// ─── Patch https.request ──────────────────────────────────────────────────────

const _originalRequest = https.request.bind(https);

https.request = function palahRequest(options, callback) {
  const hostname = hostnameFrom(options);
  const reqPath  = pathFrom(options);
  const isAI     = AI_HOSTS.has(hostname) && CHAT_PATH_RE.test(reqPath);

  const req = _originalRequest(options, callback);
  if (!isAI) return req;

  const requestId = genId();
  pendingRequests.set(requestId, { sessionId: null, onSessionId: null });

  // Attach our response listener alongside any callback already registered.
  // Works for both https.request(opts, callback) and req.on('response', fn) usage.
  req.on('response', (res) => interceptResponse(res, requestId, hostname));

  // Wrap write/end to accumulate the outbound request body
  const chunks  = [];
  const _write  = req.write.bind(req);
  const _end    = req.end.bind(req);

  req.write = function(chunk, encoding, cb) {
    if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding || 'utf8'));
    return _write(chunk, encoding, cb);
  };

  req.end = function(chunk, encoding, cb) {
    if (chunk) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding || 'utf8'));
    const entry = parseRequestBody(Buffer.concat(chunks).toString('utf8'), hostname, reqPath);
    if (entry) {
      post(entry, (palahResp) => {
        const sid = palahResp?.session_id ?? null;
        const ctx = pendingRequests.get(requestId);
        if (!ctx) return;
        if (ctx.onSessionId) {
          // SSE already finished — fire the stored callback now
          pendingRequests.delete(requestId);
          ctx.onSessionId(sid);
        } else {
          ctx.sessionId = sid;
        }
      });
    } else {
      pendingRequests.delete(requestId);
    }
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
    const url = typeof input === 'string' ? input : (input?.url ?? String(input));
    let hostname = '', reqPath = '/';
    try { const u = new URL(url); hostname = u.hostname; reqPath = u.pathname; } catch (_) {}

    const isAI = AI_HOSTS.has(hostname) && CHAT_PATH_RE.test(reqPath);
    if (!isAI) return _originalFetch(input, init);

    // Fire the prompt POST concurrently with the AI API call (no blocking delay)
    let sessionIdResolve;
    const sessionIdPromise = new Promise(r => { sessionIdResolve = r; });

    if (init?.body) {
      let bodyStr = null;
      if (typeof init.body === 'string') {
        bodyStr = init.body;
      } else if (init.body instanceof Uint8Array || Buffer.isBuffer(init.body)) {
        bodyStr = Buffer.from(init.body).toString('utf8');
      }
      const entry = bodyStr ? parseRequestBody(bodyStr, hostname, reqPath) : null;
      if (entry) {
        post(entry, (r) => sessionIdResolve(r?.session_id ?? null));
        setTimeout(() => sessionIdResolve(null), 1000); // fallback: unblock if Palah is slow
      } else {
        sessionIdResolve(null);
      }
    } else {
      sessionIdResolve(null);
    }

    const response = await _originalFetch(input, init);

    // Clone response so the page gets an unmodified copy; we read the clone for SSE.
    if (response.body) {
      try {
        const cloned = response.clone();
        // Read with a byte cap via streaming reader
        const rawPromise = (async () => {
          const reader = cloned.body.getReader();
          const dec    = new TextDecoder();
          let raw = '', totalBytes = 0;
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            totalBytes += value.length;
            if (totalBytes <= MAX_RESPONSE_BYTES) raw += dec.decode(value, { stream: true });
            else { reader.cancel(); break; }
          }
          return raw;
        })();

        // Both promises run concurrently; report when both resolve
        Promise.all([sessionIdPromise, rawPromise]).then(([sid, raw]) => {
          if (!sid || !raw) return;
          const { text, inputTokens, outputTokens } = parseSSE(raw);
          reportResponse(sid, hostname, text, inputTokens, outputTokens);
        }).catch(() => {});
      } catch (_) {}
    }

    return response;
  };
}
