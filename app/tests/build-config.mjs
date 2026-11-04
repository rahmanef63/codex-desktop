/**
 * The build config is the only place this project can silently stop being free.
 *
 * Two things must stay true, and neither is caught by a compiler:
 *   1. macOS signing is OFF. `identity: null` plus `notarize: false`. If a future edit
 *      drops one of them, electron-builder starts looking for a $99/yr certificate and
 *      the build either fails or, worse, silently signs with whatever is in the keychain.
 *   2. Windows signing is OFF for the same reason, but rcedit must still run, so
 *      `signExecutable: false` — not `signAndEditExecutable: false`, which also strips
 *      the icon and copyright from the exe.
 *
 * Parsing is a hand-rolled reader for the small YAML subset in that file (top-level keys
 * and one nested block each). Adding a YAML dependency to assert six values is not worth
 * it; `python3 -c "import yaml"` in the verify step covers full-schema validity.
 */
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";

const root = path.join(import.meta.dirname, "..");
const yml = readFileSync(path.join(root, "electron-builder.yml"), "utf8");

/** Top-level key -> value, plus `block:child` for one level of nesting. Comments dropped. */
function parse(src) {
  const out = {};
  let block = null;
  for (const raw of src.split("\n")) {
    if (/^\s*#/.test(raw) || !raw.trim()) continue;
    const top = raw.match(/^([A-Za-z][\w-]*):\s*(.*)$/);
    if (top) {
      block = top[2].trim() ? null : top[1];
      out[top[1]] = top[2].trim();
      continue;
    }
    const child = raw.match(/^\s+([\w-]+):\s*(.*)$/);
    if (child && block) out[`${block}.${child[1]}`] = child[2].trim();
  }
  return out;
}

const cfg = parse(yml);

// 1. macOS: signing and notarization are both explicitly off.
assert.equal(cfg["mac.identity"], "null", "mac.identity must be null (no certificate to find)");
assert.equal(cfg["mac.notarize"], "false", "mac.notarize must be false (no Apple upload)");
assert.equal(cfg["mac.hardenedRuntime"], "false", "hardenedRuntime off: it is a notarization prerequisite");

// 2. Windows: signature skipped, executable metadata editing still on.
assert.equal(cfg["win.signExecutable"], "false", "win.signExecutable must be false (no certificate)");
assert.notEqual(cfg["win.signAndEditExecutable"], "false", "must not disable rcedit: it drops the icon too");

// 3. The unsigned consequence is documented where a person will actually look.
assert.match(yml, /xattr -dr com\.apple\.quarantine/, "the allow-locally command must be in the config");
assert.match(yml, /per-machine override/i, "and labelled as an override, not a fix");

// 4. The icon must be DECLARED and the file must exist. A declared-but-missing path
// fails the build outright, which is why this checks both halves.
const iconRel = "build/icon.png";
assert.equal(cfg["mac.icon"], iconRel, "mac.icon must point at build/icon.png");
assert.equal(cfg["win.icon"], iconRel, "win.icon must point at build/icon.png");
assert.ok(existsSync(path.join(root, iconRel)), iconRel + " must exist next to the config");
// A real icon is bigger than a placeholder and carries the PNG signature.
const iconBytes = readFileSync(path.join(root, iconRel));
assert.ok(iconBytes.length > 2000, "icon must not be a 1x1 placeholder");
assert.deepEqual([...iconBytes.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47], "icon must be a PNG");

// 5. Both mac arches and both mac targets.
assert.match(yml, /target: dmg\n\s+arch: \[arm64, x64\]/);
assert.match(yml, /target: zip\n\s+arch: \[arm64, x64\]/);

console.log("      build config: unsigned on both platforms, as configured");
