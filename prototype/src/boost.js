// ---------------------------------------------------------------------------
// boost.js — "ability to boost the audio like on vlc windows"
//
// VLC's Windows slider does two things people actually want: it rides the
// system volume 0–100%, and then it keeps going to +12.5 dB of digital
// pre-gain, with a volume-maximum (limiter) switch to stop it turning into
// fuzz. That's exactly this chain:
//
//   source → trim → lowShelf → peak → highShelf → boost → limiter → softclip → out → analyser
//
// On device the identical graph is AVAudioEngine + AVAudioUnitEQ ×3 + a
// booster mixer node + a DynamicsCompressor limiter
// (ios/LofiGlass/Audio/AudioBoostEngine.swift).
//
// The browser can only route audio it owns, so `player: "synth"` runs this
// graph on a generated lofi loop; with the YouTube IFrame player the same dB
// value is mapped onto setVolume() and the boost half is reported as armed.
// ---------------------------------------------------------------------------

import { clamp, dbToLinear, log } from "./util.js";

export const BOOST_MIN_DB = -12;
export const BOOST_MAX_DB = 12; // +12 dB ≈ 4× amplitude, VLC-style headroom

export class BoostEngine {
  constructor() {
    this.ctx = null;
    this.preset = "FLAT";
    this.state = {
      db: 0,
      low: 0,
      mid: 0,
      high: 0,
      limiter: true,
      out: 0.85,
      softClip: true,
    };
    this.input = null;
    this.analyser = null;
    this.buf = null;
    this.bound = new Set(); // sources already wired in
  }

  ensure() {
    if (this.ctx) return this.ctx;
    const C = window.AudioContext || window.webkitAudioContext;
    this.ctx = new C({ latencyHint: "interactive" });
    const s = this.state;

    // pre trim (keeps things sane when a source is already hot)
    this.trim = this.ctx.createGain();
    this.trim.gain.value = 1;

    this.lowShelf = this.mkEQ("lowshelf", 130, s.low, 0.8);
    this.mid = this.mkEQ("peaking", 900, s.mid, 0.9);
    this.highShelf = this.mkEQ("highshelf", 3600, s.high, 0.7);

    // the boost stage — the VLC slider. 0 dB = 1.0
    this.boost = this.ctx.createGain();
    this.boost.gain.value = 1;

    // limiter: hard-ish ceiling so +12 dB doesn't clip into square-wave mush
    this.limiter = this.ctx.createDynamicsCompressor();
    this.setLimiterThreshold(-6);
    this.limiter.knee.value = 3;
    this.limiter.ratio.value = 16;
    this.limiter.attack.value = 0.003;
    this.limiter.release.value = 0.14;

    // soft clipper as an optional extra guard (WaveShaper)
    this.shaper = this.ctx.createWaveShaper();
    this.shaper.curve = this.makeSoftClipCurve(1.6);
    this.shaperBypass = this.ctx.createGain();

    this.out = this.ctx.createGain();
    this.out.gain.value = s.out;

    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 1024;
    this.analyser.smoothingTimeConstant = 0.72;
    this.buf = new Float32Array(this.analyser.fftSize);

    this.input = this.ctx.createGain();

    // graph: input → trim → eq3 → boost → (limiter|shaper) → out → analyser → speakers
    this.input.connect(this.trim);
    this.trim.connect(this.lowShelf);
    this.lowShelf.connect(this.mid);
    this.mid.connect(this.highShelf);
    this.highShelf.connect(this.boost);
    this.boost.connect(this.limiter);
    this.limiter.connect(this.shaper);
    this.shaper.connect(this.out);
    this.out.connect(this.analyser);
    this.analyser.connect(this.ctx.destination);

    this.apply(true);
    log(`boost engine online · ${this.ctx.sampleRate} Hz · ${BOOST_MIN_DB}…+${BOOST_MAX_DB} dB`, "ok");
    return this.ctx;
  }

  mkEQ(type, freq, gain, q) {
    const n = this.ctx.createBiquadFilter();
    n.type = type;
    n.frequency.value = freq;
    n.gain.value = gain;
    if (type === "peaking") n.Q.value = q;
    return n;
  }

  setLimiterThreshold(db) {
    if (!this.limiter) return;
    // DynamicsCompressor threshold only goes to 0 dB; scale the ceiling so the
    // more boost you ask for, the harder it clamps.
    this.limiter.threshold.value = clamp(db, -60, 0);
  }

