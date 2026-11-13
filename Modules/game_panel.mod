//==== module ====
{
  "id": "game_panel",
  "name": "Game Panel Helper",
  "description": "Allows for management of game servers in a Pterodactyl-compatible panel.",
  "version": "1.0.2",
  "test": true,
  "config": [
    { "key": "url", "label": "Panel URL", "type": "url", "placeholder": "https://panel.example.com", "help": "Address of your panel (Pterodactyl, Calagopus ...), without /api/client." },
    { "key": "apiKey", "label": "Client API Key", "type": "password", "secret": true, "help": "Create one in your panel under Account > API Keys. For the console it needs the server permissions control.read-console and control.console (plus control.start / control.stop / control.restart for the power buttons). It is stored encrypted on this computer." }
  ]
}
//==== main ====
// Talks to the panel's client API (https://PANEL/api/client, Authorization: Bearer <key>, Accept: application/json).
// The key never leaves this half of the module; the window only sees results.
const sessions = new Map(); // panel server id -> { ws, closed }

function baseUrl() {
  let u = String(api.config().url || '').trim().replace(/\/+$/, '').replace(/\/api(\/client)?$/i, '');
  if (!u) throw new Error('Panel URL is not set. Open Settings > Modules > Game Panel Helper (gear icon).');
  if (!/^https?:\/\//i.test(u)) u = 'https://' + u;
  new URL(u); // throws on nonsense
  return u;
}
const idOk = (id) => { if (!/^[\w-]{1,64}$/.test(String(id))) throw new Error('Invalid server id'); return String(id); };

async function req(path, opts = {}) {
  const url = baseUrl() + '/api/client' + path, key = api.config().apiKey;
  if (!key) throw new Error('Client API key is not set. Open Settings > Modules > Game Panel Helper (gear icon).');
  let r;
  try {
    r = await api.fetch(url, { method: opts.method || 'GET', headers: { Authorization: 'Bearer ' + key, Accept: 'application/json', ...(opts.body ? { 'Content-Type': 'application/json' } : {}) }, body: opts.body ? JSON.stringify(opts.body) : undefined });
  } catch (e) { throw new Error('Could not reach the panel: ' + ((e && e.cause && (e.cause.code || e.cause.message)) || (e && e.message) || e)); }
  if (r.status === 204) return null;
  const text = await r.text(); let j = null; try { j = JSON.parse(text); } catch {}
  if (!r.ok) {
    const e0 = j && j.errors && j.errors[0], d = typeof e0 === 'string' ? { detail: e0 } : e0; // Pterodactyl: objects, Calagopus: strings
    if (r.status === 401 || r.status === 403) throw new Error('The panel refused the API key (HTTP ' + r.status + ')' + (d && d.detail ? ': ' + d.detail : ''));
    throw new Error(d && (d.detail || d.code) ? `${d.detail || d.code} (HTTP ${r.status})` : `The panel answered HTTP ${r.status}`);
  }
  return j;
}

// The servers this key can see (follows pagination).
// Calagopus: GET /api/client/servers -> { servers: { total, per_page, page, data: [{ uuid, uuid_short, name, node_name, limits, is_suspended, ... }] } }
// Pterodactyl: GET /api/client -> { data: [{ attributes: { identifier, uuid, name, ... } }], meta: { pagination } }
let listRoot = null; // '/servers' (Calagopus) or '' (Pterodactyl), remembered once one works
async function listServers() {
  const out = [];
  for (let page = 1; page <= 50; page++) {
    const q = page === 1 ? '' : '?page=' + page;
    let j;
    if (listRoot !== null) j = await req(listRoot + q);
    else {
      try { j = await req('/servers' + q); listRoot = '/servers'; }
      catch (e) { if (!/HTTP 404|HTTP 405|answered HTTP 4/.test(String(e && e.message))) throw e; j = await req(q); listRoot = ''; }
    }
    if (j && j.servers && Array.isArray(j.servers.data)) { // Calagopus
      for (const s of j.servers.data) {
        out.push({ id: s.uuid, uuid: s.uuid, name: s.name, description: s.description || '', node: s.node_name || '', limits: s.limits || {}, suspended: !!s.is_suspended, installing: false });
      }
      const p = j.servers;
      if (!p.per_page || page * p.per_page >= p.total) break;
    } else { // Pterodactyl
      for (const d of (j && j.data) || []) {
        const a = d.attributes || {};
        out.push({ id: a.identifier, uuid: a.uuid, name: a.name, description: a.description || '', node: a.node || '', limits: a.limits || {}, suspended: !!a.is_suspended, installing: !!a.is_installing });
      }
      const p = j && j.meta && j.meta.pagination;
      if (!p || page >= p.total_pages) break;
    }
  }
  return out.filter((s) => s.id);
}

// GET /api/client/servers/{id}/resources -> current_state: running | starting | stopping | offline, plus live usage
async function resources(id) {
  const j = await req(`/servers/${idOk(id)}/resources`), a = (j && j.attributes) || {}, r = a.resources || {};
  return { state: a.current_state || 'unknown', suspended: !!a.is_suspended, cpu: r.cpu_absolute, mem: r.memory_bytes, disk: r.disk_bytes, rx: r.network_rx_bytes, tx: r.network_tx_bytes, uptime: r.uptime };
}

api.handle('test', async () => { const l = await listServers(); return `Connected. ${l.length} server${l.length === 1 ? '' : 's'} found.`; });
api.handle('servers', () => listServers());
api.handle('resources', async ({ ids }) => {
  const list = (ids || []).slice(0, 100), out = {}; let i = 0;
  await Promise.all(Array.from({ length: Math.min(4, list.length) }, async () => {
    while (i < list.length) { const id = list[i++]; try { out[id] = await resources(id); } catch (e) { out[id] = { error: String(e && e.message || e) }; } }
  }));
  return out;
});
api.handle('power', async ({ id, signal }) => { // POST /api/client/servers/{id}/power  { signal }
  if (!['start', 'stop', 'restart', 'kill'].includes(signal)) throw new Error('Unknown power action');
  await req(`/servers/${idOk(id)}/power`, { method: 'POST', body: { signal } }); return true;
});

// ---- live console over the panel's websocket (GET /servers/{id}/websocket -> { token, socket }) ----
function closeSession(id) { const s = sessions.get(id); if (!s) return; sessions.delete(id); s.closed = true; try { s.ws && s.ws.close(); } catch {} }
api.handle('consoleOpen', async ({ id }) => {
  id = idOk(id); closeSession(id);
  const sess = { closed: false, ws: null }; sessions.set(id, sess);
  const emit = (d) => { if (!sess.closed) api.emit('console', { id, ...d }); };
  const creds = async () => {
    let j;
    try { j = await req(`/servers/${id}/websocket`); }
    catch (e) { throw new Error(String(e.message || e) + ' (needs the API key to carry the server permissions control.read-console and control.console)'); }
    const d = (j && (j.data && j.data.token ? j.data : j.attributes && j.attributes.token ? j.attributes : j)) || {}; // Pterodactyl: { data: {...} }; Calagopus may answer unwrapped
    const socket = d.socket || d.url || d.websocket || d.ws;
    if (!d.token || !socket) throw new Error('The panel did not return console credentials. Response: ' + JSON.stringify(j).slice(0, 300));
    return { token: d.token, socket };
  };
  const c = await creds();
  if (sess.closed) return true;
  const ws = sess.ws = api.websocket(c.socket, { origin: new URL(baseUrl()).origin }); // the daemon only accepts the panel's own origin
  const send = (event, args) => { try { ws.send(JSON.stringify({ event, args })); } catch {} };
  const reauth = async () => { try { send('auth', [(await creds()).token]); } catch (e) { emit({ type: 'error', message: String(e.message || e) }); } };
  ws.on('open', () => send('auth', [c.token]));
  ws.on('message', (raw) => {
    let m; try { m = JSON.parse(raw); } catch { return; }
    const a = m.args || [];
    switch (m.event) {
      case 'auth success': emit({ type: 'ready' }); send('send logs', [null]); send('send stats', [null]); break;
      case 'console output': case 'install output': case 'transfer logs': emit({ type: 'line', text: String(a[0] == null ? '' : a[0]) }); break;
      case 'daemon message': emit({ type: 'line', text: '\x1b[2m' + String(a[0] == null ? '' : a[0]) + '\x1b[0m' }); break;
      case 'status': emit({ type: 'status', state: String(a[0]) }); break;
      case 'stats': { let s = null; try { s = JSON.parse(a[0]); } catch {} if (s) emit({ type: 'stats', state: s.state, cpu: s.cpu_absolute, mem: s.memory_bytes, memLimit: s.memory_limit_bytes, disk: s.disk_bytes, rx: s.network && s.network.rx_bytes, tx: s.network && s.network.tx_bytes, uptime: s.uptime }); break; }
      case 'token expiring': case 'token expired': reauth(); break;
      case 'daemon error': emit({ type: 'line', text: '\x1b[31m' + String(a[0] == null ? '' : a[0]) + '\x1b[0m' }); break;
      case 'jwt error': emit({ type: 'error', message: 'Console login problem: ' + String(a[0] || '') + (/permission/i.test(String(a[0])) ? ' (the API key needs control.read-console)' : '') }); reauth(); break;
    }
  });
  ws.on('error', (e) => emit({ type: 'error', message: String(e && e.message || e) }));
  ws.on('close', () => { if (sessions.get(id) === sess) sessions.delete(id); emit({ type: 'closed' }); sess.closed = true; });
  return true;
});
api.handle('consoleSend', ({ id, command }) => {
  const s = sessions.get(idOk(id)); if (!s || !s.ws || s.ws.readyState !== 1) throw new Error('Console is not connected');
  s.ws.send(JSON.stringify({ event: 'send command', args: [String(command).slice(0, 2000)] })); return true;
});
api.handle('consoleClose', ({ id }) => { closeSession(String(id)); return true; });
api.onUnload(() => { for (const id of [...sessions.keys()]) closeSession(id); });
//==== renderer ====
// Game servers as a server type: status dots + start/stop/restart in the sidebar, and a live console with CPU / RAM / disk in place of the SSH terminal.
const COLOR = { running: '#22c55e', starting: '#eab308', stopping: '#eab308', offline: '#ef4444', unknown: '#94a3b8' };
const LABEL = { running: 'Online', starting: 'Starting', stopping: 'Stopping', offline: 'Offline', unknown: 'Status unknown' };
const info = new Map();                 // panel server id -> { state, cpu, mem, disk, ... }
let cur = null;                         // the console currently shown
const isGame = (s) => s && s.type === 'game_panel';
const pidOf = (s) => s.panelServerId;
const gameServers = () => servers.filter(isGame);
const esc = (id) => String(id).replace(/[^\w-]/g, '');
const fmtB = (n) => (n == null || isNaN(n) ? '–' : n >= 2 ** 30 ? (n / 2 ** 30).toFixed(n >= 10 * 2 ** 30 ? 1 : 2) + ' GB' : n >= 2 ** 20 ? (n / 2 ** 20).toFixed(0) + ' MB' : (n / 1024).toFixed(0) + ' KB');
const mbB = (mb) => (mb > 0 ? mb * 1048576 : 0);
const canDo = (sig, st) => (sig === 'start' ? st === 'offline' || st === 'unknown' : st === 'running' || st === 'starting');

// ---- painting (updates dots / buttons / header numbers in place, no re-render) ----
function paint(pid) {
  const st = (info.get(pid) || {}).state || 'unknown';
  document.querySelectorAll(`.sdot.st[data-pid="${esc(pid)}"]`).forEach((d) => { d.style.background = COLOR[st] || COLOR.unknown; d.title = LABEL[st] || st; });
  document.querySelectorAll(`[data-gpids="${esc(pid)}"] button[data-sig]`).forEach((b) => { b.disabled = !canDo(b.dataset.sig, st); });
  const s = sel(); if (s && isGame(s) && pidOf(s) === pid) paintBar();
}
function paintBar() {
  const s = sel(), bar = document.querySelector('#tabsExtra .gpBar'); if (!bar || !s) return;
  const i = info.get(pidOf(s)) || {}, st = i.state || 'unknown', lim = s.limits || {};
  bar.querySelector('.gpLabel').textContent = i.error ? 'Panel unreachable' : (LABEL[st] || st);
  bar.title = i.error || '';
  const cpuLim = lim.cpu > 0 ? ' / ' + lim.cpu + '%' : '';
  const memLim = i.memLimit > 0 ? i.memLimit : mbB(lim.memory), diskLim = mbB(lim.disk);
  const val = (v, f) => (v == null ? '–' : f(v));
  bar.querySelector('.gpCpu').textContent = val(i.cpu, (v) => v.toFixed(1) + '%') + (i.cpu != null ? cpuLim : '');
  bar.querySelector('.gpRam').textContent = val(i.mem, fmtB) + (i.mem != null && memLim ? ' / ' + fmtB(memLim) : '');
  bar.querySelector('.gpDisk').textContent = val(i.disk, fmtB) + (i.disk != null && diskLim ? ' / ' + fmtB(diskLim) : '');
}
function setInfo(pid, patch) { info.set(pid, { ...(info.get(pid) || {}), ...patch }); paint(pid); }

// ---- polling: one request per game server every 10 s (every 2 s for a while after a power action) ----
let timer = null, fastUntil = 0, kickT = null;
async function poll() {
  const ids = gameServers().map(pidOf).filter(Boolean); if (!ids.length || document.hidden) return;
  let r; try { r = await Mod.call('resources', { ids }); } catch (e) { ids.forEach((id) => setInfo(id, { state: 'unknown', error: String(e.message || e) })); return; }
  for (const id of ids) { const v = r[id]; if (v && !v.error) { info.set(id, { ...v, error: '' }); } else info.set(id, { state: 'unknown', error: (v && v.error) || 'No answer' }); paint(id); }
}
function schedule() { clearTimeout(timer); timer = setTimeout(async () => { await poll(); schedule(); }, Date.now() < fastUntil ? 2000 : 10000); }
const kick = () => { clearTimeout(kickT); kickT = setTimeout(poll, 250); };
Mod.onUnload(() => { clearTimeout(timer); clearTimeout(kickT); document.querySelectorAll('.sdot.st, .acts[data-gpids], .gpBar').forEach((e) => e.remove()); });
schedule(); kick();

async function power(s, signal) {
  const pid = pidOf(s);
  try {
    await Mod.call('power', { id: pid, signal });
    setInfo(pid, { state: signal === 'start' ? 'starting' : 'stopping', error: '' });
    fastUntil = Date.now() + 40000; setTimeout(poll, 800);
    Mod.toast(`${s.name}: ${signal === 'start' ? 'starting' : signal === 'stop' ? 'stopping' : 'restarting'}…`);
  } catch (e) { Mod.toast(String(e.message || e)); }
}
const iconBtn = (sig, title, ic) => { const b = document.createElement('button'); b.dataset.sig = sig; b.title = title; b.innerHTML = icon(ic, 14); return b; };

// ---- the server type ----
let reloadForm = null;
Mod.onConfig(() => { if (reloadForm) reloadForm(); kick(); });
const panelHost = () => { let u = String(Mod.config().url || '').trim(); if (u && !/^https?:\/\//i.test(u)) u = 'https://' + u; try { return new URL(u).host; } catch { return ''; } };

Mod.serverType({
  id: 'game_panel', label: 'Game Panel', termLabel: 'Console',
  unsupported: { upload: 'Uploading files is not available for game servers yet.', files: 'The file browser is not available for game servers yet. Use the Console page.' },
  describe: (s) => 'Game server' + (s.host ? ' · ' + s.host : ''),
  test: (s) => Mod.call('test'),

  // Add / edit dialog: pick one of the servers the panel reports
  renderForm(box, srv, ctx) {
    box.innerHTML = '<div class="gpFormHead">Your game servers</div><div class="gpList"></div><div class="gpMsg muted"></div><div class="gpCfg"></div>';
    const list = box.querySelector('.gpList'), msg = box.querySelector('.gpMsg'), cfgRow = box.querySelector('.gpCfg');
    let chosen = srv ? { id: srv.panelServerId, name: srv.panelName || srv.name, uuid: srv.panelUuid, limits: srv.limits } : null, rows = [];
    const mark = () => rows.forEach((r) => r.el.classList.toggle('on', chosen && r.s.id === chosen.id));
    async function load() {
      list.innerHTML = ''; cfgRow.innerHTML = ''; rows = [];
      const c = Mod.config();
      if (!c.url || !Mod.has('apiKey')) { msg.textContent = 'Enter your panel address and Client API key first.'; const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Open Game Panel settings'; b.onclick = () => Mod.openConfig(); cfgRow.append(b); return; }
      msg.textContent = 'Loading servers from the panel…';
      let all; try { all = await Mod.call('servers'); } catch (e) { if (!box.isConnected) return; msg.textContent = String(e.message || e); const b = document.createElement('button'); b.type = 'button'; b.textContent = 'Open Game Panel settings'; b.onclick = () => Mod.openConfig(); cfgRow.append(b); return; }
      if (!box.isConnected) return;
      msg.textContent = all.length ? '' : 'The panel reports no servers for this key.';
      const taken = new Set(servers.filter((x) => isGame(x) && (!srv || x.id !== srv.id)).map(pidOf));
      for (const s of all) {
        const el = document.createElement('div'), used = taken.has(s.id);
        el.className = 'gpRow' + (used ? ' used' : ''); el.innerHTML = '<b></b><small></small>';
        el.firstChild.textContent = s.name;
        el.lastChild.textContent = [used ? 'already added' : '', s.node, s.limits.memory ? s.limits.memory + ' MB RAM' : '', s.suspended ? 'suspended' : ''].filter(Boolean).join(' · ') || s.id;
        if (!used) el.onclick = () => { chosen = s; ctx.setName(s.name); mark(); };
        list.append(el); rows.push({ el, s });
      }
      mark();
    }
    reloadForm = () => { if (box.isConnected) load(); };
    load();
    return {
      values() {
        if (!chosen) { msg.textContent = 'Pick one of the servers above.'; return null; }
        return { panelServerId: chosen.id, panelName: chosen.name, panelUuid: chosen.uuid || '', limits: chosen.limits || {}, host: panelHost() };
      },
    };
  },

  // Sidebar: status dot + start / stop / restart
  decorateItem(el, s) {
    const pid = pidOf(s); if (!pid) return;
    const name = el.querySelector('b'), dot = document.createElement('span'); dot.className = 'sdot st'; dot.dataset.pid = pid;
    const tag = name.querySelector('.sdot'); if (tag) tag.after(dot); else name.prepend(dot);
    const acts = document.createElement('div'); acts.className = 'acts'; acts.dataset.gpids = pid;
    for (const [sig, title, ic] of [['start', 'Start', 'play'], ['stop', 'Stop', 'stop'], ['restart', 'Restart', 'restart']]) {
      const b = iconBtn(sig, title, ic); b.onclick = (ev) => { ev.stopPropagation(); power(s, sig); }; acts.append(b);
    }
    el.append(acts);
    if (!info.has(pid)) { info.set(pid, { state: 'unknown' }); kick(); }
    paint(pid);
  },

  // Next to the Upload / Console / Files tabs: status, text + icon buttons, CPU / RAM / disk
  targetBar(box, s) {
    const pid = pidOf(s); if (!pid) return;
    const bar = document.createElement('div'); bar.className = 'gpBar';
    bar.innerHTML = '<span class="gpState"><i class="sdot st" data-pid=""></i><b class="gpLabel"></b></span><span class="gpBtns"></span>' +
      '<span class="gpStats">CPU <b class="gpCpu">–</b><i>·</i>RAM <b class="gpRam">–</b><i>·</i>Disk <b class="gpDisk">–</b></span>';
    bar.querySelector('.sdot').dataset.pid = pid; bar.dataset.gpids = pid;
    const btns = bar.querySelector('.gpBtns');
    for (const [sig, title, ic] of [['start', 'Start', 'play'], ['stop', 'Stop', 'stop'], ['restart', 'Restart', 'restart']]) {
      const b = iconBtn(sig, title, ic); b.append(' ' + title); b.title = title + ' ' + s.name; b.onclick = () => power(s, sig); btns.append(b);
    }
    box.append(bar); paint(pid);
  },

  // Console page: live output from the game, a box to type commands
  console: {
    mount(box, s) {
      const pid = pidOf(s);
      box.innerHTML = '<div class="gpCon"><div class="gpTerm"></div><form class="gpIn"><span>›</span><input class="gpCmd" placeholder="Type a command and press Enter" spellcheck="false" autocomplete="off"><button class="primary">Send</button></form></div>';
      const host = box.querySelector('.gpTerm'), input = box.querySelector('.gpCmd');
      const theme = (typeof termTheme === 'function') ? termTheme() : {};
      host.style.background = theme.background || '#0c0e12';
      const term = new Terminal({ fontFamily: window.hdFont ? hdFont() : 'ui-monospace, "SF Mono", Menlo, monospace', fontSize: window.hdFontSize ? hdFontSize() : 13, cursorBlink: false, cursorStyle: 'underline', disableStdin: true, convertEol: true, allowProposedApi: true, scrollback: typeof scrollbackLines === 'function' ? scrollbackLines() : 10000, theme });
      const fit = new FitAddon.FitAddon(); term.loadAddon(fit); term.open(host);
      const doFit = () => { try { if (host.offsetParent) fit.fit(); } catch {} };
      const ro = new ResizeObserver(doFit); ro.observe(host); requestAnimationFrame(doFit);
      term.onSelectionChange(() => { if (typeof autoCopy !== 'undefined' && autoCopy && term.hasSelection()) { api.copy(term.getSelection()); Mod.toast('Copied'); } });
      const me = { pid, term, ro, closed: false, retry: 0, timer: null, hist: [], hi: -1 };
      cur = me;
      const open = async () => {
        if (me.closed) return;
        term.write('\x1b[2mConnecting to the console…\x1b[0m\r\n');
        try { await Mod.call('consoleOpen', { id: pid }); } catch (e) { term.write(`\x1b[31m${String(e.message || e)}\x1b[0m\r\n`); again(); }
      };
      const again = () => { if (me.closed) return; clearTimeout(me.timer); me.retry++; const wait = Math.min(30, 2 * me.retry); term.write(`\x1b[2mReconnecting in ${wait}s…\x1b[0m\r\n`); me.timer = setTimeout(open, wait * 1000); };
      me.again = again;
      box.querySelector('.gpIn').onsubmit = async (ev) => {
        ev.preventDefault(); const c = input.value; if (!c.trim()) return;
        me.hist.unshift(c); me.hi = -1; input.value = '';
        try { await Mod.call('consoleSend', { id: pid, command: c }); } catch (e) { Mod.toast(String(e.message || e)); }
      };
      input.onkeydown = (ev) => {
        if (ev.key === 'ArrowUp' && me.hist.length) { me.hi = Math.min(me.hist.length - 1, me.hi + 1); input.value = me.hist[me.hi]; ev.preventDefault(); }
        else if (ev.key === 'ArrowDown') { me.hi = Math.max(-1, me.hi - 1); input.value = me.hi < 0 ? '' : me.hist[me.hi]; ev.preventDefault(); }
      };
      open(); setTimeout(() => input.focus(), 50);
    },
    unmount(box, s) {
      const me = cur; cur = null; if (!me) return;
      me.closed = true; clearTimeout(me.timer); try { me.ro.disconnect(); } catch {} try { me.term.dispose(); } catch {}
      Mod.call('consoleClose', { id: me.pid }).catch(() => {});
    },
  },
});

Mod.on('console', (d) => {
  const me = cur; if (!me || d.id !== me.pid) { if (d.id && (d.type === 'status' || d.type === 'stats')) onLive(d); return; }
  const t = me.term;
  switch (d.type) {
    case 'ready': me.retry = 0; t.reset(); break;   // the panel now replays recent output: start from a clean screen
    case 'line': t.write(d.text + '\r\n'); break;
    case 'status': case 'stats': onLive(d); break;
    case 'error': t.write(`\x1b[31m${d.message}\x1b[0m\r\n`); break;
    case 'closed': t.write('\x1b[2m[Console disconnected]\x1b[0m\r\n'); me.again(); break;
  }
});
function onLive(d) { // the console socket is the fastest source for state and usage
  if (d.type === 'status') setInfo(d.id, { state: d.state, error: '' });
  else setInfo(d.id, { state: d.state || (info.get(d.id) || {}).state, cpu: d.cpu, mem: d.mem, memLimit: d.memLimit, disk: d.disk, error: '' });
}
//==== css ====
.gpFormHead{font-size:12px;color:var(--mut);margin-bottom:6px}
.gpList{display:flex;flex-direction:column;gap:4px;max-height:210px;overflow:auto}
.gpRow{padding:7px 10px;border:1px solid var(--line);border-radius:var(--rs);cursor:pointer;background:var(--btn)}
.gpRow:hover{background:var(--btn2)}
.gpRow.on{border-color:var(--acc);background:var(--selbg)}
.gpRow.used{opacity:.45;cursor:default}
.gpRow b{display:block;color:var(--fg);font-weight:600}.gpRow small{color:var(--mut);font-size:11px}
.gpMsg{margin-top:6px;min-height:1em}.gpCfg{margin-top:6px}
.gpBar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;min-width:0}
.gpState{display:inline-flex;align-items:center;gap:0;font-weight:600;white-space:nowrap}
.gpBtns{display:inline-flex;gap:4px}
.gpBtns button{padding:4px 10px}
.gpStats{color:var(--mut);white-space:nowrap;font-variant-numeric:tabular-nums}
.gpStats b{color:var(--fg);font-weight:600}.gpStats i{font-style:normal;margin:0 8px;opacity:.5}
.gpCon{display:flex;flex-direction:column;gap:8px;flex:1;min-height:0}
.gpTerm{flex:1;min-height:160px;border:1px solid var(--line);border-radius:var(--r);padding:6px 4px 2px 8px;overflow:hidden}
.gpIn{display:flex;gap:8px;align-items:center}
.gpIn span{color:var(--mut);font-size:16px}
.gpIn input{flex:1;font-family:ui-monospace,"SF Mono",Menlo,monospace}
