#!/usr/bin/env bash
# Selftest for tests/shortcut-contract.sh, driven by `tests/shortcut-contract.sh --selftest`.
#
# Fixtures are real .lnk files written byte by byte, so the parser is exercised, not stubbed.
# Every Windows path in them is a \\wsl.localhost\Ubuntu\... UNC of a temp tree: that maps to
# the same absolute path on this host, so the run needs no Windows and touches no desktop.
set -uo pipefail

# This file is sourced by tests/shortcut-contract.sh --selftest, which supplies $WORK.
# Run directly it would die on `$WORK: unbound variable`, which reads like a broken repo.
# Say what it needs instead, and point at the command that works.
if [ -z "${WORK:-}" ]; then
	printf 'this selftest needs $WORK from its parent.\n' >&2
	printf 'run instead:  tests/shortcut-contract.sh --selftest\n' >&2
	exit 2
fi

FIX="$WORK/fixtures"
FAKE="$WORK/fakec"          # a fake C: tree: powershell.exe and one real .ico live here
DISTRO=Ubuntu

# UNC form of a posix path, which win_to_posix turns back into the same posix path.
unc() { printf '\\\\wsl.localhost\\%s%s' "$DISTRO" "$(printf '%s' "$1" | tr '/' '\\')"; }

mkdir -p "$FAKE/Windows/System32/WindowsPowerShell/v1.0" "$FAKE/icons" "$FAKE/Desktop"
: >"$FAKE/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
printf 'ico' >"$FAKE/icons/chatgpt-app-dark.ico"
printf '# a stale Desktop copy of the launcher\n' >"$FAKE/Desktop/codex-launch.ps1"

PW=$(unc "$FAKE/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")
ICO=$(unc "$FAKE/icons/chatgpt-app-dark.ico")
DESKTOP_COPY=$(unc "$FAKE/Desktop/codex-launch.ps1")
REPO_SCRIPT=$(unc "$(cd -- "$REPO" && pwd -P)/scripts/codex-launch.ps1")
PINNED='C:\Program Files\WindowsApps\OpenAI.Codex_26.1027.3384.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'

