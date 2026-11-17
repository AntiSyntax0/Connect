//==== module ====
{
  "id": "proxmox",
  "name": "Proxmox",
  "description": "Manage Proxmox VE right inside Connect. Adds a \"Proxmox Node\" server type (the Terminal is the node's root shell) with tabs for VM and container control, a live resource monitor with status dots, a creation wizard for VMs and LXC containers (with an option to add the new guest to your server list), ISO upload straight to a node, and a built-in live console: VNC for VMs and a terminal for containers. Each guest gets Console, Resources, Network, Options and Summary tabs. Uses a Proxmox API token (Datacenter > Permissions > API Tokens); the node's certificate is pinned by fingerprint.",
  "version": "0.1.1",
  "minApi": 5,
  "permissions": [
    "data",
    "net"
  ],
  "config": [
    {
      "key": "interval",
      "label": "Refresh every (seconds)",
      "type": "number",
      "default": 5,
      "help": "How often the Mgmt and Monitor pages refresh while open (2 to 60). Status dots in the server list refresh every 30 seconds."
    },
    {
      "key": "confirmStop",
      "label": "Ask before forced stop, reset and delete",
      "type": "checkbox",
      "default": true,
      "help": "Shows a confirmation before actions that can lose data."
    }
  ]
}
//==== main ====
// Proxmox (main process). Talks to the Proxmox VE API with an API token over https. The node's certificate is pinned by SHA-256 fingerprint
// (api.net), so self-signed nodes work without turning certificate checking off. The token secret is stored encrypted in the server record
// (field pveSecret) and is only ever used here to build the Authorization header.
const crypto = require('crypto');
const dec = (v) => (v ? api.secret.dec(v) : '');
const servers = () => api.data.read('servers.json', []) || [];
const fail = (m) => { throw new Error(m); };

