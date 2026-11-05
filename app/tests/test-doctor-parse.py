#!/usr/bin/env python3
"""`codex-doctor` must read a profile the way the app writes one.

Two regressions, both of which reported a HEALTHY gateway as broken:
  1. parse_profile kept the section brackets ("[model_providers.x].base_url"), so every
     lookup by "model_providers.<id>.<key>" missed. A missed base_url is "no endpoint"; a
     missed token is a working gateway reported as HTTP 401.
  2. a clone home has no `<name>.config.toml` profile — the launcher writes one config.toml
     that already names its provider — and that was reported as "profiles: none".

Run:  python3 tests/test-doctor-parse.py
Exit: 0 pass, 1 fail.
"""
import importlib.machinery
import importlib.util
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "bin" / "codex-doctor"

loader = importlib.machinery.SourceFileLoader("doctor", str(SCRIPT))
spec = importlib.util.spec_from_loader("doctor", loader)
doctor = importlib.util.module_from_spec(spec)
loader.exec_module(doctor)

failures = []


def check(label, got, want):
    if got != want:
        failures.append("%s\n  got:  %r\n  want: %r" % (label, got, want))


PROFILE = """
approval_policy = "never"
model_provider = "nine_router"
model = "deepseek-v4.1-flash-free"

[model_providers.nine_router]
base_url = "https://router.example/v1"
wire_api = "responses"
experimental_bearer_token = "sk-test"
"""

with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / "9router.config.toml").write_text(PROFILE, encoding="utf-8")
    prof = doctor.parse_profile(str(tmp / "9router.config.toml"))

    check("model_provider", prof.get("model_provider"), "nine_router")
    check("base_url is reachable by provider id",
          prof.get("model_providers.nine_router.base_url"), "https://router.example/v1")
    check("token is reachable by provider id",
          prof.get("model_providers.nine_router.experimental_bearer_token"), "sk-test")
    check("no bracket leaks into a key", [k for k in prof if "[" in k], [])

    # 2. inline clone home: config.toml names its provider, no <name>.config.toml exists.
    clone = tmp / "clone"
    clone.mkdir()
    (clone / "config.toml").write_text(PROFILE, encoding="utf-8")
    names = doctor.check_profiles(str(clone))
    check("inline clone home is a profile", names, ["config"])
    check("inline profile resolves to config.toml",
          doctor.profile_path(str(clone), "config"), str(clone / "config.toml"))
    check("named profile resolves to <name>.config.toml",
          doctor.profile_path(str(clone), "vps"), str(clone / "vps.config.toml"))

    # An empty home still has to fail rather than guess.
    empty = tmp / "empty"
    empty.mkdir()
    doctor.RESULTS.clear()
    check("empty home has no profiles", doctor.check_profiles(str(empty)), [])
    check("empty home is reported as a failure",
          [r["ok"] for r in doctor.RESULTS], [False])

if failures:
    print("codex-doctor parse: %d failed" % len(failures))
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("codex-doctor parse: 9/9 PASS")
