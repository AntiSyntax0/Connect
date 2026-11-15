//==== module ====
{
  "id": "arr",
  "name": "Arr stack",
  "description": "A sidebar for the *arr suite: library statistics and health of Sonarr / Radarr / Lidarr / Readarr / Prowlarr, live download status (qBittorrent, SABnzbd and the arr queues), who is logged in and watching on Plex / Jellyfin / Emby, Docker and host statistics over SSH, and search + request of movies and shows into Sonarr / Radarr (with optional TMDB metadata). Uses each app's API, directly or through your saved SSH logins, and can detect services and their API keys from Docker.",
  "version": "0.1.1",
  "minApi": 4,
  "permissions": [
    "ssh",
    "data"
  ],
  "config": [
    {
      "key": "tmdbKey",
      "label": "TMDB API key (optional)",
      "type": "password",
      "placeholder": "v3 API key or v4 read access token",
      "help": "Free from themoviedb.org (Settings > API). When set, search uses TMDB for results and posters; without it, Sonarr and Radarr's own lookup is used."
    },
    {
      "key": "interval",
      "label": "Refresh every (seconds)",
      "type": "number",
      "default": 5,
      "help": "How often the open sidebar refreshes downloads and who is watching (3 to 60). Docker statistics refresh at half that rate."
    }
  ]
}
//==== main ====
// Arr stack (main process). Talks to Sonarr / Radarr / Lidarr / Readarr / Prowlarr, qBittorrent / SABnzbd and Plex / Jellyfin / Emby over their HTTP APIs,
// either straight from this PC ("direct") or through one of your saved SSH servers (curl runs on the server, for services that are only reachable there),
// and reads Docker + host statistics over SSH. API keys, tokens and passwords are stored encrypted and never reach the window.
const http = require('http'), https = require('https');
const sq = (v) => "'" + String(v).replace(/'/g, "'\\''") + "'";
const rid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
const clip = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '\n… (cut)' : s; };
const num = (v) => Number(v) || 0;
const pad = (n) => String(n).padStart(2, '0');

const KINDS = {
  sonarr: { label: 'Sonarr', role: 'manager', v: 'v3', port: 8989, q: { includeSeries: true, includeEpisode: true } },
  radarr: { label: 'Radarr', role: 'manager', v: 'v3', port: 7878, q: { includeMovie: true } },
  lidarr: { label: 'Lidarr', role: 'manager', v: 'v1', port: 8686, q: { includeArtist: true, includeAlbum: true } },
  readarr: { label: 'Readarr', role: 'manager', v: 'v1', port: 8787, q: { includeAuthor: true, includeBook: true } },
  prowlarr: { label: 'Prowlarr', role: 'indexer', v: 'v1', port: 9696, q: {} },
  qbittorrent: { label: 'qBittorrent', role: 'download', port: 8080 },
  sabnzbd: { label: 'SABnzbd', role: 'download', port: 8080 },
  plex: { label: 'Plex', role: 'media', port: 32400 },
  jellyfin: { label: 'Jellyfin', role: 'media', port: 8096 },
  emby: { label: 'Emby', role: 'media', port: 8096 },
};
const DETECT = [['prowlarr', /prowlarr/i], ['sonarr', /sonarr/i], ['radarr', /radarr/i], ['lidarr', /lidarr/i], ['readarr', /readarr/i], ['qbittorrent', /qbittorrent|qbit/i], ['sabnzbd', /sabnzbd/i], ['jellyfin', /jellyfin/i], ['emby', /emby/i], ['plex', /plex|pms-docker/i]];
const ARR_RE = /(sonarr|radarr|lidarr|readarr|prowlarr|bazarr|whisparr|qbittorrent|sabnzbd|nzbget|transmission|deluge|rtorrent|plex|jellyfin|emby|tautulli|overseerr|jellyseerr|requestrr|jackett|flaresolverr|byparr|unpackerr|recyclarr|gluetun|autobrr|cross-seed|huntarr|cleanuparr|notifiarr|maintainerr|kometa|tdarr|profilarr)/i;

// ---------------------------------------------------------------- stored setup
const st0 = api.store.get();
let instances = (st0.instances || []).filter((i) => i && i.id && KINDS[i.kind]);
let hosts = (st0.hosts || []).filter((h) => h && h.id).map((h) => ({ id: h.id, sudo: ['', 'nopw', 'pw'].includes(h.sudo) ? h.sudo : '', all: !!h.all }));
const saveAll = () => api.store.set({ instances, hosts });
const dec = (v) => (v ? api.secret.dec(v) : '');
const savedServers = () => (api.data.read('servers.json', []) || []).filter((x) => x && (!x.type || x.type === 'ssh'));
const serverOf = (id) => savedServers().find((x) => x.id === id);
const srvName = (id) => { const x = serverOf(id); return x ? x.name || x.host : '(removed server)'; };
const instOf = (id) => { const i = instances.find((x) => x.id === String(id)); if (!i) throw new Error('That service is not set up'); return i; };
const pub = (i) => ({ id: i.id, kind: i.kind, name: i.name, url: i.url, transport: i.transport, host: i.host || '', hostName: i.host ? srvName(i.host) : '', insecure: !!i.insecure, hasKey: !!i.key, user: i.user || '', hasPass: !!i.pass });

// ---------------------------------------------------------------- SSH connections (shared by API-over-SSH and Docker)
const conns = new Map();
function connFor(id) {
  if (conns.has(id)) return conns.get(id);
  const x = serverOf(id); if (!x) throw new Error('That server is no longer in your list');
  const pr = api.ssh.connect({ host: x.host, port: x.port, username: x.username, authType: x.authType, jumpId: x.jumpId || '', keyPath: x.keyPath, password: api.secret.dec(x.password), passphrase: api.secret.dec(x.passphrase), name: x.name });
  conns.set(id, pr); pr.catch(() => { if (conns.get(id) === pr) conns.delete(id); });
  return pr;
}
const dropConn = (id) => { const pr = conns.get(id); conns.delete(id); if (pr) pr.then((c) => c.close(), () => {}); };
async function conn(id) { try { return await connFor(id); } catch { dropConn(id); return connFor(id); } }
async function sshExec(id, cmd, stdin, ms) { const c = await conn(id); try { return await c.exec(cmd, stdin, ms); } catch (e) { if (!/No answer/.test(e.message)) dropConn(id); throw e; } }
api.onUnload(() => { for (const id of [...conns.keys()]) dropConn(id); });

