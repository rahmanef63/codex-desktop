#!/usr/bin/env bash
# Contract harness for the Desktop shortcuts that launch this repo.
#
#   tests/shortcut-contract.sh                      # check the real Desktop
#   tests/shortcut-contract.sh --dir <path>         # check a directory of .lnk files
#   tests/shortcut-contract.sh --repo <path>        # pin the expected checkout
#   tests/shortcut-contract.sh --selftest           # prove every rule can still fail
#
# Exit: 0 every shortcut passes, 1 at least one FAIL, 2 no FAIL but something could not be
# proven (printed as UNPROVEN — never as PASS).
#
# Why this exists: four shortcuts rotted in exactly the way CONTRACT.md warns about. The MSIX
# install path moved (26.1027.3384.0 -> 26.1029.7803.0), the icons went with it, and two of the
# four ran a copy of codex-launch.ps1 sitting on the Desktop while the repo's copy moved on.
# Reading a .lnk needs no Windows: the binary format is parsed directly, so this runs on Linux
# and macOS too. Only "does this Windows path exist" needs powershell.exe.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_REPO=$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || printf '%s' "$HERE/..")

DIR=''
REPO=''
SELFTEST=0
while [ $# -gt 0 ]; do
	case "$1" in
	--dir) DIR=${2:-}; shift 2 ;;
	--dir=*) DIR=${1#*=}; shift ;;
	--repo) REPO=${2:-}; shift 2 ;;
	--repo=*) REPO=${1#*=}; shift ;;
	--selftest) SELFTEST=1; shift ;;
	-h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
	esac
done
REPO=${REPO:-$DEFAULT_REPO}

PASS=0
FAIL=0
UNPROVEN=0
ok() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
no() {
	printf 'FAIL  %s\n' "$1"
	FAIL=$((FAIL + 1))
}
unk() {
	printf 'UNPROVEN  %s\n' "$1"
	UNPROVEN=$((UNPROVEN + 1))
}
info() { printf 'INFO  %s\n' "$1"; }

# ------------------------------------------------------------------ .lnk parsing (no Windows)
# Emits TAB-separated key\tvalue pairs. WScript.Shell would be simpler but it only exists on
# Windows, and this must run where the repo runs.
lnk_parse() {
	python3 - "$1" <<'PY'
import struct, sys

path = sys.argv[1]
d = open(path, 'rb').read()
if len(d) < 76 or struct.unpack_from('<I', d, 0)[0] != 0x4C:
    print('error\tnot a shell link (bad header size)')
    raise SystemExit(0)

flags, = struct.unpack_from('<I', d, 20)
off = 76
try:
    if flags & 0x1:                       # HasLinkTargetIDList
        n, = struct.unpack_from('<H', d, off)
        off += 2 + n
    target = ''
    if flags & 0x2:                       # HasLinkInfo
        size, hdr, li_flags = struct.unpack_from('<3I', d, off)
        vol_off, lbp_off, cnrl_off, cps_off = struct.unpack_from('<4I', d, off + 12)
        lbp_u = cps_u = 0
        if hdr >= 0x24:
            lbp_u, cps_u = struct.unpack_from('<2I', d, off + 28)

        def ansi(o):
            if not o:
                return ''
            return d[off + o:d.index(b'\0', off + o)].decode('latin-1')

        def wide(o):
            if not o:
                return ''
            # UTF-16 has NUL bytes between characters, so the terminator is a double NUL at an
            # even offset — not the first \0 byte.
            e = off + o
            while e + 1 < len(d):
                if d[e] == 0 and d[e + 1] == 0:
                    break
                e += 2
            return d[off + o:e].decode('utf-16-le', 'replace')

        if li_flags & 1:                  # VolumeIDAndLocalBasePath
            target = (wide(lbp_u) if lbp_u else ansi(lbp_off)) + (wide(cps_u) if cps_u else ansi(cps_off))
        elif li_flags & 2:                # CommonNetworkRelativeLinkAndPathSuffix
            target = ansi(cps_off)
        off += size

    names = {0x4: 'name', 0x8: 'relative', 0x10: 'workdir', 0x20: 'args', 0x40: 'icon'}
    if flags & 0x80:                      # IsUnicode: every string is counted UTF-16
        for bit, key in names.items():
            if flags & bit:
                c, = struct.unpack_from('<H', d, off)
                off += 2
                print('%s\t%s' % (key, d[off:off + 2 * c].decode('utf-16-le', 'replace')))
                off += 2 * c
    else:
        for bit, key in names.items():
            if flags & bit:
                e = d.index(b'\0', off)
                print('%s\t%s' % (key, d[off:e].decode('latin-1')))
                off = e + 1
    print('target\t%s' % target)
except (struct.error, IndexError, ValueError) as exc:
    print('error\ttruncated or malformed: %s' % exc)
PY
}

field() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }

# ------------------------------------------------------------------ Windows path questions
PS=''
# SHORTCUT_NO_WINDOWS=1 forces the posix-only path: no powershell, every Windows path answered
# from the WSL/mount view. Used by --selftest so fixtures never touch the real machine.
if [ "${SHORTCUT_NO_WINDOWS:-0}" != 1 ]; then
	command -v powershell.exe >/dev/null 2>&1 && PS=powershell.exe
	[ -z "$PS" ] && command -v pwsh >/dev/null 2>&1 && PS=pwsh
fi

# C:\x\y and \\wsl.localhost\<distro>\x\y -> a path this shell can stat. Empty when the path
# cannot be expressed locally (another drive, a network share).
win_to_posix() {
	local p=$1 rest
	# \\wsl.localhost\<distro>\... and \\wsl$\<distro>\... are the same tree, by UNC.
	if printf '%s' "$p" | grep -qiE '^\\\\+(wsl\.localhost|wsl\$)\\'; then
		rest=$(printf '%s' "$p" | sed -E 's#^\\\\+([Ww][Ss][Ll]\.localhost|wsl\$)\\#\\#' | sed -E 's#^\\[^\\]+\\##' | tr '\\' '/')
		printf '/%s' "${rest#/}"
		return 0
	fi
	if printf '%s' "$p" | grep -qE '^[A-Za-z]:[\\/]'; then
		local drive=${p:0:1}
		drive=$(printf '%s' "$drive" | tr 'A-Z' 'a-z')
		rest=$(printf '%s' "${p:2}" | tr '\\' '/')
		printf '/mnt/%s/%s' "$drive" "${rest#/}"
		return 0
	fi
	return 1
}

# exists <windows-path> -> yes | no | unknown
# "unknown" is the only honest answer when neither Windows nor a readable parent directory can
# say. WindowsApps is ACL-locked, so on a host without powershell every MSIX path lands there.
# Cached in a file rather than an associative array: macOS ships bash 3.2, which has none.
exists() {
	local win=$1 answer=unknown hit
	if [ -n "${WORK:-}" ] && [ -f "$WORK/exists.cache" ]; then
		# ENVIRON, not -v: -v interprets backslash escapes, so a Windows path like \Program
		# turns into a truncated `P` and the cache silently misses.
		hit=$(P="$win" awk -F'\t' '$2 == ENVIRON["P"] { print $1; exit }' "$WORK/exists.cache")
		[ -n "$hit" ] && {
			printf '%s' "$hit"
			return
		}
	fi
	if [ -n "$PS" ]; then
		local out
		out=$("$PS" -NoProfile -NonInteractive -Command \
			"if (Test-Path -LiteralPath '$(printf '%s' "$win" | sed "s/'/''/g")') { 'yes' } else { 'no' }" 2>/dev/null |
			tr -d '\r' | tail -1)
		case "$out" in
		yes | no) answer=$out ;;
		esac
	fi
	if [ "$answer" = unknown ]; then
		local posix parent
		if posix=$(win_to_posix "$win"); then
			if [ -e "$posix" ]; then
				answer=yes
			else
				parent=$(dirname -- "$posix")
				# Absence is only a fact when the directory holding it is inspectable.
				if [ -d "$parent" ] && [ -r "$parent" ] && [ -x "$parent" ]; then answer=no; fi
			fi
		fi
	fi
	[ -n "${WORK:-}" ] && printf '%s\t%s\n' "$answer" "$win" >>"$WORK/exists.cache"
	printf '%s' "$answer"
}

