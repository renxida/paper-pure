// Connection to the shim's frame/input socket inside the container.
// Keeps a full RGBA copy of the screen and re-emits each dirty rect.
import net from 'node:net';
import zlib from 'node:zlib';
import { EventEmitter } from 'node:events';

export class Device extends EventEmitter {
  constructor({ host = '127.0.0.1', port = 8888 } = {}) {
    super();
    this.host = host;
    this.port = port;
    this.width = 1404;  // Paper Pure; the shim's hello overrides these
    this.height = 1872;
    this.fb = Buffer.alloc(this.width * this.height * 4, 255);
    this.connected = false;
    this.lastFrameAt = 0;
    this.lastActivityAt = 0;
    this.frames = 0;
    this.connect();
  }

  connect() {
    const sock = net.connect(this.port, this.host);
    let buf = Buffer.alloc(0);
    let hello = false;
    sock.setNoDelay(true);
    sock.on('data', (chunk) => {
      buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
      if (!hello) {
        if (buf.length < 8) return;
        if (buf.toString('latin1', 0, 4) !== 'RMFB') { sock.destroy(); return; }
        const w = buf.readUInt16LE(4), h = buf.readUInt16LE(6);
        if (w !== this.width || h !== this.height) {
          this.width = w; this.height = h;
          this.fb = Buffer.alloc(w * h * 4, 255);
        }
        buf = buf.subarray(8);
        hello = true;
        this.connected = true;
        this.sock = sock;
        this.emit('status');
      }
      // 'F' u16 x y w h, u32 zlen, zlib(RGBA) | 'A' (panel busy)
      for (;;) {
        if (buf.length >= 1 && buf[0] === 0x41) { buf = buf.subarray(1); this.lastActivityAt = Date.now(); continue; }
        if (buf.length < 13) break;
        const zlen = buf.readUInt32LE(9);
        if (buf.length < 13 + zlen) break;
        const msg = buf.subarray(0, 13 + zlen);
        buf = buf.subarray(13 + zlen);
        this.applyRect(msg);
      }
    });
    const retry = () => {
      if (this.connected) { this.connected = false; this.emit('status'); }
      this.sock = null;
      setTimeout(() => this.connect(), 500);
    };
    sock.on('error', () => {});
    sock.on('close', retry);
  }

  applyRect(msg) {
    const x = msg.readUInt16LE(1), y = msg.readUInt16LE(3), w = msg.readUInt16LE(5), h = msg.readUInt16LE(7);
    let px;
    try { px = zlib.inflateSync(msg.subarray(13)); } catch { return; }
    const row = w * 4;
    for (let r = 0; r < h; r++) px.copy(this.fb, ((y + r) * this.width + x) * 4, r * row, (r + 1) * row);
    this.lastFrameAt = Date.now();
    this.frames++;
    this.emit('rect', Buffer.from(msg), { x, y, w, h });
  }

  // Whole screen as one 'F' message, for clients that join late.
  fullFrame() {
    const z = zlib.deflateSync(this.fb, { level: 1 });
    const hdr = Buffer.alloc(13);
    hdr.write('F', 0, 'latin1');
    hdr.writeUInt16LE(0, 1); hdr.writeUInt16LE(0, 3);
    hdr.writeUInt16LE(this.width, 5); hdr.writeUInt16LE(this.height, 7);
    hdr.writeUInt32LE(z.length, 9);
    return Buffer.concat([hdr, z]);
  }

  send(record) {
    if (this.sock) this.sock.write(record);
  }

  // Resolves once neither the image nor the panel has changed for `idle` ms
  // (or on timeout). `min` keeps waiting at least that long for a reaction.
  waitIdle(idle = 400, timeout = 10000, min = 0) {
    const start = Date.now();
    const startFrames = this.frames;
    return new Promise((resolve) => {
      const tick = () => {
        const now = Date.now();
        const quiet = now - start >= min && now - Math.max(this.lastFrameAt, this.lastActivityAt, start) >= idle;
        if (quiet || now - start >= timeout) resolve({ changed: this.frames !== startFrames, timedOut: !quiet });
        else setTimeout(tick, 50);
      };
      tick();
    });
  }
}

// 16-byte input record understood by shim/input.c.
export function record(type, flags = 0, x = 0, y = 0, pressure = 0, tiltX = 0, tiltY = 0) {
  const b = Buffer.alloc(16);
  b.write(type, 0, 'latin1');
  b.writeUInt8(flags, 1);
  b.writeUInt16LE(Math.max(0, Math.min(4095, Math.round(pressure))), 2);
  b.writeInt32LE(Math.round(x * 8), 4);
  b.writeInt32LE(Math.round(y * 8), 8);
  b.writeInt16LE(tiltX, 12);
  b.writeInt16LE(tiltY, 14);
  return b;
}
