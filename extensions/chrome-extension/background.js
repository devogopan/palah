// background.js — Palah service worker
// Receives captured prompts, stores them locally, and (Phase 2) forwards to Palah agent.

const MAX_CAPTURES = 100;

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type !== 'PROMPT_CAPTURED') return;

  chrome.storage.local.get(['captures'], (result) => {
    const captures = result.captures ?? [];
    captures.unshift(message); // newest first
    if (captures.length > MAX_CAPTURES) captures.length = MAX_CAPTURES;
    chrome.storage.local.set({ captures });

    // Show count badge on extension icon
    const count = captures.length > 99 ? '99+' : String(captures.length);
    chrome.action.setBadgeText({ text: count });
    chrome.action.setBadgeBackgroundColor({ color: '#dc2626' });
  });

  // POST to Palah native agent — runs PII/secret detection and forwards to control plane.
  fetch('http://localhost:45678/prompt', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(message),
  }).catch(() => {});  // silently ignore if Palah app is not running
});
