//==== module ====
{
  "id": "game_panel",
  "name": "Game Panel Helper",
  "description": "Allows for management of game servers in a Pterodactyl-compatible panel.",
  "version": "1.1.0",
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

// ---- files (Calagopus/Pterodactyl client API: /files/list, /files/contents, /files/write, /files/download, /files/upload, ...) ----
const enc = encodeURIComponent;
async function raw(path, opts = {}) { // like req(), but for raw bodies / non-JSON answers
  const key = api.config().apiKey; if (!key) throw new Error('Client API key is not set. Open Settings > Modules > Game Panel Helper (gear icon).');
  let r;
  try { r = await api.fetch(baseUrl() + '/api/client' + path, { method: opts.method || 'GET', timeout: 120000, headers: { Authorization: 'Bearer ' + key, Accept: '*/*', ...(opts.type ? { 'Content-Type': opts.type } : {}) }, body: opts.body }); }
  catch (e) { throw new Error('Could not reach the panel: ' + ((e && e.cause && (e.cause.code || e.cause.message)) || (e && e.message) || e)); }
  if (!r.ok) { let m = ''; try { const j = JSON.parse(await r.text()); const e0 = j && j.errors && j.errors[0]; m = typeof e0 === 'string' ? e0 : (e0 && (e0.detail || e0.code)) || j.error || ''; } catch {} throw new Error((m || 'The panel answered') + ` (HTTP ${r.status})`); }
  return r;
}
const pathOk = (p) => { p = String(p == null ? '/' : p); if (p.length > 4096 || p.includes('\0')) throw new Error('Invalid path'); return p.startsWith('/') ? p : '/' + p; };
const nameOk = (n) => { n = String(n || ''); if (!n || n.includes('/') || n.includes('\0') || n === '.' || n === '..') throw new Error('Invalid file name'); return n; };

api.handle('filesList', async ({ id, dir }) => {
  id = idOk(id); dir = pathOk(dir); const out = [];
  for (let page = 1; page <= 40; page++) {
    const j = await req(`/servers/${id}/files/list?directory=${enc(dir)}&per_page=500&page=${page}`);
    const e = (j && j.entries) || j || {}, rows = Array.isArray(e.data) ? e.data : Array.isArray(j && j.data) ? j.data.map((d) => d.attributes || d) : [];
    for (const f of rows) out.push({ name: f.name, dir: !!(f.directory || f.is_directory || f.is_file === false), symlink: !!(f.symlink || f.is_symlink), size: Number(f.size) || 0, modified: f.modified || f.modified_at || f.created || '', mime: f.mime || f.mimetype || '' });
    if (!e.per_page || !e.total || page * e.per_page >= e.total) break;
  }
  return out;
});
api.handle('filesRead', async ({ id, path }) => { const r = await raw(`/servers/${idOk(id)}/files/contents?file=${enc(pathOk(path))}`); return await r.text(); });
api.handle('filesWrite', async ({ id, path, text }) => { await raw(`/servers/${idOk(id)}/files/write?file=${enc(pathOk(path))}`, { method: 'POST', type: 'text/plain', body: Buffer.from(String(text), 'utf8') }); return true; });
api.handle('filesMkdir', async ({ id, root, name }) => { await req(`/servers/${idOk(id)}/files/create-directory`, { method: 'POST', body: { root: pathOk(root), name: nameOk(name) } }); return true; });
api.handle('filesDelete', async ({ id, root, names }) => { await req(`/servers/${idOk(id)}/files/delete`, { method: 'POST', body: { root: pathOk(root), files: (names || []).map(nameOk) } }); return true; });
api.handle('filesRename', async ({ id, root, from, to }) => { await req(`/servers/${idOk(id)}/files/rename`, { method: 'PUT', body: { root: pathOk(root), files: [{ from: nameOk(from), to: nameOk(to) }] } }); return true; });
api.handle('filesDownload', async ({ id, root, name }) => { // -> { name, data }  (the panel hands out a one-time link on the game node)
  const j = await req(`/servers/${idOk(id)}/files/download?root=${enc(pathOk(root))}&files=${enc(nameOk(name))}`);
  const url = j && (j.url || (j.attributes && j.attributes.url) || (j.data && j.data.url)); if (!url) throw new Error('The panel did not return a download link');
  let r; try { r = await api.fetch(url, { timeout: 600000 }); } catch (e) { throw new Error('Could not reach the game node: ' + ((e && e.cause && (e.cause.code || e.cause.message)) || (e && e.message) || e)); }
  if (!r.ok) throw new Error(`The game node answered HTTP ${r.status}`);
  const buf = Buffer.from(await r.arrayBuffer()); if (buf.length > 512 * 1048576) throw new Error('File is too large to download here (limit 512 MB)');
  return { name, data: new Uint8Array(buf) };
});
const uploads = new Map(); // upload id -> { chunks, size }
api.handle('upChunk', ({ uid, data }) => {
  uid = String(uid).slice(0, 64); const u = uploads.get(uid) || { chunks: [], size: 0 }; uploads.set(uid, u);
  const b = Buffer.from(data); u.size += b.length; if (u.size > 512 * 1048576) { uploads.delete(uid); throw new Error('File is too large to upload here (limit 512 MB)'); }
  u.chunks.push(b); return u.size;
});
api.handle('upFinish', async ({ id, uid, dir, name }) => {
  uid = String(uid).slice(0, 64); const u = uploads.get(uid); uploads.delete(uid); if (!u) throw new Error('Upload data was lost');
  const j = await req(`/servers/${idOk(id)}/files/upload`); const url = j && (j.url || (j.attributes && j.attributes.url) || (j.data && j.data.url)); if (!url) throw new Error('The panel did not return an upload link');
  const bd = '----connect' + require('crypto').randomBytes(12).toString('hex');
  const body = Buffer.concat([Buffer.from(`--${bd}\r\nContent-Disposition: form-data; name="files"; filename="${nameOk(name).replace(/["\r\n]/g, '_')}"\r\nContent-Type: application/octet-stream\r\n\r\n`), ...u.chunks, Buffer.from(`\r\n--${bd}--\r\n`)]);
  const full = url + '&directory=' + enc(pathOk(dir)) + '&total_size=' + u.size;
  let r; try { r = await api.fetch(full, { method: 'POST', timeout: 900000, headers: { 'Content-Type': 'multipart/form-data; boundary=' + bd }, body }); } catch (e) { throw new Error('Could not reach the game node: ' + ((e && e.cause && (e.cause.code || e.cause.message)) || (e && e.message) || e)); }
  if (!r.ok) { let m = ''; try { m = (JSON.parse(await r.text()).error) || ''; } catch {} throw new Error(m || `The game node answered HTTP ${r.status}`); }
  return true;
});
api.handle('upCancel', ({ uid }) => { uploads.delete(String(uid).slice(0, 64)); return true; });
api.onUnload(() => { for (const id of [...sessions.keys()]) closeSession(id); uploads.clear(); });
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
  pages: { files: filesPage(), upload: uploadPage() },
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

// ---- files + upload pages ----
const fmtSize = (n) => (n == null ? '' : fmtB(n));
const fmtDate = (v) => { if (!v) return ''; const d = new Date(typeof v === 'number' && v < 1e12 ? v * 1000 : v); return isNaN(d) ? '' : d.toLocaleString(); };
const joinP = (d, n) => (d === '/' ? '' : d.replace(/\/+$/, '')) + '/' + n;
const parentP = (d) => { const p = d.replace(/\/+$/, '').split('/'); p.pop(); return p.join('/') || '/'; };
const MAXUP = 512 * 1048576;
const mk = (tag, cls, txt) => { const e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; };
async function uploadFile(pid, dir, file, onProg) { // sends the file to the main half in slices, which then posts it to the game node
  if (file.size > MAXUP) throw new Error(`${file.name}: too large (limit 512 MB)`);
  const uid = Math.random().toString(36).slice(2) + Date.now().toString(36);
  try {
    for (let off = 0; off < file.size; off += 4194304) { await Mod.call('upChunk', { uid, data: new Uint8Array(await file.slice(off, off + 4194304).arrayBuffer()) }); if (onProg) onProg(Math.min(off + 4194304, file.size) / file.size); }
    await Mod.call('upFinish', { id: pid, uid, dir, name: file.name });
  } catch (e) { Mod.call('upCancel', { uid }).catch(() => {}); throw e; }
}
function saveBlob(name, data) { const url = URL.createObjectURL(new Blob([data])), a = document.createElement('a'); a.href = url; a.download = name; document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 60000); }
function pickFiles(cb) { const i = document.createElement('input'); i.type = 'file'; i.multiple = true; i.onchange = () => { if (i.files.length) cb([...i.files]); }; i.click(); }
async function uploadMany(pid, dir, files, say) {
  let ok = 0;
  for (let i = 0; i < files.length; i++) {
    const f = files[i];
    try { await uploadFile(pid, dir, f, (p) => say(`Uploading ${f.name} (${i + 1}/${files.length}) ${Math.round(p * 100)}%`)); ok++; }
    catch (e) { say(String(e.message || e)); Mod.toast(String(e.message || e)); return ok; }
  }
  say(`Uploaded ${ok} file${ok === 1 ? '' : 's'} to ${dir}`); return ok;
}

