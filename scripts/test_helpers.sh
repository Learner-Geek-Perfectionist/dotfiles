#!/bin/bash
# shellcheck disable=SC2034

set -euo pipefail

TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_HELPERS_DIR/.." && pwd)"

section() {
	printf '\n==> %s\n' "$1"
}

info() {
	printf '  [INFO] %s\n' "$1"
}

pass() {
	printf '  [PASS] %s\n' "$1"
}

warn() {
	printf '  [WARN] %s\n' "$1"
}

fail() {
	printf '  [FAIL] %s\n' "$1" >&2
	exit 1
}

make_temp_dir() {
	mktemp -d
}

make_fake_superpowers_repo() {
	local repo
	repo=$(make_temp_dir)

	mkdir -p "$repo/skills/using-superpowers" "$repo/skills/systematic-debugging"
	cat >"$repo/skills/using-superpowers/SKILL.md" <<'EOF'
---
name: using-superpowers
description: Test fixture for Codex skill discovery
---

# Using Superpowers
EOF
	cat >"$repo/skills/systematic-debugging/SKILL.md" <<'EOF'
---
name: systematic-debugging
description: Test fixture for debugging workflows
---

# Systematic Debugging
EOF

	git init "$repo" >/dev/null 2>&1
	git -C "$repo" config user.name "Dotfiles Test"
	git -C "$repo" config user.email "dotfiles@example.com"
	git -C "$repo" add skills
	git -C "$repo" commit -m "init superpowers fixture" >/dev/null 2>&1

	printf '%s\n' "$repo"
}

assert_file_exists() {
	local path="$1"
	[[ -e "$path" || -L "$path" ]] || fail "Expected path to exist: $path"
}

assert_file_missing() {
	local path="$1"
	[[ ! -e "$path" && ! -L "$path" ]] || fail "Expected path to be absent: $path"
}

assert_executable() {
	local path="$1"
	[[ -x "$path" ]] || fail "Expected executable file: $path"
}

assert_symlink() {
	local path="$1"
	[[ -L "$path" ]] || fail "Expected symlink: $path"
}

assert_contains() {
	local needle="$1" file="$2"
	grep -qF "$needle" "$file" || fail "Expected '$needle' in $file"
}

assert_not_contains() {
	local needle="$1" file="$2"
	if grep -qF "$needle" "$file"; then
		fail "Did not expect '$needle' in $file"
	fi
}

assert_grep() {
	local pattern="$1" file="$2"
	grep -qE "$pattern" "$file" || fail "Expected pattern '$pattern' in $file"
}

assert_equal() {
	local expected="$1" actual="$2" label="${3:-value}"
	[[ "$expected" == "$actual" ]] || fail "$label mismatch: expected '$expected', got '$actual'"
}

file_mode() {
	local path="$1"

	if stat -f %Lp "$path" >/dev/null 2>&1; then
		stat -f %Lp "$path"
		return 0
	fi

	stat -c %a "$path"
}

assert_mode() {
	local expected="$1" path="$2" actual
	actual="$(file_mode "$path")"
	[[ "$actual" == "$expected" ]] || fail "Expected mode '$expected' for $path, got '$actual'"
}

run_test() {
	local name="$1"
	shift
	section "$name"
	"$@"
	pass "$name"
}
