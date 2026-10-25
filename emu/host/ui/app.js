// Simulator UI: draws the device screen from the server's WebSocket and turns
// pointer input into pen/touch records (same 16-byte format as shim/input.c).
const W = 1404, H = 1872;  // Paper Pure, portrait
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const $ = (id) => document.getElementById(id);

let ws = null;
let tool = 'pen';
let updates = 0;

// ---------------------------------------------------------------- input records

function record(type, flags, x, y, pressure = 0, tiltX = 0, tiltY = 0) {
  const b = new ArrayBuffer(16), v = new DataView(b);
  v.setUint8(0, type.charCodeAt(0)); v.setUint8(1, flags);
  v.setUint16(2, Math.max(0, Math.min(4095, Math.round(pressure))), true);
  v.setInt32(4, Math.round(x * 8), true); v.setInt32(8, Math.round(y * 8), true);
  v.setInt16(12, tiltX, true); v.setInt16(14, tiltY, true);
  return b;
}
const send = (buf) => { if (ws?.readyState === 1) ws.send(buf); };
const command = (msg) => { if (ws?.readyState === 1) ws.send(JSON.stringify(msg)); };

function toDevice(e) {
  const r = canvas.getBoundingClientRect();
  return [
    Math.max(0, Math.min(W - 1, ((e.clientX - r.left) / r.width) * W)),
    Math.max(0, Math.min(H - 1, ((e.clientY - r.top) / r.height) * H)),
  ];
}

// Pen: real styluses report pressure/tilt; a mouse gets a medium press.
function penRecord(e, flags, x, y) {
  const stylus = e.pointerType === 'pen';
  const pressure = flags & 2 ? (stylus && e.pressure > 0 ? e.pressure : 0.6) * 4095 : 0;
  const tx = stylus ? Math.round((e.tiltX || 0) * 100) : 0, ty = stylus ? Math.round((e.tiltY || 0) * 100) : 0;
  return record('P', flags | (tool === 'eraser' ? 4 : 0), x, y, pressure, tx, ty);
}

// Touch indicators, iOS-Simulator style.
const touchEls = [];
function showTouches(points) {
  const box = $('touches');
  while (touchEls.length < points.length) { const d = document.createElement('div'); d.className = 'touch'; box.append(d); touchEls.push(d); }
  touchEls.forEach((el, i) => {
    el.hidden = i >= points.length;
    if (points[i]) { el.style.left = `${(points[i][0] / W) * 100}%`; el.style.top = `${(points[i][1] / H) * 100}%`; }
  });
}

let active = null;  // { pinch } while a pointer is down
function touchPoints(x, y, pinch) {
  return pinch ? [[x, y], [W - x, H - y]] : [[x, y]];
}
function sendTouches(points, down) {
  points.forEach(([x, y], slot) => send(record('T', slot | (down ? 16 : 0) | (slot < points.length - 1 ? 32 : 0), x, y)));
}

canvas.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  canvas.setPointerCapture(e.pointerId);
  const [x, y] = toDevice(e);
  if (tool === 'finger') {
    active = { pinch: e.altKey };
    const pts = touchPoints(x, y, active.pinch);
    sendTouches(pts, true); showTouches(pts);
  } else {
    active = {};
    send(penRecord(e, 1, x, y));
    send(penRecord(e, 3, x, y));
  }
});
canvas.addEventListener('pointermove', (e) => {
  const [x, y] = toDevice(e);
  $('coords').textContent = `x ${String(Math.round(x)).padStart(4)}  y ${String(Math.round(y)).padStart(4)}`;
  if (!active) return;
  const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
  for (const ev of events) {
    const [cx, cy] = toDevice(ev);
    if (tool === 'finger') { const pts = touchPoints(cx, cy, active.pinch); sendTouches(pts, true); showTouches(pts); }
    else send(penRecord(ev, 3, cx, cy));
  }
});
function release(e) {
  if (!active) return;
  const [x, y] = toDevice(e);
  if (tool === 'finger') { sendTouches(touchPoints(x, y, active.pinch), false); showTouches([]); }
  else { send(penRecord(e, 1, x, y)); send(penRecord(e, 0, x, y)); }
  active = null;
}
canvas.addEventListener('pointerup', release);
canvas.addEventListener('pointercancel', release);
canvas.addEventListener('pointerleave', () => { if (!active) $('coords').textContent = 'x —  y —'; });
canvas.addEventListener('contextmenu', (e) => e.preventDefault());

