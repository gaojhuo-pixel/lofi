// ---------------------------------------------------------------------------
// lofi-filter.js — "only youtube lofi stuff".
//
// A genre gate. Every candidate video (from the seed corpus or a live API) is
// scored on its title, description, hashtags, channel and length; anything
// below the threshold never reaches the deck. Same weights and threshold are
// mirrored in ios/LofiGlass/Services/LofiFilter.swift, and tools/gate-check.mjs
// is the executable reference for both.
// ---------------------------------------------------------------------------

// term (regex source), weight, tag contributed when it matches
export const POSITIVE = [
  ["lo[.\\-\\s]?fi", 5, "lofi"],
  ["l o f i", 4, "lofi"],
  ["ｌｏｆｉ", 4, "lofi"],
  ["chill ?hop", 4, "chillhop"],
  ["jazz ?hop", 4, "jazzy"],
  ["(music|beats|sounds|tunes|radio)\\s*(to|for)\\s+(relax|study|sleep|focus|chill|work|drive|code)", 3.5, "beats to …"],
  ["beats? ?to ?(relax|study|sleep|chill|focus|drive)", 4, "beats to …"],
  ["study beats", 3, "study"],
  ["instrumental hip ?hop", 3, "instrumental"],
  ["hip ?hop radio", 3, "radio"],
  ["boom ?bap", 3, "boom bap"],
  ["tape hiss|tape loop|4th ?gen tape", 2.5, "tape"],
  ["\\bvhs\\b|crt|scan ?line", 2, "vhs"],
  ["chill beats", 2, "chill"],
  ["sleep lofi", 3, "sleep"],
  ["anime (edit|loop|amv)", 2, "anime edit"],
  ["type beat", 2, "type beat"],
  ["neo soul", 1.5, "neo soul"],
  ["\\bjazzy\\b", 1.5, "jazzy"],
  ["24\\s*/\\s*7", 2, "24/7"],
  ["lofi girl|chilledcow", 3, "lofi girl"],
  ["\\b(?:prod\\.|beat)\\s*(?:by\\s*)?[a-z0-9_.-]+\\b", 1, "beatmaker"],
];

// Terms that mean "this is not the genre you asked for"
export const NEGATIVE = [
  ["deep house", -4, "deep house"],
  ["progressive house", -4, "progressive house"],
  ["\btrance\b", -3.5, "trance"],
  ["hard ?style", -5, "hardstyle"],
  ["phonk", -3, "phonk"],
  ["\bdrill\b", -2, "drill"],
  ["heavy metal|deathcore|metalcore", -5, "metal"],
  ["k[\s\-]?pop", -2, "k-pop"],
  ["binaural", -3, "binaural beats"],
  ["subliminal|affirmation|solfeggio|\d{3} ?hz", -3.5, "frequencies/affirmations"],
  ["karaoke", -3, "karaoke"],
  ["workout|gym motivation", -3, "workout"],
  ["edm (festival|mix)", -4, "edm"],
  ["lofi (fake|filter scam)", -5, "lofi-bait"],
];

// Channels whose catalogue is curated lofi → trust boost.
export const TRUSTED_CHANNELS = [
  "lofi girl",
  "chilledcow",
  "lofi records",
  "chillhop music",
  "settle",
  "the bootleg boy",
  "afro lofi",
  "jeez",
  "lofi coffee",
  "mimi lofi chill",
  "the japanese town",
  "a lofi soul",
  "lofi shop 24h",
  "flux.fm",
  "lofi corners",
];

// Producers that only exist in this scene: a bare "Artist - Title" upload from
// one of them is lofi even when the description says nothing.
export const LOFI_ACTS = [
  "kudasai", "no spirit", "tonion", "nymano", "yasumu", "hm surf", "lilac", "trxxshed", "jhove",
  "blurred figures", "another silent weekend", "swiftly", "hazue", "noji", "sutton", "thymes",
  "home grown", "luella", "idealism", "sleep bean", "jinsang", "fantompower", "powfu", "dj hazel",
  "luvlee", "mnts", "tenncoats", "cwrd", "philo", "kuun", "vanyforce", "dthcheese", "shimza", "purrple cat",
];