  makeSoftClipCurve(amount = 1) {
    const n = 2048;
    const curve = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const x = (i / (n - 1)) * 2 - 1;
      curve[i] = Math.tanh(x * amount) / Math.tanh(amount);
    }
    return curve;
  }

  /** @param {Partial<BoostEngine['state']>} patch */
  update(patch, immediate = false) {
    Object.assign(this.state, patch);
    if (patch.preset) {
      this.preset = patch.preset;
      Object.assign(this.state, PRESETS[patch.preset] || {});
    }
    this.apply(immediate);
    return this.state;
  }

  apply(immediate = false) {
    if (!this.ctx) return;
    const s = this.state;
    const t = this.ctx.currentTime;
    const ramp = (param, value) => (immediate ? (param.value = value) : param.setTargetAtTime(value, t, 0.02));

    ramp(this.boost.gain, dbToLinear(clamp(s.db, BOOST_MIN_DB, BOOST_MAX_DB)));
    ramp(this.lowShelf.gain, s.low);
    ramp(this.mid.gain, s.mid);
    ramp(this.highShelf.gain, s.high);
    ramp(this.out.gain, s.out);

    // bypass the limiter by giving it a huge threshold and unity ratio
    if (s.limiter) {
      this.setLimiterThreshold(clamp(-6 + Math.min(0, s.db / 2), -24, 0));
      this.limiter.ratio.value = 16;
    } else {
      this.limiter.threshold.value = 0;
      this.limiter.ratio.value = 1;
    }
    // shaper bypass
    this.shaper.curve = s.softClip ? this.makeSoftClipCurve(clamp(1.5 - s.db / 24, 0.8, 2.4)) : new Float32Array(0);
    if (s.db > 6 && !s.limiter) log("boost past +6 dB with the limiter OFF — this will clip", "warn");
  }

  /** Connect a Web Audio node (synth, MediaStreamSource, …). */
  attach(node) {
    this.ensure();
    if (this.bound.has(node)) return;
    node.connect(this.input);
    this.bound.add(node);
  }

  detach(node) {
    try {
      node.disconnect(this.input);
    } catch {}
    this.bound.delete(node);
  }

  /** Map the dB request onto a player that only exposes 0–100 volume. */
  volumeForPlayer(db) {
    // −12 dB → 22, 0 dB → 70 (a comfortable listening level for a mix), +12 dB → 100
    const t = clamp((db - BOOST_MIN_DB) / (BOOST_MAX_DB - BOOST_MIN_DB), 0, 1);
    return Math.round(22 + t * 78);
  }

  /** level meter + gain-reduction readout */
  meter() {
    if (!this.analyser) return { rms: -Infinity, peak: -Infinity, reduction: 0, clipping: false };
    this.analyser.getFloatTimeDomainData(this.buf);
    let sum = 0;
    let peak = 0;
    for (let i = 0; i < this.buf.length; i++) {
      const v = this.buf[i];
      sum += v * v;
      if (Math.abs(v) > peak) peak = Math.abs(v);
    }
    const rms = Math.sqrt(sum / this.buf.length);
    const toDb = (x) => (x <= 1e-6 ? -Infinity : 20 * Math.log10(x));
    return {
      rms: toDb(rms),
      peak: toDb(peak),
      reduction: this.limiter ? this.limiter.reduction : 0,
      clipping: peak > 0.985,
    };
  }

  resume() {
    this.ensure();
    if (this.ctx.state === "suspended") this.ctx.resume();
  }
  suspend() {
    if (this.ctx && this.ctx.state === "running") this.ctx.suspend();
  }
}

export const PRESETS = {
  FLAT: { low: 0, mid: 0, high: 0, limiter: true },
  TAPE_WARM: { low: 2.5, mid: 1, high: -2.5, limiter: true },
  RAIN_SHELF: { low: -1.5, mid: 0, high: 3.5, limiter: true },
  BASS_HEAD: { low: 6, mid: -1, high: 1, limiter: true },
  VOICE_POD: { low: -3, mid: 4, high: 2, limiter: true },
  CLUB: { low: 3, mid: 0, high: 3, limiter: true },
  "3AM": { low: 1.5, mid: -2, high: -1, limiter: false },
};

export const PRESET_LABELS = {
  FLAT: "flat",
  TAPE_WARM: "tape warm",
  RAIN_SHELF: "rain shelf",
  BASS_HEAD: "bass head",
  VOICE_POD: "voice/pod",
  CLUB: "club (+12)",
  "3AM": "3am no-limiter",
};

