/**
 * One window over two scripts that already do the work.
 *
 * This is deliberately NOT a Codex clone. Codex Desktop is a separate MSIX that updates
 * itself through the Store; nothing here replaces it, patches it, or signs anything. What
 * this window adds is a readable view of two things that are easy to get wrong by hand:
 *
 *   1. which BYOK profile + model is active, and what each profile can actually serve,
 *   2. whether the app has moved any config key our launcher depends on.
 *
 * The renderer never sees a key. Every command is a fixed argv array, never a shell string,
 * so no user input can become a command. The scripts it calls print nothing secret.
 */
import { app, BrowserWindow, ipcMain, shell } from "electron";
import { execFile, execFileSync } from "node:child_process";
import path from "node:path";
import fs from "node:fs";

// The scripts live in the repository; the packaged app carries a copy under resources/.
const REPO_BIN = path.join(import.meta.dirname, "..", "..", "bin");
const RES_BIN = path.join(process.resourcesPath || "", "bin");
const BIN_DIR = fs.existsSync(path.join(REPO_BIN, "codex-byok")) ? REPO_BIN : RES_BIN;

/**
 * Which Codex home to read.
 *
 * This used to be a second implementation of the rules — `CODEX_HOME`, then the Windows
 * clone home under WSL, else `~/.codex-clone` — and it disagreed with `bin/codex-version-drift`
 * and with the PowerShell launcher. The window showed "no profile" while a working profile
 * existed one directory over.
 *
 * The rules now live in exactly one file, `bin/codex_home.py`. Node cannot import Python,
 * so this asks that file once and takes its answer verbatim. Nothing about the decision is
 * re-derived here: a divergent second copy is what broke, so there is no second copy.
 *
 * A refusal is surfaced, not papered over: `CODEX_HOME=../evil` cannot silently resolve
 * against the current directory, because the resolver refuses it and this passes the
 * reason through to the window.
 */
const HOME_RESOLUTION = resolveHomeOnce();

function resolveHomeOnce() {
  const script = path.join(BIN_DIR, "codex-home");
  let stdout;
  try {
    stdout = execFileSync(script, ["--json"], {
      encoding: "utf8",
      timeout: 30_000,
      env: { ...process.env },
    });
  } catch (err) {
    // A non-zero exit still prints the JSON refusal on stdout — that is the point of
    // `--json` returning 2 rather than throwing.
    stdout = String(err?.stdout || "");
    if (!stdout.trim()) {
      return {
        ok: false,
        reason: "resolver-failed",
        message: `bin/codex-home could not be run: ${err?.message || err}`,
        clone: null,
        real: null,
      };
    }
  }
  try {
    return JSON.parse(stdout);
  } catch {
    return {
      ok: false,
      reason: "resolver-not-json",
      message: "bin/codex-home --json did not return JSON",
      clone: null,
      real: null,
    };
  }
}

const CODEX_HOME = HOME_RESOLUTION.ok ? HOME_RESOLUTION.clone : null;

/**
 * Where a BYOK profile may live.
 *
 * Profiles are not tied to one home. The user's only real profile today is
 * `~/.codex/9router.config.toml` — the ChatGPT-side home — while the clone home is the one a
 * clone launch reads. Searching only the clone home reported "no profile" while a working
 * one sat one directory over, so both are searched, clone first because that is the home a
 * clone launch actually uses. Both paths come from the same resolver answer, so they cannot
 * disagree about which Windows user they belong to.
 */
function profileHomes() {
  const homes = [CODEX_HOME, process.env.CODEX_REAL_HOME || HOME_RESOLUTION.real];
  return [...new Set(homes.filter(Boolean))];
}

/** Run one of our python scripts. argv is a fixed array; nothing is interpolated into a shell. */
function run(script, args, { timeout = 120_000 } = {}) {
  return new Promise((resolve) => {
    execFile(
      path.join(BIN_DIR, script),
      args,
      { timeout, maxBuffer: 8 * 1024 * 1024, env: { ...process.env } },
      (err, stdout, stderr) => {
        resolve({
          ok: !err,
          code: err?.code ?? 0,
          stdout: String(stdout || ""),
          stderr: String(stderr || ""),
        });
      },
    );
  });
}

