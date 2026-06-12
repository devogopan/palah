// popup.js — Palah extension popup

function timeAgo(ts) {
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 5)   return 'just now';
  if (s < 60)  return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  return `${Math.floor(s / 3600)}h ago`;
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function render(captures) {
  const list    = document.getElementById('list');
  const count   = document.getElementById('count');

  count.textContent = captures.length === 0 ? '' : `${captures.length} captured`;

  if (captures.length === 0) {
    list.innerHTML = `
      <div class="empty">
        <strong>No prompts captured yet</strong>
        Open an AI tool in Chrome and send a message — it will appear here.
      </div>`;
    return;
  }

  list.innerHTML = captures.map(c => `
    <div class="capture">
      <div class="capture-meta">
        <span class="tool">${escapeHtml(c.tool)}</span>
        <span class="meta-right">
          <span class="source">${c.source === 'enter' ? '↵' : '⏎ btn'}</span>
          <span class="time">${timeAgo(c.timestamp)}</span>
        </span>
      </div>
      <div class="text">${escapeHtml(c.text)}</div>
    </div>
  `).join('');
}

// Load and display
chrome.storage.local.get(['captures'], (result) => {
  render(result.captures ?? []);
});

// Clear all
document.getElementById('clearBtn').addEventListener('click', () => {
  chrome.storage.local.set({ captures: [] });
  chrome.action.setBadgeText({ text: '' });
  render([]);
});
