# macOS notes

Read this before trying to use this repository on a Mac. The short version: **this
repository is tooling for a Windows install of Codex Desktop.** Two of its scripts happen to
be plain file editors and work anywhere. Everything that measures the app does not, and
cannot, because there is no MSIX to measure.

## What Codex Desktop means here

The subject of this repo is **Codex Desktop**, distributed on Windows as the MSIX
`OpenAI.Codex`, entry point `app\ChatGPT.exe`. Its home is `~/.codex`, and a second instance
runs from `~/.codex-clone`. The launcher, the isolation check and every probe are written
against that install: the MSIX identity, `powershell.exe`, Windows paths under
`C:\Users\...`, and a `CODEX_HOME` that the app resolves as a Windows path.

Codex on macOS is **a different build with a different home layout** —
`~/Library/Application Support/...`, not `~/.codex` on every path. Making the *tooling* in
this repo run on macOS is not the same as making it work against a macOS Codex. Nothing here
has been tested against a macOS Codex install, because there is no such install to test
against on the machine this was written on. Treat any macOS Codex claim in this repo as
unverified.

## What works on macOS today

| Tool | Works? | Notes |
| --- | --- | --- |
| `bin/codex-byok` | yes | Pure file + `urllib`. Profile list/show/add/remove, `pick`, `apply`. No Windows paths, no `powershell.exe`. |
| `bin/codex-version-drift` | mostly | Config-key and catalog checks work. The app-version probe reports **"not measurable"** — see below. |
| `bin/codex-9router-catalog` | yes | Pure Python + HTTP against your gateway. Point `--codex-home` at wherever your catalog should live. |
| `app/` (the Electron window) | builds and runs | Unsigned, unnotarized. See the Gatekeeper section. |
| `scripts/secret-scan.sh` | yes | Fixed for BSD `xargs`. |
| `scripts/capture_proxy.py`, `scripts/mcp_echo.py` | yes | Pure Python; no platform assumptions in the code. |
| `bin/isolation-check` | **no** | Its process probe is `powershell.exe`/`Get-Process`. Fixed for BSD `realpath`/`md5`, but the probe itself is Windows-only. |
| `bin/qcheck` | **no**, refuses | Exits 2 on Darwin with an explanation instead of half-running. |
| `bin/codex-real-quicktest` | **no** | Defaults to `C:\Users\...\codex.exe`. |
| `bin/codex-caps-quicktest` | **no** | Same, plus `powershell.exe` for image fixtures. |
| `scripts/codex-launch.ps1` | **no** | PowerShell launcher for the MSIX. Not ported, not going to be. |

## What does not work, and why

**There is no MSIX.** `codex-version-drift` reads the installed app identity with:

```
powershell.exe -NoProfile -Command "(Get-AppxPackage -Name OpenAI.Codex | ...)"
```

On macOS `powershell.exe` does not exist. The script now handles this in three ways, all of
which matter:

1. It does not crash. `FileNotFoundError` is an `OSError` and was already caught; the probe
   is also skipped outright when `sys.platform != "win32"`.
2. It does not lie. `record` prints `app version  not measurable here (MSIX probe is
   Windows-only)`, `check` prints a `note:` on stderr, and `check --json` emits
   `"msix_measurable": false`.
3. It does not write anywhere unexpected. The fingerprint lives in
   `<home>/version-drift/version-drift.json`, inside the home you named, never in a global
   location. Writing drift state into `~/.codex` would pollute a directory this tool does
   not own on macOS.

What that means in practice: **a drift check on macOS validates your config keys and your
model catalog, and nothing about the app.** "OK nothing our tooling depends on has moved"
on macOS is a weaker statement than the same line on Windows. The `note:` on stderr is
there so nobody has to remember that.

**No process probe.** `isolation-check` decides whether the real account's processes
survived a probe by listing them through `powershell.exe`. macOS would need `ps -axo
pid,comm` and a name-matching rule that differs from `-match 'ChatGPT|codex|extension-host'`.
That is a rewrite of the Windows-only probe, which is out of scope here.

