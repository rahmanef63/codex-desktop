# Shared invariants

Rules that must hold for every mode, every launch. Each one exists because breaking it caused a
real problem that took time to find.

## Isolation

1. **The clone home is standalone.** No junction, symlink or reparse point may point *out of*
   `~/.codex-clone`. The app legitimately creates one internal link
   (`plugins/cache/openai-bundled/chrome/latest` → its own versioned directory); that one is fine
   because it points inside. `bin/isolation-check verify` enforces this on every run: a link that
   resolves outside the clone home, or one whose target cannot be resolved, is a FAIL.
2. **Three variables, always together.** `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH`, and
   `--user-data-dir=` on the command line. Any two of them without the third silently attaches to
   the running instance.
3. **Never write into `~/.codex` from clone mode.** Not the config, not `auth.json`, not sessions.
4. **`auth.json` belongs to the real account.** It must never be copied into the clone home. The
   clone authenticates to its own gateway and needs no ChatGPT credentials.
5. **One resolver names the home.** `bin/codex_home.py` decides it; the bin scripts import it and
   `app/src/main.mjs` runs `bin/codex-home --json`. A second copy of these rules is the defect, not
   the fix — it is why the window showed "no profile" while a working profile existed, and why a
   test run wrote into the real Windows clone home. The rules, the per-platform answers and the
   refusal codes are specified in `docs/CODEX-HOME.md`; `app/tests/home-agreement.mjs` fails the
   build when two callers disagree. A default must never hardcode a username, and a derived path
   that is relative or whose base does not exist is refused, never returned.

## Configuration

5. **Never rewrite a clone config wholesale.** The app appends `[windows]`, `[desktop]`,
   `[plugins.*]`, `[marketplaces.*]`, `[projects.*]`, `[mcp_servers.*]` and its own keys. The
   launcher edits individual keys and leaves everything else byte-identical.
6. **Re-assert, do not set once.** These are overwritten by the app between runs:
   - `[windows] sandbox = "elevated"`
   - top-level `model` and `model_provider`
   - `[plugins."chrome@openai-bundled"] enabled = false`
7. **`sandbox_mode = "danger-full-access"` is required for MCP.** With `workspace-write`, every
   MCP call fails with `MCP tool call requires approval, but approval policy is never`.
8. **Every catalog entry needs the two load-bearing fields**: `tool_mode = "code_mode_only"` and
   `use_responses_lite = false`.

## Secrets

9. **No token in this repository.** The gateway bearer token lives in
   `~/.codex/9router.config.toml` and nowhere else. `.env.example` documents the shape.
10. **`codex-9router-catalog` reads the key from `NINE_ROUTER_KEY`.** It must never accept it as
    an argument, because arguments land in shell history.

## Verification

11. **Probe the disk, never the model.** A model claiming success is not evidence. Read the file,
    check the exit code, inspect the row.
12. **Never run Codex from `C:\Users\rahma`.** `~/.codex/config.toml` is then read as
    project-local config and silently overrides the profile under test.
13. **Do not touch the real account when testing the clone.** Record the pre-existing processes
    first — by name as well as by PID, because Chromium recycles renderers constantly and an
    exact-PID comparison reports a healthy app as killed — and verify every process name survives.
    `bin/isolation-check` is the executable form of this rule and runs on WSL, Linux and macOS;
    `tests/isolation-check.sh` proves it can still fail.

## Known traps

- `pkill -f "<pattern>"` matches its own shell when the pattern appears in the command line. It
  has killed the shell running it.
- `Get-ChildItem -Recurse` stops at reparse points; `cmd /c dir /s /a-d` does not. Two different
  counts for the same directory is not corruption.
- Counting reparse points on `~/.codex-clone` itself returns 1 because of the root path. Count
  with `-Recurse` and drop the root.
- `Access is denied (os error 5)` on plugin cache refresh is not a permission problem: Chrome
  launches `extension-host.exe` from inside the cache directory and Windows locks it. Turning off
  `chrome@openai-bundled` in the clone is the fix.
- The Windows sandbox banner ("Couldn't check Windows setup") is cosmetic. `HKLM\SOFTWARE\OpenAI\
  Codex\WindowsSandboxService` binds provisioning to one `CODEX_HOME`, so a clone caller always
  fails that readiness check while execution still works. Do not "fix" it by editing the registry;
  that strips the sandbox from the real account.
