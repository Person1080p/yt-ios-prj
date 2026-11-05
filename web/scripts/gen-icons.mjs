// Renders the PWA PNG icons (same design as public/icon.svg) without native deps.
import { writeFileSync } from "node:fs";
import { deflateSync } from "node:zlib";

const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};

// maskable: full-bleed with the glyph shrunk into the safe zone.
// square:   full-bleed, opaque, glyph at normal size (iOS applies its own rounded mask).
function png(size, maskable, square = false) {
  const SS = 3; // supersampling for anti-aliasing
  const raw = Buffer.alloc(size * (size * 4 + 1));
  const s = size / 512;
  const radius = maskable || square ? 0 : 112 * s;
  const inset = maskable ? 0.8 : 1; // keep the glyph in the maskable safe zone
  const c = size / 2;
  const tri = [
    [220, 190],
    [330, 256],
    [220, 322],
  ].map(([x, y]) => [c + (x - 256) * s * inset, c + (y - 256) * s * inset]);
  const inTri = (x, y) => {
    const [[x1, y1], [x2, y2], [x3, y3]] = tri;
    const d1 = (x - x2) * (y1 - y2) - (x1 - x2) * (y - y2);
    const d2 = (x - x3) * (y2 - y3) - (x2 - x3) * (y - y3);
    const d3 = (x - x1) * (y3 - y1) - (x3 - x1) * (y - y1);
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
  };
  const inRect = (x, y) => {
    const dx = Math.max(radius - x, 0, x - (size - radius));
    const dy = Math.max(radius - y, 0, y - (size - radius));
    return dx * dx + dy * dy <= radius * radius || radius === 0;
  };
  const ringR = 150 * s * inset;
  const ringW = 14 * s * inset;

  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0;
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < SS; sy++)
        for (let sx = 0; sx < SS; sx++) {
          const px = x + (sx + 0.5) / SS;
          const py = y + (sy + 0.5) / SS;
          if (!inRect(px, py)) continue;
          const t = (px + py) / (2 * size);
          let cr = 255 + (124 - 255) * t, cg = 77 + (58 - 77) * t, cb = 109 + (237 - 109) * t;
          const d = Math.hypot(px - c, py - c);
          if (Math.abs(d - ringR) <= ringW || inTri(px, py)) (cr = 255), (cg = 255), (cb = 255);
          r += cr; g += cg; b += cb; a += 255;
        }
      const n = SS * SS;
      const o = y * (size * 4 + 1) + 1 + x * 4;
      raw[o] = r / n; raw[o + 1] = g / n; raw[o + 2] = b / n; raw[o + 3] = a / n;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const out = new URL("../public/", import.meta.url);
writeFileSync(new URL("icon-192.png", out), png(192, false));
writeFileSync(new URL("icon-512.png", out), png(512, false));
writeFileSync(new URL("icon-maskable-512.png", out), png(512, true));
// iPhone/iPad home screen icon: 180×180, no transparency, no rounded corners.
writeFileSync(new URL("apple-touch-icon.png", out), png(180, false, true));
console.log("icons written");
