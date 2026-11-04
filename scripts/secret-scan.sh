#!/usr/bin/env bash
# Refuse to commit a credential.
#
# This repository drives a gateway that authenticates with a bearer token, and the token also
# appears in ~/.codex profiles and shell history. A single accidental `git add` would publish it
# permanently. Run this before every commit; `git config core.hooksPath` can wire it up.
#
# Portable across GNU (Linux/WSL) and BSD (macOS) userland. The two differences that bite:
#   * `xargs -0 -r` — BSD xargs has no `-r`. Replaced with the POSIX trick `xargs ... || true`
#     plus an empty-list guard, so an empty commit stage does not run grep on nothing.
#   * `xargs -0` itself is fine on both; only `-r` is GNU.
set -uo pipefail

PATTERNS=(
	'sk-[A-Za-z0-9_-]{16,}'                 # gateway / provider keys
	'Bearer [A-Za-z0-9._-]{20,}'            # literal bearer values
	'ghp_[A-Za-z0-9]{20,}'                  # GitHub classic
	'github_pat_[A-Za-z0-9_]{20,}'          # GitHub fine-grained
	'AKIA[0-9A-Z]{16}'                      # AWS
	'-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

files=$(git diff --cached --name-only --diff-filter=ACM)
[ -z "$files" ] && exit 0

failed=0
for pattern in "${PATTERNS[@]}"; do
	# -I skips binaries; -n prints the line so the file can be fixed precisely.
	# `printf '%s\n'` guarantees the trailing newline that `tr` turns into the NUL terminator
	# BSD `xargs -0` needs; git's list has none of its own.
	hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -InE "$pattern" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		printf 'refusing to commit: matched /%s/\n' "$pattern" >&2
		printf '%s\n' "$hits" | sed 's/^/  /' | head -20 >&2
		failed=1
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "" >&2
	echo "Remove the value, or stage it out. If it is a false positive on a documented shape," >&2
	echo "rewrite the example so it cannot be mistaken for a real credential." >&2
	exit 1
fi
