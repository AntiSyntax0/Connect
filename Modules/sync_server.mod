//==== module ====
{
  "id": "sync_server",
  "name": "Sync server",
  "description": "Keep several PCs in sync through your own SSH server: servers, macros, notes, runbooks, IPMI entries, settings and trusted host keys. Encrypted before upload; the server only needs Python 3.",
  "version": "1.0.0",
  "minApi": 2,
  "permissions": [
    "ssh",
    "data"
  ],
  "test": true,
  "config": [
    {
      "key": "on",
      "label": "Keep this PC in sync",
      "type": "checkbox",
      "default": false,
      "help": "Syncs at launch, on a timer and shortly after you change something."
    },
    {
      "key": "target",
      "label": "Sync server",
      "type": "text",
      "placeholder": "user@host[:port]",
      "help": "IP or name of a machine you can SSH into (with Python 3): me@192.0.2.10, me@sync.example.com:2222 or ssh://me@host"
    },
    {
      "key": "authType",
      "label": "Log in with",
      "type": "select",
      "default": "config",
      "options": [
        {
          "label": "Automatic (ssh config, agent, default keys)",
          "value": "config"
        },
        {
          "label": "Key file",
          "value": "key"
        },
        {
          "label": "Password",
          "value": "password"
        }
      ]
    },
    {
      "key": "keyPath",
      "label": "Key file (if \"Key file\")",
      "type": "text",
      "placeholder": "~/.ssh/id_ed25519"
    },
    {
      "key": "passphrase",
      "label": "Key passphrase (if the key has one)",
      "type": "password"
    },
    {
      "key": "password",
      "label": "Server password (if \"Password\")",
      "type": "password"
    },
    {
      "key": "syncPass",
      "label": "Sync passphrase",
      "type": "password",
      "help": "Encrypts everything before it leaves this PC. Use the same one on every PC; if you lose it the synced data cannot be recovered. At least 8 characters."
    },
    {
      "key": "every",
      "label": "Sync",
      "type": "select",
      "default": "15",
      "options": [
        {
          "label": "Only when I press Sync now",
          "value": "manual"
        },
        {
          "label": "At launch",
          "value": "launch"
        },
        {
          "label": "At launch + every 5 minutes",
          "value": "5"
        },
        {
          "label": "At launch + every 15 minutes",
          "value": "15"
        },
        {
          "label": "At launch + every hour",
          "value": "60"
        }
      ]
    },
    {
      "key": "w_servers",
      "label": "Sync servers",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_secrets",
      "label": "  … including saved passwords and key passphrases (encrypted)",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_macros",
      "label": "Sync macros",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_notes",
      "label": "Sync notes",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_runbooks",
      "label": "Sync runbooks (arrive marked \"unreviewed\")",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_ipmi",
      "label": "Sync IPMI / BMC entries",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_settings",
      "label": "Sync settings (theme, terminal, notifications, startup)",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "w_hostkeys",
      "label": "Sync trusted host keys",
      "type": "checkbox",
      "default": true
    },
    {
      "key": "dir",
      "label": "Folder on the sync server",
      "type": "text",
      "default": ".connect-sync",
      "help": "Relative to your home folder there."
    },
    {
      "key": "python",
      "label": "Python command on the sync server",
      "type": "text",
      "default": "python3"
    }
  ]
}
//==== main ====
// Sync server module (main process). Runs inside Connect's module host: only the api object and a few safe built-ins are available.
//   * The "sync server" is any machine you can SSH into that has Python 3. The module logs in over SSH (api.ssh) and runs the bundled
//     sync-server.py there (it copies the script itself the first time). No daemon, no open port.
//   * Everything is encrypted here with your sync passphrase (scrypt + AES-256-GCM) BEFORE upload: the server only stores one opaque blob.
//   * Merging happens here, per item (one server, one macro, one note ...) against what this PC saw at the last sync, so edits made on
//     different PCs to different items all survive; if the same item changed on two PCs, the later change wins. Deletions are remembered 90 days.
const crypto = require('crypto');
const { promisify } = require('util');
const scrypt = promisify(crypto.scrypt);
const SERVER_VERSION = 1;
const TOMBSTONE_MS = 90 * 24 * 3600 * 1000;
const SECRET_FIELDS = ['password', 'passphrase'];
// Preferences that make sense on every PC. (Not: hardware acceleration, UI scale, Potato mode, update settings: those belong to one machine.)
const SETTING_KEYS = ['theme', 'termFont', 'termSize', 'cursor', 'autoCopy', 'rcPaste', 'notifyLong', 'notifyDrop', 'notifyBg', 'autoReconnect', 'statsEvery', 'startTab', 'autoLogin', 'fx', 'anim', 'scrollback'];
const PREFIX = { server: 'servers', macro: 'macros', note: 'notes', runbook: 'runbooks', ipmi: 'ipmi', settings: 'settings', hostkey: 'hostkeys' };
const catOf = (key) => PREFIX[key.split(':')[0]];
const WATCHED = new Set(['servers.json', 'macros.json', 'notes.json', 'runbooks.json', 'ipmi.json', 'known_hosts.json', 'settings.json']);

