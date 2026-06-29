// background.js — Palah service worker (Safari)
//
// WHY sendNativeMessage (not fetch):
// Direct fetch('http://localhost:45678') from content.js is blocked by Safari's
// mixed-content policy (HTTPS page → HTTP server). The native messaging bridge
// sidesteps this: JS calls sendNativeMessage → SafariWebExtensionHandler.swift
// receives it natively → URLSession POSTs to localhost (no mixed-content limit).
//
// REQUIRES the manifest to declare "nativeMessaging" in permissions.
// Without it, sendNativeMessage silently rejects and nothing reaches the handler.

'use strict';

const MAX_CAPTURES = 100;

browser.runtime.onMessage.addListener((message, sender) => {
  if (message.type !== 'PROMPT_CAPTURED') return;

  // Store locally for popup display
  browser.storage.local.get(['captures']).then(result => {
    const captures = result.captures ?? [];
    captures.unshift(message);
    if (captures.length > MAX_CAPTURES) captures.length = MAX_CAPTURES;
    browser.storage.local.set({ captures });
    const count = captures.length > 99 ? '99+' : String(captures.length);
    browser.action.setBadgeText({ text: count });
    browser.action.setBadgeBackgroundColor({ color: '#dc2626' });
  });

  // Forward to Palah native app via native messaging bridge.
  // SafariWebExtensionHandler.swift receives this and POSTs to localhost:45678.
  console.log('[Palah bg] sending native message', message.event_type);
  browser.runtime.sendNativeMessage('com.devogopan.palah.safari', message)
    .then(response => {
      console.log('[Palah bg] native message response', JSON.stringify(response));
      if (response?.session_id && message.event_type === 'user_prompt' && sender.tab?.id) {
        browser.tabs.sendMessage(sender.tab.id, {
          type:       'PALAH_SESSION_CONTEXT',
          session_id: response.session_id,
          turn:       response.turn ?? 1,
        });
      }
    })
    .catch(err => { console.log('[Palah bg] native message error', String(err)); });
});
