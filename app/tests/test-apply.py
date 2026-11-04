#!/usr/bin/env python3
"""The only part of codex-byok that writes a real file must not damage it.

`set_top_level` rewrites ONE top-level key in config.toml. CONTRACT §5 forbids rewriting
the file wholesale, because the app appends `[windows]`, `[plugins.*]`, `[marketplaces.*]`
and `[projects.*]` and expects everything it wrote to survive. A bug here corrupts a user's
config, so each case below asserts the exact bytes that changed.

Run:  python3 tests/test-apply.py
Exit: 0 pass, 1 fail.
"""
import importlib.util
import os
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "bin" / "codex-byok"

spec = importlib.util.spec_from_loader("byok", loader=None)
byok = importlib.util.module_from_spec(spec)
byok.__dict__["__name__"] = "byok"
exec(compile(SCRIPT.read_text(encoding="utf-8"), str(SCRIPT), "exec"), byok.__dict__)

set_top_level = byok.set_top_level

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n  got:  {got!r}\n  want: {want!r}")


# 1. A top-level key that exists is replaced in place, nothing else moves.
src = 'model = "old"\nmodel_provider = "p"\n\n[windows]\nsandbox = "elevated"\n'
check("replace in place", set_top_level(src, "model", "new"),
      'model = "new"\nmodel_provider = "p"\n\n[windows]\nsandbox = "elevated"\n')

# 2. A key that is absent is inserted BEFORE the first table, so it stays top-level.
src = 'model_provider = "p"\n\n[windows]\nsandbox = "elevated"\n'
check("insert before first table", set_top_level(src, "model", "new"),
      'model_provider = "p"\nmodel = "new"\n\n[windows]\nsandbox = "elevated"\n')

# 3. A key with the same name INSIDE a table must not be touched. This is the bug that would
#    silently rewrite [windows] sandbox or a [model_providers.*] field.
src = '[model_providers.p]\nmodel = "inner"\n'
out = set_top_level(src, "model", "outer")
check("table key untouched, top-level added", out,
      'model = "outer"\n[model_providers.p]\nmodel = "inner"\n')
check("  and the inner value survived", 'model = "inner"' in out, True)

# 4. Comments and blank lines survive verbatim.
src = '# a comment\nmodel = "old"  # trailing\n\n# another\n[plugins."x"]\nenabled = false\n'
out = set_top_level(src, "model", "new")
check("comments preserved", out,
      '# a comment\nmodel = "new"  # trailing\n\n# another\n[plugins."x"]\nenabled = false\n')

# 5. Idempotent: applying the same value twice changes nothing the second time.
once = set_top_level('model = "a"\n', "model", "b")
check("idempotent", set_top_level(once, "model", "b"), once)

# 6. A model id containing a colon and slashes survives verbatim — this is the real case
#    (ctx/ollama/kimi-k3:cloud). Quoting is not mangled.
src = 'model = "old"\n'
out = set_top_level(src, "model", "ctx/ollama/kimi-k3:cloud")
check("colon survives", out, 'model = "ctx/ollama/kimi-k3:cloud"\n')

# 7. A key whose name merely STARTS the same (model_extra) is not matched by the `model` rewrite.
src = 'model_extra = "keep"\nmodel = "old"\n'
out = set_top_level(src, "model", "new")
check("prefix key untouched", out, 'model_extra = "keep"\nmodel = "new"\n')

# 8. A file of only tables gets the key first, not appended at the end.
src = '[a]\nx = 1\n'
check("key goes before tables, spacing kept", set_top_level(src, "model", "v"), 'model = "v"\n[a]\nx = 1\n')

if failures:
    print(f"FAIL  {len(failures)} case(s)")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("ok  apply contract: 8 groups, only the named top-level key changes")