/* =========================================================================
 * A tiny procedural lofi loop. This is the auditable source for the boost
 * chain in the browser (YouTube IFrame audio is not routable).
 * BPM 76, Rhodes-ish 7th/9th chords, dusty drums, crackle.
 * ========================================================================= */

const CHORDS = [
  { root: 55, steps: [0, 3, 7, 10, 14] }, // Fm9
  { root: 53, steps: [0, 4, 7, 11, 14] }, // Fmaj9 (a third below-ish, keeps it mellow)
  { root: 48, steps: [0, 3, 7, 10, 12] }, // C minor 9
  { root: 50, steps: [0, 4, 7, 10, 14] }, // D dom9
];

export class LofiSynth {
  /** @param {BoostEngine} engine */
  constructor(engine) {
    this.engine = engine;
    this.playing = false;
    this.tempo = 76;
    this.step = 0;
    this.bar = 0;
    this.nextTime = 0;
    this.timer = null;
    this.startedAt = 0;
  }

  ensure() {
    const ctx = this.engine.ensure();
    if (this.bus) return ctx;
    this.bus = ctx.createGain();
    this.bus.gain.value = 0.9;
    // gentle master lowpass = "everything behind a blanket"
    this.tone = ctx.createBiquadFilter();
    this.tone.type = "lowpass";
    this.tone.frequency.value = 5200;
    this.tone.Q.value = 0.4;
    this.bus.connect(this.tone);
    this.engine.attach(this.tone);

    this.makeNoise();
    this.startVinyl();
    this.wobble = ctx.createOscillator();
    this.wobble.frequency.value = 4.6; // tape flutter rate
    this.wobbleGain = ctx.createGain();
    this.wobbleGain.gain.value = 5.5; // cents
    this.wobble.connect(this.wobbleGain);
    this.wobble.start();
    return ctx;
  }

  makeNoise() {
    const ctx = this.engine.ctx;
    const len = ctx.sampleRate * 2;
    this.noise = ctx.createBuffer(1, len, ctx.sampleRate);
    const d = this.noise.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
  }

  startVinyl() {
    const ctx = this.engine.ctx;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    src.loop = true;
    const hp = ctx.createBiquadFilter();
    hp.type = "highpass";
    hp.frequency.value = 1800;
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.value = 7200;
    const g = ctx.createGain();
    g.gain.value = 0.018; // hiss floor
    src.connect(hp).connect(lp).connect(g).connect(this.bus);
    src.start();
    this.vinylGain = g;

    // occasional pops
    const pops = () => {
      if (!this.playing) return;
      const t = ctx.currentTime;
      const o = ctx.createOscillator();
      const pg = ctx.createGain();
      o.type = "square";
      o.frequency.value = 1200 + Math.random() * 2400;
      pg.gain.setValueAtTime(0.0001, t);
      pg.gain.exponentialRampToValueAtTime(0.05 + Math.random() * 0.05, t + 0.002);
      pg.gain.exponentialRampToValueAtTime(0.0001, t + 0.03);
      o.connect(pg).connect(this.bus);
      o.start(t);
      o.stop(t + 0.05);
      this.popTimer = setTimeout(pops, 380 + Math.random() * 2200);
    };
    pops();
  }