function serverConn(id) {
  const s = servers().find((x) => x && x.id === id); if (!s || s.type !== 'pve') fail('That Proxmox node is not in your server list any more');
  return conn(s, { host: s.pveHost || s.host, port: s.pvePort || 8006, tokenId: s.pveTokenId, secret: dec(s.pveSecret), fp: s.pveFp, node: s.pveNode });
}
function conn(s, o) {
  if (!o.host) fail('No host set'); if (!o.tokenId || !o.secret) fail('This node has no API token. Edit the server and enter the token ID and secret.');
  if (!o.fp) fail('This node\'s certificate is not trusted yet. Edit the server and press "Check certificate".');
  return { host: String(o.host), port: Number(o.port) || 8006, fp: o.fp, node: o.node, auth: `PVEAPIToken=${o.tokenId}=${o.secret}` };
}
const ALLOWED = /^\/(nodes\/[A-Za-z0-9._-]+|cluster|storage|pools|version|access\/permissions)(\/[\w.@:%!~*'()=+,-]*)*$/;
const enc = (v) => encodeURIComponent(v === true ? 1 : v === false ? 0 : String(v));
function form(p) { const out = []; for (const [k, v] of Object.entries(p || {})) { if (v === undefined || v === null || v === '') continue; out.push(`${encodeURIComponent(k)}=${enc(v)}`); } return out.join('&'); }

async function call(c, method, path, params) {
  method = String(method || 'GET').toUpperCase();
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(method)) fail('Bad method');
  path = String(path || ''); if (path.includes('..') || !ALLOWED.test(path)) fail('Path not allowed: ' + path);
  const m = /^\/nodes\/([^/]+)/.exec(path); if (m && c.node && m[1] !== c.node) fail('This server only manages node ' + c.node);
  const q = form(params), body = method === 'GET' || method === 'DELETE' ? null : q;
  const r = await api.net.request({ host: c.host, port: c.port, fingerprint: c.fp, method, path: '/api2/json' + path + (body === null && q ? '?' + q : ''), timeout: 30000,
    headers: { Authorization: c.auth, Accept: 'application/json', ...(body !== null ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) }, body });
  let j = null; try { j = JSON.parse(r.body); } catch {}
  if (r.status >= 400 || !j) {
    let msg = j && (j.message || '') || ''; if (j && j.errors && typeof j.errors === 'object') msg += ' ' + Object.entries(j.errors).map(([k, v]) => `${k}: ${v}`).join('; ');
    fail(`Proxmox said ${r.status}${msg ? ': ' + msg.trim() : r.status === 401 ? ': the API token was refused' : r.status === 403 ? ': the token lacks permission for this' : ''}`);
  }
  return j.data;
}

// ---- handlers ----
api.handle('probe', async ({ host, port }) => { if (!host) fail('Enter the host first'); return api.net.probe(host, Number(port) || 8006); });
api.handle('test', async (a) => {
  const c = conn(null, { host: a.host, port: a.port, tokenId: String(a.tokenId || '').trim(), secret: String(a.secret || ''), fp: a.fp, node: '' });
  const v = await call(c, 'GET', '/version'); const nodes = await call(c, 'GET', '/cluster/resources', { type: 'node' }).catch(() => []);
  return { version: v && v.version, release: v && v.release, nodes: (nodes || []).map((n) => ({ node: n.node, status: n.status })) };
});
api.handle('api', async ({ id, method, path, params }) => { const c = serverConn(id); return call(c, method, String(path || '').replace(/^\/nodes\/@/, '/nodes/' + c.node), params); }); // "/nodes/@/..." means this server's node
api.handle('nodes', async () => servers().filter((x) => x && x.type === 'pve').map((x) => ({ id: x.id, name: x.name, host: x.host, node: x.pveNode, group: x.group || '' })));
// one call for the Mgmt / Monitor pages: every guest, the node and the storages
api.handle('overview', async ({ id }) => {
  const c = serverConn(id);
  const [res, status] = await Promise.all([call(c, 'GET', '/cluster/resources').catch(() => null), call(c, 'GET', `/nodes/${c.node}/status`)]);
  let guests = res ? res.filter((r) => (r.type === 'qemu' || r.type === 'lxc') && r.node === c.node) : null, stores = res ? res.filter((r) => r.type === 'storage' && r.node === c.node) : null;
  if (!res) { // a token without Sys.Audit on / may not see cluster resources: fall back to the node's own lists
    const [q, l, st] = await Promise.all([call(c, 'GET', `/nodes/${c.node}/qemu`).catch(() => []), call(c, 'GET', `/nodes/${c.node}/lxc`).catch(() => []), call(c, 'GET', `/nodes/${c.node}/storage`).catch(() => [])]);
    guests = [...q.map((g) => ({ ...g, type: 'qemu' })), ...l.map((g) => ({ ...g, type: 'lxc' }))]; stores = st.map((x) => ({ ...x, type: 'storage' }));
  }
  return { status, guests, stores, at: Date.now() };
});

// ---- ISO / template upload ----
api.handle('pickIso', async () => api.net.pickFile({ title: 'Choose an ISO image', filters: [{ name: 'Disc images', extensions: ['iso', 'img'] }, { name: 'All files', extensions: ['*'] }] }));
api.handle('uploadFile', async ({ id, storage, filePath, content, name }) => {
  const c = serverConn(id); if (!storage) fail('Choose a storage');
  const kind = content === 'vztmpl' ? 'vztmpl' : 'iso';
  const r = await api.net.upload({ host: c.host, port: c.port, fingerprint: c.fp, path: `/api2/json/nodes/${c.node}/storage/${encodeURIComponent(storage)}/upload`, headers: { Authorization: c.auth },
    fields: { content: kind }, fileField: 'filename', fileName: name, filePath, onProgress: (sent, total) => api.emit('upload', { id, sent, total }) });
  let j = null; try { j = JSON.parse(r.body); } catch {}
  if (r.status >= 400 || !j) fail(`Upload refused (${r.status}${j && j.message ? ': ' + j.message : ''})`);
  return j.data; // UPID of the import task
});
api.handle('cancelUpload', async () => { api.net.cancelUploads(); return true; });

// ---- live console ----
const sess = new Map(); let sn = 0;
const closeSess = (sid) => { const s = sess.get(sid); if (!s) return; sess.delete(sid); clearInterval(s.ping); try { s.ws.close(); } catch {} };
api.handle('consoleOpen', async ({ id, kind, vmid }) => {
  const c = serverConn(id); if (!/^\d{1,9}$/.test(String(vmid))) fail('Bad VMID'); vmid = String(vmid);
  if (kind !== 'qemu' && kind !== 'lxc') fail('Bad guest type');
  const base = `/nodes/${c.node}/${kind}/${vmid}`;
  const p = kind === 'qemu' ? await call(c, 'POST', base + '/vncproxy', { websocket: 1 }) : await call(c, 'POST', base + '/termproxy');
  const url = `wss://${c.host}:${c.port}/api2/json${base}/vncwebsocket?port=${encodeURIComponent(p.port)}&vncticket=${encodeURIComponent(p.ticket)}`;
  const ws = await api.net.websocket(url, { fingerprint: c.fp, headers: { Authorization: c.auth } });
  const sid = 's' + (++sn); const s = { ws, kind, ready: kind === 'qemu', ping: null }; sess.set(sid, s);
  ws.on('message', (m) => {
    if (kind === 'lxc' && !s.ready) { s.ready = true; const t = Buffer.isBuffer(m) ? m.toString('latin1') : String(m); if (t.startsWith('OK')) { m = t.slice(2); if (!m.length) return; m = Buffer.from(m, 'latin1'); } }
    api.emit('console', { sid, data: Buffer.isBuffer(m) ? m : Buffer.from(String(m)) });
  });
  ws.on('close', () => { clearInterval(s.ping); if (sess.delete(sid)) api.emit('consoleClosed', { sid }); });
  ws.on('error', (e) => { api.log('console error: ' + (e && e.message)); });
  await new Promise((res, rej) => { if (ws.readyState === 1) return res(); ws.once('open', res); ws.once('error', rej); ws.once('close', () => rej(new Error('The console connection closed'))); });
  if (kind === 'lxc') { ws.send(`${p.user}:${p.ticket}\n`); s.ping = setInterval(() => { try { ws.send('2'); } catch {} }, 30000); }
  return { sid, ticket: p.ticket, kind };
});
api.handle('consoleSend', async ({ sid, data, text }) => {
  const s = sess.get(sid); if (!s) return false;
  if (s.kind === 'lxc') { const b = text != null ? Buffer.from(String(text), 'utf8') : Buffer.from(data); s.ws.send('0:' + b.length + ':' + b.toString('utf8')); }
  else s.ws.send(Buffer.from(data));
  return true;
});
api.handle('consoleResize', async ({ sid, cols, rows }) => { const s = sess.get(sid); if (s && s.kind === 'lxc') s.ws.send(`1:${Math.max(1, cols | 0)}:${Math.max(1, rows | 0)}:`); return true; });
api.handle('consoleClose', async ({ sid }) => { closeSess(sid); return true; });
api.onUnload(() => { for (const sid of [...sess.keys()]) closeSess(sid); });

// ---- add a guest to the server list ----
api.handle('addServer', async ({ nodeId, name, host, vmid, kind, group, username }) => {
  const node = servers().find((x) => x && x.id === nodeId); if (!node) fail('Node not found');
  if (!host) fail('This guest has no address to connect to yet');
  const list = servers(); const dup = list.find((x) => x && x.ext && x.ext.pve && x.ext.pve.nodeId === nodeId && String(x.ext.pve.vmid) === String(vmid));
  if (dup) return { id: dup.id, existed: true };
  const rec = { id: crypto.randomUUID(), name: String(name || `${kind === 'lxc' ? 'CT' : 'VM'} ${vmid}`).slice(0, 80), host: String(host), port: '', username: String(username || 'root'), authType: 'config', password: '', keyPath: '', passphrase: '', remotePath: '', splitMode: '', group: String(group || node.group || ''), jumpId: '', startCmd: '', color: '', ext: { pve: { nodeId, vmid: Number(vmid), kind } } };
  list.push(rec); api.data.write('servers.json', list);
  return { id: rec.id, existed: false };
});
//==== renderer ====
// Proxmox (window). A "Proxmox Node" server type (an SSH server with extra tabs) and an add-on for plain SSH servers that are VMs / containers
// of a node (adds a Console tab). All text goes in with textContent, never as HTML. The API token never reaches this side after it is saved:
// every Proxmox call goes through the main-process half (Mod.call).
const el = (tag, cls, text) => { const x = document.createElement(tag); if (cls) x.className = cls; if (text != null) x.textContent = text; return x; };
const errText = (e) => String(e && e.message || e || '').replace(/^Error invoking remote method '[^']*': (Error: )?/, '');
const lsGet = (k, d) => { try { const v = localStorage.getItem('pve.' + k); return v == null ? d : v; } catch { return d; } };
const lsSet = (k, v) => { try { localStorage.setItem('pve.' + k, v); } catch {} };
const fail = (e) => { Mod.toast(errText(e).slice(0, 220)); };
const ic = (n, s = 14) => { try { return icon(n, s); } catch { return ''; } };
const mkBtn = (label, cls, fn, title) => { const b = el('button', cls || '', label); b.type = 'button'; if (title) b.title = title; if (fn) b.onclick = fn; return b; };
const ivl = () => Math.min(60, Math.max(2, +(Mod.config().interval) || 5)) * 1000;

// ---- formatting ----
const fb = (n) => { n = +n || 0; const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']; let i = 0; while (n >= 1024 && i < 5) { n /= 1024; i++; } return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i]; };
const fr = (n) => fb(n) + '/s';
const fp = (x) => (x == null || isNaN(x) ? '–' : (x * 100).toFixed(x < 0.1 && x > 0 ? 1 : 0) + '%');
const fup = (s) => { s = +s || 0; if (!s) return '–'; const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${Math.floor(s % 60)}s`; };
const ftime = (t) => (t ? new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '');
const KIND = { qemu: 'VM', lxc: 'LXC' };
const dotCls = (st) => (st === 'running' || st === 'online' ? 'ok' : st === 'paused' || st === 'suspended' || st === 'prelaunch' ? 'warn' : st === 'stopped' || st === 'offline' ? 'off' : 'bad');
const dot = (st) => { const d = el('span', 'pv-dot ' + dotCls(st)); d.title = st || 'unknown'; return d; };
const parseKV = (str) => { const o = {}, order = []; String(str || '').split(',').forEach((p, i) => { const k = p.indexOf('='); if (k < 0) { if (i === 0) o._first = p; return; } o[p.slice(0, k)] = p.slice(k + 1); order.push(p.slice(0, k)); }); o._order = order; return o; };
const kvStr = (o, first) => [first != null && first !== '' ? first : null, ...Object.entries(o).filter(([k, v]) => k[0] !== '_' && v !== '' && v != null && v !== false).map(([k, v]) => `${k}=${v === true ? 1 : v}`)].filter((x) => x != null).join(',');

// ---- calls ----
const P = (nodeId, method, path, params) => Mod.call('api', { id: nodeId, method, path: '/nodes/@' + path, params });
const PC = (nodeId, method, path, params) => Mod.call('api', { id: nodeId, method, path, params });
const gpath = (g) => `/${g.kind}/${g.vmid}`;

// ---- per-server state ----
const ST = new Map();                       // node server id -> { guest: { kind, vmid, name } | null }
const stOf = (id) => { let o = ST.get(id); if (!o) ST.set(id, o = { guest: null }); return o; };
// what a server page is about: the node (its id) and, if one is selected, a guest
const targetOf = (s) => (s.type === 'pve' ? { nodeId: s.id, guest: stOf(s.id).guest } : { nodeId: s.ext.pve.nodeId, guest: { kind: s.ext.pve.kind, vmid: s.ext.pve.vmid, name: s.name } });

// ---- page plumbing: mount(box, s) draws, unmount stops timers ----
function page(build) {
  const live = new Map();
  return {
    mount(box, s) {
      box.innerHTML = ''; const root = el('div', 'pv-root'); box.append(root);
      const timers = new Set(), subs = []; let alive = true;
      const ctl = {
        get alive() { return alive; },
        every(fn, msf) { const run = async () => { if (!alive || document.hidden) return; try { await fn(); } catch (e) { /* shown by the page */ } }; const t = setInterval(run, typeof msf === 'function' ? msf() : msf); timers.add(t); run(); return t; },
        onStop(fn) { subs.push(fn); },
        stop() { alive = false; timers.forEach(clearInterval); timers.clear(); subs.splice(0).forEach((f) => { try { f(); } catch {} }); },
      };
      live.set(box, ctl);
      try { build(root, s, ctl); } catch (e) { console.error(e); root.textContent = 'This page failed to start: ' + errText(e); }
    },
    unmount(box) { const c = live.get(box); if (c) { c.stop(); live.delete(box); } },
  };
}
const note = (text, cls) => el('div', 'pv-note ' + (cls || ''), text);
function bar(frac, label, warn) { const b = el('div', 'pv-bar'), i = el('i'); const f = Math.max(0, Math.min(1, +frac || 0)); i.style.width = (f * 100).toFixed(1) + '%'; if (warn !== false && f > 0.9) i.className = 'bad'; else if (warn !== false && f > 0.75) i.className = 'warn'; b.append(i); if (label) b.append(el('span', 'pv-barl', label)); return b; }
function modal(title, build, opts = {}) {
  const back = el('div', 'pv-modal'), box = el('div', 'pv-mbox' + (opts.wide ? ' wide' : '')), head = el('div', 'pv-mhead'), body = el('div', 'pv-mbody');
  let closed = false;
  const close = () => { if (closed) return; closed = true; try { opts.onClose && opts.onClose(); } catch {} back.remove(); document.removeEventListener('keydown', key, true); };
  const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  head.append(el('b', '', title), mkBtn('×', 'pv-x', () => close())); box.append(head, body); back.append(box); document.body.append(back);
  document.addEventListener('keydown', key, true);
  back.addEventListener('mousedown', (e) => { if (e.target === back && !opts.sticky) close(); });
  build(body, close); return close;
}
function ask(title, text, okLabel, danger) {
  return new Promise((res) => { let done = false; modal(title, (b, cl) => { b.append(el('p', '', text)); const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', () => { done = true; res(false); cl(); }), mkBtn(okLabel || 'OK', danger ? 'danger' : 'primary', () => { done = true; res(true); cl(); })); b.append(r); }, { onClose: () => { if (!done) res(false); } }); });
}
const guard = (what) => (Mod.config().confirmStop === false ? Promise.resolve(true) : ask('Are you sure?', what, 'Yes, do it', true));

// ---- tasks ----
async function waitTask(nodeId, upid, onLog, ctl) {
  const enc = encodeURIComponent(upid); let start = 0;
  for (let i = 0; i < 1800; i++) {
    if (ctl && !ctl.alive) return { status: 'stopped', exitstatus: 'left the page' };
    let st; try { st = await P(nodeId, 'GET', `/tasks/${enc}/status`); } catch (e) { if (i > 3) throw e; await new Promise((r) => setTimeout(r, 1000)); continue; }
    if (onLog) { try { const lg = await P(nodeId, 'GET', `/tasks/${enc}/log`, { start, limit: 500 }); if (lg && lg.length) { start += lg.length; onLog(lg.map((l) => l.t)); } } catch {} }
    if (st.status === 'stopped') return st;
    await new Promise((r) => setTimeout(r, i < 10 ? 700 : 1500));
  }
  throw new Error('The task is still running; check the task list.');
}
async function runTask(nodeId, upid, label, after) {
  Mod.toast(label + '…');
  try { const st = await waitTask(nodeId, upid); Mod.toast(st.exitstatus === 'OK' ? label + ': done' : `${label}: ${st.exitstatus || 'failed'}`.slice(0, 160)); } catch (e) { fail(e); }
  if (after) try { after(); } catch {}
}
function showLog(nodeId, upid, title) {
  modal(title || 'Task log', (b) => {
    const pre = el('pre', 'pv-log', 'Loading…'); b.append(pre); let first = true;
    waitTask(nodeId, upid, (lines) => { if (first) { pre.textContent = ''; first = false; } pre.textContent += lines.join('\n') + '\n'; pre.scrollTop = pre.scrollHeight; })
      .then((st) => { pre.textContent += `\n— ${st.exitstatus || st.status}`; }).catch((e) => { pre.textContent += '\n' + errText(e); });
  }, { wide: true });
}

// ---- node status (for the dots in the server list) ----
const NODE = new Map();   // node server id -> { online, running, total, guests: Map(vmid -> status) }
let pollT = null;
async function pollNodes() {
  if (document.hidden) return;
  let list = []; try { list = await Mod.call('nodes'); } catch { return; }
  let changed = false;
  await Promise.all(list.map(async (n) => {
    let next;
    try { const o = await Mod.call('overview', { id: n.id }); next = { online: true, running: o.guests.filter((g) => g.status === 'running').length, total: o.guests.length, guests: new Map(o.guests.map((g) => [g.vmid, g.status])) }; }
    catch (e) { next = { online: false, err: errText(e), running: 0, total: 0, guests: new Map() }; }
    const old = NODE.get(n.id);
    if (!old || old.online !== next.online || old.running !== next.running || old.total !== next.total || [...next.guests].some(([k, v]) => old.guests.get(k) !== v)) changed = true;
    NODE.set(n.id, next);
  }));
  if (changed) Mod.refresh();
}
pollT = setInterval(pollNodes, 30000); setTimeout(pollNodes, 1500);
Mod.onUnload(() => clearInterval(pollT));
function sdot(elm, cls, title) { const b = elm.querySelector('b'); if (!b) return; const d = el('span', 'pv-sdot ' + cls); d.title = title; b.append(d); }

// ---- charts ----
const COLORS = ['#4c9aff', '#3ecf8e', '#f5a524', '#b58cff'];
const NSV = 'http://www.w3.org/2000/svg';
const sv = (tag, attrs, parent) => { const n = document.createElementNS(NSV, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); if (parent) parent.append(n); return n; };
// series: [{ label, data: [[unixTime, value|null], ...] }], o: { title, fmt(v), max, h }
function lineChart(o) {
  const wrap = el('div', 'pv-chart'), head = el('div', 'pv-chead'), title = el('b', '', o.title || ''), legend = el('span', 'pv-legend'); head.append(title, legend);
  const W = 600, H = o.h || 110, svg = sv('svg', { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: 'none', class: 'pv-svg' }), tip = el('div', 'pv-tip'); tip.hidden = true;
  const box = el('div', 'pv-cbox'); box.append(svg, tip); wrap.append(head, box);
  let cur = [];
  function draw(series) {
    cur = series; svg.innerHTML = ''; legend.innerHTML = '';
    if (!series.some((s) => s.data.length)) return;
    const all = series.flatMap((s) => s.data.map((d) => d[1]).filter((v) => v != null && isFinite(v)));
    const max = o.max || Math.max(...all, o.min1 || 1e-9) * 1.1, t0 = Math.min(...series.flatMap((s) => s.data.map((d) => d[0]))), t1 = Math.max(...series.flatMap((s) => s.data.map((d) => d[0])));
    for (let i = 1; i < 4; i++) sv('line', { x1: 0, x2: W, y1: H * i / 4, y2: H * i / 4, class: 'pv-grid' }, svg);
    series.forEach((s, si) => {
      const c = COLORS[si % COLORS.length]; const lg = el('span', 'pv-lg'); const sw = el('i'); sw.style.background = c; lg.append(sw, document.createTextNode(s.label)); legend.append(lg);
      let d = '', last = null; const pts = [];
      for (const [t, v] of s.data) { if (v == null || !isFinite(v)) { last = null; continue; } const x = t1 === t0 ? W : (t - t0) / (t1 - t0) * W, y = H - 2 - Math.min(1, v / max) * (H - 6); pts.push([x, y]); d += (last ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1); last = [x, y]; }
      if (!pts.length) return;
      if (si === 0 && series.length === 1) sv('path', { d: d + `L${pts[pts.length - 1][0].toFixed(1)} ${H}L${pts[0][0].toFixed(1)} ${H}Z`, fill: c, opacity: 0.14 }, svg);
      sv('path', { d, fill: 'none', stroke: c, 'stroke-width': 1.6, 'vector-effect': 'non-scaling-stroke', 'stroke-linejoin': 'round' }, svg);
    });
    const mx = el('span', 'pv-ymax', (o.fmt || String)(max)); box.querySelectorAll('.pv-ymax').forEach((x) => x.remove()); box.append(mx);
    wrap._t = [t0, t1];
  }
  box.onmousemove = (e) => {
    if (!cur.length || !cur[0].data.length) return; const r = box.getBoundingClientRect(), f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)), [t0, t1] = wrap._t, t = t0 + f * (t1 - t0);
    const rows = cur.map((s, i) => { let best = null; for (const d of s.data) if (d[1] != null && (!best || Math.abs(d[0] - t) < Math.abs(best[0] - t))) best = d; return best ? `${s.label}: ${(o.fmt || String)(best[1])}` : null; }).filter(Boolean);
    const ref = cur[0].data.reduce((b, d) => (!b || Math.abs(d[0] - t) < Math.abs(b[0] - t) ? d : b), null);
    tip.hidden = !rows.length; tip.textContent = (ref ? new Date(ref[0] * 1000).toLocaleTimeString() + '\n' : '') + rows.join('\n'); tip.style.left = Math.min(r.width - 140, Math.max(0, e.clientX - r.left + 10)) + 'px';
  };
  box.onmouseleave = () => { tip.hidden = true; };
  wrap.update = draw; return wrap;
}

// ---- the "Proxmox Node" server type ----
const TABS_NODE = [
  { id: 'pve-mgmt', label: 'Mgmt', icon: 'server' },
  { id: 'pve-mon', label: 'Monitor', icon: 'bolt' },
  { id: 'pve-new', label: 'New', icon: 'plus-circle' },
];
const TABS_GUEST = [
  { id: 'pve-console', label: 'Console', icon: 'terminal' },
  { id: 'pve-res', label: 'Resources', icon: 'sliders' },
  { id: 'pve-net', label: 'Network', icon: 'link' },
  { id: 'pve-opt', label: 'Options', icon: 'gear' },
  { id: 'pve-sum', label: 'Summary', icon: 'info' },
];
function selectGuest(s, g, tab) {   // choose a VM / container of a node: its tabs appear
  const o = stOf(s.id); o.guest = g ? { kind: g.type || g.kind, vmid: g.vmid, name: g.name || '' } : null;
  Mod.refreshTabs(); if (tab) Mod.selectTab(tab);
}
const PAGES = {};
function nodeForm(box, server, ctx) {
  const v = server || {}; let fpv = v.pveFp || '';
  const root = el('div', 'pv-form'); box.append(root);
  const lab = (t, input, help) => { const l = el('label', ''); l.append(document.createTextNode(t + ' '), input); if (help) l.append(el('small', 'pv-help', help)); root.append(l); return l; };
  const inp = (val, ph, type) => { const i = el('input'); i.type = type || 'text'; i.value = val == null ? '' : val; i.placeholder = ph || ''; i.autocomplete = 'off'; i.spellcheck = false; return i; };
  root.append(el('div', 'pv-formh', 'Proxmox API access'));
  const port = inp(v.pvePort || 8006, '8006', 'number'), tokId = inp(v.pveTokenId, 'user@pam!connect'), secret = inp(v.pveSecret, 'the secret shown once when the token was created', 'password'), node = inp(v.pveNode, 'pve'), dl = el('datalist'); dl.id = 'pvNodes' + Math.random().toString(36).slice(2, 7); node.setAttribute('list', dl.id);
  lab('API port', port); lab('Node name', node, 'The name shown in the Proxmox tree (e.g. pve).'); root.append(dl);
  lab('API token ID', tokId, 'Datacenter > Permissions > API Tokens. Uncheck "Privilege Separation" or give the token the roles it needs (e.g. PVEAdmin).').classList.add('wide');
  lab('API token secret', secret).classList.add('wide');
  const fpIn = inp(fpv, 'not checked yet'); fpIn.readOnly = true; const certRow = el('div', 'pv-certrow'), certMsg = el('div', 'pv-help wide'); certRow.append(fpIn, mkBtn('Check certificate', '', () => checkCert()));
  lab('Certificate fingerprint (pinned)', certRow).classList.add('wide'); root.append(certMsg);
  const testRow = el('div', 'pv-certrow wide'), testMsg = el('span', 'pv-help'); testRow.append(mkBtn('Test connection', '', () => test()), testMsg); root.append(testRow);
  root.append(el('div', 'pv-help wide', 'The SSH login below (host, user, key or password) is used for the node\'s shell and files. The API token is used for everything else.'));
  const hostVal = () => { const f = document.querySelector('#form [name=host]'); return f ? f.value.trim() : ''; };
  async function checkCert() {
    certMsg.textContent = 'Connecting…'; certMsg.className = 'pv-help wide';
    try {
      const r = await Mod.call('probe', { host: hostVal(), port: +port.value || 8006 });
      certMsg.textContent = ''; certMsg.className = 'pv-help wide';
      const same = fpv && fpv === r.fingerprint;
      if (same) { certMsg.textContent = 'The node presents the pinned certificate. ✓'; certMsg.classList.add('okc'); return; }
      const t = el('div', 'pv-trust' + (fpv ? ' bad' : '')); t.append(el('div', '', (fpv ? 'WARNING: the certificate changed since you pinned it. Only continue if you replaced it on purpose.\n' : 'Check this matches the node (Datacenter > node > System > Certificates):\n') + `SHA-256  ${r.fingerprint}\nsubject ${r.subject || '–'}   issuer ${r.issuer || '–'}   valid until ${r.validTo || '–'}${r.trusted ? '\nAlso trusted by your system.' : ''}`));
      t.append(mkBtn('Trust and pin this certificate', 'primary', () => { fpv = r.fingerprint; fpIn.value = fpv; certMsg.textContent = 'Pinned. ✓'; certMsg.classList.add('okc'); }));
      certMsg.append(t);
    } catch (e) { certMsg.textContent = errText(e); certMsg.classList.add('badc'); }
  }
  async function test() {
    testMsg.textContent = 'Testing…'; testMsg.className = 'pv-help';
    try {
      if (!fpv) throw new Error('Check the certificate first');
      const r = await Mod.call('test', { host: hostVal(), port: +port.value || 8006, tokenId: tokId.value, secret: secret.value, fp: fpv });
      dl.innerHTML = ''; (r.nodes || []).forEach((n) => dl.append(new Option(n.node)));
      if (!node.value && r.nodes && r.nodes.length === 1) node.value = r.nodes[0].node;
      testMsg.textContent = `Connected: Proxmox VE ${r.version || ''}${r.nodes && r.nodes.length ? ' · nodes: ' + r.nodes.map((n) => n.node).join(', ') : ''}`; testMsg.classList.add('okc');
      if (node.value) ctx.setName(node.value);
    } catch (e) { testMsg.textContent = errText(e); testMsg.classList.add('badc'); }
  }
  if (!server) { const h = document.querySelector('#form [name=host]'); if (h) h.addEventListener('change', () => { if (!fpv) certMsg.textContent = ''; }); }
  return {
    values() {
      const t = tokId.value.trim(), n = node.value.trim();
      if (!/^[^!\s]+@[\w.-]+![\w.-]+$/.test(t)) { Mod.toast('The token ID looks like user@pam!tokenname'); return null; }
      if (!secret.value.trim()) { Mod.toast('Enter the token secret'); return null; }
      if (!/^[A-Za-z0-9._-]+$/.test(n)) { Mod.toast('Enter the node name (as shown in the Proxmox tree)'); return null; }
      if (!fpv) { Mod.toast('Press "Check certificate" and pin the node\'s certificate'); return null; }
      return { pveNode: n, pvePort: +port.value || 8006, pveTokenId: t, pveSecret: secret.value.trim(), pveFp: fpv };
    },
  };
}
Mod.serverType({
  id: 'pve', label: 'Proxmox Node', sshBacked: true, defaultTab: 'pve-mgmt',
  describe: (s) => `Proxmox · ${s.pveNode || 'node'} · ${s.username ? s.username + '@' : ''}${s.host}`,
  renderForm: nodeForm,
  tabs: (s) => { const t = [...TABS_NODE]; if (stOf(s.id).guest) t.push(...TABS_GUEST); return t; },
  pages: { 'pve-mgmt': { mount: (b, s) => PAGES.mgmt.mount(b, s), unmount: (b, s) => PAGES.mgmt.unmount(b, s) }, 'pve-mon': { mount: (b, s) => PAGES.mon.mount(b, s), unmount: (b, s) => PAGES.mon.unmount(b, s) }, 'pve-new': { mount: (b, s) => PAGES.neu.mount(b, s), unmount: (b, s) => PAGES.neu.unmount(b, s) },
    'pve-console': { mount: (b, s) => PAGES.console.mount(b, s), unmount: (b, s) => PAGES.console.unmount(b, s) }, 'pve-res': { mount: (b, s) => PAGES.res.mount(b, s), unmount: (b, s) => PAGES.res.unmount(b, s) }, 'pve-net': { mount: (b, s) => PAGES.net.mount(b, s), unmount: (b, s) => PAGES.net.unmount(b, s) },
    'pve-opt': { mount: (b, s) => PAGES.opt.mount(b, s), unmount: (b, s) => PAGES.opt.unmount(b, s) }, 'pve-sum': { mount: (b, s) => PAGES.sum.mount(b, s), unmount: (b, s) => PAGES.sum.unmount(b, s) } },
  decorateItem: (elm, s) => { const n = NODE.get(s.id); if (!n) return; sdot(elm, n.online ? 'ok' : 'bad', n.online ? `Online · ${n.running}/${n.total} guests running` : 'Unreachable: ' + (n.err || '')); },
});

// ---- add-on for plain SSH servers: "this server is a VM / container of a Proxmox node" -> Console tab ----
Mod.serverExtension({
  id: 'pve', label: 'Proxmox',
  renderForm(box, ext) {
    const root = el('div', 'pv-form ext'); box.append(root);
    const row = el('label', 'chk wide'), chk = el('input'); chk.type = 'checkbox'; chk.checked = !!ext; row.append(chk, document.createTextNode(' This server is a VM or container on a Proxmox node (adds a Console tab)'));
    const more = el('div', 'pv-form wide'); more.hidden = !ext;
    const sel = el('select'), kind = el('select'), id = el('input'); kind.append(new Option('Virtual machine (VNC console)', 'qemu'), new Option('LXC container (terminal)', 'lxc')); kind.value = (ext && ext.kind) || 'qemu'; id.type = 'number'; id.min = 1; id.placeholder = '100'; id.value = ext ? ext.vmid : '';
    const l1 = el('label', '', 'Proxmox node '), l2 = el('label', '', 'Type '), l3 = el('label', '', 'VMID '); l1.append(sel); l2.append(kind); l3.append(id); more.append(l1, l2, l3);
    root.append(row, more); chk.onchange = () => { more.hidden = !chk.checked; };
    Mod.call('nodes').then((list) => { sel.innerHTML = ''; list.forEach((n) => sel.append(new Option(`${n.name} (${n.node})`, n.id))); if (!list.length) sel.append(new Option('No Proxmox node added yet', '')); if (ext) sel.value = ext.nodeId; }).catch(() => {});
    return { values() { if (!chk.checked) return {}; if (!sel.value) { Mod.toast('Add the Proxmox node as a server first (type: Proxmox Node)'); return null; } if (!(+id.value > 0)) { Mod.toast('Enter the VMID'); return null; } return { nodeId: sel.value, kind: kind.value, vmid: +id.value }; } };
  },
  tabs: (s) => (s.ext && s.ext.pve ? [{ id: 'pve-console', label: 'Console', icon: 'terminal' }] : []),
  pages: { 'pve-console': { mount: (b, s) => PAGES.console.mount(b, s), unmount: (b, s) => PAGES.console.unmount(b, s) } },
  decorateItem: (elm, s) => { const p = s.ext.pve, n = NODE.get(p.nodeId); if (!n) return; const st = n.guests.get(p.vmid); if (!n.online) sdot(elm, 'bad', 'Proxmox node unreachable'); else if (st) sdot(elm, dotCls(st), `${KIND[p.kind] || ''} ${p.vmid}: ${st}`); },
});

// ---- small popup menu ----
function popMenu(anchor, items) {
  document.querySelectorAll('.pv-menu').forEach((m) => m.remove());
  const m = el('div', 'pv-menu'); const r = anchor.getBoundingClientRect();
  for (const it of items) { if (!it) continue; if (it === '-') { m.append(el('hr')); continue; } const b = el('button', it.danger ? 'danger' : '', it.label); b.type = 'button'; b.disabled = !!it.disabled; b.onclick = () => { m.remove(); it.run(); }; m.append(b); }
  document.body.append(m); m.style.left = Math.max(4, Math.min(innerWidth - m.offsetWidth - 4, r.right - m.offsetWidth)) + 'px'; m.style.top = Math.min(innerHeight - m.offsetHeight - 4, r.bottom + 2) + 'px';
  const off = (e) => { if (!m.contains(e.target)) { m.remove(); document.removeEventListener('mousedown', off, true); } }; setTimeout(() => document.addEventListener('mousedown', off, true), 0);
}

// ---- power / lifecycle actions on a guest ----
async function guestAction(nodeId, g, op, after) {
  const name = g.name || g.vmid, kind = g.type || g.kind, L = { start: 'Start', shutdown: 'Shut down', stop: 'Force stop', reboot: 'Reboot', reset: 'Reset', suspend: 'Suspend', resume: 'Resume' };
  if ((op === 'stop' || op === 'reset') && !(await guard(`${L[op]} ${name}? ${op === 'stop' ? 'This is like pulling the power cord: unsaved data in the guest can be lost.' : 'This is a hard reset without shutting the guest down.'}`))) return;
  try { const upid = await P(nodeId, 'POST', `/${kind}/${g.vmid}/status/${op}`); runTask(nodeId, upid, `${L[op]} ${name}`, after); if (after) setTimeout(after, 600); } catch (e) { fail(e); }
}
async function deleteGuest(nodeId, g, after) {
  const name = g.name || g.vmid, kind = g.type || g.kind;
  if (!(await ask('Delete ' + name + '?', `This permanently destroys ${KIND[kind]} ${g.vmid} (${name}) and its disks. It must be stopped first.`, 'Delete', true))) return;
  try { const upid = await P(nodeId, 'DELETE', `/${kind}/${g.vmid}`, { purge: 1, 'destroy-unreferenced-disks': 1 }); runTask(nodeId, upid, 'Delete ' + name, after); } catch (e) { fail(e); }
}
// the guest's address, for "add to server list" (agent / container interfaces)
async function guestIp(nodeId, kind, vmid) {
  try {
    if (kind === 'lxc') { const l = await P(nodeId, 'GET', `/lxc/${vmid}/interfaces`); for (const i of l || []) if (i.name !== 'lo' && i.inet) return String(i.inet).split('/')[0]; }
    else { const r = await P(nodeId, 'GET', `/qemu/${vmid}/agent/network-get-interfaces`); for (const i of (r && r.result) || []) { if (/^lo/.test(i.name)) continue; for (const a of i['ip-addresses'] || []) if (a['ip-address-type'] === 'ipv4' && !/^169\.254\./.test(a['ip-address'])) return a['ip-address']; } }
  } catch {}
  return '';
}
async function addToServers(nodeSrv, g, ipHint) {
  const nodeId = nodeSrv.id; const host0 = ipHint || await guestIp(nodeId, g.type || g.kind, g.vmid);
  modal('Add to your server list', (b, close) => {
    b.append(el('p', 'pv-help', 'Adds an SSH server for this guest to the sidebar. It gets a Console tab that opens this guest\'s console. Set its SSH login afterwards with Edit.'));
    const form = el('div', 'pv-form'); b.append(form);
    const mk = (t, v, ph) => { const l = el('label', '', t + ' '), i = el('input'); i.value = v || ''; i.placeholder = ph || ''; l.append(i); form.append(l); return i; };
    const name = mk('Name', g.name || `${KIND[g.type || g.kind]} ${g.vmid}`), host = mk('Address (host or IP)', host0, 'e.g. 192.168.1.50'), user = mk('SSH user', 'root'), group = mk('Group', nodeSrv.group || '');
    if (!host0) form.append(el('div', 'pv-help wide', 'No address found (a VM needs the QEMU guest agent running; a container must be started). Type one in.'));
    const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), mkBtn('Add', 'primary', async () => {
      if (!host.value.trim()) return Mod.toast('Enter the address');
      try { const res = await Mod.call('addServer', { nodeId, name: name.value.trim(), host: host.value.trim(), vmid: g.vmid, kind: g.type || g.kind, group: group.value.trim(), username: user.value.trim() || 'root' }); await Mod.refreshData(['servers']); Mod.toast(res.existed ? 'That guest is already in your list' : 'Added to your server list'); close(); } catch (e) { fail(e); }
    })); b.append(r);
  });
}

// ================= Mgmt =================
PAGES.mgmt = page((root, s, ctl) => {
  const nodeId = s.id; let ov = null, q = lsGet('q', ''), kf = lsGet('kf', ''), sf = lsGet('sf', ''), err = '';
  const card = el('div', 'pv-card pv-node'), tools = el('div', 'pv-tools'), list = el('div', 'pv-list'), tasksBox = el('div', 'pv-tasks');
  root.append(card, tools, list, tasksBox);
  const filter = el('input'); filter.placeholder = 'Filter guests…'; filter.value = q; filter.oninput = () => { q = filter.value.toLowerCase(); lsSet('q', q); rows(); };
  const kind = el('select'); kind.append(new Option('VMs and containers', ''), new Option('Virtual machines', 'qemu'), new Option('Containers', 'lxc')); kind.value = kf; kind.onchange = () => { kf = kind.value; lsSet('kf', kf); rows(); };
  const stat = el('select'); stat.append(new Option('Any state', ''), new Option('Running', 'running'), new Option('Stopped', 'stopped')); stat.value = sf; stat.onchange = () => { sf = stat.value; lsSet('sf', sf); rows(); };
  tools.append(filter, kind, stat, el('span', 'pv-grow'), mkBtn('Upload ISO…', '', () => uploadDialog(nodeId)), mkBtn('New VM / container', 'primary', () => Mod.selectTab('pve-new')), mkBtn('↻', '', () => load(), 'Refresh'));
  q = q.toLowerCase();
  function head() {
    card.innerHTML = ''; const st = ov && ov.status;
    const top = el('div', 'pv-nhead'); top.append(dot(ov ? 'online' : err ? 'bad' : 'unknown'), el('b', '', s.pveNode || s.name), el('span', 'pv-mut', st ? `Proxmox VE ${String(st.pveversion || '').replace(/^pve-manager\//, '').split('/')[0]} · kernel ${String(st.kversion || '').split(' ')[1] || ''}` : err ? '' : 'Connecting…'));
    top.append(el('span', 'pv-grow'), mkBtn('Open node shell', '', () => { selectGuest(s, null, 'term'); }, 'The Terminal tab is this node\'s root shell'));
    card.append(top);
    if (err) card.append(note(err, 'bad'));
    if (st) { const g = el('div', 'pv-gauges');
      const mk = (t, f, sub) => { const d = el('div', 'pv-gauge'); d.append(el('span', 'pv-mut', t), bar(f, sub)); g.append(d); };
      mk('CPU', st.cpu, `${fp(st.cpu)} of ${st.cpuinfo ? st.cpuinfo.cpus : '?'} CPUs`); mk('Memory', st.memory.used / st.memory.total, `${fb(st.memory.used)} / ${fb(st.memory.total)}`);
      if (st.swap && st.swap.total) mk('Swap', st.swap.used / st.swap.total, `${fb(st.swap.used)} / ${fb(st.swap.total)}`); mk('Disk', st.rootfs.used / st.rootfs.total, `${fb(st.rootfs.used)} / ${fb(st.rootfs.total)}`);
      const u = el('div', 'pv-gauge'); u.append(el('span', 'pv-mut', 'Uptime'), el('b', '', fup(st.uptime))); g.append(u); card.append(g); }
  }
  function rows() {
    list.innerHTML = '';
    if (!ov) { list.append(note(err ? '' : 'Loading…')); return; }
    const sel = stOf(nodeId).guest;
    const gs = ov.guests.filter((g) => (!kf || g.type === kf) && (!sf || (sf === 'running' ? g.status === 'running' : g.status !== 'running')) && (!q || `${g.vmid} ${g.name || ''} ${g.tags || ''}`.toLowerCase().includes(q))).sort((a, b) => a.vmid - b.vmid);
    const run = ov.guests.filter((g) => g.status === 'running').length;
    list.append(el('div', 'pv-sum', `${ov.guests.length} guests · ${run} running · ${ov.guests.length - run} stopped`));
    if (!gs.length) { list.append(note(ov.guests.length ? 'No guest matches the filter.' : 'No VMs or containers on this node yet. Use "New VM / container".')); return; }
    const t = el('div', 'pv-table');
    const hd = el('div', 'pv-tr pv-th'); ['', 'ID', 'Name', 'Type', 'CPU', 'Memory', 'Uptime', ''].forEach((c) => hd.append(el('span', '', c))); t.append(hd);
    for (const g of gs) {
      const r = el('div', 'pv-tr' + (sel && sel.vmid === g.vmid ? ' sel' : '')), isRun = g.status === 'running';
      const nm = el('span', 'pv-nm'); nm.append(el('b', '', g.name || '(unnamed)')); if (g.template) nm.append(el('em', 'pv-chip', 'template')); if (g.lock) nm.append(el('em', 'pv-chip warn', 'locked: ' + g.lock)); if (g.tags) String(g.tags).split(/[;,]/).filter(Boolean).forEach((x) => nm.append(el('em', 'pv-chip', x)));
      const cpu = el('span', '', isRun ? fp(g.cpu) + (g.maxcpu ? ` of ${g.maxcpu}` : '') : '–'), mem = el('span'); if (isRun) mem.append(bar(g.mem / g.maxmem, `${fb(g.mem)} / ${fb(g.maxmem)}`)); else mem.textContent = g.maxmem ? fb(g.maxmem) : '–';
      const acts = el('span', 'pv-acts');
      if (!g.template) {
        if (!isRun) acts.append(mkBtn('▶', 'pv-ib', (e) => { e.stopPropagation(); guestAction(nodeId, g, 'start', load); }, 'Start'));
        else acts.append(mkBtn('■', 'pv-ib', (e) => { e.stopPropagation(); guestAction(nodeId, g, 'shutdown', load); }, 'Shut down'), mkBtn('↻', 'pv-ib', (e) => { e.stopPropagation(); guestAction(nodeId, g, 'reboot', load); }, 'Reboot'));
        if (isRun) acts.append(mkBtn('>_', 'pv-ib', (e) => { e.stopPropagation(); selectGuest(s, g, 'pve-console'); }, 'Open console'));
      }
      const more = mkBtn('⋯', 'pv-ib', (e) => { e.stopPropagation(); popMenu(more, [
        { label: 'Summary', run: () => selectGuest(s, g, 'pve-sum') }, { label: 'Console', run: () => selectGuest(s, g, 'pve-console'), disabled: !isRun }, '-',
        { label: 'Start', run: () => guestAction(nodeId, g, 'start', load), disabled: isRun || g.template }, { label: 'Shut down', run: () => guestAction(nodeId, g, 'shutdown', load), disabled: !isRun },
        { label: 'Reboot', run: () => guestAction(nodeId, g, 'reboot', load), disabled: !isRun }, { label: 'Force stop', run: () => guestAction(nodeId, g, 'stop', load), disabled: !isRun, danger: true },
        g.type === 'qemu' ? { label: 'Hard reset', run: () => guestAction(nodeId, g, 'reset', load), disabled: !isRun, danger: true } : null,
        g.type === 'qemu' ? { label: g.status === 'paused' ? 'Resume' : 'Suspend (pause)', run: () => guestAction(nodeId, g, g.status === 'paused' ? 'resume' : 'suspend', load), disabled: !isRun && g.status !== 'paused' } : null, '-',
        { label: 'Add to my server list…', run: () => addToServers(s, g) }, { label: 'Delete…', run: () => deleteGuest(nodeId, g, load), danger: true, disabled: isRun }]); }, 'More');
      acts.append(more);
      r.append(dot(g.status), el('span', 'pv-mut', String(g.vmid)), nm, el('span', '', KIND[g.type] || g.type), cpu, mem, el('span', '', isRun ? fup(g.uptime) : g.status === 'paused' ? 'paused' : '–'), acts);
      r.onclick = () => selectGuest(s, g, 'pve-sum'); r.ondblclick = () => { if (isRun) selectGuest(s, g, 'pve-console'); };
      t.append(r);
    }
    list.append(t);
  }
  async function load() { try { ov = await Mod.call('overview', { id: nodeId }); err = ''; } catch (e) { err = errText(e); } head(); rows(); }
  async function tasks() {
    let l = []; try { l = await P(nodeId, 'GET', '/tasks', { limit: 20 }); } catch { return; }
    tasksBox.innerHTML = ''; tasksBox.append(el('div', 'pv-h', 'Recent tasks'));
    const t = el('div', 'pv-table tasks'); for (const k of l) {
      const r = el('div', 'pv-tr'), ok = k.status === 'OK', run = !k.endtime;
      r.append(el('span', 'pv-mut', ftime(k.starttime)), el('span', '', `${k.type}${k.id ? ' ' + k.id : ''}`), el('span', 'pv-mut', k.user), el('span', run ? 'pv-run' : ok ? 'pv-okc' : String(k.status || '').startsWith('WARN') ? 'pv-warnc' : 'pv-badc', run ? 'running…' : k.status || ''));
      r.onclick = () => showLog(nodeId, k.upid, `${k.type} ${k.id || ''}`); t.append(r);
    } tasksBox.append(t);
  }
  ctl.every(load, ivl); ctl.every(tasks, 10000);
});

// ================= Monitor =================
PAGES.mon = page((root, s, ctl) => {
  const nodeId = s.id; let tf = lsGet('tf', 'hour');
  const bar0 = el('div', 'pv-tools'), tiles = el('div', 'pv-tiles'), charts = el('div', 'pv-charts'), storBox = el('div', 'pv-card'), gBox = el('div', 'pv-card');
  const tfSel = el('select'); [['hour', 'Last hour'], ['day', 'Last day'], ['week', 'Last week'], ['month', 'Last month']].forEach(([v, l]) => tfSel.append(new Option(l, v))); tfSel.value = tf; tfSel.onchange = () => { tf = tfSel.value; lsSet('tf', tf); rrd(); };
  bar0.append(el('b', '', 'Resource monitor'), el('span', 'pv-grow'), tfSel, mkBtn('↻', '', () => { live(); rrd(); }, 'Refresh'));
  const cCpu = lineChart({ title: 'CPU', fmt: (v) => fp(v), max: 1 }), cMem = lineChart({ title: 'Memory', fmt: fb }), cNet = lineChart({ title: 'Network traffic', fmt: fr }), cLoad = lineChart({ title: 'Load average', fmt: (v) => v.toFixed(2) });
  charts.append(cCpu, cMem, cNet, cLoad); root.append(bar0, tiles, charts, storBox, gBox);
  function tile(t, big, f, sub) { const d = el('div', 'pv-tile'); d.append(el('span', 'pv-mut', t), el('b', 'pv-big', big)); if (f != null) d.append(bar(f)); if (sub) d.append(el('small', 'pv-mut', sub)); tiles.append(d); }
  async function live() {
    let o; try { o = await Mod.call('overview', { id: nodeId }); } catch (e) { tiles.innerHTML = ''; tiles.append(note(errText(e), 'bad')); return; }
    const st = o.status; tiles.innerHTML = '';
    tile('CPU', fp(st.cpu), st.cpu, `${st.cpuinfo ? st.cpuinfo.cpus + ' cores · ' + String(st.cpuinfo.model || '').replace(/\(R\)|\(TM\)/g, '') : ''}`);
    tile('Memory', fp(st.memory.used / st.memory.total), st.memory.used / st.memory.total, `${fb(st.memory.used)} of ${fb(st.memory.total)}`);
    if (st.swap && st.swap.total) tile('Swap', fp(st.swap.used / st.swap.total), st.swap.used / st.swap.total, `${fb(st.swap.used)} of ${fb(st.swap.total)}`);
    tile('Root disk', fp(st.rootfs.used / st.rootfs.total), st.rootfs.used / st.rootfs.total, `${fb(st.rootfs.used)} of ${fb(st.rootfs.total)}`);
    tile('IO delay', fp(st.wait), null, ''); tile('Load', (st.loadavg || []).map((x) => (+x).toFixed(2)).join('  '), null, '1 / 5 / 15 min'); tile('Uptime', fup(st.uptime), null, `PVE ${String(st.pveversion || '').replace(/^pve-manager\//, '').split('/')[0]}`);
    storBox.innerHTML = ''; storBox.append(el('div', 'pv-h', 'Storage'));
    const sg = el('div', 'pv-gridc'); for (const x of o.stores.sort((a, b) => String(a.storage).localeCompare(b.storage))) {
      const active = x.status ? x.status === 'available' : x.active !== 0, d = el('div', 'pv-store'), t = el('div', 'pv-srow'); t.append(dot(active ? 'online' : 'offline'), el('b', '', x.storage), el('span', 'pv-mut', `${x.plugintype || x.type || ''} · ${x.content || ''}`));
      d.append(t); if (x.maxdisk || x.total) { const tot = x.maxdisk || x.total, used = x.disk != null ? x.disk : x.used; d.append(bar(used / tot, `${fb(used)} / ${fb(tot)}`)); } sg.append(d); } storBox.append(sg);
    gBox.innerHTML = ''; const run = o.guests.filter((g) => g.status === 'running').length; gBox.append(el('div', 'pv-h', `Guests: ${run} running of ${o.guests.length}`));
    const gg = el('div', 'pv-dots'); for (const g of o.guests.sort((a, b) => a.vmid - b.vmid)) {
      const c = el('button', 'pv-gdot'); c.type = 'button'; c.append(dot(g.status), el('span', '', `${g.vmid} ${g.name || ''}`)); if (g.status === 'running') c.append(el('small', 'pv-mut', `${fp(g.cpu)} · ${fb(g.mem)}`));
      c.title = `${KIND[g.type]} ${g.vmid} · ${g.status}`; c.onclick = () => selectGuest(s, g, 'pve-sum'); gg.append(c);
    } gBox.append(gg);
  }
  async function rrd() {
    let d; try { d = await P(nodeId, 'GET', '/rrddata', { timeframe: tf, cf: 'AVERAGE' }); } catch { return; }
    const ser = (f) => d.map((p) => [p.time, p[f] == null ? null : +p[f]]);
    cCpu.update([{ label: 'CPU', data: ser('cpu') }, { label: 'IO delay', data: ser('iowait') }]); cMem.update([{ label: 'Used', data: ser('memused') }, { label: 'Total', data: ser('memtotal') }]);
    cNet.update([{ label: 'In', data: ser('netin') }, { label: 'Out', data: ser('netout') }]); cLoad.update([{ label: 'Load', data: ser('loadavg') }]);
  }
  ctl.every(live, ivl); ctl.every(rrd, 30000);
});

// ================= ISO / template upload =================
const upSubs = new Set(); Mod.on('upload', (e) => upSubs.forEach((f) => f(e)));
async function contentStores(nodeId, content) {
  const l = await P(nodeId, 'GET', '/storage', { content }); return (l || []).filter((x) => x.active !== 0 && x.enabled !== 0).sort((a, b) => String(a.storage).localeCompare(b.storage));
}
function uploadDialog(nodeId, onDone) {
  let busy = false, onUp = null;
  modal('Upload to this node', (b, close) => {
    let kind = 'iso', picked = null;
    const form = el('div', 'pv-form'); b.append(form);
    const lk = el('label', '', 'What '), ksel = el('select'); ksel.append(new Option('ISO image (VM installer)', 'iso'), new Option('Container template (.tar.zst, .tar.gz)', 'vztmpl')); lk.append(ksel);
    const ls = el('label', '', 'Storage '), ssel = el('select'); ls.append(ssel);
    const lf = el('label', 'wide', 'File '), frow = el('div', 'pv-certrow'), fname = el('input'); fname.readOnly = true; fname.placeholder = 'No file chosen'; frow.append(fname, mkBtn('Choose file…', '', async () => { try { const f = await Mod.call('pickIso'); if (f) { picked = f; fname.value = `${f.name}  (${fb(f.size)})`; } } catch (e) { fail(e); } })); lf.append(frow);
    form.append(lk, ls, lf);
    const prog = el('div', 'pv-prog'), pb = bar(0, '', false), pt = el('small', 'pv-mut'); prog.append(pb, pt); prog.hidden = true;
    const have = el('div', 'pv-have'); b.append(prog, have);
    const go = mkBtn('Upload', 'primary', async () => {
      if (!picked) return Mod.toast('Choose a file first'); if (!ssel.value) return Mod.toast('Choose a storage');
      busy = true; go.disabled = true; prog.hidden = false; cancel.textContent = 'Cancel upload'; let t0 = Date.now();
      onUp = (e) => { if (e.id !== nodeId) return; const f = e.total ? e.sent / e.total : 0; pb.firstChild.style.width = (f * 100).toFixed(1) + '%'; const sp = e.sent / Math.max(1, (Date.now() - t0) / 1000); pt.textContent = `${fb(e.sent)} of ${fb(e.total)} · ${fr(sp)}${e.total > e.sent ? ' · about ' + fup((e.total - e.sent) / Math.max(1, sp)) + ' left' : ''}`; }; upSubs.add(onUp);
      try { const upid = await Mod.call('uploadFile', { id: nodeId, storage: ssel.value, filePath: picked.path, content: kind, name: picked.name }); pt.textContent = 'Uploaded. Finishing on the node…'; const st = await waitTask(nodeId, upid); Mod.toast(st.exitstatus === 'OK' ? 'Upload finished' : 'Upload task: ' + st.exitstatus); picked = null; fname.value = ''; pb.firstChild.style.width = '0'; prog.hidden = true; list(); if (onDone) onDone(); }
      catch (e) { fail(e); pt.textContent = errText(e); } finally { busy = false; upSubs.delete(onUp); go.disabled = false; cancel.textContent = 'Close'; }
    });
    const cancel = mkBtn('Close', '', () => { if (busy) Mod.call('cancelUpload').catch(() => {}); else close(); });
    const r = el('div', 'pv-row end'); r.append(cancel, go); b.append(r);
    async function stores() { try { const l = await contentStores(nodeId, kind); ssel.innerHTML = ''; l.forEach((x) => ssel.append(new Option(`${x.storage}  (${fb(x.avail)} free)`, x.storage))); if (!l.length) ssel.append(new Option(`No storage on this node allows ${kind === 'iso' ? 'ISO images' : 'templates'}`, '')); list(); } catch (e) { fail(e); } }
    async function list() {
      have.innerHTML = ''; if (!ssel.value) return; let l = []; try { l = await P(nodeId, 'GET', `/storage/${encodeURIComponent(ssel.value)}/content`, { content: kind }); } catch { return; }
      have.append(el('div', 'pv-h', `Already on ${ssel.value}`)); if (!l.length) have.append(note('Nothing yet.'));
      for (const x of l.sort((a, c) => a.volid.localeCompare(c.volid))) { const r2 = el('div', 'pv-tr'); r2.append(el('span', '', x.volid.split('/').pop()), el('span', 'pv-mut', fb(x.size)), mkBtn('Delete', 'pv-ib danger', async () => { if (!(await ask('Delete file?', `Delete ${x.volid} from the node?`, 'Delete', true))) return; try { await P(nodeId, 'DELETE', `/storage/${encodeURIComponent(ssel.value)}/content/${encodeURIComponent(x.volid)}`); list(); } catch (e) { fail(e); } })); have.append(r2); }
    }
    ksel.onchange = () => { kind = ksel.value; stores(); }; ssel.onchange = list; stores();
  }, { wide: true, sticky: true, onClose: () => { upSubs.delete(onUp); if (busy) Mod.call('cancelUpload').catch(() => {}); } });
}

// ================= New VM / container (wizard) =================
const WIZ = new Map();   // node server id -> { kind, step, v, done }
const hostOk = /^[A-Za-z0-9]([A-Za-z0-9.-]{0,60}[A-Za-z0-9])?$/;
function wizDefaults(kind, D) {
  const base = { vmid: D.nextid, pool: '', onboot: false, start: false, bridge: D.bridges[0] || 'vmbr0', vlan: '', fw: true, addServer: true, sshUser: 'root' };
  return kind === 'qemu'
    ? { ...base, name: '', ostype: 'l26', isoSrc: 'iso', iso: '', bios: 'seabios', machine: 'i440fx', scsihw: 'virtio-scsi-single', agent: true, tpm: false, bus: 'scsi', diskStorage: '', diskSize: 32, discard: true, ssd: true, iothread: true, sockets: 1, cores: 2, cpuType: 'x86-64-v2-AES', memory: 2048, balloon: true, model: 'virtio' }
    : { ...base, hostname: '', unprivileged: true, nesting: false, password: '', sshkeys: '', template: '', rootStorage: '', rootSize: 8, cores: 1, memory: 512, swap: 512, ipMode: 'dhcp', ip: '', gw: '', dns: '', domain: '' };
}
async function wizLoad(nodeId) {
  const D = { nextid: 100, stores: [], isos: [], tmpls: [], bridges: [], pools: [] };
  const [nid, st, br, pl] = await Promise.all([PC(nodeId, 'GET', '/cluster/nextid').catch(() => 100), P(nodeId, 'GET', '/storage').catch(() => []), P(nodeId, 'GET', '/network', { type: 'any_bridge' }).catch(() => []), PC(nodeId, 'GET', '/pools').catch(() => [])]);
  D.nextid = +nid || 100; D.stores = (st || []).filter((x) => x.active !== 0 && x.enabled !== 0); D.bridges = (br || []).map((x) => x.iface).sort(); D.pools = (pl || []).map((x) => x.poolid);
  const kinds = (x) => String(x.content || '').split(',');
  await Promise.all(D.stores.map(async (x) => {
    if (kinds(x).includes('iso')) (await P(nodeId, 'GET', `/storage/${encodeURIComponent(x.storage)}/content`, { content: 'iso' }).catch(() => [])).forEach((c) => D.isos.push(c));
    if (kinds(x).includes('vztmpl')) (await P(nodeId, 'GET', `/storage/${encodeURIComponent(x.storage)}/content`, { content: 'vztmpl' }).catch(() => [])).forEach((c) => D.tmpls.push(c));
  }));
  D.isos.sort((a, b) => a.volid.localeCompare(b.volid)); D.tmpls.sort((a, b) => a.volid.localeCompare(b.volid));
  return D;
}
function wizParams(kind, v, D) {
  const p = { vmid: +v.vmid };
  if (v.pool) p.pool = v.pool; if (v.onboot) p.onboot = 1; if (v.start) p.start = 1;
  const nic = (extra) => extra + `,bridge=${v.bridge}` + (v.vlan ? `,tag=${v.vlan}` : '') + (v.fw ? ',firewall=1' : '');
  if (kind === 'qemu') {
    Object.assign(p, { name: v.name, ostype: v.ostype, bios: v.bios, scsihw: v.scsihw, agent: v.agent ? 1 : 0, sockets: +v.sockets, cores: +v.cores, cpu: v.cpuType, memory: +v.memory, net0: nic(v.model) });
    if (v.machine === 'q35') p.machine = 'q35'; if (!v.balloon) p.balloon = 0;
    const opt = [v.discard ? 'discard=on' : '', v.ssd && (v.bus === 'scsi' || v.bus === 'sata') ? 'ssd=1' : '', v.iothread && (v.bus === 'virtio' || v.scsihw === 'virtio-scsi-single' && v.bus === 'scsi') ? 'iothread=1' : ''].filter(Boolean);
    p[v.bus + '0'] = `${v.diskStorage}:${+v.diskSize}` + (opt.length ? ',' + opt.join(',') : '');
    p.ide2 = v.iso ? `${v.iso},media=cdrom` : 'none,media=cdrom';
    if (v.bios === 'ovmf') p.efidisk0 = `${v.diskStorage}:1,efitype=4m,pre-enrolled-keys=1`; if (v.tpm) p.tpmstate0 = `${v.diskStorage}:1,version=v2.0`;
    p.boot = `order=${v.bus}0;ide2;net0`;
  } else {
    Object.assign(p, { hostname: v.hostname, ostemplate: v.template, unprivileged: v.unprivileged ? 1 : 0, rootfs: `${v.rootStorage}:${+v.rootSize}`, cores: +v.cores, memory: +v.memory, swap: +v.swap });
    if (v.password) p.password = v.password; if (v.sshkeys.trim()) p['ssh-public-keys'] = v.sshkeys.trim(); if (v.nesting) p.features = 'nesting=1'; if (v.dns) p.nameserver = v.dns; if (v.domain) p.searchdomain = v.domain;
    p.net0 = nic('name=eth0') + (v.ipMode === 'dhcp' ? ',ip=dhcp' : v.ipMode === 'static' ? `,ip=${v.ip}` + (v.gw ? `,gw=${v.gw}` : '') : ',ip=manual');
  }
  return p;
}
PAGES.neu = page((root, s, ctl) => {
  const nodeId = s.id; root.append(note('Loading what this node offers…'));
  wizLoad(nodeId).then((D) => { if (ctl.alive) wizard(root, s, ctl, D); }).catch((e) => { root.innerHTML = ''; root.append(note(errText(e), 'bad')); });
});
function wizard(root, s, ctl, D) {
  const nodeId = s.id; let W = WIZ.get(nodeId); if (!W) WIZ.set(nodeId, W = { kind: '', step: 0, v: null, maxStep: 0 });
  root.innerHTML = '';
  const wrap = el('div', 'pv-wiz'), side = el('div', 'pv-steps'), main = el('div', 'pv-wmain'); wrap.append(side, main); root.append(wrap);
  const storesFor = (c) => D.stores.filter((x) => String(x.content || '').split(',').includes(c));
  const STEPS = () => (W.kind === 'qemu' ? ['General', 'OS', 'System', 'Disks', 'CPU', 'Memory', 'Network', 'Confirm'] : ['General', 'Template', 'Disks', 'CPU', 'Memory', 'Network', 'DNS', 'Confirm']);
  function draw() {
    side.innerHTML = '';
    if (!W.kind) { main.innerHTML = ''; chooser(); return; }
    STEPS().forEach((t, i) => { const b = el('button', 'pv-step' + (i === W.step ? ' on' : '') + (i <= W.maxStep ? ' vis' : ''), `${i + 1}. ${t}`); b.type = 'button'; b.disabled = i > W.maxStep; b.onclick = () => { W.step = i; draw(); }; side.append(b); });
    side.append(mkBtn('Start over', 'pv-ib', () => { W.kind = ''; W.v = null; W.step = 0; W.maxStep = 0; draw(); }));
    main.innerHTML = ''; const t = STEPS()[W.step]; main.append(el('h3', '', `${W.kind === 'qemu' ? 'Create: Virtual Machine' : 'Create: LXC Container'} · ${t}`));
    const body = el('div', 'pv-form wizform'); main.append(body); STEP[t](body);
    const nav = el('div', 'pv-row end pv-wnav'); const last = W.step === STEPS().length - 1;
    nav.append(mkBtn('Back', '', () => { if (W.step) { W.step--; draw(); } }, ''), last ? mkBtn('Create', 'primary', () => create()) : mkBtn('Next', 'primary', () => { const e = check(t); if (e) return Mod.toast(e); W.step++; W.maxStep = Math.max(W.maxStep, W.step); draw(); }));
    nav.firstChild.disabled = !W.step; main.append(nav);
  }
  function chooser() {
    main.innerHTML = ''; main.append(el('h3', '', 'What do you want to create?'));
    const g = el('div', 'pv-choose');
    const mk = (kind, title, txt) => { const b = el('button', 'pv-big-choice'); b.type = 'button'; b.append(el('b', '', title), el('span', 'pv-mut', txt)); b.onclick = () => { W.kind = kind; W.v = wizDefaults(kind, D); W.step = 0; W.maxStep = 0; draw(); }; g.append(b); };
    mk('qemu', 'Virtual machine', 'A full machine with its own kernel: Windows, Linux, BSD … installed from an ISO image.'); mk('lxc', 'LXC container', 'A light Linux system sharing the node\'s kernel, created from a template. Starts in seconds.');
    main.append(g, el('div', 'pv-help', `Next free ID on the cluster: ${D.nextid}. Uses what this node has: ${D.stores.length} storages, ${D.isos.length} ISO images, ${D.tmpls.length} templates.`));
  }
  // ---- field helpers bound to W.v ----
  const V = () => W.v;
  function field(body, label, key, o = {}) {
    const l = el('label', o.wide ? 'wide' : ''); let c;
    if (o.type === 'check') { l.className += ' chk'; c = el('input'); c.type = 'checkbox'; c.checked = !!V()[key]; c.onchange = () => { V()[key] = c.checked; if (o.redraw) draw(); }; l.append(c, document.createTextNode(' ' + label)); }
    else {
      l.append(document.createTextNode(label + ' '));
      if (o.type === 'select') { c = el('select'); for (const [val, txt] of o.options) c.append(new Option(txt, val)); c.value = V()[key]; if (c.value !== String(V()[key]) && o.options.length) { c.value = o.options[0][0]; V()[key] = c.value; } c.onchange = () => { V()[key] = c.value; if (o.redraw) draw(); }; }
      else if (o.type === 'area') { c = el('textarea'); c.rows = 3; c.value = V()[key] || ''; c.oninput = () => { V()[key] = c.value; }; c.spellcheck = false; }
      else { c = el('input'); c.type = o.type || 'text'; if (o.min != null) c.min = o.min; if (o.max != null) c.max = o.max; c.value = V()[key] == null ? '' : V()[key]; c.placeholder = o.ph || ''; c.autocomplete = 'off'; c.spellcheck = false; c.oninput = () => { V()[key] = c.value; }; }
      l.append(c);
    }
    if (o.help) l.append(el('small', 'pv-help', o.help)); body.append(l); return c;
  }
  const poolField = (body) => { if (D.pools.length) field(body, 'Resource pool', 'pool', { type: 'select', options: [['', '(none)'], ...D.pools.map((x) => [x, x])] }); };
  const stOpts = (c, v, key) => { const l = storesFor(c); if (!V()[key] || !l.some((x) => x.storage === V()[key])) V()[key] = (l.find((x) => x.storage === 'local-lvm') || l[0] || {}).storage || ''; return l.length ? l.map((x) => [x.storage, `${x.storage}  (${fb(x.avail)} free)`]) : [['', 'No storage allows this']]; };
  const STEP = {
    General(b) {
      field(b, 'Node', '_n', { type: 'select', options: [[s.pveNode, s.pveNode]] });
      field(b, 'VM ID', 'vmid', { type: 'number', min: 100, help: `Next free: ${D.nextid}` });
      if (W.kind === 'qemu') field(b, 'Name', 'name', { ph: 'e.g. web01' }); else field(b, 'Hostname', 'hostname', { ph: 'e.g. web01' });
      poolField(b); field(b, 'Start at boot', 'onboot', { type: 'check' });
      if (W.kind === 'lxc') { field(b, 'Unprivileged container (recommended)', 'unprivileged', { type: 'check' }); field(b, 'Nesting (needed to run Docker / LXC inside)', 'nesting', { type: 'check' }); }
    },
    OS(b) {
      const o = [['', 'Do not use any media']]; D.isos.forEach((x) => o.push([x.volid, x.volid.replace(/^[^:]*:iso\//, '') + `  (${x.volid.split(':')[0]}, ${fb(x.size)})`]));
      field(b, 'ISO image', 'iso', { type: 'select', options: o, wide: true }); b.append(mkBtn('Upload an ISO to this node…', '', () => uploadDialog(nodeId, async () => { try { const n = await wizLoad(nodeId); Object.assign(D, n); draw(); } catch {} })));
      field(b, 'Guest OS type', 'ostype', { type: 'select', options: [['l26', 'Linux (6.x - 2.6)'], ['win11', 'Windows 11 / 2022 / 2025'], ['win10', 'Windows 10 / 2016 / 2019'], ['win8', 'Windows 8.x / 2012'], ['win7', 'Windows 7 / 2008 R2'], ['other', 'Other'], ['solaris', 'Solaris']], wide: true });
    },
    Template(b) {
      const o = [['', 'Choose a template…']]; D.tmpls.forEach((x) => o.push([x.volid, x.volid.replace(/^[^:]*:vztmpl\//, '') + `  (${x.volid.split(':')[0]})`]));
      field(b, 'Template', 'template', { type: 'select', options: o, wide: true });
      b.append(mkBtn('Download a template…', '', () => tmplDownload(nodeId, async () => { try { Object.assign(D, await wizLoad(nodeId)); draw(); } catch {} })), mkBtn('Upload a template…', '', () => uploadDialog(nodeId, async () => { try { Object.assign(D, await wizLoad(nodeId)); draw(); } catch {} })));
      field(b, 'Root password', 'password', { type: 'password', help: 'Leave empty if you add an SSH key.' }); field(b, 'SSH public key(s)', 'sshkeys', { type: 'area', wide: true, help: 'One key per line (optional).' });
    },
    System(b) {
      field(b, 'BIOS', 'bios', { type: 'select', options: [['seabios', 'SeaBIOS (default)'], ['ovmf', 'OVMF (UEFI)']], redraw: true }); field(b, 'Machine', 'machine', { type: 'select', options: [['i440fx', 'i440fx (default)'], ['q35', 'q35 (PCIe, recommended for UEFI/Windows 11)']] });
      field(b, 'SCSI controller', 'scsihw', { type: 'select', options: [['virtio-scsi-single', 'VirtIO SCSI single (default)'], ['virtio-scsi-pci', 'VirtIO SCSI'], ['lsi', 'LSI 53C895A'], ['lsi53c810', 'LSI 53C810'], ['megasas', 'MegaRAID SAS'], ['pvscsi', 'VMware PVSCSI']] });
      field(b, 'QEMU guest agent', 'agent', { type: 'check', help: 'Install qemu-guest-agent in the guest: IP addresses and clean shutdown.' }); if (V().bios === 'ovmf') field(b, 'Add TPM 2.0 (Windows 11)', 'tpm', { type: 'check' });
    },
    Disks(b) {
      if (W.kind === 'qemu') {
        field(b, 'Bus', 'bus', { type: 'select', options: [['scsi', 'SCSI (default)'], ['virtio', 'VirtIO Block'], ['sata', 'SATA'], ['ide', 'IDE']], redraw: true });
        field(b, 'Storage', 'diskStorage', { type: 'select', options: stOpts('images', V(), 'diskStorage') }); field(b, 'Disk size (GiB)', 'diskSize', { type: 'number', min: 1 });
        field(b, 'Discard (TRIM)', 'discard', { type: 'check' }); if (V().bus === 'scsi' || V().bus === 'sata') field(b, 'SSD emulation', 'ssd', { type: 'check' }); field(b, 'IO thread', 'iothread', { type: 'check' });
      } else { field(b, 'Storage', 'rootStorage', { type: 'select', options: stOpts('rootdir', V(), 'rootStorage') }); field(b, 'Disk size (GiB)', 'rootSize', { type: 'number', min: 1 }); }
    },
    CPU(b) { if (W.kind === 'qemu') { field(b, 'Sockets', 'sockets', { type: 'number', min: 1 }); field(b, 'Type', 'cpuType', { type: 'select', options: [['x86-64-v2-AES', 'x86-64-v2-AES (default)'], ['x86-64-v3', 'x86-64-v3'], ['host', 'host (best speed, no live migration)'], ['kvm64', 'kvm64'], ['qemu64', 'qemu64']] }); } field(b, 'Cores', 'cores', { type: 'number', min: 1 }); },
    Memory(b) { field(b, 'Memory (MiB)', 'memory', { type: 'number', min: 16 }); if (W.kind === 'qemu') field(b, 'Ballooning device', 'balloon', { type: 'check' }); else field(b, 'Swap (MiB)', 'swap', { type: 'number', min: 0 }); },
    Network(b) {
      field(b, 'Bridge', 'bridge', { type: 'select', options: D.bridges.length ? D.bridges.map((x) => [x, x]) : [['vmbr0', 'vmbr0']] }); field(b, 'VLAN tag', 'vlan', { type: 'number', min: 1, max: 4094, ph: 'none' });
      if (W.kind === 'qemu') field(b, 'Model', 'model', { type: 'select', options: [['virtio', 'VirtIO (paravirtualized)'], ['e1000', 'Intel E1000'], ['rtl8139', 'Realtek RTL8139'], ['vmxnet3', 'VMware vmxnet3']] });
      else { field(b, 'IPv4', 'ipMode', { type: 'select', options: [['dhcp', 'DHCP'], ['static', 'Static'], ['none', 'Manual / none']], redraw: true }); if (V().ipMode === 'static') { field(b, 'IPv4/CIDR', 'ip', { ph: '192.168.1.50/24' }); field(b, 'Gateway', 'gw', { ph: '192.168.1.1' }); } }
      field(b, 'Firewall', 'fw', { type: 'check' });
    },
    DNS(b) { field(b, 'DNS domain', 'domain', { ph: 'use host settings' }); field(b, 'DNS server', 'dns', { ph: 'use host settings' }); },
    Confirm(b) {
      const p = wizParams(W.kind, V(), D), t = el('div', 'pv-table sumt');
      for (const [k, val] of Object.entries(p)) { const r = el('div', 'pv-tr'); r.append(el('span', 'pv-mut', k), el('span', '', k === 'password' ? '••••••' : String(val))); t.append(r); }
      b.append(t);
      field(b, 'Start after created', 'start', { type: 'check', wide: true }); field(b, 'Add to my Connect server list', 'addServer', { type: 'check', wide: true, redraw: true, help: 'Adds an SSH server for the new guest, with a Console tab. Its address is the static IP if you set one, otherwise found once it has started (needs "Start after created").' });
      if (V().addServer) field(b, 'SSH user for the new server', 'sshUser');
    },
  };
  function check(step) {
    const v = V();
    if (step === 'General') { if (!(+v.vmid >= 100)) return 'The VM ID must be 100 or higher'; const n = W.kind === 'qemu' ? v.name : v.hostname; if (!hostOk.test(n || '')) return (W.kind === 'qemu' ? 'Name' : 'Hostname') + ': letters, digits, - and . only'; }
    if (step === 'Template') { if (!v.template) return 'Choose a template (or download one)'; if (!v.password && !v.sshkeys.trim()) return 'Set a root password or an SSH key'; if (v.password && v.password.length < 5) return 'The password needs at least 5 characters'; }
    if (step === 'Disks') { if (!(W.kind === 'qemu' ? v.diskStorage : v.rootStorage)) return 'Choose a storage'; if (!(+(W.kind === 'qemu' ? v.diskSize : v.rootSize) >= 1)) return 'Enter a disk size'; }
    if (step === 'CPU' && !(+v.cores >= 1)) return 'At least 1 core'; if (step === 'Memory' && !(+v.memory >= 16)) return 'Memory is too small';
    if (step === 'Network' && W.kind === 'lxc' && v.ipMode === 'static' && !/^\d+\.\d+\.\d+\.\d+\/\d+$/.test(v.ip)) return 'Enter the address as IP/prefix, e.g. 192.168.1.50/24';
    return '';
  }
  async function create() {
    for (const t of STEPS().slice(0, -1)) { const e = check(t); if (e) { W.step = STEPS().indexOf(t); draw(); return Mod.toast(e); } }
    const v = V(), params = wizParams(W.kind, v, D); main.innerHTML = ''; side.innerHTML = '';
    main.append(el('h3', '', `Creating ${v.name || v.hostname} (${v.vmid})…`)); const pre = el('pre', 'pv-log', ''), msg = el('div', 'pv-help'); main.append(pre, msg);
    try {
      const upid = await P(nodeId, 'POST', '/' + W.kind, params);
      const st = await waitTask(nodeId, upid, (lines) => { pre.textContent += lines.join('\n') + '\n'; pre.scrollTop = pre.scrollHeight; }, ctl);
      if (st.exitstatus !== 'OK') throw new Error(st.exitstatus || 'The task failed');
      msg.textContent = 'Created. ✓'; msg.className = 'pv-help okc';
      const g = { type: W.kind, vmid: +v.vmid, name: v.name || v.hostname };
      if (v.addServer) {
        let host = W.kind === 'lxc' && v.ipMode === 'static' ? v.ip.split('/')[0] : '';
        if (!host && v.start) { msg.textContent = 'Created. Waiting for the new guest to report its address…'; for (let i = 0; i < 40 && !host && ctl.alive; i++) { await new Promise((r) => setTimeout(r, 2500)); host = await guestIp(nodeId, W.kind, v.vmid); } }
        if (!host) host = W.kind === 'lxc' ? v.hostname : '';
        if (host) { const res = await Mod.call('addServer', { nodeId, name: g.name, host, vmid: g.vmid, kind: W.kind, group: s.group || '', username: v.sshUser || 'root' }); await Mod.refreshData(['servers']); msg.textContent = `Created and added to your server list (${host}).`; }
        else msg.textContent = 'Created. It was not added to the server list: no address yet. Use Mgmt > ⋯ > "Add to my server list" once it is running.';
      }
      const r = el('div', 'pv-row'); r.append(mkBtn('Open it', 'primary', () => selectGuest(s, g, 'pve-sum')), mkBtn('Create another', '', () => { W.kind = ''; W.v = null; W.step = 0; W.maxStep = 0; wizLoad(nodeId).then((n) => { Object.assign(D, n); draw(); }); })); main.append(r);
    } catch (e) { msg.textContent = errText(e); msg.className = 'pv-help badc'; const r = el('div', 'pv-row'); r.append(mkBtn('Back to the wizard', '', () => { W.step = STEPS().length - 1; draw(); })); main.append(r); }
  }
  draw();
}
// download a container template from the Proxmox appliance list
function tmplDownload(nodeId, done) {
  modal('Download a container template', (b, close) => {
    const form = el('div', 'pv-form'); b.append(form); const ls = el('label', 'wide', 'Template '), ts = el('select'); ls.append(ts); const lt = el('label', '', 'Store in '), ss = el('select'); lt.append(ss); form.append(ls, lt);
    const out = el('pre', 'pv-log'); out.hidden = true; b.append(out);
    Promise.all([P(nodeId, 'GET', '/aplinfo'), contentStores(nodeId, 'vztmpl')]).then(([l, st]) => { (l || []).sort((a, c) => a.template.localeCompare(c.template)).forEach((x) => ts.append(new Option(`${x.template}  ·  ${x.headline || ''}`, x.template))); st.forEach((x) => ss.append(new Option(x.storage, x.storage))); }).catch(fail);
    const go = mkBtn('Download', 'primary', async () => { if (!ts.value || !ss.value) return; go.disabled = true; out.hidden = false; try { const upid = await P(nodeId, 'POST', '/aplinfo', { storage: ss.value, template: ts.value }); const st = await waitTask(nodeId, upid, (lines) => { out.textContent += lines.join('\n') + '\n'; out.scrollTop = out.scrollHeight; }); if (st.exitstatus === 'OK') { Mod.toast('Template downloaded'); done && done(); close(); } else out.textContent += '\n' + st.exitstatus; } catch (e) { fail(e); } go.disabled = false; });
    const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), go); b.append(r);
  }, { wide: true });
}

// ================= Console =================
// ---- DES (only for the VNC password challenge) ----
const DES = (() => {
  const IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
  const FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25];
  const E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
  const P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
  const PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
  const PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
  const SH = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  const S = [
    [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
    [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
    [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
    [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
    [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
    [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
    [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
    [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
  ];
  const bits = (b) => { const o = []; for (const x of b) for (let i = 7; i >= 0; i--) o.push((x >> i) & 1); return o; };
  const perm = (a, t) => t.map((i) => a[i - 1]);
  function subkeys(key) {
    const k = perm(bits(key), PC1); let c = k.slice(0, 28), d = k.slice(28); const out = [];
    for (const s of SH) { c = c.slice(s).concat(c.slice(0, s)); d = d.slice(s).concat(d.slice(0, s)); out.push(perm(c.concat(d), PC2)); }
    return out;
  }
  function block(b8, ks) {
    const x = perm(bits(b8), IP); let l = x.slice(0, 32), r = x.slice(32);
    for (let n = 0; n < 16; n++) {
      const e = perm(r, E).map((v, i) => v ^ ks[n][i]); const f = [];
      for (let s = 0; s < 8; s++) { const o = s * 6, row = (e[o] << 1) | e[o + 5], col = (e[o + 1] << 3) | (e[o + 2] << 2) | (e[o + 3] << 1) | e[o + 4], v = S[s][row * 16 + col]; f.push((v >> 3) & 1, (v >> 2) & 1, (v >> 1) & 1, v & 1); }
      const pf = perm(f, P), nr = l.map((v, i) => v ^ pf[i]); l = r; r = nr;
    }
    const o = perm(r.concat(l), FP), out = new Uint8Array(8);
    for (let i = 0; i < 64; i++) out[i >> 3] |= o[i] << (7 - (i & 7));
    return out;
  }
  return { encrypt: (key8, data) => { const ks = subkeys(key8), out = new Uint8Array(data.length); for (let i = 0; i < data.length; i += 8) out.set(block(data.subarray(i, i + 8), ks), i); return out; } };
})();
// VNC authentication: the password is the DES key with every byte's bits reversed
function vncAuthResponse(password, challenge) {
  const key = new Uint8Array(8);
  for (let i = 0; i < 8; i++) { let c = i < password.length ? password.charCodeAt(i) & 255 : 0, r = 0; for (let j = 0; j < 8; j++) r |= ((c >> j) & 1) << (7 - j); key[i] = r; }
  return DES.encrypt(key, challenge);
}

// A small RFB (VNC) client: VNC password / no authentication, Raw + CopyRect + Hextile + DesktopSize + Cursor encodings, keyboard, mouse and wheel.
const NEED = { need: true };
class RFB {
  constructor(canvas, send, onEvent, password) {
    this.cv = canvas; this.ctx = canvas.getContext('2d'); this.send = send; this.ev = onEvent; this.pw = password || '';
    this.buf = new Uint8Array(0); this.pos = 0; this.state = 'ver'; this.w = 0; this.h = 0; this.dead = false; this.mask = 0;
  }
  push(d) {
    if (this.dead) return;
    if (this.pos >= this.buf.length) { this.buf = d; this.pos = 0; } else { const n = new Uint8Array(this.buf.length - this.pos + d.length); n.set(this.buf.subarray(this.pos)); n.set(d, this.buf.length - this.pos); this.buf = n; this.pos = 0; }
    try { for (;;) this.step(); } catch (e) { if (e !== NEED) { this.dead = true; this.ev('error', errText(e)); } }
  }
  need(n) { if (this.buf.length - this.pos < n) throw NEED; }
  u8() { return this.buf[this.pos++]; }
  u16() { const v = (this.buf[this.pos] << 8) | this.buf[this.pos + 1]; this.pos += 2; return v; }
  u32() { const v = ((this.buf[this.pos] << 24) | (this.buf[this.pos + 1] << 16) | (this.buf[this.pos + 2] << 8) | this.buf[this.pos + 3]); this.pos += 4; return v; }
  str(n) { const s = new TextDecoder().decode(this.buf.subarray(this.pos, this.pos + n)); this.pos += n; return s; }
  step() {
    const p0 = this.pos;
    try { this['s_' + this.state](); } catch (e) { if (e === NEED && this.state !== 'hextile') this.pos = p0; throw e; }
  }
  s_ver() { this.need(12); const v = this.str(12); if (!/^RFB \d{3}\.\d{3}\n$/.test(v)) throw new Error('This is not a VNC server'); this.minor = +v.slice(8, 11) >= 8 ? 8 : +v.slice(8, 11) >= 7 ? 7 : 3; this.send(new TextEncoder().encode('RFB 003.00' + this.minor + '\n')); this.state = this.minor >= 7 ? 'sec' : 'sec3'; }
  s_sec3() { this.need(4); const t = this.u32(); if (t === 0) throw new Error('The server refused the connection'); this.chooseSec(t); }
  s_sec() {
    this.need(1); const n = this.buf[this.pos]; if (n === 0) { this.need(5); this.pos++; const l = this.u32(); this.need(l); throw new Error(this.str(l) || 'The server refused the connection'); }
    this.need(1 + n); this.pos++; const types = [...this.buf.subarray(this.pos, this.pos + n)]; this.pos += n;
    const t = types.includes(2) ? 2 : types.includes(1) ? 1 : 0; if (!t) throw new Error('No supported VNC login method (server offers ' + types.join(', ') + ')');
    this.send(new Uint8Array([t])); this.chooseSec(t, true);
  }
  chooseSec(t) { if (t === 2) this.state = 'challenge'; else if (t === 1) this.state = this.minor >= 8 ? 'secres' : 'init'; else throw new Error('Unsupported login method'); if (t === 1 && this.minor < 8) this.sendInit(); }
  s_challenge() { this.need(16); const ch = this.buf.slice(this.pos, this.pos + 16); this.pos += 16; this.send(vncAuthResponse(this.pw, ch)); this.state = 'secres'; }
  s_secres() { this.need(4); const r = this.u32(); if (r !== 0) { if (this.minor >= 8 && this.buf.length - this.pos >= 4) { const l = this.u32(); this.need(l); throw new Error(this.str(l) || 'Login failed'); } throw new Error('The VNC login was refused (the one-time ticket expired?)'); } this.sendInit(); }
  sendInit() { this.send(new Uint8Array([1])); this.state = 'init'; }
  s_init() {
    this.need(24); const w = this.u16(), h = this.u16(); this.pos += 16; const l = this.u32(); this.need(l); this.name = this.str(l);
    this.resize(w, h);
    this.send(new Uint8Array([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]));
    const encs = [5, 1, 0, -223, -239], m = new Uint8Array(4 + encs.length * 4), dv = new DataView(m.buffer); m[0] = 2; dv.setUint16(2, encs.length); encs.forEach((e, i) => dv.setInt32(4 + i * 4, e));
    this.send(m); this.request(false); this.state = 'msg'; this.ev('connected', this.name);
  }
  resize(w, h) { this.w = w; this.h = h; this.cv.width = w; this.cv.height = h; this.ev('size', { w, h }); }
  request(inc) { const m = new Uint8Array(10), dv = new DataView(m.buffer); m[0] = 3; m[1] = inc ? 1 : 0; dv.setUint16(6, this.w); dv.setUint16(8, this.h); this.send(m); }
  s_msg() {
    this.need(1); const t = this.buf[this.pos];
    if (t === 0) { this.need(4); this.pos += 2; this.rects = this.u16(); this.state = 'rect'; }
    else if (t === 1) { this.need(6); this.pos++; this.pos += 1; const first = this.u16(), n = this.u16(); void first; this.need(n * 6); this.pos += n * 6; }
    else if (t === 2) { this.pos++; this.ev('bell'); }
    else if (t === 3) { this.need(8); this.pos += 4; const l = this.u32(); this.need(l); const txt = this.str(l); this.ev('clip', txt); }
    else throw new Error('Unknown VNC message ' + t);
  }
  s_rect() {
    if (!this.rects) { this.state = 'msg'; this.request(true); return; }
    this.need(12); const x = this.u16(), y = this.u16(), w = this.u16(), h = this.u16(), enc = this.u32() | 0;
    if (enc === 0) { this.need(w * h * 4); this.raw(x, y, w, h); this.rects--; }
    else if (enc === 1) { this.need(4); const sx = this.u16(), sy = this.u16(); this.ctx.drawImage(this.cv, sx, sy, w, h, x, y, w, h); this.rects--; }
    else if (enc === 5) { this.hx = { x, y, w, h, tx: 0, ty: 0, bg: '#000', fg: '#fff' }; this.state = 'hextile'; this.rects--; }
    else if (enc === -223) { this.resize(w, h); this.rects--; this.request(false); }
    else if (enc === -239) { const mb = Math.ceil(w / 8) * h; this.need(w * h * 4 + mb); this.cursor(x, y, w, h); this.rects--; }
    else throw new Error('The server used a video encoding this viewer does not support (' + enc + ')');
  }
  px(o) { const b = this.buf; return [b[o + 2], b[o + 1], b[o]]; }   // BGRX -> RGB
  raw(x, y, w, h) {
    if (!w || !h) return; const img = this.ctx.createImageData(w, h), d = img.data, b = this.buf; let o = this.pos;
    for (let i = 0, n = w * h; i < n; i++, o += 4) { d[i * 4] = b[o + 2]; d[i * 4 + 1] = b[o + 1]; d[i * 4 + 2] = b[o]; d[i * 4 + 3] = 255; }
    this.pos = o; this.ctx.putImageData(img, x, y);
  }
  cursor(hx, hy, w, h) {
    const mb = Math.ceil(w / 8), c = document.createElement('canvas'); c.width = Math.max(1, w); c.height = Math.max(1, h);
    if (!w || !h) { this.pos += 0; this.ev('cursor', ''); return; }
    const img = c.getContext('2d').createImageData(w, h), b = this.buf; let o = this.pos; const mo = o + w * h * 4;
    for (let yy = 0; yy < h; yy++) for (let xx = 0; xx < w; xx++, o += 4) { const i = (yy * w + xx) * 4, on = (b[mo + yy * mb + (xx >> 3)] >> (7 - (xx & 7))) & 1; img.data[i] = b[o + 2]; img.data[i + 1] = b[o + 1]; img.data[i + 2] = b[o]; img.data[i + 3] = on ? 255 : 0; }
    this.pos = mo + mb * h; c.getContext('2d').putImageData(img, 0, 0); this.ev('cursor', `url(${c.toDataURL()}) ${hx} ${hy}, auto`);
  }
  s_hextile() {
    const H = this.hx, rgb = (c) => `rgb(${c[0]},${c[1]},${c[2]})`;
    for (;;) {
      if (H.ty >= H.h) { this.state = 'rect'; return; }
      const p0 = this.pos, tw = Math.min(16, H.w - H.tx), th = Math.min(16, H.h - H.ty), X = H.x + H.tx, Y = H.y + H.ty;
      try {
        this.need(1); const f = this.u8();
        if (f & 1) { this.need(tw * th * 4); this.raw(X, Y, tw, th); }
        else {
          if (f & 2) { this.need(4); H.bg = rgb(this.px(this.pos)); this.pos += 4; }
          if (f & 4) { this.need(4); H.fg = rgb(this.px(this.pos)); this.pos += 4; }
          this.ctx.fillStyle = H.bg; this.ctx.fillRect(X, Y, tw, th);
          if (f & 8) {
            this.need(1); const n = this.u8(), col = !!(f & 16); this.need(n * (col ? 6 : 2));
            for (let i = 0; i < n; i++) { if (col) { this.ctx.fillStyle = rgb(this.px(this.pos)); this.pos += 4; } else this.ctx.fillStyle = H.fg; const xy = this.u8(), wh = this.u8(); this.ctx.fillRect(X + (xy >> 4), Y + (xy & 15), (wh >> 4) + 1, (wh & 15) + 1); }
          }
        }
      } catch (e) { if (e === NEED) this.pos = p0; throw e; }
      H.tx += 16; if (H.tx >= H.w) { H.tx = 0; H.ty += 16; }
    }
  }
  // ---- input ----
  key(sym, down) { const m = new Uint8Array(8), dv = new DataView(m.buffer); m[0] = 4; m[1] = down ? 1 : 0; dv.setUint32(4, sym >>> 0); this.send(m); }
  pointer(x, y, mask) { const m = new Uint8Array(6), dv = new DataView(m.buffer); m[0] = 5; m[1] = mask; dv.setUint16(2, Math.max(0, Math.min(this.w - 1, x | 0))); dv.setUint16(4, Math.max(0, Math.min(this.h - 1, y | 0))); this.send(m); }
  clipboard(text) { const t = new TextEncoder().encode(String(text).replace(/[^\x00-\xff]/g, '?')), m = new Uint8Array(8 + t.length), dv = new DataView(m.buffer); m[0] = 6; dv.setUint32(4, t.length); m.set(t, 8); this.send(m); }
}
const KEYSYM = { Enter: 0xff0d, Backspace: 0xff08, Tab: 0xff09, Escape: 0xff1b, Delete: 0xffff, Home: 0xff50, ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54, PageUp: 0xff55, PageDown: 0xff56, End: 0xff57, Insert: 0xff63, CapsLock: 0xffe5, NumLock: 0xff7f, ScrollLock: 0xff14, ContextMenu: 0xff67, PrintScreen: 0xff61, Pause: 0xff13, ShiftLeft: 0xffe1, ShiftRight: 0xffe2, ControlLeft: 0xffe3, ControlRight: 0xffe4, AltLeft: 0xffe9, AltRight: 0xffea, MetaLeft: 0xffeb, MetaRight: 0xffec };
function keysymOf(e) {
  if (KEYSYM[e.code] && /^(Shift|Control|Alt|Meta)/.test(e.code)) return e.code === 'AltRight' && e.key === 'AltGraph' ? 0xfe03 : KEYSYM[e.code];
  if (KEYSYM[e.key]) return KEYSYM[e.key];
  if (/^F([1-9]|1[0-2])$/.test(e.key)) return 0xffbe + (+e.key.slice(1)) - 1;
  if (e.key && [...e.key].length === 1) { const cp = e.key.codePointAt(0); return cp < 0x100 ? cp : 0x01000000 + cp; }
  const np = /^Numpad(\d)$/.exec(e.code); if (np) return 0xffb0 + +np[1];
  return 0;
}
const CONS = new Map();   // console session id -> { data(u8), closed() }
Mod.on('console', (m) => { const c = CONS.get(m.sid); if (c) c.data(m.data instanceof Uint8Array ? m.data : new Uint8Array(m.data)); });
Mod.on('consoleClosed', (m) => { const c = CONS.get(m.sid); if (c) c.closed(); });

PAGES.console = page((root, s, ctl) => {
  const t = targetOf(s), g = t.guest, nodeId = t.nodeId;
  if (!g) { root.append(note('Select a VM or container in Mgmt to open its console.')); return; }
  const tools = el('div', 'pv-tools'), stage = el('div', 'pv-stage'), status = el('span', 'pv-mut', ''); root.append(tools, stage);
  let sid = '', rfb = null, term = null, fit = null, running = true, cleanup = [], fitMode = lsGet('fit', '1') === '1';
  const bBtn = (l, fn, tt) => mkBtn(l, '', fn, tt);
  tools.append(el('b', '', `${KIND[g.kind]} ${g.vmid}${g.name ? ' · ' + g.name : ''}`), status, el('span', 'pv-grow'));
  const rec = bBtn('Reconnect', () => connect()), cad = bBtn('Ctrl+Alt+Del', () => { if (rfb) for (const k of [0xffe3, 0xffe9, 0xffff]) rfb.key(k, true), setTimeout(() => [0xffff, 0xffe9, 0xffe3].forEach((x) => rfb.key(x, false)), 60); }, 'Send Ctrl+Alt+Del to the guest');
  const typ = bBtn('Type text…', () => typeText(), 'Types text into the guest as if on its keyboard'), fitB = bBtn('', () => { fitMode = !fitMode; lsSet('fit', fitMode ? '1' : '0'); layout(); }), full = bBtn('Fullscreen', () => { stage.requestFullscreen && stage.requestFullscreen(); });
  if (g.kind === 'qemu') tools.append(typ, cad, fitB); tools.append(full, rec);
  function typeText() {
    modal('Type text into the guest', (b, close) => { const ta = el('textarea'); ta.rows = 5; ta.style.width = '100%'; ta.spellcheck = false; b.append(ta, el('div', 'pv-help', 'Sent as key presses. Works for plain letters, digits and symbols on a US layout.')); const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), mkBtn('Send', 'primary', async () => { const txt = ta.value; close(); for (const ch of txt) { const cp = ch.codePointAt(0), sym = ch === '\n' ? 0xff0d : ch === '\t' ? 0xff09 : cp < 0x100 ? cp : 0x01000000 + cp; rfb && rfb.key(sym, true); rfb && rfb.key(sym, false); await new Promise((r2) => setTimeout(r2, 8)); } })); b.append(r); setTimeout(() => ta.focus(), 30); });
  }
  const say = (txt, cls) => { status.textContent = txt; status.className = 'pv-mut ' + (cls || ''); };
  async function teardown() {
    cleanup.splice(0).forEach((f) => { try { f(); } catch {} });
    if (sid) { CONS.delete(sid); Mod.call('consoleClose', { sid }).catch(() => {}); sid = ''; }
    if (term) { try { term.dispose(); } catch {} term = null; } rfb = null; stage.innerHTML = ''; stage.className = 'pv-stage';
  }
  async function connect() {
    await teardown(); say('Checking the guest…');
    let cur; try { cur = await P(nodeId, 'GET', gpath(g) + '/status/current'); } catch (e) { say(errText(e), 'badc'); return; }
    if (!ctl.alive) return;
    if (cur.status !== 'running' && cur.status !== 'paused') {
      say(`${KIND[g.kind]} is ${cur.status}`); const box = el('div', 'pv-center'); box.append(el('p', '', `This ${KIND[g.kind]} is not running, so there is no console.`), mkBtn('Start it', 'primary', async () => { try { const upid = await P(nodeId, 'POST', gpath(g) + '/status/start'); await runTask(nodeId, upid, 'Start', null); setTimeout(connect, 1500); } catch (e) { fail(e); } })); stage.append(box); return;
    }
    say('Connecting…');
    try { const r = await Mod.call('consoleOpen', { id: nodeId, kind: g.kind, vmid: g.vmid }); if (!ctl.alive) { Mod.call('consoleClose', { sid: r.sid }).catch(() => {}); return; } sid = r.sid; g.kind === 'qemu' ? startVnc(r) : startTerm(r); }
    catch (e) { say(errText(e), 'badc'); }
  }
  const send = (u8) => { if (sid) Mod.call('consoleSend', { sid, data: u8 }).catch(() => {}); };
  function layout() {
    fitB.textContent = fitMode ? 'Fit window' : 'Actual size'; fitB.title = 'Switch between scaling the screen to the window and showing it at 100%';
    const cv = stage.querySelector('canvas'); if (!cv) return; stage.classList.toggle('actual', !fitMode);
    if (fitMode) { cv.style.width = '100%'; cv.style.height = '100%'; cv.style.objectFit = 'contain'; } else { cv.style.width = cv.width + 'px'; cv.style.height = cv.height + 'px'; cv.style.objectFit = ''; }
  }
  function startVnc(r) {
    const cv = el('canvas', 'pv-cv'); cv.tabIndex = 0; stage.append(cv);
    rfb = new RFB(cv, send, (ev, d) => {
      if (ev === 'connected') { say('Connected' + (d ? ' · ' + d : ''), 'okc'); layout(); cv.focus(); }
      else if (ev === 'size') layout();
      else if (ev === 'error') { say(d, 'badc'); }
      else if (ev === 'cursor') cv.style.cursor = d || 'default';
      else if (ev === 'clip') { try { navigator.clipboard.writeText(d); } catch {} }
    }, r.ticket);
    CONS.set(sid, { data: (u) => rfb && rfb.push(u), closed: () => { if (sid) { CONS.delete(sid); sid = ''; } say('Disconnected', 'badc'); } });
    const pos = (e) => { const b = cv.getBoundingClientRect(); let sx = cv.width / b.width, sy = cv.height / b.height, ox = 0, oy = 0; if (fitMode) { const k = Math.min(b.width / cv.width, b.height / cv.height); sx = sy = 1 / k; ox = (b.width - cv.width * k) / 2; oy = (b.height - cv.height * k) / 2; } return [(e.clientX - b.left - ox) * sx, (e.clientY - b.top - oy) * sy]; };
    const mask = (e) => (e.buttons & 1 ? 1 : 0) | (e.buttons & 4 ? 2 : 0) | (e.buttons & 2 ? 4 : 0);
    const on = (t, ev, fn, o) => { t.addEventListener(ev, fn, o); cleanup.push(() => t.removeEventListener(ev, fn, o)); };
    on(cv, 'mousemove', (e) => { const [x, y] = pos(e); rfb.pointer(x, y, mask(e)); });
    on(cv, 'mousedown', (e) => { cv.focus(); e.preventDefault(); const [x, y] = pos(e); rfb.pointer(x, y, mask(e)); });
    on(cv, 'mouseup', (e) => { e.preventDefault(); const [x, y] = pos(e); rfb.pointer(x, y, mask(e)); });
    on(cv, 'contextmenu', (e) => e.preventDefault());
    on(cv, 'wheel', (e) => { e.preventDefault(); const [x, y] = pos(e), b = e.deltaY < 0 ? 8 : 16, m = mask(e); rfb.pointer(x, y, m | b); rfb.pointer(x, y, m); }, { passive: false });
    const down = new Map();
    on(cv, 'keydown', (e) => { e.preventDefault(); e.stopPropagation(); const sym = keysymOf(e); if (!sym) return; down.set(e.code, sym); rfb.key(sym, true); }, true);
    on(cv, 'keyup', (e) => { e.preventDefault(); e.stopPropagation(); const sym = down.get(e.code) || keysymOf(e); down.delete(e.code); if (sym) rfb.key(sym, false); }, true);
    on(cv, 'blur', () => { for (const sym of down.values()) rfb.key(sym, false); down.clear(); });
    on(cv, 'paste', (e) => { const txt = e.clipboardData && e.clipboardData.getData('text'); if (txt) { rfb.clipboard(txt); } });
  }
  function startTerm(r) {
    const cs = getComputedStyle(document.body), box = el('div', 'pv-term'); stage.append(box); stage.classList.add('term');
    term = new Mod.Terminal({ cursorBlink: true, fontSize: 14, fontFamily: 'Menlo, Consolas, "DejaVu Sans Mono", monospace', scrollback: 5000, theme: { background: cs.getPropertyValue('--tbg').trim() || '#0a0b0e', foreground: cs.getPropertyValue('--tfg').trim() || '#e6e8eb' } });
    fit = new Mod.FitAddon.FitAddon(); term.loadAddon(fit); term.open(box);
    const doFit = () => { try { fit.fit(); Mod.call('consoleResize', { sid, cols: term.cols, rows: term.rows }).catch(() => {}); } catch {} };
    CONS.set(sid, { data: (u) => term && term.write(u), closed: () => { if (sid) { CONS.delete(sid); sid = ''; } say('Disconnected', 'badc'); } });
    term.onData((d) => { if (sid) Mod.call('consoleSend', { sid, text: d }).catch(() => {}); });
    const ro = new ResizeObserver(() => doFit()); ro.observe(box); cleanup.push(() => ro.disconnect());
    setTimeout(() => { doFit(); term && term.focus(); say('Connected', 'okc'); Mod.call('consoleSend', { sid, text: '\r' }).catch(() => {}); }, 150);
  }
  ctl.onStop(() => { teardown(); });
  connect();
});

// ================= Guest pages: Summary / Resources / Network / Options =================
function guestPage(render) {
  return page((root, s, ctl) => {
    const t = targetOf(s), g = t.guest, nodeId = t.nodeId;
    if (!g) { root.append(note('Select a VM or container in Mgmt first.')); return; }
    const head = el('div', 'pv-ghead'), body = el('div', 'pv-gbody'); root.append(head, body);
    let cur = null, first = true;
    function header() {
      head.innerHTML = ''; const run = cur && cur.status === 'running';
      head.append(dot(cur && cur.status), el('b', '', `${KIND[g.kind]} ${g.vmid}${cur && cur.name ? ' · ' + cur.name : g.name ? ' · ' + g.name : ''}`), el('span', 'pv-mut', cur ? cur.status + (run ? ' · up ' + fup(cur.uptime) : '') : ''), el('span', 'pv-grow'));
      const gg = { type: g.kind, vmid: g.vmid, name: (cur && cur.name) || g.name };
      if (!run) head.append(mkBtn('▶ Start', '', () => guestAction(nodeId, gg, 'start', () => load())));
      else head.append(mkBtn('■ Shut down', '', () => guestAction(nodeId, gg, 'shutdown', () => load())), mkBtn('↻ Reboot', '', () => guestAction(nodeId, gg, 'reboot', () => load())), mkBtn('Force stop', 'danger', () => guestAction(nodeId, gg, 'stop', () => load())));
      head.append(mkBtn('↻', '', () => load(), 'Refresh'));
    }
    async function load() {
      try {
        const [cfg, st, pend] = await Promise.all([P(nodeId, 'GET', gpath(g) + '/config'), P(nodeId, 'GET', gpath(g) + '/status/current'), P(nodeId, 'GET', gpath(g) + '/pending').catch(() => [])]);
        if (!ctl.alive) return; cur = st; header(); body.innerHTML = '';
        const waiting = (pend || []).filter((x) => x.pending !== undefined && x.key !== 'digest');
        if (waiting.length) body.append(note(`Changes waiting for a restart of the guest: ${waiting.map((x) => x.key).join(', ')}`, 'warn'));
        render({ body, g, nodeId, s, ctl, cfg, cur: st, reload: load, first });
        first = false;
      } catch (e) { body.innerHTML = ''; body.append(note(errText(e), 'bad')); }
    }
    ctl.onStop(() => {}); load();
    if (render.live) ctl.every(() => render.live({ g, nodeId, ctl }), ivl);
  });
}
async function saveCfg(nodeId, g, params, label, reload) {
  const p = { ...params }; if (!Object.keys(p).length) { Mod.toast('Nothing changed'); return; }
  try { await P(nodeId, 'PUT', gpath(g) + '/config', p); Mod.toast((label || 'Saved')); if (reload) reload(); } catch (e) { fail(e); }
}
// schema form: fields = [{ key, label, type, options, help, min, max, get(cfg), set(val, cfg) -> { param: value | null(delete) }, ro }]
function schemaForm(body, fields, cfg, onSave, title) {
  const box = el('div', 'pv-card'); if (title) box.append(el('div', 'pv-h', title)); const form = el('div', 'pv-form'); box.append(form); const ctrls = [];
  for (const f of fields) {
    const l = el('label', f.type === 'area' || f.wide ? 'wide' : ''); let c, init = f.get ? f.get(cfg) : cfg[f.key]; if (init === undefined) init = f.type === 'check' ? false : '';
    if (f.type === 'check') { l.className += ' chk'; c = el('input'); c.type = 'checkbox'; c.checked = !!init && init !== '0' && init !== 0; l.append(c, document.createTextNode(' ' + f.label)); init = c.checked; }
    else { l.append(document.createTextNode(f.label + ' ')); if (f.type === 'select') { c = el('select'); f.options.forEach(([v, t]) => c.append(new Option(t, v))); if (!f.options.some(([v]) => String(v) === String(init))) c.append(new Option(String(init) || '(not set)', init)); c.value = init; } else if (f.type === 'area') { c = el('textarea'); c.rows = 4; c.value = init; c.spellcheck = false; } else { c = el('input'); c.type = f.type || 'text'; if (f.ph) c.placeholder = f.ph; if (f.min != null) c.min = f.min; if (f.max != null) c.max = f.max; c.value = init; c.spellcheck = false; c.autocomplete = 'off'; } l.append(c); }
    if (f.ro) c.disabled = true; if (f.help) l.append(el('small', 'pv-help', f.help)); form.append(l); ctrls.push({ f, c, init });
  }
  const r = el('div', 'pv-row end'); r.append(mkBtn('Revert', '', () => ctrls.forEach(({ f, c, init }) => { if (f.type === 'check') c.checked = init; else c.value = init; })), mkBtn('Save', 'primary', () => {
    const params = {}, del = [];
    for (const { f, c, init } of ctrls) {
      if (f.ro) continue; const val = f.type === 'check' ? c.checked : f.type === 'number' ? c.value.trim() : c.value; if (String(val) === String(init)) continue;
      const out = f.set ? f.set(val, cfg) : { [f.key]: f.type === 'check' ? (val ? 1 : 0) : val === '' ? null : val };
      for (const [k, v] of Object.entries(out)) { if (v === null || v === '') del.push(k); else params[k] = v; }
    }
    if (del.length) params.delete = [...new Set(del)].join(',');
    onSave(params);
  })); box.append(r); body.append(box); return box;
}
const featSet = (cfg, name, on) => { const o = parseKV(cfg.features); delete o._order; if (on) o[name] = 1; else delete o[name]; const v = kvStr(o); return v ? v : null; };

// ---- Resources ----
const diskRe = /^(ide|sata|scsi|virtio)\d+$/;
PAGES.res = guestPage(({ body, g, nodeId, cfg, reload }) => {
  const q = g.kind === 'qemu';
  const f = q ? [
    { key: 'sockets', label: 'Sockets', type: 'number', min: 1, get: (c) => c.sockets || 1 }, { key: 'cores', label: 'Cores', type: 'number', min: 1, get: (c) => c.cores || 1 },
    { key: 'cpu', label: 'CPU type', type: 'select', options: [['x86-64-v2-AES', 'x86-64-v2-AES'], ['x86-64-v3', 'x86-64-v3'], ['host', 'host'], ['kvm64', 'kvm64'], ['qemu64', 'qemu64']], get: (c) => String(c.cpu || 'kvm64').split(',')[0] },
    { key: 'memory', label: 'Memory (MiB)', type: 'number', min: 16, get: (c) => c.memory || 512 }, { key: 'balloon', label: 'Minimum memory for ballooning (MiB, 0 = off)', type: 'number', min: 0, get: (c) => (c.balloon == null ? '' : c.balloon), set: (v) => ({ balloon: v === '' ? null : v }) },
  ] : [
    { key: 'cores', label: 'Cores', type: 'number', min: 0, help: '0 = all cores of the node', get: (c) => c.cores || 0, set: (v) => ({ cores: +v ? v : null }) }, { key: 'cpulimit', label: 'CPU limit (cores, 0 = none)', type: 'number', min: 0, get: (c) => c.cpulimit || 0, set: (v) => ({ cpulimit: +v ? v : null }) },
    { key: 'memory', label: 'Memory (MiB)', type: 'number', min: 16, get: (c) => c.memory || 512 }, { key: 'swap', label: 'Swap (MiB)', type: 'number', min: 0, get: (c) => (c.swap == null ? 512 : c.swap) },
  ];
  schemaForm(body, f, cfg, (p) => saveCfg(nodeId, g, p, 'Resources saved', reload), 'CPU and memory');
  // disks
  const dbox = el('div', 'pv-card'); dbox.append(el('div', 'pv-h', q ? 'Hard disks and CD/DVD drives' : 'Root disk and mount points'));
  const keys = Object.keys(cfg).filter((k) => (q ? diskRe.test(k) : k === 'rootfs' || /^mp\d+$/.test(k))).sort();
  if (!keys.length) dbox.append(note('No disks.'));
  for (const k of keys) {
    const v = String(cfg[k]), kv = parseKV(v), r = el('div', 'pv-disk'), cd = /media=cdrom/.test(v);
    const name = el('b', '', k), main = el('span', cd ? 'pv-mut' : '', cd ? (v.startsWith('none') ? 'Empty CD/DVD drive' : v.split(',')[0]) : v.split(',')[0]), sz = el('span', 'pv-mut', kv.size ? `size ${kv.size}` : '');
    r.append(name, main, sz, el('span', 'pv-grow'));
    if (cd) { r.append(mkBtn('Change ISO…', '', () => pickIsoFor(nodeId, async (volid) => saveCfg(nodeId, g, { [k]: `${volid || 'none'},media=cdrom` }, 'Drive changed', reload))), v.startsWith('none') ? '' : mkBtn('Eject', '', () => saveCfg(nodeId, g, { [k]: 'none,media=cdrom' }, 'Ejected', reload))); }
    else {
      r.append(mkBtn('Resize…', '', () => modal('Grow ' + k, (b, close) => { const i = el('input'); i.type = 'number'; i.min = 1; i.value = 5; const l = el('label', '', 'Add (GiB) '); l.append(i); b.append(l, el('div', 'pv-help', 'Disks can only be grown. The partition and filesystem inside the guest must be grown separately.')); const rw = el('div', 'pv-row end'); rw.append(mkBtn('Cancel', '', close), mkBtn('Grow', 'primary', async () => { close(); try { await P(nodeId, 'PUT', gpath(g) + '/resize', { disk: k, size: '+' + (+i.value || 1) + 'G' }); Mod.toast('Disk grown'); reload(); } catch (e) { fail(e); } })); b.append(rw); })),
        mkBtn('Detach', '', async () => { if (k === 'rootfs') return Mod.toast('The root disk cannot be detached'); if (await ask('Detach ' + k + '?', 'The disk is detached and kept as an unused disk (nothing is deleted).', 'Detach', true)) saveCfg(nodeId, g, { delete: k }, 'Detached', reload); }));
    }
    dbox.append(r);
  }
  dbox.append(mkBtn(q ? 'Add hard disk…' : 'Add mount point…', '', () => addDisk(nodeId, g, cfg, reload))); body.append(dbox);
});
async function pickIsoFor(nodeId, done) {
  let isos = []; try { const st = await contentStores(nodeId, 'iso'); for (const x of st) isos.push(...(await P(nodeId, 'GET', `/storage/${encodeURIComponent(x.storage)}/content`, { content: 'iso' }))); } catch (e) { return fail(e); }
  modal('Choose an ISO image', (b, close) => { const sel = el('select'); sel.size = Math.min(12, isos.length + 1); sel.style.width = '100%'; sel.append(new Option('(empty drive)', '')); isos.sort((a, c) => a.volid.localeCompare(c.volid)).forEach((x) => sel.append(new Option(`${x.volid}  (${fb(x.size)})`, x.volid))); sel.selectedIndex = 0; b.append(sel); const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), mkBtn('Use', 'primary', () => { close(); done(sel.value); })); b.append(r); });
}
async function addDisk(nodeId, g, cfg, reload) {
  const q = g.kind === 'qemu'; let st = []; try { st = await contentStores(nodeId, q ? 'images' : 'rootdir'); } catch (e) { return fail(e); }
  modal(q ? 'Add hard disk' : 'Add mount point', (b, close) => {
    const form = el('div', 'pv-form'); b.append(form); const mk = (t, c) => { const l = el('label', '', t + ' '); l.append(c); form.append(l); return c; };
    const bus = q ? mk('Bus', el('select')) : null; if (bus) ['scsi', 'virtio', 'sata', 'ide'].forEach((x) => bus.append(new Option(x, x)));
    const sto = mk('Storage', el('select')); st.forEach((x) => sto.append(new Option(`${x.storage} (${fb(x.avail)} free)`, x.storage))); const size = mk('Size (GiB)', el('input')); size.type = 'number'; size.value = 8; size.min = 1; const path = q ? null : mk('Path in the container', el('input')); if (path) path.placeholder = '/mnt/data';
    const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), mkBtn('Add', 'primary', () => {
      if (!sto.value) return Mod.toast('No storage available'); let key, val;
      if (q) { const used = new Set(Object.keys(cfg)); let i = 0; while (used.has(bus.value + i)) i++; key = bus.value + i; val = `${sto.value}:${+size.value}`; }
      else { if (!/^\/[^,]+$/.test(path.value)) return Mod.toast('Enter an absolute path like /mnt/data'); const used = new Set(Object.keys(cfg)); let i = 0; while (used.has('mp' + i)) i++; key = 'mp' + i; val = `${sto.value}:${+size.value},mp=${path.value}`; }
      close(); saveCfg(nodeId, g, { [key]: val }, 'Disk added', reload);
    })); b.append(r);
  });
}

// ---- Network ----
const NET_MODELS = ['virtio', 'e1000', 'e1000e', 'rtl8139', 'vmxnet3', 'i82551', 'i82557b', 'i82559er', 'ne2k_pci', 'pcnet'];
PAGES.net = guestPage(({ body, g, nodeId, cfg, reload }) => {
  const q = g.kind === 'qemu'; const keys = Object.keys(cfg).filter((k) => /^net\d+$/.test(k)).sort((a, b) => +a.slice(3) - +b.slice(3));
  const head = el('div', 'pv-tools'); head.append(el('b', '', 'Network devices'), el('span', 'pv-grow'), mkBtn('Add network device', 'primary', async () => {
    const used = new Set(keys); let i = 0; while (used.has('net' + i)) i++; let br = 'vmbr0'; try { const l = await P(nodeId, 'GET', '/network', { type: 'any_bridge' }); if (l && l[0]) br = l[0].iface; } catch {}
    saveCfg(nodeId, g, { ['net' + i]: q ? `virtio,bridge=${br},firewall=1` : `name=eth${i},bridge=${br},ip=dhcp,firewall=1` }, 'Network device added', reload);
  })); body.append(head);
  if (!keys.length) body.append(note('This guest has no network device.'));
  P(nodeId, 'GET', '/network', { type: 'any_bridge' }).catch(() => []).then((brs) => {
    const bridges = (brs || []).map((x) => x.iface);
    for (const k of keys) {
      const o = parseKV(cfg[k]); let model = '', mac = '';
      if (q) { model = NET_MODELS.find((m) => o[m] !== undefined || o._first === m) || 'virtio'; mac = o[model] || ''; }
      const fields = q ? [
        { key: 'model', label: 'Model', type: 'select', options: NET_MODELS.map((m) => [m, m]), get: () => model }, { key: 'mac', label: 'MAC address', get: () => mac, help: 'Empty = generate one.' },
      ] : [{ key: 'name', label: 'Interface name', get: () => o.name || '' }, { key: 'hwaddr', label: 'MAC address', get: () => o.hwaddr || '' }];
      fields.push({ key: 'bridge', label: 'Bridge', type: 'select', options: bridges.length ? bridges.map((x) => [x, x]) : [[o.bridge || 'vmbr0', o.bridge || 'vmbr0']], get: () => o.bridge || '' }, { key: 'tag', label: 'VLAN tag', type: 'number', min: 1, max: 4094, get: () => o.tag || '' });
      if (!q) fields.push({ key: 'ip', label: 'IPv4 (CIDR, dhcp or manual)', get: () => o.ip || '' }, { key: 'gw', label: 'IPv4 gateway', get: () => o.gw || '' }, { key: 'ip6', label: 'IPv6 (CIDR, auto, dhcp or manual)', get: () => o.ip6 || '' }, { key: 'gw6', label: 'IPv6 gateway', get: () => o.gw6 || '' });
      fields.push({ key: 'firewall', label: 'Firewall', type: 'check', get: () => o.firewall === '1' }, { key: 'rate', label: 'Rate limit (MB/s)', type: 'number', min: 0, get: () => o.rate || '' }, { key: 'mtu', label: 'MTU', type: 'number', get: () => o.mtu || '' });
      if (q) fields.push({ key: 'link_down', label: 'Disconnected', type: 'check', get: () => o.link_down === '1' });
      const box = schemaForm(body, fields.map((f) => ({ ...f, set: () => ({}) })), cfg, () => {}, k);
      // the form is rebuilt as one string, so the generic save is replaced
      const form = box.querySelector('.pv-form'), inputs = [...form.querySelectorAll('input,select')]; const row = box.querySelector('.pv-row'); row.innerHTML = '';
      row.append(mkBtn('Remove', 'danger', async () => { if (await ask('Remove ' + k + '?', 'The network device is removed from the guest.', 'Remove', true)) saveCfg(nodeId, g, { delete: k }, 'Removed', reload); }), mkBtn('Save', 'primary', () => {
        const val = {}; fields.forEach((f, i) => { const c = inputs[i]; val[f.key] = f.type === 'check' ? c.checked : c.value.trim(); });
        const n = {}; ['bridge', 'tag', 'rate', 'mtu'].forEach((x) => { if (val[x]) n[x] = val[x]; }); if (val.firewall) n.firewall = 1; if (val.link_down) n.link_down = 1;
        let str;
        if (q) str = kvStr({ ...n }, val.mac ? `${val.model}=${val.mac}` : val.model); else { ['name', 'hwaddr', 'ip', 'gw', 'ip6', 'gw6'].forEach((x) => { if (val[x]) n[x] = val[x]; }); const first = { name: n.name }; delete n.name; str = kvStr({ ...first, ...n }); }
        saveCfg(nodeId, g, { [k]: str }, k + ' saved', reload);
      }));
    }
  });
});

// ---- Options ----
PAGES.opt = guestPage(({ body, g, nodeId, cfg, reload }) => {
  const q = g.kind === 'qemu', save = (p) => saveCfg(nodeId, g, p, 'Options saved', reload);
  const f = [
    { key: q ? 'name' : 'hostname', label: q ? 'Name' : 'Hostname', set: (v) => ({ [q ? 'name' : 'hostname']: v || null }) },
    { key: 'description', label: 'Notes', type: 'area' },
    { key: 'onboot', label: 'Start at boot', type: 'check' }, { key: 'protection', label: 'Protection (blocks deleting the guest and its disks)', type: 'check' },
    { key: 'startup', label: 'Start / shutdown order', ph: 'order=1,up=30,down=60', help: 'order=N,up=SECONDS,down=SECONDS' }, { key: 'tags', label: 'Tags', help: 'Separated by ;' },
  ];
  if (q) f.push(
    { key: 'ostype', label: 'OS type', type: 'select', options: [['l26', 'Linux'], ['win11', 'Windows 11 / 2022 / 2025'], ['win10', 'Windows 10 / 2016 / 2019'], ['win8', 'Windows 8.x / 2012'], ['win7', 'Windows 7 / 2008 R2'], ['other', 'Other'], ['solaris', 'Solaris']] },
    { key: 'boot', label: 'Boot order', help: 'e.g. order=scsi0;ide2;net0' }, { key: 'agent', label: 'QEMU guest agent', type: 'check', get: (c) => /(^|,)(enabled=)?1/.test(String(c.agent || '')), set: (v, c) => { const o = parseKV(c.agent); const rest = Object.entries(o).filter(([k]) => k[0] !== '_' && k !== 'enabled'); return { agent: kvStr({ enabled: v ? 1 : 0, ...Object.fromEntries(rest) }) }; } },
    { key: 'tablet', label: 'Use tablet for pointer', type: 'check', get: (c) => (c.tablet == null ? true : c.tablet), set: (v) => ({ tablet: v ? 1 : 0 }) }, { key: 'localtime', label: 'Use local time for RTC', type: 'check' }, { key: 'hotplug', label: 'Hotplug', help: 'e.g. disk,network,usb' },
    { key: 'vga', label: 'Display', help: 'e.g. std, qxl, virtio, serial0' });
  else f.push(
    { key: 'nameserver', label: 'DNS server' }, { key: 'searchdomain', label: 'DNS domain' },
    { key: '_nest', label: 'Nesting', type: 'check', get: (c) => parseKV(c.features).nesting === '1', set: (v, c) => ({ features: featSet(c, 'nesting', v) }) }, { key: '_keyctl', label: 'keyctl', type: 'check', get: (c) => parseKV(c.features).keyctl === '1', set: (v, c) => ({ features: featSet(c, 'keyctl', v) }) }, { key: '_fuse', label: 'FUSE', type: 'check', get: (c) => parseKV(c.features).fuse === '1', set: (v, c) => ({ features: featSet(c, 'fuse', v) }) },
    { key: 'cmode', label: 'Console mode', type: 'select', options: [['tty', 'tty'], ['console', 'console'], ['shell', 'shell']], get: (c) => c.cmode || 'tty' }, { key: 'tty', label: 'TTY count', type: 'number', min: 0, max: 6, get: (c) => (c.tty == null ? 2 : c.tty) },
    { key: 'unprivileged', label: 'Unprivileged', type: 'check', ro: true }, { key: 'arch', label: 'Architecture', ro: true }, { key: 'ostype', label: 'OS', ro: true });
  schemaForm(body, f, cfg, save, 'Options');
  body.append(note('Some options (like the SCSI controller or machine type) only apply after the guest restarts.'));
});

// ---- Summary ----
PAGES.sum = guestPage(({ body, g, nodeId, s, ctl, cfg, cur, reload }) => {
  const q = g.kind === 'qemu', gg = { type: g.kind, vmid: g.vmid, name: cur.name || g.name };
  const run = cur.status === 'running', info = el('div', 'pv-card'), kv = el('div', 'pv-kv'); info.append(el('div', 'pv-h', 'Summary'), kv);
  const row = (k, v) => { kv.append(el('span', 'pv-mut', k), el('span', '', v == null || v === '' ? '–' : String(v))); };
  row('Status', cur.status + (cur.qmpstatus && cur.qmpstatus !== cur.status ? ` (${cur.qmpstatus})` : '')); row('Uptime', run ? fup(cur.uptime) : '–'); row('Node', s.pveNode || cfg.node || ''); row('ID', g.vmid); row('Type', q ? 'Virtual machine (QEMU)' : 'LXC container');
  row('OS', cfg.ostype); row('CPU', q ? `${(cfg.sockets || 1) * (cfg.cores || 1)} (${cfg.sockets || 1} socket, ${cfg.cores || 1} cores)` : `${cfg.cores || 'all'} cores`); row('Memory', `${cfg.memory || '?'} MiB`); if (cfg.tags) row('Tags', cfg.tags); if (cfg.onboot) row('Start at boot', 'yes');
  const ipRow = el('span', '', '…'); kv.append(el('span', 'pv-mut', 'Address'), ipRow); guestIp(nodeId, g.kind, g.vmid).then((ip) => { ipRow.textContent = ip || (run ? (q && !(cfg.agent && /1/.test(String(cfg.agent))) ? 'unknown (enable the QEMU guest agent)' : 'unknown') : 'not running'); });
  if (cfg.description) { kv.append(el('span', 'pv-mut', 'Notes'), el('span', 'pv-pre', cfg.description)); }
  body.append(info);
  if (run) { const gb = el('div', 'pv-card pv-gauges'), mk = (t, f, sub) => { const d = el('div', 'pv-gauge'); d.append(el('span', 'pv-mut', t), bar(f, sub)); gb.append(d); };
    mk('CPU', cur.cpu, `${fp(cur.cpu)} of ${cur.cpus || cfg.cores || '?'} CPUs`); mk('Memory', cur.mem / cur.maxmem, `${fb(cur.mem)} / ${fb(cur.maxmem)}`); if (cur.maxdisk) mk('Disk', cur.disk / cur.maxdisk, `${fb(cur.disk)} / ${fb(cur.maxdisk)}`); body.append(gb); }
  const act = el('div', 'pv-card pv-tools'); act.append(mkBtn('Open console', '', () => Mod.selectTab('pve-console')), mkBtn('Add to my server list…', '', () => addToServers({ id: nodeId, group: s.group }, gg)), mkBtn('Delete…', 'danger', () => deleteGuest(nodeId, gg, () => { selectGuest(s, null, 'pve-mgmt'); }))); body.append(act);
  // charts
  const tfSel = el('select'); [['hour', 'Last hour'], ['day', 'Last day'], ['week', 'Last week']].forEach(([v, l]) => tfSel.append(new Option(l, v))); tfSel.value = lsGet('gtf', 'hour');
  const ch = el('div', 'pv-card'); const ct = el('div', 'pv-tools'); ct.append(el('b', '', 'Usage'), el('span', 'pv-grow'), tfSel); const grid = el('div', 'pv-charts'); ch.append(ct, grid); body.append(ch);
  const cCpu = lineChart({ title: 'CPU', fmt: fp, max: 1 }), cMem = lineChart({ title: 'Memory', fmt: fb }), cNet = lineChart({ title: 'Network', fmt: fr }), cIo = lineChart({ title: 'Disk I/O', fmt: fr }); grid.append(cCpu, cMem, cNet, cIo);
  async function rrd() { let d; try { d = await P(nodeId, 'GET', gpath(g) + '/rrddata', { timeframe: tfSel.value, cf: 'AVERAGE' }); } catch { return; } const sr = (f) => d.map((p) => [p.time, p[f] == null ? null : +p[f]]);
    cCpu.update([{ label: 'CPU', data: sr('cpu') }]); cMem.update([{ label: 'Used', data: sr('mem') }, { label: 'Allocated', data: sr('maxmem') }]); cNet.update([{ label: 'In', data: sr('netin') }, { label: 'Out', data: sr('netout') }]); cIo.update([{ label: 'Read', data: sr('diskread') }, { label: 'Write', data: sr('diskwrite') }]); }
  tfSel.onchange = () => { lsSet('gtf', tfSel.value); rrd(); }; ctl.every(rrd, 30000);
  // snapshots
  const sn = el('div', 'pv-card'); body.append(sn);
  async function snaps() {
    let l = []; try { l = await P(nodeId, 'GET', gpath(g) + '/snapshot'); } catch (e) { sn.innerHTML = ''; sn.append(el('div', 'pv-h', 'Snapshots'), note(errText(e), 'bad')); return; }
    sn.innerHTML = ''; const h = el('div', 'pv-tools'); h.append(el('b', '', 'Snapshots'), el('span', 'pv-grow'), mkBtn('Take snapshot…', '', () => modal('Take snapshot', (b, close) => {
      const form = el('div', 'pv-form'); b.append(form); const mk = (t, c) => { const l2 = el('label', '', t + ' '); l2.append(c); form.append(l2); return c; }; const nm = mk('Name', el('input')); nm.value = 'snap' + new Date().toISOString().slice(0, 10).replace(/-/g, ''); const ds = mk('Description', el('input')); let vm = null; if (q) { vm = el('input'); vm.type = 'checkbox'; const l3 = el('label', 'chk wide'); l3.append(vm, document.createTextNode(' Include RAM (VM state)')); form.append(l3); }
      const r = el('div', 'pv-row end'); r.append(mkBtn('Cancel', '', close), mkBtn('Take', 'primary', async () => { if (!/^[A-Za-z][\w-]{1,39}$/.test(nm.value)) return Mod.toast('Name: start with a letter; letters, digits, _ and - only'); close(); try { const upid = await P(nodeId, 'POST', gpath(g) + '/snapshot', { snapname: nm.value, description: ds.value, ...(vm && vm.checked ? { vmstate: 1 } : {}) }); await runTask(nodeId, upid, 'Snapshot ' + nm.value, snaps); } catch (e) { fail(e); } })); b.append(r); })));
    sn.append(h); const real = l.filter((x) => x.name !== 'current'); if (!real.length) sn.append(note('No snapshots.'));
    for (const x of real) { const r = el('div', 'pv-disk'); r.append(el('b', '', x.name), el('span', 'pv-mut', `${x.snaptime ? ftime(x.snaptime) : ''} ${x.description || ''}`), el('span', 'pv-grow'),
      mkBtn('Roll back', '', async () => { if (await ask('Roll back to ' + x.name + '?', 'The guest returns to this snapshot. Everything changed since then is lost.', 'Roll back', true)) try { const upid = await P(nodeId, 'POST', gpath(g) + `/snapshot/${x.name}/rollback`); runTask(nodeId, upid, 'Rollback', reload); } catch (e) { fail(e); } }),
      mkBtn('Delete', 'danger', async () => { if (await ask('Delete snapshot?', x.name, 'Delete', true)) try { const upid = await P(nodeId, 'DELETE', gpath(g) + `/snapshot/${x.name}`); runTask(nodeId, upid, 'Delete snapshot', snaps); } catch (e) { fail(e); } })); sn.append(r); }
  }
  snaps();
});
//==== css ====
.pv-root{height:100%;min-height:0;overflow:auto;display:flex;flex-direction:column;gap:10px;padding:2px 2px 14px;font-size:13px}
.pv-root *{box-sizing:border-box}
.pv-mut{color:var(--mut)}.pv-grow{flex:1}.pv-pre{white-space:pre-wrap;word-break:break-word}
.okc{color:var(--ok)}.badc{color:var(--bad)}.warnc{color:#f5a524}.pv-run{color:var(--acc)}.pv-okc{color:var(--ok)}.pv-badc{color:var(--bad)}.pv-warnc{color:#f5a524}
.pv-note{padding:10px 12px;border:1px solid var(--line);border-radius:8px;color:var(--mut);white-space:pre-wrap;word-break:break-word}
.pv-note.bad{color:var(--bad);border-color:var(--bad)}.pv-note.warn{color:#f5a524;border-color:#f5a524}
.pv-card{border:1px solid var(--line);border-radius:10px;padding:10px 12px;background:color-mix(in srgb,var(--panel) 70%,transparent);flex:none}
.pv-h{font-weight:600;margin-bottom:8px}
.pv-tools{display:flex;gap:8px;align-items:center;flex-wrap:wrap;flex:none}
.pv-tools input{min-width:160px}
.pv-row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.pv-row.end{justify-content:flex-end;margin-top:10px}
button.primary{background:var(--acc);color:var(--accfg);border-color:var(--acc)}
.pv-root button.danger,.pv-modal button.danger{color:var(--bad)}
.pv-ib{padding:2px 8px;min-width:28px}
/* dots */
.pv-dot{width:10px;height:10px;border-radius:50%;flex:none;display:inline-block;background:var(--mut)}
.pv-dot.ok{background:var(--ok);box-shadow:0 0 0 3px color-mix(in srgb,var(--ok) 25%,transparent)}.pv-dot.warn{background:#f5a524}.pv-dot.bad{background:var(--bad)}.pv-dot.off{background:var(--mut);opacity:.6}
.pv-sdot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-left:7px;vertical-align:middle;background:var(--mut)}
.pv-sdot.ok{background:var(--ok)}.pv-sdot.warn{background:#f5a524}.pv-sdot.bad{background:var(--bad)}.pv-sdot.off{background:var(--mut)}
/* bars */
.pv-bar{position:relative;height:16px;border-radius:8px;background:color-mix(in srgb,var(--fg) 12%,var(--panel));overflow:hidden;min-width:70px}
.pv-bar>i{display:block;height:100%;background:var(--acc);border-radius:8px}.pv-bar>i.warn{background:#f5a524}.pv-bar>i.bad{background:var(--bad)}
.pv-barl{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:11px;white-space:nowrap;text-shadow:0 0 3px var(--bg)}
/* node card */
.pv-nhead{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.pv-gauges{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-top:10px}
.pv-gauge{display:flex;flex-direction:column;gap:4px}
/* table */
.pv-sum{color:var(--mut);padding:0 2px}
.pv-table{border:1px solid var(--line);border-radius:10px;overflow:hidden}
.pv-tr{display:grid;grid-template-columns:18px 52px minmax(120px,1.6fr) 54px 90px minmax(120px,1.2fr) 80px 150px;gap:8px;align-items:center;padding:6px 10px;border-top:1px solid var(--line);cursor:pointer}
.pv-tr:first-child{border-top:0}.pv-tr:hover{background:var(--hover)}.pv-tr.sel{background:var(--selbg)}
.pv-th{cursor:default;color:var(--mut);font-size:12px;background:var(--panel)}.pv-th:hover{background:var(--panel)}
.pv-nm{display:flex;gap:6px;align-items:center;min-width:0;flex-wrap:wrap}.pv-nm b{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pv-chip{font-style:normal;font-size:10px;padding:1px 6px;border:1px solid var(--line);border-radius:9px;color:var(--mut)}.pv-chip.warn{color:#f5a524;border-color:#f5a524}
.pv-acts{display:flex;gap:4px;justify-content:flex-end}
.pv-table.tasks .pv-tr,.pv-table.sumt .pv-tr{grid-template-columns:150px minmax(100px,1fr) 160px 90px;cursor:pointer}
.pv-table.sumt .pv-tr{grid-template-columns:160px 1fr;cursor:default}
.pv-have .pv-tr{grid-template-columns:1fr 90px 80px;cursor:default;padding:4px 8px}
.pv-tasks{display:flex;flex-direction:column;gap:6px;flex:none}
/* monitor */
.pv-tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;flex:none}
.pv-tile{border:1px solid var(--line);border-radius:10px;padding:10px 12px;display:flex;flex-direction:column;gap:5px;background:color-mix(in srgb,var(--panel) 70%,transparent)}
.pv-big{font-size:20px;font-weight:600;letter-spacing:-.01em}
.pv-charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:10px;flex:none}
.pv-chart{border:1px solid var(--line);border-radius:10px;padding:8px 10px;background:color-mix(in srgb,var(--panel) 70%,transparent)}
.pv-chead{display:flex;justify-content:space-between;gap:8px;align-items:baseline;flex-wrap:wrap}
.pv-legend{display:flex;gap:10px;font-size:11px;color:var(--mut)}.pv-lg{display:inline-flex;align-items:center;gap:4px}.pv-lg i{width:10px;height:3px;border-radius:2px;display:inline-block}
.pv-cbox{position:relative;margin-top:6px}.pv-svg{width:100%;height:110px;display:block}.pv-grid{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
.pv-ymax{position:absolute;top:0;left:2px;font-size:10px;color:var(--mut);pointer-events:none}
.pv-tip{position:absolute;top:4px;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:4px 8px;font-size:11px;white-space:pre;pointer-events:none;z-index:3;box-shadow:var(--shadow)}
.pv-gridc{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px}
.pv-store{display:flex;flex-direction:column;gap:5px;border:1px solid var(--line);border-radius:8px;padding:8px 10px}.pv-srow{display:flex;gap:7px;align-items:center;min-width:0}.pv-srow span{font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pv-dots{display:flex;flex-wrap:wrap;gap:6px}
.pv-gdot{display:inline-flex;gap:6px;align-items:center;padding:3px 9px;border-radius:14px;font-size:12px}.pv-gdot small{font-size:10px}
/* forms */
.pv-form{display:grid;grid-template-columns:1fr 1fr;gap:10px 14px;align-items:start}
.pv-form label{display:flex;flex-direction:column;gap:4px;color:var(--mut);font-size:12px;min-width:0}.pv-form label.chk{flex-direction:row;align-items:center;gap:8px;color:var(--fg);font-size:13px;padding-top:4px}
.pv-form label.wide,.pv-form .wide{grid-column:1/-1}.pv-form input:not([type=checkbox]),.pv-form select,.pv-form textarea{width:100%;color:var(--fg);font-size:13px}
.pv-form textarea{font-family:var(--mono,monospace);background:var(--btn);border:1px solid var(--line);border-radius:var(--rs);padding:6px 8px}
.pv-formh{grid-column:1/-1;font-weight:600;margin-top:4px}
.pv-form.ext{display:block}.pv-form.ext>label.chk{padding:4px 0}.pv-form.ext .pv-form{margin-top:8px}
.pv-help{font-size:11px;color:var(--mut);white-space:pre-wrap;word-break:break-word}.pv-form label .pv-help{margin-top:1px}
.pv-certrow{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.pv-certrow input{flex:1;min-width:200px}
.pv-trust{border:1px solid var(--line);border-radius:8px;padding:8px 10px;margin-top:6px;display:flex;flex-direction:column;gap:8px;align-items:flex-start;color:var(--fg);white-space:pre-wrap;font-family:var(--mono,monospace);font-size:11px}.pv-trust.bad{border-color:var(--bad)}
#typeBox .pv-form{margin:6px 0}
.extSec{margin-top:6px;border-top:1px solid var(--line);padding-top:8px}
/* guest pages */
.pv-ghead{display:flex;gap:10px;align-items:center;flex-wrap:wrap;flex:none}
.pv-gbody{display:flex;flex-direction:column;gap:10px}
.pv-kv{display:grid;grid-template-columns:130px 1fr;gap:5px 12px}
.pv-disk{display:flex;gap:10px;align-items:center;padding:6px 0;border-top:1px solid var(--line);flex-wrap:wrap}.pv-disk:first-of-type{border-top:0}
.pv-disk>b{min-width:64px}
/* wizard */
.pv-wiz{display:flex;gap:14px;min-height:0;flex:1}
.pv-steps{display:flex;flex-direction:column;gap:3px;width:150px;flex:none}
.pv-step{text-align:left;border:0;background:none;color:var(--mut);padding:6px 10px;border-radius:8px}.pv-step.vis{color:var(--fg)}.pv-step.on{background:var(--selbg);color:var(--fg)}.pv-step:disabled{opacity:.45}
.pv-wmain{flex:1;min-width:0;display:flex;flex-direction:column;gap:12px}.pv-wmain h3{margin:0}
.pv-wnav{margin-top:auto}
.pv-choose{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.pv-big-choice{display:flex;flex-direction:column;gap:6px;align-items:flex-start;text-align:left;padding:16px;border-radius:12px;height:auto;white-space:normal}.pv-big-choice b{font-size:15px}
.pv-log{background:var(--tbg,#0a0b0e);color:var(--tfg,#e6e8eb);border:1px solid var(--line);border-radius:8px;padding:10px;max-height:340px;min-height:80px;overflow:auto;white-space:pre-wrap;font-size:12px;margin:0}
.pv-prog{display:flex;flex-direction:column;gap:5px;margin-top:10px}
/* console */
.pv-stage{flex:1;min-height:320px;background:#000;border-radius:8px;position:relative;overflow:hidden;display:flex}
.pv-stage.actual{overflow:auto;display:block}.pv-stage:fullscreen{border-radius:0}
.pv-cv{display:block;outline:0;image-rendering:auto}
.pv-center{margin:auto;color:#ddd;text-align:center;display:flex;flex-direction:column;gap:10px;align-items:center}
.pv-stage.term{background:var(--tbg,#0a0b0e);padding:6px}.pv-term{flex:1;min-width:0;min-height:0}.pv-term .xterm{height:100%}
/* modal + menu */
.pv-modal{position:fixed;inset:0;background:#0009;z-index:9000;display:flex;align-items:center;justify-content:center;padding:20px}
.pv-mbox{background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:14px;width:min(520px,100%);max-height:90vh;display:flex;flex-direction:column;box-shadow:var(--shadow)}.pv-mbox.wide{width:min(760px,100%)}
.pv-mhead{display:flex;justify-content:space-between;align-items:center;padding:12px 16px;border-bottom:1px solid var(--line)}.pv-x{border:0;background:none;font-size:20px;padding:0 6px}
.pv-mbody{padding:14px 16px;overflow:auto}.pv-mbody p{margin:0 0 6px}
.pv-menu{position:fixed;z-index:9500;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:4px;box-shadow:var(--shadow);display:flex;flex-direction:column;min-width:180px}
.pv-menu button{border:0;background:none;text-align:left;padding:6px 10px;border-radius:6px}.pv-menu button:hover:not(:disabled){background:var(--hover)}.pv-menu button:disabled{opacity:.4}.pv-menu hr{border:0;border-top:1px solid var(--line);margin:3px 0;width:100%}
@media (max-width:760px){.pv-form{grid-template-columns:1fr}.pv-wiz{flex-direction:column}.pv-steps{width:auto;flex-direction:row;flex-wrap:wrap}.pv-tr{grid-template-columns:18px 1fr 80px 100px}.pv-tr>:nth-child(2),.pv-tr>:nth-child(4),.pv-tr>:nth-child(5),.pv-tr>:nth-child(7){display:none}}
