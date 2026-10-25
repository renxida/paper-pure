// Minimal PNG encoder for screenshots (RGB, optional box downscale).
import zlib from 'node:zlib';

const crcTable = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

export function encodePNG(rgba, width, height, scale = 1) {
  const s = Math.max(1, Math.round(1 / Math.min(1, scale)));  // integer box factor
  const w = Math.floor(width / s), h = Math.floor(height / s);
  const raw = Buffer.alloc((w * 3 + 1) * h);
  const area = s * s;
  for (let y = 0; y < h; y++) {
    let o = y * (w * 3 + 1);
    raw[o++] = 0;
    for (let x = 0; x < w; x++) {
      let r = 0, g = 0, b = 0;
      for (let dy = 0; dy < s; dy++) {
        let i = ((y * s + dy) * width + x * s) * 4;
        for (let dx = 0; dx < s; dx++, i += 4) { r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; }
      }
      raw[o++] = r / area; raw[o++] = g / area; raw[o++] = b / area;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;  // 8-bit RGB
  return {
    png: Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0)),
    ]),
    width: w, height: h, factor: s,
  };
}