// ---------- helpers ----------
const stable = (v) => (Array.isArray(v) ? '[' + v.map(stable).join(',') + ']' : v && typeof v === 'object' ? '{' + Object.keys(v).sort().filter((k) => v[k] !== undefined).map((k) => JSON.stringify(k) + ':' + stable(v[k])).join(',') + '}' : JSON.stringify(v === undefined ? null : v));
const hash = (v) => crypto.createHash('sha256').update(stable(v)).digest('hex').slice(0, 32);
const clone = (v) => JSON.parse(JSON.stringify(v));

// "user@host:port", "ssh://user@host:2222", "host", "[::1]:22" -> { host, port, username }
function parseTarget(text) {
  let t = String(text || '').trim().replace(/^ssh:\/\//i, '').replace(/\/.*$/, '');
  if (!t) return null;
  let username = '', port = 0;
  const at = t.lastIndexOf('@'); if (at >= 0) { username = t.slice(0, at); t = t.slice(at + 1); }
  const m6 = /^\[([^\]]+)\](?::(\d+))?$/.exec(t);
  let host;
  if (m6) { host = m6[1]; port = +m6[2] || 0; }
  else { const m = /^([^:]+)(?::(\d+))?$/.exec(t); if (!m) return null; host = m[1]; port = +m[2] || 0; }
  if (!/^[\w.\-:%]+$/.test(host) || (username && !/^[\w.\-]+$/.test(username)) || port > 65535) return null;
  return { host, port: port || 22, username };
}
const safePath = (p, dflt) => { p = String(p || '').trim() || dflt; return /^[\w.\/~-]+$/.test(p) && !/(^|\/)\.\.(\/|$)/.test(p) ? p : null; };

// ---------- encryption (envelope the server stores) ----------
const keyCache = new Map();
async function deriveKey(pass, salt) {
  const id = salt.toString('base64') + '|' + pass;
  if (keyCache.has(id)) return keyCache.get(id);
  const k = await scrypt(pass, salt, 32, { N: 32768, r: 8, p: 1, maxmem: 128 * 1024 * 1024 });
  if (keyCache.size > 4) keyCache.clear();
  keyCache.set(id, k); return k;
}
async function seal(obj, pass, salt) {
  const key = await deriveKey(pass, salt), iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv); c.setAAD(Buffer.from('hdc-sync-v1'));
  const ct = Buffer.concat([c.update(JSON.stringify(obj), 'utf8'), c.final()]);
  return JSON.stringify({ format: 'hdc-sync', v: 1, kdf: 'scrypt-N32768-r8-p1', salt: salt.toString('base64'), iv: iv.toString('base64'), tag: c.getAuthTag().toString('base64'), ct: ct.toString('base64') });
}
async function open(text, pass) {
  let env; try { env = JSON.parse(text); } catch { throw new Error('The data on the sync server is not a Connect sync file'); }
  if (!env || env.format !== 'hdc-sync' || env.v !== 1) throw new Error('The data on the sync server is from a different version of Connect sync');
  const salt = Buffer.from(env.salt, 'base64'), key = await deriveKey(pass, salt);
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(env.iv, 'base64')); d.setAAD(Buffer.from('hdc-sync-v1')); d.setAuthTag(Buffer.from(env.tag, 'base64'));
    const obj = JSON.parse(Buffer.concat([d.update(Buffer.from(env.ct, 'base64')), d.final()]).toString('utf8'));
    return { obj, salt };
  } catch { throw Object.assign(new Error('Wrong sync passphrase (the data on the sync server could not be decrypted). Use the passphrase you chose on your first PC.'), { code: 'WRONG_PASS' }); }
}

