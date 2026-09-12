#!/usr/bin/env node
// mimo-search-mcp.mjs — minimal, dependency-free MCP (stdio) server that
// exposes a `web_search` tool backed by Xiaomi MiMo's web-search plugin.
//
// Claude Code (via claudex) calls web_search -> this bridge hits MiMo's
// OpenAI-compatible /v1/chat/completions with tools:[{type:"web_search"}]
// using a pay-as-you-go key, and returns the grounded answer + source URLs.
//
// Key: MIMO_PAYGO_KEY env, else ~/.claude/mimo_paygo_token.
// Base/model overridable via MIMO_SEARCH_BASE / MIMO_SEARCH_MODEL.
//
// NOTE: intentionally written without JS template literals (no dollar-brace)
// so it survives OpenTofu templatefile() rendering unescaped in cloud-init.

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const BASE = (process.env.MIMO_SEARCH_BASE || 'https://api.xiaomimimo.com').replace(/\/+$/, '');
const MODEL = process.env.MIMO_SEARCH_MODEL || 'mimo-v2.5';

function getKey() {
  if (process.env.MIMO_PAYGO_KEY && process.env.MIMO_PAYGO_KEY.trim()) {
    return process.env.MIMO_PAYGO_KEY.trim();
  }
  try {
    return readFileSync(path.join(homedir(), '.claude', 'mimo_paygo_token'), 'utf8').trim();
  } catch {
    return '';
  }
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}
function respond(id, result) {
  send({ jsonrpc: '2.0', id, result });
}
function respondError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

const TOOL = {
  name: 'web_search',
  description:
    'Search the public web via Xiaomi MiMo and return a grounded answer with source citations. ' +
    'Use for current events, news, prices, docs, or anything beyond the model knowledge cutoff.',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'The search query or question.' },
      limit: { type: 'number', description: 'Max sources to consult (default 5).' },
    },
    required: ['query'],
  },
};

async function doSearch(query, limit) {
  const key = getKey();
  if (!key) throw new Error('No MiMo pay-as-you-go key (MIMO_PAYGO_KEY or ~/.claude/mimo_paygo_token).');
  const body = {
    model: MODEL,
    max_completion_tokens: 1024,
    messages: [
      {
        role: 'system',
        content:
          'You are a web-search backend. Search the web for the user query and answer concisely ' +
          'in the same language as the query, grounding every claim in the cited sources.',
      },
      { role: 'user', content: String(query || '') },
    ],
    tools: [{ type: 'web_search', force_search: true, limit: Number(limit) > 0 ? Number(limit) : 5 }],
  };
  const res = await fetch(BASE + '/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer ' + key },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error('MiMo search HTTP ' + res.status + ': ' + text.slice(0, 500));
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error('MiMo search: unparseable response: ' + text.slice(0, 300));
  }
  const msg = (data.choices && data.choices[0] && data.choices[0].message) || {};
  const answer = (msg.content || '').trim();
  const cites = Array.isArray(msg.annotations) ? msg.annotations.filter((a) => a && a.type === 'url_citation') : [];
  let out = answer || '(no answer returned)';
  if (cites.length) {
    const lines = cites.map(function (c, i) {
      const head = i + 1 + '. ' + (c.title || c.url) + ' — ' + c.url;
      return c.summary ? head + '\n   ' + c.summary : head;
    });
    out += '\n\nSources:\n' + lines.join('\n');
  }
  return out;
}

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    respond(id, {
      protocolVersion: (params && params.protocolVersion) || '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'mimo-search', version: '1.0.0' },
    });
  } else if (method === 'tools/list') {
    respond(id, { tools: [TOOL] });
  } else if (method === 'tools/call') {
    const name = params && params.name;
    if (name !== 'web_search') {
      respondError(id, -32602, 'Unknown tool: ' + name);
      return;
    }
    const args = (params && params.arguments) || {};
    try {
      const out = await doSearch(args.query, args.limit);
      respond(id, { content: [{ type: 'text', text: out }] });
    } catch (e) {
      respond(id, { content: [{ type: 'text', text: 'web_search error: ' + e.message }], isError: true });
    }
  } else if (method === 'ping') {
    respond(id, {});
  } else if (id !== undefined && method) {
    respondError(id, -32601, 'Method not found: ' + method);
  }
  // Notifications (no id) are ignored.
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try {
    msg = JSON.parse(s);
  } catch {
    return;
  }
  Promise.resolve(handle(msg)).catch(() => {});
});
