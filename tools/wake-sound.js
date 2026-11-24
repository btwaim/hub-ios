// Erzeugt den Hub-Weckton: sanftes Glockenspiel (Pentatonik), wird in der ersten Minute von sehr leise bis laut,
// danach bleibt er laut. 5 Minuten lang (AlarmKit spielt eigene Töne teils nur einmal ab).
// Aufruf: node tools/wake-sound.js <ausgabe.wav>  → danach mit ffmpeg nach .caf (IMA4) wandeln
const fs = require('fs');
const out = process.argv[2] || 'hub-wake.wav';
const SR = 22050, SECONDS = 300, N = SR * SECONDS;
const buf = new Float32Array(N);

const freq = n => 440 * Math.pow(2, (n - 69) / 12);
// Melodie (MIDI-Noten), C-Dur-Pentatonik, leicht variierend je Durchgang
const phrases = [
  [72, 76, 79, 81, 79, 76, 74, 79],
  [72, 74, 76, 79, 81, 84, 81, 79],
  [76, 79, 81, 84, 81, 79, 76, 74],
  [72, 76, 79, 76, 74, 72, 74, 79],
];
const STEP = 0.36;                      // Sekunden pro Note
const PHRASE = 8 * STEP + 0.72;         // Pause nach jeder Phrase
function bell(t0, midi, amp) {
  const f = freq(midi), start = Math.floor(t0 * SR), len = Math.floor(2.2 * SR);
  for (let i = 0; i < len && start + i < N; i++) {
    const t = i / SR;
    const env = Math.min(1, t / 0.004) * Math.exp(-t * 2.6);
    const s = Math.sin(2 * Math.PI * f * t) * 0.62
      + Math.sin(2 * Math.PI * f * 2.0 * t) * 0.22 * Math.exp(-t * 3.5)
      + Math.sin(2 * Math.PI * f * 3.01 * t) * 0.09 * Math.exp(-t * 6)
      + Math.sin(2 * Math.PI * f * 0.5 * t) * 0.10;
    buf[start + i] += s * env * amp;
  }
}
let t = 0.2, k = 0;
while (t < SECONDS - 3) {
  const p = phrases[k % phrases.length];
  p.forEach((m, i) => bell(t + i * STEP, m, i === 0 ? 0.55 : 0.42));
  // tiefer Grundton zu jeder Phrase (weich)
  bell(t, p[0] - 24, 0.25);
  t += PHRASE;
  k++;
}
// Lautstärke-Verlauf: 0–60 s von ~4 % auf 100 % (wahrgenommen gleichmäßig), danach voll
let peak = 0;
for (let i = 0; i < N; i++) peak = Math.max(peak, Math.abs(buf[i]));
const data = Buffer.alloc(N * 2);
for (let i = 0; i < N; i++) {
  const sec = i / SR;
  const r = Math.min(1, sec / 60);
  const gain = 0.04 + 0.96 * Math.pow(r, 2.2);
  const fadeOut = Math.min(1, (SECONDS - sec) / 1.5);
  const v = Math.max(-1, Math.min(1, buf[i] / peak * 0.95 * gain * fadeOut));
  data.writeInt16LE(Math.round(v * 32767), i * 2);
}
const h = Buffer.alloc(44);
h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
h.writeUInt32LE(SR, 24); h.writeUInt32LE(SR * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
h.write('data', 36); h.writeUInt32LE(data.length, 40);
fs.writeFileSync(out, Buffer.concat([h, data]));
console.log('ok', out, (data.length / 1e6).toFixed(1) + ' MB');