// ---------- the merge (pure: no I/O, unit-testable) ----------
// local:  Map key -> content (undefined = not here)          remote: { key: { t, d } }  (d === null: deleted)
// state:  { key: { h, t } } what this PC saw at the last sync   returns what to upload / apply / remember
function merge({ local, remote, state, what, now, norm = (_k, d) => d, carry = (_k, l) => l }) {
  const on = (cat) => !!what[cat];
  const keys = new Set([...local.keys(), ...Object.keys(remote), ...Object.keys(state)]);
  const merged = {}, apply = {}, next = {}, stats = { pushed: 0, pulled: 0, removed: 0 };
  let upload = false;
  for (const key of keys) {
    const cat = catOf(key);
    if (!cat) { if (remote[key]) merged[key] = remote[key]; continue; }
    const R = remote[key], S = state[key];
    if (!on(cat)) { if (R) merged[key] = R; if (S) next[key] = S; continue; } // switched off: leave the server's copy alone
    const has = local.has(key), L = has ? local.get(key) : undefined;
    const hL = has ? hash(L) : null;
    const localChanged = S ? hL !== S.h : has;
    const tL = localChanged ? now : S ? S.t : 0;
    const take = (item) => { merged[key] = item; next[key] = { h: item.d == null ? null : hash(norm(key, item.d)), t: item.t }; };
    const keepLocal = () => { const item = { t: tL, d: has ? carry(key, clone(L), R && R.d) : null }; if (!has && !R) return; merged[key] = item; next[key] = { h: has ? hL : null, t: tL }; if (has || R) { upload = true; stats.pushed++; } };
    if (!R) { if (has) keepLocal(); continue; } // (an item the server lost is restored from here)
    const Rd = R.d == null ? null : norm(key, R.d), hR = Rd == null ? null : hash(Rd);
    const remoteChanged = S ? hR !== S.h : true;
    if (hL === hR) { merged[key] = R; next[key] = { h: hR, t: R.t }; continue; } // already the same
    let remoteWins;
    if (!localChanged) remoteWins = true;
    else if (!remoteChanged) remoteWins = false;
    else remoteWins = !S || R.t >= tL; // changed on both PCs: later change wins (first sync on this PC: the server's copy wins)
    if (remoteWins) {
      take(R);
      if (R.d == null) { if (has) { apply[key] = null; stats.removed++; } } else { apply[key] = Rd; stats.pulled++; }
    } else if (!has && R.d == null) take(R);
    else keepLocal();
  }
  for (const k of Object.keys(merged)) if (merged[k].d == null && now - merged[k].t > TOMBSTONE_MS) { delete merged[k]; delete next[k]; upload = true; }
  return { merged, apply, next, upload, stats };
}


// ---------- the SSH side ----------
const parseReply = (r) => { const line = String(r.out).split('\n').reverse().find((l) => l.startsWith('HDCSYNC:')); if (!line) return null; try { return JSON.parse(line.slice(8)); } catch { return null; } };

