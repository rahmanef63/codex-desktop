#!/usr/bin/env bash
# Tests for bin/isolation-check's platform layer. No Windows, no PowerShell, no real account:
# every case builds a fake trio of homes under /tmp and drives the script with explicit env.
#
#   tests/isolation-check.sh            # all cases, exit non-zero on any failure
#
# The last case is the one that matters: a missing home must be an error, never a pass. A check
# that reads absent as "nothing changed" would report a clean run while verifying nothing.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
CHECK="$HERE/../bin/isolation-check"

PASS=0
FAIL=0
ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() {
	printf 'FAIL %s\n' "$1"
	FAIL=$((FAIL + 1))
	[ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'
}

WORK=${TMPDIR:-/tmp}/isolation-check-tests.$$
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# A fake machine: three homes with the shape the real ones have.
make_homes() { # make_homes <dir>
	local root="$1"
	mkdir -p "$root/.codex/sessions/2026" "$root/.codex-clone/sessions" "$root/.codex-probe/sessions"
	printf 'model = "real"\n' >"$root/.codex/config.toml"
	printf '{"token":"not-a-real-token"}\n' >"$root/.codex/auth.json"
	printf 'rollout\n' >"$root/.codex/sessions/2026/one.jsonl"
	printf 'rollout\n' >"$root/.codex-clone/sessions/one.jsonl"
	mkdir -p "$root/.codex-clone/plugins/cache/openai-bundled/chrome/26.1"
	# The one link CONTRACT §1 explicitly allows: inside the clone home.
	ln -sfn "$root/.codex-clone/plugins/cache/openai-bundled/chrome/26.1" \
		"$root/.codex-clone/plugins/cache/openai-bundled/chrome/latest"
}

# run <root> <args...> — the script is always driven with explicit homes and a snapshot outside
# them, on this host's real platform layer (linux here), never on the WSL/powershell path.
run() {
	local root="$1"
	shift
	CODEX_REAL_HOME="$root/.codex" \
		CODEX_CLONE_HOME="$root/.codex-clone" \
		CODEX_PROBE_HOME="$root/.codex-probe" \
		SNAPSHOT_FILE="$root.snapshot.tsv" \
		ISOLATION_PLATFORM="${ISOLATION_PLATFORM:-linux}" \
		bash "$CHECK" "$@" 2>&1
}

# -------------------------------------------------------------------------------- case 1
case_clean() {
	local root="$WORK/clean"
	make_homes "$root"
	local out rc
	out=$(run "$root" snapshot) || { no "clean: snapshot failed" "$out"; return; }
	out=$(run "$root" verify)
	rc=$?
	if [ $rc -eq 0 ] && ! grep -q '  FAIL' <<<"$out" && grep -q 'PASS  clone home: 1 links, all inside' <<<"$out"; then
		ok "clean tree passes ($(grep -c '  PASS' <<<"$out") invariants, $(grep -c '  INFO' <<<"$out") informational)"
	else
		no "clean tree should pass" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 2
case_escape() {
	local root="$WORK/escape"
	make_homes "$root"
	run "$root" snapshot >/dev/null
	# A link pointing out of the clone home, at the real account's config.
	ln -sfn "$root/.codex/config.toml" "$root/.codex-clone/escaped.toml"
	local out rc
	out=$(run "$root" verify)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'FAIL  clone home has 1 link(s) pointing out of it' <<<"$out" \
		&& grep -q 'escaped.toml' <<<"$out"; then
		ok "symlink out of the clone home fails"
	else
		no "symlink out of the clone home should fail" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 3
case_session_in_real() {
	local root="$WORK/session"
	make_homes "$root"
	run "$root" snapshot >/dev/null
	# A clone session landing in the real account's history — the failure that started this.
	printf 'leaked rollout\n' >"$root/.codex/sessions/2026/leaked.jsonl"
	local out rc
	out=$(run "$root" verify)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'FAIL  real home sessions unchanged — was 1, now 2' <<<"$out"; then
		ok "session appearing in the real home fails"
	else
		no "session in the real home should fail" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 4
case_config_byte() {
	local root="$WORK/config"
	make_homes "$root"
	run "$root" snapshot >/dev/null
	# Same length, different byte: a size check would miss this, a hash cannot.
	printf 'model = "reaL"\n' >"$root/.codex/config.toml"
	local out rc
	out=$(run "$root" verify)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'FAIL  real config.toml unchanged' <<<"$out"; then
		ok "config byte change fails"
	else
		no "config byte change should fail" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 5
case_missing_home() {
	local root="$WORK/missing"
	make_homes "$root"
	run "$root" snapshot >/dev/null
	# Real home gone entirely: absence must never read as isolation.
	rm -rf "$root/.codex"
	local out rc
	out=$(run "$root" verify)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'FAIL  real home missing' <<<"$out"; then
		ok "missing real home is an error, not a pass"
	else
		no "missing real home should be an error" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 6
# A defaulted home that is not a Codex home must be refused rather than silently verified.
case_wrong_default() {
	local root="$WORK/wrongdefault"
	mkdir -p "$root/not-a-codex-home/.codex"
	local out rc
	# A $HOME with no CODEX_HOME and no config.toml/auth.json/sessions: the default resolves to
	# a directory the app does not use, so the script must refuse rather than verify nothing.
	out=$(HOME="$root/not-a-codex-home" CODEX_REAL_HOME="" USERPROFILE_WSL="" \
		CODEX_CLONE_HOME="$root/.codex-clone" SNAPSHOT_FILE="$root/s.tsv" ISOLATION_PLATFORM=linux \
		bash "$CHECK" snapshot 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'not a Codex home on this machine' <<<"$out"; then
		ok "defaulted home with no Codex shape is refused"
	else
		no "defaulted non-Codex home should be refused" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 7
# The snapshot file may not be aimed inside a home it protects (CONTRACT §13, existing guard).
case_guard() {
	local root="$WORK/guard"
	make_homes "$root"
	local out rc
	out=$(CODEX_REAL_HOME="$root/.codex" CODEX_CLONE_HOME="$root/.codex-clone" \
		CODEX_PROBE_HOME="$root/.codex-probe" SNAPSHOT_FILE="$root/.codex/canary.tsv" \
		ISOLATION_PLATFORM=linux bash "$CHECK" snapshot 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'resolves inside a protected home' <<<"$out" \
		&& [ ! -e "$root/.codex/canary.tsv" ]; then
		ok "snapshot path inside a protected home is refused, and nothing is written"
	else
		no "snapshot guard should refuse and write nothing" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 8
# The platform layer itself: every dependency resolves on this host.
case_layer() {
	local out rc
	# shellcheck disable=SC1090
	out=$(ISOLATION_PLATFORM="${ISOLATION_PLATFORM:-linux}" bash -c '
		set -uo pipefail
		eval "$(sed -n "/^real_path()/,/^}/p" "'"$CHECK"'")"
		eval "$(sed -n "/^file_hash()/,/^}/p" "'"$CHECK"'")"
		eval "$(sed -n "/^link_scan()/,/^}/p" "'"$CHECK"'")"
		PLATFORM=${ISOLATION_PLATFORM}
		p=$(real_path /tmp/../tmp/x/../y) || exit 1
		[ "$p" = /tmp/y ] || { echo "real_path gave $p"; exit 1; }
		h1=$(file_hash /etc/hostname) || exit 1
		[ -n "$h1" ] && [ "$h1" = "$(file_hash /etc/hostname)" ] || { echo "file_hash unstable"; exit 1; }
		file_hash /nonexistent && { echo "file_hash accepted a missing file"; exit 1; }
		mkdir -p /tmp/isc-layer.$$/in
		ln -sfn /tmp/isc-layer.$$/in /tmp/isc-layer.$$/ok
		ln -sfn /etc/hostname /tmp/isc-layer.$$/out
		scan=$(link_scan /tmp/isc-layer.$$) || { rm -rf /tmp/isc-layer.$$; exit 1; }
		rm -rf /tmp/isc-layer.$$
		grep -q "inside.*ok" <<<"$scan" || { echo "inside link not detected: $scan"; exit 1; }
		grep -q "escape.*out" <<<"$scan" || { echo "escaping link not detected: $scan"; exit 1; }
		link_scan /nonexistent && { echo "link_scan accepted a missing root"; exit 1; }
		echo LAYER-OK
	' 2>&1)
	rc=$?
	if [ $rc -eq 0 ] && grep -q LAYER-OK <<<"$out"; then
		ok "platform layer: real_path, file_hash, link_scan ($PLATFORM_UNDER_TEST)"
	else
		no "platform layer should expose real_path/file_hash/link_scan" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 9
# Unsupported platform is an error, not a silent fallback to a GNU assumption.
case_unknown_platform() {
	local out rc
	out=$(SNAPSHOT_FILE="$WORK/plan9.tsv" ISOLATION_PLATFORM=plan9 bash "$CHECK" verify 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'unsupported platform' <<<"$out"; then
		ok "unknown platform is refused"
	else
		no "unknown platform should be refused" "$out"
	fi
}

# -------------------------------------------------------------------------------- case 9
# The process invariant on the posix path, both directions. A snapshot is synthesized rather than
# staged with a live process: spawning and then killing a process to prove "it disappeared" would
# need exactly the signal this tool must never send, and a name from `ps` is all the check reads.
case_proc_posix() {
	local root="$WORK/proc"
	make_homes "$root"
	run "$root" snapshot >/dev/null
	local base="$root.snapshot.tsv" mine="$WORK/proc.mine.tsv" missing="$WORK/proc.missing.tsv"
	# A name that IS running on this host (bash runs the check itself) and one that is not.
	awk -F'\t' '$1 == "home"' "$base" >"$mine"
	printf 'pid\t999999\tbash\n' >>"$mine"
	awk -F'\t' '$1 == "home"' "$base" >"$missing"
	printf 'pid\t999998\tzz-no-such-process-zz\n' >>"$missing"

	local out_alive out_gone rc_gone
	out_alive=$(CODEX_REAL_HOME="$root/.codex" CODEX_CLONE_HOME="$root/.codex-clone" \
		CODEX_PROBE_HOME="$root/.codex-probe" PROC_RE='bash' SNAPSHOT_FILE="$mine" \
		ISOLATION_PLATFORM=linux bash "$CHECK" verify 2>&1)
	out_gone=$(CODEX_REAL_HOME="$root/.codex" CODEX_CLONE_HOME="$root/.codex-clone" \
		CODEX_PROBE_HOME="$root/.codex-probe" PROC_RE='zz-no-such-process-zz' SNAPSHOT_FILE="$missing" \
		ISOLATION_PLATFORM=linux bash "$CHECK" verify 2>&1)
	rc_gone=$?
	if grep -q 'PASS  all 1 pre-existing processes still running by name' <<<"$out_alive" \
		&& [ $rc_gone -ne 0 ] && grep -q 'FAIL  pre-existing processes gone' <<<"$out_gone"; then
		ok "process name alive passes, name gone fails (posix path)"
	else
		no "process name comparison on the posix path" "alive:
$out_alive
gone:
$out_gone"
	fi
}

# -------------------------------------------------------------------------------- case 10
# Platform dispatch of the homes: darwin and linux take $HOME, wsl keeps the Windows profile even
# when $HOME points somewhere else. Read from the same script, not a second copy.
case_home_dispatch() {
	local d w
	d=$(HOME=/tmp/isc-home-darwin CODEX_REAL_HOME="" USERPROFILE_WSL="" \
		CODEX_CLONE_HOME=/tmp/isc-clone-darwin \
		SNAPSHOT_FILE=/tmp/isc-dispatch.tsv ISOLATION_PLATFORM=darwin bash "$CHECK" verify 2>&1 | grep -m1 '^home:')
	w=$(HOME=/tmp/isc-home-wsl USERPROFILE_WSL=/mnt/c/Users/rahma CODEX_REAL_HOME="" \
		ISOLATION_PLATFORM=wsl SNAPSHOT_FILE=/tmp/isc-dispatch.tsv bash "$CHECK" verify 2>&1 | grep -m1 '^home:')
	if [ "$d" = "home: /tmp/isc-home-darwin" ] && [ "$w" = "home: /mnt/c/Users/rahma" ]; then
		ok "home defaults per platform: darwin \$HOME, wsl Windows profile"
	else
		no "per-platform home defaults" "darwin: $d
wsl: $w"
	fi
}

# -------------------------------------------------------------------------------- case 11
# The macOS decision that is not a guess: the real home follows the documented fallback, the clone
# home has no documented default and must be named. Silently defaulting it would verify a
# directory the app may never touch.
case_clone_home_required() {
	local out rc
	out=$(HOME=/tmp/isc-home-x CODEX_REAL_HOME="" USERPROFILE_WSL="" CODEX_CLONE_HOME="" \
		SNAPSHOT_FILE=/tmp/isc-clone-req.tsv ISOLATION_PLATFORM=darwin bash "$CHECK" verify 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'clone home is not known on this platform' <<<"$out" \
		&& grep -q 'set CODEX_CLONE_HOME' <<<"$out"; then
		ok "clone home has no default off Windows: named or refused, never guessed"
	else
		no "clone home should be required off Windows" "$out"
	fi
}

PLATFORM_UNDER_TEST=${ISOLATION_PLATFORM:-$(uname -s)}
printf 'isolation-check tests — platform: %s\n\n' "$PLATFORM_UNDER_TEST"
case_layer
case_clean
case_escape
case_session_in_real
case_config_byte
case_missing_home
case_wrong_default
case_guard
case_unknown_platform
case_proc_posix
case_home_dispatch
case_clone_home_required

printf '\n%s: %d passed, %d failed\n' "$([ "$FAIL" -eq 0 ] && echo OK || echo FAILED)" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