export const MOODS = [
  ["sleep", ["sleep", "bedtime", "dream", "insomnia", "8 hours", "\ud83d\udca4"]],
  ["study", ["study", "exam", "homework", "revision", "relax/study"]],
  ["rain", ["rain", "storm", "thunder", "wet"]],
  ["cafe", ["cafe", "coffee", "barista", "latte"]],
  ["night-drive", ["night drive", "headlights", "midnight", "\uff5e drive", "drive to"]],
  ["jazzy", ["jazz", "sax", "piano trio", "swing"]],
  ["sad", ["sad", "cry", "lonely", "heartbreak", "melanch", "\ud83d\udc94"]],
  ["anime", ["anime", "ghibli", "spirited away", "opening"]],
  ["morning", ["morning", "sunrise", "breakfast", "upbeat"]],
  ["code", ["code", "coding", "programming"]],
  ["focus", ["focus", "deep work", "concentration"]],
];

const norm = (s = "") => ` ${String(s).toLowerCase().replace(/[|·—–]/g, " ").replace(/\s+/g, " ")} `;
const rxEsc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * @returns {{lofi:boolean, score:number, threshold:number, hits:string[], penalties:string[], moods:string[]}}
 */
export function gateTrack({ title = "", description = "", tags = [], channelName = "", durationSeconds = 0 } = {}) {
  const hay = norm(title) + "|" + norm(description) + "|" + norm((tags || []).join(" ")) + "|" + norm(channelName);
  const titleHay = norm(title);
  let score = 0;
  const hits = [];
  const penalties = [];

  for (const [term, weight, tag] of POSITIVE) {
    const re = new RegExp(term, "g");
    const inTitle = re.test(titleHay);
    re.lastIndex = 0;
    if (inTitle || re.test(hay)) {
      score += weight + (inTitle ? 1 : 0);
      hits.push(tag || term);
    }
  }

  for (const [term, weight, label] of NEGATIVE) {
    if (new RegExp(term, "g").test(hay)) {
      score += weight;
      penalties.push(label || term);
    }
  }

  if (TRUSTED_CHANNELS.some((c) => norm(channelName).includes(rxEsc(c)))) score += 2;
  for (const act of LOFI_ACTS) {
    if (titleHay.includes(` ${act} `) || titleHay.includes(` ${act}`) || norm(`${title} ${description}`).includes(`${act} - `)) {
      score += 4;
      hits.push(`${act} (known lofi act)`);
      break;
    }
  }

  // Long-form mixes and streams are lofi's natural habitat; sub-90s clips are not.
  if (durationSeconds > 3600) score += 0.75;
  else if (durationSeconds > 0 && durationSeconds < 90) score -= 0.75;
  if (durationSeconds === 0) score += 0.25; // live

  const threshold = 4;
  const moods = [];
  for (const [mood, words] of MOODS) if (words.some((w) => hay.includes(w))) moods.push(mood);

  return {
    lofi: score >= threshold,
    score: +score.toFixed(2),
    threshold,
    hits: [...new Set(hits)],
    penalties: [...new Set(penalties)],
    moods: [...new Set(moods)],
  };
}

/** Unique tags: explicit hashtags first, then everything the gate inferred. */
export function deriveTags(track, gate) {
  const explicit = (track.tags || []).map((t) => String(t).replace(/^#/, "").trim()).filter(Boolean);
  const inferred = (gate?.hits || []).concat(gate?.moods || []);
  const out = [];
  for (const t of [...explicit, ...inferred]) {
    const clean = t.replace(/^#/, "").trim().toLowerCase();
    if (clean && clean.length > 1 && !out.includes(clean)) out.push(clean);
    if (out.length >= 12) break;
  }
  return out;
}

export function deriveMood(track, gate) {
  if (track.mood) return track.mood;
  return gate?.moods?.[0] || "chill";
}