// A transport is { call(cmd, stdin) -> parsed reply, install(script), close() }.
function sshTransport(cfg) {
  const t = parseTarget(cfg.target); if (!t) throw new Error('The sync server address is not valid (use  user@host  or  user@host:port)');
  const dir = safePath(cfg.dir, '.connect-sync'), py = safePath(cfg.python, 'python3');
  if (!dir || !py) throw new Error('The remote folder or Python command contains characters that are not allowed');
  let conn = null;
  const open = async () => conn || (conn = await api.ssh.connect({ name: 'Sync server', host: t.host, port: t.port, username: t.username, authType: cfg.authType, keyPath: cfg.keyPath, password: cfg.password, passphrase: cfg.passphrase }));
  return {
    async call(cmd, stdin) {
      const c = await open();
      const r = await c.exec(`${py} ${dir}/server.py --dir ${dir} ${cmd}`, stdin, 60000);
      const j = parseReply(r);
      if (!j) return { _missing: true, code: r.code, err: (r.err || r.out || '').trim().slice(0, 300) };
      return j;
    },
    async install(script) {
      const c = await open();
      const r = await c.exec(`umask 077 && mkdir -p ${dir} && cat > ${dir}/server.py.new && mv ${dir}/server.py.new ${dir}/server.py`, script, 30000);
      if (r.code !== 0) throw new Error('Could not copy the sync script to the sync server: ' + ((r.err || r.out).trim().slice(0, 200) || 'exit ' + r.code));
    },
    close() { if (conn) { conn.close(); conn = null; } },
  };
}

// Make sure the script is on the server and current. Returns the server's ping reply.
async function ensureServer(tx, script) {
  let p = await tx.call('ping');
  if (!p || p._missing || !p.ok || (p.version || 0) < SERVER_VERSION) {
    if (p && p._missing && /python3?: (command )?not found|is not recognized/i.test(p.err) && !/server\.py/.test(p.err)) throw new Error('Python 3 is not installed on the sync server (or the Python command in the module settings is wrong).');
    await tx.install(script);
    p = await tx.call('ping');
  }
  if (!p || p._missing) throw new Error('The sync script would not run on the server' + (p && p.err ? ': ' + p.err : '') + '. It needs Python 3.');
  if (!p.ok) throw new Error(p.error || 'The sync script reported an error');
  return p;
}

// ---------- local data (through the app's data API) ----------
const store = (() => {
  const arr = (n) => { const v = api.data.read(n, []); return Array.isArray(v) ? v : []; };
  const obj = (n) => { const v = api.data.read(n, {}); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; };
  const okId = (x) => x && typeof x === 'object' && typeof x.id === 'string' && x.id && x.id.length <= 80;
  const strip = (o, keys) => { const c = { ...o }; for (const k of keys) delete c[k]; return c; };
  const { enc, dec } = api.secret;
  function collect(what) {
    const m = new Map();
    if (what.servers) for (const s of arr('servers.json')) { if (!okId(s) || s.id === 'local') continue; const c = { ...s }; for (const k of SECRET_FIELDS) { if (what.secrets) c[k] = dec(c[k]); else delete c[k]; } m.set('server:' + s.id, c); }
    if (what.macros) for (const x of arr('macros.json')) if (okId(x)) m.set('macro:' + x.id, x);
    if (what.notes) for (const x of arr('notes.json')) if (okId(x)) m.set('note:' + x.id, x);
    if (what.runbooks) for (const x of arr('runbooks.json')) if (okId(x)) m.set('runbook:' + x.id, strip(x, ['imported']));
    if (what.ipmi) { const all = obj('ipmi.json'); for (const h of Object.keys(all)) { const e = all[h]; if (!e || typeof e !== 'object') continue; const c = strip(e, ['pass']); if (what.secrets && e.pass) c.password = dec(e.pass); m.set('ipmi:' + h, c); } }
    if (what.settings) { const s = api.settings.get(), c = {}; for (const k of SETTING_KEYS) if (s[k] !== undefined) c[k] = s[k]; if (Object.keys(c).length) m.set('settings:all', c); }
    if (what.hostkeys) { const h = obj('known_hosts.json'); for (const id of Object.keys(h)) { const v = Array.isArray(h[id]) ? h[id] : h[id] ? [h[id]] : []; if (v.length) m.set('hostkey:' + id, [...v].sort()); } }
    return m;
  }

  // changes: { key: content | null }. Returns the categories that changed (so the window can refresh).
  function apply(changes, what) {
    const touched = new Set(), by = (cat) => Object.entries(changes).filter(([k]) => catOf(k) === cat).map(([k, d]) => [k.slice(k.indexOf(':') + 1), d]);
    const listCat = (cat, file, build) => {
      const ch = by(cat); if (!ch.length) return;
      const all = arr(file);
      for (const [id, d] of ch) {
        const i = all.findIndex((x) => x && x.id === id);
        if (d === null) { if (i >= 0) all.splice(i, 1); continue; }
        if (!d || typeof d !== 'object' || d.id !== id) continue;
        const v = build(d, i >= 0 ? all[i] : null);
        if (i >= 0) all[i] = v; else all.push(v);
      }
      api.data.write(file, all); touched.add(cat);
    };
    listCat('servers', 'servers.json', (d, cur) => { const c = { ...d }; for (const k of SECRET_FIELDS) { const v = what.secrets ? d[k] : cur ? dec(cur[k]) : ''; c[k] = enc(typeof v === 'string' ? v : ''); } return c; });
    listCat('macros', 'macros.json', (d) => d);
    listCat('notes', 'notes.json', (d) => d);
    listCat('runbooks', 'runbooks.json', (d) => ({ ...d, imported: true })); // arrives "unreviewed", like a runbook imported from a file
    const ip = by('ipmi');
    if (ip.length) {
      const all = obj('ipmi.json');
      for (const [h, d] of ip) {
        if (d === null) { delete all[h]; continue; }
        if (!d || typeof d !== 'object') continue;
        const cur = all[h], c = strip(d, ['password']);
        c.pass = what.secrets && typeof d.password === 'string' ? enc(d.password) : (cur && cur.pass) || '';
        all[h] = c;
      }
      api.data.write('ipmi.json', all); touched.add('ipmi');
    }
    const st = by('settings');
    if (st.length && st[0][1]) { const patch = {}; for (const k of SETTING_KEYS) if (st[0][1][k] !== undefined) patch[k] = st[0][1][k]; api.settings.set(patch); touched.add('settings'); }
    const hk = by('hostkeys');
    if (hk.length) { const all = obj('known_hosts.json'); for (const [id, d] of hk) { if (d === null) delete all[id]; else if (Array.isArray(d)) all[id] = d.filter((x) => typeof x === 'string'); } api.data.write('known_hosts.json', all); touched.add('hostkeys'); }
    return [...touched];
  }
  return { collect, apply };
})();

