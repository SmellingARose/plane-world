#!/usr/bin/env node
// Germ War live server (no dependencies).
//  - serves the game
//  - watches mods/*.js and tells the running game to hot-reload them (no restart)
//  - POST /eval runs JS inside the running game and returns the result:
//      curl -s localhost:8787/eval -d 'GW.money += 1000'
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = __dirname, MODS = path.join(ROOT, 'mods'), PORT = +process.env.PORT || 8787;
const TYPES = { '.html':'text/html', '.js':'text/javascript', '.css':'text/css', '.json':'application/json', '.png':'image/png', '.md':'text/plain' };
const clients = new Set(), pending = new Map();
let nextId = 1;

function send(msg){ const s = `data: ${JSON.stringify(msg)}\n\n`; for (const c of clients) c.write(s); }
const readBody = req => new Promise(r => { let b = ''; req.on('data', d => b += d); req.on('end', () => r(b)); });

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/events'){
    res.writeHead(200, { 'Content-Type':'text/event-stream', 'Cache-Control':'no-cache', Connection:'keep-alive' });
    res.write(': connected\n\n'); clients.add(res); req.on('close', () => clients.delete(res)); return;
  }
  if (url.pathname === '/mods'){
    const list = fs.readdirSync(MODS).filter(f => f.endsWith('.js')).sort();
    res.writeHead(200, { 'Content-Type':'application/json' }); return res.end(JSON.stringify(list));
  }
  if (url.pathname === '/eval' && req.method === 'POST'){
    const code = await readBody(req);
    if (!clients.size){ res.writeHead(503); return res.end('no game connected — open http://localhost:' + PORT + '\n'); }
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); res.end('timeout (is the game tab open?)\n'); }, 5000);
    pending.set(id, v => { clearTimeout(timer); res.end(v + '\n'); });
    send({ type:'eval', id, code }); return;
  }
  if (url.pathname === '/result' && req.method === 'POST'){
    const { id, value } = JSON.parse(await readBody(req));
    const p = pending.get(id); if (p){ pending.delete(id); p(value); }   // first tab to answer wins
    return res.end('ok');
  }
  const file = path.normalize(path.join(ROOT, url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname)));
  if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()){ res.writeHead(404); return res.end('not found'); }
  res.writeHead(200, { 'Content-Type':TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control':'no-store' });
  fs.createReadStream(file).pipe(res);
}).listen(PORT, () => console.log(`Germ War live server → http://localhost:${PORT}`));

// Editors fire several events per save, so debounce per file.
const timers = {};
fs.watch(MODS, (ev, file) => {
  if (!file || !file.endsWith('.js')) return;
  clearTimeout(timers[file]);
  timers[file] = setTimeout(() => { if (fs.existsSync(path.join(MODS, file))){ console.log('hot-reload', file); send({ type:'mod', file }); } }, 120);
});
setInterval(() => { for (const c of clients) c.write(': ping\n\n'); }, 20000);
