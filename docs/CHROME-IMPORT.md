# Chrome import failure — cause, evidence, and what actually works

Investigation of the Codex Desktop "Import from Chrome" flow, measured on this machine.
Nothing under `AppData\Local\Google\Chrome` was modified. Chrome was **not** stopped, restarted
or killed; 46 `chrome.exe` processes were live for the whole exercise.

- Codex Desktop: MSIX `OpenAI.Codex` `26.1029.7803.0`,
  `C:\Program Files\WindowsApps\OpenAI.Codex_26.1029.7803.0_x64__2p2nqsd0c76g0\app\`
- Host Chrome: `157.0.8103.38`, 14 profiles, `last_used` moves (`Profile 12` → `Profile 6` during the run)
- Clone home: `C:\Users\rahma\.codex-clone`, Electron user-data `C:\Users\rahma\.codex\electron-clone`

## Verdict in one paragraph

The four messages are not four failures. They are **one** failure reported per category, and the
category is not decided by measuring anything about passwords, cookies or history — the UI marks
history as failed unconditionally on Windows. The importer copies the selected Chrome profile
directory, and that copy dies on `Network\Cookies`, the one file Chrome holds open for every loaded
profile. Passwords and history are collateral: their files copy fine on their own. On top of that,
Windows Chrome stores every cookie and `Login Data For Account` password behind **App-Bound
Encryption**, which the app cannot decrypt without an administrator-approved elevation step. So even
a perfect copy of a fully-closed Chrome would not decrypt this machine's passwords and cookies
without that consent. **The 46 running Chrome processes are half the cause, not a red herring,
and not the whole cause.** Closing Chrome alone will not fix it — see §6.

---

## 1. Where the flow lives

Not in this repository. This repo holds the launcher, the probes and the BYOK tooling; the import
dialog belongs to the app. Grep over the repo for `import` + `chrome` finds only the unrelated
`chrome@openai-bundled` plugin contract (`CONTRACT.md` §6, `scripts/codex-launch.ps1:277`).

The flow is split across three shipped artifacts:

| Layer | Artifact | What it holds |
| --- | --- | --- |
| UI | `app\resources\app.asar` | The dialog, the messages, the failure predicates |
| Main process | `app\resources\app.asar` | `class O7` — `browserProfileImporter.list/getSignals/import` |
| Profile discovery | `plugins\cache\openai-bundled\browser\26.1029.61003\scripts\browser-service.mjs` | Reads `Local State`, enumerates profiles |
| Native copy + crypto | `app\chrome.dll` (embedded Chromium 156.0.8078.79) | `Login Data`, `Login Data For Account`, `Network\Cookies`, `History`, `Web Data`; ABE |

`app.asar` is a 720 MB archive reachable read-only at the install path. Every string below was read
straight out of it with an offset search, not from a decompiler.

The app-server logs in `~\.codex-clone\logs_2.sqlite` **cannot** help here: grepping all 30 148 rows
for `profile import`, `profileImport`, `browserProfile`, `browser profile` returns **0 hits**. The
import flow writes nothing to that log. The evidence is in the shipped code, not in a log.

Query used:

```python
import sqlite3
c = sqlite3.connect('logs_2.sqlite')                 # copy of ~/.codex-clone/logs_2.sqlite
c.execute("select count(*) from logs where lower(feedback_log_body) like '%profile import%'")   # 0
c.execute("select count(*) from logs where lower(feedback_log_body) like '%browser profile%'")  # 0
```

## 2. The exact strings, and where each one comes from

All four user-visible lines are localised `react-intl` messages, keyed under
`settings.browserUse.profileImport.*`:

| Message key | English default | Meaning in code |
| --- | --- | --- |
| `failed` | `Import failed` | the attempt threw or returned no result at all — dialog title |
| `failedSummary` | `We were unable to import your browsing data` | every selected category came back `failed` |
| `passwordsError` | `Passwords couldn’t be imported` | `passwords.status` failed |
| `cookiesError` | `Cookies couldn’t be imported` | `cookies.status` failed |
| `historyRetryGuidance` | `Make sure Chrome is fully closed` | **guidance, not a measurement** — see below |

`Import failed` as the title plus `We were unable to import your browsing data` as the body is the
shape you get when *nothing* came back usable: the import promise rejected, or the result carried no
successful category. That is exactly what a recursive copy aborting on `Network\Cookies` produces.

There is also, unused in the reported screenshot, a more specific cookie message, gated on
`cookies.status === "failed_to_copy"` specifically:

```
chromeCookieAccessError: "ChatGPT couldn't access this profile's cookies. Chrome may still be
running in the background. Close Chrome completely and try again. A device security policy may
also block access"
```

That it did **not** appear matters: it means the app did not receive a `failed_to_copy` cookie
result — it received no result, or a failed one. Consistent with the whole copy throwing before any
category could be reported (see §4).

## 3. The failure predicates — read from the bundle

Two functions decide everything (module `vv5b` in `app.asar`):

```js
// PR — "this category failed"
l = e => (e?.failed ?? 0) > 0 || e?.error != null || (e?.status != null && e.status !== "success" && e.status !== "missing")