// ---------- config, state, one sync ----------
const what = (c) => ({ servers: c.w_servers, secrets: c.w_secrets, macros: c.w_macros, notes: c.w_notes, runbooks: c.w_runbooks, ipmi: c.w_ipmi, settings: c.w_settings, hostkeys: c.w_hostkeys });
const targetId = (c) => [c.target, c.dir].join('|');
const SYNC_PASS_MIN = 8;
function validate(c) {
  if (!c.target) throw new Error('Enter the sync server address first (module settings).');
  if (!parseTarget(c.target)) throw new Error('That sync server address is not valid. Use  user@host  or  user@host:port  (an IP or a name).');
  if (!safePath(c.dir, '.connect-sync') || !safePath(c.python, 'python3')) throw new Error('The remote folder / Python command may only contain letters, digits and . / ~ _ -');
  if (!c.syncPass) throw new Error('Enter a sync passphrase first (module settings).');
  if (c.syncPass.length < SYNC_PASS_MIN) throw new Error('The sync passphrase must be at least 8 characters.');
}
const saved = () => api.store.get();
let status = (() => { const s = saved(); return { running: false, last: s.lastSync || 0, ok: s.lastOk !== false, error: s.lastError || '', stats: s.stats || null, rev: s.rev || 0 }; })();
const setStatus = (p) => { status = { ...status, ...p }; api.emit('status', status); };

let running = null, again = false, applying = false;
const script = () => api.asset('sync-server.py');