// ---------------------------------------------------------------- toolbar

function setTool(t) {
  tool = t;
  document.body.dataset.tool = t;
  document.querySelectorAll('[data-tool]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.tool === t)));
  try { localStorage.setItem('rmemu.tool', t); } catch {}
}
document.querySelectorAll('[data-tool]').forEach((b) => b.addEventListener('click', () => setTool(b.dataset.tool)));

const power = () => command({ cmd: 'gesture', gesture: { op: 'key', key: 'power' } });
$('power').addEventListener('click', power);
$('powerKey').addEventListener('click', power);

$('folio').addEventListener('click', () => {
  const closed = $('folio').getAttribute('aria-pressed') !== 'true';
  $('folio').setAttribute('aria-pressed', String(closed));
  $('folio').title = closed ? 'Open the cover (hall sensor)' : 'Close the cover (hall sensor)';
  command({ cmd: 'gesture', gesture: { op: 'folio', open: !closed } });
});

$('marker').addEventListener('click', () => {
  const docked = $('marker').getAttribute('aria-pressed') !== 'true';
  $('marker').setAttribute('aria-pressed', String(docked));
  $('marker').title = docked ? 'Detach the Marker' : 'Attach the Marker';
  command({ cmd: 'gesture', gesture: { op: 'marker', docked } });
});

async function screenshot() {
  const blob = await (await fetch('/api/screenshot.png')).blob();
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `paperpro-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}.png`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
$('shot').addEventListener('click', screenshot);
$('restart').addEventListener('click', () => command({ cmd: 'restart' }));

function setPaper(on) {
  $('screen').classList.toggle('paper', on);
  $('paper').setAttribute('aria-pressed', String(on));
  try { localStorage.setItem('rmemu.paper', on ? '1' : '0'); } catch {}
}
$('paper').addEventListener('click', () => setPaper(!$('screen').classList.contains('paper')));

addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); screenshot(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest('input, textarea')) return;
  const t = { p: 'pen', e: 'eraser', f: 'finger' }[e.key.toLowerCase()];
  if (t) setTool(t);
});

try {
  setTool(localStorage.getItem('rmemu.tool') || 'pen');
  setPaper(localStorage.getItem('rmemu.paper') === '1');
} catch { setTool('pen'); }

// ---------------------------------------------------------------- screen

// Rects must be painted in arrival order; decompression is async.
let chain = Promise.resolve();
function paint(buf) {
  const v = new DataView(buf);
  const x = v.getUint16(1, true), y = v.getUint16(3, true), w = v.getUint16(5, true), h = v.getUint16(7, true);
  const z = new Blob([new Uint8Array(buf, 13)]).stream().pipeThrough(new DecompressionStream('deflate'));
  chain = chain.then(async () => {
    const px = new Uint8ClampedArray(await new Response(z).arrayBuffer());
    if (px.length === w * h * 4) ctx.putImageData(new ImageData(px, w, h), x, y);
    updates++;
  }).catch(() => {});
}

function status(s) {
  $('dot').classList.toggle('on', !!s.connected);
  $('dot').title = s.connected ? 'Connected' : 'Disconnected';
  $('fw').textContent = s.firmware ? s.firmware : '';
  $('offline').hidden = !!s.connected;
}

function connect() {
  ws = new WebSocket(`ws://${location.host}/ws`);
  ws.binaryType = 'arraybuffer';
  ws.onmessage = (m) => {
    if (typeof m.data === 'string') { const msg = JSON.parse(m.data); if (msg.type === 'status') status(msg); }
    else paint(m.data);
  };
  ws.onclose = () => { status({ connected: false }); setTimeout(connect, 1000); };
}
connect();

setInterval(() => { $('rate').textContent = updates ? `${updates} updates/s` : ''; updates = 0; }, 1000);
