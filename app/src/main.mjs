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
import os from "node:os";
import fs from "node:fs";

// The scripts live in the repository; the packaged app carries a copy under resources/.
const REPO_BIN = path.join(import.meta.dirname, "..", "..", "bin");
const RES_BIN = path.join(process.resourcesPath || "", "bin");
const BIN_DIR = fs.existsSync(path.join(REPO_BIN, "codex-byok")) ? REPO_BIN : RES_BIN;

/**
 * Which Codex home to read.
 *
 * CODEX_HOME wins, then the Windows clone home — but only when actually running under WSL,
 * because that is the one situation where the app (and therefore its home) lives on the
 * Windows side while the process is Linux. Anywhere else it is ~/.codex-clone.
 *
 * The Windows path is DERIVED, never hardcoded: `os.homedir()` under WSL is the LINUX home
 * (/home/<user>), so it is not a substitute, and hardcoding a username is wrong on every
 * machine but one. Ask Windows for USERPROFILE and translate it.
 */
function resolveCodexHome() {
  if (process.env.CODEX_HOME) return process.env.CODEX_HOME;
  const isWsl = Boolean(process.env.WSL_DISTRO_NAME);
  if (isWsl) {
    const winHome = windowsHomeFromWsl();
    if (winHome) return path.join(winHome, ".codex-clone");
  }
  return path.join(os.homedir(), ".codex-clone");
}

function windowsHomeFromWsl() {
  const runOnce = (cmd, args) => {
    try {
      const out = execFileSync(cmd, args, { encoding: "utf8", timeout: 15000 }).trim();
      return out || null;
    } catch {
      return null;
    }
  };
  // USERPROFILE is frequently unset inside WSL; asking Windows is authoritative.
  const profile = process.env.USERPROFILE
    || runOnce("cmd.exe", ["/c", "echo %USERPROFILE%"]);
  if (!profile || profile.toUpperCase() === "%USERPROFILE%") return null;
  const translated = runOnce("wslpath", ["-u", profile]);
  return translated && path.isAbsolute(translated) ? translated : null;
}

const CODEX_HOME = resolveCodexHome();

/**
 * Where a BYOK profile may live.
 *
 * Profiles are not tied to one home. The user's only real profile today is
 * `~/.codex/9router.config.toml` — the ChatGPT-side home — while the clone home is the one a
 * clone launch reads. Searching only the clone home reported "no profile" while a working
 * one sat one directory over, so both are searched, clone first because that is the home a
 * clone launch actually uses.
 */
function profileHomes() {
  const homes = [CODEX_HOME];
  // The ChatGPT-side home is the Windows one under WSL, not the Linux ~/.codex — that is
  // where the app and its profiles actually live. Ask the same resolver that found the
  // clone home, so both answers come from one place.
  const real = process.env.CODEX_REAL_HOME || realHomeFromWsl() || path.join(os.homedir(), ".codex");
  if (real !== CODEX_HOME) homes.push(real);
  return homes;
}

function realHomeFromWsl() {
  if (!process.env.WSL_DISTRO_NAME) return null;
  const base = windowsHomeFromWsl(); // returns the translated /mnt/c/Users/<winuser>
  return base ? path.join(base, ".codex") : null;
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
