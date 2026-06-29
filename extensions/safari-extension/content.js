// content.js — Palah prompt interceptor (Safari)
// Identical to chrome content.js, but the Palah relay goes through the
// native bridge: content.js → sendMessage → background.js → sendNativeMessage
// → SafariWebExtensionHandler → URLSession POST localhost:45678.
// (Direct fetch to http://localhost is blocked from an HTTPS page by
// mixed-content policy, so it cannot be done in the content script.)

'use strict';

console.log('[Palah] content.js v4 loaded on', location.hostname);

// ─── Inject page-world script ─────────────────────────────────────────────────
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

const DEFAULT_CONFIG = {
  attachments:  '[class*="attach"], [class*="file-pill"], [data-testid*="file"], [aria-label*="attachment" i]',
  response:     null,
  responseRoot: 'body',
  streamDone:   () => true,
};

function siteConfig() { return SITE_CONFIG[location.hostname] ?? DEFAULT_CONFIG; }
function toolName()   { return AI_TOOL_NAMES[location.hostname] ?? location.hostname; }

// ─── Prompt text ─────────────────────────────────────────────────────────────

function readPromptText() {
  const active = document.activeElement;
  if (active) {
    if (active.isContentEditable) { const t = active.innerText.trim(); if (t) return t; }
    if (active.tagName === 'TEXTAREA') { const t = active.value.trim(); if (t) return t; }
  }
  const selectors = [
    '#prompt-textarea', '.ProseMirror', '[data-testid="chat-input"]',
    'textarea[placeholder]', 'div[contenteditable="true"]',
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
    if (name && !seen.has(name)) { seen.add(name); result.push({ name, type: fileExt(name) }); }
  }
  return result;
}

function extractFilename(el) {
  const candidates = [
    el.getAttribute('aria-label'), el.getAttribute('title'),
    el.querySelector('img')?.alt, el.textContent,
  ];
  for (const c of candidates) {
    const text = c?.trim();
    if (text && /\.\w{1,5}$/.test(text) && text.length < 200) return text;
  }
  return null;
}

function fileExt(name) {
  return (name.match(/\.(\w{1,5})$/) ?? [])[1]?.toLowerCase() ?? 'unknown';
}

// ─── Prompt capture ───────────────────────────────────────────────────────────

let pendingSession = null;
let pendingCapture = null;
let pendingTokens  = { input_tokens: null, output_tokens: null };
let pendingUploads = [];
let lastCaptureTime = 0;

window.addEventListener('message', (e) => {
  if (!e.data?.__palah) return;
  if (e.data.type === 'TOKEN_USAGE') {
    if (e.data.input_tokens  != null) pendingTokens.input_tokens  = e.data.input_tokens;
    if (e.data.output_tokens != null) pendingTokens.output_tokens = e.data.output_tokens;
  }
  if (e.data.type === 'FILE_UPLOAD' && Array.isArray(e.data.attachments)) {
    for (const f of e.data.attachments) {
      if (!pendingUploads.find(u => u.name === f.name)) pendingUploads.push(f);
    }
  }
});

function capturePrompt(source) {
  const now = Date.now();
  if (now - lastCaptureTime < 300) return;
  lastCaptureTime = now;

  const text = readPromptText();
  if (!text) return;

  const cfg = siteConfig();
  const domAttachments    = readAttachments();
  const mergedAttachments = [...pendingUploads];
  for (const a of domAttachments) {
    if (!mergedAttachments.find(u => u.name === a.name)) mergedAttachments.push(a);
  }
  pendingUploads = [];
  pendingTokens  = { input_tokens: null, output_tokens: null };

  if (cfg.response) {
    const countBefore = document.querySelectorAll(cfg.response).length;
    pendingCapture = { cfg, countBefore };
    scheduleResponseObserver();
  }

  const payload = {
    type:        'PROMPT_CAPTURED',
    event_type:  'user_prompt',
    text,
    tool:        toolName(),
    url:         location.hostname,
    source,
    words:       text.trim().split(/\s+/).length,
    attachments: mergedAttachments,
    timestamp:   now,
  };

  // Relay to background.js, which forwards to Palah via native messaging.
  // (Direct fetch to http://localhost is blocked from this HTTPS page by
  // mixed-content policy, so the native bridge is the only working path.)
  chrome.runtime.sendMessage(payload);
}

// ─── Response capture ─────────────────────────────────────────────────────────

let responseObserver = null;
let responseTimer    = null;
const STREAM_SETTLE_MS = 1200;

function scheduleResponseObserver() {
  if (responseObserver) responseObserver.disconnect();
  setTimeout(startResponseObserver, 200);
}

function startResponseObserver() {
  if (!pendingCapture?.cfg.response) return;
  const cfg  = pendingCapture.cfg;
  const root = document.querySelector(cfg.responseRoot) ?? document.body;

  responseObserver = new MutationObserver(() => {
    clearTimeout(responseTimer);
    if (cfg.streamDone()) {
      responseTimer = setTimeout(tryCapture, STREAM_SETTLE_MS);
    } else {
      responseTimer = setTimeout(() => { if (cfg.streamDone()) tryCapture(); }, STREAM_SETTLE_MS);
    }
  });

  responseObserver.observe(root, { childList: true, subtree: true, characterData: true });
  setTimeout(() => {
    if (responseObserver) { responseObserver.disconnect(); responseObserver = null; }
  }, 300_000);
}

function tryCapture() {
  if (!pendingCapture) return;
  const { cfg, countBefore } = pendingCapture;

  const allResponses = [...document.querySelectorAll(cfg.response)];
  const newResponses = allResponses.slice(countBefore);
  if (!newResponses.length) return;

  const responseEl = newResponses[newResponses.length - 1];
  const text = responseEl?.innerText?.trim() ?? '';
  if (text.length < 10) return;

  if (responseObserver) { responseObserver.disconnect(); responseObserver = null; }
  clearTimeout(responseTimer);
  pendingCapture = null;

  const payload = {
    type:          'PROMPT_CAPTURED',
    event_type:    'ai_response',
    text,
    tool:          toolName(),
    url:           location.hostname,
    source:        'response',
    words:         text.split(/\s+/).length,
    input_tokens:  pendingTokens.input_tokens,
    output_tokens: pendingTokens.output_tokens,
    timestamp:     Date.now(),
  };
  pendingTokens = { input_tokens: null, output_tokens: null };

  if (pendingSession) {
    payload.session_id = pendingSession.session_id;
    payload.turn       = pendingSession.turn;
    pendingSession     = null;
  }

  // Relay to background.js → native bridge → Palah
  chrome.runtime.sendMessage(payload);
}

// ─── Submit detection ─────────────────────────────────────────────────────────

document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey) capturePrompt('enter');
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
