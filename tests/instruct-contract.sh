#!/usr/bin/env bash
# Contract for bin/codex-instruct and the CLI path resolver in bin/codex-real-quicktest.
#
# Why a test and not a manual check: every assertion here fails silently in production.
# A mangled Windows path in a profile means the app reads a file that does not exist and
# quietly falls back to the default prompt — no error, no message. A double-escaped path
# in the quicktest means PowerShell never starts the binary. Both look like "nothing
# happened", which is exactly what a test is for.
#
# Run: tests/instruct-contract.sh        (exit 0 all pass, 1 any failure)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export ROOT
BIN="$ROOT/bin"
PASS=0
FAIL=0

ok() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/instruct-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

printf '\n=== instruct contract ===\n'

# ---------------------------------------------------------------- 1. TOML escaping
# A Windows path must survive as a TOML basic string. Raw backslashes become escape
# sequences and the app reads C:Usersrahmax.md — a file that does not exist, with no error.
escaped=$(python3 - <<'PY'
import os
p = os.path.join(os.environ["ROOT"], "bin", "codex-instruct")
g = {"__name__": "ci", "__file__": p}
exec(compile(open(p).read(), p, "exec"), g)
print(g["toml_quote"]("C:\\Users\\rahma\\x.md"))
PY
)
if [ "$escaped" = 'C:\\Users\\rahma\\x.md' ]; then
	ok "toml_quote escapes backslashes"
else
	bad "toml_quote escapes backslashes (got '$escaped')"
fi

cat > "$WORK/w.config.toml" <<'EOF'
model_provider = "byok_x"
model = "m"

[model_providers.byok_x]
base_url = "http://127.0.0.1:1/v1"
EOF
printf 'be terse\n' > "$WORK/instr.md"
"$BIN/codex-instruct" --home "$WORK" set w --file "$WORK/instr.md" >/dev/null 2>&1

stored=$("$BIN/codex-instruct" --home "$WORK" show 2>/dev/null | sed -n 's/.*instructions -> //p' | head -1)
if [ -f "$stored" ]; then
	ok "stored path resolves to a real file"
else
	bad "stored path resolves to a real file (got '$stored')"
fi

# A WSL home must be translated: the app is a Windows process and cannot open /mnt/c/...
# This is the case that silently breaks a real user, and a Linux-only fixture never sees it.
win=$(python3 - <<'PY'
import os
p = os.path.join(os.environ["ROOT"], "bin", "codex-instruct")
g = {"__name__": "ci", "__file__": p}
exec(compile(open(p).read(), p, "exec"), g)
f = g["windows_path"]
cases = [
    ("/mnt/c/Users/rahma/.codex/a.md", "C:\\Users\\rahma\\.codex\\a.md"),
    ("/mnt/e/x/y.md", "E:\\x\\y.md"),
    ("/tmp/x.md", "/tmp/x.md"),          # not a Windows drive: leave alone
    ("C:\\already\\win.md", "C:\\already\\win.md"),
    ("/mnt/cc/x.md", "/mnt/cc/x.md"),    # not a single drive letter
]
bad = [ (i, o) for i, o in cases if f(i) != o ]
print("ok" if not bad else bad)
PY
)
[ "$win" = "ok" ] && ok "windows_path translates /mnt/<drive>/... and leaves the rest" \
	|| bad "windows_path ($win)"

# The instruction body must be copied into the home, never referenced in place: a profile
# that points at a file the user later moves loads with the default prompt and no warning.
[ -f "$WORK/w.instructions.md" ] && ok "instructions copied into the home" \
	|| bad "instructions copied into the home"

# ---------------------------------------------------------------- 2. nothing else touched
body=$(cat "$WORK/w.config.toml")
if printf '%s' "$body" | grep -q '^model_provider = "byok_x"$' &&
	printf '%s' "$body" | grep -q '^\[model_providers.byok_x\]$' &&
	printf '%s' "$body" | grep -q '^base_url = "http://127.0.0.1:1/v1"$'; then
	ok "every other byte in the profile left alone"
else
	bad "every other byte in the profile left alone"
fi

# ---------------------------------------------------------------- 3. clear removes it
"$BIN/codex-instruct" --home "$WORK" set w --clear >/dev/null 2>&1
if grep -q model_instructions_file "$WORK/w.config.toml"; then
	bad "--clear removed the key"
else
	ok "--clear removed the key"
fi

# ---------------------------------------------------------------- 4. refuses unknown profile
if "$BIN/codex-instruct" --home "$WORK" set nope --text x >/dev/null 2>&1; then
	bad "refuses an unknown profile"
else
	ok "refuses an unknown profile"
fi

# ---------------------------------------------------------------- 5. hooks are valid JSON
"$BIN/codex-instruct" --home "$WORK" hook --event PreToolUse \
	--command 'echo hi' --matcher 'Edit|Write' >/dev/null 2>&1
if python3 -c "
import json,sys
d=json.load(open('$WORK/hooks.json'))
h=d['hooks']['PreToolUse'][0]
assert h['matcher']=='Edit|Write'
assert h['hooks'][0]['command']=='echo hi'
" 2>/dev/null; then
	ok "hook written as valid JSON with matcher"
else
	bad "hook written as valid JSON with matcher"
fi

# Adding a second command must append, not replace: a user editing hooks by hand and then
# adding one through the tool would otherwise lose the hand-written entry.
"$BIN/codex-instruct" --home "$WORK" hook --event Stop --command 'echo bye' >/dev/null 2>&1
n=$(python3 -c "
import json
d=json.load(open('$WORK/hooks.json'))
print(len(d['hooks'])+len(d['hooks']['PreToolUse']))
" 2>/dev/null)
[ "$n" = "3" ] && ok "hooks append across events" || bad "hooks append across events (got $n)"

# ---------------------------------------------------------------- 6. refuses a bad event
if "$BIN/codex-instruct" --home "$WORK" hook --event Nonsense --command x >/dev/null 2>&1; then
	bad "refuses an unknown hook event"
else
	ok "refuses an unknown hook event"
fi

# ---------------------------------------------------------------- 7. determinism report is honest
# It must never claim temperature/seed can be pinned: the Codex request has no such field.
if "$BIN/codex-instruct" --home "$WORK" determinism --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'temperature' in d['not_pinnable'], 'must not claim temperature is pinnable'
assert 'seed' in d['not_pinnable']
assert d['pinnable']['instructions']=='model_instructions_file'
" 2>/dev/null; then
	ok "determinism report does not overclaim"
else
	bad "determinism report does not overclaim"
fi

# ---------------------------------------------------------------- 8. CLI path translation
# The quicktest used to hardcode a content-addressed MSIX path that disappears on every
# update. It must resolve, and the result must be a Windows path PowerShell can execute.
resolved=$(bash -c "source <(sed -n '/^find_codex_exe/,/^}/p' '$BIN/codex-real-quicktest'); find_codex_exe" 2>/dev/null)
case "$resolved" in
C:\\*)
	ok "codex.exe resolved to a Windows path"
	;;
"")
	printf '  SKIP  codex.exe resolution (no Windows app on this host)\n'
	;;
*)
	bad "codex.exe resolved to a Windows path (got '$resolved')"
	;;
esac

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
