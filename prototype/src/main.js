// ---------------------------------------------------------------------------
// main.js — boot gate, deck, hunt loop, boost routing, meters.
// ---------------------------------------------------------------------------

import { $, $$, el, fmtTime, clamp, log, toast, setLogTarget, sparkles, flash } from "./util.js";
import { state, restore, persist, current, on } from "./state.js";
import { BoostEngine, BOOST_MIN_DB, BOOST_MAX_DB } from "./boost.js";
import { Player } from "./player.js";
import { Deck } from "./deck.js";
import { Sheets, fmtDb } from "./sheets.js";
import { loadSeed, searchLofi, fetchDetails, fetchTopComments, artistAt, parseTracklist } from "./youtube.js";
import { gateTrack } from "./lofi-filter.js";

const engine = new BoostEngine();
const shuffle = (arr) => {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
};

let deck, sheets, player;
const enrichTimers = new Map();
let vizBuf = null;

/* ------------------------------------------------------------------ boot */

async function boot() {
  setLogTarget($("#log"));
  restore();
  sparkles();
  tickClock();
  setInterval(tickClock, 20_000);
  document.body.dataset.crt = state.crt !== false ? "on" : "off";
  document.body.dataset.refract = state.refract !== false ? "on" : "off";

  const seed = await loadSeed();
  // Real non-lofi results, kept so the gate can show what it threw away.
  state.rejectedPool = (seed.excludedExamples || []).map((r) => ({
    ...r,
    thumbnail: `https://i.ytimg.com/vi/${r.videoId}/mqdefault.jpg`,
    gate: gateTrack(r),
    tags: [],
  }));
  state.pool = shuffle(seed.tracks);
  state.poolPos = 0;

  player = new Player({
    onTime: (pos, dur) => onTick(pos, dur),
    onState: (st) => {
      const PLAYING = window.YT?.PlayerState?.PLAYING ?? 1;
      const playing = st === PLAYING;
      deck?.setPlaying(playing);
      $("#btnPlay").textContent = playing ? "⏸" : "⏵";
      $("#unmute").hidden = true;
    },
    onEnded: () => hunt({}),
    onBlocked: async () => {
      log("this video disallows embedding → routing audio through the local source", "warn");
      $("#selPlayer").value = "synth";
      player.setKind("synth");
      state.playerKind = "synth";
      persist();
      const t = current();
      if (t) await player.load(t.videoId, state.time || 0, true);
    },
  });

  engine.update(state.boost, true);

  deck = new Deck($("#deck"), {
    onSwipe: (dir) => (dir > 0 ? hunt({}) : back()),
    onInfo: (t) => sheets.openInfo(t),
    onFlip: (isFlipped) => log(isFlipped ? "disc flipped → sleeve notes" : "disc flipped back"),
  });

  sheets = new Sheets({
    onSeek: (sec) => {
      player.seek(sec);
      state.time = sec;
      onTick(sec, state.duration);
      toast(`seek ${fmtTime(sec)}`);
    },
    onVolume: (v) => {
      state.volume = v;
      persist();
      routeBoost();
    },
    onHunt: async (q, mood) => {
      const res = await hunt({ query: q, mood, fromSearch: true });
      sheets.renderSearchResults(res);
      return res;
    },
    onPick: async (t) => {
      sheets.close();
      state.pool = [t, ...state.pool];
      state.poolPos = 0;
      await hunt({});
      toast(`queued · ${t.title.slice(0, 44)}`);
    },
  });

  await player.mount($("#ytStage"), engine);
  player.setKind(state.playerKind);
  $("#selPlayer").value = state.playerKind;
  $("#selSource").value = state.source;
  $("#selMode").value = state.mode;
  $("#srcDot").dataset.src = state.source;

  wireUI();
  on((what) => {
    if (what === "boost") routeBoost();
    if (what === "crate" && sheets.open === "crate") sheets.openCrate();
  });

  await selectCurrent(false);
  log(`booted · pool ${state.pool.length} · source ${state.source}`, "ok");
}

/* ------------------------------------------------------------- deck flow */

async function selectCurrent(autoplay) {
  const t = current();
  if (!t) return;
  state.time = 0;
  renderDeck();
  deck.pulse();
  flash();
  await player.load(t.videoId, 0, autoplay);
  routeBoost();
  scheduleEnrich(t);
  toast(t.title.length > 52 ? t.title.slice(0, 52) + "…" : t.title, 2200);
  log(`now spinning · ${t.title} · gate ${t.gate?.score ?? "n/a"}`);
}

