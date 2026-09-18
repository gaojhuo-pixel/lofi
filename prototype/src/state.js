// App state + persistence. Tiny by design: one object, a listener set.

const KEY = "lofiglass.v1";

export const state = {
  // deck
  queue: [], // what the fingers can touch right now
  idx: 0,
  history: [], // rewound discs
  pool: [], // candidate pool the hunt pulls from
  poolPos: 0,
  rejectedPool: [], // real non-lofi results, for "thrown out" proof
  gate: { accepted: 0, rejected: 0, lastRejected: [] },

  // cache
  details: {}, // videoId → pulled description/tags/chapters
  comments: {}, // videoId → { origin, items }
  crate: [],

  // transport
  playing: false,
  busy: false,
  time: 0,
  duration: 0,
  autoplay: true,
  volume: 70,

  // config
  source: "seed", // seed | piped
  mode: "deck", // deck | endless radio
  playerKind: "youtube", // youtube | synth
  mood: "",
  crt: true,
  refract: true,

  // the VLC-style gain panel
  boost: { db: 0, low: 0, mid: 0, high: 0, limiter: true, softClip: true, out: 0.85, preset: "FLAT" },
};

const listeners = new Set();
export const on = (fn) => {
  listeners.add(fn);
  return () => listeners.delete(fn);
};
export function emit(what) {
  listeners.forEach((fn) => {
    try {
      fn(what, state);
    } catch (err) {
      console.error(err);
    }
  });
}

export const current = () => state.queue[state.idx] || null;

export function persist() {
  try {
    localStorage.setItem(
      KEY,
      JSON.stringify({
        crate: state.crate,
        boost: state.boost,
        playerKind: state.playerKind,
        source: state.source,
        mode: state.mode,
        volume: state.volume,
        crt: state.crt,
        refract: state.refract,
      })
    );
  } catch {}
}

export function restore() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return;
    const saved = JSON.parse(raw) || {};
    if (Array.isArray(saved.crate)) state.crate = saved.crate;
    if (saved.boost) Object.assign(state.boost, saved.boost);
    for (const k of ["playerKind", "source", "mode", "volume", "crt", "refract"]) if (saved[k] !== undefined) state[k] = saved[k];
  } catch {}
}

export const inCrate = (videoId) => state.crate.some((t) => t.videoId === videoId);

export function toggleCrate(track) {
  const i = state.crate.findIndex((t) => t.videoId === track.videoId);
  if (i >= 0) state.crate.splice(i, 1);
  else state.crate.unshift({ ...track, comments: [], tracklist: track.tracklist || [] });
  persist();
  emit("crate");
  return i < 0;
}

export function applyBoost(patch) {
  Object.assign(state.boost, patch);
  persist();
  emit("boost");
  return state.boost;
}
