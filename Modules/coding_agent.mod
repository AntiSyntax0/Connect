//==== module ====
{
  "id": "coding_agent",
  "name": "Coding agent sidebar",
  "description": "A chat sidebar for coding agents. Uses the Claude Code CLI already installed on this PC, so your own Claude subscription does the work: no API key and nothing is sent anywhere by Connect.",
  "version": "0.2.0",
  "minApi": 3,
  "permissions": [
    "spawn",
    "ssh",
    "sshStream",
    "data"
  ],
  "binaries": [
    "claude"
  ],
  "config": [
    {
      "key": "mode",
      "label": "Default permissions",
      "type": "select",
      "default": "manual",
      "options": [
        {
          "label": "Ask before editing files or running commands",
          "value": "manual"
        },
        {
          "label": "Allow file edits, ask for commands",
          "value": "acceptEdits"
        },
        {
          "label": "Plan only (no changes)",
          "value": "plan"
        },
        {
          "label": "Allow everything (dangerous)",
          "value": "bypassPermissions"
        }
      ],
      "help": "Can be changed per chat in the sidebar."
    },
    {
      "key": "model",
      "label": "Default model",
      "type": "select",
      "default": "",
      "options": [
        {
          "label": "Claude Code default",
          "value": ""
        },
        {
          "label": "Sonnet",
          "value": "sonnet"
        },
        {
          "label": "Opus",
          "value": "opus"
        },
        {
          "label": "Haiku",
          "value": "haiku"
        }
      ]
    },
    {
      "key": "folder",
      "label": "Default folder",
      "type": "text",
      "placeholder": "/home/me/project (empty = your home folder)"
    }
  ]
}
//==== main ====
// Coding agent sidebar (main process): runs the Claude Code CLI (`claude -p --input-format stream-json --output-format stream-json`) as a child process
// per chat and turns its event stream into a simple list of "items" (user / text / thinking / tool / error) that the window draws.
// Login and billing stay with the CLI itself (your own Claude account); this module never sees a token.
// Tool permission questions are answered over the CLI's control protocol (--permission-prompt-tool stdio).
const MODES = ['manual', 'acceptEdits', 'plan', 'bypassPermissions'];
const MODELS = ['', 'sonnet', 'opus', 'haiku'];
const MAX_ITEMS = 400, TOOL_OUT = 6000;
const sessions = new Map(); // id -> live state (proc, items, ...)
const rid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
const clip = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + `\n… (${s.length - n} more characters)` : s; };

// ---- persistence: chat list + finished transcript, so chats survive a restart (and resume with the CLI's own session id) ----
let saveT = null;
function persist(now) {
  clearTimeout(saveT);
  const go = () => { try { api.store.set({ chats: [...sessions.values()].map((s) => ({ id: s.id, title: s.title, cwd: s.cwd, target: s.target, where: s.where, mode: s.mode, model: s.model, claudeId: s.claudeId, created: s.created, items: s.items.slice(-MAX_ITEMS).map((i) => ({ ...i, streaming: false })) })) }); } catch (e) { api.log('save failed: ' + e.message); } };
  if (now) go(); else saveT = setTimeout(go, 800);
}
function restore() {
  const st = api.store.get();
  for (const c of st.chats || []) sessions.set(c.id, { id: c.id, title: c.title || 'Chat', cwd: c.cwd || '', target: c.target || '', where: c.where || '', mode: MODES.includes(c.mode) ? c.mode : 'manual', model: c.model || '', claudeId: c.claudeId || '', created: c.created || Date.now(), items: Array.isArray(c.items) ? c.items : [], proc: null, busy: false, buf: '', err: '', blocks: new Map(), streamed: new Set(), tools: new Map(), pending: new Map(), rate: null });
}
const brief = (s) => ({ id: s.id, title: s.title, cwd: s.cwd, target: s.target, where: s.where, mode: s.mode, model: s.model, busy: s.busy, running: !!s.proc, rate: s.rate, claudeId: s.claudeId });
const emitS = (s) => api.emit('session', brief(s));

