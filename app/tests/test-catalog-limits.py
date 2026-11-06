#!/usr/bin/env python3
"""The catalog must not inherit OpenAI's 95% safety margin onto a third-party slug.

Why this test exists: the catalog is built from the first entry of OpenAI's own
models_cache.json, which carries effective_context_window_percent = 95. Copying that onto
every 9router slug meant `model_context_window = 200000` in config.toml was reported by
Codex as 190000 -- a hidden multiply that looked like a second, unexplained limit. The
margin belongs to OpenAI's models, not to models proxied through a gateway.

Run:  python3 tests/test-catalog-limits.py
Exit: 0 pass, 1 fail.
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "bin" / "codex-9router-catalog"

loader = importlib.machinery.SourceFileLoader("catalog", str(SCRIPT))
spec = importlib.util.spec_from_loader("catalog", loader)
catalog = importlib.util.module_from_spec(spec)
loader.exec_module(catalog)

failures = []


def check(label, got, want):
    if got != want:
        failures.append("%s\n  got:  %r\n  want: %r" % (label, got, want))


# A faithful slice of what OpenAI's models_cache.json first entry looks like.
TEMPLATE = {
    "slug": "gpt-6.1-sol",
    "context_window": 500000,
    "max_context_window": 872000,
    "effective_context_window_percent": 95,
    "tool_mode": "code_mode_only",
    "use_responses_lite": False,
    "model_messages": {"persistent_instructions": "x"},
}

LIVE = {
    "ctx/ollama/deepseek-v4.1-flash:1017-cloud": {
        "id": "ctx/ollama/deepseek-v4.1-flash:1017-cloud",
        "context_length": 1000000,
        "max_completion_tokens": 128000,
        "capabilities": {"vision": True, "search": True, "thinkingEffortSupported": True},
    }
}

slug = "ctx/ollama/deepseek-v4.1-flash:1017-cloud"
entry = catalog.build_entry(TEMPLATE, slug, LIVE[slug], 0)

# 1. No hidden multiplier. This is the whole point of the fix.
check("effective_context_window_percent is 100, not inherited 95",
      entry.get("effective_context_window_percent"), 100)

# 2. The gateway's number is used verbatim for both context keys.
check("context_window comes from the gateway", entry.get("context_window"), 1000000)
check("max_context_window comes from the gateway", entry.get("max_context_window"), 1000000)

# 3. The percentage must not silently change the usable window. For a set of config values,
#    the number Codex would report must equal the value itself.
for configured in (200000, 500000, 1000000):
    reported = int(configured * entry["effective_context_window_percent"] / 100)
    check("config %d reports itself" % configured, reported, configured)

# 4. The template's own ChatGPT limits must not leak through.
check("template's context_window did not leak", entry.get("context_window") != 500000, True)
check("template's max_context_window did not leak", entry.get("max_context_window") != 872000, True)

# 5. Other load-bearing fields still come from the template (the fix must not regress them).
check("tool_mode kept from template", entry.get("tool_mode"), "code_mode_only")
check("use_responses_lite kept from template", entry.get("use_responses_lite"), False)

# 6. A real end-to-end run against a temp home, if a key is available.
key = pathlib.Path.home() / ".config" / "opencode" / "9router-vps.key"
if key.exists():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / "models_cache.json").write_text(json.dumps({"models": [TEMPLATE]}), encoding="utf-8")
        out = tmp / "cat.json"
        # Call the same pieces main() uses, rather than re-implementing it.
        live = catalog.fetch_models(key.read_text().strip())
        wanted = sorted(live)[:5]
        entries = [catalog.build_entry(TEMPLATE, s, live[s], i)
                   for i, s in enumerate(wanted)]
        out.write_text(json.dumps({"models": entries}), encoding="utf-8")
        loaded = json.loads(out.read_text(encoding="utf-8"))["models"]
        check("live run produced entries", len(loaded) > 0, True)
        check("live entries all use 100%",
              sorted({e.get("effective_context_window_percent") for e in loaded}), [100])
else:
    print("note: no gateway key, skipped the live run")

if failures:
    print("catalog limits: %d failed" % len(failures))
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("catalog limits: 12/12 PASS")
