// ---------------------------------------------------------------------------
// youtube.js — "finds only youtube lofi stuff".
//
// The app is YouTube-only. Metadata (description, tags, comments) is fetched
// from public Piped/Invidious-compatible JSON endpoints at runtime, straight
// from the user's browser. The sandbox itself has no general egress, and any
// of these public instances can be down, so every call degrades gracefully to
// the bundled seed feed (shared/seed/lofi-feed.json) — which holds real video
// IDs, titles, channels and tracklists scraped from YouTube on 2026-09-18.
// ---------------------------------------------------------------------------

import { gateTrack, deriveTags, deriveMood } from "./lofi-filter.js";
import { log } from "./util.js";

export const PIPED_INSTANCES = [
  "https://pipedapi.kavin.rocks",
  "https://pipedapi.adminforge.de",
  "https://api.piped.private.coffee",
  "https://pipedapi.drgns.space",
];

export const INVIDIOUS_INSTANCES = [
  "https://inv.nadeko.net",
  "https://invidious.nerdvpn.de",
  "https://yewtu.be",
  "https://iv.melmac.space",
];

let liveBase = null; // first instance that answered

async function tryFetch(url, ms = 6500) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(url, { signal: ctrl.signal, headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

async function fromAnyBase(paths, ms) {
  for (const base of paths) {
    try {
      const data = await tryFetch(base.url, ms);
      liveBase = base.name;
      return data;
    } catch (err) {
      log(`instance unreachable: ${base.url.replace(/^https:\/\//, "")} (${err.message})`, "warn");
    }
  }
  return null;
}

/* ------------------------------------------------------------------ seed */

let seed = null;
export async function loadSeed() {
  if (seed) return seed;
  const res = await fetch("/seed/lofi-feed.json");
  seed = await res.json();
  seed.tracks = seed.tracks.map(normalizeTrack).filter((t) => t.gate.lofi);
  log(`seed feed ready · ${seed.tracks.length} lofi videos accepted, ${seed.excludedExamples?.length ?? 0} rejected`, "ok");
  return seed;
}

export function thumbFor(videoId, size = "hq") {
  return `https://i.ytimg.com/vi/${videoId}/${size}default.jpg`;
}

export function normalizeTrack(raw) {
  const gate = gateTrack(raw);
  const track = {
    ...raw,
    source: "seed",
    thumbnail: thumbFor(raw.videoId),
    watchUrl: `https://www.youtube.com/watch?v=${raw.videoId}`,
    tags: raw.tags || [],
  };
  track.gate = gate;
  track.tags = deriveTags(track, gate);
  track.mood = deriveMood(track, gate);
  return track;
}

/* --------------------------------------------------------------- search */

function pipedItemToTrack(item) {
  return {
    source: "piped",
    videoId: (item.url || "").split("=").pop().replace(/^\//, ""),
    kind: item.duration === 0 || item.duration === -1 ? "live" : item.duration > 1200 ? "mix" : "track",
    title: item.title,
    channelName: item.uploaderName || item.channelName || "unknown",
    channelHandle: item.uploaderUrl ? item.uploaderUrl.replace("/@", "@") : "",
    durationSeconds: Math.max(0, item.duration || 0),
    viewCount: item.views || 0,
    publishedLabel: item.uploadedDate || "",
    tags: [],
    description: item.shortDescription || "",
    descriptionExcerpt: item.shortDescription || "",
    tracklist: [],
    comments: [],
  };
}

function invidiousItemToTrack(item) {
  return {
    source: "invidious",
    videoId: item.videoId,
    kind: item.lengthSeconds === 0 ? "live" : item.lengthSeconds > 1200 ? "mix" : "track",
    title: item.title,
    channelName: item.author || "unknown",
    channelHandle: "@" + (item.author || "").replace(/\s+/g, "").toLowerCase(),
    durationSeconds: item.lengthSeconds || 0,
    viewCount: item.viewCount || 0,
    publishedText: item.publishedText,
    tags: item.keywords || [],
    description: item.description || "",
    tracklist: [],
    comments: [],
  };
}

/**
 * Search YouTube for lofi, gated so only genuinely-lofi results survive.
 * @param {string} query  user text (the word "lofi" is injected if missing)
 * @param {object} opts   { mood, limit, allowSeedFallback }
 */
export async function searchLofi(query, { mood = "", limit = 24 } = {}) {
  const q = [query, mood, "lofi"].filter(Boolean).join(" ").trim();
  const out = { accepted: [], rejected: [], origin: "seed", query: q };

  if (q.trim()) {
    const piped = await fromAnyBase(
      PIPED_INSTANCES.map((u) => ({ name: "piped", url: `${u}/search?q=${encodeURIComponent(q)}&filter=music_tracks` })),
      7000
    );
    if (piped?.items?.length) {
      out.origin = `piped · ${liveBase}`;
      for (const item of piped.items.slice(0, 60)) {
        const t = normalizeTrack(pipedItemToTrack(item));
        (t.gate.lofi ? out.accepted : out.rejected).push(t);
      }
    } else {
      const inv = await fromAnyBase(
        INVIDIOUS_INSTANCES.map((u) => ({ name: "invidious", url: `${u}/api/v1/search?q=${encodeURIComponent(q + " lofi")}&type=video` })),
        7000
      );
      if (inv?.length) {
        out.origin = `invidious · ${liveBase}`;
        for (const item of inv.slice(0, 60)) {
          const t = normalizeTrack(invidiousItemToTrack(item));
          (t.gate.lofi ? out.accepted : out.rejected).push(t);
        }
      }
    }
  }

  if (!out.accepted.length) {
    // Offline/demo path: query the seed corpus instead.
    const s = await loadSeed();
    const words = q.toLowerCase().split(/\s+/).filter((w) => w && w !== "lofi");
    const scored = s.tracks.map((t) => {
      const hay = `${t.title} ${t.channelName} ${(t.tags || []).join(" ")} ${t.mood} ${t.descriptionExcerpt || ""}`.toLowerCase();
      let score = 0;
      for (const w of words) if (hay.includes(w)) score += 2;
      if (t.mood === mood) score += 3;
      return { t, score };
    });
    out.accepted = scored
      .filter((x) => x.score > 0 || words.length === 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.t)
      .slice(0, limit);
    out.rejected = s.tracks.filter((t) => !out.accepted.includes(t)).slice(0, 0);
  }

  out.accepted = out.accepted.slice(0, limit);
  log(`search "${q}" → ${out.accepted.length} lofi / ${out.rejected.length} rejected · via ${out.origin}`);
  return out;
}

/* ------------------------------------------------------------ enrichment */

/** Full description + tracklist from the watch page JSON (Piped or Invidious). */
export async function fetchDetails(videoId) {
  const piped = await fromAnyBase(
    PIPED_INSTANCES.map((u) => ({ name: "piped", url: `${u}/streams/${videoId}` })),
    7000
  );
  if (piped && (piped.description || piped.title)) {
    return {
      origin: "piped",
      title: piped.title,
      description: piped.description || "",
      tags: (piped.tags || []).filter(Boolean),
      channelName: piped.uploaderName,
      durationSeconds: piped.duration > 0 ? piped.duration : 0,
      viewCount: piped.views || 0,
      chapters: (piped.chapters || []).map((c) => ({ startSeconds: Math.round(c.start / 1000), title: c.title })),
      relatedStreams: (piped.relatedStreams || []).slice(0, 12),
    };
  }
  const inv = await fromAnyBase(
    INVIDIOUS_INSTANCES.map((u) => ({ name: "invidious", url: `${u}/api/v1/videos/${videoId}?fields=description,descriptionHtml,keywords,title,author,lengthSeconds,viewCount,chapters` })),
    7000
  );
  if (inv && (inv.description || inv.title)) {
    return {
      origin: "invidious",
      title: inv.title,
      description: stripTags(inv.descriptionHtml || inv.description || ""),
      tags: inv.keywords || [],
      channelName: inv.author,
      durationSeconds: inv.lengthSeconds || 0,
      viewCount: inv.viewCount || 0,
      chapters: (inv.chapters || []).map((c) => ({ startSeconds: c.start, title: c.title })),
    };
  }
  return null;
}

export async function fetchTopComments(videoId) {
  const piped = await fromAnyBase(
    PIPED_INSTANCES.map((u) => ({ name: "piped", url: `${u}/comments/${videoId}` })),
    7000
  );
  if (piped?.comments?.length) {
    return {
      origin: "piped",
      items: piped.comments.slice(0, 8).map((c) => ({
        author: c.author,
        authorAvatar: c.authorAvatar,
        text: c.commentText,
        likes: c.likeCount || 0,
        time: c.uploadedDate || "",
        creatorReplied: !!c.creatorReplied,
        pinned: !!c.pinned,
        provenance: "youtube",
      })),
    };
  }
  const inv = await fromAnyBase(
    INVIDIOUS_INSTANCES.map((u) => ({ name: "invidious", url: `${u}/api/v1/comments/${videoId}?sort_by=top` })),
    7000
  );
  if (inv?.comments?.length) {
    return {
      origin: "invidious",
      items: inv.comments.slice(0, 8).map((c) => ({
        author: c.author,
        text: c.content,
        likes: c.likeCount || 0,
        time: c.publishedText,
        pinned: c.pinned || false,
        provenance: "youtube",
      })),
    };
  }
  return null;
}

const stripTags = (html) =>
  String(html)
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();

/* -------------------------------------------------- tracklist from text */

// Lofi Girl / Settle / most mix channels write their description as
//   0:00 Artist - Title
//   3:40 Artist – Title
//   [00:12:34] Name — Track
// We parse that into timed credits so "who am I hearing right now" is answerable.
const LINE = /^\s*(?:\[)?(\d{1,2}:)?(\d{1,2}):(\d{2})(?:\])?\s*(?:[-–—•·:*>]+)?\s*(.+?)\s*$/;

export function parseTracklist(text = "") {
  const out = [];
  for (const raw of String(text).split(/\r?\n/)) {
    const m = raw.match(LINE);
    if (!m) continue;
    const hh = m[1] ? parseInt(m[1], 10) : 0;
    const mm = parseInt(m[2], 10);
    const ss = parseInt(m[3], 10);
    let label = (m[4] || "").trim();
    if (!label || label.length < 3) continue;
    if (/^(stream|listen|follow|sub|social|track ?list|timestamps?)/i.test(label)) continue;
    label = label.replace(/^\d{1,2}:\d{2}\s*[-–—]\s*/, "");
    let artist = label;
    let title = "";
    const sep = label.match(/\s+[-–—]\s+/);
    if (sep) {
      artist = label.slice(0, sep.index).trim();
      title = label.slice(sep.index + sep[0].length).trim();
    }
    if (!title) {
      const byIx = label.match(/\s+by\s+(.+)$/i);
      if (byIx) {
        title = label.slice(0, byIx.index).trim();
        artist = byIx[1].trim();
      }
    }
    if (!artist) continue;
    const startSeconds = hh * 3600 + mm * 60 + ss;
    if (out.length && startSeconds <= out[out.length - 1].startSeconds) continue;
    out.push({ startSeconds, artist: cleanArtist(artist), title: title || label, feat: featOf(title || label, artist) });
  }
  return out.sort((a, b) => a.startSeconds - b.startSeconds);
}

const cleanArtist = (a) =>
  a
    .replace(/^\s*(prod\.?|beat|music)\s*(by)?\s*[:\-]?\s*/i, "")
    .replace(/[|].*$/, "")
    .trim();

const featOf = (title, artist) => {
  const m = `${artist} ${title}`.match(/\b(?:ft\.?|feat\.?|with)\b[:\s]+(.+)$/i);
  return m ? m[1].trim() : "";
};

/** Which credit covers a playhead position. */
export function artistAt(tracklist, seconds) {
  if (!tracklist?.length) return null;
  let cur = null;
  for (const e of tracklist) {
    if (e.startSeconds <= seconds + 0.001) cur = e;
    else break;
  }
  return cur || tracklist[0];
}

export function nextTrackStart(tracklist, seconds) {
  return tracklist.find((e) => e.startSeconds > seconds + 0.5)?.startSeconds ?? null;
}
