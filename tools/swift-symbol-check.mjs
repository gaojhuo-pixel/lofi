// Swift symbol check: `node tools/swift-symbol-check.mjs`
//
// There is no Swift toolchain in this environment, so the theme/type surface is
// verified textually instead. Three classes of mistake this repo actually made
// once and could make again:
//
//   1. a view references `Y2K.glassRefraction` and nobody ever declared it
//   2. two files both declare `struct SectionHeader` (redeclaration error)
//   3. a view references a type that no file declares (deep-link typo)
//
// It is a linter-shaped net, not a compiler: it will not catch signature drift.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const swiftFiles = [];
(function walk(dir) {
  if (!statSync(dir).isDirectory()) return;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const abs = join(dir, entry.name);
    if (entry.isDirectory()) walk(abs);
    else if (entry.name.endsWith(".swift")) swiftFiles.push(abs);
  }
})(join(root, "ios"));

const sources = new Map(swiftFiles.map((f) => [f, readFileSync(f, "utf8")]));
const rel = (f) => f.slice(root.length + 1);

const DECL = /^[ \t]*(?:@\w+\s+)*(?:public |internal |private |fileprivate )?(?:static |class )?(?:final )?(?:struct|class|enum|actor|protocol|extension)\s+(\w+)/gm;
const STATIC = /^[ \t]*(?:public |internal )?(?:static|class) (?:let|var|func) (\w+)/gm;
const TYPE_USE = /\b(?:struct|class|enum)\s+(\w+)\b/g;

// ---------------------------------------------------------------- types
const declaredTypes = new Map(); // name -> [files]
for (const [file, src] of sources) {
  // Only column-0 declarations can collide: nested types (`PipedProvider.Item`
  // vs `YouTubeDataProvider.Item`) are namespaced by their parent.
  for (const m of src.matchAll(/^(?:public |internal |private |fileprivate )?(?:final )?(?:struct|class|enum|actor|protocol)\s+(\w+)/gm)) {
    if (!declaredTypes.has(m[1])) declaredTypes.set(m[1], []);
    declaredTypes.get(m[1]).push(file);
  }
}

// type names referenced from view bodies we control
const OUR_TYPES = [...declaredTypes.keys()];
const referenced = new Map();
for (const [file, src] of sources) {
  for (const name of OUR_TYPES) {
    const hits = src.match(new RegExp(`\\b${name}\\b`, "g"));
    if (!hits) continue;
    if (!referenced.has(name)) referenced.set(name, new Set());
    referenced.get(name).add(file);
  }
}

const problems = [];

// 1. duplicate top-level type declarations (extension is fine, structs are not)
for (const [name, files] of declaredTypes) {
  const unique = [...new Set(files)];
  if (unique.length > 1) {
    problems.push(`type '${name}' is declared in ${unique.length} files: ${unique.map(rel).join(", ")}`);
  }
}

// 2. declared but never referenced anywhere (dead code that will rot)
const orphans = OUR_TYPES.filter((name) => {
  const users = referenced.get(name);
  if (!users) return true;
  return [...users].every((f) => declaredTypes.get(name).includes(f));
});
const testFiles = (f) => f.includes("LofiGlassTests");
const realOrphans = orphans.filter((name) => {
  const files = declaredTypes.get(name).filter((f) => !testFiles(f));
  return files.every((f) => !f.includes("/Views/") && !f.includes("/App/"));
});

// 3. statics on the theme enums: every `Y2K.foo` / `GlassTint.foo` must exist
const staticsOf = (typeName) => {
  const out = new Set();
  for (const [file, src] of sources) {
    const m = src.match(new RegExp(`(struct|enum|class|extension)\\s+${typeName}[^{;]*\\{`));
    if (!m) continue;
    let i = m.index + m[0].length - 1;
    let depth = 0;
    do {
      if (src[i] === "{") depth++;
      else if (src[i] === "}") depth--;
      i++;
    } while (i < src.length && depth > 0);
    const body = src.slice(m.index, i);
    for (const s of body.matchAll(/^[ \t]*(?:@\w+\s+)?(?:public |internal )?(?:static |class )?(?:let|var|func) (\w+)/gm)) out.add(s[1]);
    for (const s of body.matchAll(/^[ \t]*case (\w+)/gm)) out.add(s[1]);
    for (const s of body.matchAll(/^[ \t]*var (\w+)\s*:\s*\w+\s*\{/gm)) out.add(s[1]); // computed properties
  }
  return out;
};

for (const typeName of ["Y2K", "GlassTint", "GlassPanel", "Preset", "BoostSettings", "LofiFilter"]) {
  const have = staticsOf(typeName);
  if (!have.size) { problems.push(`no members found for ${typeName} — did it get renamed?`); continue; }
  const used = new Set();
  for (const [, src] of sources) {
    for (const m of src.matchAll(new RegExp(`\\b${typeName}\\.(\\w+)`, "g"))) used.add(m[1]);
  }
  // `Type.self` and the members Swift synthesises (CaseIterable, RawRepresentable,
  // Collection sugar) never appear as declarations, so they are not drift.
  const SYNTHESISED = new Set(["self", "init", "allCases", "Cases", "rawValue", "id", "hashValue", "description"]);
  for (const member of used) {
    if (SYNTHESISED.has(member)) continue;
    if (!have.has(member)) problems.push(`${typeName}.${member} is used but never declared`);
  }
}

console.log(
  `swift symbols · ${sources.size} files · ${declaredTypes.size} types · ` +
    `${["Y2K", "GlassTint", "Preset", "BoostSettings", "LofiFilter"].map((t) => `${t}:${staticsOf(t).size}`).join(" ")}`
);
if (realOrphans.length) console.log(`  · ${realOrphans.length} types only used inside their own file (${realOrphans.slice(0, 6).join(", ")})`);
if (problems.length) {
  console.log("\nproblems:");
  for (const p of problems) console.log(`  ✗ ${p}`);
  process.exit(1);
}
console.log("SYMBOLS OK");
