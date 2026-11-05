#!/usr/bin/env python3
"""codex-cost must attribute cost, not just count tokens.

The first version reported reasoning as 0% of re-sent tokens because its text-extraction
whitelist matched `content: null` before the `summary` list that actually holds the text.
That is the kind of silent zero this test exists to prevent.

Run:  python3 tests/test-cost.py
Exit: 0 pass, 1 fail.
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "bin" / "codex-cost"

loader = importlib.machinery.SourceFileLoader("cost", str(SCRIPT))
spec = importlib.util.spec_from_loader("cost", loader)
cost = importlib.util.module_from_spec(spec)
loader.exec_module(cost)

failures = []


def check(label, got, want):
    if got != want:
        failures.append("%s\n  got:  %r\n  want: %r" % (label, got, want))


# 1. reasoning text lives under summary, content is null. Must not be counted as zero.
reasoning = {"type": "reasoning", "id": "rs_1", "content": None,
             "summary": [{"type": "summary_text", "text": "x" * 400}]}
check("reasoning summary is counted", cost.text_len(reasoning), 400)

# 2. tool output text.
out = {"type": "custom_tool_call_output", "call_id": "c1",
       "output": [{"type": "input_text", "text": "y" * 200}]}
check("tool output is counted", cost.text_len(out), 200)

# 3. bookkeeping keys must not inflate the count.
check("id and call_id ignored", cost.text_len({"type": "message", "id": "z" * 50}), 0)

# 4. images counted structurally, and also when they arrive as base64 text.
check("input_image block detected", cost.images_in({"type": "input_image"}), 1)
check("base64 data url detected", cost.images_in({"text": "x data:image/png;base64,AAA"}), 1)

# 5. end to end on a synthetic session: re-send cost is size x later turns.
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / "sessions").mkdir()
    rows = [
        {"type": "turn_context", "payload": {"model": "m"}},
        {"type": "response_item", "payload": {"type": "message", "role": "user",
                                              "content": [{"type": "input_text", "text": "a" * 4000}]}},
        {"type": "token_usage_record", "payload": {"usage": {"input_tokens": 1000, "output_tokens": 10}}},
        {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "c",
                                              "output": [{"type": "input_text", "text": "b" * 400}]}},
        {"type": "token_usage_record", "payload": {"usage": {"input_tokens": 2000, "output_tokens": 10}}},
        {"type": "token_usage_record", "payload": {"usage": {"input_tokens": 3000, "output_tokens": 10}}},
    ]
    p = tmp / "sessions" / "s.jsonl"
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")

    r = cost.analyse(str(p))
    check("turns", r["turns"], 3)
    check("input summed", r["total_in"], 6000)
    check("output summed", r["total_out"], 30)
    check("model read", r["model"], "m")

    # The user message is re-sent on the three later turns (a usage record counts when it is
    # after the item, because that turn's request carried it); the tool output on two.
    by_kind = {}
    for it in r["items"]:
        by_kind[it["kind"]] = by_kind.get(it["kind"], 0) + it["cost"]
    check("message re-send cost is size x 3 later turns",
          int(by_kind["message"]), int(4000 / 4 * 3))
    check("tool output re-send cost is size x 2 later turns",
          int(by_kind["custom_tool_call_output"]), int(400 / 4 * 2))

# 6. a session with no usage records must be reported as empty, never as zero cost.
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / "sessions").mkdir()
    p = tmp / "sessions" / "empty.jsonl"
    p.write_text(json.dumps({"type": "turn_context", "payload": {"model": "m"}}) + "\n",
                 encoding="utf-8")
    r = cost.analyse(str(p))
    check("empty session has no turns", r["turns"], 0)

if failures:
    print("codex-cost: %d failed" % len(failures))
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("codex-cost: 13/13 PASS")