/** Only these model ids may be applied. The renderer can choose, not invent. */
let allowedModels = new Set();

async function listProfiles() {
  // No home means no honest answer. Say why, in the resolver's own words, rather than
  // falling back to a guess — the guess is what used to write into the wrong home.
  if (!HOME_RESOLUTION.ok) return { ok: false, error: HOME_RESOLUTION.message };
  const rows = [];
  const seen = new Set();
  const errors = [];
  for (const home of profileHomes()) {
    const r = await run("codex-byok", ["--home", home, "profile", "list", "--json"]);
    if (!r.ok) {
      // An empty home is not an error worth showing; a broken one is.
      if (r.stdout.trim() || r.stderr.trim()) errors.push(`${home}: ${r.stderr || r.stdout}`);
      continue;
    }
    let parsed;
    try {
      parsed = JSON.parse(r.stdout);
    } catch {
      errors.push(`${home}: profile list did not return JSON`);
      continue;
    }
    for (const row of parsed) {
      // A profile seen in both homes is the same file only if the home is the same; here the
      // homes differ, so name-collisions are shown with their home instead of dropped.
      const key = `${home}\u0000${row.name}`;
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push({ ...row, home });
    }
  }
  allowedModels = new Set(rows.flatMap((row) => row.models || []));
  if (!rows.length && errors.length) return { ok: false, error: errors.join("; ") };
  return { ok: true, rows, errors };
}

async function checkDrift() {
  if (!HOME_RESOLUTION.ok) return { ok: false, error: HOME_RESOLUTION.message };
  const r = await run("codex-version-drift", ["check", "--json", "--home", CODEX_HOME]);
  // Exit 1 means "drift", which is a successful measurement — only 2 is a failure.
  if (r.code === 2) return { ok: false, error: r.stderr || "nothing recorded yet" };
  try {
    const { problems = [] } = JSON.parse(r.stdout);
    return { ok: true, problems };
  } catch {
    return { ok: false, error: "version-drift did not return JSON" };
  }
}

function createWindow() {
  const win = new BrowserWindow({
    width: 900,
    height: 640,
    title: "Codex BYOK",
    backgroundColor: "#111214",
    webPreferences: {
      preload: path.join(import.meta.dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.loadFile(path.join(import.meta.dirname, "index.html"));
  // A link in the report is the user's to open, not ours to navigate.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  return win;
}

ipcMain.handle("profiles", () => listProfiles());
ipcMain.handle("drift", () => checkDrift());

ipcMain.handle("apply", async (_event, target) => {
  if (typeof target !== "string" || !target.includes(":")) {
    return { ok: false, error: "expected <profile>:<model>" };
  }
  const profileName = target.slice(0, target.indexOf(":"));
  const model = target.slice(target.indexOf(":") + 1);
  // The model must be one the gateway actually listed — the renderer cannot smuggle a path
  // or a flag in through this string.
  if (!allowedModels.has(model)) {
    return { ok: false, error: `model not in the served list: ${model}` };
  }
  // Apply in the home that OWNS the profile, so the write lands beside the file it names.
  let owner = null;
  for (const home of profileHomes()) {
    if (fs.existsSync(path.join(home, `${profileName}.config.toml`))) {
      owner = home;
      break;
    }
  }
  if (!owner) return { ok: false, error: `no ${profileName}.config.toml in any known home` };
  const r = await run("codex-byok", ["--home", owner, "apply", target]);
  return { ok: r.ok, home: owner, stdout: r.stdout, stderr: r.stderr };
});

ipcMain.handle("record-drift", async () => {
  if (!HOME_RESOLUTION.ok) return { ok: false, error: HOME_RESOLUTION.message };
  const r = await run("codex-version-drift", ["record", "--home", CODEX_HOME]);
  return { ok: r.ok, stdout: r.stdout, stderr: r.stderr };
});

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