// ---- items ----
const pendingEmit = new Map();
function push(s, item) { s.items.push(item); if (s.items.length > MAX_ITEMS * 1.5) { s.items.splice(0, s.items.length - MAX_ITEMS); api.emit('items', { id: s.id, reset: true, items: s.items }); return s.items.length - 1; } api.emit('item', { id: s.id, idx: s.items.length - 1, item: item }); return s.items.length - 1; }
function touch(s, idx, soft) { // item changed: tell the window (deltas are throttled)
  const send = () => { pendingEmit.delete(s.id + ':' + idx); if (s.items[idx]) api.emit('item', { id: s.id, idx, item: s.items[idx] }); };
  if (!soft) return send();
  if (!pendingEmit.has(s.id + ':' + idx)) pendingEmit.set(s.id + ':' + idx, setTimeout(send, 60));
}
function tool(s, toolId) { // the item for a tool call (created on first sight: the permission question can arrive before the call's own message)
  let i = s.tools.get(toolId);
  if (i === undefined || !s.items[i] || s.items[i].toolId !== toolId) { i = push(s, { k: 'tool', toolId, name: '', input: {}, status: 'running', result: '' }); s.tools.set(toolId, i); }
  return i;
}

// ---- the CLI process ----
function args(s) {
  const a = ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-prompt-tool', 'stdio', '--permission-mode', s.mode];
  if (s.model) a.push('--model', s.model);
  if (s.claudeId) a.push('--resume', s.claudeId);
  return a;
}
// ---- where the CLI runs: this PC, or a saved SSH server ----
const sq = (v) => "'" + String(v).replace(/'/g, "'\\''") + "'";
const conns = new Map(); // server id -> Promise<connection> (one login shared by all chats and checks on that server)
function savedServers() { return (api.data.read('servers.json', []) || []).filter((x) => x && (!x.type || x.type === 'ssh')); }
function serverById(id) { const x = savedServers().find((v) => v.id === id); if (!x) throw new Error('That server is no longer in your list'); return x; }
function connFor(id) {
  if (conns.has(id)) return conns.get(id);
  const x = serverById(id);
  if (x.jumpId) throw new Error(`"${x.name || x.host}" is reached through a jump host, which this module can't use yet.`);
  const pr = api.ssh.connect({ host: x.host, port: x.port, username: x.username, authType: x.authType, keyPath: x.keyPath, password: api.secret.dec(x.password), passphrase: api.secret.dec(x.passphrase), name: x.name });
  conns.set(id, pr); pr.catch(() => { if (conns.get(id) === pr) conns.delete(id); });
  return pr;
}
const dropConn = (id) => { const pr = conns.get(id); conns.delete(id); if (pr) pr.then((c) => c.close(), () => {}); };
// Run through the user's login shell on the server, so PATH from ~/.profile / ~/.bashrc (nvm, ~/.local/bin, ...) applies.
const remoteCmd = (script) => `"\${SHELL:-/bin/sh}" -lc ${sq(script)}`;
const remoteCd = (cwd) => { cwd = String(cwd || '').trim(); if (!cwd) return ''; return 'cd ' + (cwd === '~' ? '"$HOME"' : cwd.startsWith('~/') ? '"$HOME"/' + sq(cwd.slice(2)) : sq(cwd)) + ' && '; };
async function detectOn(target) {
  if (!target) { const p = api.proc.which('claude'); return { installed: !!p, path: p, where: 'this PC' }; }
  const x = serverById(target), c = await connFor(target);
  const r = await c.exec(remoteCmd('command -v claude && claude --version'), null, 20000);
  const [path, version] = r.out.trim().split('\n');
  return { installed: r.code === 0 && !!path, path: path || '', version: version || '', where: x.name || x.host };
}

async function ensureProc(s) {
  if (s.proc) return s.proc;
  let p;
  if (!s.target) p = api.proc.spawn('claude', args(s), { cwd: s.cwd || api.config().folder || undefined });
  else {
    const script = remoteCd(s.cwd) + 'exec claude ' + args(s).map(sq).join(' ');
    try { p = await (await connFor(s.target)).spawn(remoteCmd(script), { pty: false }); }
    catch (e) { dropConn(s.target); p = await (await connFor(s.target)).spawn(remoteCmd(script), { pty: false }); } // the login may have gone stale: retry once on a fresh one
  }
  s.proc = p; s.buf = ''; s.err = '';
  p.onData((chunk, isErr) => {
    if (isErr) { s.err = (s.err + chunk).slice(-4000); return; }
    s.buf += chunk;
    let nl; while ((nl = s.buf.indexOf('\n')) >= 0) { const line = s.buf.slice(0, nl).trim(); s.buf = s.buf.slice(nl + 1); if (line) { try { onEvent(s, JSON.parse(line)); } catch (e) { api.log('bad event: ' + e.message + ' :: ' + line.slice(0, 120)); } } }
  });
  p.onExit(({ code, error }) => {
    if (s.proc !== p) return;
    s.proc = null; const wasBusy = s.busy; s.busy = false;
    for (const it of s.items) { if (it.streaming) it.streaming = false; if (it.k === 'tool' && (it.status === 'running' || it.status === 'asking')) { it.status = 'error'; it.approval = null; } }
    if (error || (code && wasBusy)) push(s, { k: 'error', text: error || clip(s.err.trim(), 1500) || `Claude Code stopped (exit code ${code}).` });
    api.emit('items', { id: s.id, reset: true, items: s.items });
    emitS(s); persist();
  });
  return p;
}
const out = (s, obj) => { if (s.proc) s.proc.write(JSON.stringify(obj) + '\n'); };

function onEvent(s, ev) {
  switch (ev.type) {
    case 'system':
      if (ev.subtype === 'init') { s.claudeId = ev.session_id || s.claudeId; s.realModel = ev.model; emitS(s); persist(); }
      break;
    case 'stream_event': {
      const e = ev.event || {}, mid = ev.api_message_id || '';
      if (e.type === 'content_block_start' && e.content_block && (e.content_block.type === 'text' || e.content_block.type === 'thinking')) {
        s.streamed.add(mid);
        s.blocks.set(mid + ':' + e.index, push(s, { k: e.content_block.type, text: '', streaming: true }));
      } else if (e.type === 'content_block_delta' && e.delta) {
        const i = s.blocks.get(mid + ':' + e.index); if (i === undefined) break;
        const t = e.delta.type === 'text_delta' ? e.delta.text : e.delta.type === 'thinking_delta' ? e.delta.thinking : '';
        if (t) { s.items[i].text += t; touch(s, i, true); }
      } else if (e.type === 'content_block_stop') {
        const i = s.blocks.get(mid + ':' + e.index); if (i !== undefined) { s.items[i].streaming = false; touch(s, i); s.blocks.delete(mid + ':' + e.index); }
      }
      break;
    }
    case 'assistant': {
      const m = ev.message || {};
      for (const b of m.content || []) {
        if (b.type === 'tool_use') { const i = tool(s, b.id); Object.assign(s.items[i], { name: b.name, input: b.input || {} }); touch(s, i); }
        else if ((b.type === 'text' || b.type === 'thinking') && !s.streamed.has(m.id)) { const t = b.type === 'text' ? b.text : b.thinking; if (t) push(s, { k: b.type, text: t }); }
      }
      break;
    }
    case 'user': { // tool results
      const c = ev.message && ev.message.content;
      if (Array.isArray(c)) for (const b of c) if (b.type === 'tool_result') {
        const i = tool(s, b.tool_use_id), it = s.items[i];
        const txt = Array.isArray(b.content) ? b.content.map((x) => x.text || '').join('\n') : String(b.content == null ? '' : b.content);
        it.result = clip(txt, TOOL_OUT); it.approval = null;
        it.status = b.is_error ? (it.status === 'denied' || /haven't granted|permission|denied/i.test(txt) ? 'denied' : 'error') : 'done'; touch(s, i);
      }
      break;
    }
    case 'control_request': {
      const r = ev.request || {};
      if (r.subtype !== 'can_use_tool') { out(s, { type: 'control_response', response: { subtype: 'error', request_id: ev.request_id, error: 'unsupported' } }); break; }
      const i = tool(s, r.tool_use_id || ev.request_id), it = s.items[i];
      it.name = it.name || r.tool_name; if (!Object.keys(it.input || {}).length) it.input = r.input || {};
      it.status = 'asking'; it.approval = { req: ev.request_id, canRemember: Array.isArray(r.permission_suggestions) && r.permission_suggestions.length > 0 };
      s.pending.set(ev.request_id, { input: r.input || {}, suggestions: r.permission_suggestions || [], item: i });
      touch(s, i); emitS(s);
      break;
    }
    case 'control_cancel_request': {
      const p = s.pending.get(ev.request_id); if (p) { s.pending.delete(ev.request_id); const it = s.items[p.item]; if (it) { it.approval = null; it.status = 'running'; touch(s, p.item); } }
      break;
    }
    case 'rate_limit_event': {
      const w = ev.rate_limit_info && ev.rate_limit_info.unifiedWindows || {};
      s.rate = { five: w.five_hour ? w.five_hour.utilization : null, seven: w.seven_day ? w.seven_day.utilization : null, fiveResets: w.five_hour ? w.five_hour.resetsAt : 0 };
      emitS(s); break;
    }
    case 'result':
      s.busy = false; s.streamed.clear(); s.blocks.clear();
      if (ev.is_error) push(s, { k: 'error', text: clip(ev.result || ev.subtype || 'The request failed.', 1500) });
      emitS(s); persist();
      break;
  }
}

// ---- handlers called by the window ----
const need = (id) => { const s = sessions.get(id); if (!s) throw new Error('That chat no longer exists'); return s; };
api.handle('detect', async ({ target } = {}) => { try { return { claude: await detectOn(target || '') }; } catch (e) { return { claude: { installed: false, error: e.message } }; } });
api.handle('servers', () => savedServers().map((x) => ({ id: x.id, name: x.name || x.host, host: x.host, jump: !!x.jumpId })));
api.handle('state', () => ({ chats: [...sessions.values()].map(brief), config: api.config() }));
api.handle('items', ({ id }) => need(id).items);
api.handle('create', ({ cwd, mode, model, target }) => {
  target = String(target || ''); const where = target ? (() => { const x = serverById(target); return x.name || x.host; })() : 'This PC';
  const c = api.config(), s = { id: rid(), target, where, title: 'New chat', cwd: String(cwd || c.folder || '').trim(), mode: MODES.includes(mode) ? mode : (MODES.includes(c.mode) ? c.mode : 'manual'), model: MODELS.includes(model) ? model : (c.model || ''), claudeId: '', created: Date.now(), items: [], proc: null, busy: false, buf: '', err: '', blocks: new Map(), streamed: new Set(), tools: new Map(), pending: new Map(), rate: null };
  sessions.set(s.id, s); persist(); return brief(s);
});
api.handle('send', async ({ id, text }) => {
  const s = need(id); text = String(text || '').trim(); if (!text) return;
  if (s.busy) throw new Error('Claude is still working. Stop it first or wait.');
  s.busy = true; emitS(s); // set first so a double Enter can't start two turns while the SSH login is being made
  try { await ensureProc(s); } catch (e) { s.busy = false; emitS(s); throw new Error(s.target ? `Could not start Claude on ${s.where}: ${e.message}` : e.message); }
  if (s.title === 'New chat') { s.title = text.replace(/\s+/g, ' ').slice(0, 40); }
  s.streamed.clear(); s.blocks.clear();
  push(s, { k: 'user', text });
  out(s, { type: 'user', message: { role: 'user', content: text } });
  emitS(s); persist();
});
api.handle('approve', ({ id, req, allow, remember }) => {
  const s = need(id), p = s.pending.get(req); if (!p) return;
  s.pending.delete(req);
  const resp = allow ? { behavior: 'allow', updatedInput: p.input, ...(remember && p.suggestions.length ? { updatedPermissions: p.suggestions } : {}) } : { behavior: 'deny', message: 'The user declined this action.' };
  out(s, { type: 'control_response', response: { subtype: 'success', request_id: req, response: resp } });
  const it = s.items[p.item]; if (it) { it.approval = null; it.status = allow ? 'running' : 'denied'; touch(s, p.item); }
});
api.handle('interrupt', ({ id }) => { const s = need(id); if (s.proc) out(s, { type: 'control_request', request_id: rid(), request: { subtype: 'interrupt' } }); });
api.handle('setMode', ({ id, mode }) => {
  const s = need(id); if (!MODES.includes(mode)) throw new Error('Unknown mode');
  s.mode = mode; if (s.proc) out(s, { type: 'control_request', request_id: rid(), request: { subtype: 'set_permission_mode', mode } });
  emitS(s); persist();
});
api.handle('setModel', ({ id, model }) => { // applied on the next start of the CLI: restart it now if idle
  const s = need(id); if (!MODELS.includes(model)) throw new Error('Unknown model');
  s.model = model; if (s.proc && !s.busy) { const p = s.proc; s.proc = null; p.kill(); }
  emitS(s); persist();
});
api.handle('stop', ({ id }) => { const s = need(id); if (s.proc) { const p = s.proc; s.proc = null; s.busy = false; p.kill(); } emitS(s); });
api.handle('remove', ({ id }) => { const s = sessions.get(id); if (!s) return; if (s.proc) s.proc.kill(); sessions.delete(id); persist(true); });
api.handle('rename', ({ id, title }) => { const s = need(id); s.title = String(title || '').trim().slice(0, 60) || s.title; emitS(s); persist(); });

restore();
api.onUnload(() => { persist(true); for (const s of sessions.values()) if (s.proc) { try { s.proc.kill(); } catch {} s.proc = null; } });
//==== renderer ====
// AI sidebar (window): a docked chat panel. All text is inserted with textContent, never as HTML.
const MODES = [['manual', 'Ask first'], ['acceptEdits', 'Auto-edit'], ['plan', 'Plan only'], ['bypassPermissions', 'Allow all']];
const MODELS = [['', 'Default model'], ['sonnet', 'Sonnet'], ['opus', 'Opus'], ['haiku', 'Haiku']];
const chats = new Map(), items = new Map(), open = new Set(); // chat id -> brief / items; open = tool ids the user expanded
let cur = '', installed = null, creating = false, ui = {}, nodes = [];
const errText = (e) => String(e && e.message || e || '').replace(/^Error invoking remote method '[^']*': (Error: )?/, '');
const el = (tag, cls, text) => { const x = document.createElement(tag); if (cls) x.className = cls; if (text != null) x.textContent = text; return x; };
const call = (n, a) => Mod.call(n, a).catch((e) => { Mod.toast(errText(e)); throw e; });

// ---- text: ``` fences become code blocks, `x` becomes inline code ----
function inline(parent, s) { s.split(/(`[^`\n]+`)/).forEach((p) => { if (p.length > 2 && p[0] === '`' && p.endsWith('`')) parent.append(el('code', '', p.slice(1, -1))); else if (p) parent.append(document.createTextNode(p)); }); }
function rich(box, text) {
  box.textContent = '';
  const parts = String(text).split(/```[^\n]*\n?/);
  parts.forEach((p, i) => { if (i % 2) box.append(el('pre', 'ai-code', p.replace(/\n$/, ''))); else if (p.trim()) { const d = el('div', 'ai-p'); inline(d, p.replace(/^\n+|\n+$/g, '')); box.append(d); } });
}

// ---- tool cards ----
const short = (s, n = 90) => { s = String(s == null ? '' : s).replace(/\s+/g, ' '); return s.length > n ? s.slice(0, n) + '…' : s; };
function summary(t) {
  const i = t.input || {};
  return short(i.command || i.file_path || i.path || i.pattern || i.url || i.query || i.description || (Object.keys(i).length ? JSON.stringify(i) : ''));
}
function diff(box, oldS, newS) {
  const d = el('div', 'ai-diff');
  for (const [cls, s] of [['del', oldS], ['add', newS]]) if (s) for (const ln of String(s).split('\n').slice(0, 60)) d.append(el('div', cls, (cls === 'del' ? '- ' : '+ ') + ln));
  box.append(d);
}
function toolNode(t) {
  const card = el('div', 'ai-tool st-' + t.status);
  const head = el('div', 'ai-th'); head.append(el('span', 'ai-dot'), el('b', '', t.name || 'Tool'), el('span', 'ai-ts', summary(t)));
  const body = el('div', 'ai-tb'); const isOpen = open.has(t.toolId) || t.status === 'asking'; body.hidden = !isOpen;
  head.onclick = () => { if (body.hidden) { open.add(t.toolId); body.hidden = false; } else { open.delete(t.toolId); body.hidden = true; } };
  const i = t.input || {};
  if (t.name === 'Edit' && i.old_string != null) { body.append(el('div', 'ai-file', i.file_path || '')); diff(body, i.old_string, i.new_string); }
  else if (t.name === 'Write') { body.append(el('div', 'ai-file', i.file_path || '')); diff(body, '', i.content); }
  else if (t.name === 'Bash') body.append(el('pre', 'ai-code', i.command || ''));
  else if (Object.keys(i).length) body.append(el('pre', 'ai-code', JSON.stringify(i, null, 2)));
  if (t.result) body.append(el('pre', 'ai-code ai-res', t.result));
  card.append(head, body);
  if (t.approval) {
    const row = el('div', 'ai-ask'); row.append(el('span', '', 'Allow this?'));
    const b = (label, cls, fn) => { const x = el('button', cls, label); x.onclick = () => { row.querySelectorAll('button').forEach((y) => { y.disabled = true; }); fn(); }; row.append(x); };
    b('Allow', 'primary', () => call('approve', { id: cur, req: t.approval.req, allow: true }));
    if (t.approval.canRemember) b('Always', '', () => call('approve', { id: cur, req: t.approval.req, allow: true, remember: true }));
    b('Deny', '', () => call('approve', { id: cur, req: t.approval.req, allow: false }));
    card.append(row);
  }
  return card;
}
function itemNode(it) {
  if (it.k === 'user') return el('div', 'ai-msg ai-user', it.text);
  if (it.k === 'text') { const d = el('div', 'ai-msg ai-bot' + (it.streaming ? ' live' : '')); rich(d, it.text); return d; }
  if (it.k === 'thinking') { const d = el('details', 'ai-think'); d.append(el('summary', '', 'Thinking'), el('div', '', it.text)); return d; }
  if (it.k === 'tool') return toolNode(it);
  if (it.k === 'error') return el('div', 'ai-err', it.text);
  return el('div');
}

// ---- drawing ----
function atBottom() { const m = ui.msgs; return m.scrollHeight - m.scrollTop - m.clientHeight < 80; }
function drawItem(idx) {
  const list = items.get(cur) || [], it = list[idx]; if (!it || !ui.msgs) return;
  const stick = atBottom(), n = itemNode(it);
  if (nodes[idx]) nodes[idx].replaceWith(n); else { for (let i = nodes.length; i < idx; i++) { nodes[i] = el('div'); ui.msgs.append(nodes[i]); } ui.msgs.append(n); }
  nodes[idx] = n; if (stick) ui.msgs.scrollTop = ui.msgs.scrollHeight;
}
function drawAll() {
  ui.msgs.textContent = ''; nodes = [];
  const list = items.get(cur) || [];
  if (!list.length) ui.msgs.append(el('div', 'ai-empty', 'Ask Claude about this folder, or tell it what to build. It runs the Claude Code CLI with your own account, on this PC or on the SSH server you picked.'));
  list.forEach((it, i) => { const n = itemNode(it); nodes[i] = n; ui.msgs.append(n); });
  ui.msgs.scrollTop = ui.msgs.scrollHeight;
}
function drawTabs() {
  ui.tabs.textContent = '';
  for (const c of chats.values()) {
    const t = el('div', 'ai-tab' + (c.id === cur && !creating ? ' on' : '')); t.title = (c.where || 'This PC') + ': ' + (c.cwd || 'home folder');
    t.append(el('span', c.busy ? 'ai-spin' : 'ai-nospin'), el('span', 'ai-tt', (c.target ? c.where + ' · ' : '') + c.title));
    const x = el('span', 'ai-tx', '×'); x.title = 'Delete this chat'; x.onclick = async (e) => { e.stopPropagation(); if (!confirm(`Delete the chat "${c.title}"?`)) return; await call('remove', { id: c.id }); chats.delete(c.id); items.delete(c.id); if (cur === c.id) cur = [...chats.keys()][0] || ''; show(); };
    t.append(x); t.onclick = () => { creating = false; select(c.id); }; ui.tabs.append(t);
  }
  const plus = el('button', 'ai-plus', '+'); plus.title = 'New chat'; plus.onclick = () => { creating = true; show(); }; ui.tabs.append(plus);
}
function drawFoot() {
  const c = chats.get(cur); if (!c) return;
  ui.mode.value = c.mode; ui.model.value = c.model;
  ui.send.textContent = c.busy ? 'Stop' : 'Send'; ui.send.classList.toggle('primary', !c.busy);
  const r = c.rate; ui.rate.textContent = r && r.five != null ? `5h limit ${Math.round(r.five * 100)}% used` + (r.seven != null ? ` · week ${Math.round(r.seven * 100)}%` : '') : '';
  ui.rate.title = 'How much of your Claude plan usage is spent';
}
function show() {
  if (!ui.root) return;
  const none = false; // whether Claude Code exists is checked per target in the New chat form
  ui.missing.hidden = !none; ui.newBox.hidden = none || !(creating || !cur); ui.chat.hidden = none || creating || !cur;
  drawTabs(); if (!ui.chat.hidden) { drawAll(); drawFoot(); }
}
async function select(id) {
  cur = id;
  if (!items.has(id)) { try { items.set(id, await call('items', { id })); } catch { items.set(id, []); } }
  show();
}

// ---- panel ----
function build(box) {
  ui.root = box; box.classList.add('ai-root');
  ui.tabs = el('div', 'ai-tabs');
  ui.missing = el('div'); ui.missing.hidden = true;

  ui.newBox = el('div', 'ai-new'); ui.newBox.hidden = true;
  const where = el('select'); where.append(new Option('This PC', ''));
  const folder = el('input'); folder.placeholder = 'Folder to work in (empty = home folder)';
  const mode = el('select'); MODES.forEach(([v, l]) => mode.append(new Option(l, v)));
  const model = el('select'); MODELS.forEach(([v, l]) => model.append(new Option(l, v)));
  const status = el('div', 'ai-st');
  const go = el('button', 'primary', 'Start chat'); go.disabled = true;
  const check = async () => { // is Claude Code installed where the chat will run?
    go.disabled = true; status.className = 'ai-st'; status.textContent = 'Checking…'; const t = where.value;
    let r; try { r = (await call('detect', { target: t })).claude; } catch { r = { installed: false, error: 'Check failed' }; }
    if (where.value !== t) return;
    if (r.installed) { status.textContent = `Claude Code found${r.version ? ' (' + r.version + ')' : ''}: ${r.path}`; go.disabled = false; }
    else { status.className = 'ai-st bad'; status.textContent = r.error ? r.error : `Claude Code is not installed on ${r.where || 'this PC'}. Install it there (https://claude.com/claude-code), run \`claude\` once and log in with your Claude account.`; }
  };
  where.onchange = check; ui.check = check;
  go.onclick = async () => { const c = await call('create', { cwd: folder.value.trim(), mode: mode.value, model: model.value, target: where.value }); chats.set(c.id, c); items.set(c.id, []); creating = false; await select(c.id); ui.input.focus(); };
  const row2 = el('div', 'ai-row'); row2.append(mode, model);
  ui.newBox.append(el('h4', '', 'New chat'), el('label', '', 'Run on'), where, folder, row2, status, go);
  ui.nf = folder; ui.nm = mode; ui.nmo = model; ui.nw = where;

  ui.chat = el('div', 'ai-chat'); ui.chat.hidden = true;
  ui.msgs = el('div', 'ai-msgs');
  const foot = el('div', 'ai-foot');
  ui.input = el('textarea'); ui.input.rows = 3; ui.input.placeholder = 'Message Claude…  (Enter to send, Shift+Enter for a new line)';
  const row = el('div', 'ai-row');
  ui.mode = el('select'); MODES.forEach(([v, l]) => ui.mode.append(new Option(l, v)));
  ui.model = el('select'); MODELS.forEach(([v, l]) => ui.model.append(new Option(l, v)));
  ui.rate = el('span', 'ai-rate'); ui.send = el('button', 'primary', 'Send');
  ui.mode.onchange = () => call('setMode', { id: cur, mode: ui.mode.value });
  ui.model.onchange = () => call('setModel', { id: cur, model: ui.model.value });
  const submit = async () => {
    const c = chats.get(cur); if (!c) return;
    if (c.busy) { call('interrupt', { id: cur }); return; }
    const text = ui.input.value.trim(); if (!text) return; ui.input.value = '';
    try { await call('send', { id: cur, text }); } catch { ui.input.value = text; }
  };
  ui.send.onclick = submit;
  ui.input.onkeydown = (e) => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); } };
  row.append(ui.mode, ui.model, ui.rate, ui.send); foot.append(ui.input, row); ui.chat.append(ui.msgs, foot);
  box.append(ui.tabs, ui.missing, ui.newBox, ui.chat);
}
async function init() {
  const st = await call('state'); chats.clear();
  for (const c of st.chats) chats.set(c.id, c);
  try { const sv = await call('servers'); const keep = ui.nw.value; ui.nw.length = 1; sv.forEach((x) => ui.nw.append(new Option(x.name + (x.jump ? ' (jump host: not supported yet)' : ''), x.id))); ui.nw.value = [...ui.nw.options].some((o) => o.value === keep) ? keep : ''; } catch {}
  ui.nf.value = st.config.folder || ''; ui.nm.value = st.config.mode || 'manual'; ui.nmo.value = st.config.model || '';
  if (!chats.has(cur)) cur = [...chats.keys()][0] || '';
  if (cur) await select(cur); else show();
  ui.check();
}
const panel = Mod.sidebarPanel({ id: 'ai', label: 'AI', icon: 'bolt', mount: build, show: () => init() });

