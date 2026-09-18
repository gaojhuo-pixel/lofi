// Validates ios/project.yml well enough to catch the mistakes that break
// `xcodegen generate`: bad YAML, missing target/source paths, resources that
// point at files which do not exist, and an Info.plist key we rely on being gone.
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import YAML from "yaml";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const ymlPath = join(root, "ios/project.yml");
const doc = YAML.parse(readFileSync(ymlPath, "utf8"));

const problems = [];
const note = (ok, msg) => { if (!ok) problems.push(msg); };

note(!!doc.name, "project.yml has no name");
note(!!doc.targets?.LofiGlass, "missing app target LofiGlass");
note(!!doc.targets?.LofiGlassTests, "missing test target LofiGlassTests");
note(doc.settings?.base?.IPHONEOS_DEPLOYMENT_TARGET === "18.0", "deployment target should be 18.0");

const sources = doc.targets?.LofiGlass?.sources ?? [];
note(sources.length >= 2, "app target should include LofiGlass/ and the shared seed");
for (const entry of sources) {
  const p = typeof entry === "string" ? entry : entry?.path;
  if (!p) { problems.push("source entry without a path"); continue; }
  const abs = resolve(join(root, "ios"), p);
  note(existsSync(abs), `source path does not exist: ${p}`);
}

const resources = join(root, "ios/LofiGlass/Resources");
note(existsSync(resources), "ios/LofiGlass/Resources missing");

// XcodeGen's `info:` writes this plist; make sure the keys the code reads are set.
const info = doc.targets?.LofiGlass?.info?.properties ?? {};
for (const key of ["CFBundleDisplayName", "NSAppTransportSecurity", "CFBundleURLTypes", "UIAppFonts", "YouTubeAPIKey"]) {
  note(key in info, `Info.plist missing ${key}`);
}
note(
  info.NSAppTransportSecurity?.NSAllowsArbitraryLoads === false,
  "NSAllowsArbitraryLoads must stay false — only web content and localhost are exempt"
);
note(!!doc.schemes?.LofiGlass?.test?.targets?.length, "no test target wired into the LofiGlass scheme");

// Every Swift file on disk must be reachable from the sources list.
const walk = (dir, out = []) => {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const abs = join(dir, entry.name);
    if (entry.isDirectory()) walk(abs, out);
    else if (entry.name.endsWith(".swift")) out.push(abs);
  }
  return out;
};
const files = walk(join(root, "ios/LofiGlass")).concat(walk(join(root, "ios/LofiGlassTests")));
note(files.length >= 12, `suspiciously few swift files (${files.length})`);
console.log(`project.yml ok · ${files.length} swift files · ${sources.length} source entries`);

if (problems.length) {
  console.log("\nproblems:");
  for (const p of problems) console.log(`  ✗ ${p}`);
  process.exit(1);
}
console.log("PROJECT OK");