# ------------------------------------------------------------------ rules
# Each rule exists because breaking it cost real time. See CONTRACT.md and PROGRESS.md.
#   R1 target   — a stale powershell.exe copy launches a different interpreter than the one
#                 the repo tested; a missing target launches nothing at all.
#   R2 script   — a Desktop copy of codex-launch.ps1 silently diverges from the repo, so a fix
#                 lands in git and the shortcut keeps running the old file.
#   R3 icon     — an icon pointing at a moved file renders as the generic white page. This is
#                 the visible symptom of the MSIX version bump, not a cosmetic issue.
#   R4 msix-pin — no path may embed OpenAI.Codex_<version>_: Store updates move that folder, so
#                 every pinned path rots on the next update. Resolve it at run time instead.
#   R5 mode     — the launcher's only required argument. Absent or mistyped, the shortcut
#                 inherits whatever default the launcher happens to carry (clone since
#                 2026-11-05), so the click no longer says which account it opens.
#   R6 duplicate— two shortcuts for the same script+mode: one of them is unmaintained, and
#                 which one the user clicks is luck.

check_shortcut() { # check_shortcut <file>
	local file=$1 base parsed target args icon workdir script mode_vals
	base=$(basename -- "$file")
	parsed=$(lnk_parse "$file")

	if [ -n "$(field "$parsed" error)" ]; then
		no "$base: R0 unreadable — $(field "$parsed" error)"
		return 1
	fi
	target=$(field "$parsed" target)
	args=$(field "$parsed" args)
	icon=$(field "$parsed" icon)
	workdir=$(field "$parsed" workdir)

	# ---- R1: the target is the expected program and it exists right now.
	local tbase tbase_l
	tbase=$(printf '%s' "$target" | tr '\\' '/' | awk -F/ '{ print $NF }')
	tbase_l=$(printf '%s' "$tbase" | tr 'A-Z' 'a-z')
	if [ -z "$target" ]; then
		no "$base: R1 no target path in the link"
	elif [ "$tbase_l" != 'powershell.exe' ]; then
		no "$base: R1 target is '$tbase', expected powershell.exe"
	elif [ "${target:0:9}" = 'C:\Users\' ] || [ "${target:0:9}" = 'C:\users\' ]; then
		no "$base: R1 target is a copy under the user profile ($target), expected the system powershell.exe"
	else
		case "$(exists "$target")" in
		yes) ok "$base: R1 target exists — $target" ;;
		no) no "$base: R1 target does not exist — $target" ;;
		*) unk "$base: R1 target existence unproven (no powershell, unreadable parent) — $target" ;;
		esac
	fi

	# ---- R5: exactly one -Mode, and it is real or clone.
	mode_vals=$(printf '%s' "$args" | tr 'A-Z' 'a-z' | grep -o -- '-mode[ :=]\+[a-z0-9]*' | sed 's/^.*[ :=]//' | tr '\n' ' ')
	mode_vals=$(printf '%s' "$mode_vals" | sed 's/ *$//')
	case "$mode_vals" in
	real | clone) ok "$base: R5 mode is '$mode_vals'" ;;
	'') no "$base: R5 no -Mode argument (the launcher's own default would decide)" ;;
	*' '*) no "$base: R5 more than one -Mode argument: $mode_vals" ;;
	*) no "$base: R5 mode '$mode_vals' is not real or clone" ;;
	esac

	# ---- R2: the -File it runs is the repo's launcher, not a Desktop copy.
	# Parsed in python: the flag is case-insensitive, may sit anywhere in the line, and the path
	# may be quoted with spaces. A leading-space sed pattern silently skipped `-File "x"` first.
	script=$(printf '%s' "$args" | tr -d '\r' | python3 -c '
import re, sys
a = sys.stdin.read()
m = re.search(r"-{1,2}file\s+(\"[^\"]*\"|\S+)", a, re.I)
print(m.group(1).strip("\"") if m else "")
')
	if [ -z "$script" ]; then
		no "$base: R2 no -File argument; the link must run scripts/codex-launch.ps1"
	else
		local spath
		if ! spath=$(win_to_posix "$script"); then
			unk "$base: R2 cannot map '$script' to a local path on this host"
		elif [ "$(basename -- "$spath")" != 'codex-launch.ps1' ]; then
			no "$base: R2 runs '$spath', expected scripts/codex-launch.ps1"
		elif [ ! -f "$spath" ]; then
			no "$base: R2 launcher does not exist — $spath"
		elif printf '%s' "$spath" | grep -qi '/Desktop/'; then
			no "$base: R2 runs a Desktop copy — $spath (the repo's copy is what gets fixed)"
		else
			local toplevel common want
			toplevel=$(git -C "$(dirname -- "$spath")" rev-parse --show-toplevel 2>/dev/null || true)
			# Any worktree of the same repo is the same repo: compare the shared git dir, not
			# the checkout path, or a fix tested in a worktree looks like a foreign copy.
			common=$(git -C "$(dirname -- "$spath")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
			want=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
			if [ -z "$toplevel" ]; then
				no "$base: R2 launcher is not inside a git work tree — $spath (a copy nobody fixes)"
			elif [ -n "$common" ] && [ "$common" = "$want" ]; then
				# Same repo is not the same file: another worktree can sit on another branch, so
				# a fix merged here would not reach the shortcut. Compare bytes.
				if cmp -s "$spath" "$REPO/scripts/codex-launch.ps1"; then
					ok "$base: R2 runs the repo launcher — $spath"
				else
					no "$base: R2 launcher drift — $spath differs from $REPO/scripts/codex-launch.ps1 (shortcut runs stale code)"
				fi
			else
				no "$base: R2 launcher is in $toplevel, not a checkout of the repo under test ($(cd -- "$REPO" && pwd -P))"
			fi
		fi
	fi

	# ---- R3: the icon file exists right now.
	local ico=${icon}
	ico=$(printf '%s' "$ico" | sed 's/,-\?[0-9]\+$//')
	if [ -z "$ico" ]; then
		info "$base: R3 no IconLocation; the shell inherits the target's icon"
	elif [ "$ico" = "$target" ]; then
		ok "$base: R3 icon is the target itself — $ico"
	else
		case "$(exists "$ico")" in
		yes) ok "$base: R3 icon exists — $ico" ;;
		no) no "$base: R3 icon file does not exist — $ico" ;;
		*) unk "$base: R3 icon existence unproven (no powershell, unreadable parent) — $ico" ;;
		esac
	fi

	# ---- R4: no version-pinned MSIX folder anywhere in the link.
	local pinned='' f v
	for f in "target:$target" "args:$args" "icon:$icon" "workdir:$workdir"; do
		v=${f#*:}
		if printf '%s' "$v" | grep -q 'OpenAI\.Codex_[0-9]'; then
			pinned="${pinned:+$pinned; }${f%%:*} $(printf '%s' "$v" | grep -o 'OpenAI\.Codex_[0-9][^\\"]*' | head -1)"
		fi
	done
	if [ -n "$pinned" ]; then
		no "$base: R4 version-pinned MSIX path — $pinned (moves on every Store update)"
	else
		ok "$base: R4 no version-pinned MSIX path"
	fi

	printf '%s\t%s\t%s\n' "$script" "${mode_vals%% *}" "$base" >>"$WORK/pairs.tsv"
	return 0
}

