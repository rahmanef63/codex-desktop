#!/usr/bin/env python3
"""The drift probe must survive a platform that has no MSIX.

`codex-version-drift` shells out to `powershell.exe` to read the installed app identity.
On macOS that binary does not exist, which is not an error — there is simply no app to
identify. The failure modes this test pins down, because each one is silent:

  1. A crash. `FileNotFoundError` from `subprocess.run` is an `OSError`, so the probe has
     to contain it rather than propagate a traceback to the caller.
  2. A false "OK". Exit 0 with an empty problem list means "checked, nothing moved". If the
     app-version comparison did not happen, the output has to say so — otherwise the
     report is a green light nobody actually earned.
  3. Writing outside the home it was asked about. The state file belongs inside `--home`;
     a test run must never touch a real Codex home.

Runs without Electron and without a network. `PATH` is reduced to the POSIX default set and
`powershell.exe` is deliberately absent, which is the closest honest approximation of macOS
available on a Linux or Windows host.

Run:  python3 tests/test-drift.py
Exit: 0 pass, 1 fail.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "bin" / "codex-version-drift"

failures = []


def run(home, *args, extra_env=None):
    """Invoke the probe in a clean environment with no powershell.exe on PATH."""
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(home),
        # Unset on purpose: CODEX_HOME wins over --home in some code paths, and WSL_DISTRO_NAME
        # switches the default to the Windows home. Both would mask the behaviour under test.
        "CODEX_HOME": "",
        "WSL_DISTRO_NAME": "",
    }
    env.update(extra_env or {})
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args, "--home", str(home)],
        capture_output=True, text=True, env=env, timeout=120,
    )


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="drift-test-"))
    try:
        home = root / "home"
        (home).mkdir()
        cfg = home / "config.toml"
        # A config with every load-bearing key present, so a clean check is meaningful.
        cfg.write_text(
            'model = "cx/gpt-6.1-sol"\n'
            'sandbox_mode = "workspace-write"\n'
            'model_provider = "9router"\n'
            '[windows]\n'
            'sandbox = "elevated"\n'
            'chrome@openai-bundled = false\n',
            encoding="utf-8",
        )

        # --- 1. record does not crash without powershell.exe, and writes inside the home.
        r = run(home, "record")
        if r.returncode != 0:
            failures.append(f"record exited {r.returncode} without powershell.exe\n"
                            f"  stderr: {r.stderr.strip()[:400]}")
        state = home / "version-drift" / "version-drift.json"
        if not state.is_file():
            failures.append(f"record did not write state to {state}")
        outside = [p for p in root.rglob("version-drift.json") if state not in p.parents and p != state]
        if outside:
            failures.append(f"state leaked outside --home: {[str(p) for p in outside]}")

        # --- 2. It says out loud that the app version was not measurable.
        if "not measurable" not in (r.stdout + r.stderr):
            failures.append("record did not report the app version as not measurable")

        # --- 3. check --json reports msix_measurable=false rather than implying a full check.
        r = run(home, "check", "--json")
        if r.returncode != 0:
            failures.append(f"check --json exited {r.returncode}: {r.stderr.strip()[:300]}")
        try:
            payload = json.loads(r.stdout)
        except json.JSONDecodeError:
            payload = None
            failures.append(f"check --json did not emit JSON: {r.stdout[:300]!r}")
        if payload is not None:
            if payload.get("msix_measurable") is not False:
                failures.append(f"msix_measurable should be false without an MSIX, got "
                                f"{payload.get('msix_measurable')!r}")
            if payload.get("problems"):
                failures.append(f"clean config reported problems: {payload['problems']}")

        # --- 4. Drift is still actually detected: the point of the tool, platform-independent.
        cfg.write_text('model = "changed"\n', encoding="utf-8")
        r = run(home, "check")
        if r.returncode != 1:
            failures.append(f"drift not detected after removing load-bearing keys: "
                            f"exit {r.returncode}, out={r.stdout.strip()[:300]!r}")
    finally:
        shutil.rmtree(root, ignore_errors=True)

    if failures:
        for f in failures:
            print(f"  FAIL  {f}")
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("ok  drift probe: no crash, no false OK, state stays inside --home, drift still detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
