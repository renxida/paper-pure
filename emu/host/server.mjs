// ppemu host server (forked from rmemu): bridges the emulator container to
// the simulator UI (WebSocket) and to scripts/agents (HTTP API).
//
//   GET  /                     simulator UI
//   GET  /ws                   live screen (binary 'F' rects) + input (16-byte records)
//   GET  /api/status           connection + device info
//   GET  /api/screenshot.png   ?scale=0.5
//   POST /api/gesture          {op: tap|longpress|swipe|draw|pinch|key|folio, ...}; waits for the screen to settle
//   GET  /api/wait             ?idle=400&timeout=10000&min=0
//   POST /api/xochitl/restart
//   GET  /api/logs             ?lines=200
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Device } from './device.mjs';
import { encodePNG } from './png.mjs';
import { play } from './gestures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.RMEMU_UI_PORT || 7777);
const CONTAINER = process.env.PPEMU_CONTAINER || process.env.RMEMU_CONTAINER || 'pp-emu-tablet';
// On an x86 host the arm64 device runs under qemu-user and reacts seconds,
// not milliseconds, after input, so gestures wait longer before calling the
// screen settled. PPEMU_SLOW=1/0 forces either profile.
const SLOW = process.env.PPEMU_SLOW ? process.env.PPEMU_SLOW === '1' : process.arch !== 'arm64';
const SETTLE = SLOW ? { idle: 1500, min: 4000, timeout: 30000 } : { idle: 500, min: 300, timeout: 8000 };
const device = new Device({ port: Number(process.env.RMEMU_DEVICE_PORT || 8888) });

const docker = (args) => new Promise((resolve) => {
  execFile('docker', args, { maxBuffer: 16 << 20 }, (err, stdout, stderr) => resolve({ ok: !err, out: stdout + stderr }));
});

let firmware = null;
async function info() {
  if (!firmware) {
    const r = await docker(['exec', CONTAINER, 'sh', '-c', '. /etc/os-release; echo $IMG_VERSION']);
    if (r.ok) firmware = r.out.match(/^\d+(\.\d+){3}$/m)?.[0] ?? null;
  }
  return {
    connected: device.connected, width: device.width, height: device.height,
    firmware, container: CONTAINER, model: 'reMarkable Paper Pure (tatsu)', slow: SLOW, lastFrameAt: device.lastFrameAt,
  };
}

// ---------------------------------------------------------------- websocket

const clients = new Set();

function wsSend(sock, data) {
  const isText = typeof data === 'string';
  const payload = isText ? Buffer.from(data) : data;
  let hdr;
  if (payload.length < 126) hdr = Buffer.from([0x80 | (isText ? 1 : 2), payload.length]);
  else if (payload.length < 65536) { hdr = Buffer.alloc(4); hdr[0] = 0x80 | (isText ? 1 : 2); hdr[1] = 126; hdr.writeUInt16BE(payload.length, 2); }
  else { hdr = Buffer.alloc(10); hdr[0] = 0x80 | (isText ? 1 : 2); hdr[1] = 127; hdr.writeBigUInt64BE(BigInt(payload.length), 2); }
  sock.write(Buffer.concat([hdr, payload]));
}

function wsAccept(req, sock) {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  sock.setNoDelay(true);
  clients.add(sock);
  info().then((i) => { wsSend(sock, JSON.stringify({ type: 'status', ...i })); wsSend(sock, device.fullFrame()); });

  let buf = Buffer.alloc(0);
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const op = buf[0] & 15, masked = buf[1] & 0x80;
      let len = buf[1] & 127, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const mask = masked ? buf.subarray(off, off + 4) : null;
      if (masked) off += 4;
      if (buf.length < off + len) return;
      const data = Buffer.from(buf.subarray(off, off + len));
      if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      buf = buf.subarray(off + len);
      if (op === 8) { sock.end(); return; }
      if (op === 9) { sock.write(Buffer.from([0x8a, 0])); continue; }
      if (op === 2) for (let i = 0; i + 16 <= data.length; i += 16) device.send(data.subarray(i, i + 16));
      if (op === 1) handleCommand(sock, data.toString());
    }
  });
  const drop = () => clients.delete(sock);
  sock.on('close', drop);
  sock.on('error', drop);
}

async function handleCommand(sock, text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (msg.cmd === 'gesture') await play(device, msg.gesture).catch(() => {});
  if (msg.cmd === 'restart') await docker(['exec', CONTAINER, 'systemctl', 'restart', 'xochitl']);
}

device.on('rect', (msg) => { for (const c of clients) wsSend(c, msg); });
device.on('status', () => info().then((i) => { for (const c of clients) wsSend(c, JSON.stringify({ type: 'status', ...i })); }));

// ---------------------------------------------------------------- http

const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };

function json(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const s = Buffer.concat(chunks).toString();
  return s ? JSON.parse(s) : {};
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname === '/api/status') return json(res, 200, await info());
    if (url.pathname === '/api/screenshot.png') {
      const { png, width, height, factor } = encodePNG(device.fb, device.width, device.height, Number(url.searchParams.get('scale') || 1));
      res.writeHead(200, { 'content-type': 'image/png', 'x-rmemu-size': `${width}x${height}`, 'x-rmemu-factor': String(factor) });
      return res.end(png);
    }
    if (url.pathname === '/api/gesture' && req.method === 'POST') {
      const g = await readBody(req);
      const before = device.frames;
      await play(device, g);
      // UIs often react a beat after input (and e-ink refreshes run on), so
      // give it a moment to start before calling it settled.
      const settle = g.wait === false ? { changed: device.frames !== before } : await device.waitIdle(g.idle ?? SETTLE.idle, g.timeout ?? SETTLE.timeout, g.min ?? SETTLE.min);
      return json(res, 200, { ok: true, changed: settle.changed || device.frames !== before });
    }
    if (url.pathname === '/api/wait') {
      const q = (k, d) => Number(url.searchParams.get(k) || d);
      return json(res, 200, await device.waitIdle(q('idle', 400), q('timeout', 10000), q('min', 0)));
    }
    if (url.pathname === '/api/xochitl/restart' && req.method === 'POST') {
      const r = await docker(['exec', CONTAINER, 'systemctl', 'restart', 'xochitl']);
      return json(res, r.ok ? 200 : 500, r);
    }
    if (url.pathname === '/api/logs') {
      const r = await docker(['logs', '--tail', url.searchParams.get('lines') || '200', CONTAINER]);
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      return res.end(r.out.split('\n').filter((l) => !l.includes('Could not open bin file')).join('\n'));
    }
    // Static UI.
    const file = path.join(here, 'ui', url.pathname === '/' ? 'index.html' : path.normalize(url.pathname).replace(/^\/+/, ''));
    if (!file.startsWith(path.join(here, 'ui')) || !fs.existsSync(file)) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache' });
    fs.createReadStream(file).pipe(res);
  } catch (e) {
    json(res, 500, { ok: false, error: String(e.message || e) });
  }
});

server.on('upgrade', (req, sock) => {
  if (new URL(req.url, 'http://x').pathname === '/ws' && req.headers['sec-websocket-key']) wsAccept(req, sock);
  else sock.destroy();
});

server.listen(PORT, '127.0.0.1', () => console.log(`ppemu UI on http://127.0.0.1:${PORT} (container ${CONTAINER}${SLOW ? ', slow host' : ''})`));
