// injected.js — Palah fetch interceptor
// Runs in the PAGE's main JavaScript world (not the isolated content-script world).
// Wraps window.fetch to intercept AI API responses and extract:
//   - input/output token counts from SSE streams
//   - file attachment metadata from multipart requests
//
// Communicates back to content.js via window.postMessage with {__palah: true}.
// The page's normal operation is unaffected — we tee the response body so
// both the page and this script read independent copies.

(function () {
  'use strict';

  // ── AI API endpoint patterns ────────────────────────────────────────────────
  // Each entry maps a hostname to URL substrings that identify AI API calls.
  // Add new sites here as their API paths are discovered.

  const API_ENDPOINTS = {
    'chatgpt.com':          ['/backend-api/conversation', '/backend-anon/conversation'],
    'claude.ai':            ['/api/organizations/'],
    'gemini.google.com':    ['StreamGenerateContent', 'generateContent'],
    'perplexity.ai':        ['/rest/sse/', '/socket.io/'],
    'www.perplexity.ai':    ['/rest/sse/', '/socket.io/'],
    'deepseek.com':         ['/api/v0/chat/completion'],
    'chat.deepseek.com':    ['/api/v0/chat/completion'],
    'copilot.microsoft.com':['/c/api/chat'],
  };

  function isAIEndpoint(url) {
    const patterns = API_ENDPOINTS[location.hostname];
    return patterns ? patterns.some(p => url.includes(p)) : false;
  }

  // ── Token extraction per site ───────────────────────────────────────────────
  // Each function receives a parsed JSON object from one SSE chunk and returns
  // { input_tokens, output_tokens } (either field may be null if not in this chunk).

  const TOKEN_EXTRACTORS = {
    'chatgpt.com': (data) => {
      // ChatGPT final chunk: {"usage":{"prompt_tokens":N,"completion_tokens":N}}
      if (data.usage) return {
        input_tokens:  data.usage.prompt_tokens     ?? null,
        output_tokens: data.usage.completion_tokens ?? null,
      };
      return null;
    },

    'claude.ai': (data) => {
      // message_start: {"type":"message_start","message":{"usage":{"input_tokens":N}}}
      if (data.type === 'message_start' && data.message?.usage) return {
        input_tokens:  data.message.usage.input_tokens  ?? null,
        output_tokens: data.message.usage.output_tokens ?? null,
      };
      // message_delta: {"type":"message_delta","usage":{"output_tokens":N}}
      if (data.type === 'message_delta' && data.usage) return {
        input_tokens:  null,
        output_tokens: data.usage.output_tokens ?? null,
      };
      return null;
    },

    'gemini.google.com': (data) => {
      // {"usageMetadata":{"promptTokenCount":N,"candidatesTokenCount":N}}
      if (data.usageMetadata) return {
        input_tokens:  data.usageMetadata.promptTokenCount     ?? null,
        output_tokens: data.usageMetadata.candidatesTokenCount ?? null,
      };
      return null;
    },

    'deepseek.com':      (data) => chatgptStyleUsage(data),
    'chat.deepseek.com': (data) => chatgptStyleUsage(data),
  };

  function chatgptStyleUsage(data) {
    if (data.usage) return {
      input_tokens:  data.usage.prompt_tokens     ?? null,
      output_tokens: data.usage.completion_tokens ?? null,
    };
    return null;
  }

  // ── SSE stream reader ───────────────────────────────────────────────────────

  async function readStreamForTokens(body) {
    const extractor = TOKEN_EXTRACTORS[location.hostname];
    if (!extractor) return;

    let inputTokens  = null;
    let outputTokens = null;

    try {
      const reader  = body.getReader();
      const decoder = new TextDecoder();
      let   buffer  = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';   // keep the incomplete trailing line

        for (const line of lines) {
          // SSE data line — skip comments, event: lines, empty lines
          if (!line.startsWith('data:')) continue;
          const jsonStr = line.slice(5).trim();
          if (!jsonStr || jsonStr === '[DONE]') continue;
          try {
            const chunk  = JSON.parse(jsonStr);
            const tokens = extractor(chunk);
            if (tokens) {
              if (tokens.input_tokens  != null) inputTokens  = tokens.input_tokens;
              if (tokens.output_tokens != null) outputTokens = tokens.output_tokens;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    if (inputTokens !== null || outputTokens !== null) {
      window.postMessage({
        __palah:       true,
        type:          'TOKEN_USAGE',
        input_tokens:  inputTokens,
        output_tokens: outputTokens,
      }, '*');
    }
  }

  // ── Attachment detection from multipart form requests ───────────────────────
  // When the user uploads a file to an AI tool, the browser sends a multipart/form-data
  // request. We capture the filenames from the FormData before it is sent.

  function extractAttachmentsFromRequest(init) {
    const body = init?.body;
    if (!(body instanceof FormData)) return null;
    const files = [];
    for (const [, value] of body.entries()) {
      if (value instanceof File) {
        files.push({ name: value.name, type: value.type, size: value.size });
      }
    }
    return files.length ? files : null;
  }

  // ── fetch interceptor ───────────────────────────────────────────────────────

  const _fetch = window.fetch.bind(window);

  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input
              : input instanceof Request  ? input.url
              : String(input);

    // Check for file uploads on any endpoint
    const attachments = extractAttachmentsFromRequest(init);
    if (attachments) {
      window.postMessage({ __palah: true, type: 'FILE_UPLOAD', attachments }, '*');
    }

    const response = await _fetch(input, init);

    // Intercept AI API streaming responses for token extraction
    if (isAIEndpoint(url) && response.body) {
      try {
        const [pageBody, ourBody] = response.body.tee();
        readStreamForTokens(ourBody);   // read our copy in the background
        return new Response(pageBody, { // give the page its copy
          status:     response.status,
          statusText: response.statusText,
          headers:    response.headers,
        });
      } catch (_) {}
    }

    return response;
  };

})();
