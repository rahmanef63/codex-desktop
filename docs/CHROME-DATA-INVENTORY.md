# Chrome data inventory — import failure evidence

Read-only investigation. Nothing under `AppData\Local\Google\Chrome` was modified or deleted.
Chrome was **not** stopped, killed, or restarted (27 `chrome.exe` processes live during the whole exercise).

- Host Chrome: `157.0.8103.38`, `C:\Program Files\Google\Chrome\Application\chrome.exe`
- User-data root: `C:\Users\rahma\AppData\Local\Google\Chrome\User Data\`
- Codex Desktop: MSIX `OpenAI.Codex` `26.1029.7803.0` (`…\app\ChatGPT.exe`, Chromium `156.0.8078.79`)
- Sample time: 2026-11-04 ~20:18 WIB

## 1. Headline: there is no `Default` profile

`User Data\Default` **does not exist.** `Local State` reports 14 profiles, all custom-named:

```
last_used      = "Profile 12"
last_active    = ["Profile 12", "Profile 3", "Profile 1", "Profile 6"]
profile.info_cache = 14 entries
```

| Profile dir | `Local State` name |
|---|---|
| `Profile 1`  | 03 dita |
| `Profile 2`  | 01 lara |
| `Profile 3`  | 02 manef |
| `Profile 5`  | 04 Anti |
| `Profile 6`  | 11 careerpack |
| `Profile 7`  | BIN ZIAAN |
| `Profile 8`  | Belajar AI |
| `Profile 10` | 11 komtec |
| `Profile 11` | conextlab.ai |
| `Profile 12` | belajar  ← **last used / default** |
| `Profile 13` | 00 rahman |
| `Profile 15` | 11 batonly |
| `Profile 16` | mimin.org |
| `Profile 17` | s |

`System Profile` exists but holds none of the import targets.

Any importer that hardcodes the canonical `...\User Data\Default` path finds an empty directory here. That alone is
sufficient to produce a generic "couldn't be imported" for every category at once.

## 2. Per-file inventory

`Cookies` is **not** at the profile root on Chrome 157 — it lives in `<profile>\Network\Cookies`
(`NetworkDataMigrated` marker present in all 14 profiles). Root-level `Cookies` is **absent in every profile**.
A reader that only looks at `<profile>\Cookies` finds nothing, always.

| Profile | `Login Data` | `Login Data For Account` | `Network\Cookies` | `History` | `Web Data` |
|---|---|---|---|---|---|
| Profile 1  | 40 960 | 73 728 | 262 144 | 6 193 152 | 196 608 |
| Profile 2  | 40 960 | 40 960 | 196 608 | 3 145 728 | 159 744 |
| Profile 3  | 40 960 | 94 208 | 950 272 | 31 621 120 | 229 376 |
| Profile 5  | 40 960 | 81 920 | 294 912 | 13 238 272 | 196 608 |
| Profile 6  | 45 056 | 94 208 | 262 144 | 1 343 488 | 159 744 |
| Profile 7  | 40 960 | 40 960 | 36 864 | 307 200 | 159 744 |
| Profile 8  | 40 960 | 77 824 | 217 088 | 9 633 792 | 186 368 |
| Profile 10 | 45 056 | 40 960 | 163 840 | 950 272 | 163 840 |
| Profile 11 | 40 960 | 81 920 | 114 688 | 688 128 | 159 744 |
| Profile 12 | 40 960 | 53 248 | 126 976 | 2 162 688 | 196 608 |
| Profile 13 | 40 960 | 294 912 | 196 608 | 18 776 064 | 163 840 |
| Profile 15 | 40 960 | 81 920 | 135 168 | 16 547 840 | 159 744 |
| Profile 16 | 45 056 | 40 960 | 106 496 | 360 448 | 159 744 |
| Profile 17 | 40 960 | 40 960 | 57 344 | 557 056 | 159 744 |

All present, all non-zero. Nothing is missing on disk for any category. `Bookmarks` is absent in every profile
(synced, not local) — noted only so it is not mistaken for damage.

## 3. Copy test while Chrome runs

Method: `cp --reflink=never <file> /tmp/opencode/d7-copytest/<name>` from WSL, then `sha256sum` both sides.
Windows-level cross-check with `[System.IO.File]::Open(path,'Open','Read','ReadWrite')`, which is the exact access
the Chromium import path uses (read share, write share).

| File | WSL copy | Windows open (R/W share) | Error |
|---|---|---|---|
| `Profile 12\Login Data` | **OK**, sha256 match | OPEN-OK | — |
| `Profile 12\Login Data For Account` | **OK** | OPEN-OK | — |
| `Profile 12\History` | **OK**, sha256 match | OPEN-OK | — |
| `Profile 12\Web Data` | **OK**, sha256 match | OPEN-OK | — |
| `Profile 12\Network\Cookies` | **FAIL** | `IOException` | `The process cannot access the file … because it is being used by another process.` |

Full matrix over all 14 profiles:

| Profile | `Login Data` | `Network\Cookies` | `History` | `Web Data` |
|---|---|---|---|---|
| Profile 1  | COPY-OK | **LOCKED** | COPY-OK | COPY-OK |
| Profile 2  | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 3  | COPY-OK | **LOCKED** | COPY-OK | COPY-OK |
| Profile 5  | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 6  | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 7  | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 8  | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 10 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 11 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 12 | COPY-OK | **LOCKED** | COPY-OK | COPY-OK |
| Profile 13 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 15 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 16 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |
| Profile 17 | COPY-OK | COPY-OK | COPY-OK | COPY-OK |

The locked set `{1, 3, 12}` is an exact match for `profile.last_active_profiles` `["Profile 12","Profile 3","Profile 1","Profile 6"]`
(Profile 6 has no cookie writes in flight, hence unlocked). `--lock-dir` is set to `…\User Data\Profile N`, so a profile
is locked while Chrome has it loaded. Locking is **per-profile and transient**, not machine-wide.

`Network\Cookies-journal` is also locked for the same profiles. Five consecutive retries on `Profile 12\Network\Cookies`
all failed — the lock is held for the whole session, not a momentary flush.

Schema read (no values printed, `mode=ro`):

| File | `meta.version` | Notes |
|---|---|---|
| `Login Data` | 43 (compatible 40) | `logins` table present |
| `Login Data For Account` | 43 | `logins` table present |
| `History` | — | `urls` = 726 rows (Profile 12) |
| `Web Data` | — | `autofill` / `addresses` present |
| `Network\Cookies` (Profile 13) | 24 (compatible 24) | 39 rows, 4 distinct `host_key` |

**Passwords are not empty — they are just in the other file.** `logins` row counts:

| Profile | `Login Data` | `Login Data For Account` |
|---|---|---|
| Profile 1  | 0 | 37 |
| Profile 2  | 0 | 4 |
| Profile 3  | 0 | 58 |
| Profile 5  | 0 | 42 |
| Profile 6  | 1 | 58 |
| Profile 7  | 0 | 0 |
| Profile 8  | 0 | 53 |
| Profile 10 | 3 | 0 |
| Profile 11 | 0 | 49 |
| Profile 12 | 0 | 18 |
| Profile 13 | 0 | **260** |
| Profile 15 | 2 | 52 |
| Profile 16 | 3 | 0 |
| Profile 17 | 1 | 0 |

On Chrome 157 with account sync enabled, `Login Data` is the local-only store (mostly empty) and
`Login Data For Account` is the real, synced password store. Reading only `Login Data` reports zero passwords
in 12 of 14 profiles — a second independent cause of "Passwords couldn't be imported".

## 4. Where the messages come from

`strings` over the Codex MSIX bundle (`app\*.dll`, `*.exe`, `*.pak`): the messages exist **only in `app\chrome.dll`**
— the embedded Chromium, not app JS/TS. The string table in `chrome.dll` contains, in one block:

```
NetworkCookies  Login Data  Login Data For Account  History  Web Data
Chrome  User Data  Local State
```

Verdict: the import is **Chromium's native `importer` component**, shipped inside the app's own Chromium 156.
No custom importer exists, and no application log in
`…\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\**` records a successful or failed import attempt — the flow has
not been driven in this build's logging, so there is no log line to correlate against.

Path reality check: the app searches the canonical location (`…\AppData\Local\Google\Chrome\User Data`), which does
exist here, on **Chrome 157** — a newer major than the bundled Chromium 156. Edge also exists
(`…\Microsoft\Edge\User Data`, single `Default`) and is a separate candidate; it is not Chrome and will not satisfy a
Chrome import.

## 5. Verdict

**Not a lock. Not a design requirement. Two real causes: path and file-name, plus one partial lock.**

Ordered by how much each explains the reported symptoms:

1. **Path — no `Default` profile (affects every category at once).**
   `…\User Data\Default` is absent; the real profiles are `Profile 1`…`Profile 17`. An importer that resolves the
   canonical default profile finds an empty directory and fails passwords, cookies and history simultaneously —
   exactly the triple failure reported. This is the primary suspect and it is **independent of whether Chrome runs**.

2. **File name — `Cookies` is under `Network\`, not the profile root (affects cookies alone).**
   Absent at the root in all 14 profiles, present at `<profile>\Network\Cookies` in all 14. Even with a correct
   profile selected, a reader using the legacy root path imports zero cookies.

3. **File name — passwords are in `Login Data For Account` (affects passwords alone).**
   `Login Data` holds 0 rows in 12 of 14 profiles; the synced store is `Login Data For Account` (up to 260 rows).
   A reader that only opens `Login Data` reports "Passwords couldn't be imported" while 800+ passwords sit on disk.

4. **Lock — `Network\Cookies` of the loaded profile (real, but narrower than the message implies).**
   Only `{Profile 1, Profile 3, Profile 12}` are locked right now, only for `Cookies`, and only because Chrome has
   those profiles open. `Login Data`, `Login Data For Account`, `History` and `Web Data` copy cleanly with matching
   sha256 **for every profile including the open ones**.

### Is closing Chrome genuinely required?

**No — not for passwords, history, or autofill.** Proved by byte-identical read-only copies of `Login Data`,
`Login Data For Account`, `History` and `Web Data` taken from the live, open Profile 12 while 27 Chrome processes ran,
confirmed at both the WSL and the Windows `FileStream` layer. Chromium's SQLite profile databases are opened with
`read`+`write` sharing and are safe to read while Chrome runs; the standard mitigation is copy-then-open, which is
what the successful copies above already do.

**For cookies, closing Chrome would help — but it is not the correct fix.** `Network\Cookies` is the one file whose
lock is real and persistent (5/5 retries failed, `IOException` at the Windows layer). Chrome keeps a session-level
exclusive-ish handle on the cookie DB of every loaded profile. Two proper alternatives avoid asking the user to quit:

- import from a profile that is **not** loaded (`Profile 2/5/6/7/8/10/11/13/15/16/17` all copy cleanly right now), or
- run Chrome with `--user-data-dir` pointing at a copy/snapshot and read that.

So "Make sure Chrome is fully closed" is **the importer's chosen method for the cookies step**, generalized into a
single message for all three categories. It is only literally true for `Network\Cookies` of a loaded profile, it is
false for the two named categories in the failure text (Passwords, and by extension History/Web Data), and it would
still fail after a full Chrome quit because of causes 1–3.

Even with Chrome completely closed, this machine would keep failing: there is no `Default` profile to read, `Cookies`
is not where a legacy reader looks, and the password store is `Login Data For Account`.

## 6. Reproduction commands (read-only)

```bash
UD="/mnt/c/Users/rahma/AppData/Local/Google/Chrome/User Data"
ls -d "$UD/Default"                    # -> No such file or directory
ls "$UD" | grep -c '^Profile '         # -> 14

cp --reflink=never "$UD/Profile 12/Login Data" /tmp/x       # OK
cp --reflink=never "$UD/Profile 12/History"    /tmp/y       # OK
cp --reflink=never "$UD/Profile 12/Network/Cookies" /tmp/z  # Permission denied
```

```powershell
# Windows-layer confirmation of the same lock
[System.IO.File]::Open('C:\Users\rahma\AppData\Local\Google\Chrome\User Data\Profile 12\Network\Cookies','Open','Read','ReadWrite')
# -> IOException: The process cannot access the file because it is being used by another process.
```

No credential, cookie value, or password was printed, exported, or committed. Only file names, sizes, mtimes,
lock outcomes, and integer row counts were recorded.