  note(freq, t, dur, { gain = 0.1, type = "triangle", detune = 0, cutoff = 2600, q = 0.8 } = {}) {
    const ctx = this.engine.ctx;
    const o = ctx.createOscillator();
    o.type = type;
    o.frequency.setValueAtTime(freq, t);
    o.detune.value = detune;
    if (this.wobbleGain) this.wobbleGain.connect(o.detune);
    const f = ctx.createBiquadFilter();
    f.type = "lowpass";
    f.frequency.setValueAtTime(cutoff, t);
    f.frequency.exponentialRampToValueAtTime(Math.max(320, cutoff * 0.42), t + dur);
    f.Q.value = q;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + 0.03);
    g.gain.setValueAtTime(gain, t + dur * 0.55);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(f).connect(g).connect(this.bus);
    o.start(t);
    o.stop(t + dur + 0.05);
  }

  kick(t) {
    const ctx = this.engine.ctx;
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.frequency.setValueAtTime(132, t);
    o.frequency.exponentialRampToValueAtTime(44, t + 0.14);
    g.gain.setValueAtTime(0.42, t);
    g.gain.exponentialRampToValueAtTime(0.0008, t + 0.24);
    o.connect(g).connect(this.bus);
    o.start(t);
    o.stop(t + 0.3);
  }

  snare(t, level = 0.2) {
    const ctx = this.engine.ctx;
    const s = ctx.createBufferSource();
    s.buffer = this.noise;
    s.playbackRate.value = 0.9 + Math.random() * 0.2;
    const bp = ctx.createBiquadFilter();
    bp.type = "bandpass";
    bp.frequency.value = 1750;
    bp.Q.value = 0.8;
    const g = ctx.createGain();
    g.gain.setValueAtTime(level, t);
    g.gain.exponentialRampToValueAtTime(0.0008, t + 0.18);
    s.connect(bp).connect(g).connect(this.bus);
    s.start(t, Math.random());
    s.stop(t + 0.2);
  }

  hat(t, level = 0.05) {
    const ctx = this.engine.ctx;
    const s = ctx.createBufferSource();
    s.buffer = this.noise;
    s.playbackRate.value = 1.7;
    const hp = ctx.createBiquadFilter();
    hp.type = "highpass";
    hp.frequency.value = 7600;
    const g = ctx.createGain();
    g.gain.setValueAtTime(level, t);
    g.gain.exponentialRampToValueAtTime(0.0006, t + 0.05);
    s.connect(hp).connect(g).connect(this.bus);
    s.start(t, Math.random());
    s.stop(t + 0.08);
  }

  mtof(m) {
    return 440 * Math.pow(2, (m - 69) / 12);
  }

  start() {
    const ctx = this.ensure();
    this.engine.resume();
    if (this.playing) return;
    this.playing = true;
    this.step = 0;
    this.bar = 0;
    this.nextTime = ctx.currentTime + 0.08;
    this.startedAt = ctx.currentTime;
    this.timer = setInterval(() => this.schedule(), 25);
  }

  stop() {
    this.playing = false;
    clearInterval(this.timer);
    clearTimeout(this.popTimer);
    this.timer = null;
  }

  /** seconds into the loop, for the disc + scrub UI */
  position() {
    if (!this.engine.ctx || !this.playing) return this.offset || 0;
    return (this.offset || 0) + (this.engine.ctx.currentTime - this.startedAt);
  }
  seek(sec) {
    this.offset = sec;
  }

  schedule() {
    if (!this.playing) return;
    const ctx = this.engine.ctx;
    const spb = 60 / this.tempo / 4; // one 16th
    while (this.nextTime < ctx.currentTime + 0.25) {
      this.tick(this.step, this.bar, this.nextTime, spb);
      this.nextTime += spb;
      this.step++;
      if (this.step >= 16) {
        this.step = 0;
        this.bar = (this.bar + 1) % CHORDS.length;
      }
    }
  }

  tick(step, bar, t, spb) {
    const chord = CHORDS[bar];
    // pad: chord swells on bar down, last note sustains
    if (step === 0) {
      chord.steps.forEach((s, i) => {
        const midi = chord.root + 12 * 2 + s;
        this.note(this.mtof(midi), t, spb * 15.5, {
          gain: 0.075 - i * 0.006,
          type: i % 2 ? "triangle" : "sine",
          detune: (i - 2) * 6,
          cutoff: 1750 + i * 240,
          q: 0.6,
        });
      });
      // bass
      this.note(this.mtof(chord.root + 12), t, spb * 7, { gain: 0.2, type: "sine", cutoff: 420, q: 1.4 });
    }
    // melody: sparse pentatonic-ish taps
    if (step === 6 || step === 11 || step === 14) {
      const pick = [0, 2, 4, 3][Math.floor(Math.random() * 4)];
      const midi = chord.root + 24 + chord.steps[pick] + (Math.random() < 0.3 ? 12 : 0);
      this.note(this.mtof(midi), t, spb * 3.2, { gain: 0.085, type: "triangle", cutoff: 3200, q: 1.1 });
    }
    // drums (lazy half-time, swung)
    if (step === 0 || step === 8 || step === 11) this.kick(t);
    if (step === 4 || step === 12) this.snare(t, 0.19);
    if (step % 2 === 0) this.hat(t, step % 4 === 2 ? 0.055 : 0.03);
    if (step === 7 || step === 15) this.snare(t + spb * 0.5, 0.07);
  }
}