function renderDeck() {
  deck.render(state.queue, state.idx);
  const t = current();
  $("#deckHint").hidden = !!t;
  if (t) {
    const c = artistAt(t.tracklist || [], state.time);
    $("#nowText").textContent = `◉ ${c ? `${c.artist}${c.title ? ` — ${c.title}` : ""}` : t.channelName} · ${t.title}`;
  }
}

/** Lazily pull the full description + top comments for the disc in hand. */
function scheduleEnrich(track) {
  clearTimeout(enrichTimers.get(track.videoId));
  enrichTimers.set(
    track.videoId,
    setTimeout(async () => {
      if (state.source !== "piped") return;
      const [det, com] = await Promise.all([
        state.details[track.videoId] ? null : fetchDetails(track.videoId),
        state.comments[track.videoId] ? null : fetchTopComments(track.videoId),
      ]);
      let changed = false;
      if (det) {
        state.details[track.videoId] = det;
        const list = det.chapters?.length
          ? det.chapters.map((c) => ({
              startSeconds: c.startSeconds,
              artist: (c.title || "").split(/\s+[-–—]\s+/)[0] || c.title,
              title: (c.title || "").split(/\s+[-–—]\s+/)[1] || "",
            }))
          : parseTracklist(det.description || "");
        Object.assign(track, {
          description: det.description || track.description,
          tags: det.tags?.length ? [...new Set([...(track.tags || []), ...det.tags])] : track.tags,
          tracklist: list.length ? list : track.tracklist,
          durationSeconds: det.durationSeconds || track.durationSeconds,
          viewCount: det.viewCount || track.viewCount,
        });
        changed = !!list.length;
        log(`enriched ${track.videoId} · ${list.length} credits · ${det.origin}`, "ok");
      }
      if (com?.items?.length) {
        state.comments[track.videoId] = com;
        log(`${com.items.length} live comments on ${track.videoId} · ${com.origin}`, "ok");
        changed = true;
      }
      if (changed) {
        deck.render(state.queue, state.idx);
        if (sheets.open === "info") sheets.openInfo(track, sheets.infoTab);
      }
    }, 700)
  );
}

/* ------------------------------------------------------------- hunt loop */

function takeFromPool() {
  while (state.poolPos < state.pool.length) {
    const cand = state.pool[state.poolPos++];
    if (cand.videoId === current()?.videoId) continue;
    if (cand.gate?.lofi !== false) return cand;
    state.gate.rejected++;
    state.gate.lastRejected = [cand, ...state.gate.lastRejected].slice(0, 8);
  }
  return null;
}

async function hunt({ query = "", mood = "", fromSearch = false } = {}) {
  if (state.busy) return lastHunt;
  state.busy = true;
  showSeeking(true);
  let res = lastHunt;

  try {
    let next = fromSearch ? null : takeFromPool();

    if (!next || query || mood) {
      const seedQueries = (await loadSeed()).querySeeds || ["lofi hip hop"];
      const q = query || (state.mode === "radio" ? seedQueries[Math.floor(Math.random() * seedQueries.length)] : "");
      res = await searchLofi(q, { mood: mood || (query ? "" : state.mood), limit: 24 });
      state.pool = [...res.accepted, ...state.pool].filter((t, i, a) => a.findIndex((x) => x.videoId === t.videoId) === i);
      state.poolPos = 0;
      next = takeFromPool() || res.accepted[0] || null;
    }

    if (!next) {
      toast("no lofi matched — the gate threw them all out");
      return res;
    }

    state.history.push(current());
    state.queue = [next, ...state.queue.slice(state.idx + 1)].slice(0, 60);
    state.idx = 0;
    state.gate.accepted++;
    state.autoplay = state.mode === "radio" ? true : state.autoplay;
    await selectCurrent(state.autoplay !== false);
    return res;
  } finally {
    showSeeking(false);
    state.busy = false;
    if (sheets.open === "search") sheets.renderSearchResults(res);
  }
}

let lastHunt = { accepted: [], rejected: [], origin: "pool", query: "" };

function back() {
  const prev = state.history.pop();
  if (!prev) return toast("this was the first disc");
  state.queue = [prev, ...state.queue].slice(0, 60);
  state.idx = 0;
  selectCurrent(state.autoplay !== false);
  toast("rewound ↺");
}

function showSeeking(on) {
  const holder = $("#deck");
  let node = $(".seeking", holder);
  if (on && !node) {
    node = el("div", { class: "seeking" }, [
      el("div", { class: "seeking__txt" }, "seeking lofi…"),
      el("div", { class: "seeking__bar" }, el("i")),
    ]);
    holder.append(node);
  } else if (!on && node) node.remove();
}

