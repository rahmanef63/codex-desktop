/**
 * Three callers used to decide "which Codex home" three times, and they disagreed. That is
 * the bug this file makes impossible: it runs every caller against the SAME environment and
 * requires the SAME answer, or the SAME refusal reason.
 *
 * The callers, and how each is reached without a Windows box:
 *
 *   1. Python, `codex-version-drift`. Its `default_home()` is imported and called — the
 *      function that actually picks a home, not a reimplementation of it.
 *   2. Python, `codex-byok`. Its `home_dir()` likewise; every subcommand goes through it.
 *   3. Python, `codex-9router-catalog`. Its `default_home()`, which means the ChatGPT-side
 *      home; it used to hardcode `/mnt/c/Users/rahma/.codex`, a username baked into a
 *      default, and is asserted to resolve the same base as everyone else.
 *   4. Node, `app/src/main.mjs`. Importing it starts Electron, so the assertion runs
 *      `bin/codex-home --json` — the exact subprocess main.mjs runs — and separately proves
 *      main.mjs carries no resolver of its own.
 *
 * `scripts/codex-launch.ps1` is the remaining decision and is deliberately NOT rewritten: its
 * default already IS the Windows rule. It is asserted instead, as source, plus evaluated
 * for real when pwsh is present.
 *
 * Platforms are forced with `CODEX_HOME_PLATFORM`, the same escape hatch
 * `bin/isolation-check` gives `ISOLATION_PLATFORM`. Without it the WSL branch is testable
 * only on a WSL host and the Windows branch never — which is how three copies drifted apart
 * unnoticed in the first place.
 *
 * Offline: `cmd.exe` and `wslpath` are stubbed on PATH. They are the only two external
 * questions the resolver asks, and stubbing them is how the WSL branch becomes
 * deterministic on a Linux CI box. No network, no window, no real Codex home touched.
 */
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const REPO = path.join(import.meta.dirname, "..", "..");
const BIN = path.join(REPO, "bin");
const CLI = path.join(BIN, "codex-home");
const PYTHON = "python3";

const havePython = spawnSync(PYTHON, ["--version"], { encoding: "utf8" }).status === 0;

if (!havePython) {
  // No interpreter is a SKIP, not a pass — the repo's rule everywhere else.
  console.log("      skip: no python3 on PATH, cannot prove the three callers agree");
} else {
  main();
}