# ------------------------------------------------------------------ run
WORK=$(mktemp -d "${TMPDIR:-/tmp}/shortcut-contract.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [ "$SELFTEST" -eq 1 ]; then
	# shellcheck source=/dev/null
	. "$HERE/shortcut-contract-selftest.sh"
	exit $?
fi

if [ -z "$DIR" ]; then
	if [ -n "$PS" ]; then
		DIR=$("$PS" -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("Desktop")' 2>/dev/null | tr -d '\r' | tail -1)
		DIR=$(win_to_posix "$DIR" 2>/dev/null || true)
	fi
	[ -n "$DIR" ] && [ -d "$DIR" ] || DIR=''
	# `All Users/Desktop` and `Public/Desktop` hold shortcuts too, so "first directory with .lnk
	# files" picks a machine-wide folder nobody's Codex shortcut lives in. Prefer the folder that
	# already has a Codex shortcut, then any real user profile (one with AppData).
	best='' best_score=-1
	for d in ${DIR:+"$DIR"} "${USERPROFILE_WSL:-}/Desktop" "/mnt/c/Users/${WINUSER:-${USER:-}}/Desktop" /mnt/c/Users/*/Desktop; do
		[ -d "$d" ] || continue
		score=0
		ls "$d"/[Cc]odex*.lnk >/dev/null 2>&1 && score=$((score + 2))
		[ -d "$(dirname -- "$d")/AppData" ] && score=$((score + 1))
		[ "$score" -gt "$best_score" ] && best=$d && best_score=$score
	done
	DIR=$best
	[ -z "$DIR" ] && {
		printf 'cannot find the Windows Desktop; pass --dir <path>\n' >&2
		exit 64
	}
fi
[ -d "$DIR" ] || {
	printf 'not a directory: %s\n' "$DIR" >&2
	exit 64
}

printf 'shortcut contract — desktop: %s\n' "$DIR"
printf '                    repo:    %s\n' "$(cd -- "$REPO" 2>/dev/null && pwd -P || printf '%s' "$REPO")"
printf '                    windows: %s\n\n' "${PS:-none (path existence falls back to posix)}"

: >"$WORK/pairs.tsv"
count=0
for f in "$DIR"/*.lnk; do
	[ -e "$f" ] || continue
	parsed=$(lnk_parse "$f")
	# Ours are the ones that run the launcher, plus anything already named after Codex.
	if ! printf '%s' "$(field "$parsed" args)" | grep -qi 'codex-launch'; then
		case "$(basename -- "$f")" in
		[Cc]odex*) ;;
		*) continue ;;
		esac
	fi
	count=$((count + 1))
	check_shortcut "$f"
done

if [ "$count" -eq 0 ]; then
	printf 'FAIL  no Codex shortcut in %s\n' "$DIR"
	FAIL=$((FAIL + 1))
fi

# ---- R6: no duplicate script+mode pair.
dups=$(awk -F'\t' '{ print $1 "\t" $2 }' "$WORK/pairs.tsv" | sort | uniq -d)
if [ -n "$dups" ]; then
	while IFS=$'\t' read -r dscript dmode; do
		names=$(awk -F'\t' -v s="$dscript" -v m="$dmode" '$1 == s && $2 == m { print $3 }' "$WORK/pairs.tsv" | paste -sd', ')
		no "R6 duplicate shortcuts for mode '$dmode': $names"
	done <<<"$dups"
else
	[ "$count" -gt 0 ] && ok "R6 no duplicate script+mode pairs ($count shortcut(s))"
fi

# clone only is the intended shape (the real app is named ChatGPT in the Start Menu), so a
# missing mode is reported, never failed. A shortcut for 'real' would be the duplication this
# repo already cleaned up once.
for m in clone real; do
	grep -q "	$m	" "$WORK/pairs.tsv" || info "no shortcut for mode '$m'"
done

printf '\n%d passed, %d failed, %d unproven\n' "$PASS" "$FAIL" "$UNPROVEN"
[ "$FAIL" -eq 0 ] || exit 1
[ "$UNPROVEN" -eq 0 ] || exit 2
exit 0
