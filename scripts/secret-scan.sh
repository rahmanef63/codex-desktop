#!/usr/bin/env bash
# Refuse to commit a credential.
#
# This repository drives a gateway that authenticates with a bearer token, and the token also
# appears in ~/.codex profiles and shell history. A single accidental `git add` would publish it
# permanently. Run this before every commit; `git config core.hooksPath` can wire it up.
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
	hits=$(echo "$files" | tr '\n' '\0' | xargs -0 -r grep -InE "$pattern" 2>/dev/null || true)
	if [ -n "$hits" ]; then
		echo "refusing to commit: matched /$pattern/" >&2
		echo "$hits" | sed 's/^/  /' | head -20 >&2
		failed=1
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "" >&2
	echo "Remove the value, or stage it out. If it is a false positive on a documented shape," >&2
	echo "rewrite the example so it cannot be mistaken for a real credential." >&2
	exit 1
fi
