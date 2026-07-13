'use strict';
// palah-relay.js — BASE_URL relay for Palah
// Receives AI API requests, logs prompts, forwards to real upstream.
// No certs needed — plain HTTP on loopback, HTTPS to real APIs.

const http  = require('http');
const https = require('https');
const fs    = require('fs');

const RELAY_PORT = 45679;
const PALAH_PORT = 45678;
const LOG_PATH   = '/tmp/palah.log';

function ts() { return new Date().toISOString(); }

function logJSON(obj) {
  try { fs.appendFileSync(LOG_PATH, JSON.stringify(obj) + '\n'); } catch (_) {}
}

function notifyPalah(entry) {
  try {
    const body = JSON.stringify({ type: 'PROMPT_CAPTURED', source: 'relay', ...entry });
    const r = http.request({
      hostname: '127.0.0.1', port: PALAH_PORT, path: '/prompt', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    });
    r.on('error', () => {});
    r.write(body); r.end();
  } catch (_) {}
}

// Route to the correct upstream based on path and auth header
function resolveUpstream(req) {
  const path    = req.url || '/';
  const hasApiKey = !!(req.headers['x-api-key']);
  if (hasApiKey || path.includes('/messages')) return 'api.anthropic.com';
  return 'api.openai.com';
}

const CHAT_PATH_RE = /\/(messages|chat\/completions)/;

function extractPrompt(bodyStr) {
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
    return { model: json.model || 'unknown', messageCount: messages.length, text };
  } catch (_) { return null; }
}

function detectApp(req) {
  const ua = (req.headers['user-agent'] || '').toLowerCase();
  if (ua.includes('claude'))       return 'claude-code';
  if (ua.includes('cursor'))       return 'cursor';
  if (ua.includes('anthropic'))    return 'anthropic-sdk';
  if (ua.includes('openai'))       return 'openai-sdk';
  if (ua.includes('python'))       return 'python';
  return ua.split('/')[0] || 'unknown';
}

http.createServer((req, res) => {

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin':  '*',
      'Access-Control-Allow-Headers': '*',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    });
    res.end();
    return;
  }

  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', server: 'palah-relay', port: RELAY_PORT }) + '\n');
    return;
  }

  const upstream = resolveUpstream(req);
  const chunks   = [];

  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const bodyBuf = Buffer.concat(chunks);
    const bodyStr = bodyBuf.toString('utf8');

    // Log only chat/messages endpoints
    if (CHAT_PATH_RE.test(req.url)) {
      const parsed = extractPrompt(bodyStr);
      if (parsed && parsed.text) {
        const app   = detectApp(req);
        const words = parsed.text.trim().split(/\s+/).filter(Boolean).length;
        const entry = {
          ts: ts(), event: 'submit', source: 'relay', app,
          url: upstream, endpoint: req.url,
          model: parsed.model, messageCount: parsed.messageCount,
          words, preview: parsed.text.slice(0, 120), text: parsed.text.slice(0, 500),
        };
        logJSON(entry);
        notifyPalah(entry);
        console.log(`[${ts()}] ${app} → ${upstream}${req.url}  words=${words}  model=${parsed.model}`);
      }
    }

    // Forward request to real upstream — pipe streaming response straight back
    const fwdHeaders = Object.assign({}, req.headers, { host: upstream });
    delete fwdHeaders['content-encoding']; // avoid decompression mismatch

    const fwdReq = https.request(
      { hostname: upstream, port: 443, path: req.url, method: req.method, headers: fwdHeaders },
      fwdRes => {
        res.writeHead(fwdRes.statusCode, fwdRes.headers);
        fwdRes.pipe(res);
      }
    );

    fwdReq.on('error', e => {
      console.error('upstream error:', e.message);
      if (!res.headersSent) { res.writeHead(502); res.end('upstream error'); }
    });

    fwdReq.write(bodyBuf);
    fwdReq.end();
  });

}).listen(RELAY_PORT, '127.0.0.1', () => {
  console.log(`\nPalah relay  http://127.0.0.1:${RELAY_PORT}`);
  console.log('  Anthropic → export ANTHROPIC_BASE_URL=http://localhost:45679');
  console.log('  OpenAI    → export OPENAI_BASE_URL=http://localhost:45679');
  console.log('  Logs      → tail -f /tmp/palah.log\n');
});
