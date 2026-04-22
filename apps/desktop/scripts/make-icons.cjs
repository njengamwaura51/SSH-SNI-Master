// Produce the minimum icon set tauri.conf.json requires:
//   icons/32x32.png, icons/128x128.png, icons/128x128@2x.png,
//   icons/icon.ico, icons/icon.icns
//
// We avoid sharp/canvas (heavy native deps for a one-shot script) by
// emitting simple solid-color PNGs at the right dimensions plus minimal ICO
// and ICNS wrappers. They are placeholders that satisfy the bundler — the
// user can drop in nicer art any time. Branding SVG lives at
// src-tauri/icons/icon.svg for anyone with imagemagick to regenerate.
//
// Usage: node scripts/make-icons.cjs
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const OUT_DIR = path.join(__dirname, "..", "src-tauri", "icons");
fs.mkdirSync(OUT_DIR, { recursive: true });

// CRC32 — RFC 1952 table.
const CRC_TABLE = new Uint32Array(256);
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  CRC_TABLE[n] = c >>> 0;
}
function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}

function makePng(size, rgba) {
  // RGBA raster, scanline-filtered (filter=0).
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter
    for (let x = 0; x < size; x++) {
      const off = y * (stride + 1) + 1 + x * 4;
      // Soft radial gradient → ring → center dot, using brand palette.
      const cx = size / 2;
      const cy = size / 2;
      const dx = x - cx;
      const dy = y - cy;
      const d = Math.sqrt(dx * dx + dy * dy);
      const r = size / 2;
      let pixel;
      if (d < r * 0.07) pixel = [0x03, 0xda, 0xc6, 0xff]; // center dot
      else if (Math.abs(d - r * 0.6) < r * 0.05)
        pixel = [0xbb, 0x86, 0xfc, 0xff]; // ring
      else if (d < r * 0.95) {
        // background gradient
        const t = d / r;
        pixel = [
          Math.round(0x1a + (0x12 - 0x1a) * t),
          Math.round(0x10 + (0x12 - 0x10) * t),
          Math.round(0x3a + (0x12 - 0x3a) * t),
          0xff,
        ];
      } else pixel = [0, 0, 0, 0]; // outside circle = transparent
      raw[off] = pixel[0];
      raw[off + 1] = pixel[1];
      raw[off + 2] = pixel[2];
      raw[off + 3] = pixel[3];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", idat),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function writePng(name, size) {
  const p = path.join(OUT_DIR, name);
  fs.writeFileSync(p, makePng(size));
  console.log("  wrote", path.relative(process.cwd(), p), `(${size}×${size})`);
}

function writeIco() {
  // Simple ICO containing a single 32×32 PNG entry (PNG-in-ICO is allowed
  // since Vista).
  const png = makePng(32);
  const dir = Buffer.alloc(6);
  dir.writeUInt16LE(0, 0); // reserved
  dir.writeUInt16LE(1, 2); // type = ICO
  dir.writeUInt16LE(1, 4); // count
  const entry = Buffer.alloc(16);
  entry[0] = 32;
  entry[1] = 32;
  entry[2] = 0;
  entry[3] = 0;
  entry.writeUInt16LE(1, 4);
  entry.writeUInt16LE(32, 6);
  entry.writeUInt32LE(png.length, 8);
  entry.writeUInt32LE(6 + 16, 12);
  fs.writeFileSync(
    path.join(OUT_DIR, "icon.ico"),
    Buffer.concat([dir, entry, png])
  );
  console.log("  wrote icons/icon.ico");
}

function writeIcns() {
  // Minimal ICNS containing one 128×128 PNG (type 'ic07').
  const png = makePng(128);
  const typeTag = Buffer.from("ic07", "ascii");
  const len = Buffer.alloc(4);
  len.writeUInt32BE(8 + png.length, 0);
  const body = Buffer.concat([typeTag, len, png]);

  const header = Buffer.from("icns", "ascii");
  const totalLen = Buffer.alloc(4);
  totalLen.writeUInt32BE(8 + body.length, 0);
  fs.writeFileSync(
    path.join(OUT_DIR, "icon.icns"),
    Buffer.concat([header, totalLen, body])
  );
  console.log("  wrote icons/icon.icns");
}

console.log("[make-icons] generating placeholder icon set:");
writePng("32x32.png", 32);
writePng("128x128.png", 128);
writePng("128x128@2x.png", 256);
writeIco();
writeIcns();
console.log("[make-icons] done. Replace with real art any time.");