/* ------------------------------------------------------------ boost route */

/**
 * One dB value, two routings:
 *  · synth source  → real gain into the Web Audio chain (audible +12 dB)
 *  · youtube iframe→ setVolume(0–100) + the +dB half reported as armed
 */
function routeBoost() {
  engine.update(state.boost);
  const pct = engine.volumeForPlayer(state.boost.db);
  state.volume = pct;
  const vol = $("#sysVol");
  if (vol) vol.value = pct;
  player?.setVolumePct(pct);
  $("#boostMini").textContent = fmtDb(state.boost.db);
  const dbNode = $("#boostDb");
  if (dbNode) dbNode.textContent = fmtDb(state.boost.db);
  const stateNode = $("#boostState");
  if (stateNode) {
    stateNode.textContent =
      state.boost.db > 0 ? (player?.kind === "synth" ? "boost live" : "boost armed · iframe-capped") : state.boost.db < 0 ? "trimmed" : "unity";
    stateNode.style.color = state.boost.db > 0 ? "var(--lime)" : state.boost.db < 0 ? "var(--cyan)" : "#9aa3d8";
  }
}

/* ------------------------------------------------------------------ tick */

function onTick(pos, dur) {
  state.time = pos || 0;
  state.duration = dur || current()?.durationSeconds || 0;
  $("#timeLabel").textContent = `${fmtTime(state.time)}${state.duration > 1 ? ` / ${fmtTime(state.duration)}` : ""}`;
  const pct = state.duration > 1 ? clamp((state.time / state.duration) * 100, 0, 100) : 0;
  $("#scrubFill").style.width = pct + "%";
  deck?.updateCredit();
  const t = current();
  if (t) {
    const c = artistAt(t.tracklist || [], state.time);
    if (c) $("#nowText").textContent = `◉ now · ${c.artist}${c.title ? ` — ${c.title}` : ""} · via ${t.channelName}${t.license ? ` · ${t.license}` : ""}`;
  }
  updateMeter();
}

function updateMeter() {
  const live = player?.kind === "synth" ? engine.meter() : null;
  const target = live ? clamp(((live.rms ?? -60) + 60) / 60, 0, 1) : clamp((state.boost.db - BOOST_MIN_DB) / (BOOST_MAX_DB - BOOST_MIN_DB), 0, 1);
  $("#meterBar").style.width = (target * 100).toFixed(1) + "%";
  $("#meterDb").textContent = live ? `${(live.rms ?? -60).toFixed(1)} dBFS` : fmtDb(state.boost.db);
  $("#clipLed").classList.toggle("is-on", !!live?.clipping || (state.boost.db > 9 && !state.boost.limiter));
  drawViz(live);
}

function drawViz(meter) {
  const c = $("#boostViz");
  if (!c) return;
  const g = c.getContext("2d");
  const w = c.width;
  const h = c.height;
  g.clearRect(0, 0, w, h);
  const bars = 44;
  const an = engine.analyser;
  if (an) {
    if (!vizBuf || vizBuf.length !== an.frequencyBinCount) vizBuf = new Uint8Array(an.frequencyBinCount);
    an.getByteFrequencyData(vizBuf);
  }
  for (let i = 0; i < bars; i++) {
    const v = an && player?.kind === "synth" ? vizBuf[Math.floor((i / bars) * vizBuf.length * 0.72)] / 255 : 0.04 + (Math.abs(state.boost.db) / 12) * 0.5 * (1 - i / bars) + 0.05 * Math.abs(Math.sin(i / 4));
    const bh = Math.max(2, v * (h - 14));
    const x = (i / bars) * w;
    const grd = g.createLinearGradient(0, h, 0, h - bh);
    grd.addColorStop(0, "#46f8ff");
    grd.addColorStop(0.6, "#ff37d3");
    grd.addColorStop(1, "#ffe9a8");
    g.fillStyle = grd;
    g.fillRect(x + 1, h - bh - 1, w / bars - 2, bh);
  }
  // gain-reduction trace, like VLC's volume-maximum feedback
  if (meter?.reduction) {
    g.fillStyle = "rgba(255,255,255,.8)";
    g.font = "13px VT323, monospace";
    g.fillText(`limiter −${Math.abs(meter.reduction).toFixed(1)} dB`, 8, 14);
  }
  g.strokeStyle = "rgba(255,255,255,.16)";
  g.beginPath();
  g.moveTo(0, h * 0.5);
  g.lineTo(w, h * 0.5);
  g.stroke();
}