function filesPage() {
  let alive = false, st = null;
  return {
    mount(box, s) {
      const pid = pidOf(s); alive = true;
      const st0 = { dir: '/', rows: [], sel: new Set(), filter: '' }; st = st0;
      box.innerHTML = '';
      const root = mk('div', 'gpFiles'), bar = mk('div', 'gpFbar'), bar2 = mk('div', 'gpFbar'), listBox = mk('div', 'gpFlist'), msg = mk('div', 'gpFmsg muted');
      const btn = (t, f, title) => { const b = mk('button', '', t); if (title) b.title = title; b.onclick = f; return b; };
      const path = mk('input'); path.spellcheck = false; path.onkeydown = (e) => { if (e.key === 'Enter') go(path.value.trim() || '/'); };
      const filter = mk('input'); filter.placeholder = 'Filter this folder…'; filter.oninput = () => { st0.filter = filter.value.toLowerCase(); draw(); };
      const bDown = btn('Download', () => download(), 'Download the selected file'), bRen = btn('Rename', () => rename()), bDel = btn('Delete', () => del()), bEdit = btn('Edit', () => edit(), 'Edit the selected text file (or double-click it)');
      bDel.className = 'danger';
      bar.append(btn('↑', () => go(parentP(st0.dir)), 'Parent folder'), btn('⟳', () => go(st0.dir), 'Refresh'), path, btn('New folder', async () => { const n = await ask('New folder name'); if (!n) return; try { await Mod.call('filesMkdir', { id: pid, root: st0.dir, name: n }); go(st0.dir); } catch (e) { Mod.toast(String(e.message || e)); } }), btn('Upload…', () => pickFiles(up)));
      bar2.append(filter, bDown, bEdit, bRen, bDel);
      root.append(bar, bar2, listBox, msg); box.append(root);
      const selRows = () => st0.rows.filter((r) => st0.sel.has(r.name));
      const sync = () => { const n = st0.sel.size, one = n === 1 ? selRows()[0] : null; bDown.disabled = !(one && !one.dir); bEdit.disabled = !(one && !one.dir); bRen.disabled = !one; bDel.disabled = !n; };
      function draw() {
        listBox.innerHTML = '';
        const t = mk('table'), tb = mk('tbody'); t.innerHTML = '<thead><tr><th>Name</th><th class="r">Size</th><th>Modified</th></tr></thead>'; t.append(tb);
        const rows = st0.rows.filter((r) => !st0.filter || r.name.toLowerCase().includes(st0.filter));
        for (const r of rows) {
          const tr = mk('tr', st0.sel.has(r.name) ? 'on' : ''), n = mk('td'); n.append(mk('span', 'gpIco', r.dir ? '📁' : '📄'), document.createTextNode(' ' + r.name));
          tr.append(n, mk('td', 'r', r.dir ? '' : fmtSize(r.size)), mk('td', '', fmtDate(r.modified)));
          tr.onclick = (e) => { if (e.ctrlKey || e.metaKey) { st0.sel.has(r.name) ? st0.sel.delete(r.name) : st0.sel.add(r.name); } else { st0.sel.clear(); st0.sel.add(r.name); } draw(); };
          tr.ondblclick = () => { if (r.dir) go(joinP(st0.dir, r.name)); else edit(r); };
          tb.append(tr);
        }
        if (!rows.length) { const tr = mk('tr'), td = mk('td', 'muted', st0.rows.length ? 'No matches.' : 'This folder is empty.'); td.colSpan = 3; tr.append(td); tb.append(tr); }
        listBox.append(t); sync();
      }
      async function go(dir) {
        dir = dir.startsWith('/') ? dir : '/' + dir; msg.textContent = 'Loading…';
        try {
          const rows = await Mod.call('filesList', { id: pid, dir }); if (!alive || st !== st0) return;
          rows.sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name, undefined, { numeric: true }));
          st0.dir = dir; st0.rows = rows; st0.sel.clear(); path.value = dir; msg.textContent = `${rows.length} item${rows.length === 1 ? '' : 's'}`; draw();
        } catch (e) { if (alive) msg.textContent = String(e.message || e); }
      }
      async function up(files) { await uploadMany(pid, st0.dir, files, (m) => { if (alive) msg.textContent = m; }); if (alive) go(st0.dir); }
      async function download() { const r = selRows()[0]; if (!r || r.dir) return; msg.textContent = 'Downloading ' + r.name + '…'; try { const d = await Mod.call('filesDownload', { id: pid, root: st0.dir, name: r.name }); saveBlob(d.name, d.data); if (alive) msg.textContent = 'Downloaded ' + r.name; } catch (e) { if (alive) msg.textContent = String(e.message || e); } }
      async function rename() { const r = selRows()[0]; if (!r) return; const n = await ask('Rename to', r.name); if (!n || n === r.name) return; try { await Mod.call('filesRename', { id: pid, root: st0.dir, from: r.name, to: n }); go(st0.dir); } catch (e) { Mod.toast(String(e.message || e)); } }
      async function del() { const rs = selRows(); if (!rs.length || !confirm(`Delete ${rs.length === 1 ? '"' + rs[0].name + '"' : rs.length + ' items'}?`)) return; try { await Mod.call('filesDelete', { id: pid, root: st0.dir, names: rs.map((r) => r.name) }); go(st0.dir); } catch (e) { Mod.toast(String(e.message || e)); } }
      async function edit(r) {
        r = r || selRows()[0]; if (!r || r.dir) return; if (r.size > 2097152) return Mod.toast('Too large to edit here (over 2 MB). Download it instead.');
        let text; try { text = await Mod.call('filesRead', { id: pid, path: joinP(st0.dir, r.name) }); } catch (e) { return Mod.toast(String(e.message || e)); }
        const ov = mk('div', 'gpEd'), head = mk('div', 'gpEdHead'), ta = mk('textarea'); ta.spellcheck = false; ta.value = text;
        const close = () => ov.remove(), save = btn('Save', async () => { try { await Mod.call('filesWrite', { id: pid, path: joinP(st0.dir, r.name), text: ta.value }); Mod.toast('Saved ' + r.name); close(); go(st0.dir); } catch (e) { Mod.toast(String(e.message || e)); } });
        save.className = 'primary'; head.append(mk('b', '', joinP(st0.dir, r.name)), save, btn('Cancel', close));
        ta.onkeydown = (e) => { if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); save.click(); } if (e.key === 'Tab') { e.preventDefault(); const a = ta.selectionStart; ta.setRangeText('\t', a, ta.selectionEnd, 'end'); } };
        ov.append(head, ta); root.append(ov); ta.focus();
      }
      root.ondragover = (e) => { e.preventDefault(); root.classList.add('drag'); }; root.ondragleave = () => root.classList.remove('drag');
      root.ondrop = (e) => { e.preventDefault(); root.classList.remove('drag'); const f = [...e.dataTransfer.files].filter((x) => x.type || x.size); if (f.length) up(f); };
      go('/');
    },
    unmount() { alive = false; st = null; },
  };
}

