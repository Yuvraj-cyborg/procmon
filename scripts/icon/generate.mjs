// Generates the Procmon app icon as SVG: an iridescent disc with one outer
// sector pulled out like an exploded pie chart (disk usage, at a glance).
//
// SVG has no conic gradients, so the holographic sheen is built from thin
// wedges whose colours are computed here.
//
// Usage: node scripts/icon/generate.mjs > assets/icon/procmon.svg

const SIZE = 1024;
const C = SIZE / 2;

const DISC = 300; // outer radius
const BAND = 188; // inner radius of the data band the sector is cut from
const CLEAR = 104; // clear plastic ring around the hub
const HUB = 70; // metal hub ring
const HOLE = 32; // spindle hole

// The pulled-out sector, in degrees clockwise from 12 o'clock.
const SECTOR = { from: 28, to: 82, offset: 30 };

const PALETTE = ['#7c86e8', '#4fc3e8', '#48d1a8', '#f4d35e', '#ff8fab', '#b07cf0', '#7c86e8'];
const SILVER = [188, 194, 222];

const f = (n) => Number(n.toFixed(2));

function polar(r, deg) {
  const a = ((deg - 90) * Math.PI) / 180;
  return [C + r * Math.cos(a), C + r * Math.sin(a)];
}

function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function mix(a, b, t) {
  return a.map((v, i) => v + (b[i] - v) * t);
}

function paletteAt(t) {
  const x = (((t % 1) + 1) % 1) * (PALETTE.length - 1);
  const i = Math.floor(x);
  return mix(hexToRgb(PALETTE[i]), hexToRgb(PALETTE[i + 1]), x - i);
}

const rgb = ([r, g, b]) => `rgb(${Math.round(r)},${Math.round(g)},${Math.round(b)})`;

/** Annular wedge from r0 to r1 between two angles, optionally shifted. */
function wedge(r0, r1, a0, a1, [dx, dy] = [0, 0]) {
  const large = a1 - a0 > 180 ? 1 : 0;
  const p = (r, a) => polar(r, a).map((v, i) => f(v + (i === 0 ? dx : dy)));
  const [x0, y0] = p(r1, a0);
  const [x1, y1] = p(r1, a1);
  const [x2, y2] = p(r0, a1);
  const [x3, y3] = p(r0, a0);
  return `M${x0} ${y0}A${r1} ${r1} 0 ${large} 1 ${x1} ${y1}L${x2} ${y2}A${r0} ${r0} 0 ${large} 0 ${x3} ${y3}Z`;
}

/**
 * Colour of the holographic sheen at an angle: a silvery base with two
 * opposite rainbow fans (how light splits on a DVD) and a soft glint.
 */
function sheen(deg) {
  const fan = Math.abs(Math.cos(((deg - 40) * Math.PI) / 180)) ** 1.4;
  const rainbow = paletteAt(deg / 120);
  const glint = Math.max(0, Math.cos(((deg - 320) * Math.PI) / 60)) ** 6;
  const base = mix(SILVER, rainbow, 0.3 + 0.7 * fan);
  return mix(base, [255, 255, 255], 0.5 * glint);
}

const STEPS = 180;
const wedges = [];
for (let i = 0; i < STEPS; i++) {
  const a0 = (i * 360) / STEPS;
  const a1 = ((i + 1) * 360) / STEPS + 0.35; // overlap hides seams
  wedges.push(`<path d="${wedge(CLEAR, DISC, a0, a1)}" fill="${rgb(sheen(a0))}"/>`);
}

const grooves = [];
for (let r = CLEAR + 10; r < DISC - 4; r += 7) {
  const strong = Math.abs(r - BAND) < 4;
  grooves.push(
    `<circle cx="${C}" cy="${C}" r="${r}" fill="none" stroke="#fff" stroke-opacity="${strong ? 0.2 : 0.055}" stroke-width="${strong ? 2 : 1.2}"/>`,
  );
}

const mid = (SECTOR.from + SECTOR.to) / 2;
const shift = polar(SECTOR.offset, mid).map((v) => v - C);
const sectorPath = wedge(BAND, DISC, SECTOR.from, SECTOR.to, shift);
const gapPath = wedge(BAND - 1, DISC + 2, SECTOR.from - 1.2, SECTOR.to + 1.2);

