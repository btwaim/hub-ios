// Baut die Ortsnamen für die GTA-Karte aus den GTADB-Landmarken (CC BY 4.0, https://map.gtadb.org):
// Regionen (weit weg), Stadtteile (näher), Straßen (ganz nah). Position = Median der Gebäude mit diesem Namen.
// Aufruf: node tools/labels.js  → Hub/Resources/leonida-labels.json
const fs = require('fs');
const path = require('path');
const src = path.join(__dirname, '..', 'Hub', 'Resources', 'leonida.json');
const d = JSON.parse(fs.readFileSync(src, 'utf8'));

// große Namen wie auf der Spielkarte
const REGIONS = new Set(['Vice City', 'Port Gellhorn', 'Ambrosia', 'Key Lento', 'Hamlet', 'Mariana County', 'Kelly County',
  'Lummox County', 'Vice-Dale County', 'Leonard County', 'Grassrivers', 'Mount Kalaga', 'Lake Leonida', 'Leonida Keys']);
const SKIP = new Set(['Leonida', '']);
const STREET = /\b(ave|st|dr|blvd|rd|hwy|route|way|ln|ct|pkwy|cswy|causeway|street|avenue|drive|road)\b|^(sw|nw|ne|se|n|s|e|w)\s\d/i;

const groups = new Map();
const add = (name, tier, x, y) => {
  const k = tier + '|' + name;
  if (!groups.has(k)) groups.set(k, { name, tier, xs: [], ys: [] });
  groups.get(k).xs.push(x); groups.get(k).ys.push(y);
};
for (const [, , area, x, y] of d.landmarks) {
  const parts = String(area).split(',').map(s => s.trim()).filter(Boolean);
  parts.forEach((p, i) => {
    if (SKIP.has(p)) return;
    const last = i === parts.length - 1;
    const tier = REGIONS.has(p) ? 1 : STREET.test(p) ? 3 : (last && parts.length === 1 ? 2 : i === parts.length - 1 ? 1.5 : 2);
    add(p, tier === 1.5 ? 2 : tier, x, y);
  });
}
const med = a => { const s = [...a].sort((p, q) => p - q); return s[Math.floor(s.length / 2)]; };
const out = [];
for (const g of groups.values()) {
  if (g.tier === 3 && g.xs.length < 2) continue;             // einzelne Straßen-Treffer sind zu ungenau
  out.push({ n: g.name, t: g.tier, x: Math.round(med(g.xs)), y: Math.round(med(g.ys)), c: g.xs.length });
}
// Gegenden ohne Gebäude-Daten über die Anker (z. B. Grassrivers, Mount Kalaga)
for (const a of d.anchors) {
  const name = String(a[0]).split('↔')[0].split('/')[0].trim();
  if (!out.some(o => o.n === name)) out.push({ n: name, t: REGIONS.has(name) ? 1 : 2, x: Math.round(a[3]), y: Math.round(a[4]), c: 0 });
}
out.sort((a, b) => a.t - b.t || b.c - a.c);
fs.writeFileSync(path.join(__dirname, '..', 'Hub', 'Resources', 'leonida-labels.json'), JSON.stringify({ credit: d.credit, labels: out }));
console.log(out.length, 'Namen', ['1', '2', '3'].map(t => t + ':' + out.filter(o => String(o.t) === t).length).join(' '));
console.log(out.filter(o => o.t === 1).map(o => o.n).join(', '));
