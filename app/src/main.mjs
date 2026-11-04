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
import { execFile } from "node:child_process";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

// The scripts live in the repository; the packaged app carries a copy under resources/.
const REPO_BIN = path.join(import.meta.dirname, "..", "..", "bin");
const RES_BIN = path.join(process.resourcesPath || "", "bin");
const BIN_DIR = fs.existsSync(path.join(REPO_BIN, "codex-byok")) ? REPO_BIN : RES_BIN;

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex-clone");

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
  const r = await run("codex-byok", ["--home", CODEX_HOME, "profile", "list", "--json"]);
  if (!r.ok) return { ok: false, error: r.stderr || r.stdout };
  try {
    const rows = JSON.parse(r.stdout);
    allowedModels = new Set(rows.flatMap((row) => row.models || []));
    return { ok: true, rows };
  } catch {
    return { ok: false, error: "profile list did not return JSON" };
  }
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
  const model = target.slice(target.indexOf(":") + 1);
  // The model must be one the gateway actually listed — the renderer cannot smuggle a path
  // or a flag in through this string.
  if (!allowedModels.has(model)) {
    return { ok: false, error: `model not in the served list: ${model}` };
  }
  const r = await run("codex-byok", ["--home", CODEX_HOME, "apply", target]);
  return { ok: r.ok, stdout: r.stdout, stderr: r.stderr };
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