// ---------------------------------------------------------------- HTTP: direct from this PC
const baseOf = (i) => String(i.url || '').trim().replace(/\/+$/, '');
function nice(e, host) {
  const c = e && e.code, m = String((e && e.message) || e);
  if (c === 'ECONNREFUSED') return new Error(`Connection refused by ${host}: is the service running, and is the port right?`);
  if (c === 'ENOTFOUND' || c === 'EAI_AGAIN') return new Error(`Cannot find ${host}: check the address.`);
  if (c === 'ETIMEDOUT' || c === 'EHOSTUNREACH' || c === 'ENETUNREACH') return new Error(`${host} is not reachable from this computer. If it is only reachable from the server, set "Reach it" to "through an SSH server".`);
  if (/SELF_SIGNED|UNABLE_TO_VERIFY|CERT_/.test(String(c))) return new Error(`The certificate of ${host} is not trusted. Turn on "Accept a self-signed certificate" for this service.`);
  return e instanceof Error ? e : new Error(m);
}
function viaDirect(inst, spec) {
  return new Promise((resolve, reject) => {
    let u; try { u = new URL(baseOf(inst) + spec.path); if (!/^https?:$/.test(u.protocol)) throw 0; } catch { return reject(new Error('The address of this service is not a valid http(s) URL')); }
    const lib = u.protocol === 'https:' ? https : http, headers = { 'User-Agent': 'Connect-arr', Accept: 'application/json', ...spec.headers };
    if (spec.body != null) headers['Content-Length'] = Buffer.byteLength(spec.body);
    const ms = spec.ms || 15000;
    const r = lib.request(u, { method: spec.method || 'GET', headers, rejectUnauthorized: !inst.insecure, timeout: ms }, (res) => {
      const chunks = []; let n = 0;
      res.on('data', (c) => { n += c.length; if (n > 40e6) { r.destroy(new Error('The answer is too large')); return; } chunks.push(c); });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', (e) => reject(nice(e, u.host)));
    });
    r.on('timeout', () => r.destroy(new Error(`No answer from ${u.host} within ${Math.round(ms / 1000)} s`)));
    r.on('error', (e) => reject(nice(e, u.host)));
    if (spec.body != null) r.write(spec.body);
    r.end();
  });
}
// ---------------------------------------------------------------- HTTP: through an SSH server (curl on the server; secrets go over stdin, never on a command line)
const cfgEsc = (s) => String(s).replace(/[\\"]/g, '\\$&').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t');
function curlCfg(inst, spec, last) {
  const L = ['silent', 'show-error', 'max-time = ' + Math.round((spec.ms || 15000) / 1000), `url = "${cfgEsc(baseOf(inst) + spec.path)}"`, `request = "${spec.method || 'GET'}"`];
  if (inst.insecure) L.push('insecure');
  for (const [k, v] of Object.entries({ Accept: 'application/json', ...spec.headers })) L.push(`header = "${cfgEsc(k + ': ' + v)}"`);
  if (spec.body != null) L.push(`data-binary = "${cfgEsc(spec.body)}"`);
  if (last) L.push('write-out = "\\n@@HTTP:%{http_code}"');
  return L.join('\n');
}
async function viaSsh(inst, spec, login) {
  if (!inst.host) throw new Error('No SSH server is chosen for this service');
  const t1 = 'CFG' + rid() + 'A', t2 = 'CFG' + rid() + 'B';
  let s = `command -v curl >/dev/null 2>&1 || { echo '@@NOCURL'; exit 0; }\nJ=$(mktemp 2>/dev/null || echo /tmp/.arr$$); trap 'rm -f "$J"' EXIT\n`;
  if (login) s += `L=$(curl -K - -c "$J" <<'${t1}'\n${curlCfg(inst, login, false)}\n${t1}\n)\ncase "$L" in Ok*) ;; *) echo '@@LOGINFAIL'; exit 0;; esac\n`;
  s += `curl -K - -b "$J" -c "$J" <<'${t2}'\n${curlCfg(inst, spec, true)}\n${t2}\n`;
  const r = await sshExec(inst.host, '/bin/sh -s', s, (spec.ms || 15000) + 15000);
  if (r.out.includes('@@NOCURL')) throw new Error('curl is not installed on ' + srvName(inst.host));
  if (r.out.includes('@@LOGINFAIL')) throw new Error('qBittorrent rejected the user name / password, or cannot be reached from ' + srvName(inst.host) + (r.err ? ': ' + clip(r.err.trim(), 200) : ''));
  const m = /\n?@@HTTP:(\d{3})\s*$/.exec(r.out);
  if (!m) throw new Error(clip((r.err || r.out).trim(), 300) || 'No answer');
  return { status: +m[1], headers: {}, text: r.out.slice(0, m.index) };
}
const request = (inst, spec) => (inst.transport === 'ssh' ? viaSsh(inst, spec) : viaDirect(inst, spec));

// qBittorrent: cookie login (direct), or login + request in one SSH script
const qCookie = new Map();
const qLoginSpec = (inst) => ({ method: 'POST', path: '/api/v2/auth/login', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Referer: baseOf(inst) }, body: new URLSearchParams({ username: inst.user || '', password: dec(inst.pass) }).toString() });
async function qbLogin(inst) {
  const r = await viaDirect(inst, qLoginSpec(inst));
  if (r.status === 403) throw new Error('qBittorrent has banned this computer after failed logins: wait a while or check the user name / password');
  if (!/^Ok/i.test(r.text.trim())) throw new Error('qBittorrent rejected the user name or password');
  const ck = [].concat(r.headers['set-cookie'] || []).map((c) => c.split(';')[0]).join('; ');
  qCookie.set(inst.id, ck); return ck;
}
async function qb(inst, spec) {
  if (inst.transport === 'ssh') return viaSsh(inst, spec, qLoginSpec(inst));
  for (let tries = 0; ; tries++) {
    const ck = qCookie.has(inst.id) ? qCookie.get(inst.id) : await qbLogin(inst);
    const r = await viaDirect(inst, { ...spec, headers: { ...spec.headers, Cookie: ck, Referer: baseOf(inst) } });
    if ((r.status === 403 || r.status === 401) && tries === 0) { qCookie.delete(inst.id); continue; }
    return r;
  }
}
const errMsg = (r) => { let m = ''; try { const j = JSON.parse(r.text); m = Array.isArray(j) ? j.map((x) => x.errorMessage || x.message).filter(Boolean).join('; ') : j.message || j.error || j.errorMessage || ''; } catch {} return m || clip(r.text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim(), 200); };

// One authenticated API call. o: { query, json, text }
async function call(inst, method, path, o = {}) {
  const K = KINDS[inst.kind], key = dec(inst.key), headers = {}, q = { ...(o.query || {}) };
  if (K.v) headers['X-Api-Key'] = key;
  else if (inst.kind === 'plex') headers['X-Plex-Token'] = key;
  else if (inst.kind === 'jellyfin' || inst.kind === 'emby') { headers['X-Emby-Token'] = key; headers.Authorization = `MediaBrowser Token="${key}"`; }
  else if (inst.kind === 'sabnzbd') { q.apikey = key; q.output = 'json'; }
  const spec = { method, path: (K.v ? `/api/${K.v}` : '') + path, headers, ms: o.ms };
  if (Object.keys(q).length) spec.path += '?' + new URLSearchParams(q).toString();
  if (o.json !== undefined) { spec.body = JSON.stringify(o.json); headers['Content-Type'] = 'application/json'; }
  const r = await (inst.kind === 'qbittorrent' ? qb(inst, spec) : request(inst, spec));
  if (r.status === 401 || r.status === 403) throw new Error(`${K.label} rejected the API key / login (${r.status})`);
  if (r.status === 404 && !o.soft404) throw new Error(`${K.label}: ${path} not found (404). Is the address right, with its URL base if it has one?`);
  if (r.status >= 400) { const e = new Error(`${K.label} ${r.status}: ${errMsg(r)}`); e.status = r.status; throw e; }
  if (o.text) return r.text;
  if (!r.text.trim()) return null;
  try { return JSON.parse(r.text); } catch { throw new Error(`${K.label} did not answer with JSON (wrong address or port?): ${clip(r.text.replace(/\s+/g, ' '), 100)}`); }
}
const soft = (p) => p.catch(() => null);

// ---------------------------------------------------------------- snapshots per service
const lib = new Map(), libIds = new Map(); // inst id -> { at, stats, disks, wanted } / { tmdb:Set, tvdb:Set }
const itemTitle = (k, r) => {
  const s = r.series, e = r.episode, m = r.movie, a = r.artist, al = r.album, au = r.author, b = r.book;
  if (k === 'sonarr' && s) return { t: s.title + (e ? ` S${pad(e.seasonNumber)}E${pad(e.episodeNumber)}` : ''), sub: e && e.title ? e.title : '' };
  if (k === 'radarr' && m) return { t: m.title + (m.year ? ` (${m.year})` : ''), sub: '' };
  if (k === 'lidarr' && a) return { t: a.artistName, sub: al ? al.title : '' };
  if (k === 'readarr' && au) return { t: au.authorName, sub: b ? b.title : '' };
  return { t: r.title || '(unknown)', sub: '' };
};
const queueItem = (inst, r) => {
  const n = itemTitle(inst.kind, r), size = num(r.size), left = num(r.sizeleft), msgs = (r.statusMessages || []).flatMap((x) => [x.title, ...(x.messages || [])]).filter(Boolean);
  return { src: inst.id, srcName: inst.name, title: n.t, sub: n.sub, release: r.title || '', size, left, pct: size ? Math.max(0, Math.min(100, (1 - left / size) * 100)) : 0, eta: r.timeleft || '', state: r.trackedDownloadState || r.status || '', status: r.trackedDownloadStatus || 'ok', msg: clip([r.errorMessage, ...msgs].filter(Boolean).join('\n'), 400), proto: r.protocol || '', client: r.downloadClient || '', indexer: r.indexer || '' };
};
async function libFor(inst, force) {
  const c = lib.get(inst.id); if (c && !force && Date.now() - c.at < 90000) return c;
  const k = inst.kind, out = { at: Date.now(), stats: [], disks: [], wanted: null }, ids = { tmdb: new Set(), tvdb: new Set() };
  const [disk, wanted] = await Promise.all([soft(call(inst, 'GET', '/diskspace')), k === 'prowlarr' ? null : soft(call(inst, 'GET', '/wanted/missing', { query: { page: 1, pageSize: 1, monitored: true } }))]);
  const seen = new Set(); for (const d of disk || []) { if (!d.path || seen.has(d.path)) continue; seen.add(d.path); out.disks.push({ path: d.path, label: d.label || '', free: num(d.freeSpace), total: num(d.totalSpace) }); }
  if (wanted && typeof wanted.totalRecords === 'number') out.wanted = wanted.totalRecords;
  try {
    if (k === 'sonarr') {
      const l = (await call(inst, 'GET', '/series')) || []; let eps = 0, have = 0, size = 0, mon = 0, ended = 0;
      for (const s of l) { const x = s.statistics || {}; eps += num(x.episodeCount); have += num(x.episodeFileCount); size += num(x.sizeOnDisk); if (s.monitored) mon++; if (s.status === 'ended') ended++; if (s.tvdbId) ids.tvdb.add(s.tvdbId); if (s.tmdbId) ids.tmdb.add(s.tmdbId); }
      out.stats = [{ l: 'Series', v: l.length }, { l: 'Monitored', v: mon }, { l: 'Ended', v: ended }, { l: 'Episodes', v: `${have} / ${eps}` }, { l: 'On disk', b: size }];
    } else if (k === 'radarr') {
      const l = (await call(inst, 'GET', '/movie')) || []; let have = 0, size = 0, mon = 0;
      for (const m of l) { if (m.hasFile) have++; size += num(m.sizeOnDisk); if (m.monitored) mon++; if (m.tmdbId) ids.tmdb.add(m.tmdbId); }
      out.stats = [{ l: 'Movies', v: l.length }, { l: 'Monitored', v: mon }, { l: 'Downloaded', v: have }, { l: 'On disk', b: size }];
    } else if (k === 'lidarr') {
      const l = (await call(inst, 'GET', '/artist')) || []; let al = 0, tr = 0, size = 0;
      for (const a of l) { const x = a.statistics || {}; al += num(x.albumCount); tr += num(x.trackFileCount); size += num(x.sizeOnDisk); }
      out.stats = [{ l: 'Artists', v: l.length }, { l: 'Albums', v: al }, { l: 'Tracks', v: tr }, { l: 'On disk', b: size }];
    } else if (k === 'readarr') {
      const l = (await call(inst, 'GET', '/author')) || []; let bk = 0, bf = 0, size = 0;
      for (const a of l) { const x = a.statistics || {}; bk += num(x.bookCount); bf += num(x.bookFileCount); size += num(x.sizeOnDisk); }
      out.stats = [{ l: 'Authors', v: l.length }, { l: 'Books', v: `${bf} / ${bk}` }, { l: 'On disk', b: size }];
    } else if (k === 'prowlarr') {
      const [ix, bad] = await Promise.all([call(inst, 'GET', '/indexer'), soft(call(inst, 'GET', '/indexerstatus'))]);
      out.stats = [{ l: 'Indexers', v: (ix || []).length }, { l: 'Enabled', v: (ix || []).filter((x) => x.enable).length }, { l: 'Failing', v: (bad || []).length }];
    }
  } catch (e) { out.statsErr = e.message; }
  if (out.wanted != null) out.stats.push({ l: 'Missing', v: out.wanted });
  libIds.set(inst.id, ids); lib.set(inst.id, out); return out;
}
async function snapManager(inst, force) {
  const K = KINDS[inst.kind];
  const [status, health, queue] = await Promise.all([call(inst, 'GET', '/system/status'), soft(call(inst, 'GET', '/health')), inst.kind === 'prowlarr' ? null : soft(call(inst, 'GET', '/queue', { query: { page: 1, pageSize: 200, ...K.q } }))]);
  const l = await libFor(inst, force);
  return { version: status.version || '', info: [status.osName, status.isDocker ? 'docker' : ''].filter(Boolean).join(' · '), since: status.startTime || '', health: (health || []).filter((h) => h.type !== 'ok').map((h) => ({ level: h.type, text: h.message, src: h.source || '' })),
    stats: l.stats, statsErr: l.statsErr || '', disks: l.disks, queue: queue ? (queue.records || []).map((r) => queueItem(inst, r)) : [], queueTotal: queue ? num(queue.totalRecords) : 0 };
}
const QB_DONE = new Set(['uploading', 'stalledUP', 'pausedUP', 'stoppedUP', 'queuedUP', 'forcedUP', 'checkingUP']);
const QB_LABEL = { downloading: 'Downloading', stalledDL: 'Stalled', queuedDL: 'Queued', forcedDL: 'Downloading (forced)', metaDL: 'Fetching metadata', pausedDL: 'Paused', stoppedDL: 'Paused', checkingDL: 'Checking', checkingResumeData: 'Checking', error: 'Error', missingFiles: 'Missing files', allocating: 'Allocating', moving: 'Moving' };
const qbVer = new Map();
async function snapQbit(inst) {
  const [md, ver] = await Promise.all([call(inst, 'GET', '/api/v2/sync/maindata', { query: { rid: 0 } }), qbVer.has(inst.id) ? qbVer.get(inst.id) : soft(call(inst, 'GET', '/api/v2/app/version', { text: true }))]);
  if (ver) qbVer.set(inst.id, String(ver).replace(/^v/, ''));
  const ss = md.server_state || {}, ts = Object.entries(md.torrents || {}).map(([hash, t]) => ({ hash, ...t }));
  const open = ts.filter((t) => !QB_DONE.has(t.state) && num(t.progress) < 1), seeding = ts.filter((t) => ['uploading', 'stalledUP', 'forcedUP'].includes(t.state)).length;
  open.sort((a, b) => num(b.dlspeed) - num(a.dlspeed) || num(a.amount_left) - num(b.amount_left));
  return { version: qbVer.get(inst.id) || '', info: ss.connection_status || '', speeds: { dl: num(ss.dl_info_speed), up: num(ss.up_info_speed) }, health: ss.connection_status === 'disconnected' ? [{ level: 'warning', text: 'qBittorrent is not connected to the network', src: '' }] : [],
    stats: [{ l: 'Torrents', v: ts.length }, { l: 'Downloading', v: open.length }, { l: 'Seeding', v: seeding }, { l: 'Down', s: num(ss.dl_info_speed) }, { l: 'Up', s: num(ss.up_info_speed) }, { l: 'Free space', b: num(ss.free_space_on_disk) }, ...(ss.global_ratio ? [{ l: 'Ratio', v: ss.global_ratio }] : [])],
    queue: open.slice(0, 100).map((t) => ({ src: inst.id, srcName: inst.name, title: t.name, sub: t.category || '', size: num(t.size), left: num(t.amount_left), pct: num(t.progress) * 100, eta: num(t.eta) > 0 && num(t.eta) < 8640000 ? num(t.eta) : '', speed: num(t.dlspeed), state: QB_LABEL[t.state] || t.state, status: t.state === 'error' || t.state === 'missingFiles' ? 'error' : t.state === 'stalledDL' ? 'warning' : 'ok', msg: '', proto: 'torrent', peers: `${num(t.num_seeds)} seeds` })), queueTotal: open.length };
}
async function snapSab(inst) {
  const [qd, ver] = await Promise.all([call(inst, 'GET', '/api', { query: { mode: 'queue' } }), soft(call(inst, 'GET', '/api', { query: { mode: 'version' } }))]);
  const q = qd.queue || qd; if (qd.error) throw new Error('SABnzbd: ' + qd.error);
  const MB = 1048576, speed = num(q.kbpersec) * 1024;
  return { version: (ver && ver.version) || q.version || '', info: q.paused ? 'paused' : q.status || '', speeds: { dl: speed, up: 0 }, health: (q.warnings && num(q.warnings) ? [{ level: 'warning', text: `${q.warnings} warning(s) in SABnzbd`, src: '' }] : []),
    stats: [{ l: 'In queue', v: num(q.noofslots_total || (q.slots || []).length) }, { l: 'Down', s: speed }, { l: 'Left', b: num(q.mbleft) * MB }, { l: 'Free space', b: num(q.diskspace1_norm || q.diskspace1) * 1073741824 }],
    queue: (q.slots || []).map((s) => { const size = num(s.mb) * MB, left = num(s.mbleft) * MB; return { src: inst.id, srcName: inst.name, title: s.filename, sub: s.cat && s.cat !== '*' ? s.cat : '', size, left, pct: num(s.percentage) || (size ? (1 - left / size) * 100 : 0), eta: s.timeleft && s.timeleft !== '0:00:00' ? s.timeleft : '', speed: 0, state: s.status, status: /fail/i.test(s.status) ? 'error' : 'ok', msg: '', proto: 'usenet' }; }), queueTotal: num(q.noofslots_total) };
}
const ticksMs = (t) => Math.round(num(t) / 1e4);
async function snapMedia(inst, force) {
  let version = '', info = '', sessions = [], stats = [];
  if (inst.kind === 'plex') {
    const [root, ss] = await Promise.all([soft(call(inst, 'GET', '/')), call(inst, 'GET', '/status/sessions')]);
    const mc = (root && root.MediaContainer) || {}; version = mc.version || ''; info = mc.friendlyName || '';
    for (const m of (ss.MediaContainer && ss.MediaContainer.Metadata) || []) {
      const ep = m.type === 'episode', tr = m.type === 'track', P = m.Player || {}, T = m.TranscodeSession;
      sessions.push({ user: (m.User && m.User.title) || 'Unknown', watching: true, title: ep || tr ? m.grandparentTitle || m.title : m.title, sub: ep ? `S${pad(m.parentIndex || 0)}E${pad(m.index || 0)} · ${m.title}` : tr ? m.parentTitle || '' : m.year ? String(m.year) : '', type: m.type,
        client: P.product || '', device: P.title || P.device || '', platform: P.platform || '', ip: P.local ? P.address || '' : P.remotePublicAddress || P.address || '', remote: P.local === false, state: P.state || 'playing', pos: num(m.viewOffset), dur: num(m.duration),
        method: T ? (T.videoDecision === 'transcode' || T.audioDecision === 'transcode' ? 'transcode' : 'direct stream') : 'direct play', detail: T ? [T.videoDecision && 'video: ' + T.videoDecision, T.audioDecision && 'audio: ' + T.audioDecision].filter(Boolean).join(', ') : '', kbps: num(m.Session && m.Session.bandwidth) });
    }
  } else {
    const pre = '';
    const [si, ss, cnt] = await Promise.all([soft(call(inst, 'GET', pre + '/System/Info')), call(inst, 'GET', pre + '/Sessions', { query: { activeWithinSeconds: 960 } }), (lib.has(inst.id) && !force && Date.now() - lib.get(inst.id).at < 90000) ? lib.get(inst.id) : soft(call(inst, 'GET', pre + '/Items/Counts'))]);
    if (si) { version = si.Version || ''; info = si.ServerName || ''; }
    if (cnt && cnt.at) stats = cnt.stats; else if (cnt) { stats = [{ l: 'Movies', v: num(cnt.MovieCount) }, { l: 'Series', v: num(cnt.SeriesCount) }, { l: 'Episodes', v: num(cnt.EpisodeCount) }, ...(num(cnt.SongCount) ? [{ l: 'Songs', v: num(cnt.SongCount) }] : [])]; lib.set(inst.id, { at: Date.now(), stats }); }
    for (const s of ss || []) {
      if (!s.UserName) continue; const np = s.NowPlayingItem, ps = s.PlayState || {}, ep = np && np.Type === 'Episode';
      const pm = ps.PlayMethod === 'Transcode' ? 'transcode' : ps.PlayMethod === 'DirectStream' ? 'direct stream' : 'direct play', ti = s.TranscodingInfo;
      sessions.push({ user: s.UserName, watching: !!np, title: np ? (ep ? np.SeriesName || np.Name : np.Name) : '', sub: np ? (ep ? `S${pad(np.ParentIndexNumber || 0)}E${pad(np.IndexNumber || 0)} · ${np.Name}` : np.ProductionYear ? String(np.ProductionYear) : '') : '', type: np ? String(np.Type || '').toLowerCase() : '',
        client: s.Client || '', device: s.DeviceName || '', platform: '', ip: s.RemoteEndPoint || '', remote: false, state: np ? (ps.IsPaused ? 'paused' : 'playing') : 'idle', pos: ticksMs(ps.PositionTicks), dur: np ? ticksMs(np.RunTimeTicks) : 0, last: s.LastActivityDate || '',
        method: np ? pm : '', detail: ti ? [ti.VideoCodec && 'video ' + ti.VideoCodec, ti.AudioCodec && 'audio ' + ti.AudioCodec, ...(ti.TranscodeReasons || []).slice(0, 2)].filter(Boolean).join(', ') : '', kbps: ti ? Math.round(num(ti.Bitrate) / 1000) : 0 });
    }
  }
  return { version, info, sessions, stats, health: [], queue: [], queueTotal: 0 };
}
const inflight = new Map();
function snap(inst, force) {
  const k = inst.id + (force ? '!' : ''); if (inflight.has(k)) return inflight.get(k);
  const K = KINDS[inst.kind], pr = (async () => {
    const d = K.role === 'manager' || K.role === 'indexer' ? await snapManager(inst, force) : inst.kind === 'qbittorrent' ? await snapQbit(inst) : inst.kind === 'sabnzbd' ? await snapSab(inst) : await snapMedia(inst, force);
    return { sessions: [], speeds: null, ...d, at: Date.now() };
  })();
  inflight.set(k, pr); pr.then(() => inflight.delete(k), () => inflight.delete(k)); return pr;
}
api.handle('snapshot', async ({ force } = {}) => Promise.all(instances.map(async (i) => { try { return { id: i.id, ok: true, data: await snap(i, !!force) }; } catch (e) { return { id: i.id, ok: false, error: String(e.message || e) }; } })));

// ---------------------------------------------------------------- setup: services
const okUrl = (u) => { try { const x = new URL(String(u).trim()); return /^https?:$/.test(x.protocol) && !!x.host; } catch { return false; } };
api.handle('state', () => ({ instances: instances.map(pub), hosts: hosts.map((h) => ({ ...h, name: srvName(h.id) })), servers: savedServers().map((x) => ({ id: x.id, name: x.name || x.host, host: x.host })), kinds: Object.fromEntries(Object.entries(KINDS).map(([k, v]) => [k, { label: v.label, role: v.role, port: v.port }])), tmdb: !!String(api.config().tmdbKey || '').trim() }));
api.handle('saveInstance', (a) => {
  const kind = String(a.kind); if (!KINDS[kind]) throw new Error('Unknown service type');
  const url = String(a.url || '').trim(); if (!okUrl(url)) throw new Error('Enter the address as http://host:port (or https://…)');
  const transport = a.transport === 'ssh' ? 'ssh' : 'direct', host = transport === 'ssh' ? String(a.host || '') : ''; if (transport === 'ssh' && !serverOf(host)) throw new Error('Pick one of your saved SSH servers');
  let i = a.id ? instOf(a.id) : null; const isNew = !i; if (!i) { i = { id: rid() }; }
  i.kind = kind; i.name = String(a.name || KINDS[kind].label).trim().slice(0, 60) || KINDS[kind].label; i.url = url; i.transport = transport; i.host = host; i.insecure = !!a.insecure; i.user = String(a.user || '').slice(0, 100);
  if (a.key) i.key = api.secret.enc(String(a.key).trim()); if (a.pass) i.pass = api.secret.enc(String(a.pass));
  if (isNew) instances.push(i); qCookie.delete(i.id); lib.delete(i.id); saveAll(); return i.id;
});
api.handle('removeInstance', ({ id }) => { instOf(id); instances = instances.filter((i) => i.id !== id); lib.delete(id); libIds.delete(id); qCookie.delete(id); saveAll(); });
api.handle('test', async ({ id }) => {
  const i = instOf(id); lib.delete(id); qCookie.delete(id); const d = await snap(i, true);
  return `${KINDS[i.kind].label}${d.version ? ' ' + d.version : ''}${d.info ? ' · ' + d.info : ''}: connected`;
});

// ---------------------------------------------------------------- Docker + host statistics over SSH
const hostRec = (id) => { const h = hosts.find((x) => x.id === String(id)); if (!h) throw new Error('That server is not set up here'); return h; };
function prelude(h) { const c = h.sudo === 'nopw' ? 'sudo -n docker "$@"' : h.sudo === 'pw' ? `printf '%s\\n' "$SPW" | sudo -S -p '' docker "$@"` : 'docker "$@"'; return 'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/snap/bin"; export PATH\n' + (h.sudo === 'pw' ? 'IFS= read -r SPW\n' : '') + `d() { ${c}; }\n`; }
async function run(id, script, ms) {
  const h = hostRec(id), x = serverOf(id); let stdin = null;
  if (h.sudo === 'pw') { const pw = x ? api.secret.dec(x.password) : ''; if (!pw) throw new Error('This server has no saved password: save one in its SSH settings, or use passwordless sudo'); stdin = pw + '\n'; }
  return sshExec(id, '/bin/sh -c ' + sq(prelude(h) + script), stdin, ms);
}
const hint = (t) => /incorrect password|a password is required|no tty present/i.test(t) ? t + '\n\nsudo did not accept it: check the saved SSH password, or use passwordless sudo.' : /permission denied|got permission/i.test(t) ? t + '\n\nThis user may not use Docker there: add it to the "docker" group, or use sudo for this server.' : t;
const sections = (out) => { const sec = {}; let cur = null; for (const l of out.split('\n')) { const m = /^@@(\w+)$/.exec(l); if (m) { cur = m[1]; sec[cur] = []; } else if (cur) sec[cur].push(l); } return sec; };
const jl = (lines) => (lines || []).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const B = { b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, kib: 1024, mib: 1048576, gib: 1073741824, tib: 1099511627776 };
const bytes = (s) => { const m = /^([\d.]+)\s*([a-z]*)/i.exec(String(s).trim()); return m ? Number(m[1]) * (B[m[2].toLowerCase()] || 1) : 0; };
const T_PS = '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"state":{{json .State}},"status":{{json .Status}},"ports":{{json .Ports}},"project":{{json (.Label "com.docker.compose.project")}},"service":{{json (.Label "com.docker.compose.service")}}}';
const known = new Map(); // host id -> Set of container ids seen
api.handle('addHost', ({ id, sudo }) => { id = String(id); if (!serverOf(id)) throw new Error('Pick one of your saved SSH servers'); if (hosts.some((h) => h.id === id)) throw new Error('That server is already added'); hosts.push({ id, sudo: ['nopw', 'pw'].includes(sudo) ? sudo : '', all: false }); saveAll(); });
api.handle('updateHost', ({ id, sudo, all }) => { const h = hostRec(id); h.sudo = ['nopw', 'pw'].includes(sudo) ? sudo : ''; h.all = !!all; saveAll(); });
api.handle('removeHost', ({ id }) => { hostRec(id); hosts = hosts.filter((h) => h.id !== id); known.delete(id); saveAll(); });
api.handle('docker', async ({ id }) => {
  const h = hostRec(id);
  const r = await run(id, `v=$(d version --format '{{.Server.Version}}' 2>&1) || { echo '@@error'; echo "$v"; exit 0; }\necho '@@ver'; echo "$v"\n` +
    `echo '@@ps'; d ps -a --format '${T_PS}' 2>/dev/null\necho '@@stats'; d stats --no-stream --format '{{json .}}' 2>/dev/null\n` +
    `echo '@@load'; cat /proc/loadavg 2>/dev/null\necho '@@mem'; grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null\necho '@@cpu'; nproc 2>/dev/null\necho '@@up'; cut -d' ' -f1 /proc/uptime 2>/dev/null\n` +
    `echo '@@df'; df -P -B1 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|overlay|shm|none|udev|/dev/loop|efivarfs)'\necho '@@end'\n`, 90000);
  const s = sections(r.out);
  if (s.error) throw new Error(hint(s.error.join('\n').trim() || 'Docker is not reachable on this server'));
  if (!s.ver) throw new Error(hint(clip((r.err || r.out).trim(), 500) || 'No answer from the server'));
  const stats = new Map(jl(s.stats).map((j) => { const [mu, ml] = String(j.MemUsage).split('/').map(bytes), [rx, tx] = String(j.NetIO).split('/').map(bytes); return [String(j.ID || j.Container).slice(0, 12), { cpu: parseFloat(j.CPUPerc) || 0, mem: mu, memLimit: ml, rx, tx }]; }));
  const all = jl(s.ps).map((j) => { const ports = [...new Set(String(j.ports || '').split(',').map((p) => /(?:^|:)(\d+)->(\d+)\/(tcp|udp)/.exec(p.trim())).filter(Boolean).map((m) => `${m[1]}→${m[2]}`))]; return { id: String(j.id).slice(0, 12), name: String(j.name || '').split(',')[0], image: j.image || '', state: j.state || '', status: j.status || '', ports, project: j.project || '', service: j.service || '', arr: ARR_RE.test(j.name + ' ' + j.image), stats: stats.get(String(j.id).slice(0, 12)) || null }; });
  const arrProjects = new Set(all.filter((c) => c.arr && c.project).map((c) => c.project));
  const shown = h.all ? all : all.filter((c) => c.arr || (c.project && arrProjects.has(c.project)));
  known.set(id, new Set(all.map((c) => c.id)));
  const mem = {}; for (const l of s.mem || []) { const m = /^(\w+):\s+(\d+)/.exec(l); if (m) mem[m[1]] = +m[2] * 1024; }
  const la = String((s.load || [''])[0]).split(' ');
  const disks = (s.df || []).slice(1).map((l) => l.trim().split(/\s+/)).filter((p) => p.length >= 6).map((p) => ({ fs: p[0], total: num(p[1]), used: num(p[2]), free: num(p[3]), mount: p.slice(5).join(' ') })).filter((d) => d.total > 0);
  return { version: (s.ver[0] || '').trim(), containers: shown, hidden: all.length - shown.length, host: { load: [num(la[0]), num(la[1]), num(la[2])], cpus: num((s.cpu || [])[0]), memTotal: num(mem.MemTotal), memFree: num(mem.MemAvailable), swapTotal: num(mem.SwapTotal), swapFree: num(mem.SwapFree), uptime: num((s.up || [])[0]), disks }, at: Date.now() };
});
const needCid = (id, cid) => { cid = String(cid); if (!/^[0-9a-f]{12}$/.test(cid) || !(known.get(id) || new Set()).has(cid)) throw new Error('Unknown container: refresh first'); return cid; };
api.handle('containerAction', async ({ id, cid, op }) => {
  if (!['start', 'stop', 'restart'].includes(op)) throw new Error('Unknown action'); cid = needCid(id, cid);
  const r = await run(id, `d ${op} ${cid} 2>&1`, 120000); if (r.code !== 0) throw new Error(hint(clip(r.out.trim() || r.err.trim(), 500)));
});
api.handle('containerLogs', async ({ id, cid }) => { cid = needCid(id, cid); const r = await run(id, `d logs --tail 300 -t ${cid} 2>&1`, 60000); return clip(r.out, 120000); });

// ---------------------------------------------------------------- finding the services in Docker, and their API keys
const DISC = new Map(); // token -> candidate (with secrets)
const FILES = { sonarr: ['config.xml'], radarr: ['config.xml'], lidarr: ['config.xml'], readarr: ['config.xml'], prowlarr: ['config.xml'], sabnzbd: ['sabnzbd.ini', 'sabnzbd/sabnzbd.ini'], plex: ['Library/Application Support/Plex Media Server/Preferences.xml'] };
const T_INSPECT = '{"name":{{json .Name}},"image":{{json .Config.Image}},"running":{{json .State.Running}},"mode":{{json .HostConfig.NetworkMode}},"ports":{{json .NetworkSettings.Ports}},"nets":{{json .NetworkSettings.Networks}},"mounts":{{json .Mounts}}}';
api.handle('discover', async ({ id }) => {
  const h = hostRec(id), x = serverOf(id); if (!x) throw new Error('Server not found');
  const r = await run(id, `echo '@@i'; ids=$(d ps -aq 2>/dev/null); [ -n "$ids" ] && d inspect -f '${T_INSPECT}' $ids 2>/dev/null\necho '@@end'\n`, 60000);
  const s = sections(r.out); if (!s.i) throw new Error(hint(clip((r.err || r.out).trim(), 400) || 'Docker is not reachable on this server'));
  const cands = [];
  for (const j of jl(s.i)) {
    const name = String(j.name || '').replace(/^\//, ''), hit = DETECT.find(([, re]) => re.test(name + ' ' + j.image)); if (!hit || !/^[\w.-]+$/.test(name)) continue;
    const kind = hit[0]; cands.push({ kind, name, image: j.image, running: !!j.running, ports: j.ports || {}, host: j.mode === 'host', ip: Object.values(j.nets || {}).map((n) => n.IPAddress).find(Boolean) || '', cfg: (j.mounts || []).find((m) => m.Destination === '/config'), token: rid() });
  }
  const want = cands.filter((c) => FILES[c.kind] && c.running);
  if (want.length) {
    let sc = ''; want.forEach((c, i) => { for (const rel of FILES[c.kind]) { const src = c.cfg && c.cfg.Source ? c.cfg.Source + '/' + rel : ''; sc += `echo '@@f${i}'; { d exec ${c.name} cat ${sq('/config/' + rel)} 2>/dev/null${src ? ' || cat ' + sq(src) + ' 2>/dev/null' : ''}; } | head -c 40000\n`; } });
    const r2 = await run(id, sc + "echo '@@end'\n", 90000), s2 = sections(r2.out);
    want.forEach((c, i) => { c.conf = (s2['f' + i] || []).join('\n'); });
  }
  DISC.clear(); const out = [];
  for (const c of cands) {
    const K = KINDS[c.kind], cf = c.conf || '', xml = (t) => { const m = new RegExp(`<${t}>([^<]*)</${t}>`).exec(cf); return m ? m[1].trim() : ''; };
    let key = '', base = '', inner = K.port;
    if (K.v) { key = xml('ApiKey'); base = xml('UrlBase'); inner = num(xml('Port')) || K.port; if (base && !base.startsWith('/')) base = '/' + base; }
    else if (c.kind === 'sabnzbd') { const m = /^api_key\s*=\s*(\S+)/m.exec(cf); key = m ? m[1] : ''; }
    else if (c.kind === 'plex') { const m = /PlexOnlineToken="([^"]+)"/.exec(cf); key = m ? m[1] : ''; }
    const b = (c.ports[inner + '/tcp'] || [])[0] || Object.values(c.ports).flat().find(Boolean), hp = c.host ? inner : b ? num(b.HostPort) : 0;
    const direct = hp ? `http://${x.host}:${hp}${base}` : '', viaSsh = hp ? `http://127.0.0.1:${hp}${base}` : c.ip ? `http://${c.ip}:${inner}${base}` : '';
    if (!viaSsh) continue;
    const cand = { token: c.token, kind: c.kind, name: c.name, image: c.image, running: c.running, direct, viaSsh, hasKey: !!key, key, already: instances.some((i) => i.name === c.name || (i.url && (i.url === direct || i.url === viaSsh))) };
    DISC.set(cand.token, cand); out.push({ ...cand, key: undefined });
  }
  return out;
});
api.handle('addDiscovered', ({ id, tokens, transport }) => {
  hostRec(id); let n = 0;
  for (const t of tokens || []) {
    const c = DISC.get(String(t)); if (!c) continue; const ssh = transport === 'ssh' || !c.direct;
    instances.push({ id: rid(), kind: c.kind, name: c.name, url: ssh ? c.viaSsh : c.direct, transport: ssh ? 'ssh' : 'direct', host: ssh ? id : '', insecure: false, user: '', key: c.key ? api.secret.enc(c.key) : undefined }); n++;
  }
  DISC.clear(); saveAll(); return n;
});

// ---------------------------------------------------------------- search and request (Sonarr / Radarr, metadata from TMDB when a key is set)
const first = (k) => instances.find((i) => i.kind === k);
async function tmdb(path, params) {
  const key = String(api.config().tmdbKey || '').trim(); if (!key) throw new Error('No TMDB key set');
  const u = new URL('https://api.themoviedb.org/3' + path); for (const [k, v] of Object.entries(params || {})) u.searchParams.set(k, v);
  const bearer = key.length > 40; if (!bearer) u.searchParams.set('api_key', key);
  const r = await api.fetch(u.toString(), { headers: bearer ? { Authorization: 'Bearer ' + key, Accept: 'application/json' } : { Accept: 'application/json' } });
  if (r.status === 401) throw new Error('TMDB rejected the key (module settings: TMDB key)');
  if (!r.ok) throw new Error('TMDB answered ' + r.status); return r.json();
}
const poster = (imgs) => { const p = (imgs || []).find((i) => i.coverType === 'poster'); return p ? p.remoteUrl || '' : ''; };
async function libOf(inst) { if (!libIds.has(inst.id)) { try { await libFor(inst, true); } catch {} } return libIds.get(inst.id) || { tmdb: new Set(), tvdb: new Set() }; }
api.handle('search', async ({ q, type }) => {
  q = String(q || '').trim(); if (q.length < 2) return { results: [], via: '' };
  const rad = first('radarr'), son = first('sonarr'), want = (t) => type !== (t === 'movie' ? 'tv' : 'movie');
  if (!rad && !son) throw new Error('Add Sonarr and/or Radarr under Services first');
  const [rl, sl] = await Promise.all([rad ? libOf(rad) : null, son ? libOf(son) : null]);
  let results = [], via = 'arr';
  if (String(api.config().tmdbKey || '').trim()) {
    via = 'tmdb'; const j = await tmdb('/search/multi', { query: q, include_adult: 'false' });
    for (const r of j.results || []) {
      if (r.media_type !== 'movie' && r.media_type !== 'tv') continue; if (r.media_type === 'movie' ? !want('movie') || !rad : !want('tv') || !son) continue;
      const lib = r.media_type === 'movie' ? rl.tmdb.has(r.id) : sl.tmdb.has(r.id);
      results.push({ type: r.media_type, tmdbId: r.id, tvdbId: 0, title: r.title || r.name || '', year: String(r.release_date || r.first_air_date || '').slice(0, 4), overview: clip(r.overview || '', 400), rating: r.vote_average ? Math.round(r.vote_average * 10) / 10 : 0, img: r.poster_path ? 'https://image.tmdb.org/t/p/w185' + r.poster_path : '', inLib: lib });
    }
  } else {
    const [mv, tv] = await Promise.all([rad && want('movie') ? call(rad, 'GET', '/movie/lookup', { query: { term: q } }) : [], son && want('tv') ? call(son, 'GET', '/series/lookup', { query: { term: q } }) : []]);
    for (const m of (mv || []).slice(0, 12)) results.push({ type: 'movie', tmdbId: m.tmdbId, tvdbId: 0, title: m.title, year: m.year ? String(m.year) : '', overview: clip(m.overview || '', 400), rating: m.ratings && m.ratings.tmdb ? m.ratings.tmdb.value : 0, img: poster(m.images), inLib: !!m.id || rl.tmdb.has(m.tmdbId) });
    for (const s of (tv || []).slice(0, 12)) results.push({ type: 'tv', tmdbId: s.tmdbId || 0, tvdbId: s.tvdbId || 0, title: s.title, year: s.year ? String(s.year) : '', overview: clip(s.overview || '', 400), rating: s.ratings ? s.ratings.value : 0, img: poster(s.images), inLib: !!s.id || sl.tvdb.has(s.tvdbId) });
    results = results.filter((r) => r.tmdbId || r.tvdbId);
  }
  return { results: results.slice(0, 30), via };
});
const imgCache = new Map();
api.handle('image', async ({ url }) => {
  url = String(url || ''); if (imgCache.has(url)) return imgCache.get(url);
  let u; try { u = new URL(url); } catch { return ''; }
  if (u.protocol !== 'https:' || !/(^|\.)(tmdb\.org|themoviedb\.org|thetvdb\.com|fanart\.tv|tvmaze\.com|sonarr\.tv|radarr\.video)$/.test(u.hostname)) return '';
  u.pathname = u.pathname.replace('/t/p/original/', '/t/p/w185/');
  const r = await api.fetch(u.toString(), { timeout: 12000 }); if (!r.ok) return '';
  const buf = Buffer.from(await r.arrayBuffer()), ct = r.headers.get('content-type') || 'image/jpeg'; if (buf.length > 800000 || !/^image\//.test(ct)) return '';
  const out = `data:${ct};base64,${buf.toString('base64')}`; if (imgCache.size > 300) imgCache.delete(imgCache.keys().next().value); imgCache.set(url, out); return out;
});
api.handle('targets', ({ type }) => instances.filter((i) => i.kind === (type === 'movie' ? 'radarr' : 'sonarr')).map((i) => ({ id: i.id, name: i.name })));
api.handle('options', async ({ id }) => {
  const i = instOf(id); if (i.kind !== 'sonarr' && i.kind !== 'radarr') throw new Error('Only Sonarr and Radarr can take requests');
  const [pr, rf] = await Promise.all([call(i, 'GET', '/qualityprofile'), call(i, 'GET', '/rootfolder')]);
  return { profiles: (pr || []).map((p) => ({ id: p.id, name: p.name })), roots: (rf || []).map((f) => ({ path: f.path, free: num(f.freeSpace) })) };
});
const MONITOR = ['all', 'future', 'missing', 'existing', 'firstSeason', 'lastSeason', 'pilot', 'none'], AVAIL = ['announced', 'inCinemas', 'released'], STYPE = ['standard', 'anime', 'daily'];
api.handle('request', async (a) => {
  const i = instOf(a.id), profileId = Math.trunc(num(a.profileId)), root = String(a.root || ''); if (!profileId || !root) throw new Error('Choose a quality profile and a folder');
  const opts = await call(i, 'GET', '/rootfolder'); if (!(opts || []).some((f) => f.path === root)) throw new Error('That folder is not one of the root folders of ' + i.name);
  let body, path;
  if (i.kind === 'radarr') {
    const tmdbId = Math.trunc(num(a.tmdbId)); if (!tmdbId) throw new Error('No TMDB id for this movie');
    const l = await call(i, 'GET', '/movie/lookup', { query: { term: 'tmdb:' + tmdbId } }), m = (Array.isArray(l) ? l : [l]).find((x) => x && x.tmdbId === tmdbId); if (!m) throw new Error('Radarr could not find this movie');
    if (m.id) throw new Error(`"${m.title}" is already in ${i.name}`);
    path = '/movie'; body = { ...m, qualityProfileId: profileId, rootFolderPath: root, monitored: a.monitor !== 'none', minimumAvailability: AVAIL.includes(a.avail) ? a.avail : 'released', addOptions: { monitor: 'movieOnly', searchForMovie: !!a.search } };
  } else if (i.kind === 'sonarr') {
    let tvdbId = Math.trunc(num(a.tvdbId)); const tmdbId = Math.trunc(num(a.tmdbId));
    if (!tvdbId && tmdbId) { const ex = await tmdb(`/tv/${tmdbId}/external_ids`); tvdbId = num(ex.tvdb_id); if (!tvdbId) throw new Error('TMDB has no TVDB id for this show, and Sonarr needs one'); }
    if (!tvdbId) throw new Error('No TVDB id for this show');
    const l = await call(i, 'GET', '/series/lookup', { query: { term: 'tvdb:' + tvdbId } }), s = (Array.isArray(l) ? l : [l]).find((x) => x && x.tvdbId === tvdbId); if (!s) throw new Error('Sonarr could not find this show');
    if (s.id) throw new Error(`"${s.title}" is already in ${i.name}`);
    const lp = await soft(call(i, 'GET', '/languageprofile')); path = '/series';
    body = { ...s, qualityProfileId: profileId, rootFolderPath: root, monitored: a.monitor !== 'none', seasonFolder: true, seriesType: STYPE.includes(a.seriesType) ? a.seriesType : 'standard', addOptions: { monitor: MONITOR.includes(a.monitor) ? a.monitor : 'all', searchForMissingEpisodes: !!a.search, searchForCutoffUnmetEpisodes: false } };
    if (Array.isArray(lp) && lp.length) body.languageProfileId = lp[0].id;
  } else throw new Error('Only Sonarr and Radarr can take requests');
  const res = await call(i, 'POST', path, { json: body }); lib.delete(i.id); libIds.delete(i.id);
  return { title: (res && res.title) || body.title, id: res && res.id };
});
//==== renderer ====
// Arr stack (window): a docked panel with Overview, Downloads, Watching, Docker, Search and Services. All text goes in with textContent, never as HTML.
const LOGO = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M10 8.5v3.5l3-1.75z"/><path d="M8 20h8M12 16v4"/></svg>';
const el = (tag, cls, text) => { const x = document.createElement(tag); if (cls) x.className = cls; if (text != null) x.textContent = text; return x; };
const errText = (e) => String(e && e.message || e || '').replace(/^Error invoking remote method '[^']*': (Error: )?/, '');
const quiet = (n, a) => Mod.call(n, a);
const call = (n, a) => Mod.call(n, a).catch((e) => { Mod.toast(errText(e).slice(0, 160)); throw e; });
const lsGet = (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : v; } catch { return d; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch {} };
const NS = 'http://www.w3.org/2000/svg';
const svg = (tag, attrs, parent) => { const n = document.createElementNS(NS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); if (parent) parent.append(n); return n; };
const GL = { refresh: '↻', gear: '⚙', plus: '+', play: '▶', stop: '■', restart: '↻', file: '≡', trash: '✕', edit: '✎', search: '⌕', check: '✓' };
const ic = (n, s = 14) => { try { return icon(n, s); } catch { return GL[n] || n; } };

// ---- state ----
let S = { instances: [], hosts: [], servers: [], kinds: {}, tmdb: false };
const SNAP = new Map();   // instance id -> { ok, data | error, at }
const DK = new Map();     // docker host id -> { d, err, loading }
const HIST = new Map();   // docker host id -> Map(key -> { cpu: [] })
let view = lsGet('arView', 'overview'), dkHost = lsGet('arDkHost', ''), timer = null, tickN = 0, loading = false;
const ui = {}, N = 60;
const busy = new Set();

// ---- formatting ----
const fb = (n) => { n = +n || 0; const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB']; let i = 0; while (n >= 1024 && i < 5) { n /= 1024; i++; } return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i]; };
const fr = (n) => fb(n) + '/s';
const clock = (ms) => { const s = Math.max(0, Math.round(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60); return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s % 60).padStart(2, '0'); };
const etaText = (e) => (typeof e === 'number' ? (e >= 3600 ? Math.floor(e / 3600) + 'h ' + Math.round(e % 3600 / 60) + 'm' : e >= 60 ? Math.round(e / 60) + 'm' : e + 's') : String(e || '').replace(/^00:/, '').replace(/^0(\d:)/, '$1'));
const ago = (iso) => { const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000); if (!isFinite(s)) return ''; return s < 90 ? Math.round(s) + 's' : s < 5400 ? Math.round(s / 60) + 'm' : s < 129600 ? Math.round(s / 3600) + 'h' : Math.round(s / 86400) + 'd'; };
const upText = (s) => { const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`; };
const KL = (k) => (S.kinds[k] || {}).label || k;
const inst = (id) => S.instances.find((i) => i.id === id);
const role = (i) => (S.kinds[i.kind] || {}).role;
const interval = () => Math.min(60, Math.max(3, +Mod.config().interval || 5));
const bar = (pct, cls) => { const b = el('div', 'ar-bar ' + (cls || '')), i = el('i'); i.style.width = Math.max(0, Math.min(100, pct)) + '%'; b.append(i); return b; };
const chip = (t, cls) => el('span', 'ar-chip ' + (cls || ''), t);
const empty = (t) => el('div', 'ar-empty', t);
function spark(vals, w, h, cls) {
  const s = svg('svg', { class: 'ar-sp ' + (cls || ''), width: w, height: h, viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none' });
  if (vals.length < 2) return s;
  const m = Math.max(...vals, 1e-9) * 1.15, step = w / (N - 1), v = vals.slice(-N), pts = v.map((y, i) => [w - (v.length - 1 - i) * step, h - 1 - Math.min(1, y / m) * (h - 2)]);
  const line = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('');
  svg('path', { class: 'a', d: line + `L${w} ${h}L${pts[0][0].toFixed(1)} ${h}Z` }, s); svg('path', { class: 'l', d: line }, s); return s;
}
function dialog(title, text, bad) {
  const d = el('div', 'ar-dlg'), c = el('div'), f = el('div', 'f'), ok = el('button', 'primary', 'Close'), pre = el('pre', '', text || '(no output)'); if (bad) pre.style.color = 'var(--bad)';
  ok.onclick = () => d.remove(); f.append(ok); c.append(el('h4', '', title), pre, f); d.append(c); d.onclick = (e) => { if (e.target === d) d.remove(); }; ui.root.append(d);
}
const tb = (label, title, fn, cls) => { const b = el('button', cls || '', label); b.title = title || ''; b.onclick = fn; return b; };
const ib = (icon, title, fn, cls, dis) => { const b = el('button', 'ar-ib ' + (cls || '')); b.innerHTML = ic(icon, 14); b.title = title; if (dis) b.disabled = true; b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };

// ---- data ----
async function loadState() { try { S = await quiet('state'); } catch (e) { Mod.toast(errText(e)); } if (!S.hosts.some((h) => h.id === dkHost)) dkHost = (S.hosts[0] || {}).id || ''; }
async function refresh(force) {
  if (loading) return; loading = true; ui.spin.textContent = 'updating…';
  try { const r = await quiet('snapshot', { force: !!force }); for (const x of r) SNAP.set(x.id, { ...x, at: Date.now() }); } catch (e) { ui.spin.textContent = errText(e).slice(0, 80); loading = false; return; }
  loading = false; ui.spin.textContent = 'updated ' + new Date().toLocaleTimeString(); drawLive();
}
async function pollDocker(id, force) {
  if (!id) return; const x = DK.get(id) || {}; DK.set(id, x); if (x.loading && !force) return; x.loading = true;
  try { x.d = await quiet('docker', { id }); x.err = ''; ingest(id, x.d); } catch (e) { x.err = errText(e); }
  x.loading = false; if (view === 'docker') drawDocker();
}
function tick() {
  if (!panel.isOpen()) return; tickN++;
  refresh(); if (view === 'docker' && tickN % 2 === 0) pollDocker(dkHost);
}
function startTimer() { clearInterval(timer); timer = setInterval(tick, interval() * 1000); }
Mod.onConfig(() => { startTimer(); loadState(); });
Mod.onUnload(() => clearInterval(timer));
const pushN = (a, v) => { a.push(v); if (a.length > N) a.shift(); };
function ingest(id, d) { let m = HIST.get(id); if (!m) HIST.set(id, m = new Map()); let tot = 0; for (const c of d.containers) { if (!c.stats) continue; let h = m.get(c.id); if (!h) m.set(c.id, h = { cpu: [] }); pushN(h.cpu, c.stats.cpu); tot += c.stats.cpu; } let h = m.get('host'); if (!h) m.set('host', h = { cpu: [] }); pushN(h.cpu, tot); }

// ---- summary line ----
const snaps = (pred) => S.instances.filter(pred).map((i) => [i, SNAP.get(i.id)]).filter(([, s]) => s && s.ok).map(([i, s]) => ({ i, d: s.data }));
function drawSummary() {
  const sm = ui.sum; sm.textContent = ''; const add = (t, v, cls) => { const s = el('span'); s.append(el('b', cls || '', String(v)), ' ' + t); sm.append(s); };
  const total = S.instances.length; if (!total) return;
  const up = S.instances.filter((i) => (SNAP.get(i.id) || {}).ok).length, down = S.instances.filter((i) => SNAP.get(i.id) && !SNAP.get(i.id).ok).length;
  add('services up', up + '/' + total, down ? 'bad' : ''); const dl = snaps((i) => role(i) === 'download'); const n = dl.reduce((a, x) => a + x.d.queueTotal, 0), sp = dl.reduce((a, x) => a + ((x.d.speeds || {}).dl || 0), 0);
  add('downloading', n); if (sp) add('', fr(sp)); const w = snaps((i) => role(i) === 'media').reduce((a, x) => a + x.d.sessions.filter((s) => s.watching).length, 0); add('watching', w);
  const hl = [...SNAP.values()].reduce((a, s) => a + (s.ok ? s.data.health.filter((h) => h.level === 'error' || h.level === 'warning').length : 0), 0); if (hl) add('health issue' + (hl === 1 ? '' : 's'), hl, 'bad');
}

// ---- overview ----
function statGrid(stats) { const g = el('div', 'ar-stats'); for (const s of stats) { const c = el('div'); c.append(el('b', '', s.b != null ? fb(s.b) : s.s != null ? fr(s.s) : String(s.v)), el('small', '', s.l)); g.append(c); } return g; }
function instCard(i) {
  const sn = SNAP.get(i.id), card = el('div', 'ar-card'), h = el('div', 'ar-ch');
  const dot = el('span', 'ar-dot ' + (!sn ? 'busy' : sn.ok ? ((sn.data.health || []).some((x) => x.level === 'error') ? 'bad' : (sn.data.health || []).some((x) => x.level === 'warning') ? 'warn' : 'ok') : 'bad'));
  h.append(dot, el('span', 'ar-name', i.name), chip(KL(i.kind))); if (sn && sn.ok && sn.data.version) h.append(el('span', 'ar-st', 'v' + sn.data.version)); card.append(h);
  if (!sn) { card.append(el('div', 'ar-sub', 'Connecting…')); return card; }
  if (!sn.ok) { card.append(el('div', 'ar-errbox', sn.error)); const a = el('div', 'ar-acts'); a.append(tb('Edit service', '', () => serviceForm(i))); card.append(a); return card; }
  const d = sn.data; if (d.info) card.append(el('div', 'ar-sub', d.info + (d.since ? '  ·  up ' + ago(d.since) : '')));
  for (const x of d.health) card.append(el('div', 'ar-health ' + (x.level === 'error' ? 'bad' : 'warn'), (x.src ? x.src + ': ' : '') + x.text));
  if (d.stats && d.stats.length) card.append(statGrid(d.stats)); if (d.statsErr) card.append(el('div', 'ar-sub', 'Library statistics unavailable: ' + d.statsErr));
  if (role(i) === 'manager' && d.queueTotal) card.append(el('div', 'ar-sub', `${d.queueTotal} in the download queue`));
  if (role(i) === 'media') { const w = d.sessions.filter((s) => s.watching).length; card.append(el('div', 'ar-sub', `${w} watching now · ${d.sessions.length} online`)); }
  return card;
}
function drawOverview() {
  const b = ui.panes.overview; b.textContent = '';
  if (!S.instances.length) { b.append(empty('No services yet.\nOpen Services and add Sonarr, Radarr, your download client or Plex / Jellyfin / Emby, or detect them from a Docker server over SSH.')); b.append(tb('Open Services', '', () => setView('services'), 'primary')); return; }
  const groups = [['manager', 'Media managers'], ['indexer', 'Indexers'], ['download', 'Download clients'], ['media', 'Media servers']];
  for (const [r, t] of groups) { const list = S.instances.filter((i) => role(i) === r); if (!list.length) continue; b.append(el('h5', 'ar-h', t)); for (const i of list) b.append(instCard(i)); }
  const disks = new Map(); for (const { d } of snaps((i) => role(i) === 'manager')) for (const k of d.disks) if (k.total && !disks.has(k.path)) disks.set(k.path, k);
  if (disks.size) { b.append(el('h5', 'ar-h', 'Disk space (as the media managers see it)')); const c = el('div', 'ar-card ar-pad'); for (const k of disks.values()) c.append(diskRow(k.path, k.total - k.free, k.total, k.free)); b.append(c); }
}
function diskRow(label, used, total, free) {
  const r = el('div', 'ar-disk'), t = el('div', 'ar-l1'), pct = total ? used / total * 100 : 0; t.append(el('span', 'ar-name', label), el('span', 'ar-st', `${fb(free)} free of ${fb(total)}`)); t.querySelector('.ar-name').title = label;
  r.append(t, bar(pct, pct > 92 ? 'bad' : pct > 80 ? 'warn' : '')); return r;
}

// ---- downloads ----
function dlRow(q, own) {
  const r = el('div', 'ar-row'), l1 = el('div', 'ar-l1'), t = el('span', 'ar-name', q.title); t.title = q.release || q.title; l1.append(t);
  if (q.status === 'error') l1.append(chip('error', 'bad')); else if (q.status === 'warning') l1.append(chip('warning', 'warn'));
  l1.append(el('span', 'ar-st', q.state)); r.append(l1);
  r.append(bar(q.pct, q.status === 'error' ? 'bad' : q.status === 'warning' ? 'warn' : ''));
  const l2 = el('div', 'ar-l2'); l2.append(el('span', '', q.pct.toFixed(q.pct >= 99.95 ? 0 : 1) + '%'), el('span', '', `${fb(q.size - q.left)} / ${fb(q.size)}`)); if (q.speed) l2.append(el('span', '', fr(q.speed))); if (q.eta !== '') l2.append(el('span', '', 'ETA ' + etaText(q.eta)));
  if (q.sub) l2.append(el('span', '', q.sub)); if (q.peers) l2.append(el('span', '', q.peers)); if (q.client && !own) l2.append(el('span', '', q.client)); if (q.indexer) l2.append(el('span', '', q.indexer)); if (q.proto && !own) l2.append(el('span', '', q.proto)); r.append(l2);
  if (q.msg) r.append(el('div', 'ar-msg ' + (q.status === 'error' ? 'bad' : 'warn'), q.msg));
  return r;
}
function drawDownloads() {
  const b = ui.panes.downloads; b.textContent = ''; const f = ui.q.value.trim().toLowerCase(), m = (q) => !f || (q.title + ' ' + q.sub).toLowerCase().includes(f);
  const dl = snaps((i) => role(i) === 'download'), mg = snaps((i) => role(i) === 'manager'); let any = false;
  for (const { i, d } of dl) {
    const items = d.queue.filter(m); const h = el('div', 'ar-sech'); h.append(el('b', '', i.name), el('span', 'ar-st', `${KL(i.kind)} · ${d.queueTotal} active` + (d.speeds && d.speeds.dl ? ' · ' + fr(d.speeds.dl) : '') + (d.speeds && d.speeds.up ? ' · ↑ ' + fr(d.speeds.up) : '')));
    b.append(h); for (const q of items) { b.append(dlRow(q, true)); any = true; } if (!items.length) b.append(el('div', 'ar-sub', d.queueTotal ? 'Nothing matches the filter.' : 'Idle.'));
  }
  for (const { i, d } of mg) {
    const items = d.queue.filter(m); if (!items.length) continue; const h = el('div', 'ar-sech'); h.append(el('b', '', i.name + ' queue'), el('span', 'ar-st', `${d.queueTotal} item${d.queueTotal === 1 ? '' : 's'} (downloading, waiting to import, or needing attention)`)); b.append(h);
    for (const q of items) { b.append(dlRow(q, false)); any = true; }
  }
  if (!S.instances.some((i) => ['download', 'manager'].includes(role(i)))) b.append(empty('Add a download client (qBittorrent / SABnzbd) or Sonarr / Radarr under Services.'));
  else if (!any && !b.children.length) b.append(empty('No downloads.'));
}

// ---- watching ----
function sessCard(i, s) {
  const c = el('div', 'ar-card ar-pad'), l1 = el('div', 'ar-l1'); l1.append(el('span', 'ar-dot ' + (s.state === 'playing' ? 'ok' : s.state === 'paused' || s.state === 'buffering' ? 'warn' : 'idle')), el('b', 'ar-name', s.user), chip(i.name), el('span', 'ar-st', s.state)); c.append(l1);
  if (s.watching) {
    const t = el('div', 'ar-title', s.title); c.append(t); if (s.sub) c.append(el('div', 'ar-sub', s.sub));
    const l2 = el('div', 'ar-l2'); if (s.dur) { c.append(bar(s.pos / s.dur * 100)); l2.append(el('span', '', clock(s.pos) + ' / ' + clock(s.dur))); }
    if (s.method) l2.append(chip(s.method, s.method === 'transcode' ? 'warn' : '')); if (s.detail) l2.append(el('span', '', s.detail)); if (s.kbps) l2.append(el('span', '', (s.kbps / 1000).toFixed(1) + ' Mbps')); c.append(l2);
  }
  const l3 = el('div', 'ar-l2'); for (const v of [s.client, s.device, s.platform, s.ip && (s.remote ? 'remote ' : '') + s.ip, !s.watching && s.last ? 'active ' + ago(s.last) + ' ago' : '']) if (v) l3.append(el('span', '', v)); c.append(l3);
  return c;
}
function drawWatching() {
  const b = ui.panes.watching; b.textContent = ''; const ms = S.instances.filter((i) => role(i) === 'media');
  if (!ms.length) { b.append(empty('Add Plex, Jellyfin or Emby under Services to see who is watching.')); return; }
  const all = []; for (const i of ms) { const sn = SNAP.get(i.id); if (sn && !sn.ok) b.append(el('div', 'ar-errbox', `${i.name}: ${sn.error}`)); else if (sn) for (const s of sn.data.sessions) all.push([i, s]); }
  const now = all.filter(([, s]) => s.watching), on = all.filter(([, s]) => !s.watching);
  b.append(el('h5', 'ar-h', `Watching now (${now.length})`)); if (!now.length) b.append(el('div', 'ar-sub', 'Nobody is watching.')); for (const [i, s] of now) b.append(sessCard(i, s));
  if (on.length) { b.append(el('h5', 'ar-h', `Logged in, not watching (${on.length})`)); for (const [i, s] of on) b.append(sessCard(i, s)); }
  if (ms.some((i) => i.kind === 'plex')) b.append(el('div', 'ar-sub', 'Plex only reports people who are playing something. Jellyfin and Emby also show who is logged in on a device.'));
}

// ---- docker ----
const act = async (key, label, fn) => { if (busy.has(key)) return; busy.add(key); drawDocker(); Mod.toast(label); try { await fn(); } catch (e) { dialog('Failed', errText(e), true); } busy.delete(key); await pollDocker(dkHost, true); };
function contRow(c) {
  const row = el('div', 'ar-row'), l1 = el('div', 'ar-l1'), run = c.state === 'running', b = busy.has(dkHost + c.id), bad = /unhealthy|restarting/i.test(c.status) || c.state === 'dead' || (c.state === 'exited' && /\((?!0\))\d+\)/.test(c.status));
  l1.append(el('span', 'ar-dot ' + (b ? 'busy' : run ? (bad ? 'warn' : 'ok') : bad ? 'bad' : 'idle')), el('span', 'ar-name', c.service || c.name), el('span', 'ar-st', c.status));
  const a = el('div', 'ar-tags'); a.style.cssText = 'margin-left:6px;flex:none;flex-wrap:nowrap';
  a.append(ib('play', 'Start', () => act(dkHost + c.id, c.name + ': starting…', () => call('containerAction', { id: dkHost, cid: c.id, op: 'start' })), '', run || b), ib('stop', 'Stop', () => act(dkHost + c.id, c.name + ': stopping…', () => call('containerAction', { id: dkHost, cid: c.id, op: 'stop' })), '', !run || b),
    ib('restart', 'Restart', () => act(dkHost + c.id, c.name + ': restarting…', () => call('containerAction', { id: dkHost, cid: c.id, op: 'restart' })), '', b), ib('file', 'Last 300 log lines', async () => { try { dialog(c.name + ' log', await call('containerLogs', { id: dkHost, cid: c.id })); } catch {} }));
  l1.append(a); row.append(l1);
  const l2 = el('div', 'ar-l2'); l2.append(el('span', '', c.image)); for (const p of c.ports.slice(0, 4)) l2.append(el('span', '', p)); row.append(l2);
  if (run && c.stats) { const l3 = el('div', 'ar-l3'), h = ((HIST.get(dkHost) || new Map()).get(c.id) || { cpu: [] }); l3.append(el('span', 'ar-nums', `CPU ${c.stats.cpu.toFixed(1)}%  ·  ${fb(c.stats.mem)}`), spark(h.cpu, 90, 18)); row.append(l3); }
  return row;
}
function drawDocker() {
  const b = ui.panes.docker, top = b.scrollTop; b.textContent = '';
  const bx = el('div', 'ar-hosts'); for (const h of S.hosts) { const x = DK.get(h.id) || {}, t = el('div', 'ar-host' + (h.id === dkHost ? ' on' : '')); t.append(el('span', 'ar-dot ' + (x.err ? 'bad' : x.d ? 'ok' : 'busy')), el('span', '', h.name)); t.onclick = () => { dkHost = h.id; lsSet('arDkHost', h.id); if (!(DK.get(h.id) || {}).d) pollDocker(h.id); drawDocker(); }; bx.append(t); }
  const r = el('div', 'ar-sp-r'); r.append(ib('refresh', 'Refresh now', () => pollDocker(dkHost, true), '', !dkHost), ib('plus', 'Add a Docker server', () => hostForm())); bx.append(r); b.append(bx);
  if (!S.hosts.length) { b.append(empty('No Docker servers yet.\nAdd one of your saved SSH servers to see containers, compose stacks and host statistics. Nothing is installed on the server.')); b.append(tb('Add a Docker server', '', () => hostForm(), 'primary')); return; }
  const x = DK.get(dkHost) || {};
  if (x.err) { b.append(el('div', 'ar-errbox', x.err)); const a = el('div', 'ar-acts'); a.append(tb('Retry', '', () => pollDocker(dkHost, true), 'primary'), tb('Server settings', '', () => hostForm(S.hosts.find((h) => h.id === dkHost)))); b.append(a); }
  const d = x.d; if (!d) { if (!x.err) b.append(empty('Connecting…')); return; }
  const h = d.host, card = el('div', 'ar-card ar-pad'), cpuH = (HIST.get(dkHost) || new Map()).get('host');
  const mu = h.memTotal - h.memFree; card.append(el('div', 'ar-sub', `Docker ${d.version}${h.cpus ? ' · ' + h.cpus + ' CPUs' : ''}${h.uptime ? ' · up ' + upText(h.uptime) : ''} · load ${h.load.map((v) => v.toFixed(2)).join(' ')}`));
  if (h.memTotal) card.append(diskRow('Memory', mu, h.memTotal, h.memFree)); if (h.swapTotal) card.append(diskRow('Swap', h.swapTotal - h.swapFree, h.swapTotal, h.swapFree));
  if (cpuH && cpuH.cpu.length > 1) { const w = el('div', 'ar-l3'); w.append(el('span', 'ar-nums', `Containers CPU ${cpuH.cpu[cpuH.cpu.length - 1].toFixed(0)}%`), spark(cpuH.cpu, 160, 22)); card.append(w); }
  const seen = new Set(); for (const k of h.disks) { if (seen.has(k.fs + k.total)) continue; seen.add(k.fs + k.total); card.append(diskRow(k.mount, k.used, k.total, k.free)); } b.append(card);
  const f = ui.q.value.trim().toLowerCase(), cs = d.containers.filter((c) => !f || (c.name + ' ' + c.image + ' ' + c.project).toLowerCase().includes(f)), groups = new Map();
  for (const c of cs) { const k = c.project || ''; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(c); }
  for (const [p, list] of [...groups].sort((a, z) => (a[0] === '') - (z[0] === '') || a[0].localeCompare(z[0]))) {
    const run = list.filter((c) => c.state === 'running').length, hd = el('div', 'ar-sech'); hd.append(el('b', '', p ? '⧉ ' + p : 'Other containers'), el('span', 'ar-st', `${run}/${list.length} running`)); b.append(hd);
    for (const c of list.sort((a, z) => (a.service || a.name).localeCompare(z.service || z.name))) b.append(contRow(c));
  }
  if (!cs.length) b.append(empty(d.hidden ? 'No arr containers found. Turn on "Show every container" in the server settings.' : 'No containers.'));
  else if (d.hidden) b.append(el('div', 'ar-sub', `${d.hidden} unrelated container${d.hidden === 1 ? '' : 's'} hidden (server settings: show every container).`));
  b.scrollTop = top;
}
function sudoSelect(val) { const sel = el('select'); sel.append(new Option('No sudo: the login user may run docker', ''), new Option('sudo, passwordless', 'nopw'), new Option("sudo, using this server's saved SSH password", 'pw')); sel.value = val || ''; return sel; }
function modal(title, build) {
  const d = el('div', 'ar-dlg'), c = el('div'), form = el('div', 'ar-form'); c.append(el('h4', '', title), form); d.append(c); d.onclick = (e) => { if (e.target === d) d.remove(); }; ui.root.append(d); build(form, () => d.remove()); return d;
}
function hostForm(h) {
  modal(h ? 'Server: ' + h.name : 'Add a Docker server', (f, close) => {
    const free = S.servers.filter((s) => !S.hosts.some((x) => x.id === s.id)), sel = el('select'), su = sudoSelect(h ? h.sudo : ''), all = el('input'); all.type = 'checkbox'; all.checked = !!(h && h.all);
    for (const s of free) sel.append(new Option(s.name, s.id));
    if (!h) f.append(el('label', '', 'SSH server'), sel);
    f.append(el('div', 'ar-help', 'Connect logs in with the SSH login you already saved and runs the docker command there. The user needs docker access (docker group) or sudo.'), el('label', '', 'Run docker as'), su);
    const ck = el('label', 'ck'); ck.append(all, ' Show every container, not just the arr stack and the compose projects it belongs to'); f.append(ck);
    const a = el('div', 'ar-acts'), go = tb(h ? 'Save' : 'Add', '', async () => { try { if (h) await call('updateHost', { id: h.id, sudo: su.value, all: all.checked }); else await call('addHost', { id: sel.value, sudo: su.value }); } catch { return; } close(); await loadState(); if (!h) { dkHost = sel.value; lsSet('arDkHost', dkHost); } DK.delete(dkHost); drawAll(); pollDocker(dkHost, true); }, 'primary');
    if (!h && !free.length) { go.disabled = true; f.append(el('div', 'ar-help', S.servers.length ? 'Every saved SSH server is already added.' : 'No saved SSH servers yet. Add one in Connect first.')); }
    a.append(go, tb('Cancel', '', close)); if (h) a.append(tb('Remove', 'Only removes it from this list', async () => { if (!confirm(`Remove ${h.name} from the Arr stack panel? Nothing changes on the server.`)) return; try { await call('removeHost', { id: h.id }); } catch { return; } close(); await loadState(); DK.delete(h.id); drawAll(); }, 'danger')); f.append(a);
  });
}

// ---- services (setup) ----
const KEYLABEL = { plex: 'Plex token (X-Plex-Token)', jellyfin: 'API key (Dashboard → API keys)', emby: 'API key (Settings → API keys)', qbittorrent: '', sabnzbd: 'API key (Config → General)' };
function serviceForm(i) {
  modal(i ? 'Edit ' + i.name : 'Add a service', (f, close) => {
    const kind = el('select'); for (const [k, v] of Object.entries(S.kinds)) kind.append(new Option(v.label, k)); kind.value = i ? i.kind : 'sonarr'; if (i) kind.disabled = true;
    const name = el('input'), url = el('input'), tr = el('select'), host = el('select'), ins = el('input'), key = el('input'), user = el('input'), pass = el('input'); ins.type = 'checkbox'; key.type = 'password'; pass.type = 'password'; key.autocomplete = pass.autocomplete = 'off';
    tr.append(new Option('directly from this computer', 'direct'), new Option('through an SSH server (curl runs there)', 'ssh')); for (const s of S.servers) host.append(new Option(s.name, s.id));
    if (i) { name.value = i.name; url.value = i.url; tr.value = i.transport; host.value = i.host; ins.checked = i.insecure; user.value = i.user; }
    const kl = el('label'), kw = el('div'), hw = el('div'), qw = el('div'); kw.append(kl, key); hw.append(el('label', '', 'SSH server'), host); qw.append(el('label', '', 'User name'), user, el('label', '', 'Password'), pass);
    const upd = () => { const k = kind.value; url.placeholder = `http://192.168.1.10:${(S.kinds[k] || {}).port || 80}`; if (!i) name.placeholder = KL(k); kl.textContent = (KEYLABEL[k] !== undefined ? KEYLABEL[k] : 'API key (Settings → General)') + (i && i.hasKey ? '  (saved: leave empty to keep)' : ''); kw.hidden = k === 'qbittorrent'; qw.hidden = k !== 'qbittorrent'; hw.hidden = tr.value !== 'ssh'; if (k === 'qbittorrent' && i && i.hasPass) pass.placeholder = '(saved: leave empty to keep)'; };
    kind.onchange = tr.onchange = upd; upd();
    const ck = el('label', 'ck'); ck.append(ins, ' Accept a self-signed certificate');
    f.append(el('label', '', 'Type'), kind, el('label', '', 'Name'), name, el('label', '', 'Address (with its URL base if it has one, e.g. http://nas:8989/sonarr)'), url, el('label', '', 'Reach it'), tr, hw, kw, qw, ck);
    f.append(el('div', 'ar-help', 'The key / password is stored encrypted and is never shown in the window. "Through an SSH server" is for services that only listen on the server itself: use the address as the server sees it (e.g. http://127.0.0.1:8989).'));
    const a = el('div', 'ar-acts'), save = async (andTest) => { let id; try { id = await call('saveInstance', { id: i && i.id, kind: kind.value, name: name.value, url: url.value, transport: tr.value, host: host.value, insecure: ins.checked, key: key.value, user: user.value, pass: pass.value }); } catch { return; } close(); await loadState(); drawAll(); refresh(true); if (andTest) { try { Mod.toast(await call('test', { id })); } catch {} } };
    a.append(tb('Save and test', '', () => save(true), 'primary'), tb('Cancel', '', close)); if (i) a.append(tb('Delete', '', async () => { if (!confirm(`Remove ${i.name} from the Arr stack panel? The service itself is not touched.`)) return; try { await call('removeInstance', { id: i.id }); } catch { return; } SNAP.delete(i.id); close(); await loadState(); drawAll(); }, 'danger')); f.append(a);
  });
}
function discoverForm(h) {
  modal('Detect services on ' + h.name, (f, close) => {
    f.append(el('div', 'ar-help', 'Looks at the containers on this server and, for the *arr apps, SABnzbd and Plex, reads their API key / token from the config folder. Keys are kept encrypted in Connect; nothing leaves your computer or this server.'));
    const list = el('div', 'ar-dlist'), tr = el('select'), go = tb('Add selected', '', () => {}, 'primary'); tr.append(new Option('Reach them directly from this computer (server address + published port)', 'direct'), new Option('Reach them through this SSH server', 'ssh')); go.disabled = true;
    f.append(list, el('label', '', 'How should Connect reach them?'), tr); const a = el('div', 'ar-acts'); a.append(go, tb('Cancel', '', close)); f.append(a); list.append(el('div', 'ar-sub', 'Looking…'));
    const checks = [];
    quiet('discover', { id: h.id }).then((cs) => {
      list.textContent = ''; if (!cs.length) list.append(el('div', 'ar-sub', 'No known services found in the containers of this server.'));
      for (const c of cs) { const r = el('label', 'ck ar-drow'), ck = el('input'); ck.type = 'checkbox'; ck.checked = !c.already && c.running; ck.disabled = c.already; ck.dataset.t = c.token; checks.push(ck); r.append(ck, el('b', '', c.name), chip(KL(c.kind)), el('span', 'ar-st', c.already ? 'already added' : !c.running ? 'not running' : c.hasKey ? 'key found' : c.kind === 'qbittorrent' || c.kind === 'jellyfin' || c.kind === 'emby' ? 'add the ' + (c.kind === 'qbittorrent' ? 'login' : 'API key') + ' afterwards' : 'no key found')); list.append(r); }
      go.disabled = false;
    }).catch((e) => { list.textContent = ''; list.append(el('div', 'ar-errbox', errText(e))); });
    go.onclick = async () => { const tokens = checks.filter((c) => c.checked).map((c) => c.dataset.t); if (!tokens.length) return; let n; try { n = await call('addDiscovered', { id: h.id, tokens, transport: tr.value }); } catch { return; } close(); await loadState(); drawAll(); refresh(true); Mod.toast(`${n} service${n === 1 ? '' : 's'} added. Services that need a login or an API key: open them with ✎.`); };
  });
}
function drawServices() {
  const b = ui.panes.services; b.textContent = '';
  b.append(el('h5', 'ar-h', 'Services')); const a = el('div', 'ar-acts'); a.style.paddingLeft = '0'; a.append(tb('Add a service', '', () => serviceForm(), 'primary')); b.append(a);
  if (!S.instances.length) b.append(el('div', 'ar-sub', 'Nothing yet. Add a service by hand, or detect them from a Docker server below.'));
  for (const i of S.instances) {
    const r = el('div', 'ar-row'), l1 = el('div', 'ar-l1'), sn = SNAP.get(i.id); l1.append(el('span', 'ar-dot ' + (!sn ? 'busy' : sn.ok ? 'ok' : 'bad')), el('b', 'ar-name', i.name), chip(KL(i.kind)));
    const t = el('div', 'ar-tags'); t.style.cssText = 'margin-left:auto;flex:none'; t.append(ib('check', 'Test', async () => { try { Mod.toast(await call('test', { id: i.id })); } catch (e) {} refresh(true); }), ib('edit', 'Edit', () => serviceForm(i))); l1.append(t); r.append(l1);
    r.append(el('div', 'ar-sub', i.url + (i.transport === 'ssh' ? '  ·  via ' + i.hostName : '') + (i.hasKey || i.hasPass ? '' : '  ·  no key / login saved'))); if (sn && !sn.ok) r.append(el('div', 'ar-msg bad', sn.error)); b.append(r);
  }
  b.append(el('h5', 'ar-h', 'Docker servers')); b.append(el('div', 'ar-sub', 'Saved SSH servers that run Docker: used for container and host statistics, and to detect services with their API keys.'));
  for (const h of S.hosts) { const r = el('div', 'ar-row'), l1 = el('div', 'ar-l1'); l1.append(el('b', 'ar-name', h.name), el('span', 'ar-st', h.sudo === 'pw' ? 'sudo + saved password' : h.sudo === 'nopw' ? 'sudo' : 'no sudo')); const t = el('div', 'ar-tags'); t.style.cssText = 'margin-left:auto;flex:none'; t.append(tb('Detect services', 'Find the arr apps in Docker and read their API keys', () => discoverForm(h)), ib('gear', 'Server settings', () => hostForm(h))); l1.append(t); r.append(l1); b.append(r); }
  const a2 = el('div', 'ar-acts'); a2.style.paddingLeft = '0'; a2.append(tb('Add a Docker server', '', () => hostForm())); b.append(a2);
  b.append(el('h5', 'ar-h', 'Search and requests')); b.append(el('div', 'ar-sub', S.tmdb ? 'TMDB is set: searches use TMDB metadata and posters. Change the key in Settings → Modules → Arr stack (gear).' : 'Searches use Sonarr / Radarr themselves (their built-in lookup). For TMDB metadata and richer results, add a free TMDB key in Settings → Modules → Arr stack (gear).'));
}

