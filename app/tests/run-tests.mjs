/**
 * Runs every tests/*.mjs and tests/*.py. No framework, no Electron, no dependencies.
 *
 * Exists because two agents add test files to this directory on separate branches; a
 * hardcoded `node tests/<one-file>.mjs` chain would silently drop whichever landed
 * second. .mjs files use node:assert and throw on failure; .py files exit non-zero, so
 * import-and-spawn covers both.
 */
import { readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const dir = import.meta.dirname;
const all = readdirSync(dir).filter((f) => f !== "run-tests.mjs").sort();
const js = all.filter((f) => f.endsWith(".mjs"));
const py = all.filter((f) => f.endsWith(".py"));

if (all.length === 0) {
  console.error("no tests found in tests/");
  process.exit(1);
}

let failed = 0;
for (const f of js) {
  try {
    await import(path.join(dir, f));
    console.log(`  ok    ${f}`);
  } catch (err) {
    failed += 1;
    console.error(`  FAIL  ${f}`);
    console.error(String(err?.stack || err));
  }
}

// No python3 on the box is a skip, not a pass — the same rule the repo applies everywhere.
const python = py.length ? spawnSync("python3", ["--version"], { encoding: "utf8" }) : null;
for (const f of py) {
  if (!python || python.status !== 0) {
    failed += 1;
    console.error(`  FAIL  ${f}  (no python3 on PATH to run it)`);
    continue;
  }
  const r = spawnSync("python3", [path.join(dir, f)], { encoding: "utf8" });
  if (r.status === 0) {
    console.log(`  ok    ${f}`);
  } else {
    failed += 1;
    console.error(`  FAIL  ${f}`);
    console.error(`${r.stdout || ""}${r.stderr || ""}`.trimEnd());
  }
}

const total = js.length + py.length;
console.log(`\n${total - failed}/${total} test files passed`);
process.exit(failed === 0 ? 0 : 1);
