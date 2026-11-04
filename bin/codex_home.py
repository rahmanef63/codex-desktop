"""The one place that decides which Codex home is meant.

Three callers used to answer this question independently — `codex-version-drift`,
`app/src/main.mjs`, and `scripts/codex-launch.ps1` — and they disagreed, so the window
said "no profile" while a working profile existed, and one test run wrote into the real
Windows clone home. This module is the only implementation; the rest are adapters:

  * `codex-version-drift` and `codex-byok` import it (Python puts a script's own
    directory on sys.path, and they live beside it),
  * `bin/codex-home` is the CLI, and `app/src/main.mjs` shells out to it once with
    `--json`,
  * `scripts/codex-launch.ps1` is NOT changed: its default already IS the Windows rule
    below, and the agreement test asserts that against this module.

Rules, first match wins:

    CODEX_HOME set?    -> use it (absolute only; a Windows path is translated under WSL)
    platform == wsl    -> <wslpath USERPROFILE>/.codex-clone
    platform == win32  -> <USERPROFILE>/.codex-clone
    otherwise          -> <HOME>/.codex-clone

Every successful answer also names the ChatGPT-side `.codex` beside it, derived the same
way, so one call answers both questions the callers actually ask.

Three refusal codes, each a bug that used to be silent:

  relative-codex-home    A relative CODEX_HOME resolves against the current directory, so
                         `../evil` means "write wherever the process happens to stand".
                         That is worse than a wrong home because it succeeds.
  no-userprofile         USERPROFILE is frequently unset inside WSL. An empty value
                         translated through wslpath yields an empty base, hence a
                         RELATIVE home — the bug above, reached by accident.
  missing-base           A *derived* default is a guess about a directory. If the base it
                         is derived from does not exist the guess is wrong; this is how
                         `/home/rahman/.codex-clone` got created when the Linux home is
                         not the Windows one. An explicit absolute CODEX_HOME is intent,
                         not a guess, so it is honoured even before it exists.

`CODEX_HOME_PLATFORM=wsl|win32|posix` forces the platform read, the same escape hatch
`bin/isolation-check` uses via `ISOLATION_PLATFORM`. Tests need it to cover every branch
without a Windows box; production never sets it.
"""
import ntpath
import os
import posixpath
import subprocess
import sys

CLONE_NAME = ".codex-clone"
REAL_NAME = ".codex"


def platform():
    forced = (os.environ.get("CODEX_HOME_PLATFORM") or "").strip().lower()
    if forced in ("wsl", "win32", "posix"):
        return forced
    if os.environ.get("WSL_DISTRO_NAME"):
        return "wsl"
    return "win32" if sys.platform == "win32" else "posix"


def _pathmod(plat):
    return ntpath if plat == "win32" else posixpath


def _run(argv, timeout):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def windows_profile():
    """The Windows user's home, DERIVED — never a hardcoded username.

    USERPROFILE is frequently unset inside WSL, so an empty value must not be
    translated: that yields an empty base and a RELATIVE home. Asking Windows is
    authoritative. Guessing from $USER is not: the Linux account and the Windows
    account routinely differ (`rahman` vs `rahma` here) and the guess lands on a
    directory that may not exist or may not be ours.
    """
    profile = (os.environ.get("USERPROFILE") or "").strip()
    if profile:
        return profile
    out = _run(["cmd.exe", "/c", "echo %USERPROFILE%"], 15)
    if not out:
        return None
    first = out.splitlines()[0].strip()
    # An unexpanded %USERPROFILE% means the shell echoed the literal back at us.
    return None if first.upper() == "%USERPROFILE%" else first


def wsl_path(path):
    """Translate a Windows path into one a Linux process can stat.

    `wslpath` is the authority. The conventional /mnt/<drive>/... form is only used when
    the binary is missing, and the result still has to be absolute.
    """
    out = _run(["wslpath", "-u", path], 10)
    if out and posixpath.isabs(out):
        return out
    if len(path) >= 3 and path[1] == ":" and path[2] in "\\/":
        guess = "/mnt/%s/%s" % (path[0].lower(), path[2:].replace("\\", "/").lstrip("/"))
        if posixpath.isabs(guess):
            return guess
    return None