// ---- search / request ----
let results = [], searchVia = '', searching = false;
const posterCache = new Map();
function poster(box, url) {
  if (!url) return; if (posterCache.has(url)) { const v = posterCache.get(url); if (v) { const im = el('img'); im.src = v; box.textContent = ''; box.append(im); } return; }
  quiet('image', { url }).then((d) => { posterCache.set(url, d); if (d && box.isConnected) { const im = el('img'); im.src = d; box.textContent = ''; box.append(im); } }).catch(() => posterCache.set(url, ''));
}
async function doSearch() {
  const q = ui.sq.value.trim(); if (q.length < 2) return; searching = true; drawSearch();
  try { const r = await quiet('search', { q, type: ui.stype.value }); results = r.results; searchVia = r.via; } catch (e) { results = []; searchVia = ''; ui.results.textContent = ''; ui.results.append(el('div', 'ar-errbox', errText(e))); searching = false; return; }
  searching = false; drawSearch();
}
function drawSearch() {
  const rs = ui.results; rs.textContent = ''; if (searching) { rs.append(empty('Searching…')); return; }
  if (!results.length) { rs.append(empty(ui.sq.value.trim() ? 'No results.' : 'Search for a movie or a TV show to request it.\n' + (S.tmdb ? 'Metadata from TMDB.' : 'Using the lookup of Sonarr / Radarr. A TMDB key (module settings) gives richer results.'))); return; }
  for (const r of results) {
    const row = el('div', 'ar-res'), p = el('div', 'ar-poster', r.type === 'movie' ? '🎬' : '📺'), body = el('div', 'ar-rb'), l1 = el('div', 'ar-l1');
    l1.append(el('b', 'ar-name', r.title), el('span', 'ar-st', [r.year, r.type === 'movie' ? 'Movie' : 'TV', r.rating ? '★ ' + r.rating : ''].filter(Boolean).join(' · '))); body.append(l1, el('div', 'ar-ov', r.overview || ''));
    const a = el('div', 'ar-acts'); a.style.padding = '2px 0 0'; if (r.inLib) a.append(chip('In library', 'ok')); else a.append(tb('Request', '', () => requestForm(r), 'primary')); body.append(a); row.append(p, body); rs.append(row); poster(p, r.img);
  }
  rs.append(el('div', 'ar-sub', searchVia === 'tmdb' ? 'Results: TMDB' : 'Results: Sonarr / Radarr lookup'));
}
function requestForm(r) {
  modal('Request: ' + r.title + (r.year ? ' (' + r.year + ')' : ''), async (f, close) => {
    f.append(el('div', 'ar-sub', 'Loading…'));
    let targets, opts, id;
    try { targets = await quiet('targets', { type: r.type }); if (!targets.length) throw new Error(r.type === 'movie' ? 'Radarr is not set up' : 'Sonarr is not set up'); id = targets[0].id; opts = await quiet('options', { id }); } catch (e) { f.textContent = ''; f.append(el('div', 'ar-errbox', errText(e)), tb('Close', '', close)); return; }
    f.textContent = '';
    const tsel = el('select'), prof = el('select'), root = el('select'), mon = el('select'), stype = el('select'), avail = el('select'), srch = el('input'); srch.type = 'checkbox'; srch.checked = true;
    for (const t of targets) tsel.append(new Option(t.name, t.id)); const fill = (o) => { prof.textContent = ''; root.textContent = ''; for (const p of o.profiles) prof.append(new Option(p.name, p.id)); for (const x of o.roots) root.append(new Option(`${x.path}  (${fb(x.free)} free)`, x.path)); };
    fill(opts); tsel.onchange = async () => { try { fill(await quiet('options', { id: tsel.value })); } catch (e) { Mod.toast(errText(e)); } };
    for (const [v, l] of [['all', 'All episodes'], ['future', 'Future episodes'], ['missing', 'Missing episodes'], ['existing', 'Existing episodes'], ['firstSeason', 'First season'], ['lastSeason', 'Latest season'], ['pilot', 'Pilot only'], ['none', 'None']]) mon.append(new Option(l, v));
    for (const [v, l] of [['standard', 'Standard'], ['anime', 'Anime'], ['daily', 'Daily']]) stype.append(new Option(l, v)); for (const [v, l] of [['released', 'Released'], ['inCinemas', 'In cinemas'], ['announced', 'Announced']]) avail.append(new Option(l, v));
    if (targets.length > 1) f.append(el('label', '', r.type === 'movie' ? 'Radarr' : 'Sonarr'), tsel);
    f.append(el('label', '', 'Quality profile'), prof, el('label', '', 'Folder'), root);
    if (r.type === 'tv') f.append(el('label', '', 'Monitor'), mon, el('label', '', 'Series type'), stype); else f.append(el('label', '', 'Minimum availability'), avail);
    const ck = el('label', 'ck'); ck.append(srch, r.type === 'movie' ? ' Search for the movie right away' : ' Search for missing episodes right away'); f.append(ck);
    const a = el('div', 'ar-acts'), go = tb('Request', '', async () => {
      go.disabled = true; try { const x = await call('request', { id: tsel.value, tmdbId: r.tmdbId, tvdbId: r.tvdbId, profileId: prof.value, root: root.value, monitor: r.type === 'tv' ? mon.value : 'all', seriesType: stype.value, avail: avail.value, search: srch.checked }); close(); Mod.toast(`Requested: ${x.title}`); r.inLib = true; drawSearch(); refresh(true); } catch { go.disabled = false; }
    }, 'primary'); if (!prof.options.length || !root.options.length) { go.disabled = true; f.append(el('div', 'ar-help', 'This service has no quality profile or root folder yet: create them in its own settings first.')); }
    a.append(go, tb('Cancel', '', close)); f.append(a);
  });
}