**No launcher.** `scripts/codex-launch.ps1` sets `CODEX_HOME`,
`CODEX_ELECTRON_USER_DATA_PATH` and re-asserts the two config values the app rewrites. The
equivalent on macOS would need to find the app bundle, its real support directory, and the
`--user-data-dir=` flag that build accepts — none of which has been verified. Do not assume
the Windows approach transfers.

## The unsigned build, and what Gatekeeper does about it

The macOS build is **unsigned and unnotarized**, on purpose. A Developer ID certificate
costs $99/year and the constraint for this project is that nothing costs money. That is a
documented price, not a defect, and it is not worked around with a fake signature.

Configured in `app/electron-builder.yml`:

| Key | Value | Effect |
| --- | --- | --- |
| `mac.identity` | `null` | electron-builder does not look for a certificate and does not sign. |
| `mac.notarize` | `false` | Nothing is uploaded to Apple; no Apple ID, no App Store Connect key. |
| `mac.hardenedRuntime` | `false` | Hardened Runtime is a notarization prerequisite and can block launch without a signature. |
| `mac.gatekeeperAssess` | `false` | Skips the post-sign assessment, which cannot pass with no signature. |
| `win.signExecutable` | `false` | Same reason on the Windows side: no certificate. |

`win.signExecutable: false` and not `win.signAndEditExecutable: false` is deliberate: the
latter also stops `rcedit`, which strips the icon and copyright out of the exe
(electron-builder issue #9030). Skipping only the signature keeps the metadata.

**Consequence.** A downloaded `.dmg` carries a quarantine flag. First launch is blocked:
*"cannot be opened because the developer cannot be verified."* The one command that allows
it on that machine is:

```sh
xattr -dr com.apple.quarantine "/Applications/Codex BYOK.app"
```

Or right-click the app → **Open** → **Open**, which does the same thing through the UI.

**This is a per-machine override, not a fix.** It removes the download flag from that one
copy on that one machine. It does not sign the app, does not satisfy Gatekeeper for anyone
else, does not survive a re-download, and does not help on a second Mac. The only real fix
is buying a certificate.

**One further caveat, stated because it is likely.** On Apple Silicon the kernel refuses to
execute arm64 binaries with no signature at all, so the `arm64` artifact may be killed on
launch even after the quarantine flag is gone. The free escape hatch — *not* enabled in the
config — is an ad-hoc signature, which needs no Apple certificate and no money, but still
leaves the Gatekeeper block for other machines:

```sh
cd app && npx electron-builder --mac -c.mac.identity=- -c.mac.hardenedRuntime=false
codesign -dv "dist/mac-arm64/Codex BYOK.app"     # check what you actually produced
```

Ad-hoc signing requires disabling library validation because Electron's frameworks carry
Apple's Team ID; `--mac` with `identity: "-"` in current electron-builder uses an ad-hoc
entitlements template that does this. If the app dies with
`[framework] not valid for use in process`, that is the reason.

## Steps a macOS user would actually follow

1. **Decide whether this repo is useful to you at all.** If you want a working Codex Desktop
   clone launcher, it is not — that is Windows-only. If you want the BYOK profile manager and
   the config/catalog drift report, continue.

2. **Nothing to install for the scripts.** Python 3 is on macOS. The scripts are stdlib-only.

   ```sh
   bin/codex-byok profile list                       # default home: ~/.codex-clone
   CODEX_HOME=~/somewhere bin/codex-byok profile add local \
       --base-url http://127.0.0.1:20128/v1 --key-env NINE_ROUTER_KEY
   bin/codex-byok pick
   ```

   `apply` backs up `config.toml` to `config.toml.bak` and rewrites exactly two top-level
   keys, leaving every other byte alone.

3. **Drift, against a catalog and config you actually have**

   ```sh
   bin/codex-version-drift record
   bin/codex-version-drift check --json      # note "msix_measurable": false
   ```

4. **The Electron window** — needs Node, and this is where you pay the Gatekeeper price:

   ```sh
   cd app
   npm install
   npm test            # config assertions + python self-checks, no Electron needed
   npm start           # runs unpackaged, no Gatekeeper involved at all
   npm run dist:mac    # dmg + zip, arm64 and x64, unsigned
   ```

   `npm start` is the cheapest way to look at it: running from source is not a downloaded
   quarantine-flagged bundle, so it launches without any override. The unsigned-build
   consequences apply to `npm run dist:mac` output, not to `npm start`.

5. **Run the checks**

   ```sh
   npm test                  # from app/
   python3 app/tests/test-apply.py
   python3 app/tests/test-drift.py
   bin/codex-version-drift check --json
   ```

## Which architecture to build

`dmg` and `zip`, each for `arm64` and `x64` — two artifacts per format, not a universal
binary. Every Mac Apple has sold since 2020 is arm64; `x64` covers Intel Macs and also runs
on Apple Silicon under Rosetta. A universal binary would double the merge step's failure
surface for no functional gain here (there is no native module to rebuild), and each
download would be twice the size.

## Portability fixes made for macOS

These were real breaks, not hypothetical:

| File | Was | Now | Why it broke |
| --- | --- | --- | --- |
| `scripts/secret-scan.sh` | `xargs -0 -r` | `xargs -0` + empty-list guard | BSD `xargs` has no `-r`. |
| `bin/isolation-check` | `realpath -m -- "$p"` | `resolve_path()` using `cd -P` + `$PWD` | `-m` is GNU. macOS 13+ has `realpath` without `-m`; macOS 12 has none at all. Verified byte-identical to `realpath -m` on 7 path shapes including symlinks and `..`. |
| `bin/isolation-check` | `md5sum` | `md5sum` if present, else `md5 -q` | macOS ships `md5`, not `md5sum`. Falls back to "cannot read" if neither exists, never to "unchanged". |
| `bin/isolation-check` | `grep -E '^[0-9]+\s'` | `grep -E '^[0-9]+[[:space:]]'` | `\s` is a GNU extension, undefined in POSIX ERE. |
| `bin/qcheck` | created `/mnt/c/...` unconditionally | refuses on Darwin; `QCHECK_DIR`/`QCHECK_WIN` overrides; `mkdir` failure is now FAILED | Silent `mkdir -p` success turned an unmeasurable run into a PASS. |
| `bin/codex-clone-quicktest` | `cd "${REPO:-default}" \|\| exit 1` | explicit "no repo at ..." message | Exiting 1 with no output reads like a script bug. |
| `bin/codex-version-drift` | hardcoded `/mnt/c/...` default; `state_dir()` outside the home | `WSL_DISTRO_NAME`-based default; state inside `--home` | A default that depends on what exists on disk wrote into the Windows home from a macOS test run. |

Constructs that look non-portable but are **not**, so nobody "fixes" them again:

- `seq 1 40` (`codex-clone-quicktest:138`) — macOS has had `/usr/bin/seq` since 10.8
  (BSD flavour, integer arguments identical to GNU).
- `date -u +%Y-%m-%dT%H:%M:%SZ` (`isolation-check:182`) — POSIX, no `-d`.
- `sed` without `-i` — `-i` differs between GNU and BSD; the repo never uses it.
- `comm -23 <(...) <(...)` — process substitution is bash, and macOS bash is 3.2, but 3.2
  supports it. No bash-4-only syntax is used anywhere (`declare -A`, `${x^^}`, `mapfile`,
  `&>>` all absent).
- `grep -P`, `stat -c`, `readlink -f` — not present anywhere in `bin/` or `scripts/`.

## Not done, deliberately

- No macOS port of `isolation-check`'s process probe (needs `ps` and a different
  name-matching rule; belongs with the Windows-only probe work).
- No macOS launcher. Not attempted, because the app bundle's real paths and flags have not
  been verified against an actual macOS Codex install.
- No `.icns` or `.ico`. This branch has no `build/` assets; a missing icon path fails the
  build, so `mac.icon`/`win.icon` are unset and electron-builder uses its default.
