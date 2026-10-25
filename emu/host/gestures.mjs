// High-level gestures -> timed input records. Coordinates are device pixels
// (portrait 1404x1872, origin top-left).
import { record } from './device.mjs';

const KEYS = { power: 116 };
const SWITCHES = { lid: 0 };
const PEN = { range: 1, touch: 2, eraser: 4, button: 8 };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lerp = (a, b, t) => a + (b - a) * t;

// Points along a polyline, at most `step` px apart.
function densify(points, step = 4) {
  const out = [points[0]];
  for (let i = 1; i < points.length; i++) {
    const [x0, y0] = points[i - 1], [x1, y1] = points[i];
    const n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / step));
    for (let k = 1; k <= n; k++) out.push([lerp(x0, x1, k / n), lerp(y0, y1, k / n)]);
  }
  return out;
}

async function penStroke(dev, points, { pressure = 0.6, eraser = false, ms } = {}) {
  const pts = densify(points);
  const dt = ms ? ms / pts.length : 4;
  const tool = eraser ? PEN.eraser : 0;
  const p = pressure * 4095;
  dev.send(record('P', PEN.range | tool, ...pts[0])); await sleep(10);
  for (const [x, y] of pts) { dev.send(record('P', PEN.range | PEN.touch | tool, x, y, p)); await sleep(dt); }
  const [lx, ly] = pts[pts.length - 1];
  dev.send(record('P', PEN.range | tool, lx, ly)); await sleep(10);
  dev.send(record('P', 0, lx, ly));
}

async function fingerPath(dev, points, { ms = 250, hold = 0 } = {}) {
  const pts = densify(points, 6);
  const dt = Math.max(4, ms / pts.length);
  dev.send(record('T', 16, ...pts[0]));
  if (hold) await sleep(hold);
  for (const [x, y] of pts.slice(1)) { await sleep(dt); dev.send(record('T', 16, x, y)); }
  await sleep(dt);
  dev.send(record('T', 0, ...pts[pts.length - 1]));
}

export async function play(dev, g) {
  const pen = g.tool === 'pen' || g.tool === 'eraser';
  const eraser = g.tool === 'eraser';
  switch (g.op) {
    case 'tap':
      if (pen) return penStroke(dev, [[g.x, g.y], [g.x, g.y]], { eraser, ms: 40 });
      return fingerPath(dev, [[g.x, g.y]], { ms: 0, hold: 60 });
    case 'longpress':
      if (pen) return penStroke(dev, [[g.x, g.y], [g.x, g.y]], { eraser, ms: g.ms ?? 900 });
      return fingerPath(dev, [[g.x, g.y]], { ms: 0, hold: g.ms ?? 900 });
    case 'swipe': {
      const pts = [[g.x0, g.y0], [g.x1, g.y1]];
      if (pen) return penStroke(dev, pts, { eraser, ms: g.ms ?? 300 });
      return fingerPath(dev, pts, { ms: g.ms ?? 300 });
    }
    case 'draw':
      return penStroke(dev, g.points, { pressure: g.pressure ?? 0.6, eraser: g.eraser ?? eraser, ms: g.ms });
    case 'pinch': {
      // Two fingers on a horizontal line through (cx, cy), radius r0 -> r1.
      const steps = Math.max(2, Math.round((g.ms ?? 400) / 12));
      for (let i = 0; i <= steps; i++) {
        const r = lerp(g.r0, g.r1, i / steps);
        dev.send(record('T', 16 | 32 | 0, g.cx - r, g.cy));
        dev.send(record('T', 16 | 1, g.cx + r, g.cy));
        await sleep(12);
      }
      dev.send(record('T', 32 | 0, g.cx - g.r1, g.cy));
      dev.send(record('T', 1, g.cx + g.r1, g.cy));
      return;
    }
    case 'key': {
      const code = KEYS[g.key] ?? Number(g.key);
      if (g.action !== 'up') dev.send(record('K', 1, code));
      if (g.action === 'down') return;
      await sleep(g.ms ?? 120);
      dev.send(record('K', 0, code));
      return;
    }
    case 'folio':
      dev.send(record('S', g.open ? 0 : 1, SWITCHES.lid));
      return;
    case 'marker':  // magnetically attach (dock + charge) or detach the Marker
      dev.send(record('M', g.docked ? 1 : 0));
      return;
    case 'usb':  // USB-C power
      dev.send(record('C', g.connected ? 1 : 0));
      return;
    case 'battery':
      dev.send(record('B', 0, Math.max(0, Math.min(100, Math.round(g.percent)))));
      return;
    default:
      throw new Error(`unknown gesture op: ${g.op}`);
  }
}