// ---- panel ----
const VIEWS = [['overview', 'Overview'], ['downloads', 'Downloads'], ['watching', 'Watching'], ['docker', 'Docker'], ['search', 'Search'], ['services', 'Services']];
function drawLive() { drawSummary(); drawNav(); if (view === 'overview') drawOverview(); else if (view === 'downloads') drawDownloads(); else if (view === 'watching') drawWatching(); else if (view === 'services') drawServices(); }
function drawAll() { drawNav(); drawSummary(); ({ overview: drawOverview, downloads: drawDownloads, watching: drawWatching, docker: drawDocker, search: drawSearch, services: drawServices })[view](); }
function drawNav() {
  const nv = ui.nav; nv.textContent = ''; const counts = { downloads: snaps((i) => role(i) === 'download').reduce((a, x) => a + x.d.queueTotal, 0), watching: snaps((i) => role(i) === 'media').reduce((a, x) => a + x.d.sessions.filter((s) => s.watching).length, 0) };
  for (const [v, l] of VIEWS) { const b = el('button', view === v ? 'on' : '', l); if (counts[v]) b.append(' ', el('small', '', String(counts[v]))); b.onclick = () => setView(v); nv.append(b); }
  ui.bar.hidden = !['downloads', 'docker'].includes(view); ui.sbar.hidden = view !== 'search';
}
function setView(v) { view = v; lsSet('arView', v); for (const k in ui.panes) ui.panes[k].hidden = k !== v; if (v === 'docker' && dkHost) pollDocker(dkHost, true); drawAll(); }
function build(box) {
  ui.root = box; box.classList.add('ar-root');
  ui.nav = el('div', 'ar-nav'); ui.bar = el('div', 'ar-bar2'); ui.sbar = el('div', 'ar-bar2'); ui.sum = el('div', 'ar-sum'); ui.body = el('div', 'ar-body');
  ui.q = el('input'); ui.q.placeholder = 'Filter…'; ui.q.oninput = () => { if (view === 'downloads') drawDownloads(); else drawDocker(); }; ui.spin = el('span', 'ar-spin'); ui.bar.append(ui.q, ui.spin);
  ui.sq = el('input'); ui.sq.placeholder = 'Search movies and TV shows…'; ui.sq.onkeydown = (e) => { if (e.key === 'Enter') doSearch(); }; ui.stype = el('select'); ui.stype.append(new Option('All', 'all'), new Option('Movies', 'movie'), new Option('TV', 'tv')); ui.stype.onchange = () => { if (ui.sq.value.trim()) doSearch(); };
  const go = tb('Search', '', doSearch, 'primary'); ui.sbar.append(ui.sq, ui.stype, go); ui.sbar.hidden = true;
  ui.panes = {}; for (const [v] of VIEWS) { const p = el('div', 'ar-pane'); p.hidden = v !== view; ui.panes[v] = p; ui.body.append(p); }
  ui.results = el('div', 'ar-results'); ui.panes.search.append(ui.results);
  box.append(ui.nav, ui.bar, ui.sbar, ui.sum, ui.body);
}
async function init() {
  await loadState(); drawAll(); refresh(); startTimer(); if (view === 'docker' && dkHost) pollDocker(dkHost);
}
lsGet('modPanelW:arr', '') || lsSet('modPanelW:arr', '520');
const panel = Mod.sidebarPanel({ id: 'arr', label: '*arr', icon: 'server', mount: build, show: () => init() });
{ const tab = document.querySelector('.modPanelTab[title="*arr"]'); if (tab) { tab.classList.add('ar-tab'); tab.textContent = '*arr'; } }
//==== css ====
.modPanelTab.ar-tab{top:calc(50% + 88px)}
.ar-tab{writing-mode:vertical-rl;font-weight:600;letter-spacing:.04em;font-size:12px;line-height:1}
.ar-root{height:100%;font-size:13px;display:flex;flex-direction:column;position:relative;min-height:0}
.ar-nav{display:flex;gap:2px;padding:6px 8px 0;border-bottom:1px solid var(--line);flex:none;overflow-x:auto}
.ar-nav button{border:0;border-bottom:2px solid transparent;border-radius:0;background:none;color:var(--mut);padding:5px 8px;white-space:nowrap}
.ar-nav button.on{color:var(--fg);border-bottom-color:var(--acc)}.ar-nav small{opacity:.8;background:var(--acc);color:var(--accfg);border-radius:8px;padding:0 5px;margin-left:2px}
.ar-bar2{display:flex;gap:8px;align-items:center;padding:6px 8px;flex:none;color:var(--mut);font-size:12px}
.ar-bar2 input{flex:1;min-width:60px;padding:3px 8px}.ar-bar2[hidden],.ar-pane[hidden]{display:none}
.ar-sum{display:flex;flex-wrap:wrap;gap:4px 12px;padding:0 8px 6px;color:var(--mut);font-size:12px;flex:none}.ar-sum b{color:var(--fg);font-weight:600}.ar-sum b.bad{color:var(--bad)}
.ar-body{flex:1;min-height:0;overflow-y:auto;padding:4px 8px 12px;overscroll-behavior:contain}
.ar-pane{display:flex;flex-direction:column;gap:8px}
.ar-empty{color:var(--mut);padding:16px;text-align:center;white-space:pre-wrap}
.ar-errbox{color:var(--bad);padding:8px 10px;border:1px solid var(--bad);border-radius:8px;white-space:pre-wrap;word-break:break-word;font-size:12px}
.ar-h{margin:8px 0 0;color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.08em;font-weight:600}
.ar-dot{width:9px;height:9px;border-radius:50%;background:var(--mut);flex:none}
.ar-dot.ok{background:var(--ok)}.ar-dot.warn{background:#f5a524}.ar-dot.bad{background:var(--bad)}.ar-dot.idle{background:var(--mut)}
.ar-dot.busy{background:none;border:2px solid var(--acc);border-right-color:transparent;animation:arspin .8s linear infinite;box-sizing:border-box}
@keyframes arspin{to{transform:rotate(360deg)}}
.ar-card{border:1px solid var(--line);border-radius:8px;padding:8px 10px;display:flex;flex-direction:column;gap:5px}
.ar-card.ar-pad{padding:8px 10px}
.ar-ch,.ar-l1{display:flex;align-items:center;gap:8px;min-width:0}
.ar-name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.ar-st{color:var(--mut);font-size:11px;margin-left:auto;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.ar-chip{font-size:10px;padding:1px 6px;border-radius:9px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
.ar-chip.ok{color:var(--ok);border-color:var(--ok)}.ar-chip.bad{color:var(--bad);border-color:var(--bad)}.ar-chip.warn{color:#f5a524;border-color:#f5a524}
.ar-sub{color:var(--mut);font-size:11px;word-break:break-word}
.ar-health{font-size:11px;padding:3px 8px;border-radius:6px;border:1px solid var(--line);word-break:break-word}.ar-health.warn{color:#f5a524;border-color:color-mix(in srgb,#f5a524 50%,var(--line))}.ar-health.bad{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 50%,var(--line))}
.ar-stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(88px,1fr));gap:6px}
.ar-stats>div{border:1px solid var(--line);border-radius:6px;padding:4px 8px;display:flex;flex-direction:column}.ar-stats b{font-size:14px}.ar-stats small{color:var(--mut);font-size:10px}
.ar-bar{height:5px;border-radius:3px;background:color-mix(in srgb,var(--fg) 10%,transparent);overflow:hidden}.ar-bar i{display:block;height:100%;background:var(--acc);border-radius:3px;transition:width .4s}
.ar-bar.warn i{background:#f5a524}.ar-bar.bad i{background:var(--bad)}
.ar-disk{display:flex;flex-direction:column;gap:3px;margin-top:2px}
.ar-row{border:1px solid var(--line);border-radius:8px;padding:7px 10px;display:flex;flex-direction:column;gap:4px}
.ar-l2{color:var(--mut);font-size:11px;display:flex;flex-wrap:wrap;gap:2px 10px;word-break:break-all;align-items:center}
.ar-l3{display:flex;align-items:center;gap:8px}.ar-nums{font-size:11px;color:var(--mut);white-space:nowrap;min-width:110px}
.ar-msg{font-size:11px;white-space:pre-wrap;word-break:break-word}.ar-msg.bad{color:var(--bad)}.ar-msg.warn{color:#f5a524}
.ar-sech{display:flex;align-items:baseline;gap:8px;margin-top:6px;padding:0 2px}.ar-sech b{font-size:13px}
.ar-title{font-weight:600}
.ar-sp{display:block}.ar-sp .a{fill:color-mix(in srgb,var(--acc) 22%,transparent);stroke:none}.ar-sp .l{fill:none;stroke:var(--acc);stroke-width:1.4}
.ar-hosts{display:flex;gap:4px;align-items:center;overflow-x:auto}
.ar-host{display:flex;align-items:center;gap:6px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;cursor:pointer;white-space:nowrap;color:var(--mut)}.ar-host.on{color:var(--fg);border-color:var(--acc)}
.ar-sp-r{margin-left:auto;display:flex;gap:4px}
.ar-acts{display:flex;gap:6px;flex-wrap:wrap;align-items:center;padding:0 0 4px}
.ar-tags{display:flex;gap:4px;align-items:center}
.ar-ib{padding:3px 7px;font-size:12px}.ar-ib svg{display:block}.ar-ib:disabled{opacity:.3}.ar-ib.danger{color:var(--bad)}
.ar-res{display:flex;gap:10px;border:1px solid var(--line);border-radius:8px;padding:8px}
.ar-poster{width:62px;height:92px;flex:none;border-radius:5px;background:var(--btn);display:flex;align-items:center;justify-content:center;font-size:22px;overflow:hidden}.ar-poster img{width:100%;height:100%;object-fit:cover;display:block}
.ar-rb{min-width:0;flex:1;display:flex;flex-direction:column;gap:3px}
.ar-ov{color:var(--mut);font-size:11px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.ar-results{display:flex;flex-direction:column;gap:8px}
.ar-dlg{position:absolute;inset:0;z-index:6;background:#0008;display:flex;align-items:center;justify-content:center;padding:12px}
.ar-dlg>div{background:var(--panel);border:1px solid var(--line);border-radius:10px;width:100%;max-height:92%;display:flex;flex-direction:column;box-shadow:var(--shadow);overflow:hidden}
.ar-dlg h4{margin:0;padding:10px 12px;border-bottom:1px solid var(--line)}.ar-dlg pre{margin:0;padding:10px 12px;overflow:auto;font:12px/1.4 var(--mono,monospace);white-space:pre-wrap;word-break:break-word;flex:1}.ar-dlg .f{padding:8px 12px;border-top:1px solid var(--line);display:flex;justify-content:flex-end}
.ar-form{display:flex;flex-direction:column;gap:8px;padding:12px;overflow-y:auto}.ar-form label{color:var(--mut);font-size:11px;margin-bottom:-4px}.ar-form .ck{display:flex;gap:6px;align-items:center;color:var(--fg);font-size:12px;margin:0}.ar-form .ar-help{color:var(--mut);font-size:11px}
.ar-form>div[hidden]{display:none}.ar-form>div>label{display:block;margin:4px 0}.ar-form>div>input{width:100%;box-sizing:border-box}
.ar-dlist{display:flex;flex-direction:column;gap:6px}.ar-drow{border:1px solid var(--line);border-radius:6px;padding:5px 8px}