# mklnk <out> <target> <args> <icon> [workdir]
mklnk() {
	python3 - "$@" <<'PY'
import struct, sys

out, target, args, icon = sys.argv[1:5]
workdir = sys.argv[5] if len(sys.argv) > 5 else ''
name = 'Codex Desktop fixture'

FLAG_LINKINFO, FLAG_NAME, FLAG_RELPATH, FLAG_WORKDIR = 0x2, 0x4, 0x8, 0x10
FLAG_ARGS, FLAG_ICON, FLAG_UNICODE = 0x20, 0x40, 0x80
flags = FLAG_LINKINFO | FLAG_UNICODE
if name: flags |= FLAG_NAME
if workdir: flags |= FLAG_WORKDIR
if args: flags |= FLAG_ARGS
if icon: flags |= FLAG_ICON

volid = struct.pack('<IIII', 0x11, 3, 0x12345678, 0x10) + b'C:\\\x00'
ansi_base = b'\x00'
ansi_suff = b'\x00'
wide_base = target.encode('utf-16-le') + b'\x00\x00'
wide_suff = b'\x00\x00'

hdr = 0x24
# The struct is 8 dwords + 2 unicode offsets = 0x28 bytes, but HeaderSize stays 0x24: the
# unicode offset pair is what pushes it past the older 0x1C header.
struct_len = 0x28
vol_off = struct_len
lbp_off = vol_off + len(volid)
cnrl_off = 0
cps_off = lbp_off + len(ansi_base)
lbp_u_off = cps_off + len(ansi_suff)
cps_u_off = lbp_u_off + len(wide_base)
body = volid + ansi_base + ansi_suff + wide_base + wide_suff
li = struct.pack('<IIIIIIII', struct_len + len(body), hdr, 1, vol_off, lbp_off, cnrl_off, cps_off, 0) + \
     struct.pack('<II', lbp_u_off, cps_u_off) + body

strings = b''
for value in (name, workdir, args, icon):
    if value:
        data = value.encode('utf-16-le')
        strings += struct.pack('<H', len(data) // 2) + data

header = struct.pack('<I', 0x4C) + bytes.fromhex('0114020000000000c000000000000046') + \
         struct.pack('<II', flags, 0x20) + b'\x00' * 24 + struct.pack('<Iii', 0, 0, 1) + \
         struct.pack('<HHII', 0, 0, 0, 0)
assert len(header) == 76, len(header)
open(out, 'wb').write(header + li + strings)
PY
}

# run <fixture-dir> -> stdout+rc of the harness, posix-only, repo pinned, no Windows.
run() {
	SHORTCUT_NO_WINDOWS=1 bash "$HERE/shortcut-contract.sh" --dir "$1" --repo "$REPO" 2>&1
}

expect_fail() { # expect_fail <label> <fixture> <needle> [repo]
	local out rc
	out=$(SHORTCUT_NO_WINDOWS=1 bash "$HERE/shortcut-contract.sh" --dir "$2" --repo "${4:-$REPO}" 2>&1)
	rc=$?
	if [ $rc -eq 1 ] && grep -qF -- "$3" <<<"$out"; then
		printf 'ok   %s\n' "$1"
		SELFTEST_PASS=$((SELFTEST_PASS + 1))
	else
		printf 'FAIL %s — rc=$rc, wanted exit 1 with "%s"\n' "$1" "$3"
		printf '%s\n' "$out" | sed 's/^/     /'
		SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	fi
}

SELFTEST_PASS=0
SELFTEST_FAIL=0
printf 'shortcut-contract selftest — no Windows, fixtures under %s\n\n' "$FIX"

# ---- control: a correct shortcut must pass, or the negative cases prove nothing.
mkdir -p "$FIX/good"
mklnk "$FIX/good/Codex.lnk" "$PW" "-NoProfile -File \"$REPO_SCRIPT\" -Mode real" "$ICO"
out=$(run "$FIX/good")
rc=$?
if [ $rc -eq 0 ] && ! grep -q '^FAIL' <<<"$out" && ! grep -q '^UNPROVEN' <<<"$out"; then
	printf 'ok   control: a correct shortcut passes clean\n'
	SELFTEST_PASS=$((SELFTEST_PASS + 1))
else
	printf 'FAIL control: a correct shortcut should pass\n'
	printf '%s\n' "$out" | sed 's/^/     /'
	SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
fi

# ---- negative 1: IconLocation points at a file that is not there.
mkdir -p "$FIX/icon-missing"
mklnk "$FIX/icon-missing/Codex.lnk" "$PW" "-File \"$REPO_SCRIPT\" -Mode real" "$(unc "$FAKE/icons/gone.ico")"
expect_fail 'negative: icon file missing fails R3' "$FIX/icon-missing" 'R3 icon file does not exist'

# ---- negative 2: a version-pinned MSIX path, exactly how all four rotted.
mkdir -p "$FIX/msix-pinned"
mklnk "$FIX/msix-pinned/Codex.lnk" "$PW" "-File \"$REPO_SCRIPT\" -Mode real" "$PINNED,0"
expect_fail 'negative: version-pinned MSIX path fails R4' "$FIX/msix-pinned" 'R4 version-pinned MSIX path'

# ---- negative 3: runs a copy of the launcher that lives on the Desktop.
mkdir -p "$FIX/desktop-copy"
mklnk "$FIX/desktop-copy/Codex.lnk" "$PW" "-File \"$DESKTOP_COPY\" -Mode real" "$ICO"
expect_fail 'negative: Desktop-copy script fails R2' "$FIX/desktop-copy" 'R2 runs a Desktop copy'

# ---- negative 4: two shortcuts claiming the same script and mode.
mkdir -p "$FIX/duplicate"
mklnk "$FIX/duplicate/Codex.lnk" "$PW" "-File \"$REPO_SCRIPT\" -Mode clone" "$ICO"
mklnk "$FIX/duplicate/Codex Clone.lnk" "$PW" "-File \"$REPO_SCRIPT\" -Mode clone" "$ICO"
expect_fail 'negative: duplicate script+mode fails R6' "$FIX/duplicate" 'R6 duplicate shortcuts for mode'

# ---- negative 5: no -Mode at all, so the launcher silently runs in real mode.
mkdir -p "$FIX/no-mode"
mklnk "$FIX/no-mode/Codex.lnk" "$PW" "-File \"$REPO_SCRIPT\"" "$ICO"
expect_fail 'negative: missing -Mode fails R5' "$FIX/no-mode" 'R5 no -Mode argument'

# ---- negative 6: a launcher inside the repo but on a different branch — synced path, stale bytes.
# Two worktrees of one temp repo: same git common dir, different launcher content. That is the
# real shape of "the shortcut is fine, the branch it points at is not".
DRIFT="$WORK/driftrepo"
mkdir -p "$DRIFT/main/scripts"
printf '# launcher as merged\n' >"$DRIFT/main/scripts/codex-launch.ps1"
git -C "$DRIFT/main" init -q
git -C "$DRIFT/main" -c user.email=t@t -c user.name=t add -A
git -C "$DRIFT/main" -c user.email=t@t -c user.name=t commit -qm one
git -C "$DRIFT/main" worktree add -q --detach "$DRIFT/stale" 2>/dev/null
printf '# launcher on the old branch\n' >"$DRIFT/stale/scripts/codex-launch.ps1"
mkdir -p "$FIX/drift"
mklnk "$FIX/drift/Codex.lnk" "$PW" "-File \"$(unc "$DRIFT/stale/scripts/codex-launch.ps1")\" -Mode real" "$ICO"
expect_fail 'negative: stale launcher bytes fail R2 drift' "$FIX/drift" 'R2 launcher drift' "$DRIFT/main"

printf '\nselftest: %d passed, %d failed\n' "$SELFTEST_PASS" "$SELFTEST_FAIL"
[ "$SELFTEST_FAIL" -eq 0 ] || exit 1
exit 0