const [gx0, gy0] = polar(DISC, SECTOR.from).map((v, i) => v + shift[i]);
const [gx1, gy1] = polar(BAND, SECTOR.to).map((v, i) => v + shift[i]);

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#2d3150"/>
      <stop offset="1" stop-color="#12131f"/>
    </linearGradient>
    <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.07"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="aura" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#6e7bf2" stop-opacity="0.5"/>
      <stop offset="1" stop-color="#6e7bf2" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="depth" cx="${C}" cy="${C}" r="${DISC}" gradientUnits="userSpaceOnUse">
      <stop offset="${f(CLEAR / DISC)}" stop-color="#000" stop-opacity="0.35"/>
      <stop offset="0.55" stop-color="#000" stop-opacity="0"/>
      <stop offset="0.93" stop-color="#000" stop-opacity="0.05"/>
      <stop offset="1" stop-color="#000" stop-opacity="0.4"/>
    </radialGradient>
    <linearGradient id="gloss" x1="0.15" y1="0.1" x2="0.85" y2="0.9">
      <stop offset="0" stop-color="#fff" stop-opacity="0.28"/>
      <stop offset="0.42" stop-color="#fff" stop-opacity="0.04"/>
      <stop offset="0.58" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="clear" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#3a3f63" stop-opacity="0.95"/>
      <stop offset="1" stop-color="#1a1c2d" stop-opacity="0.95"/>
    </linearGradient>
    <linearGradient id="metal" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f4f5fb"/>
      <stop offset="0.5" stop-color="#a9aec6"/>
      <stop offset="1" stop-color="#e3e5f0"/>
    </linearGradient>
    <linearGradient id="sector" x1="${f(gx0)}" y1="${f(gy0)}" x2="${f(gx1)}" y2="${f(gy1)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#a7afff"/>
      <stop offset="0.55" stop-color="#6e7bf2"/>
      <stop offset="1" stop-color="#4a4fc4"/>
    </linearGradient>
    <mask id="cut">
      <rect width="${SIZE}" height="${SIZE}" fill="#fff"/>
      <path d="${gapPath}" fill="#000"/>
    </mask>
    <filter id="tileShadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="0.35"/>
    </filter>
    <filter id="discShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#05060d" flood-opacity="0.55"/>
    </filter>
    <filter id="glow" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="14" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <clipPath id="tileClip">
      <rect x="100" y="100" width="824" height="824" rx="186"/>
    </clipPath>
  </defs>

  <rect x="100" y="100" width="824" height="824" rx="186" fill="url(#tile)" filter="url(#tileShadow)"/>
  <g clip-path="url(#tileClip)">
    <circle cx="${C}" cy="${C}" r="420" fill="url(#aura)"/>
    <rect x="100" y="100" width="824" height="824" fill="url(#sky)"/>
  </g>

  <g filter="url(#discShadow)">
    <g mask="url(#cut)">
      ${wedges.join('\n      ')}
      <circle cx="${C}" cy="${C}" r="${DISC}" fill="url(#depth)"/>
      ${grooves.join('\n      ')}
      <circle cx="${C}" cy="${C}" r="${DISC}" fill="url(#gloss)"/>
      <circle cx="${C}" cy="${C}" r="${DISC - 2}" fill="none" stroke="#fff" stroke-opacity="0.35" stroke-width="3"/>
    </g>
    <circle cx="${C}" cy="${C}" r="${CLEAR}" fill="url(#clear)" stroke="#fff" stroke-opacity="0.18" stroke-width="2"/>
    <circle cx="${C}" cy="${C}" r="${HUB}" fill="url(#metal)"/>
    <circle cx="${C}" cy="${C}" r="${HUB - 16}" fill="none" stroke="#8b90aa" stroke-opacity="0.5" stroke-width="2"/>
    <circle cx="${C}" cy="${C}" r="${HOLE}" fill="#141522"/>
    <circle cx="${C}" cy="${C}" r="${HOLE}" fill="none" stroke="#000" stroke-opacity="0.5" stroke-width="4"/>
  </g>

  <g filter="url(#glow)">
    <path d="${sectorPath}" fill="url(#sector)"/>
  </g>
  <path d="${sectorPath}" fill="none" stroke="#fff" stroke-opacity="0.55" stroke-width="3" stroke-linejoin="round"/>
  <path d="${wedge(BAND + 26, BAND + 30, SECTOR.from + 6, SECTOR.to - 6, shift)}" fill="#fff" fill-opacity="0.35"/>
  <path d="${wedge(BAND + 52, BAND + 56, SECTOR.from + 9, SECTOR.to - 9, shift)}" fill="#fff" fill-opacity="0.25"/>
</svg>
`;

process.stdout.write(svg);