function main() {
  // A fake Windows profile that really exists, so the existing-base rule is exercised
  // rather than dodged by the case accidentally failing for another reason. A temp dir:
  // nothing here can reach a real Codex home.
  const root = mkdtempSync(path.join(os.tmpdir(), "home-agreement-"));
  const winBase = path.join(root, "win", "Users", "somebody");
  const posixBase = path.join(root, "posix", "somebody");
  mkdirSync(winBase, { recursive: true });
  mkdirSync(posixBase, { recursive: true });

  // The two binaries the resolver shells out to. `wslpath` answers with STUB_WSL_BASE when
  // it is set, which is exactly how the real one is told to return a path that exists.
  const stubs = path.join(root, "stubs");
  mkdirSync(stubs, { recursive: true });
  const stub = (name, body) => {
    const p = path.join(stubs, name);
    writeFileSync(p, `#!/bin/sh\n${body}\n`);
    chmodSync(p, 0o755);
  };
  stub("cmd.exe", 'printf "%s\\n" "${STUB_USERPROFILE:-}"');
  stub("wslpath", 'if [ -n "${STUB_WSL_BASE:-}" ]; then printf "%s\\n" "$STUB_WSL_BASE"; else exit 1; fi');

  const withStubs = (extra) => ({
    PATH: `${stubs}:/usr/bin:/bin`, // no powershell.exe: the MSIX probe must short-circuit
    ...extra,
  });

  /** bin/codex-version-drift `default_home()`, executed from the real file. */
  const DRIFT_EVAL = `
import importlib.util
spec = importlib.util.spec_from_loader("drift", loader=None)
m = importlib.util.module_from_spec(spec)
p = ${JSON.stringify(path.join(BIN, "codex-version-drift"))}
m.__dict__["__name__"] = "drift"
m.__dict__["__file__"] = p   # the scripts resolve their sibling resolver from it
exec(compile(open(p, encoding="utf-8").read(), p, "exec"), m.__dict__)
try:
    print("HOME=" + m.default_home())
except SystemExit as exc:
    print("REFUSED " + getattr(exc, "reason", "refused"))
    print(str(exc))
`;

  /** bin/codex-byok `home_dir()`, likewise. */
  const BYOK_EVAL = `
import importlib.util
spec = importlib.util.spec_from_loader("byok", loader=None)
m = importlib.util.module_from_spec(spec)
p = ${JSON.stringify(path.join(BIN, "codex-byok"))}
m.__dict__["__name__"] = "byok"
m.__dict__["__file__"] = p
exec(compile(open(p, encoding="utf-8").read(), p, "exec"), m.__dict__)
try:
    print("HOME=" + m.home_dir())
except SystemExit as exc:
    print("REFUSED " + getattr(exc, "reason", "refused"))
    print(str(exc))
`;

  let ENV = {};

  function pyEval(code) {
    const r = spawnSync(PYTHON, ["-c", code], { encoding: "utf8", env: ENV, timeout: 60_000 });
    if (r.status !== 0) return { broken: `exit ${r.status}: ${(r.stderr || "").trim().slice(0, 300)}` };
    const lines = r.stdout.trimEnd().split("\n");
    if (lines[0].startsWith("HOME=")) return { home: lines[0].slice(5) };
    if (lines[0].startsWith("REFUSED")) {
      return { reason: lines[0].slice("REFUSED".length).trim() || "refused", message: lines.slice(1).join(" ").trim() };
    }
    return { broken: `unexpected output: ${r.stdout.slice(0, 300)}` };
  }

  /** bin/codex-9router-catalog `default_home()`, which means the ChatGPT-side home. */
  const CATALOG_EVAL = `
import importlib.util
spec = importlib.util.spec_from_loader("cat", loader=None)
m = importlib.util.module_from_spec(spec)
p = ${JSON.stringify(path.join(BIN, "codex-9router-catalog"))}
m.__dict__["__name__"] = "cat"
m.__dict__["__file__"] = p
exec(compile(open(p, encoding="utf-8").read(), p, "exec"), m.__dict__)
try:
    print("HOME=" + m.default_home())
except SystemExit as exc:
    print("REFUSED " + getattr(exc, "reason", "refused"))
    print(str(exc))
`;

  const callers = {
    drift: () => pyEval(DRIFT_EVAL),
    byok: () => pyEval(BYOK_EVAL),
    catalog: () => pyEval(CATALOG_EVAL),
    node: () => {
      const r = spawnSync(CLI, ["--json"], { encoding: "utf8", env: ENV, timeout: 60_000 });
      let body;
      try {
        body = JSON.parse(r.stdout);
      } catch {
        return { broken: `not JSON (exit ${r.status}): ${(r.stdout || r.stderr || "").slice(0, 300)}` };
      }
      if (!body.ok) return { reason: body.reason, message: body.message };
      return { home: body.clone, real: body.real };
    },
  };

  const cases = [
    {
      name: "CODEX_HOME set, absolute",
      env: withStubs({ CODEX_HOME: path.join(root, "explicit"), CODEX_HOME_PLATFORM: "posix", HOME: posixBase }),
      want: { home: path.join(root, "explicit"),
        // The real home is DERIVED independently, so a bogus CODEX_HOME cannot poison it.
        // Deliberate: that is what keeps a clone-home override from hiding a real profile.
        catalog: path.join(posixBase, ".codex") },
    },
    {
      name: "WSL, USERPROFILE unset and cmd.exe yields nothing",
      // The stub echoes an empty string — precisely what WSL does. The old code translated
      // that empty value and produced a RELATIVE home.
      env: withStubs({ CODEX_HOME_PLATFORM: "wsl", HOME: posixBase, STUB_USERPROFILE: "" }),
      want: { reason: "no-userprofile" },
    },
    {
      name: "WSL, USERPROFILE set",
      env: withStubs({
        CODEX_HOME_PLATFORM: "wsl",
        HOME: posixBase,
        STUB_USERPROFILE: "C:\\Users\\somebody",
        STUB_WSL_BASE: winBase, // what wslpath would return; it must exist for the case to mean anything
      }),
      want: { home: path.join(winBase, ".codex-clone") },
    },
    {
      name: "plain Linux",
      env: withStubs({ CODEX_HOME_PLATFORM: "posix", HOME: posixBase }),
      want: { home: path.join(posixBase, ".codex-clone") },
    },
    {
      name: "hostile relative CODEX_HOME",
      env: withStubs({ CODEX_HOME: "../evil", CODEX_HOME_PLATFORM: "posix", HOME: posixBase }),
      want: { reason: "relative-codex-home" },
    },
    {
      name: "derived base that does not exist",
      // The real failure: a default derived from a Linux home that has no Windows clone
      // beside it. Returning it anyway is how /home/<user>/.codex-clone got created.
      env: withStubs({ CODEX_HOME_PLATFORM: "posix", HOME: path.join(root, "missing") }),
      want: { reason: "missing-base" },
    },
  ];

  const failures = [];
  const results = [];
  const shape = (a) =>
    a.broken ? `broken(${a.broken})` : a.home ? `home:${a.home}` : `reason:${a.reason}`;

  // `codex-9router-catalog` asks a different question on purpose: it generates a catalog
  // the ChatGPT-side home reads, so it names `.codex`, not `.codex-clone`. It is still held
  // to the same rule set — same base, same derivation, same refusals — which is the point.
  const CLONE_CALLERS = ["drift", "byok", "node"];

  for (const c of cases) {
    ENV = c.env;
    const got = {};
    for (const [name, fn] of Object.entries(callers)) {
      try {
        got[name] = fn();
      } catch (err) {
        got[name] = { broken: String(err?.message || err) };
      }
    }

    // 1. Every caller that answers the same question agrees with every other. This is the
    //    assertion the three original copies failed.
    const shapes = CLONE_CALLERS.map((k) => shape(got[k]));
    if (!shapes.every((s) => s === shapes[0])) {
      failures.push(`${c.name}: callers DISAGREE\n` +
        CLONE_CALLERS.map((k) => `      ${k}: ${shape(got[k])}`).join("\n"));
    }

    // 2. And the answer must be the RIGHT one. All callers agreeing on a wrong answer
    //    would be a green test that proves nothing.
    const expected = c.want.home ? `home:${c.want.home}` : `reason:${c.want.reason}`;
    if (shapes[0] !== expected) {
      failures.push(`${c.name}: answered ${shapes[0]}, expected ${expected}`);
    }

    // 3. The catalog caller must land on the same BASE as the others: `.codex` instead of
    //    `.codex-clone`, and the same refusal otherwise. It answers a different question,
    //    so `want.catalog` may override the expected path.
    const catShape = shape(got.catalog);
    const baseOf = (s) => (s.startsWith("home:") ? s.replace(/\/\.codex(-clone)?$/, "") : s);
    if (c.want.catalog) {
      if (catShape !== `home:${c.want.catalog}`) {
        failures.push(`${c.name}: catalog answered ${catShape}, expected home:${c.want.catalog}`);
      }
    } else if (baseOf(catShape) !== baseOf(shapes[0])) {
      failures.push(`${c.name}: catalog caller landed on a different base\n` +
        `      clone callers: ${shapes[0]}\n      catalog:       ${catShape}`);
    }
    if (c.want.reason && catShape !== `reason:${c.want.reason}`) {
      failures.push(`${c.name}: catalog refused with ${catShape}, expected reason:${c.want.reason}`);
    }
    if (c.want.home && !c.want.catalog && !catShape.endsWith("/.codex")) {
      failures.push(`${c.name}: catalog must name the .codex home, got ${catShape}`);
    }

    results.push({ case: c.name, answer: shapes[0], catalog: catShape });
  }

  // 3. main.mjs must not carry a resolver of its own. The bug was a second copy, so the
  //    absence of a second copy is the invariant, not the current answer.
  const mainSrc = readFileSync(path.join(REPO, "app", "src", "main.mjs"), "utf8");
  assert.match(mainSrc, /"codex-home"/, "main.mjs must ask the shared CLI");
  assert.doesNotMatch(mainSrc, /"\.codex-clone"/, "main.mjs must not build a clone home itself");
  assert.doesNotMatch(mainSrc, /USERPROFILE/, "main.mjs must not do its own USERPROFILE lookup");
  assert.doesNotMatch(mainSrc, /os\.homedir/, "main.mjs must not derive a home from homedir()");

  // 4. The Python callers must import the shared resolver, not restate its rules.
  //    Comments are stripped first: one of them documents the old hardcoded path, and a
  //    check that fails on its own explanation is a check nobody keeps.
  const stripComments = (src) =>
    src.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
  for (const f of ["codex-version-drift", "codex-byok", "codex-9router-catalog"]) {
    const src = stripComments(readFileSync(path.join(BIN, f), "utf8"));
    assert.match(src, /import codex_home/, `${f} must import the shared resolver`);
    assert.doesNotMatch(src, /WSL_DISTRO_NAME/, `${f} must not test for WSL itself`);
    assert.doesNotMatch(src, /cmd\.exe/, `${f} must not ask Windows itself`);
    // The username must never appear in a default. This is the rule the brief names, and
    // the catalog script broke it for months without anyone noticing.
    assert.doesNotMatch(src, /\/mnt\/c\/Users\/[A-Za-z0-9._-]+/,
      `${f} must not hardcode a Windows username`);
  }

  // 5. The Windows launcher keeps its own default, and that default must be the same rule
  //    the resolver encodes for win32. Source check always; real evaluation when pwsh exists.
  const ps1 = readFileSync(path.join(REPO, "scripts", "codex-launch.ps1"), "utf8");
  assert.match(ps1, /Join-Path \$env:USERPROFILE '\.codex-clone'/,
    "codex-launch.ps1 default must stay $USERPROFILE\\.codex-clone");
  if (spawnSync("pwsh", ["--version"], { encoding: "utf8" }).status === 0) {
    const out = execFileSync("pwsh", ["-NoProfile", "-Command",
      `$env:USERPROFILE='C:\\Users\\somebody'; Join-Path $env:USERPROFILE '.codex-clone'`],
      { encoding: "utf8" }).trim();
    assert.equal(out, "C:\\Users\\somebody\\.codex-clone", "pwsh resolves the win32 rule to the same shape");
  }

  rmSync(root, { recursive: true, force: true });

  if (failures.length) {
    for (const f of failures) console.error(`  FAIL  ${f}`);
    throw new Error(`${failures.length} agreement failure(s)`);
  }
  for (const r of results) console.log(`      agree  ${r.case}  ->  ${r.answer}`);
  console.log("      home agreement: 4 callers, " + results.length + " environments, one answer or one refusal");
}
