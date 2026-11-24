// Hub-Weckton nach Studienlage:
// - melodisch statt monoton (McFarlane et al. 2020: weniger Aussetzer/Fehlstarts nach melodischem Weckton),
//   Tempo 105 BPM, Vibraphon-Klang, Melodie im Bereich ~1,3–2,6 kHz, ansteigende Linie
// - tiefer Anteil um 520 Hz, der aus tiefem Schlaf am zuverlässigsten weckt (Bruck et al.), erst in der lauten Phase
// - langsam lauter + dichter über mehrere Minuten (SoundRise 2026: 5-Min-Anstieg → bessere Laune, nicht später wach)
//
// Zwei Fassungen:
//   hub-wake.caf       mit 3 Min. Vorlauf: startet 3 Min. vor der Weckzeit fast unhörbar, ist zur Weckzeit laut
//   hub-wake-kurz.caf  ohne Vorlauf: 45 s von leise auf laut
// Aufruf: node tools/wake-sound.js <ordner-für-wav>
const fs = require('fs');
const path = require('path');
const dir = process.argv[2] || '.';
const SR = 22050;
const BPM = 105, BEAT = 60 / BPM, EIGHTH = BEAT / 2, BAR = 4 * BEAT;

const hz = m => 440 * Math.pow(2, (m - 69) / 12);
// Zwei-Takt-Motive (Achtel), C-Dur-Pentatonik C6–E7, Linie steigt zum Ende hin; null = Pause
const MOTIFS = [
  [84, null, 88, 91, 93, null, 91, 96, 93, 91, 88, null, 91, 93, 96, null],
  [88, null, 91, 93, 96, 98, null, 96, 93, null, 96, 98, 100, null, 98, null],
  [84, 86, 88, null, 91, null, 93, 96, 98, 96, 93, null, 96, null, 100, null],
  [96, null, 93, 91, 88, null, 91, 93, 96, 98, null, 100, 98, 96, null, null],
];

function render(seconds, gainAt, densityAt) {
  const N = Math.floor(SR * seconds), buf = new Float32Array(N);
  const add = (t0, len, fn) => {
    const s = Math.floor(t0 * SR), n = Math.floor(len * SR);
    for (let i = 0; i < n && s + i < N; i++) if (s + i >= 0) buf[s + i] += fn(i / SR);
  };
  // Vibraphon: Grundton + typischer 4. Teilton, Motor-Tremolo ~5,5 Hz, weicher Ausklang
  const vibe = (t0, m, amp) => {
    const f = hz(m);
    add(t0, 2.4, t => {
      const env = Math.min(1, t / 0.003) * Math.exp(-t * 1.7);
      const trem = 1 - 0.18 * (0.5 + 0.5 * Math.sin(2 * Math.PI * 5.5 * t));
      return amp * env * trem * (Math.sin(2 * Math.PI * f * t) * 0.78 + Math.sin(2 * Math.PI * f * 4 * t) * 0.16 * Math.exp(-t * 6) + Math.sin(2 * Math.PI * f * 2 * t) * 0.06);
    });
  };
  // tiefer, runder Puls um 523 Hz (C5) – der „Aufwach-Anteil“
  const low = (t0, amp) => add(t0, 1.2, t => amp * Math.min(1, t / 0.01) * Math.exp(-t * 3) * (Math.sin(2 * Math.PI * 523.25 * t) * 0.8 + Math.sin(2 * Math.PI * 1046.5 * t) * 0.2));
  // Holzblock (D6) als Takt
  const wood = (t0, amp) => add(t0, 0.08, t => amp * Math.exp(-t * 70) * (Math.sin(2 * Math.PI * 1174.7 * t) + 0.5 * Math.sin(2 * Math.PI * 2349 * t)));

  let bar = 0;
  for (let t = 0.3; t < seconds - 3; t += BAR, bar++) {
    const d = densityAt(t);                    // 0 = spärlich, 1 = normal, 2 = voll
    const motif = MOTIFS[Math.floor(bar / 2) % MOTIFS.length];
    const half = (bar % 2) * 8;
    const playMelody = d >= 1 || bar % 2 === 0;
    if (playMelody) {
      for (let i = 0; i < 8; i++) {
        const m = motif[half + i];
        if (m == null) continue;
        vibe(t + i * EIGHTH, m, i === 0 ? 0.5 : 0.4);
        if (d >= 2) vibe(t + i * EIGHTH, m - 12, 0.22);     // Oktave tiefer → mehr Körper in der lauten Phase
      }
    }
    if (d >= 2) {
      low(t, 0.55); low(t + 2 * BEAT, 0.4);
      for (let b = 0; b < 4; b += 2) wood(t + b * BEAT, 0.18);
    }
  }
  // normieren (auf die volle Phase), dann Lautstärkeverlauf
  let peak = 0;
  for (let i = 0; i < N; i++) peak = Math.max(peak, Math.abs(buf[i]));
  const out = Buffer.alloc(N * 2);
  for (let i = 0; i < N; i++) {
    const sec = i / SR, fade = Math.min(1, (seconds - sec) / 1.5);
    const v = Math.max(-1, Math.min(1, buf[i] / peak * 0.95 * gainAt(sec) * fade));
    out.writeInt16LE(Math.round(v * 32767), i * 2);
  }
  return out;
}

function wav(file, data) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(SR, 24); h.writeUInt32LE(SR * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  fs.writeFileSync(file, Buffer.concat([h, data]));
}

const ease = (a, b, x, p = 1.6) => a + (b - a) * Math.pow(Math.min(1, Math.max(0, x)), p);

// Mit Vorlauf: 0–180 s (vor der Weckzeit) 3 % → 55 %, spärlich → normal; ab 180 s (Weckzeit) dicht, bis 220 s auf 100 %
wav(path.join(dir, 'hub-wake.wav'), render(360,
  s => s < 180 ? ease(0.03, 0.55, s / 180) : ease(0.55, 1, (s - 180) / 40, 1),
  s => s < 100 ? 0 : s < 180 ? 1 : 2));
// Ohne Vorlauf: 45 s von 6 % auf 100 %, nach 20 s volle Dichte
wav(path.join(dir, 'hub-wake-kurz.wav'), render(240,
  s => ease(0.06, 1, s / 45),
  s => s < 8 ? 1 : 2));
console.log('ok');
