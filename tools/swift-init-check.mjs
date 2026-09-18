// Swift init check: `node tools/swift-init-check.mjs`
//
// The first class of error in a codebase nobody has compiled is a view built
// with a label the type does not declare (`ScanlineOverlay(dimmed: true)` after
// the parameter was renamed to `opacity`). This resolves every explicit
// `init(...)` in ios/LofiGlass and checks each construction site's labels against
// it. Structural, not semantic: it will not judge types, optionality or order,
// and it deliberately ignores memberwise inits (those cannot drift the same way).
import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dir = join(root, "ios");

const files = [];
(function walk(d) {
  for (const entry of readdirSync(d, { withFileTypes: true })) {
    const abs = join(d, entry.name);
    if (entry.isDirectory()) walk(abs);
    else if (entry.name.endsWith(".swift")) files.push(abs);
  }
})(dir);

const rel = (f) => f.slice(root.length + 1);
const strip = (src) =>
  src
    .split("\n")
    .filter((l) => !/^\s*\/\/[^/]/.test(l)) // keep doc comments out of matching
    .join("\n");

/** text between `openIndex`'s brace and its match */
function balancedBraces(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    const ch = text[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  return "";
}

/** label list for `init(a: B, _ c: D = 1, e: F)` */
function labelsOf(paramList) {
  const out = [];
  let depth = 0;
  let current = "";
  const push = () => {
    const piece = current.trim();
    current = "";
    if (!piece) return;
    // external label is the first word unless the param starts with `_`
    const m = /^(\w+|_)\s*(\w+)?\s*:/.exec(piece);
    if (m) out.push(m[1] === "_" ? (m[2] ?? "") : m[1]);
    else {
      const noDefault = piece.split(/=(?![^()]*\))/)[0].trim();
      const w = noDefault.split(/[\s:]/)[0];
      if (w && w !== "_") out.push(w);
    }
  };
  // `->` must not be read as a closing angle bracket, and braces are counted so
  // a default value like `{ true }` cannot swallow the next parameter.
  for (const ch of paramList.replace(/->/g, "")) {
    if (ch === "(" || ch === "[" || ch === "{") depth++;
    else if (ch === ")" || ch === "]" || ch === "}") depth--;
    if (ch === "," && depth === 0) { push(); continue; }
    current += ch;
  }
  push();
  return out;
}

const TYPES = new Map(); // "Name" -> [{labels, file}]
const PROPS = new Map(); // "Name" -> [stored property names in declaration order]

/** Text starting at an opening paren; returns the balanced contents. */
function balanced(text, openIndex) {
  let depth = 0;
  for (let i = openIndex; i < text.length; i++) {
    const ch = text[i];
    if (ch === "(" || ch === "{" || ch === "[") depth++;
    else if (ch === ")" || ch === "}" || ch === "]") {
      depth--;
      if (depth === 0) return text.slice(openIndex + 1, i);
    }
  }
  return "";
}

const DECL_HEAD = /(?:^|\n)[ \t]*(?:public |internal |private )?(?:required |convenience )*init\s*\(/g;
const TYPE_HEAD = /^[ \t]*(?:@\w+\s+)*(?:public |internal |private |fileprivate )?(?:final )?(?:struct|class|enum|actor|extension)\s+(\w+)[^\n{]*\{/gm;

for (const file of files) {
  if (rel(file).includes("LofiGlassTests")) continue;
  const src = strip(readFileSync(file, "utf8"));
  // find the type each init belongs to by scanning backwards for a type header
  const heads = [...src.matchAll(TYPE_HEAD)].map((m) => ({ name: m[1], index: m.index }));
  for (const m of src.matchAll(DECL_HEAD)) {
    const open = m.index + m[0].length - 1;
    const params = balanced(src, open); // `() -> Bool` params need real balancing
    const owner = heads.filter((h) => h.index < m.index).pop();
    if (!owner) continue;
    if (!TYPES.has(owner.name)) TYPES.set(owner.name, []);
    TYPES.get(owner.name).push({ labels: labelsOf(params), file: rel(file) });
  }
  // Stored properties give every struct a memberwise init, which is not written
  // out anywhere and therefore cannot be matched against a declaration.
  if (!PROPS.has("")) PROPS.set("", []);
  for (const h of heads) {
    const bodyStart = src.indexOf("{", h.index);
    const body = balancedBraces(src, bodyStart);
    const names = [...body.matchAll(/^[ \t]{2,4}(?:@\w+(?:\([^)]*\))?\s*)*(?:private\(set\)\s+)?(?:public |internal |private )?(?:static |final )?(?:var|let) (\w+)\s*:/gm)]
      .map((m) => m[1])
      .filter((n) => n !== "id");
    const existing = PROPS.get(h.name) ?? [];
    PROPS.set(h.name, existing.concat(names.filter((n) => !existing.includes(n))));
  }
}

const problems = [];
let checked = 0;

for (const file of files) {
  const src = strip(readFileSync(file, "utf8"));
  for (const [name, overloads] of TYPES) {
    // construction sites: `Name(` or ` Name(label: …)` — skip declarations,
    // switch cases and type positions by requiring a lowercase label or `)`
    const re = new RegExp(`(?:^|[^.\\w])${name}\\s*\\(`, "g");
    for (const m of src.matchAll(re)) {
      const args = balanced(src, m.index + m[0].length - 1);
      if (!/\w\s*:/.test(args)) continue; // unlabelled / memberwise: nothing to check
      // strip nested calls so `credit: current(at: x)` does not donate `at:`
      const flat = args.replace(/\w+\s*\((?:[^()]|\([^()]*\))*\)/g, "n");
      const used = [...flat.matchAll(/(^|[(,\s])(\w+):/g)].map((x) => x[2]);
      if (!used.length) continue;
      checked++;
      const memberwise = (PROPS.get(name) ?? []);
      const isMemberwise =
        memberwise.length > 0 &&
        used.every((u, i) => memberwise[i] === u); // same order, may stop early (defaults)
      const inOrder = (used, labels) => {
        let i = 0;
        for (const label of used) {
          i = labels.indexOf(label, i);
          if (i === -1) return false;
          i += 1;
        }
        return true;
      };
      const ok =
        isMemberwise ||
        used.every((u) => u === "rawValue") ||
        overloads.some((o) => used.every((u) => o.labels.includes(u)) && inOrder(used, o.labels));
      if (!ok) {
        const known = overloads.map((o) => o.labels.join(", ")).join(" | ");
        problems.push(`${rel(file)}: ${name}(${used.join(", ")}) — declared labels: ${known}`);
      }
    }
  }
}

console.log(`swift inits · ${TYPES.size} types with explicit inits · ${checked} labelled call sites`);
if (problems.length) {
  console.log("\nproblems:");
  for (const p of [...new Set(problems)]) console.log(`  ✗ ${p}`);
  process.exit(1);
}
console.log("INITS OK");
