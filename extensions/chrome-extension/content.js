// content.js — Palah prompt interceptor
// Captures: user prompt text + file attachments at submit time,
//           AI response text when streaming completes,
//           input/output token counts extracted by injected.js.

'use strict';

// ─── Inject page-world script ─────────────────────────────────────────────────
// injected.js runs in the PAGE's JS world (not our isolated world) so it can
// wrap window.fetch and read API response streams for token counts.
// Must run at document_start (manifest) so it intercepts fetch before page use.
(function injectPageScript() {
  const s = document.createElement('script');
  s.src = chrome.runtime.getURL('injected.js');
  (document.head || document.documentElement).appendChild(s);
  s.remove();
})();

const AI_TOOL_NAMES = {
  'chatgpt.com':          'ChatGPT',
  'claude.ai':            'Claude',
  'gemini.google.com':    'Gemini',
  'perplexity.ai':        'Perplexity',
  'www.perplexity.ai':    'Perplexity',
  'grok.com':             'Grok',
  'x.com':                'Grok (X)',
  'deepseek.com':         'DeepSeek',
  'chat.deepseek.com':    'DeepSeek',
  'copilot.microsoft.com':'Microsoft Copilot',
  'www.bing.com':         'Bing Copilot',
  'meta.ai':              'Meta AI',
  'poe.com':              'Poe',
  'you.com':              'You.com',
  'character.ai':         'Character.AI',
  'chat.mistral.ai':      'Mistral',
  'huggingface.co':       'HuggingFace',
};

// ─── Per-site selectors ──────────────────────────────────────────────────────
// attachments  : elements showing attached files near the input area
// response     : selector for assistant message containers
// responseRoot : subtree to observe for new response elements
// streamDone   : returns true when streaming has finished
//
// NOTE: These selectors are derived from DOM inspection and may break when
// sites update their markup. Test and update when capture stops working.

const SITE_CONFIG = {
  'chatgpt.com': {
    attachments:  '[data-testid*="file"], [class*="composer"] [class*="attachment"], button[aria-label*="file" i]',
    response:     '[data-message-author-role="assistant"]',
    responseRoot: 'main',
    streamDone:   () => !document.querySelector('[data-testid="stop-button"]'),
  },
  'claude.ai': {
    attachments:  '[data-testid*="attachment"], [class*="file-preview"], [class*="attachment-pill"]',
    response:     '[data-is-streaming="false"]',
    responseRoot: '[class*="conversation"], main',
    streamDone:   () => !!document.querySelector('[data-is-streaming="false"]') &&
                        !document.querySelector('[data-is-streaming="true"]'),
  },
  'gemini.google.com': {
    attachments:  '[class*="attachment"], [class*="file-chip"], [aria-label*="attachment" i]',
    response:     'model-response, [class*="model-response"]',
    responseRoot: '[class*="conversation-container"], main',
    streamDone:   () => !document.querySelector('[class*="loading"], [class*="generating"]'),
  },
  'perplexity.ai': {
    attachments:  '[class*="attachment"], [class*="file"]',
    response:     '[class*="prose"], [class*="answer-text"]',
    responseRoot: 'main',
    streamDone:   () => !document.querySelector('[class*="generating"], [class*="loading-bar"]'),
  },
  'www.perplexity.ai': {
    attachments:  '[class*="attachment"], [class*="file"]',
    response:     '[class*="prose"], [class*="answer-text"]',
    responseRoot: 'main',
    streamDone:   () => !document.querySelector('[class*="generating"]'),
  },
};

// Fallback for sites not in SITE_CONFIG — response capture disabled until configured.
const DEFAULT_CONFIG = {
  attachments:  '[class*="attach"], [class*="file-pill"], [data-testid*="file"], [aria-label*="attachment" i]',
  response:     null,   // null = response capture not configured for this site
  responseRoot: 'body',
  streamDone:   () => true,
};

function siteConfig() {
  return SITE_CONFIG[location.hostname] ?? DEFAULT_CONFIG;
}

function toolName() {
  return AI_TOOL_NAMES[location.hostname] ?? location.hostname;
}