async function syncOnce() {
  const c = api.config(); validate(c);
  const w = what(c), tx = sshTransport(c);
  try {
    await ensureServer(tx, script());
    for (let attempt = 0; attempt < 4; attempt++) {
      const g = await tx.call('get');
      if (!g || !g.ok) throw new Error((g && g.error) || 'The sync server did not answer correctly');
      let remote = {}, salt = null;
      if (g.data) { const o = await open(g.data, c.syncPass); remote = o.obj && o.obj.items && typeof o.obj.items === 'object' ? o.obj.items : {}; salt = o.salt; }
      const sv = saved(), state = sv.target === targetId(c) && sv.items ? sv.items : {}, now = Date.now();
      const local = store.collect(w);
      const strip = (key, d) => { if (w.secrets || d == null || typeof d !== 'object') return d; const x = { ...d }; for (const k of SECRET_FIELDS) delete x[k]; if (key.startsWith('ipmi:')) delete x.password; return x; };
      const carry = (key, l, rd) => { if (w.secrets || !rd || typeof rd !== 'object') return l; if (key.startsWith('server:')) for (const k of SECRET_FIELDS) if (rd[k]) l[k] = rd[k]; if (key.startsWith('ipmi:') && rd.password) l.password = rd.password; return l; };
      const r = merge({ local, remote, state, what: w, now, norm: strip, carry });
      let rev = g.rev;
      if (r.upload || !g.data) {
        const env = await seal({ v: 1, items: r.merged, written: now, by: api.hostname }, c.syncPass, salt || crypto.randomBytes(16));
        const p = await tx.call(`put --base ${g.rev}`, env);
        if (p && p.conflict) continue; // another PC pushed meanwhile: read it again and merge again
        if (!p || !p.ok) throw new Error((p && p.error) || 'The sync server refused the upload');
        rev = p.rev;
      }
      let touched = [];
      if (Object.keys(r.apply).length) { applying = true; try { touched = store.apply(r.apply, w); } finally { applying = false; } }
      api.store.set({ target: targetId(c), items: r.next, rev, lastSync: Date.now(), lastOk: true, lastError: '', stats: r.stats });
      if (touched.length) api.emit('applied', { cats: touched });
      return { rev, ...r.stats };
    }
    throw new Error('The sync server kept changing while syncing. Try again.');
  } finally { tx.close(); }
}

function run(reason) {
  if (running) { again = true; return running; }
  setStatus({ running: true, error: '' });
  return (running = (async () => {
    try {
      const r = await syncOnce();
      api.log(`sync ok (${reason}): rev ${r.rev}, sent ${r.pushed}, received ${r.pulled}, removed ${r.removed}`);
      setStatus({ running: false, ok: true, error: '', last: Date.now(), rev: r.rev, stats: { pushed: r.pushed, pulled: r.pulled, removed: r.removed } });
      return { ok: true, ...r };
    } catch (e) {
      const msg = String(e && e.message ? e.message : e);
      api.log(`sync failed (${reason}): ${msg}`);
      try { api.store.set({ ...saved(), lastOk: false, lastError: msg }); } catch {}
      setStatus({ running: false, ok: false, error: msg });
      return { ok: false, error: msg, wrongPass: !!(e && e.code === 'WRONG_PASS') };
    } finally { running = null; if (again) { again = false; debounce(); } }
  })());
}

// ---------- when to sync: at launch, on a timer, and shortly after a synced file changes on this PC ----------
let timer = null, deb = null, first = null;
const active = () => { const c = api.config(); return !!(c.on && c.target && c.syncPass); };
function schedule() {
  clearInterval(timer); timer = null;
  const c = api.config(); if (!active() || !/^\d+$/.test(String(c.every))) return;
  timer = setInterval(() => { if (active()) run('timer'); }, +c.every * 60000);
}
function debounce() { clearTimeout(deb); if (!active() || api.config().every === 'manual') return; deb = setTimeout(() => run('change'), 15000); }
api.data.onChange((name) => { if (!applying && WATCHED.has(name)) debounce(); });
api.onConfig(() => { schedule(); });
schedule();
first = setTimeout(() => { if (active() && api.config().every !== 'manual') run('launch'); }, 8000);
api.onUnload(() => { clearInterval(timer); clearTimeout(deb); clearTimeout(first); });