def _looks_windows(path):
    return len(path) >= 3 and path[1] == ":" and path[2] in "\\/"


def resolve(environ=None, isdir=os.path.isdir):
    """Return a dict, never raise for a user-facing condition.

    {'ok': True, 'platform', 'clone', 'real', 'source'} or
    {'ok': False, 'platform', 'reason', 'message'}

    A refusal is a return value so that every caller — Python, Node, the test — sees the
    same code and the same sentence. `real` can be None when only the clone home can be
    named; that is not a refusal, because the clone home is what the callers act on.
    """
    env = os.environ if environ is None else environ
    plat = platform()
    p = _pathmod(plat)

    def refuse(reason, message):
        return {"ok": False, "platform": plat, "reason": reason, "message": message}

    explicit = (env.get("CODEX_HOME") or "").strip()
    if explicit:
        if plat == "wsl" and _looks_windows(explicit):
            # The launcher sets a Windows path; the WSL side must not treat it as relative.
            translated = wsl_path(explicit)
            if not translated:
                return refuse(
                    "untranslatable-codex-home",
                    "CODEX_HOME is a Windows path (%r) this process cannot translate; "
                    "set CODEX_HOME to the /mnt/... form" % explicit,
                )
            explicit = translated
        if not p.isabs(explicit):
            return refuse(
                "relative-codex-home",
                "CODEX_HOME must be an absolute path, got %r; a relative home resolves "
                "against the current directory" % explicit,
            )
        return {
            "ok": True,
            "platform": plat,
            "clone": p.normpath(explicit),
            "real": _real_home(plat, isdir, p),
            "source": "codex-home",
        }

    if plat in ("wsl", "win32"):
        profile = windows_profile()
        if not profile:
            return refuse(
                "no-userprofile",
                "cannot determine the Windows user's home: USERPROFILE is unset and "
                "cmd.exe did not report one; set CODEX_HOME",
            )
        base = wsl_path(profile) if plat == "wsl" else profile
        if not base:
            return refuse(
                "untranslatable-profile",
                "cannot translate the Windows home %r into a path this process can read; "
                "set CODEX_HOME" % profile,
            )
    else:
        base = (env.get("HOME") or "").strip() or os.path.expanduser("~")

    if not p.isabs(base):
        return refuse(
            "relative-base",
            "the base home resolved to a relative path (%r); refusing to guess which "
            "directory that is" % base,
        )
    if not isdir(base):
        return refuse(
            "missing-base",
            "the derived home base does not exist (%s); set CODEX_HOME to the home you "
            "actually mean" % base,
        )
    return {
        "ok": True,
        "platform": plat,
        "clone": p.join(base, CLONE_NAME),
        "real": p.join(base, REAL_NAME),
        "source": "windows-profile" if plat in ("wsl", "win32") else "home",
    }


def _real_home(plat, isdir, p):
    """`.codex` beside the same base, derived independently.

    Kept off the CODEX_HOME branch's result so a bogus CODEX_HOME cannot poison it: the
    user's only real profile lives in the ChatGPT-side home while the clone home is the
    one a clone launch reads, and searching just one of them reported "no profile".
    """
    if plat in ("wsl", "win32"):
        profile = windows_profile()
        if not profile:
            return None
        base = wsl_path(profile) if plat == "wsl" else profile
    else:
        base = os.path.expanduser("~")
    if not base or not p.isabs(base) or not isdir(base):
        return None
    return p.join(base, REAL_NAME)


def clone_home():
    """The clone home, or SystemExit carrying the refusal.

    The refusal CODE is attached to the exception as `.reason`, so a caller (or the
    agreement test) can compare *why* it refused, not just that it did. The message is
    the same sentence every other caller reports for the same environment.
    """
    result = resolve()
    if not result["ok"]:
        exc = SystemExit(result["message"])
        exc.reason = result["reason"]
        raise exc
    return result["clone"]