function uploadPage() {
  return {
    mount(box, s) {
      const pid = pidOf(s); let busy = false;
      box.innerHTML = '';
      const root = mk('div', 'gpUp'), lab = mk('label', '', 'Destination folder '), dest = mk('input'), drop = mk('div', 'gpDrop'), msg = mk('div', 'muted');
      dest.value = '/'; dest.spellcheck = false; lab.append(dest);
      drop.append(mk('div', 'gpBig', '⬆'), mk('div', '', 'Drop files here'));
      const choose = mk('a', '', 'or choose files…'); choose.href = '#'; choose.onclick = (e) => { e.preventDefault(); pickFiles(go); }; drop.append(choose, msg);
      async function go(files) { if (busy) return; busy = true; drop.classList.add('busy'); await uploadMany(pid, dest.value.trim() || '/', files, (m) => { msg.textContent = m; }); busy = false; drop.classList.remove('busy'); }
      drop.ondragover = (e) => { e.preventDefault(); drop.classList.add('drag'); }; drop.ondragleave = () => drop.classList.remove('drag');
      drop.ondrop = (e) => { e.preventDefault(); drop.classList.remove('drag'); const f = [...e.dataTransfer.files].filter((x) => x.type || x.size); if (f.length) go(f); };
      root.append(lab, drop); box.append(root);
    },
    unmount() {},
  };
}

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
.gpFiles,.gpUp{display:flex;flex-direction:column;gap:8px;flex:1;min-height:0;position:relative}
.gpFbar{display:flex;gap:6px;align-items:center}.gpFbar input{flex:1;min-width:0}
.gpFlist{flex:1;min-height:120px;overflow:auto;border:1px solid var(--line);border-radius:var(--r)}
.gpFlist table{width:100%;border-collapse:collapse}.gpFlist th{text-align:left;font-size:11px;color:var(--mut);padding:6px 10px;position:sticky;top:0;background:var(--btn)}
.gpFlist td{padding:5px 10px;white-space:nowrap;cursor:default}.gpFlist .r{text-align:right}.gpFlist tr:hover td{background:var(--btn2)}.gpFlist tr.on td{background:var(--selbg)}
.gpFiles.drag .gpFlist,.gpDrop.drag{border-color:var(--acc)}
.gpEd{position:absolute;inset:0;background:var(--bg,#0c0e12);display:flex;flex-direction:column;gap:6px;z-index:5}
.gpEdHead{display:flex;gap:8px;align-items:center}.gpEdHead b{flex:1;overflow:hidden;text-overflow:ellipsis}
.gpEd textarea{flex:1;font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:13px;resize:none;tab-size:4;white-space:pre}
.gpUp label{display:flex;gap:8px;align-items:center}.gpUp label input{flex:1}
.gpDrop{flex:1;min-height:200px;border:2px dashed var(--line);border-radius:var(--r);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px}
.gpBig{font-size:42px;opacity:.6}.gpDrop.busy{opacity:.8}
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
