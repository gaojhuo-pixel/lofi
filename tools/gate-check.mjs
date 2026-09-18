// Gate check: run `node tools/gate-check.mjs`.
// Asserts the lofi filter accepts every seed track and rejects every
// non-lofi example, so the Swift port has an executable reference to match.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  gateTrack,
  POSITIVE,
  NEGATIVE,
  TRUSTED_CHANNELS,
  LOFI_ACTS,
  MOODS,
} from "../prototype/src/lofi-filter.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const seed = JSON.parse(readFileSync(join(root, "shared/seed/lofi-feed.json"), "utf8"));

let accepted = 0;
const falseNegatives = [];
for (const t of seed.tracks) {
  const g = gateTrack({
    title: t.title,
    description: t.descriptionExcerpt || t.description || "",
    tags: t.tags || [],
    channelName: t.channelName,
    durationSeconds: t.durationSeconds,
  });
  if (g.lofi) accepted++;
  else falseNegatives.push({ title: t.title, score: g.score, hits: g.hits, penalties: g.penalties });
}

let rejected = 0;
const falsePositives = [];
for (const t of seed.excludedExamples) {
  const g = gateTrack({ title: t.title, description: "", tags: [], channelName: t.channelName, durationSeconds: 5400 });
  if (!g.lofi) rejected++;
  else falsePositives.push({ title: t.title, score: g.score, hits: g.hits });
}

const adversarial = [
  ["Deep House Festival Mix 2026 — EDM mainstage", "house", true],
  ["lofi beats to study to ☕ 1 hour", "lofi", false],
  // self-described #lofi + "beats to focus": ambiguous, we let the uploader's own tag win
  ["Binaural beats for focus • solfeggio 432hz #lofi", "ambiguous", false],
  ["Binaural beats for focus • solfeggio 432hz", "no lofi claim", true],
  ["Nujabes - Feathers (lofi remix)", "lofi", false],
  ["6AM MOTIVATION WORKOUT MIX", "workout", true],
];

// ---------------------------------------------------------------------------
// Swift parity. ios/LofiGlass/Services/LofiFilter.swift must carry the same
// regexes, weights, lists and threshold as the JS reference. There is no Swift
// compiler in this environment, so the tables are decoded straight out of the
// source text — one stray backslash in a Swift string literal silently changes
// a regex, and that is exactly the bug this catches.
// ---------------------------------------------------------------------------
const swift = readFileSync(join(root, "ios/LofiGlass/Services/LofiFilter.swift"), "utf8");

const swiftValue = (raw) => {
  let out = "";
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch === "\\" && i + 1 < raw.length) {
      const next = raw[i + 1];
      if (next === "\\") { out += "\\"; i++; continue; }
      if (next === '"') { out += '"'; i++; continue; }
      if (next === "n") { out += "\n"; i++; continue; }
      if (next === "t") { out += "\t"; i++; continue; }
      if (next === "u") {
        const end = raw.indexOf("}", i);
        out += String.fromCodePoint(parseInt(raw.slice(i + 3, end), 16));
        i = end;
        continue;
      }
    }
    out += ch;
  }
  return out;
};

const QUOTED = /"((?:[^"\\]|\\.)*)"/g;
const parity = [];

const swiftSignals = [...swift.matchAll(/\.init\(pattern: "((?:[^"\\]|\\.)*)",\s*weight:\s*(-?[\d.]+),\s*tag: "((?:[^"\\]|\\.)*)"\)/g)]
  .map((m) => [swiftValue(m[1]), parseFloat(m[2]), swiftValue(m[3])]);
const jsSignals = [...POSITIVE, ...NEGATIVE];
if (swiftSignals.length !== jsSignals.length) {
  parity.push(`signal count: swift ${swiftSignals.length} vs js ${jsSignals.length}`);
}
jsSignals.forEach(([term, weight, tag], i) => {
  const [sp, sw, st] = swiftSignals[i] ?? [];
  if (sp !== term) parity.push(`pattern #${i}: js ${JSON.stringify(term)} vs swift ${JSON.stringify(sp)}`);
  else if (sw !== weight) parity.push(`weight for /${term}/: js ${weight} vs swift ${sw}`);
  else if (st !== tag) parity.push(`tag for /${term}/: js ${JSON.stringify(tag)} vs swift ${JSON.stringify(st)}`);
});

const swiftArray = (name) => {
  const m = swift.match(new RegExp(`${name}: \\[[^\\]]*\\] = \\[([\\s\\S]*?)\\n  \\]`));
  if (!m) return null;
  return [...m[1].matchAll(QUOTED)].map((x) => swiftValue(x[1]));
};
for (const [js, name] of [[TRUSTED_CHANNELS, "trustedChannels"], [LOFI_ACTS, "knownActs"]]) {
  const got = swiftArray(name);
  if (!got) parity.push(`could not find ${name} in the swift port`);
  else if (got.join("|") !== js.join("|")) parity.push(`${name} drifted: swift ${got.length} entries vs js ${js.length}`);
}

const swiftThreshold = parseFloat((swift.match(/static let threshold: Double = ([\d.]+)/) ?? [])[1]);
if (swiftThreshold !== 4) parity.push(`swift threshold is ${swiftThreshold}, must be 4`);

const swiftMoods = [...swift.matchAll(/^\s*\("([a-z-]+)", \[([^\]]*)\]\),$/gm)]
  .map((m) => [m[1], [...m[2].matchAll(QUOTED)].map((w) => swiftValue(w[1]))]);
for (const [name, words] of MOODS) {
  const found = swiftMoods.find((x) => x[0] === name);
  if (!found) { parity.push(`swift is missing the ${name} mood`); continue; }
  if (found[1].join("|") !== words.join("|")) {
    parity.push(`mood ${name}: js ${JSON.stringify(words)} vs swift ${JSON.stringify(found[1])}`);
  }
}

console.log(`swift parity · ${parity.length === 0 ? "tables match" : `${parity.length} drifts`}`);
for (const d of parity) console.log(`  ✗ ${d}`);

console.log(`seed acceptance · ${accepted}/${seed.tracks.length}`);
console.log(`non-lofi rejection · ${rejected}/${seed.excludedExamples.length}`);
for (const [title, , shouldReject] of adversarial) {
  const [t, d] = title.split(" — ");
  const g = gateTrack({ title: t, description: d || "", tags: [], channelName: "", durationSeconds: 3600 });
  const verdict = g.lofi ? "accepted" : "rejected";
  const ok = shouldReject ? !g.lofi : g.lofi;
  console.log(`${ok ? "✓" : "✗"} "${t.slice(0, 44)}" → ${verdict} (score ${g.score}, hits ${g.hits.join("|") || "—"}, pen ${g.penalties.join("|") || "—"})`);
}
if (falseNegatives.length) {
  console.log("\nfalse negatives (seed items the gate refused):");
  for (const f of falseNegatives) console.log(`  ✗ ${f.title} · score ${f.score} · hits [${f.hits}] · pen [${f.penalties}]`);
}
if (falsePositives.length) {
  console.log("\nfalse positives (non-lofi the gate let through):");
  for (const f of falsePositives) console.log(`  ✗ ${f.title} · score ${f.score} · hits [${f.hits}]`);
}
const ok = accepted === seed.tracks.length && rejected === seed.excludedExamples.length && parity.length === 0;
console.log(`\n${ok ? "GATE OK" : "GATE NEEDS WORK"}`);
process.exit(ok ? 0 : 1);