// ---------- calls from the window ----------
api.handle('status', () => ({ status, configured: active() }));
api.handle('run', () => run('manual'));
api.handle('test', async () => { // "Save & test" in the module settings: reaches the server, installs / updates the script
  const c = api.config(); validate(c);
  const tx = sshTransport(c);
  try {
    const p = await ensureServer(tx, script()), s = await tx.call('status');
    return `Sync server is ready (Python ${p.python}, folder ${p.dir}). ` + (s && s.rev ? `It holds revision ${s.rev}.` : 'It is empty: the first sync uploads this PC.');
  } finally { tx.close(); }
});
api.handle('saveScript', async () => { const p = await api.saveText('connect-sync-server.py', script()); return p || ''; });
//==== renderer ====
// Sync server module (window side): a "Sync server" page in Settings, and a refresh of the lists when another PC's changes arrive.
let st = { running: false, last: 0, ok: true, error: '', stats: null }, configured = false;
const ago = (t) => { if (!t) return 'never'; const s = Math.max(0, (Date.now() - t) / 1000); return s < 60 ? 'just now' : s < 3600 ? Math.round(s / 60) + ' min ago' : s < 86400 ? Math.round(s / 3600) + ' h ago' : new Date(t).toLocaleString(); };
const errText = (e) => String(e || '').replace(/^Error invoking remote method '[^']*': (Error: )?/, '');
let box = null, line = null, run = null;
function draw() {
  if (!line) return;
  run.disabled = !!st.running;
  line.style.color = '';
  if (st.running) { line.textContent = 'Syncing…'; return; }
  if (st.error) { line.textContent = 'Last sync failed: ' + st.error; line.style.color = 'var(--bad)'; return; }
  if (!configured) { line.textContent = 'Not set up yet: press "Settings…", enter your sync server and passphrase, and turn on "Keep this PC in sync".'; return; }
  const t = st.stats ? ` (sent ${st.stats.pushed}, received ${st.stats.pulled}, removed ${st.stats.removed})` : '';
  line.textContent = st.last ? `Last synced ${ago(st.last)}${t}.` : 'Ready. Press "Sync now".';
}
async function load() { try { const r = await Mod.call('status'); st = r.status; configured = r.configured; } catch {} draw(); }
Mod.settingsPage({
  id: 'sync', label: 'Sync', icon: 'sync',
  render(b) {
    box = b;
    const p = document.createElement('p'); p.className = 'muted'; p.style.margin = '0 0 10px';
    p.textContent = 'Keeps several PCs the same through your own SSH server (any machine with Python 3): servers, macros, notes, runbooks, IPMI entries, settings and trusted host keys. Everything is encrypted on this PC with your sync passphrase before upload, so the server only stores unreadable data. SSH key files are not copied: put the same keys on each PC.';
    line = document.createElement('div'); line.style.margin = '10px 0';
    const row = document.createElement('div'); row.className = 'row'; row.style.flexWrap = 'wrap';
    const mk = (label, fn, cls) => { const x = document.createElement('button'); x.textContent = label; if (cls) x.className = cls; x.onclick = fn; row.append(x); return x; };
    mk('Settings…', () => Mod.openConfig());
    run = mk('Sync now', async () => {
      const r = await Mod.call('run'); await load();
      if (r.ok) Mod.toast('Synced'); else line.textContent = 'Last sync failed: ' + r.error, line.style.color = 'var(--bad)';
    }, 'primary');
    mk('Save server script…', async () => { try { const f = await Mod.call('saveScript'); if (f) line.textContent = `Saved ${f}. To install by hand, copy it to the sync server and run:  python3 connect-sync-server.py ping`; } catch (e) { line.textContent = errText(e.message); } });
    b.append(p, row, line); draw();
  },
  show: load,
});
Mod.on('status', (s) => { st = s; draw(); });
Mod.on('applied', (d) => { const c = (d && d.cats) || []; Mod.refreshData(c); Mod.toast('Synced changes from another PC: ' + c.join(', ')); });
load();
//==== asset sync-server.py ====
#!/usr/bin/env python3
"""Connect sync server (v1).

A tiny, dependency-free storage helper for Connect's "Sync server" feature. There is no daemon and no open port:
the Connect app logs in over SSH and runs this script, one command per call. The server stores ONE opaque blob
(the app encrypts everything with your sync passphrase before it leaves your PC), so this machine never sees your
servers, notes or passwords in readable form.

Commands (the app uses these; you can run them by hand too):
    ping               check that the script works      -> {"ok":true,"version":1,...}
    status             revision, size, last update, kept history
    get                print the stored blob            -> {"ok":true,"rev":N,"data":"..."}
    put --base N       read a blob on stdin, store it as revision N+1 (refused if the stored revision is no longer N)
    reset [--yes]      (by hand only) wipe everything stored here

Options:  --dir DIR    where the data lives (default: ~/.connect-sync)   --keep N   old revisions to keep (default 10)

Every reply is one line:  HDCSYNC:{json}   (a prefix, so login banners and shell noise can't confuse the app).
Requires Python 3.6+. Install: the app can copy this file for you (Settings > Sync > "Set up server"), or put it anywhere and run it.
"""
import argparse, fcntl, json, os, sys, time