// ─── Prompt text ─────────────────────────────────────────────────────────────

function readPromptText() {
  const active = document.activeElement;
  if (active) {
    if (active.isContentEditable) { const t = active.innerText.trim(); if (t) return t; }
    if (active.tagName === 'TEXTAREA') { const t = active.value.trim(); if (t) return t; }
  }
  const selectors = [
    '#prompt-textarea',
    '.ProseMirror',
    '[data-testid="chat-input"]',
    'textarea[placeholder]',
    'div[contenteditable="true"]',
  ];
  for (const sel of selectors) {
    const el = document.querySelector(sel);
    if (!el) continue;
    const t = (el.innerText ?? el.value ?? '').trim();
    if (t) return t;
  }
  return '';
}

// ─── Attachments ─────────────────────────────────────────────────────────────

function readAttachments() {
  const sel = siteConfig().attachments;
  if (!sel) return [];
  const seen = new Set();
  const result = [];
  for (const el of document.querySelectorAll(sel)) {
    const name = extractFilename(el);
    if (name && !seen.has(name)) {
      seen.add(name);
      result.push({ name, type: fileExt(name) });
    }
  }
  return result;
}

function extractFilename(el) {
  // Try structured attributes first, then text content
  const candidates = [
    el.getAttribute('aria-label'),
    el.getAttribute('title'),
    el.querySelector('img')?.alt,
    el.textContent,
  ];
  for (const c of candidates) {
    const text = c?.trim();
    // Accept strings that look like filenames (have an extension, not too long)
    if (text && /\.\w{1,5}$/.test(text) && text.length < 200) return text;
  }
  return null;
}

function fileExt(name) {
  return (name.match(/\.(\w{1,5})$/) ?? [])[1]?.toLowerCase() ?? 'unknown';
}

// ─── Prompt capture ───────────────────────────────────────────────────────────

// pendingSession : set when Palah returns session_id after a prompt POST.
// pendingCapture : set at submit time with response config and pre-submit count.
// pendingTokens  : accumulates token counts from injected.js as the stream arrives.
// pendingUploads : file metadata from fetch-intercepted multipart uploads.
let pendingSession = null;
let pendingCapture = null;
let pendingTokens  = { input_tokens: null, output_tokens: null };
let pendingUploads = [];
let lastCaptureTime = 0;   // debounce: ignore duplicate Enter+button events

// ── Messages from injected.js (page world → content world) ──────────────────
window.addEventListener('message', (e) => {
  if (!e.data?.__palah) return;

  if (e.data.type === 'TOKEN_USAGE') {
    // Accumulate — Claude sends input in one chunk, output in another
    if (e.data.input_tokens  != null) pendingTokens.input_tokens  = e.data.input_tokens;
    if (e.data.output_tokens != null) pendingTokens.output_tokens = e.data.output_tokens;
  }

  if (e.data.type === 'FILE_UPLOAD' && Array.isArray(e.data.attachments)) {
    // Merge with DOM-detected attachments (injected.js sees the actual File objects)
    for (const f of e.data.attachments) {
      if (!pendingUploads.find(u => u.name === f.name)) pendingUploads.push(f);
    }
  }
});

function capturePrompt(source) {
  // Debounce — Enter key and button click can both fire within a few ms
  const now = Date.now();
  if (now - lastCaptureTime < 300) return;
  lastCaptureTime = now;

  const text = readPromptText();
  if (!text) return;

  const cfg = siteConfig();

  // Merge DOM-detected attachment names with any already-intercepted File objects
  const domAttachments   = readAttachments();
  const mergedAttachments = [...pendingUploads];
  for (const a of domAttachments) {
    if (!mergedAttachments.find(u => u.name === a.name)) mergedAttachments.push(a);
  }
  pendingUploads = [];  // reset for next turn

  // Reset token accumulator for this new turn
  pendingTokens = { input_tokens: null, output_tokens: null };

  // Snapshot response count now (before streaming starts) and queue capture
  if (cfg.response) {
    const countBefore = document.querySelectorAll(cfg.response).length;
    pendingCapture = { cfg, countBefore };
    scheduleResponseCapture();
  }

  chrome.runtime.sendMessage({
    type:        'PROMPT_CAPTURED',
    event_type:  'user_prompt',
    text,
    tool:        toolName(),
    url:         location.hostname,
    source,
    words:       text.trim().split(/\s+/).length,
    attachments: mergedAttachments,
    timestamp:   now,
  });
}