/* ---------------------------------------------------------------- ui wire */

function wireUI() {
  $("#unmuteBtn").addEventListener("click", async () => {
    $("#unmute").hidden = true;
    engine.resume();
    state.autoplay = true;
    await selectCurrent(true);
    player.play();
  });

  $("#btnPlay").addEventListener("click", () => player.toggle());
  $("#btnNext").addEventListener("click", () => hunt({}));
  $("#btnPrev").addEventListener("click", () => back());
  $("#openInfo").addEventListener("click", () => sheets.openInfo(current()));
  $("#openBoost").addEventListener("click", () => sheets.openBoost());
  $("#openSearch").addEventListener("click", () => sheets.openSearch(""));
  $("#openSettings").addEventListener("click", () => sheets.openSettings());

  $("#scrub").addEventListener("click", (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const p = clamp((e.clientX - r.left) / r.width, 0, 1);
    if (state.duration <= 1) return toast("live stream — no seeking");
    player.seek(p * state.duration);
  });

  $$(".dock__item").forEach((b) =>
    b.addEventListener("click", () => {
      const tab = b.dataset.tab;
      if (tab === "deck") sheets.close();
      else if (tab === "info") sheets.openInfo(current());
      else if (tab === "boost") sheets.openBoost();
      else if (tab === "search") sheets.openSearch("");
      else if (tab === "crate") sheets.openCrate();
    })
  );

  $("#selSource").addEventListener("change", async (e) => {
    state.source = e.target.value;
    persist();
    $("#srcDot").dataset.src = state.source;
    if (state.source === "piped") {
      toast("probing piped / invidious…");
      const res = await searchLofi("lofi hip hop", { limit: 20 });
      if (res.origin.startsWith("seed")) toast("live instances unreachable — kept the seed corpus");
      else {
        state.pool = shuffle(res.accepted.length ? res.accepted : state.pool);
        state.poolPos = 0;
        toast(`${res.origin} · ${res.accepted.length} lofi accepted / ${res.rejected.length} rejected`);
      }
      log(`source probe → ${res.origin}`);
    } else {
      const s = await loadSeed();
      state.pool = shuffle(s.tracks);
      state.poolPos = 0;
      toast("metadata source · offline seed");
    }
    const t = current();
    if (t) scheduleEnrich(t);
  });

  $("#selMode").addEventListener("change", (e) => {
    state.mode = e.target.value;
    toast(state.mode === "radio" ? "endless radio · every swipe digs a new query" : "deck mode · swipe the seeded pool");
  });

  $("#selPlayer").addEventListener("change", (e) => {
    state.playerKind = e.target.value;
    persist();
    player.setKind(e.target.value);
    const t = current();
    if (t) player.load(t.videoId, state.time, !player.paused);
    routeBoost();
    toast(e.target.value === "synth" ? "routable source · boost is live and audible" : "youtube playback · boost maps to player volume");
  });

  addEventListener("keydown", (e) => {
    if (e.target.matches("input,textarea,select")) return;
    const key = e.key;
    if (key === "ArrowRight") hunt({});
    else if (key === "ArrowLeft") back();
    else if (key === " ") {
      e.preventDefault();
      player.toggle();
    } else if (key.toLowerCase() === "b") sheets.openBoost();
    else if (key.toLowerCase() === "i") sheets.openInfo(current());
    else if (key.toLowerCase() === "s") sheets.openSearch("");
    else if (key.toLowerCase() === "c") sheets.openCrate();
    else if (key.toLowerCase() === "f") {
      const c = $("#stack .card");
      c && deck.flip(c);
    } else if (key === "+" || key === "=") nudgeBoost(1);
    else if (key === "-" || key === "_") nudgeBoost(-1);
  });

  function nudgeBoost(db) {
    state.boost.db = clamp(state.boost.db + db, BOOST_MIN_DB, BOOST_MAX_DB);
    const sl = $("#boostSlider");
    if (sl) sl.value = state.boost.db;
    persist();
    routeBoost();
    toast(`boost ${fmtDb(state.boost.db)} · ${player.kind === "synth" ? "live" : "armed"}`);
  }
}

function tickClock() {
  const d = new Date();
  $("#clock").textContent = `${d.getHours() % 12 || 12}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/* ---------------------------------------------------------------- launch */

$("#unmute").hidden = false;
boot().catch((err) => {
  console.error(err);
  log(`boot failed: ${err.message}`, "warn");
  toast("boot failed — see the console panel");
});
