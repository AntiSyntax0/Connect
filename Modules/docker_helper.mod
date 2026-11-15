//==== module ====
{
  "id": "docker_helper",
  "name": "Docker helper",
  "description": "A Docker sidebar for your SSH servers: docker compose stacks (found by scanning for compose files and docker ps), containers, networks and volumes, live CPU / memory / network graphs, start / stop / restart, exec into a container, live log tail and a compose file editor. Works over your saved SSH logins through the docker CLI on the server: no socket exposed, nothing to install on the server.",
  "version": "0.1.0",
  "minApi": 3,
  "permissions": [
    "ssh",
    "sshStream",
    "data"
  ],
  "config": [
    {
      "key": "scanDirs",
      "label": "Folders to scan for compose files",
      "type": "text",
      "default": "~ /opt /srv /home",
      "placeholder": "~ /opt /srv /home",
      "help": "Space separated, searched 4 levels deep on each Docker host. Stacks that are running are always found, whatever folder they live in. Each host can override this."
    },
    {
      "key": "interval",
      "label": "Refresh every (seconds)",
      "type": "number",
      "default": 8,
      "help": "How often the open sidebar refreshes status and stats (5 to 120)."
    }
  ]
}
//==== main ====
// Docker helper (main process). Everything runs through the `docker` CLI on the server over an SSH login you already saved in Connect,
// so there is no Docker socket to expose and nothing to install on the server. Needs a user that may run docker (docker group) or
// passwordless sudo (per-host option). The window only ever sees parsed results.
const sq = (v) => "'" + String(v).replace(/'/g, "'\\''") + "'";
const PATHFIX = 'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/snap/bin:$HOME/.local/bin"; export PATH; ';
const remoteCmd = (script) => '/bin/sh -c ' + sq(PATHFIX + script);
const rid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
const clip = (s, n) => { s = String(s == null ? '' : s); return s.length > n ? s.slice(0, n) + '\n… (cut)' : s; };

// ---- hosts: a Docker host is one of the saved SSH servers, plus per-host options ----
const SUDO = ['', 'nopw', 'pw']; // '' = docker as the login user, 'nopw' = sudo without a password, 'pw' = sudo with the server's saved SSH password
const sudoMode = (v) => (v === true ? 'nopw' : SUDO.includes(v) ? v : '');
let hosts = (api.store.get().hosts || []).filter((h) => h && h.id).map((h) => ({ ...h, sudo: sudoMode(h.sudo) }));
const saveHosts = () => api.store.set({ hosts });
const savedServers = () => (api.data.read('servers.json', []) || []).filter((x) => x && (!x.type || x.type === 'ssh'));
const hostRec = (id) => { const h = hosts.find((x) => x.id === String(id)); if (!h) throw new Error('That Docker host is not set up'); return h; };
const hostName = (id) => { const x = savedServers().find((v) => v.id === id); return x ? (x.name || x.host) : '(removed server)'; };

const conns = new Map();
function connFor(id) {
  if (conns.has(id)) return conns.get(id);
  const x = savedServers().find((v) => v.id === id); if (!x) throw new Error('That server is no longer in your list');
  if (x.jumpId) throw new Error(`"${x.name || x.host}" is reached through a jump host, which this module can't use yet.`);
  const pr = api.ssh.connect({ host: x.host, port: x.port, username: x.username, authType: x.authType, keyPath: x.keyPath, password: api.secret.dec(x.password), passphrase: api.secret.dec(x.passphrase), name: x.name });
  conns.set(id, pr); pr.catch(() => { if (conns.get(id) === pr) conns.delete(id); });
  return pr;
}
const dropConn = (id) => { const pr = conns.get(id); conns.delete(id); if (pr) pr.then((c) => c.close(), () => {}); };
async function conn(id) { try { return await connFor(id); } catch (e) { dropConn(id); return connFor(id); } } // one retry on a fresh login
// The saved SSH password of the server, only ever sent down the SSH channel's stdin (never in a command line, a file or the window).
function sudoPw(id) {
  const x = savedServers().find((v) => v.id === id), pw = x ? api.secret.dec(x.password) : '';
  if (!pw) throw new Error('This server has no saved password. Save one in the server settings, or use "passwordless sudo" instead.');
  return pw;
}
async function run(id, script, stdin, ms) {
  if (hostRec(id).sudo === 'pw') stdin = sudoPw(id) + '\n' + (stdin == null ? '' : stdin); // first line: read by the script's prelude
  const c = await conn(id);
  try { return await c.exec(remoteCmd(script), stdin, ms); } catch (e) { if (!/No answer/.test(e.message)) dropConn(id); throw e; }
}
const hint = (t) => /incorrect password|a password is required|no tty present/i.test(t) ? t + '\n\nsudo did not accept the password. Check the saved password of this server, that the user may use sudo, and that sudo is not set to require a terminal.'
  : /permission denied|got permission/i.test(t) ? t + '\n\nThis user may not use Docker on that server. Add it to the "docker" group, or use sudo for this host (host settings).'
  : /not found|No such file/i.test(t) && /docker/i.test(t) ? t + '\n\nDocker does not seem to be installed for this user on that server.' : t;

// shell prelude: d = docker (maybe via sudo), dc = compose v2 or v1.
//   one-shot commands (tty = false): with a saved password the first stdin line is read once and piped to each `sudo -S`.
//   live PTY streams (tty = true): the script switches echo off, announces @@PW, reads the password, and primes sudo's ticket once (see open()).
function prelude(h, tty) {
  const m = h.sudo, cmd = (bin) => m === 'nopw' ? `sudo -n ${bin} "$@"` : m === 'pw' ? (tty ? `sudo -n ${bin} "$@"` : `printf '%s\\n' "$SPW" | sudo -S -p '' ${bin} "$@"`) : `${bin} "$@"`;
  const head = m !== 'pw' ? '' : tty ? `stty -echo 2>/dev/null; echo @@PW; IFS= read -r SPW; stty echo 2>/dev/null; printf '%s\\n' "$SPW" | sudo -S -v -p '' || exit 1; unset SPW\n` : `IFS= read -r SPW\n`;
  return head + `d() { ${cmd('docker')}; }\nif d compose version >/dev/null 2>&1; then dc() { d compose "$@"; }; DCV=v2; elif command -v docker-compose >/dev/null 2>&1; then dc() { ${cmd('docker-compose')}; }; DCV=v1; else dc() { echo 'Docker Compose is not installed on this server' >&2; return 127; }; DCV=none; fi\n`;
}
const dirArg = (d) => { d = String(d).trim(); if (d === '~') return '"$HOME"'; if (d.startsWith('~/')) return '"$HOME"/' + sq(d.slice(2)); return sq(d); };
const okDirs = (s) => String(s || '').trim().split(/\s+/).filter((d) => /^[\w ./~@+-]{1,200}$/.test(d)).slice(0, 12);

const T_CONT = '{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"cmd":{{json .Config.Cmd}},"state":{{json .State}},"labels":{{json .Config.Labels}},"nets":{{json .NetworkSettings.Networks}},"ports":{{json .NetworkSettings.Ports}},"mounts":{{json .Mounts}},"restart":{{json .HostConfig.RestartPolicy.Name}},"created":{{json .Created}}}';
const T_NET = '{"id":{{json .Id}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}},"internal":{{json .Internal}},"ipam":{{json .IPAM.Config}},"created":{{json .Created}}}';
const FIND = "find DIRS -maxdepth 4 -type d \\( -name node_modules -o -name .git -o -name proc -o -name sys \\) -prune -o -type f \\( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name 'compose.*.yml' -o -name 'compose.*.yaml' \\) -print 2>/dev/null | head -300";

const cache = new Map(); // host id -> { at, ov, scanAt, files:[...] }
const inflight = new Map();
const num = (v) => Number(v) || 0;
const dirname = (p) => { const i = String(p).lastIndexOf('/'); return i <= 0 ? '/' : p.slice(0, i); };
const basename = (p) => String(p).replace(/\/+$/, '').split('/').pop();
const parseLines = (t) => String(t || '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

function containerOf(j) {
  const s = j.state || {}, L = j.labels || {}, status = s.Status || 'unknown';
  const kind = s.Restarting ? 'restarting' : s.Dead || status === 'dead' ? 'failed' : s.Running ? (s.Paused ? 'paused' : 'running') : status === 'exited' ? (num(s.ExitCode) !== 0 ? 'failed' : 'exited') : status === 'created' ? 'created' : status;
  const ports = [];
  for (const [k, v] of Object.entries(j.ports || {})) { if (Array.isArray(v) && v.length) { for (const b of v) ports.push(`${b.HostIp && b.HostIp !== '0.0.0.0' && b.HostIp !== '::' ? b.HostIp + ':' : ''}${b.HostPort}→${k}`); } else ports.push(k); }
  const h = s.Health;
  return {
    id: String(j.id).slice(0, 12), full: j.id, name: String(j.name || '').replace(/^\//, ''), image: j.image || '', cmd: Array.isArray(j.cmd) ? j.cmd.join(' ') : '',
    state: status, kind, exit: num(s.ExitCode), error: s.Error || '', oom: !!s.OOMKilled, started: s.StartedAt || '', finished: s.FinishedAt || '', created: j.created || '', restart: j.restart || 'no',
    health: h ? h.Status : '', healthLog: h && Array.isArray(h.Log) && h.Log.length ? clip(String(h.Log[h.Log.length - 1].Output || '').trim(), 300) : '',
    project: L['com.docker.compose.project'] || '', service: L['com.docker.compose.service'] || '', workdir: L['com.docker.compose.project.working_dir'] || '',
    files: String(L['com.docker.compose.project.config_files'] || '').split(',').map((x) => x.trim()).filter(Boolean),
    ports, nets: Object.entries(j.nets || {}).map(([name, n]) => ({ name, ip: n.IPAddress || '', aliases: (n.Aliases || []).filter((a) => !/^[0-9a-f]{12}$/.test(a)) })),
    mounts: (j.mounts || []).map((m) => ({ type: m.Type, name: m.Name || '', src: m.Source || '', dst: m.Destination || '', rw: m.RW !== false })),
  };
}
const bad = (c) => !c.ignored && (c.kind === 'failed' || c.kind === 'restarting' || c.health === 'unhealthy');
function projectStatus(all) {
  if (!all.length) return 'down';
  const cs = all.filter((c) => !c.ignored); // ignored containers never make a stack degraded or failed
  if (!cs.length) return all.some((c) => c.kind === 'running') ? 'running' : 'exited';
  const run = cs.filter((c) => c.kind === 'running' || c.kind === 'paused');
  if (run.length === cs.length) return cs.some(bad) ? 'degraded' : 'running';
  if (run.length) return cs.some(bad) ? 'degraded' : 'running'; // some one-shot jobs finished with 0: still a healthy stack
  return cs.some(bad) ? 'failed' : 'exited';
}
function build(h, p) {
  const ig = new Set(h.ignore || []);
  const containers = p.inspect.map((j) => { const c = containerOf(j); c.ignored = ig.has(c.name); return c; }).sort((a, b) => a.name.localeCompare(b.name));
  const nets = p.nets.map((n) => ({ id: String(n.id).slice(0, 12), name: n.name, driver: n.driver, scope: n.scope, internal: !!n.internal, subnets: (n.ipam || []).map((x) => x.Subnet).filter(Boolean), gateway: ((n.ipam || [])[0] || {}).Gateway || '', created: n.created || '', containers: containers.filter((c) => c.nets.some((x) => x.name === n.name)).map((c) => c.id) }));
  const vols = p.vols.map((v) => ({ name: v.Name, driver: v.Driver, scope: v.Scope, mountpoint: v.Mountpoint || '', containers: containers.filter((c) => c.mounts.some((m) => m.type === 'volume' && m.name === v.Name)).map((c) => c.id) }));
  const projects = [], byKey = new Map();
  const mk = (key, name, dir) => { const o = { key, name, dir, files: [], active: [], containers: [], status: 'down', standalone: false }; byKey.set(key, o); projects.push(o); return o; };
  for (const c of containers) {
    if (!c.project) continue;
    const key = (c.workdir || '') + '|' + c.project; const o = byKey.get(key) || mk(key, c.project, c.workdir);
    o.containers.push(c.id); for (const f of c.files) { if (!o.active.includes(f)) o.active.push(f); if (!o.files.includes(f)) o.files.push(f); }
  }
  for (const f of p.files) {
    const dir = dirname(f); const o = projects.find((x) => x.dir === dir) || mk(dir + '|' + basename(dir), basename(dir), dir);
    if (!o.files.includes(f)) o.files.push(f);
  }
  const alone = containers.filter((c) => !c.project);
  if (alone.length) { const o = mk('standalone', 'Standalone containers', ''); o.standalone = true; o.containers = alone.map((c) => c.id); }
  for (const o of projects) { const cs = o.containers.map((id) => containers.find((c) => c.id === id)); o.status = o.standalone ? (cs.some((c) => c.kind === 'running') ? 'running' : 'exited') : projectStatus(cs); o.files.sort(); }
  projects.sort((a, b) => (a.standalone - b.standalone) || a.name.localeCompare(b.name));
  return { version: p.version, dc: p.dc, info: p.info, containers, networks: nets, volumes: vols, projects, scannedAt: p.scanAt, at: Date.now() };
}

async function overview(id, force) {
  const h = hostRec(id), key = id;
  if (inflight.has(key)) return inflight.get(key);
  const pr = (async () => {
    const old = cache.get(id) || {}, scan = force || !old.scanAt || Date.now() - old.scanAt > 90000;
    const dirs = okDirs(h.dirs || api.config().scanDirs || '~ /opt /srv /home').map(dirArg).join(' ');
    const script = prelude(h) + `v=$(d version --format '{{.Server.Version}}' 2>&1) || { echo '@@error'; echo "$v"; exit 0; }\n` +
      `echo '@@ver'; echo "$v"; echo '@@dc'; echo "$DCV"\n` +
      `echo '@@info'; d info --format '{{.Name}}|{{.NCPU}}|{{.MemTotal}}|{{.OperatingSystem}}|{{.ServerVersion}}' 2>/dev/null\n` +
      `echo '@@inspect'; ids=$(d ps -aq 2>/dev/null); [ -n "$ids" ] && d inspect -f '${T_CONT}' $ids 2>/dev/null\n` +
      `echo '@@nets'; n=$(d network ls -q 2>/dev/null); [ -n "$n" ] && d network inspect -f '${T_NET}' $n 2>/dev/null\n` +
      `echo '@@vols'; d volume ls --format '{{json .}}' 2>/dev/null\n` +
      (scan ? `echo '@@files'; T=""; command -v timeout >/dev/null 2>&1 && T="timeout 25"; $T ${FIND.replace('DIRS', () => dirs || '"$HOME"')}\n` : '') + `echo '@@end'\n`;
    const r = await run(id, script, null, 90000);
    const sec = {}; let cur = null;
    for (const line of r.out.split('\n')) { const m = /^@@(\w+)$/.exec(line); if (m) { cur = m[1]; sec[cur] = []; } else if (cur) sec[cur].push(line); }
    if (sec.error) throw new Error(hint(sec.error.join('\n').trim() || 'Docker is not reachable on this server'));
    if (!sec.ver) throw new Error(hint(clip((r.err || r.out).trim(), 600) || 'No answer from the server'));
    const files = scan ? (sec.files || []).map((x) => x.trim()).filter((x) => x.startsWith('/')) : old.files || [];
    const [iname, ncpu, mem, os, sv] = (sec.info || [''])[0].split('|');
    const ov = build(h, { version: (sec.ver[0] || '').trim(), dc: (sec.dc[0] || '').trim(), info: { name: iname || '', ncpu: num(ncpu), mem: num(mem), os: os || '', version: sv || '' }, inspect: parseLines((sec.inspect || []).join('\n')), nets: parseLines((sec.nets || []).join('\n')), vols: parseLines((sec.vols || []).join('\n')), files, scanAt: scan ? Date.now() : old.scanAt });
    cache.set(id, { at: Date.now(), ov, scanAt: ov.scannedAt, files });
    return ov;
  })();
  inflight.set(key, pr); pr.then(() => inflight.delete(key), () => inflight.delete(key));
  return pr;
}
const known = (id) => { const c = cache.get(id); if (!c) throw new Error('Refresh the host first'); return c.ov; };
const needContainer = (id, cid) => { cid = String(cid); if (!/^[0-9a-f]{12,64}$/.test(cid)) throw new Error('Invalid container id'); if (!known(id).containers.some((c) => c.full.startsWith(cid) || c.id === cid)) throw new Error('Unknown container: refresh first'); return cid; };
const needProject = (id, key) => { const p = known(id).projects.find((x) => x.key === key); if (!p) throw new Error('Unknown stack: refresh first'); return p; };
const needFile = (id, f) => { f = String(f); if (!known(id).projects.some((p) => p.files.includes(f))) throw new Error('That is not one of the compose files found on this host'); return f; };
// docker compose command line for a stack: from its folder, with its files and project name
function composeCmd(p, args) {
  const f = p.active.length ? p.active : p.files.slice(0, 1);
  const named = p.containers.length && /^[\w.-]+$/.test(p.name);
  return (p.dir ? 'cd ' + sq(p.dir) + ' && ' : '') + 'dc ' + f.map((x) => '-f ' + sq(x)).join(' ') + (named ? ' -p ' + sq(p.name) : '') + ' ' + args;
}

api.handle('servers', () => savedServers().map((x) => ({ id: x.id, name: x.name || x.host, host: x.host, jump: !!x.jumpId })));
api.handle('state', () => ({ hosts: hosts.map((h) => ({ ...h, name: hostName(h.id) })), config: api.config() }));
api.handle('addHost', ({ id, sudo, dirs }) => {
  sudo = sudoMode(sudo);
  id = String(id); if (!savedServers().some((x) => x.id === id)) throw new Error('Pick one of your saved SSH servers');
  if (hosts.some((h) => h.id === id)) throw new Error('That server is already a Docker host');
  hosts.push({ id, sudo, dirs: okDirs(dirs).join(' ') }); saveHosts();
});
api.handle('updateHost', ({ id, sudo, dirs }) => { const h = hostRec(id); h.sudo = sudoMode(sudo); h.dirs = okDirs(dirs).join(' '); saveHosts(); cache.delete(id); });
api.handle('removeHost', ({ id }) => { hostRec(id); hosts = hosts.filter((h) => h.id !== id); saveHosts(); cache.delete(id); dropConn(id); for (const [sid, s] of streams) if (s.host === id) closeStream(sid); });
api.handle('setIgnore', ({ id, name, ignore }) => { // by container name, so it survives the container being recreated
  const h = hostRec(id); name = String(name || '').slice(0, 200); if (!name) throw new Error('No container name');
  const set = new Set(h.ignore || []); if (ignore) set.add(name); else set.delete(name); h.ignore = [...set].slice(0, 200); saveHosts();
});
api.handle('overview', ({ id, force }) => overview(id, !!force));

api.handle('stats', async ({ id }) => {
  const h = hostRec(id);
  const r = await run(id, prelude(h) + `d stats --no-stream --format '{{json .}}'`, null, 60000);
  if (r.code !== 0 && !r.out.trim()) throw new Error(hint(clip(r.err.trim(), 400)));
  const B = { b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, kib: 1024, mib: 1048576, gib: 1073741824, tib: 1099511627776 };
  const bytes = (s) => { const m = /^([\d.]+)\s*([a-z]*)/i.exec(String(s).trim()); return m ? Number(m[1]) * (B[m[2].toLowerCase()] || 1) : 0; };
  const pair = (s) => String(s).split('/').map(bytes);
  return parseLines(r.out).map((j) => { const [mu, ml] = pair(j.MemUsage), [rx, tx] = pair(j.NetIO), [br, bw] = pair(j.BlockIO); return { id: String(j.ID || j.Container).slice(0, 12), name: j.Name, cpu: parseFloat(j.CPUPerc) || 0, mem: mu, memLimit: ml, memPct: parseFloat(j.MemPerc) || 0, rx, tx, br, bw, pids: num(j.PIDs) }; });
});

api.handle('containerAction', async ({ id, cid, op }) => {
  if (!['start', 'stop', 'restart', 'pause', 'unpause', 'kill', 'rm'].includes(op)) throw new Error('Unknown action');
  const h = hostRec(id); cid = needContainer(id, cid);
  const r = await run(id, prelude(h) + `d ${op} ${cid} 2>&1`, null, 120000);
  if (r.code !== 0) throw new Error(hint(clip(r.out.trim() || r.err.trim(), 600)));
  return true;
});
api.handle('projectAction', async ({ id, key, op }) => {
  const ops = { up: 'up -d', start: 'start', stop: 'stop', restart: 'restart', down: 'down', pull: 'pull', recreate: 'up -d --force-recreate' };
  if (!ops[op]) throw new Error('Unknown action');
  const h = hostRec(id), p = needProject(id, key); if (p.standalone) throw new Error('Standalone containers have no stack');
  if (!p.files.length && ['up', 'pull', 'recreate'].includes(op)) throw new Error('No compose file is known for this stack');
  if (!p.dir) throw new Error('This stack has no known folder on the server');
  const r = await run(id, prelude(h) + composeCmd(p, ops[op]) + ' 2>&1', null, 600000);
  if (r.code !== 0) throw new Error(hint(clip(r.out.trim(), 1500)));
  return clip(r.out.trim(), 3000);
});

// ---- compose files: read, validate, save (with a .bak of the previous version), resolved view ----
api.handle('readFile', async ({ id, file }) => {
  const h = hostRec(id); file = needFile(id, file);
  const r = await run(id, `F=${sq(file)}; [ -r "$F" ] || { echo "Cannot read $F" >&2; exit 2; }; cksum < "$F" | cut -d' ' -f1,2; head -c 1048576 "$F"`, null, 30000);
  if (r.code !== 0) throw new Error(clip(r.err.trim() || 'Could not read the file', 300));
  const nl = r.out.indexOf('\n'); return { sum: r.out.slice(0, nl), text: r.out.slice(nl + 1) };
});
api.handle('saveFile', async ({ id, file, text, sum, force, dry, nocheck }) => {
  const h = hostRec(id); file = needFile(id, file); text = String(text); if (text.length > 1048576) throw new Error('File is too large');
  const dir = dirname(file);
  const script = prelude(h) + `F=${sq(file)}; T="$F.connect-new"; EXP=${sq(force ? '' : sum || '')}\n` +
    `if [ -n "$EXP" ] && [ "$(cksum < "$F" | cut -d' ' -f1,2)" != "$EXP" ]; then echo CHANGED; exit 3; fi\n` +
    `cat > "$T" || { echo "Cannot write next to $F" >&2; exit 4; }\n` +
    `if [ "$DCV" != none ] && [ -z ${sq(nocheck ? '1' : '')} ]; then out=$(cd ${sq(dir)} && dc -f "$T" config -q 2>&1) || { rm -f "$T"; echo "$out"; exit 5; }; fi\n` +
    (dry ? `rm -f "$T"; echo OK\n` : `cp -p "$F" "$F.bak" 2>/dev/null; cat "$T" > "$F" && rm -f "$T" && cksum < "$F" | cut -d' ' -f1,2 || { echo "Cannot overwrite $F" >&2; exit 6; }\n`);
  const r = await run(id, script, text, 60000);
  if (r.code === 3) return { ok: false, changed: true };
  if (r.code === 5) return { ok: false, invalid: clip(r.out.trim(), 1500) };
  if (r.code !== 0) throw new Error(clip(r.err.trim() || r.out.trim() || 'Save failed', 400));
  return { ok: true, sum: dry ? sum : r.out.trim().split('\n').pop() };
});
api.handle('resolved', async ({ id, key, file }) => {
  const h = hostRec(id), p = needProject(id, key); file = needFile(id, file);
  const r = await run(id, prelude(h) + `cd ${sq(p.dir || dirname(file))} && dc -f ${sq(file)} config 2>&1`, null, 60000);
  return { ok: r.code === 0, text: clip(r.out, 200000) };
});

// ---- live streams: log tail and exec shells (PTY) ----
const streams = new Map(); // sid -> { host, p, kind, timer, buf }
function closeStream(sid) { const s = streams.get(sid); if (!s) return; streams.delete(sid); clearTimeout(s.timer); try { if (s.kind === 'log') s.p.write('\x03'); s.p.kill(); } catch {} }
api.onUnload(() => { for (const sid of [...streams.keys()]) closeStream(sid); });
async function open(id, kind, script, cols, rows) {
  const pw = hostRec(id).sudo === 'pw' ? sudoPw(id) : '';
  if ([...streams.values()].filter((s) => s.kind === kind).length >= (kind === 'log' ? 6 : 4)) throw new Error(`Too many open ${kind === 'log' ? 'log views' : 'shells'}: close one first`);
  const c = await conn(id);
  let p; try { p = await c.spawn(remoteCmd(script), { pty: true, cols, rows }); } catch (e) { dropConn(id); throw e; }
  const sid = rid(), s = { host: id, p, kind, timer: null, buf: '' };
  let armed = !pw, pre = '';
  streams.set(sid, s);
  const flush = () => { s.timer = null; if (s.buf) { api.emit(kind, { sid, text: s.buf }); s.buf = ''; } };
  p.onData((chunk) => {
    if (!armed) { // wait for the script to switch echo off, then hand it the password (never echoed, never shown)
      pre += chunk; const i = pre.indexOf('@@PW'); if (i < 0) return;
      armed = true; chunk = pre.slice(i + 4).replace(/^\r?\n/, ''); pre = ''; p.write(pw + '\n'); if (!chunk) return;
    }
    s.buf += chunk; if (kind === 'exec') flush(); else if (!s.timer) s.timer = setTimeout(flush, 80); });
  p.onExit(({ code }) => { if (!streams.has(sid)) return; flush(); streams.delete(sid); api.emit(kind + 'End', { sid, code }); });
  return sid;
}
api.handle('logStart', async ({ id, cid, key, tail, ts }) => {
  const h = hostRec(id); tail = [50, 100, 200, 500, 1000, 2000, 5000].includes(+tail) ? +tail : 200;
  let cmd;
  if (key) { const p = needProject(id, key); cmd = composeCmd(p, `logs -f --no-color --tail ${tail}${ts ? ' -t' : ''}`); }
  else cmd = `d logs -f --tail ${tail}${ts ? ' -t' : ''} ${needContainer(id, cid)} 2>&1`;
  return open(id, 'log', prelude(h, true) + cmd, 220, 50);
});
api.handle('execStart', async ({ id, cid, cmd, user, cols, rows }) => {
  const h = hostRec(id); cid = needContainer(id, cid); user = String(user || '').trim();
  if (user && !/^[\w.:@-]{1,60}$/.test(user)) throw new Error('Invalid user name');
  const inner = String(cmd || '').trim() || 'command -v bash >/dev/null 2>&1 && exec bash || exec sh';
  return open(id, 'exec', prelude(h, true) + `d exec -it ${user ? '-u ' + sq(user) + ' ' : ''}${cid} sh -c ${sq(inner)}`, Math.max(20, +cols || 80), Math.max(5, +rows || 24));
});
const need = (sid) => { const s = streams.get(String(sid)); if (!s) throw new Error('That session has ended'); return s; };
api.handle('execWrite', ({ sid, data }) => { need(sid).p.write(String(data)); });
api.handle('execResize', ({ sid, cols, rows }) => { need(sid).p.resize(cols, rows); });
api.handle('streamStop', ({ sid }) => { closeStream(String(sid)); });
//==== renderer ====
// Docker helper (window): a docked panel with one tab per Docker host (a saved SSH server). All text goes in with textContent, never as HTML.
const WHALE = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="9" width="3" height="3"/><rect x="8.5" y="9" width="3" height="3"/><rect x="12" y="9" width="3" height="3"/><rect x="8.5" y="5.5" width="3" height="3"/><rect x="12" y="5.5" width="3" height="3"/><path d="M2.5 12.5h16.8c1.3 0 2.2-.7 2.6-1.8-.8-.5-1.8-.4-2.4.3-.3-1-.9-1.6-1.8-2"/><path d="M2.5 12.5c.3 3.6 3.2 6 7.2 6 4.4 0 7.6-2.3 9.6-6"/></svg>';
// `icon` (icons.js) is a global const, not a window property, so it is called directly; plain glyphs if it is ever missing
const GLYPH = { plus: '+', refresh: '↻', gear: '⚙', play: '▶', stop: '■', restart: '↻', terminal: '>_', file: '≡', edit: '✎', trash: '✕', info: 'i', download: '↓' };
const ic = (n, s = 14) => { try { return icon(n, s); } catch { return GLYPH[n] || n; } };
const el = (tag, cls, text) => { const x = document.createElement(tag); if (cls) x.className = cls; if (text != null) x.textContent = text; return x; };
const errText = (e) => String(e && e.message || e || '').replace(/^Error invoking remote method '[^']*': (Error: )?/, '');
const quiet = (n, a) => Mod.call(n, a);
const call = (n, a) => Mod.call(n, a).catch((e) => { Mod.toast(errText(e).slice(0, 160)); throw e; });
const lsGet = (k, d) => { try { const v = localStorage.getItem(k); return v == null ? d : v; } catch { return d; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch {} };
const NS = 'http://www.w3.org/2000/svg';
const svg = (tag, attrs, parent) => { const n = document.createElementNS(NS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); if (parent) parent.append(n); return n; };

// ---- state ----
let hosts = [], cur = lsGet('dkHost', ''), view = lsGet('dkView', 'stacks'), q = '', servers = [], ui = {}, page = null, timer = null, tickN = 0;
const D = new Map();        // host id -> { ov, err, loading }
const HIST = new Map();     // host id -> Map(key -> { cpu, mem, rx, tx, last })
const STATS = new Map();    // host id -> Map(container id -> latest stats)
const busy = new Set();
const openP = new Set(JSON.parse(lsGet('dkOpen', '[]')));
const N = 60;               // samples shown in a graph

// ---- formatting ----
const fb = (n) => { n = +n || 0; const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB']; let i = 0; while (n >= 1024 && i < 4) { n /= 1024; i++; } return (n >= 100 || i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i]; };
const fr = (n) => fb(n) + '/s';
const ago = (iso) => { if (!iso || iso.startsWith('0001')) return ''; const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000); if (!isFinite(s)) return ''; return s < 90 ? Math.round(s) + 's' : s < 5400 ? Math.round(s / 60) + 'm' : s < 129600 ? Math.round(s / 3600) + 'h' : Math.round(s / 86400) + 'd'; };
const STL = { running: 'Running', degraded: 'Degraded', failed: 'Failed', exited: 'Exited', down: 'Not created' };
const cstat = (c) => c.kind === 'running' ? 'up ' + ago(c.started) : c.kind === 'exited' ? 'exited ' + ago(c.finished) + ' ago' : c.kind === 'failed' ? (c.exit ? `failed (exit ${c.exit}${c.oom ? ', out of memory' : ''}) ` : 'dead ') + ago(c.finished) + ' ago' : c.kind === 'restarting' ? 'restarting (exit ' + c.exit + ')' : c.kind;
const match = (...t) => !q || t.join(' ').toLowerCase().includes(q);
const ov = (h) => (D.get(h) || {}).ov;
function sudoSelect(val) {
  const sel = el('select'); sel.append(new Option('No sudo: the login user may run docker', ''), new Option('sudo, passwordless', 'nopw'), new Option("sudo, using this server's saved SSH password", 'pw')); sel.value = val === true ? 'nopw' : val || '';
  const help = el('div', 'help', ''); const upd = () => { help.textContent = sel.value === 'pw' ? 'The saved password is sent to sudo over the SSH connection only: it is never written to a file or a command line on the server, and never shown in the window.' : ''; help.hidden = !help.textContent; }; sel.onchange = upd; upd();
  return { sel, help };
}

// ---- graphs ----
function spark(vals, w, h, cls, max) {
  const s = svg('svg', { class: 'dk-sp ' + (cls || ''), width: w, height: h, viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none' });
  if (vals.length < 2) return s;
  const m = max || Math.max(...vals, 1e-9) * 1.15, step = w / (N - 1), v = vals.slice(-N);
  const pts = v.map((y, i) => [w - (v.length - 1 - i) * step, h - 1 - Math.min(1, y / m) * (h - 2)]);
  const line = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('');
  svg('path', { class: 'a', d: line + `L${w} ${h}L${pts[0][0].toFixed(1)} ${h}Z` }, s); svg('path', { class: 'l', d: line }, s);
  return s;
}
const histOf = (h, key) => { let m = HIST.get(h); if (!m) HIST.set(h, m = new Map()); let o = m.get(key); if (!o) m.set(key, o = { cpu: [], mem: [], rx: [], tx: [], last: null }); return o; };
const pushN = (a, v) => { a.push(v); if (a.length > N) a.shift(); };
function ingest(h, list) {
  const now = Date.now(), sm = new Map(), o = ov(h), host = histOf(h, 'host'); let tc = 0, tm = 0;
  for (const s of list) {
    sm.set(s.id, s); const hs = histOf(h, s.id); let rx = 0, tx = 0;
    if (hs.last) { const dt = (now - hs.last.t) / 1000; if (dt > 0) { rx = Math.max(0, (s.rx - hs.last.rx) / dt); tx = Math.max(0, (s.tx - hs.last.tx) / dt); } }
    hs.last = { t: now, rx: s.rx, tx: s.tx }; pushN(hs.cpu, s.cpu); pushN(hs.mem, s.mem); pushN(hs.rx, rx); pushN(hs.tx, tx); tc += s.cpu; tm += s.mem;
  }
  pushN(host.cpu, tc); pushN(host.mem, tm);
  if (o) for (const p of o.projects) { const ps = p.containers.map((id) => sm.get(id)).filter(Boolean), g = histOf(h, 'p:' + p.key); pushN(g.cpu, ps.reduce((a, s) => a + s.cpu, 0)); pushN(g.mem, ps.reduce((a, s) => a + s.mem, 0)); }
  STATS.set(h, sm);
}

// ---- data ----
async function refresh(id, force) {
  if (!id) return; const d = D.get(id) || {}; D.set(id, d); if (d.loading) return;
  d.loading = true; if (id === cur) drawBar();
  try { d.ov = await quiet('overview', { id, force: !!force }); d.err = ''; } catch (e) { d.err = errText(e); }
  d.loading = false; if (id === cur) { draw(); if (page && page.refresh) page.refresh(); } else drawHosts();
}
async function pollStats(id) {
  const o = ov(id); if (!o || !o.containers.some((c) => c.kind === 'running')) return;
  try { ingest(id, await quiet('stats', { id })); } catch { return; }
  if (id === cur) { drawBody(); if (page && page.refresh) page.refresh(); drawSummary(); }
}
function tick() {
  if (!panel.isOpen() || !hosts.length) return; tickN++;
  refresh(cur); pollStats(cur);
  if (tickN % 5 === 0) for (const h of hosts) if (h.id !== cur) refresh(h.id);
}
function startTimer() { clearInterval(timer); const s = Math.min(120, Math.max(5, +Mod.config().interval || 8)); timer = setInterval(tick, s * 1000); }
Mod.onConfig(startTimer); Mod.onUnload(() => { clearInterval(timer); closePage(); });

// ---- actions ----
function dialog(title, text, bad) {
  const d = el('div', 'dk-dlg'), c = el('div'), f = el('div', 'f'), ok = el('button', 'primary', 'Close'), pre = el('pre', '', text || '(no output)'); if (bad) pre.style.color = 'var(--bad)';
  ok.onclick = () => d.remove(); f.append(ok); c.append(el('h4', '', title), pre, f); d.append(c); d.onclick = (e) => { if (e.target === d) d.remove(); }; ui.root.append(d);
}
async function act(key, label, fn, title) {
  if (busy.has(key)) return; busy.add(key); draw(); Mod.toast(label);
  try { const r = await fn(); if (typeof r === 'string' && r.trim() && title) dialog(title, r); } catch (e) { dialog((title || 'Failed') + ' failed', errText(e), true); }
  busy.delete(key); await refresh(cur); pollStats(cur);
}
const contAct = (c, op, label) => act(cur + c.id, `${c.name}: ${label}…`, () => quiet('containerAction', { id: cur, cid: c.id, op }), c.name);
const projAct = (p, op, label) => act(cur + p.key, `${p.name}: ${label}…`, () => quiet('projectAction', { id: cur, key: p.key, op }), p.name);
const btn = (icon, title, fn, cls, dis) => { const b = el('button', 'dk-ib ' + (cls || '')); b.innerHTML = ic(icon, 14); b.title = title; if (dis) b.disabled = true; b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
const tb = (label, title, fn, cls) => { const b = el('button', cls || '', label); b.title = title || ''; b.onclick = fn; return b; };

// ---- containers ----
function contRow(c, own) {
  const row = el('div', 'dk-crow' + (own ? ' own' : '')), run = c.kind === 'running' || c.kind === 'paused' || c.kind === 'restarting', b = busy.has(cur + c.id);
  const l1 = el('div', 'dk-l1'), dot = el('span', 'dk-dot ' + (b ? 'busy' : c.ignored && (c.kind === 'failed' || c.kind === 'restarting') ? 'exited' : c.kind)); const name = el('span', 'dk-name', own || !c.service ? c.name : c.service); name.title = c.name;
  l1.append(dot, name);
  if (c.health) l1.append(el('span', 'dk-chip ' + (c.health === 'unhealthy' ? 'failed' : c.health === 'healthy' ? 'running' : 'warn'), c.health));
  if (c.ignored) l1.append(el('span', 'dk-chip', 'ignored'));
  l1.append(el('span', 'dk-st', cstat(c)));
  if (c.ignored) row.style.opacity = '.7';
  const acts = el('div', 'dk-tags'); acts.style.cssText = 'margin-left:8px;flex:none;flex-wrap:nowrap';
  acts.append(btn('play', 'Start', () => contAct(c, 'start', 'starting'), '', run || b), btn('stop', 'Stop', () => contAct(c, 'stop', 'stopping'), '', !run || b), btn('restart', 'Restart', () => contAct(c, 'restart', 'restarting'), '', b),
    btn('terminal', 'Open a shell in this container', () => execPage(c), '', c.kind !== 'running'), btn('file', 'Live log', () => logsPage({ cid: c.id, name: c.name })), btn('info', 'Details and graphs', () => detailPage(c.id)));
  l1.append(acts); row.append(l1);
  const l2 = el('div', 'dk-l2'); l2.append(el('span', '', c.image)); for (const p of c.ports.slice(0, 4)) l2.append(el('span', '', p)); if (c.ports.length > 4) l2.append(el('span', '', `+${c.ports.length - 4} more`)); row.append(l2);
  const s = (STATS.get(cur) || new Map()).get(c.id);
  if (s && c.kind === 'running') { const l3 = el('div', 'dk-l3'), h = histOf(cur, c.id); l3.append(el('span', 'dk-nums', `CPU ${s.cpu.toFixed(1)}%  ·  ${fb(s.mem)}`), spark(h.cpu, 90, 18), spark(h.mem, 90, 18, 'm')); row.append(l3); }
  row.onclick = (e) => { if (!e.target.closest('button')) detailPage(c.id); }; row.style.cursor = 'pointer';
  return row;
}

// ---- stacks ----
function projCard(o, p) {
  const cs = p.containers.map((id) => o.containers.find((c) => c.id === id)).filter(Boolean), runN = cs.filter((c) => c.kind === 'running').length, b = busy.has(cur + p.key), isOpen = openP.has(cur + p.key);
  const card = el('div', 'dk-card st-' + p.status), head = el('div', 'dk-ch'); head.title = 'Show or hide the containers';
  head.append(el('span', '', isOpen ? '▾' : '▸'), el('span', 'dk-dot ' + (b ? 'busy' : p.status)), el('span', 'dk-name', p.name), el('span', 'dk-chip ' + p.status, p.standalone ? `${runN}/${cs.length} running` : STL[p.status] + (cs.length ? ` · ${runN}/${cs.length}` : '')));
  const g = histOf(cur, 'p:' + p.key); if (g.cpu.length > 1 && runN) { const sp = spark(g.cpu, 70, 18); sp.style.marginLeft = 'auto'; head.append(sp); }
  head.onclick = () => { const k = cur + p.key; if (openP.has(k)) openP.delete(k); else openP.add(k); lsSet('dkOpen', JSON.stringify([...openP])); drawBody(); };
  card.append(head);
  if (p.dir || p.files.length) card.append(el('div', 'dk-sub', (p.dir || '') + (p.files.length ? '  ·  ' + p.files.map((f) => f.split('/').pop()).join(', ') : '')));
  if (!p.standalone) {
    const a = el('div', 'dk-acts'), dis = b || p.status === 'running' && runN === cs.length;
    a.append(btn('play', p.containers.length ? 'Start (docker compose up -d)' : 'Create and start (docker compose up -d)', () => projAct(p, 'up', 'starting'), '', b || !p.files.length), btn('stop', 'Stop the stack', () => projAct(p, 'stop', 'stopping'), '', b || !runN), btn('restart', 'Restart the stack', () => projAct(p, 'restart', 'restarting'), '', b || !cs.length),
      btn('file', 'Live log of the whole stack', () => logsPage({ key: p.key, name: p.name }), '', !cs.length), btn('edit', 'View / edit the compose file', () => editPage(p), '', !p.files.length),
      btn('download', 'Pull newer images', () => projAct(p, 'pull', 'pulling images'), '', b || !p.files.length),
      btn('trash', 'Down: stop and remove the containers and networks (volumes are kept)', () => { if (confirm(`Run "docker compose down" for ${p.name}? Containers and networks are removed; volumes are kept.`)) projAct(p, 'down', 'taking down'); }, 'danger', b || !cs.length));
    if (!p.files.length) a.append(el('span', 'dk-st', 'compose file not found: add its folder in the host settings'));
    card.append(a);
  }
  if (isOpen) { const w = el('div', 'dk-cs'); for (const c of cs) if (match(c.name, c.image, c.service)) w.append(contRow(c)); if (!cs.length) w.append(el('div', 'dk-sub', 'No containers yet. Use Start to create them.')); card.append(w); }
  return card;
}

// ---- views ----
function drawStacks(o, box) {
  const ps = o.projects.filter((p) => match(p.name, p.dir, ...p.containers.map((id) => { const c = o.containers.find((x) => x.id === id); return c ? c.name + ' ' + c.image : ''; })));
  if (!ps.length) { box.append(el('div', 'dk-empty', o.projects.length ? 'Nothing matches the filter.' : 'No compose stacks or containers found on this host.\nIf your compose files live somewhere unusual, add the folder in the host settings (gear).')); return; }
  for (const p of ps) box.append(projCard(o, p));
}
function drawContainers(o, box) {
  const cs = o.containers.filter((c) => match(c.name, c.image, c.project, c.state));
  if (!cs.length) { box.append(el('div', 'dk-empty', 'No containers.')); return; }
  for (const c of cs) { const r = contRow(c, true); if (c.project) r.querySelector('.dk-l2').prepend(el('span', '', '⧉ ' + c.project)); box.append(r); }
}
const chips = (o, ids) => { const w = el('div', 'dk-tags'); if (!ids.length) w.append(el('span', 'dk-tag dim', 'unused')); for (const id of ids) { const c = o.containers.find((x) => x.id === id); if (!c) continue; const t = el('span', 'dk-tag', c.name); t.onclick = () => detailPage(c.id); w.append(t); } return w; };
function drawNetworks(o, box) {
  const ns = o.networks.filter((n) => match(n.name, n.driver, ...n.subnets));
  if (!ns.length) { box.append(el('div', 'dk-empty', 'No networks.')); return; }
  for (const n of ns) { const r = el('div', 'dk-row'), l = el('div', 'dk-l1'); l.append(el('b', 'dk-name', n.name), el('span', 'dk-chip', n.driver), n.internal ? el('span', 'dk-chip warn', 'internal') : '', el('span', 'dk-st', n.subnets.join(', ') + (n.gateway ? ' · gw ' + n.gateway : ''))); r.append(l, chips(o, n.containers)); box.append(r); }
}
function drawVolumes(o, box) {
  const vs = o.volumes.filter((v) => match(v.name, v.driver, v.mountpoint));
  if (!vs.length) { box.append(el('div', 'dk-empty', 'No volumes.')); return; }
  for (const v of vs) { const r = el('div', 'dk-row'), l = el('div', 'dk-l1'), anon = /^[0-9a-f]{64}$/.test(v.name); const nm = el('b', 'dk-name', anon ? v.name.slice(0, 12) + '… (anonymous)' : v.name); nm.title = v.name; l.append(nm, el('span', 'dk-chip', v.driver)); r.append(l); if (v.mountpoint) r.append(el('div', 'meta', v.mountpoint)); r.append(chips(o, v.containers)); box.append(r); }
}
// Topology: networks <- containers -> named volumes
function drawMap(o, box) {
  const cs = o.containers.filter((c) => match(c.name, c.image, c.project)).sort((a, b) => (a.project || '~').localeCompare(b.project || '~') || a.name.localeCompare(b.name));
  if (!cs.length) { box.append(el('div', 'dk-empty', 'Nothing to draw.')); return; }
  const bary = (items, key) => { const m = new Map(items.map((x) => [x, []])); cs.forEach((c, i) => { for (const x of key(c)) if (m.has(x)) m.get(x).push(i); }); return items.filter((x) => m.get(x).length).sort((a, b) => avg(m.get(a)) - avg(m.get(b))); };
  const avg = (a) => a.reduce((x, y) => x + y, 0) / a.length;
  const nets = bary(o.networks.map((n) => n.name), (c) => c.nets.map((n) => n.name)), vols = bary(o.volumes.map((v) => v.name), (c) => c.mounts.filter((m) => m.type === 'volume').map((m) => m.name));
  const W = 440, rows = Math.max(cs.length, nets.length, vols.length), H = 30 + rows * 30, X = [4, 160, 316], NW = 120;
  const ys = (n) => (i) => n <= 1 ? H / 2 : 24 + i * (H - 36) / (n - 1);
  const yc = ys(cs.length), yn = ys(nets.length), yv = ys(vols.length);
  const s = svg('svg', { class: 'dk-map', viewBox: `0 0 ${W} ${H}` }); box.append(s);
  [['Networks', 0], ['Containers', 1], ['Volumes', 2]].forEach(([t, i]) => { const x = svg('text', { class: 'col', x: X[i], y: 10 }, s); x.textContent = t; });
  const edges = svg('g', {}, s), nodes = svg('g', {}, s), rel = new Map();
  const link = (k, e) => { if (!rel.has(k)) rel.set(k, []); rel.get(k).push(e); };
  const node = (x, y, label, dot, key, onclick) => { const g = svg('g', { class: 'n' }, nodes); svg('rect', { x, y: y - 10, width: NW, height: 20, rx: 5 }, g); if (dot) svg('circle', { cx: x + 9, cy: y, r: 3.5, fill: dot }, g); const t = svg('text', { x: x + (dot ? 18 : 8), y: y + 3 }, g); t.textContent = label.length > 17 ? label.slice(0, 16) + '…' : label; const tt = svg('title', {}, g); tt.textContent = label; g.onmouseenter = () => { s.classList.add('hov'); (rel.get(key) || []).forEach((e) => e.classList.add('hl')); }; g.onmouseleave = () => { s.classList.remove('hov'); s.querySelectorAll('.hl').forEach((e) => e.classList.remove('hl')); }; if (onclick) g.onclick = onclick; };
  const col = (c) => c.kind === 'running' ? 'var(--ok)' : c.kind === 'failed' ? 'var(--bad)' : c.kind === 'restarting' || c.kind === 'paused' ? '#f5a524' : 'var(--mut)';
  const curve = (x1, y1, x2, y2, key1, key2) => { const m = (x1 + x2) / 2, e = svg('path', { class: 'e', d: `M${x1} ${y1}C${m} ${y1} ${m} ${y2} ${x2} ${y2}` }, edges); link(key1, e); link(key2, e); };
  cs.forEach((c, i) => { c.nets.forEach((n) => { const j = nets.indexOf(n.name); if (j >= 0) curve(X[0] + NW, yn(j), X[1], yc(i), 'n:' + n.name, 'c:' + c.id); }); c.mounts.forEach((m) => { const j = m.type === 'volume' ? vols.indexOf(m.name) : -1; if (j >= 0) curve(X[1] + NW, yc(i), X[2], yv(j), 'c:' + c.id, 'v:' + m.name); }); });
  nets.forEach((n, j) => node(X[0], yn(j), n, null, 'n:' + n));
  cs.forEach((c, i) => node(X[1], yc(i), c.name, col(c), 'c:' + c.id, () => detailPage(c.id)));
  vols.forEach((v, j) => node(X[2], yv(j), /^[0-9a-f]{64}$/.test(v) ? v.slice(0, 12) + '…' : v, null, 'v:' + v));
}

// ---- header, nav, body ----
const hostState = (id) => { const d = D.get(id) || {}, o = d.ov; if (d.err) return 'failed'; if (!o) return 'down'; const ps = o.projects.map((p) => p.status); return ps.includes('failed') ? 'failed' : ps.includes('degraded') ? 'degraded' : o.containers.some((c) => c.kind === 'running') ? 'running' : 'exited'; };
function drawHosts() {
  const bx = ui.hosts; bx.textContent = '';
  for (const h of hosts) { const t = el('div', 'dk-host' + (h.id === cur && view !== 'add' ? ' on' : '')); t.title = h.name; t.append(el('span', 'dk-dot ' + ((D.get(h.id) || {}).loading && !ov(h.id) ? 'busy' : hostState(h.id))), el('span', 't', h.name)); t.onclick = () => { selectHost(h.id); }; bx.append(t); }
  const r = el('div', 'dk-sp-r'); r.append(btn('plus', 'Add a Docker host', () => { view = 'add'; draw(); }), btn('refresh', 'Refresh now (rescan compose files)', () => { if (cur) { refresh(cur, true); pollStats(cur); } }, '', !cur), btn('gear', 'Host settings', () => { view = 'settings'; draw(); }, '', !cur)); bx.append(r);
}
function selectHost(id) { cur = id; lsSet('dkHost', id); if (['add', 'settings'].includes(view)) view = lsGet('dkView', 'stacks'); if (!ov(id)) refresh(id); else { refresh(id); pollStats(id); } draw(); }
function drawNav() {
  const nv = ui.nav; nv.textContent = ''; const o = ov(cur); if (!cur || ['add', 'settings'].includes(view)) { nv.hidden = ui.bar.hidden = ui.sum.hidden = true; return; } nv.hidden = ui.bar.hidden = ui.sum.hidden = false;
  const items = [['stacks', 'Stacks', o && o.projects.filter((p) => !p.standalone).length], ['containers', 'Containers', o && o.containers.length], ['networks', 'Networks', o && o.networks.length], ['volumes', 'Volumes', o && o.volumes.length], ['map', 'Map']];
  for (const [v, l, n] of items) { const b = el('button', view === v ? 'on' : '', l); if (n != null && n !== false) b.append(' ', el('small', '', String(n))); b.onclick = () => { view = v; lsSet('dkView', v); draw(); }; nv.append(b); }
}
function drawBar() { const d = D.get(cur) || {}; ui.spin.textContent = d.loading ? 'updating…' : d.ov ? 'updated ' + new Date(d.ov.at).toLocaleTimeString() : ''; }
function drawSummary() {
  const sm = ui.sum; sm.textContent = ''; const o = ov(cur); drawBar(); if (!o) return;
  const n = (k) => o.containers.filter((c) => c.kind === k && !(c.ignored && (k === 'failed' || k === 'restarting'))).length, add = (t, v, cls) => { const s = el('span'); s.append(v === '' ? '' : el('b', cls || '', String(v)), ' ' + t); sm.append(s); };
  add('running', n('running')); if (n('exited')) add('exited', n('exited')); if (n('failed') + n('restarting')) add('failed', n('failed') + n('restarting'), 'bad'); if (n('paused')) add('paused', n('paused'));
  const hs = HIST.get(cur) && HIST.get(cur).get('host'); if (hs && hs.cpu.length) { add('CPU', hs.cpu[hs.cpu.length - 1].toFixed(0) + '%' + (o.info.ncpu ? ` of ${o.info.ncpu * 100}%` : '')); add('memory', fb(hs.mem[hs.mem.length - 1]) + (o.info.mem ? ' of ' + fb(o.info.mem) : '')); }
  sm.append(el('span', '', 'Docker ' + o.version + (o.dc && o.dc !== 'none' ? ' · compose ' + o.dc : ' · no compose')));
}
function drawBody() {
  const b = ui.body, top = b.scrollTop; b.textContent = '';
  if (view === 'add') drawAdd(b); else if (view === 'settings') drawSettings(b);
  else { const d = D.get(cur) || {}; const o = d.ov;
    if (d.err) { b.append(el('div', 'dk-err', d.err)); const r = el('div', 'dk-acts'); r.style.paddingLeft = '0'; r.append(tb('Retry', '', () => refresh(cur, true), 'primary'), tb('Host settings', '', () => { view = 'settings'; draw(); })); b.append(r); }
    if (o) ({ stacks: drawStacks, containers: drawContainers, networks: drawNetworks, volumes: drawVolumes, map: drawMap }[view] || drawStacks)(o, b);
    else if (!d.err) b.append(el('div', 'dk-empty', 'Connecting…')); }
  b.scrollTop = top;
}
function draw() {
  if (!ui.root) return;
  if (!hosts.length && view !== 'add') view = 'add';
  drawHosts(); drawNav(); drawSummary(); drawBody();
}

// ---- add host / settings ----
function drawAdd(b) {
  const f = el('div', 'dk-form'); f.append(el('h4', '', hosts.length ? 'Add a Docker host' : 'Set up a Docker host'));
  f.append(el('div', 'help', 'Pick one of your saved SSH servers. Connect logs in with it and runs the docker command there, so nothing has to be exposed or installed on the server. It needs a user that may run docker (docker group) or passwordless sudo.'));
  const free = servers.filter((s) => !hosts.some((h) => h.id === s.id)), sel = el('select');
  for (const s of free) sel.append(new Option(s.name + (s.jump ? ' (jump host: not supported yet)' : ''), s.id));
  const su = sudoSelect(''), sudo = su.sel;
  const dirs = el('input'); dirs.placeholder = (Mod.config().scanDirs || '~ /opt /srv /home') + '   (folders to scan for compose files)';
  const go = tb('Add and connect', '', async () => { try { await call('addHost', { id: sel.value, sudo: sudo.value, dirs: dirs.value }); } catch { return; } await loadState(); view = lsGet('dkView', 'stacks'); selectHost(sel.value); }, 'primary'); go.disabled = !free.length;
  f.append(el('label', '', 'SSH server'), sel, el('label', '', 'Run docker as'), sudo, su.help, el('label', '', 'Folders to scan (optional)'), dirs, go);
  if (!free.length) f.append(el('div', 'help', servers.length ? 'Every saved SSH server is already a Docker host.' : 'No saved SSH servers yet. Add one in Connect first.'));
  if (hosts.length) f.append(tb('Cancel', '', () => { view = lsGet('dkView', 'stacks'); draw(); }));
  b.append(f);
}
function drawSettings(b) {
  const h = hosts.find((x) => x.id === cur); if (!h) return; const o = ov(cur), f = el('div', 'dk-form');
  f.append(el('h4', '', h.name));
  if (o) f.append(el('div', 'help', `Docker ${o.version}${o.info.os ? ' · ' + o.info.os : ''}${o.info.ncpu ? ' · ' + o.info.ncpu + ' CPUs' : ''}${o.info.mem ? ' · ' + fb(o.info.mem) + ' RAM' : ''} · compose ${o.dc || '?'}`));
  const su = sudoSelect(h.sudo), sudo = su.sel;
  const dirs = el('input'); dirs.value = h.dirs || ''; dirs.placeholder = Mod.config().scanDirs || '~ /opt /srv /home';
  const save = tb('Save and rescan', '', async () => { try { await call('updateHost', { id: cur, sudo: sudo.value, dirs: dirs.value }); } catch { return; } await loadState(); view = lsGet('dkView', 'stacks'); D.delete(cur); draw(); refresh(cur, true); }, 'primary');
  const rm = tb('Remove this host', 'Only removes it from this list: nothing is changed on the server', async () => { if (!confirm(`Remove ${h.name} from the Docker sidebar? Nothing is changed on the server.`)) return; try { await call('removeHost', { id: cur }); } catch { return; } D.delete(cur); await loadState(); cur = (hosts[0] || {}).id || ''; view = lsGet('dkView', 'stacks'); if (cur) refresh(cur); draw(); }, 'danger');
  const ign = el('div', 'dk-tags'); for (const n of h.ignore || []) { const t = el('span', 'dk-tag', n + '  ✕'); t.title = 'Stop ignoring'; t.onclick = async () => { try { await call('setIgnore', { id: cur, name: n, ignore: false }); } catch { return; } await loadState(); refresh(cur); drawBody(); }; ign.append(t); }
  if ((h.ignore || []).length) f.append(el('label', '', 'Ignored containers (click to stop ignoring)'), ign);
  f.append(el('label', '', 'Run docker as'), sudo, su.help, el('label', '', 'Folders to scan for compose files (space separated, 4 levels deep; empty = default)'), dirs, el('div', 'help', 'Running stacks are always found through their containers; scanning finds the ones that are stopped or never started.'), save, tb('Back', '', () => { view = lsGet('dkView', 'stacks'); draw(); }), rm);
  b.append(f);
}

// ---- pages (log, shell, editor, details) drawn over the panel ----
function openPage(title, build) {
  closePage();
  const p = el('div', 'dk-page'), h = el('div', 'dk-ph'), back = tb('← Back', 'Close', () => closePage()), t = el('span', 'dk-name', title), content = el('div', 'dk-pc');
  h.append(back, t); p.append(h, content); ui.root.append(p); page = { el: p, cleanup: null, refresh: null, title: h, canClose: null };
  build(content, h, page);
}
function closePage() { if (!page) return; if (page.canClose && !page.canClose()) return; const p = page; page = null; try { p.cleanup && p.cleanup(); } catch (e) { console.error(e); } p.el.remove(); }
// events from running streams (log tail / shell): can arrive before the start call returns, so they are held until attached
const handlers = new Map(), early = new Map();
function attach(sid, fn) { handlers.set(sid, fn); for (const ev of early.get(sid) || []) fn(ev.t, ev.d); early.delete(sid); return () => { handlers.delete(sid); quiet('streamStop', { sid }).catch(() => {}); }; }
for (const [name, t] of [['log', 'data'], ['logEnd', 'end'], ['exec', 'data'], ['execEnd', 'end']]) Mod.on(name, (ev) => { const f = handlers.get(ev.sid); if (f) f(t, t === 'data' ? ev.text : ev.code); else { if (!early.has(ev.sid)) early.set(ev.sid, []); early.get(ev.sid).push({ t, d: t === 'data' ? ev.text : ev.code }); } });
const ANSI = /\x1b\[[0-9;?]*[ -\/]*[@-~]|\x1b\][^\x07]*(\x07|\x1b\\)|\x1b[()][A-Za-z0-9]/g;

function logsPage(t) {
  openPage('Log: ' + t.name, (box, head, pg) => {
    let sid = null, off = null, lines = [], part = '', follow = true, paused = false, filter = '', ended = false, redraw = null, tail = 200, ts = false;
    const tools = el('div', 'dk-pt'), pre = el('pre', 'dk-log'), msg = el('div', 'dk-msg', 'Connecting…');
    const tailS = el('select'); [100, 200, 500, 1000, 2000, 5000].forEach((n) => tailS.append(new Option('last ' + n, n))); tailS.value = '200';
    const tsC = el('input'); tsC.type = 'checkbox'; const tsL = el('label'); tsL.append(tsC, 'Timestamps');
    const fol = el('input'); fol.type = 'checkbox'; fol.checked = true; const folL = el('label'); folL.append(fol, 'Follow');
    const flt = el('input'); flt.placeholder = 'Filter lines…';
    const pb = tb('Pause', 'Stop adding new lines to the view', () => { paused = !paused; pb.textContent = paused ? 'Resume' : 'Pause'; if (!paused) paint(); });
    const cb = tb('Clear', '', () => { lines = []; part = ''; paint(); }), cp = tb('Copy', 'Copy what is shown', () => { navigator.clipboard.writeText(pre.textContent).then(() => Mod.toast('Copied'), () => {}); }), rc = tb('Restart', 'Reconnect the stream', () => start());
    tools.append(tailS, tsL, folL, flt, pb, cb, cp, rc); box.append(tools, pre, msg);
    function paint() { redraw = null; if (paused) return; const f = filter.toLowerCase(), v = f ? lines.filter((l) => l.toLowerCase().includes(f)) : lines; pre.textContent = v.slice(-3000).join('\n') + (part && (!f || part.toLowerCase().includes(f)) ? '\n' + part : ''); if (follow) pre.scrollTop = pre.scrollHeight; }
    const later = () => { if (!redraw) redraw = setTimeout(paint, 120); };
    const onEv = (kind, d) => {
      if (kind === 'data') { part += String(d).replace(ANSI, '').replace(/\r/g, ''); const a = part.split('\n'); part = a.pop(); if (a.length) { lines.push(...a); if (lines.length > 6000) lines.splice(0, lines.length - 5000); } later(); msg.className = 'dk-msg'; msg.textContent = 'Live'; }
      else { ended = true; msg.className = 'dk-msg bad'; msg.textContent = 'The stream ended' + (d ? ` (exit ${d})` : '') + '. Press Restart to reconnect.'; }
    };
    async function start() {
      if (off) { off(); off = null; } lines = []; part = ''; ended = false; msg.className = 'dk-msg'; msg.textContent = 'Connecting…'; paint();
      try { sid = await quiet('logStart', { id: cur, cid: t.cid, key: t.key, tail: +tailS.value, ts: tsC.checked }); off = attach(sid, onEv); } catch (e) { msg.className = 'dk-msg bad'; msg.textContent = errText(e); }
    }
    tailS.onchange = tsC.onchange = start; flt.oninput = () => { filter = flt.value; paint(); };
    fol.onchange = () => { follow = fol.checked; if (follow) pre.scrollTop = pre.scrollHeight; };
    pre.onscroll = () => { const at = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 30; if (at !== follow) { follow = at; fol.checked = at; } };
    pg.cleanup = () => { if (off) off(); clearTimeout(redraw); };
    start();
  });
}

function execPage(c) {
  openPage('Shell: ' + c.name, (box, head, pg) => {
    if (!Mod.Terminal || !Mod.FitAddon) { box.append(el('div', 'dk-empty', 'The terminal component is not available in this version of Connect.')); return; }
    const tools = el('div', 'dk-pt'), cmd = el('input'), user = el('input'), go = tb('Reconnect', '', () => connect()), msg = el('div', 'dk-msg', ''), holder = el('div', 'dk-term');
    cmd.placeholder = 'Command (empty = bash, or sh if there is no bash)'; user.placeholder = 'User (optional)'; user.style.maxWidth = '110px'; user.style.flex = 'none';
    tools.append(cmd, user, go); box.append(tools, holder, msg);
    const cssv = (n, d) => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || d;
    const term = new Mod.Terminal({ fontFamily: window.hdFont ? hdFont() : 'ui-monospace, "SF Mono", Menlo, monospace', fontSize: window.hdFontSize ? hdFontSize() : 13, cursorBlink: true, allowProposedApi: true, scrollback: 5000, theme: window.termTheme ? termTheme() : { background: cssv('--tbg', '#0a0b0e'), foreground: cssv('--tfg', '#e6e8eb') } });
    const fit = new Mod.FitAddon.FitAddon(); term.loadAddon(fit); term.open(holder);
    let sid = null, off = null;
    const doFit = () => { try { fit.fit(); if (sid) quiet('execResize', { sid, cols: term.cols, rows: term.rows }).catch(() => {}); } catch {} };
    const ro = new ResizeObserver(() => doFit()); ro.observe(holder);
    term.onData((d) => { if (sid) quiet('execWrite', { sid, data: d }).catch(() => {}); });
    async function connect() {
      if (off) { off(); off = null; sid = null; } term.reset(); msg.className = 'dk-msg'; msg.textContent = 'Connecting…'; doFit();
      try { const s = await quiet('execStart', { id: cur, cid: c.id, cmd: cmd.value, user: user.value, cols: term.cols, rows: term.rows }); sid = s; off = attach(s, (k, d) => { if (k === 'data') term.write(d); else { sid = null; msg.className = 'dk-msg bad'; msg.textContent = 'Session ended' + (d ? ` (exit ${d})` : '') + '. Press Reconnect for a new shell.'; } }); msg.textContent = `Connected to ${c.name}`; term.focus(); }
      catch (e) { msg.className = 'dk-msg bad'; msg.textContent = errText(e); }
    }
    pg.cleanup = () => { ro.disconnect(); if (off) off(); try { term.dispose(); } catch {} };
    requestAnimationFrame(() => { doFit(); connect(); });
  });
}

function editPage(p) {
  openPage('Compose: ' + p.name, (box, head, pg) => {
    let file = (p.active.length ? p.active : p.files)[0], sum = '', orig = '', mode = 'edit';
    const tools = el('div', 'dk-pt'), fsel = el('select'), tabs = el('div', 'dk-tabs'), ed = el('textarea', 'dk-ed'), res = el('pre', 'dk-log'), msg = el('div', 'dk-msg', 'Loading…');
    for (const f of p.files) fsel.append(new Option(p.dir && f.startsWith(p.dir + '/') ? f.slice(p.dir.length + 1) : f, f)); fsel.value = file; fsel.title = file; ed.spellcheck = false; res.hidden = true;
    const tEdit = tb('Edit', '', () => setMode('edit')), tRes = tb('Resolved', 'What docker compose config makes of it (variables filled in, files merged)', () => setMode('res'));
    tabs.append(tEdit, tRes);
    const saveB = tb('Save', 'Check the file with docker compose config, keep a .bak of the old one, then save (Ctrl/Cmd+S)', () => save(false), 'primary'), checkB = tb('Check', 'Validate without saving', () => save(false, true)), applyB = tb('Save & apply', 'Save, then run docker compose up -d so the changes take effect', () => save(true));
    tools.append(fsel, tabs, saveB, checkB, applyB); box.append(tools, ed, res, msg);
    const say = (t, cls) => { msg.className = 'dk-msg ' + (cls || ''); msg.textContent = t; };
    const dirty = () => ed.value !== orig;
    function setMode(m) { mode = m; tEdit.classList.toggle('primary', m === 'edit'); tRes.classList.toggle('primary', m === 'res'); ed.hidden = m !== 'edit'; res.hidden = m !== 'res'; if (m === 'res') { res.textContent = 'Loading…'; quiet('resolved', { id: cur, key: p.key, file }).then((r) => { res.textContent = r.text; res.style.color = r.ok ? '' : 'var(--bad)'; }, (e) => { res.textContent = errText(e); }); } }
    async function load() { say('Loading…'); try { const r = await quiet('readFile', { id: cur, file }); sum = r.sum; orig = r.text; ed.value = r.text; say('Loaded ' + file); } catch (e) { say(errText(e), 'bad'); } }
    async function save(apply, dry) {
      if (!dry && !dirty() && !apply) { say('No changes to save.'); return; }
      if (apply && !confirm(`Save and run "docker compose up -d" for ${p.name}? Services whose configuration changed are recreated.`)) return;
      say(dry ? 'Checking…' : 'Saving…'); let r;
      try { r = await quiet('saveFile', { id: cur, file, text: ed.value, sum, dry: !!dry }); if (r.changed) { if (!confirm('This file was changed on the server since you opened it. Overwrite it with your version?')) { say('Not saved: the file changed on the server. Reload to see the new version.', 'bad'); return; } r = await quiet('saveFile', { id: cur, file, text: ed.value, force: true, dry: !!dry }); } if (r.invalid) { if (dry || !confirm('docker compose reports a problem:\n\n' + r.invalid.slice(0, 600) + '\n\nSave it anyway?')) { say(r.invalid, 'bad'); return; } r = await quiet('saveFile', { id: cur, file, text: ed.value, force: true, nocheck: true }); } }
      catch (e) { say(errText(e), 'bad'); return; }
      if (dry) { say('The file is valid.', 'ok'); return; }
      sum = r.sum; orig = ed.value; say('Saved (the previous version is kept as ' + file.split('/').pop() + '.bak)', 'ok'); if (mode === 'res') setMode('res');
      if (apply) { say('Applying…'); try { const out = await quiet('projectAction', { id: cur, key: p.key, op: 'up' }); say('Saved and applied.\n' + out.slice(-600), 'ok'); } catch (e) { say('Saved, but docker compose up failed:\n' + errText(e), 'bad'); } refresh(cur, true); }
    }
    fsel.onchange = () => { if (dirty() && !confirm('Discard your unsaved changes?')) { fsel.value = file; return; } file = fsel.value; fsel.title = file; load(); if (mode === 'res') setMode('res'); };
    ed.onkeydown = (e) => { if (e.key === 'Tab') { e.preventDefault(); const s = ed.selectionStart; ed.setRangeText('  ', s, ed.selectionEnd, 'end'); } else if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); save(false); } };
    ed.oninput = () => { head.querySelector('.dk-name').textContent = 'Compose: ' + p.name + (dirty() ? '  ●' : ''); };
    pg.canClose = () => !dirty() || confirm('Discard your unsaved changes?');
    setMode('edit'); load();
  });
}

function detailPage(cid) {
  const find = () => (ov(cur) || { containers: [] }).containers.find((c) => c.id === cid);
  if (!find()) return;
  openPage(find().name, (box, head, pg) => {
    const tools = el('div', 'dk-pt'), body = el('div', 'dk-detail'); box.append(tools, body);
    pg.refresh = () => {
      const c = find(); if (!c) { closePage(); return; } const run = c.kind === 'running' || c.kind === 'paused' || c.kind === 'restarting', h = histOf(cur, c.id), s = (STATS.get(cur) || new Map()).get(c.id);
      tools.textContent = ''; tools.append(btn('play', 'Start', () => contAct(c, 'start', 'starting'), '', run), btn('stop', 'Stop', () => contAct(c, 'stop', 'stopping'), '', !run), btn('restart', 'Restart', () => contAct(c, 'restart', 'restarting')),
        tb(c.kind === 'paused' ? 'Unpause' : 'Pause', '', () => contAct(c, c.kind === 'paused' ? 'unpause' : 'pause', 'pausing'), c.kind === 'running' || c.kind === 'paused' ? '' : 'dk-hide'), tb(c.ignored ? 'Stop ignoring' : 'Ignore', c.ignored ? 'Count this container in the stack status again' : 'Do not let this container make its stack (or this host) show as degraded or failed', async () => { try { await call('setIgnore', { id: cur, name: c.name, ignore: !c.ignored }); } catch { return; } await refresh(cur); }), tb('Shell', '', () => execPage(c)), tb('Log', '', () => logsPage({ cid: c.id, name: c.name })),
        tb('Kill', 'Send SIGKILL', () => { if (confirm(`Kill ${c.name}?`)) contAct(c, 'kill', 'killing'); }, 'danger'), tb('Remove', 'docker rm: only for stopped containers', async () => { if (!confirm(`Remove container ${c.name}? Its writable layer is deleted (named volumes are kept).`)) return; await contAct(c, 'rm', 'removing'); closePage(); }, 'danger'));
      tools.querySelectorAll('.dk-hide').forEach((x) => x.remove());
      body.textContent = '';
      const chart = (t, vals, fmt, cls, extra) => { const w = el('div', 'dk-ch2'), hh = el('div', 'h'); hh.append(el('span', '', t), el('b', '', vals.length ? fmt(vals[vals.length - 1]) + (extra || '') : '–')); w.append(hh, spark(vals, 400, 54, cls)); return w; };
      if (c.kind === 'running') {
        const cs = el('div', 'dk-detail'); cs.style.padding = '0';
        cs.append(chart('CPU', h.cpu, (v) => v.toFixed(1) + '%'), chart('Memory', h.mem, fb, 'm', s && s.memLimit ? '  /  ' + fb(s.memLimit) : ''), chart('Network in', h.rx, fr, 'n'), chart('Network out', h.tx, fr, 'n'));
        if (s) cs.append(el('div', 'dk-st', `${s.pids} processes · block I/O ${fb(s.br)} read / ${fb(s.bw)} written · network total ${fb(s.rx)} in / ${fb(s.tx)} out`)); body.append(cs);
      } else if (c.kind === 'failed' || c.kind === 'exited') body.append(el('div', 'dk-chip ' + (c.kind === 'failed' ? 'failed' : ''), cstat(c)));
      const kv = el('div', 'dk-kv'), add = (k, v) => { if (v === '' || v == null || (Array.isArray(v) && !v.length)) return; kv.append(el('span', '', k), el('span', '', Array.isArray(v) ? v.join('\n') : String(v))); };
      add('Status', cstat(c) + (c.health ? ' · ' + c.health : '')); if (c.error) add('Error', c.error); if (c.healthLog) add('Health check', c.healthLog);
      add('Image', c.image); add('ID', c.id); add('Command', c.cmd); add('Stack', c.project ? c.project + (c.service ? ' / ' + c.service : '') : ''); add('Created', c.created ? new Date(c.created).toLocaleString() : '');
      add('Restart policy', c.restart); add('Ports', c.ports); add('Networks', c.nets.map((n) => n.name + (n.ip ? '  ' + n.ip : ''))); add('Mounts', c.mounts.map((m) => `${m.type === 'volume' ? m.name : m.src} → ${m.dst}${m.rw ? '' : ' (ro)'}`));
      body.append(kv);
    };
    pg.refresh();
  });
}

// ---- panel ----
function build(box) {
  ui.root = box; box.classList.add('dk-root');
  ui.hosts = el('div', 'dk-hosts'); ui.nav = el('div', 'dk-nav'); ui.bar = el('div', 'dk-bar'); ui.sum = el('div', 'dk-sum'); ui.body = el('div', 'dk-body');
  const flt = el('input'); flt.placeholder = 'Filter by name, image, network…'; flt.oninput = () => { q = flt.value.trim().toLowerCase(); drawBody(); };
  ui.spin = el('span'); ui.bar.append(flt, ui.spin);
  box.append(ui.hosts, ui.nav, ui.bar, ui.sum, ui.body);
}
async function loadState() { const st = await call('state'); hosts = st.hosts; if (!hosts.some((h) => h.id === cur)) cur = (hosts[0] || {}).id || ''; }
async function init() {
  try { await loadState(); servers = await quiet('servers'); } catch {}
  if (!hosts.length) view = 'add'; else if (view === 'add') view = 'stacks';
  draw(); for (const h of hosts) refresh(h.id, h.id === cur); pollStats(cur); startTimer();
}
lsGet('modPanelW:docker', '') || lsSet('modPanelW:docker', '520');
const panel = Mod.sidebarPanel({ id: 'docker', label: 'Docker', icon: 'server', mount: build, show: () => init() });
{ // the docker logo instead of a generic icon, and stacked under the AI button
  const tab = document.querySelector('.modPanelTab[title="Docker"]'); if (tab) { tab.classList.add('dk-tab'); tab.innerHTML = WHALE; }
}
//==== css ====
.modPanelTab.dk-tab{top:calc(50% + 44px)}
.dk-tab svg{display:block;width:16px;height:16px}
.dk-root{height:100%;font-size:13px;display:flex;flex-direction:column;position:relative;min-height:0}
.dk-hosts{display:flex;gap:4px;padding:6px 8px;border-bottom:1px solid var(--line);overflow-x:auto;flex:none;align-items:center}
.dk-host{display:flex;align-items:center;gap:6px;padding:4px 8px;border:1px solid var(--line);border-radius:6px;cursor:pointer;white-space:nowrap;max-width:170px;color:var(--mut)}
.dk-host.on{color:var(--fg);border-color:var(--acc)}.dk-host span.t{overflow:hidden;text-overflow:ellipsis}
.dk-sp-r{margin-left:auto;display:flex;gap:4px}
.dk-nav{display:flex;gap:2px;padding:6px 8px 0;border-bottom:1px solid var(--line);flex:none;overflow-x:auto}
.dk-nav button{border:0;border-bottom:2px solid transparent;border-radius:0;background:none;color:var(--mut);padding:5px 8px;white-space:nowrap}
.dk-nav button.on{color:var(--fg);border-bottom-color:var(--acc)}.dk-nav small{opacity:.7}
.dk-bar{display:flex;gap:8px;align-items:center;padding:6px 8px;flex:none;color:var(--mut);font-size:12px}
.dk-bar input{flex:1;min-width:60px;padding:3px 8px}
.dk-sum{display:flex;flex-wrap:wrap;gap:4px 12px;padding:0 8px 6px;color:var(--mut);font-size:12px;flex:none}.dk-sum b{color:var(--fg);font-weight:600}
.dk-body{flex:1;min-height:0;overflow-y:auto;padding:4px 8px 12px;display:flex;flex-direction:column;gap:8px}
.dk-empty{color:var(--mut);padding:16px;text-align:center;white-space:pre-wrap}
.dk-err{color:var(--bad);padding:10px;border:1px solid var(--bad);border-radius:8px;white-space:pre-wrap;word-break:break-word}
.dk-dot{width:9px;height:9px;border-radius:50%;background:var(--mut);flex:none}
.dk-dot.running,.st-running>.dk-ch .dk-dot{background:var(--ok)}.dk-dot.degraded,.dk-dot.restarting,.dk-dot.paused{background:#f5a524}
.dk-dot.failed{background:var(--bad)}.dk-dot.exited,.dk-dot.down,.dk-dot.created{background:var(--mut)}
.dk-dot.busy{background:none;border:2px solid var(--acc);border-right-color:transparent;animation:dkspin .8s linear infinite;box-sizing:border-box}
@keyframes dkspin{to{transform:rotate(360deg)}}
.dk-card{border:1px solid var(--line);border-radius:8px;overflow:hidden}
.dk-card.st-failed{border-color:color-mix(in srgb,var(--bad) 60%,var(--line))}.dk-card.st-degraded{border-color:color-mix(in srgb,#f5a524 60%,var(--line))}
.dk-ch{display:flex;align-items:center;gap:8px;padding:7px 10px;cursor:pointer}
.dk-name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.dk-chip{font-size:10px;padding:1px 6px;border-radius:9px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
.dk-chip.running{color:var(--ok);border-color:var(--ok)}.dk-chip.failed{color:var(--bad);border-color:var(--bad)}.dk-chip.degraded,.dk-chip.warn{color:#f5a524;border-color:#f5a524}
.dk-sub{padding:0 10px 6px 27px;color:var(--mut);font-size:11px;word-break:break-all}
.dk-acts{display:flex;gap:4px;padding:0 10px 8px 27px;flex-wrap:wrap;align-items:center}
.dk-ib{padding:3px 7px;font-size:12px}.dk-ib.danger{color:var(--bad)}.dk-ib svg{display:block}
.dk-ib:disabled{opacity:.3}
.dk-cs{border-top:1px solid var(--line)}
.dk-crow{padding:7px 10px;display:flex;flex-direction:column;gap:3px}.dk-cs .dk-crow+.dk-crow{border-top:1px solid color-mix(in srgb,var(--line) 60%,transparent)}
.dk-card.solo .dk-crow,.dk-crow.own{border:1px solid var(--line);border-radius:8px}
.dk-l1{display:flex;align-items:center;gap:8px;min-width:0}.dk-l1 .dk-name{flex:0 1 auto}.dk-st{color:var(--mut);font-size:11px;margin-left:auto;white-space:nowrap}
.dk-l2{color:var(--mut);font-size:11px;display:flex;flex-wrap:wrap;gap:2px 8px;padding-left:17px;word-break:break-all}
.dk-l3{display:flex;align-items:center;gap:8px;padding-left:17px}.dk-nums{font-size:11px;color:var(--mut);white-space:nowrap;min-width:110px}
.dk-sp{display:block}.dk-sp .a{fill:color-mix(in srgb,var(--acc) 22%,transparent);stroke:none}.dk-sp .l{fill:none;stroke:var(--acc);stroke-width:1.4}
.dk-sp.m .a{fill:color-mix(in srgb,var(--ok) 22%,transparent)}.dk-sp.m .l{stroke:var(--ok)}
.dk-sp.n .l{stroke:#c58af9}.dk-sp.n .a{fill:color-mix(in srgb,#c58af9 20%,transparent)}
.dk-tags{display:flex;flex-wrap:wrap;gap:4px}.dk-tag{font-size:11px;padding:0 6px;border:1px solid var(--line);border-radius:5px;cursor:pointer;color:var(--fg)}.dk-tag.dim{color:var(--mut);cursor:default}
.dk-row{border:1px solid var(--line);border-radius:8px;padding:8px 10px;display:flex;flex-direction:column;gap:4px}
.dk-row .meta{color:var(--mut);font-size:11px;word-break:break-all}
.dk-page{position:absolute;inset:0;background:var(--panel);display:flex;flex-direction:column;z-index:4;min-height:0}.dk-page[hidden]{display:none}
.dk-ph{display:flex;align-items:center;gap:8px;padding:8px;border-bottom:1px solid var(--line);flex:none}.dk-ph .dk-name{flex:1}
.dk-pt{display:flex;gap:6px;align-items:center;padding:6px 8px;border-bottom:1px solid var(--line);flex:none;flex-wrap:wrap}.dk-pt input[type=text],.dk-pt input:not([type]){min-width:80px;flex:1;padding:3px 8px}.dk-pt select{padding:3px 6px}
.dk-pt label{display:flex;gap:4px;align-items:center;color:var(--mut);font-size:12px}
.dk-pc{flex:1;min-height:0;overflow:auto;display:flex;flex-direction:column}
.dk-log{margin:0;flex:1;min-height:0;overflow:auto;padding:8px;background:var(--tbg);color:var(--tfg);font:12px/1.4 var(--mono,monospace);white-space:pre-wrap;word-break:break-all}
.dk-term{flex:1;min-height:0;background:var(--tbg);padding:4px}
.dk-ed{flex:1;min-height:0;resize:none;border-radius:0;border:0;background:var(--tbg);color:var(--tfg);font:12px/1.5 var(--mono,monospace);padding:8px;tab-size:2;white-space:pre;overflow:auto}
.dk-msg{padding:5px 10px;font-size:12px;color:var(--mut);border-top:1px solid var(--line);flex:none;white-space:pre-wrap;word-break:break-word;max-height:30%;overflow:auto}.dk-msg.bad{color:var(--bad)}.dk-msg.ok{color:var(--ok)}
.dk-tabs{display:flex;gap:2px}.dk-tabs button{padding:2px 10px}.dk-tabs button.on{border-color:var(--acc)}
.dk-detail{padding:10px;display:flex;flex-direction:column;gap:12px}
.dk-ch2{border:1px solid var(--line);border-radius:8px;padding:6px 8px}.dk-ch2 .h{display:flex;justify-content:space-between;color:var(--mut);font-size:11px;margin-bottom:2px}.dk-ch2 .h b{color:var(--fg)}.dk-ch2 svg{width:100%;height:54px}
.dk-kv{display:grid;grid-template-columns:100px 1fr;gap:4px 10px;font-size:12px}.dk-kv>span:nth-child(odd){color:var(--mut)}.dk-kv>span:nth-child(even){word-break:break-all;white-space:pre-wrap}
.dk-map{width:100%;height:auto;display:block}.dk-map text{fill:var(--fg);font-size:10px;pointer-events:none}.dk-map .col{fill:var(--mut);font-size:9px;text-transform:uppercase;letter-spacing:.08em}
.dk-map .n rect{fill:var(--btn,#222);stroke:var(--line)}.dk-map .n{cursor:pointer}.dk-map .n:hover rect{stroke:var(--acc)}
.dk-map .e{fill:none;stroke:var(--mut);stroke-opacity:.45;stroke-width:1}.dk-map.hov .e{stroke-opacity:.08}.dk-map.hov .e.hl{stroke:var(--acc);stroke-opacity:1;stroke-width:1.8}
.dk-dlg{position:absolute;inset:0;z-index:6;background:#0008;display:flex;align-items:center;justify-content:center;padding:12px}
.dk-dlg>div{background:var(--panel);border:1px solid var(--line);border-radius:10px;max-width:100%;width:100%;max-height:90%;display:flex;flex-direction:column;box-shadow:var(--shadow)}
.dk-dlg h4{margin:0;padding:10px 12px;border-bottom:1px solid var(--line)}.dk-dlg pre{margin:0;padding:10px 12px;overflow:auto;font:12px/1.4 var(--mono,monospace);white-space:pre-wrap;word-break:break-word;flex:1}.dk-dlg .f{padding:8px 12px;border-top:1px solid var(--line);display:flex;justify-content:flex-end}
.dk-form{display:flex;flex-direction:column;gap:8px;padding:12px}.dk-form h4{margin:0}.dk-form label{color:var(--mut);font-size:11px;margin-bottom:-4px}.dk-form .ck{display:flex;gap:6px;align-items:center;color:var(--fg);font-size:12px;margin:0}.dk-form .help{color:var(--mut);font-size:11px}
.dk-body>*,.dk-pc>.dk-detail,.dk-form{flex:none}
.dk-body{overscroll-behavior:contain}