// ─── Response capture ─────────────────────────────────────────────────────────
// Capture by CONTENT STABILITY, not by a site-specific "is generating" selector.
// Those selectors break when sites change markup, which made streamDone() report
// "done" immediately and capture a partial response. Instead we poll the latest
// response element and only capture once its text has stopped growing for
// STREAM_SETTLE_MS — robust across sites and immune to streaming-indicator changes.

let responsePoll       = null;
const STREAM_SETTLE_MS = 1500;     // text must be unchanged this long to count as complete
const RESPONSE_POLL_MS = 400;      // how often to sample the response element
const RESPONSE_MAX_MS  = 300_000;  // give up after 5 minutes

function scheduleResponseCapture() {
  if (responsePoll) { clearInterval(responsePoll); responsePoll = null; }
  // Small delay so the submit completes and response elements start appearing
  setTimeout(startResponsePolling, 300);
}

function startResponsePolling() {
  if (!pendingCapture?.cfg.response) return;
  const cfg       = pendingCapture.cfg;
  const startedAt = Date.now();
  let   lastLen   = 0;
  let   lastGrowth = Date.now();

  responsePoll = setInterval(() => {
    if (!pendingCapture) { clearInterval(responsePoll); responsePoll = null; return; }

    const fresh = [...document.querySelectorAll(cfg.response)].slice(pendingCapture.countBefore);
    const el    = fresh[fresh.length - 1];
    const text  = el?.innerText?.trim() ?? '';

    if (text.length > lastLen) {        // still growing → reset the settle clock
      lastLen    = text.length;
      lastGrowth = Date.now();
    }

    // Done when the text has been stable long enough. streamDone() is only an
    // optional extra guard — if its selector is stale (always true) we fall back
    // entirely to the stability signal.
    const stable      = text.length >= 10 && (Date.now() - lastGrowth) >= STREAM_SETTLE_MS;
    const streamDoneOk = !cfg.streamDone || cfg.streamDone();
    const timedOut    = Date.now() - startedAt > RESPONSE_MAX_MS;

    if ((stable && streamDoneOk) || timedOut) {
      clearInterval(responsePoll); responsePoll = null;
      if (text.length >= 10) finalizeResponse(text);
      pendingCapture = null;
    }
  }, RESPONSE_POLL_MS);
}

function finalizeResponse(text) {
  const payload = {
    type:          'PROMPT_CAPTURED',
    event_type:    'ai_response',
    text,
    tool:          toolName(),
    url:           location.hostname,
    source:        'response',
    words:         text.split(/\s+/).length,
    // Token counts extracted by injected.js from the SSE stream
    input_tokens:  pendingTokens.input_tokens,
    output_tokens: pendingTokens.output_tokens,
    timestamp:     Date.now(),
  };
  pendingTokens = { input_tokens: null, output_tokens: null };

  // Attach session_id so Palah writes the response to the same turn file as the prompt
  if (pendingSession) {
    payload.session_id = pendingSession.session_id;
    payload.turn       = pendingSession.turn;
    pendingSession = null;
  }

  chrome.runtime.sendMessage(payload);
}

// Receive session context back from background.js after Palah processes the prompt
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === 'PALAH_SESSION_CONTEXT') {
    pendingSession = { session_id: msg.session_id, turn: msg.turn };
  }
});

// ─── Submit detection ─────────────────────────────────────────────────────────

document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
    capturePrompt('enter');
  }
}, true);

const SEND_SELECTORS = [
  'button[aria-label*="Send" i]',
  'button[aria-label*="Submit" i]',
  'button[data-testid*="send" i]',
  'button[data-testid*="submit" i]',
  'button[type="submit"]',
].join(', ');

document.addEventListener('click', (e) => {
  if (e.target.closest(SEND_SELECTORS)) capturePrompt('button');
}, true);