VERSION = 1
MAX_BYTES = 64 * 1024 * 1024


def reply(obj, code=0):
    sys.stdout.write("HDCSYNC:" + json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    sys.exit(code)


def fail(msg, **extra):
    reply(dict(ok=False, error=msg, **extra), 1)


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd", nargs="?", default="ping")
    ap.add_argument("--dir", default=os.path.join("~", ".connect-sync"))
    ap.add_argument("--base", type=int, default=0)
    ap.add_argument("--keep", type=int, default=10)
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()
    if a.help:
        print(__doc__)
        return
    root = os.path.abspath(os.path.expanduser(a.dir))
    hist = os.path.join(root, "history")
    os.umask(0o077)
    os.makedirs(hist, mode=0o700, exist_ok=True)
    cur = os.path.join(root, "current.json")      # {"rev":N,"updated":T}
    blob = os.path.join(root, "blob")            # the opaque data
    lockf = open(os.path.join(root, "lock"), "a+")
    fcntl.flock(lockf, fcntl.LOCK_EX)            # one command at a time, so two PCs can never interleave a write

    def meta():
        try:
            with open(cur) as f:
                m = json.load(f)
            return int(m.get("rev", 0)), float(m.get("updated", 0))
        except Exception:
            return 0, 0.0

    rev, updated = meta()

    if a.cmd == "ping":
        reply(dict(ok=True, version=VERSION, python=sys.version.split()[0], dir=root, rev=rev))
    elif a.cmd == "status":
        size = os.path.getsize(blob) if os.path.exists(blob) else 0
        reply(dict(ok=True, version=VERSION, rev=rev, updated=updated, size=size, history=len(os.listdir(hist)), dir=root))
    elif a.cmd == "get":
        data = None
        if rev and os.path.exists(blob):
            with open(blob, "r", encoding="utf-8") as f:
                data = f.read()
        reply(dict(ok=True, version=VERSION, rev=rev, updated=updated, data=data))
    elif a.cmd == "put":
        if a.base != rev:
            reply(dict(ok=False, conflict=True, rev=rev, error="the server has a newer revision"), 2)
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            fail("data is too large")
        try:
            text = raw.decode("utf-8")
            json.loads(text)                     # must at least be a JSON document (the app's encrypted envelope)
        except Exception:
            fail("data is not valid JSON")
        new = rev + 1
        if os.path.exists(blob):                 # keep the previous revision, in case a PC ever pushes something bad
            os.replace(blob, os.path.join(hist, "%08d.json" % rev))
        tmp = blob + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, blob)
        now = time.time()
        with open(cur + ".tmp", "w") as f:
            json.dump(dict(rev=new, updated=now), f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(cur + ".tmp", cur)
        for name in sorted(os.listdir(hist))[:-max(a.keep, 1)]:
            try:
                os.remove(os.path.join(hist, name))
            except OSError:
                pass
        reply(dict(ok=True, rev=new, updated=now))
    elif a.cmd == "reset":
        if not a.yes and (not sys.stdin.isatty() or input("Delete ALL synced data in %s? Type yes: " % root).strip() != "yes"):
            fail("cancelled (add --yes to confirm)")
        for d, _, files in os.walk(root):
            for n in files:
                if n != "lock":
                    os.remove(os.path.join(d, n))
        reply(dict(ok=True, rev=0))
    else:
        fail("unknown command: " + a.cmd)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:                        # always answer in the protocol, never with a traceback
        reply(dict(ok=False, error="%s: %s" % (type(e).__name__, e)), 1)
