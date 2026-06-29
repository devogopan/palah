// background.js — Palah service worker
// Receives captured events, stores locally, forwards to Palah native agent.
// For user_prompt events: relays the session_id Palah returns so the content
// script can correlate the subsequent AI response to the same turn file.

'use strict';

const PALAH_ENDPOINT = 'http://localhost:45678/prompt';
const MAX_CAPTURES   = 100;

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type !== 'PROMPT_CAPTURED') return;

  // Store locally for popup display
  chrome.storage.local.get(['captures'], (result) => {
    const captures = result.captures ?? [];
    captures.unshift(message);
    if (captures.length > MAX_CAPTURES) captures.length = MAX_CAPTURES;
    chrome.storage.local.set({ captures });
    const count = captures.length > 99 ? '99+' : String(captures.length);
    chrome.action.setBadgeText({ text: count });
    chrome.action.setBadgeBackgroundColor({ color: '#dc2626' });
  });

  // Forward to Palah native agent
  fetch(PALAH_ENDPOINT, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify(message),
  })
  .then(r => r.json())
  .then(data => {
    // For user_prompt events Palah returns {session_id, turn}.
    // Relay it back to the tab so the content script can attach it to the
    // AI response (which arrives later) for same-turn-file correlation.
    if (data.session_id && message.event_type === 'user_prompt' && sender.tab?.id) {
      chrome.tabs.sendMessage(sender.tab.id, {
        type:       'PALAH_SESSION_CONTEXT',
        session_id: data.session_id,
        turn:       data.turn ?? 1,
      });
    }
  })
  .catch(() => {});  // silently ignore if Palah app is not running
});
