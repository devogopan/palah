// content.js — Palah prompt interceptor
// Runs inside AI tool pages. Captures the prompt text at the moment the user submits.

const AI_TOOL_NAMES = {
  'chatgpt.com': 'ChatGPT',
  'claude.ai': 'Claude',
  'gemini.google.com': 'Gemini',
  'perplexity.ai': 'Perplexity',
  'www.perplexity.ai': 'Perplexity',
  'grok.com': 'Grok',
  'x.com': 'Grok (X)',
  'deepseek.com': 'DeepSeek',
  'chat.deepseek.com': 'DeepSeek',
  'copilot.microsoft.com': 'Microsoft Copilot',
  'www.bing.com': 'Bing Copilot',
  'meta.ai': 'Meta AI',
  'poe.com': 'Poe',
  'you.com': 'You.com',
  'character.ai': 'Character.AI',
  'chat.mistral.ai': 'Mistral',
  'huggingface.co': 'HuggingFace',
};

function toolName() {
  return AI_TOOL_NAMES[location.hostname] ?? location.hostname;
}

// Read the current prompt text from the active element or known selectors.
// Order: active contenteditable → active textarea → site-specific selectors → generic.
function readPromptText() {
  const active = document.activeElement;

  if (active) {
    if (active.isContentEditable) {
      const text = active.innerText.trim();
      if (text) return text;
    }
    if (active.tagName === 'TEXTAREA') {
      const text = active.value.trim();
      if (text) return text;
    }
  }

  // Fallback: known selectors that identify the prompt input on major AI tools
  const selectors = [
    '#prompt-textarea',          // ChatGPT
    '.ProseMirror',              // Claude, Notion AI, many ProseMirror editors
    '[data-testid="chat-input"]',
    'textarea[placeholder]',     // Perplexity, DeepSeek
    'div[contenteditable="true"]',
  ];

  for (const sel of selectors) {
    const el = document.querySelector(sel);
    if (!el) continue;
    const text = (el.innerText ?? el.value ?? '').trim();
    if (text) return text;
  }

  return '';
}

function capturePrompt(source) {
  const text = readPromptText();
  if (!text) return;

  chrome.runtime.sendMessage({
    type: 'PROMPT_CAPTURED',
    text,
    tool: toolName(),
    url: location.hostname,
    source,         // 'enter' | 'button'
    timestamp: Date.now(),
  });
}

// --- Submit detection ---

// 1. Enter key (without Shift, which inserts a newline in most AI tools)
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
    capturePrompt('enter');
  }
}, true); // capture phase — fires before the page's own handlers clear the input

// 2. Send/Submit button clicks — covers tools where Enter does not submit
const SEND_SELECTORS = [
  'button[aria-label*="Send" i]',
  'button[aria-label*="Submit" i]',
  'button[data-testid*="send" i]',
  'button[data-testid*="submit" i]',
  'button[type="submit"]',
].join(', ');

document.addEventListener('click', (e) => {
  if (e.target.closest(SEND_SELECTORS)) {
    capturePrompt('button');
  }
}, true);
