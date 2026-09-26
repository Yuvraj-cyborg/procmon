// Writes an .icns file from pre-optimised PNGs, storing them byte for byte.
// (iconutil re-encodes PNGs and roughly triples their size.)
//
// Usage: node scripts/icon/icns.mjs <png-dir> <out.icns>
// where <png-dir> contains 16.png, 32.png, 64.png, … 1024.png.

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [dir, out] = process.argv.slice(2);
if (!dir || !out) {
  console.error('usage: icns.mjs <png-dir> <out.icns>');
  process.exit(1);
}

// OSType -> pixel size. The @2x types reuse the next size up.
const ENTRIES = [
  ['icp4', 16],
  ['icp5', 32],
  ['icp6', 64],
  ['ic07', 128],
  ['ic08', 256],
  ['ic09', 512],
  ['ic10', 1024],
  ['ic11', 32],
  ['ic12', 64],
  ['ic13', 256],
  ['ic14', 512],
];

const chunks = ENTRIES.map(([type, size]) => {
  const png = readFileSync(join(dir, `${size}.png`));
  const header = Buffer.alloc(8);
  header.write(type, 0, 'latin1');
  header.writeUInt32BE(png.length + 8, 4);
  return Buffer.concat([header, png]);
});

const body = Buffer.concat(chunks);
const header = Buffer.alloc(8);
header.write('icns', 0, 'latin1');
header.writeUInt32BE(body.length + 8, 4);
writeFileSync(out, Buffer.concat([header, body]));