// Jm — "this category succeeded"
u = e => e != null && ((e.imported ?? 0) > 0 || (e.skippedExisting ?? 0) > 0
       || (e.imported == null && (e.status === "partial-success" || (e.status === "success" && (e.failed ?? 0) === 0))))
```

And the history row does not ask a question:

```js
// inside the result panel; `d` == history was selected for import
eA = isWindows || isMacOS                                  // platform, nothing else
k  = d ? <Msg id="profileImport.historyRetryGuidance"
             defaultMessage="Make sure Chrome is fully closed" /> : undefined
```

`Make sure Chrome is fully closed` is therefore **hardcoded on Windows whatever the actual state
of the machine is**. It is a generic hint for the whole flow, rendered next to the history row
because history is the category the UI cannot classify. It is not evidence that Chrome's lock was
detected. This is the single most misleading part of the screen.

## 4. Why "we were unable to import" for all three at once

The importer copies the profile directory before reading it. Chromium's own `importer` reads the
`Network\Cookies` of any loaded profile with no sharing, and that handle is what an ordinary copy
then trips over. Proven both ways on this machine:

Selected profile = `Profile 12` (was `last_used` when the import was attempted):

```
Login Data                 OPEN-OK      (and a plain copy succeeds)
Login Data For Account     OPEN-OK
History                    OPEN-OK      (copy is byte-identical, sha256 match)
Web Data                   OPEN-OK
Network\Cookies            LOCKED: The process cannot access the file ... because it is being used by another process.
```

Then, copying the whole directory exactly as an importer would:

```
Copy-Item 'User Data\Profile 12' -Recurse
  -> FAILED on ...\Profile 12\Network\Cookies : being used by another process
  -> 12 527 files copied, then aborted
```

And the control, same command, a profile Chrome is **not** holding:

```
Copy-Item 'User Data\Profile 2'  -Recurse -> OK, 11 734 files
Copy-Item 'User Data\Profile 13' -Recurse -> OK, 31 282 files
```

That is the mechanism. One locked file aborts a recursive copy; the app then reports the abort once
per selected category. Passwords and history never had a problem of their own — `History` even
answers at **every** share mode (`share=0` exclusive through `share=3`), which is why "fully closed"
was never the requirement for it.

Current lock state, `Get-ChildItem`-driven, per profile:

```
LOCKED: Profile 1, Profile 3, Profile 6, Profile 12
FREE:   Profile 2, Profile 5, Profile 7, Profile 8, Profile 10, Profile 11,
        Profile 13, Profile 15, Profile 16, Profile 17
```

The locked set is exactly the profiles Chrome currently has loaded — it tracked
`profile.last_active_profiles` live during this run (`Profile 12` was `last_used` at the start,
`Profile 6` at the end, and both are in the locked set). Locking is per-profile and transient.
It is **not** machine-wide, and it is **not** "Chrome must be closed".

## 5. The second, independent cause — App-Bound Encryption

Even with a clean copy of a fully closed Chrome, this machine's cookies and passwords are
encrypted with a key the app cannot get at without elevation:

```
Local State -> os_crypt: ["app_bound_encrypted_key", "audit_enabled", "encrypted_key"]
app_bound_encrypted_key present: 860 chars
```

Cookie values carry the `v20` prefix (ABE), on every profile sampled:

```
Profile  2: v20=160  v10=0      303 cookie rows, all encrypted_value starts 76 32 30 ("v20")
Profile  8: v20=199  v10=0
Profile 13: v20= 24  v10=0
Profile 15: v20=113  v10=0
```

The same applies to `Login Data For Account`, which is the real password store on Chrome 157
(`Login Data` holds 0 rows in 12 of 14 profiles): `v20=36, v10=0` on `Profile 12`.

The app knows this and ships a consent gate for it — in `O7.importBrowserProfile` the request
carries `allowElevatedChromeDecryption`, and the UI renders:

```
windowsChrome.title:       "Administrator approval required"
windowsChrome.description: "Windows protects Chrome cookies and passwords with App-Bound
                            Encryption, so ChatGPT also needs administrator approval"
windowsChrome.consent:     "I understand the app will request administrator approval to import
                            this Chrome data"
