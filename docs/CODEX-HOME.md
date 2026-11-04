# Which Codex home is meant

One question, five places that used to answer it independently. They disagreed, and the
disagreement was expensive: the desktop window showed *"no profile"* while a working profile
sat one directory over, and a portability test run wrote into the real Windows clone home.

There is now **one implementation**, `bin/codex_home.py`, and everything else is a thin
adapter over it. This file is the specification the adapters are checked against;
`app/tests/home-agreement.mjs` runs every caller on the same hostile environment and fails
if they do not agree.

## The rules

First match wins. Nothing here looks at what happens to exist on disk except the one rule
that says so, and that one **refuses** rather than guessing.

| # | Condition | Decision | Result |
|---|---|---|---|
| 1 | `CODEX_HOME` set, absolute | trust it as intent | `$CODEX_HOME` |
| 1a | `CODEX_HOME` set, Windows path under WSL | translate via `wslpath -u`, else `/mnt/<drive>/...` | `$CODEX_HOME` in POSIX form |
| 1b | `CODEX_HOME` set, relative | **refuse** `relative-codex-home` | — |
| 2 | platform is `wsl` | `cmd.exe /c echo %USERPROFILE%` if unset → `wslpath -u` | `<base>/.codex-clone` |
| 2a | USERPROFILE unset **and** `cmd.exe` gives nothing / literal `%USERPROFILE%` | **refuse** `no-userprofile` | — |
| 2b | `wslpath` unavailable or returns non-absolute | `/mnt/<drive>/...` fallback, else **refuse** `untranslatable-profile` | — |
| 3 | platform is `win32` | `$env:USERPROFILE` | `<USERPROFILE>\.codex-clone` |
| 4 | anything else (Linux, macOS) | `$HOME` | `<HOME>/.codex-clone` |
| 5 | derived base is not absolute | **refuse** `relative-base` | — |
| 6 | derived base does not exist | **refuse** `missing-base` | — |

The ChatGPT-side home (`.codex`) is derived **by the same rule from the same base**, as a
separate value. Kept separate on purpose: a bogus `CODEX_HOME` must not be able to hide a
real profile, and searching only the clone home is exactly what produced "no profile".

## Failure modes each rule guards against

| Failure mode | What actually happened | Rule that stops it |
|---|---|---|
| Relative result | `CODEX_HOME=../evil` resolved against the process's cwd, so a write landed wherever the process stood. Worse than a wrong home: it *succeeds*. | 1b, 2b, 5 |
| Empty USERPROFILE translated | `wslpath -u ""` yields `""`, then `join("", ".codex-clone")` = `".codex-clone"` — relative, and silently created in the cwd. | 2a |
| Linux username assumed == Windows username | Here it is `rahman` vs `rahma`. Deriving from `$USER` lands on a directory that does not exist or is not ours. | 2 — ask Windows, never guess from `$USER` |
| `os.path.isdir()` used as the WSL test | A default that changes based on what exists is not a default. An `isdir` version wrote into the Windows home from a macOS portability run. | platform is an *environment read* (`WSL_DISTRO_NAME`), never a filesystem sniff |
| Hardcoded username | `"/mnt/c/Users/rahma/.codex"` as a literal default is wrong on every machine but one, and it is invisible on the machine where it works. | 2/3 derive from `USERPROFILE`; the test forbids `\/mnt\/c\/Users\/<name>` in any default |
| Derived base that does not exist | `~/.codex-clone` was created on Linux because the Linux home has no Windows clone home beside it. | 6 |

## The callers

| Caller | Question | How it reaches the resolver |
|---|---|---|
| `bin/codex-version-drift` | clone home (drift state lives inside it) | imports `codex_home`, calls `clone_home()` |
| `bin/codex-byok` | clone home (profiles live in it) | imports `codex_home` **lazily**, calls `clone_home()` |
| `bin/codex-9router-catalog` | real `.codex` home (writes the catalog it reads) | imports `codex_home`, `resolve()["real"]` |
| `app/src/main.mjs` (Electron main) | clone home + real home | runs `bin/codex-home --json` **once**, takes the answer verbatim |
| `scripts/codex-launch.ps1` | clone / real, Windows side | **unchanged**: `Join-Path $env:USERPROFILE '.codex-clone'` already *is* rule 3 |

`codex-byok` imports lazily because `app/tests/test-apply.py` `exec`s the file to reach
`set_top_level` alone and supplies no `__file__`; a module-scope import broke a test that
has nothing to do with homes.

## Why one Python implementation and not a shared data file

Considered: one authoritative implementation emits a small data file (platform → rule
table) that the other two read. Rejected, because the table is not the hard part — the hard
part is the two *external questions* (`cmd.exe` for USERPROFILE, `wslpath` for translation)
and the *refusals*, neither of which is expressible as static data. A data file would still
need code on each side to ask those questions and to decide what counts as a refusal, which
is three copies of the interesting logic with a table stapled on top.

Chosen instead: **one implementation, three thin adapters.** Node cannot import Python, so
it runs the CLI once and parses JSON — the adapter re-derives nothing, so there is nothing
to drift. PowerShell stays as it is because it is the Windows-side launcher, its default is
already the Windows rule, and rewriting a working launcher to call a Python script would add
an interpreter dependency to a path that must work before any of this is installed.

Cost, stated plainly: the Electron main process now depends on `bin/codex-home` being
present. It is shipped in `extraResources` beside the two scripts it already needed, and a
missing resolver surfaces as a `resolver-failed` refusal in the window rather than a
silently different home.

## Testing it

`app/tests/home-agreement.mjs` forces the platform with `CODEX_HOME_PLATFORM=wsl|win32|posix`
(the same escape hatch `bin/isolation-check` gives `ISOLATION_PLATFORM`) and stubs `cmd.exe`
and `wslpath` on `PATH`. That makes the WSL branch deterministic on a Linux CI box, where it
would otherwise be untestable — which is how the copies drifted apart unnoticed.

Six environments, every caller, same answer or same refusal: `CODEX_HOME` absolute; WSL with
USERPROFILE unset; WSL with USERPROFILE set; plain Linux; hostile relative `CODEX_HOME`;
derived base that does not exist. Two mutants were run against it and both were caught.