Mod.on('session', (c) => { chats.set(c.id, c); if (!ui.root) return; drawTabs(); if (c.id === cur) drawFoot(); });
Mod.on('item', ({ id, idx, item }) => { const l = items.get(id); if (!l) return; l[idx] = item; if (id === cur && ui.msgs && !ui.chat.hidden) { if (l.length === 1 && idx === 0) drawAll(); else drawItem(idx); } });
Mod.on('items', ({ id, items: l }) => { items.set(id, l); if (id === cur && ui.msgs && !ui.chat.hidden) drawAll(); });
//==== css ====
.ai-root{height:100%;font-size:13px}
.ai-tabs{display:flex;gap:4px;padding:6px 8px;border-bottom:1px solid var(--line);overflow-x:auto;flex:none}
.ai-tab{display:flex;align-items:center;gap:6px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;cursor:pointer;white-space:nowrap;max-width:160px;color:var(--mut)}
.ai-tab.on{color:var(--fg);border-color:var(--acc)}
.ai-tt{overflow:hidden;text-overflow:ellipsis}.ai-tx{opacity:.5}.ai-tx:hover{opacity:1;color:var(--bad)}
.ai-plus{padding:2px 10px}
.ai-spin{width:8px;height:8px;border-radius:50%;border:2px solid var(--acc);border-right-color:transparent;animation:aispin .8s linear infinite}
.ai-nospin{width:8px}@keyframes aispin{to{transform:rotate(360deg)}}
.ai-chat{display:flex;flex-direction:column;flex:1;min-height:0}
.ai-chat[hidden],.ai-new[hidden],.ai-note[hidden]{display:none}
.ai-msgs{flex:1;min-height:0;overflow-y:auto;padding:10px 12px;display:flex;flex-direction:column;gap:8px}
.ai-msg{padding:8px 10px;border-radius:8px;line-height:1.5;word-break:break-word}
.ai-user{align-self:flex-end;max-width:90%;background:var(--acc);color:var(--accfg);white-space:pre-wrap}
.ai-bot{background:color-mix(in srgb,var(--fg) 6%,transparent)}
.ai-bot.live::after{content:'▍';opacity:.6}
.ai-p{white-space:pre-wrap}.ai-p+.ai-p,.ai-p+.ai-code,.ai-code+.ai-p{margin-top:6px}
.ai-p code{background:color-mix(in srgb,var(--fg) 12%,transparent);padding:0 4px;border-radius:3px;font-family:var(--mono,monospace)}
.ai-code{margin:0;padding:8px;background:var(--tbg);color:var(--tfg);border-radius:6px;overflow-x:auto;font:12px/1.4 var(--mono,monospace);white-space:pre-wrap;word-break:break-all;max-height:260px;overflow-y:auto}
.ai-res{margin-top:6px;opacity:.85}
.ai-tool{border:1px solid var(--line);border-radius:8px;overflow:hidden}
.ai-th{display:flex;align-items:center;gap:8px;padding:6px 10px;cursor:pointer}
.ai-ts{color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.ai-dot{width:8px;height:8px;border-radius:50%;background:var(--mut);flex:none}
.st-running .ai-dot{background:var(--acc)}.st-done .ai-dot{background:var(--ok)}.st-error .ai-dot,.st-denied .ai-dot{background:var(--bad)}.st-asking .ai-dot{background:#f5a524}
.ai-tb{padding:8px 10px;border-top:1px solid var(--line)}
.ai-file{color:var(--mut);margin-bottom:4px}
.ai-diff{font:12px/1.4 var(--mono,monospace);max-height:260px;overflow:auto;background:var(--tbg);border-radius:6px}
.ai-diff div{padding:0 8px;white-space:pre-wrap;word-break:break-all}.ai-diff .del{background:#ff6b6b26;color:#ff9b9b}.ai-diff .add{background:#3ecf8e22;color:#7fe3b4}
.ai-ask{display:flex;align-items:center;gap:6px;padding:8px 10px;border-top:1px solid var(--line);background:color-mix(in srgb,#f5a524 12%,transparent)}.ai-ask span{margin-right:auto}
.ai-think{color:var(--mut)}.ai-think div{white-space:pre-wrap;padding:4px 0}
.ai-err{color:var(--bad);padding:8px 10px;border:1px solid var(--bad);border-radius:8px;white-space:pre-wrap}
.ai-empty,.ai-note{color:var(--mut);padding:16px}
.ai-foot{border-top:1px solid var(--line);padding:8px;display:flex;flex-direction:column;gap:6px;flex:none}
.ai-foot textarea{resize:none;width:100%;box-sizing:border-box}
.ai-row{display:flex;gap:6px;align-items:center}.ai-rate{margin-left:auto;color:var(--mut);font-size:11px}
.ai-new{padding:12px;display:flex;flex-direction:column;gap:8px}.ai-new h4{margin:0}
.ai-new label{color:var(--mut);font-size:11px;margin-bottom:-4px}
.ai-st{color:var(--mut);font-size:12px;word-break:break-word}.ai-st.bad{color:var(--bad)}