```

That checkbox is not optional decoration: without it the import request goes out without
`allowElevatedChromeDecryption`, and the AES-GCM `v20` blobs stay unreadable. `app` also ships
`elevation_service.exe` (3.87 MB) for the step. This is a Windows platform constraint, not a repo
setting.

## 6. What the user must do — in order

Neither step alone is enough; the first removes the copy abort, the second removes the decryption
wall.

1. **Pick a profile Chrome is not holding open.** In the import dialog, choose the profile picker
   rather than accepting the `last_used` default. Any of `Profile 2, 5, 7, 8, 10, 11, 13, 15, 16, 17`
   is currently unlocked and copies cleanly with Chrome still running. This alone is enough to get
   **history** and the non-encrypted part of the profile across with zero disruption to the live
   browsing session.
2. **Tick the administrator-approval checkbox** in the import dialog. That is what sets
   `allowElevatedChromeDecryption`; it triggers the elevation prompt via `elevation_service.exe`.
   Decline it and cookies and passwords will keep failing on this machine forever, closed browser
   or not.
3. **Only if the profile you actually need is one of the loaded ones** (`Profile 1, 3, 6, 12` right
   now) does closing Chrome become necessary — and even then only for cookies. Quit Chrome
   completely (tray included; 46 processes is normal, Chrome leaves background helpers), then
   import. History and `Login Data` never required it.

If step 1 and 2 both succeed, "Make sure Chrome is fully closed" can be ignored: it is a static
Windows string (§3), not a verdict about this machine.

## 7. Why no change in this repository can fix it

The failure is inside OpenAI's shipped copy logic and Windows' ABE, in artifacts this repo does not
own and cannot patch:

- The copy is Chromium's native importer in `app\chrome.dll` plus `O7` in `app.asar` — both inside
  the signed MSIX. Editing them breaks the package signature.
- The lock is held by Chrome, not by anything here. The fix is copy-then-read, which is **app-side**
  by definition. A wrapper cannot retry a copy that the app performs internally.
- ABE decryption needs an elevated context the app must request; nothing in `~/.codex-clone` or the
  launcher can supply that consent.
- The clone config has no key that moves any of this. `allowExternalBrowserSettingsImport` is a
  managed **policy** read from config requirements; it is not set here, so it defaults to allowed,
  and the import is not policy-blocked. Verified: no `allowExternalBrowserSettingsImport` and no
  browser-import policy key in `~/.codex-clone/config.toml`.

What this repo *can* do, and what this document is: replace the misleading screen with the measured
cause and a workaround that actually works. Nothing else here is honest.

Deliberately not touched: `chrome@openai-bundled` stays disabled in the clone. That is the
extension-host cache lock (`CONTRACT.md` §6, `Access is denied (os error 5)` on plugin cache
refresh) — a different feature from the data import, and re-enabling it would regress the launcher
for no gain here.

## 8. Are the 46 Chrome processes the cause?

**Partly — and the message overstates their role.**

- They are the direct cause of the **copy abort**, but only for the four profiles they hold. Any
  other profile imports with Chrome fully running, proven above on `Profile 2` and `Profile 13`.
- They are **not** the reason passwords and cookies fail to decrypt. That is App-Bound Encryption,
  which persists after a full quit.
- They are **not** the reason history fails. `History` was never locked; it is failed by the shared
  copy abort plus a hardcoded Windows hint.
- The count itself is not the problem. 46 processes is Chrome's normal shape (one browser, one GPU,
  one network service, one renderer and utility set per loaded profile). Chasing the process count
  is chasing the wrong number.

## 9. Reproduction, read-only

`bin/chrome-import-check` packages the whole probe. It opens files for sharing, copies nothing,
writes nothing under the Chrome user-data directory, and never touches a browser process:

```
$ bin/chrome-import-check
chrome-import-check  (read-only; nothing closed, nothing copied)
  last_used profile : Profile 6
  importable now    : Profile 10, Profile 11, Profile 13, Profile 15, Profile 16, Profile 17, Profile 2, Profile 5, Profile 7, Profile 8
  locked (in use)   : Profile 1, Profile 12, Profile 3, Profile 6
  App-Bound Encrypt.: True

  PASS  at least one profile imports with Chrome still running.
        Cookies/passwords still need the 'Administrator approval required' consent.
```

Exit 0 = something is importable right now, 1 = everything is locked, 2 = could not measure.
Run it before believing any "close Chrome" advice.

The individual steps, if you want them by hand:

```powershell
# 1. the copy abort, on a loaded profile
Copy-Item 'C:\Users\rahma\AppData\Local\Google\Chrome\User Data\Profile 12' `
          'C:\Users\rahma\AppData\Local\Temp\copy1' -Recurse
# -> FAILED on ...\Profile 12\Network\Cookies : being used by another process

# 2. the control, on a profile Chrome is not holding
Copy-Item 'C:\Users\rahma\AppData\Local\Google\Chrome\User Data\Profile 2' `
          'C:\Users\rahma\AppData\Local\Temp\copy2' -Recurse
# -> OK

# 3. which profiles are locked right now
$ud = 'C:\Users\rahma\AppData\Local\Google\Chrome\User Data'
Get-ChildItem $ud -Directory | Where-Object Name -like 'Profile *' | ForEach-Object {
  $c = Join-Path $_.FullName 'Network\Cookies'
  try   { $fs=[IO.File]::Open($c,'Open','Read','ReadWrite'); $fs.Close(); "$($_.Name) FREE" }
  catch { "$($_.Name) LOCKED" }
}

# 4. App-Bound Encryption is live
(Get-Content "$ud\Local State" -Raw | ConvertFrom-Json).os_crypt.PSObject.Properties.Name
# -> app_bound_encrypted_key, audit_enabled, encrypted_key
```

No credential, cookie value or password was printed, exported or committed. Only file names, sizes,
lock outcomes, integer row counts and the string `v20` prefix were recorded.
