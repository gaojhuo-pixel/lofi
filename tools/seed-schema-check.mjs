// Seed-schema check: `node tools/seed-schema-check.mjs`
//
// Swift's synthesized Decodable requires every non-optional property that has no
// default, so a missing key in shared/seed/lofi-feed.json is a *boot failure* on
// iOS even though the prototype happily renders around it. This reads the real
// property list out of ios/LofiGlass/Models/LofiModels.swift and validates the
// seed file against it — no Swift compiler needed.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const models = readFileSync(join(root, "ios/LofiGlass/Models/LofiModels.swift"), "utf8");
const seed = JSON.parse(readFileSync(join(root, "shared/seed/lofi-feed.json"), "utf8"));

/** Parse `struct Name { var foo: T = d ... }` into {name: [{key, type, required}]} */
function structs(src) {
  const out = {};
  const re = /^struct (\w+)[^\n{]*\{/gm;
  let m;
  while ((m = re.exec(src))) {
    const name = m[1];
    let depth = 1;
    let i = m.index + m[0].length;
    while (i < src.length && depth > 0) {
      if (src[i] === "{") depth++;
      else if (src[i] === "}") depth--;
      i++;
    }
    const body = src.slice(m.index + m[0].length, i - 1);
    const props = [];
    for (const line of body.split("\n")) {
      const pm = /^\s*var\s+(\w+)\s*:\s*([^=;{]+?)(?:\s*=\s*(.+?))?\s*;?\s*$/.exec(line);
      if (!pm) continue; // computed properties (`var id: String { … }`) are never decoded
      const type = pm[2].trim();
      const optional = /\?$/.test(type) || /^Optional</.test(type);
      props.push({ key: pm[1], type: type.replace(/\?$/, ""), required: !optional && pm[3] === undefined });
    }
    // A hand-written init(from:) decodes with decodeIfPresent, so nothing is
    // actually required on the wire — do not invent requirements it doesn't have.
    const customDecoder = /init\(from decoder: Decoder\)/.test(body);
    if (customDecoder) for (const p of props) p.required = false;
    out[name] = props;
  }
  return out;
}

const S = structs(models);
const problems = [];
const check = (cond, msg) => { if (!cond) problems.push(msg); };

function validate(label, obj, structName) {
  const props = S[structName];
  if (!props) { problems.push(`no swift struct ${structName} found in LofiModels.swift`); return; }
  for (const p of props) {
    if (!p.required) continue;
    check(obj[p.key] !== undefined, `${label}: required swift field '${p.key}: ${p.type}' is missing from the seed`);
  }
}

check(!!S.LofiTrack, "LofiTrack struct not found");
check(!!S.SeedFile, "SeedFile struct not found");

// Top level keys the Swift model expects.
for (const p of S.SeedFile ?? []) {
  if (!p.required) continue;
  check(seed[p.key] !== undefined, `seed: required '${p.key}: ${p.type}' missing`);
}

const typeChecks = {
  videoId: (v) => typeof v === "string" && /^[A-Za-z0-9_-]{11}$/.test(v),
  durationSeconds: (v) => Number.isInteger(v) && v >= 0,
  viewCount: (v) => Number.isInteger(v) && v >= 0,
  tags: (v) => Array.isArray(v) && v.every((x) => typeof x === "string"),
  kind: (v) => ["mix", "live", "track"].includes(v),
};
const optionalTypeChecks = {
  mood: (v) => typeof v === "string" && /^[a-z-]+$/.test(v),
  publishedLabel: (v) => typeof v === "string",
  channelHandle: (v) => typeof v === "string" && v.startsWith("@"),
  channelId: (v) => typeof v === "string" && /^UC[\w-]{22}$/.test(v),
};

let tracklistEntries = 0;
let commentEntries = 0;
for (const track of seed.tracks ?? []) {
  const label = `track ${track.videoId}`;
  validate(label, track, "LofiTrack");
  for (const [key, ok] of Object.entries(typeChecks)) {
    if (track[key] !== undefined) check(ok(track[key]), `${label}: '${key}' has a value the swift model can't use (${JSON.stringify(track[key])})`);
  }
  for (const [key, ok] of Object.entries(optionalTypeChecks)) {
    if (track[key] != null) check(ok(track[key]), `${label}: '${key}' should be a ${key === "channelHandle" ? "@handle" : "sane string"}, got ${JSON.stringify(track[key])}`);
  }
  for (const entry of track.tracklist ?? []) {
    tracklistEntries++;
    validate(`${label} tracklist`, entry, "TrackCredit");
    check(Number.isInteger(entry.startSeconds) && entry.startSeconds >= 0, `${label}: tracklist startSeconds must be a non-negative int`);
  }
  for (const comment of track.comments ?? []) {
    commentEntries++;
    validate(`${label} comment`, comment, "YTComment");
    check(Number.isInteger(comment.likes), `${label}: comment likes must be an int (swift wants Int)`);
  }
  if (track.durationSeconds > 0) {
    check(track.durationSeconds < 86_400 * 3, `${label}: duration looks wrong (${track.durationSeconds}s)`);
  }
}

for (const example of seed.excludedExamples ?? []) {
  validate("excluded", example, "ExcludedExample");
  check(/^[A-Za-z0-9_-]{11}$/.test(example.videoId ?? ""), `excluded example has a bad videoId: ${example.videoId}`);
}

for (const q of seed.querySeeds ?? []) {
  validate("querySeed", q, "QuerySeed");
  check(typeof q.query === "string" || typeof q.label === "string", "querySeed needs a query or a label");
  if (q.mood != null) check(/^[a-z-]+$/.test(q.mood), `querySeed mood must be a slug, got ${q.mood}`);
}

// Everything the gate reads must exist in some form, or the deck empties itself.
const gateless = (seed.tracks ?? []).filter((t) => !t.title || (!t.descriptionExcerpt && !t.description && !(t.tags ?? []).length));
check(gateless.length === 0, `${gateless.length} seed tracks have no title/description/tags for the gate to read`);

console.log(
  `seed schema · ${seed.tracks?.length ?? 0} tracks · ${tracklistEntries} credit lines · ${commentEntries} comments · ` +
    `${seed.excludedExamples?.length ?? 0} counter-examples · ${seed.querySeeds?.length ?? 0} query seeds`
);
if (problems.length) {
  console.log("\nproblems:");
  for (const p of problems) console.log(`  ✗ ${p}`);
  process.exit(1);
}
console.log("SCHEMA OK");
