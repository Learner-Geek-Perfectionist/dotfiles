#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"

run_shell_syntax_checks() {
	cd "$REPO_ROOT"
	local shell_files=(
		install.sh
		uninstall.sh
		lib/*.sh
		scripts/*.sh
		scripts/wrappers/*
		sh-script/*.sh
	)
	local file
	for file in "${shell_files[@]}"; do
		bash -n "$file"
	done
}

capture_bootstrap_banner() {
	local width="$1" msg="$2"
	local temp_source log_file
	temp_source="$(mktemp)"
	log_file="$(mktemp)"

	sed '$d' "$REPO_ROOT/install.sh" >"$temp_source"
	(
		export COLUMNS="$width" DOTFILES_LOG="$log_file" TERM="xterm-256color"
		# shellcheck source=/dev/null
		source "$temp_source"
		print_banner "$msg"
	)

	rm -f "$temp_source" "$log_file"
}

capture_utils_banner() {
	local width="$1" msg="$2"
	local log_file
	log_file="$(mktemp)"

	(
		export COLUMNS="$width" DOTFILES_LOG="$log_file" TERM="xterm-256color"
		# shellcheck source=../lib/utils.sh
		source "$REPO_ROOT/lib/utils.sh"
		print_banner "$msg"
	)

	rm -f "$log_file"
}

portable_combining_mark_sample() {
	printf 'e\314\201'
}

portable_ascii_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

inspect_banner_output() {
	python3 - "$1" <<'PY'
import re
import sys

line = re.sub(r'\x1b\[[0-9;]*m', '', sys.argv[1]).rstrip('\n')
leading = len(line) - len(line.lstrip(' '))
trailing = len(line) - len(line.rstrip(' '))
core_end = len(line) - trailing if trailing else len(line)
print(f"{leading}|{trailing}|{line[leading:core_end]}")
PY
}

assert_banner_layout() {
	local label="$1" output="$2" expected_left="$3" expected_right="$4" expected_text="$5"
	local actual left right text

	actual="$(inspect_banner_output "$output")"
	IFS='|' read -r left right text <<<"$actual"

	assert_equal "$expected_left" "$left" "$label left padding"
	assert_equal "$expected_right" "$right" "$label right padding"
	assert_equal "$expected_text" "$text" "$label content"
}

run_banner_regression_checks() {
	local output combining_mark

	combining_mark="$(portable_combining_mark_sample)"

	output="$(capture_bootstrap_banner 10 "$combining_mark")"
	assert_banner_layout "bootstrap combining mark" "$output" 4 5 "$combining_mark"

	output="$(capture_bootstrap_banner 10 '🇨🇳')"
	assert_banner_layout "bootstrap flag emoji" "$output" 4 4 '🇨🇳'

	output="$(capture_bootstrap_banner 10 '👨‍👩‍👧‍👦')"
	assert_banner_layout "bootstrap zwj emoji" "$output" 4 4 '👨‍👩‍👧‍👦'

	output="$(capture_utils_banner 10 "$combining_mark")"
	assert_banner_layout "utils combining mark" "$output" 4 5 "$combining_mark"

	output="$(capture_utils_banner 10 '🇨🇳')"
	assert_banner_layout "utils flag emoji" "$output" 4 4 '🇨🇳'

	output="$(capture_utils_banner 10 '👨‍👩‍👧‍👦')"
	assert_banner_layout "utils zwj emoji" "$output" 4 4 '👨‍👩‍👧‍👦'
}

run_install_clone_path_regression_checks() {
	local temp_source fake_bin log_file log_dir clone_dir
	temp_source="$(mktemp)"
	fake_bin="$(make_temp_dir)"
	log_file="$(mktemp)"

	sed '$d' "$REPO_ROOT/install.sh" >"$temp_source"
	cat >"$fake_bin/git" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/git"

	{
		IFS= read -r log_dir
		IFS= read -r clone_dir
	} < <(
		PATH="$fake_bin:/usr/bin:/bin" DOTFILES_LOG="$log_file" TERM="xterm-256color" bash -c '
			set -euo pipefail
			# shellcheck source=/dev/null
			source "$1"
			printf "%s\n" "$DOTFILES_LOG_DIR"
			clone_dotfiles 2>/dev/null
		' _ "$temp_source"
	)

	[[ "$(portable_ascii_lower "$log_dir")" != "$(portable_ascii_lower "$clone_dir")" ]] || fail "clone path collides with log dir on case-insensitive filesystems: $clone_dir"
	rm -f "$temp_source" "$log_file"
	rm -rf "$fake_bin"
}

run_install_clone_does_not_retry_github_ssh_failures() {
	local temp_source fake_bin log_file git_log expected_repo expected_clone_dir
	temp_source="$(mktemp)"
	fake_bin="$(make_temp_dir)"
	log_file="$(mktemp)"
	git_log="$(mktemp)"
	expected_repo="https://github.com/Learner-Geek-Perfectionist/Dotfiles.git"
	expected_clone_dir="${TMPDIR:-/tmp}"
	expected_clone_dir="${expected_clone_dir%/}/dotfiles-clone-$(whoami)"

	sed '$d' "$REPO_ROOT/install.sh" >"$temp_source"
cat >"$fake_bin/git" <<EOF
#!/bin/sh
printf 'GIT_CONFIG_GLOBAL=%s|%s\n' "\${GIT_CONFIG_GLOBAL:-}" "\$*" >>"$git_log"
if [ "\$1" = "clone" ] && [ "\$2" = "--depth=1" ] && [ "\$3" = "--branch" ] && [ "\$5" = "--single-branch" ] && [ "\$6" = "$expected_repo" ]; then
  printf '%s\n' 'git@github.com: Permission denied (publickey).' >&2
  printf '%s\n' 'fatal: Could not read from remote repository.' >&2
  exit 1
fi
printf '%s\n' "unexpected git invocation: \$*" >&2
exit 99
EOF
	chmod +x "$fake_bin/git"

	if PATH="$fake_bin:/usr/bin:/bin" DOTFILES_LOG="$log_file" TERM="xterm-256color" bash -c '
		set -euo pipefail
		# shellcheck source=/dev/null
		source "$1"
		clone_dotfiles >/dev/null 2>&1
	' _ "$temp_source"; then
		fail "clone_dotfiles should fail for GitHub SSH clone errors"
	fi

	assert_grep "^GIT_CONFIG_GLOBAL=\\|clone --depth=1 --branch beta --single-branch $expected_repo $expected_clone_dir\$" "$git_log"
	if grep -q "/dev/null" "$git_log"; then
		fail "clone_dotfiles retried GitHub SSH failure with HTTPS fallback"
	fi

	rm -f "$temp_source" "$log_file" "$git_log"
	rm -rf "$fake_bin"
}

run_install_clone_does_not_retry_non_ssh_failures() {
	local temp_source fake_bin log_file git_log expected_repo expected_clone_dir
	temp_source="$(mktemp)"
	fake_bin="$(make_temp_dir)"
	log_file="$(mktemp)"
	git_log="$(mktemp)"
	expected_repo="https://github.com/Learner-Geek-Perfectionist/Dotfiles.git"
	expected_clone_dir="${TMPDIR:-/tmp}"
	expected_clone_dir="${expected_clone_dir%/}/dotfiles-clone-$(whoami)"

	sed '$d' "$REPO_ROOT/install.sh" >"$temp_source"
	cat >"$fake_bin/git" <<EOF
#!/bin/sh
printf 'GIT_CONFIG_GLOBAL=%s|%s\n' "\${GIT_CONFIG_GLOBAL:-}" "\$*" >>"$git_log"
if [ "\$1" = "clone" ] && [ "\$2" = "--depth=1" ] && [ "\$3" = "--branch" ] && [ "\$5" = "--single-branch" ] && [ "\$6" = "$expected_repo" ]; then
  printf '%s\n' "fatal: repository '\$6' not found" >&2
  exit 1
fi
printf '%s\n' "unexpected git invocation: \$*" >&2
exit 99
EOF
	chmod +x "$fake_bin/git"

	if PATH="$fake_bin:/usr/bin:/bin" DOTFILES_LOG="$log_file" TERM="xterm-256color" bash -c '
		set -euo pipefail
		# shellcheck source=/dev/null
		source "$1"
		clone_dotfiles >/dev/null 2>&1
	' _ "$temp_source"; then
		fail "clone_dotfiles should fail for non-SSH clone errors"
	fi

	assert_grep "^GIT_CONFIG_GLOBAL=\\|clone --depth=1 --branch beta --single-branch $expected_repo $expected_clone_dir\$" "$git_log"
	if grep -q "/dev/null" "$git_log"; then
		fail "clone_dotfiles retried non-SSH failure with HTTPS fallback"
	fi

	rm -f "$temp_source" "$log_file" "$git_log"
	rm -rf "$fake_bin"
}

run_python_checks() {
	cd "$REPO_ROOT"
	if ! command -v python3 &>/dev/null; then
		if [[ "${CI:-}" == "true" ]]; then
			fail "python3 is required in CI"
		fi
		warn "python3 not found, skipping Python syntax checks"
		return 0
	fi

	python3 -m py_compile .config/kitty/*.py
}

run_kitty_config_checks() {
	cd "$REPO_ROOT"
	if ! command -v kitty &>/dev/null; then
		warn "kitty not found, skipping kitty.conf parse checks"
		return 0
	fi

	local output
	if ! output="$(kitty +runpy 'from kitty.config import load_config; import sys; bad=[]; load_config(".config/kitty/kitty.conf", accumulate_bad_lines=bad); [print(repr(x)) for x in bad]; sys.exit(1 if bad else 0)' 2>&1)"; then
		printf '%s\n' "$output" >&2
		fail "kitty.conf does not parse cleanly"
	fi
}

run_lua_checks() {
	cd "$REPO_ROOT"
	if ! command -v luac &>/dev/null; then
		if [[ "${CI:-}" == "true" ]]; then
			fail "luac is required in CI"
		fi
		warn "luac not found, skipping Lua syntax checks"
		return 0
	fi

	find .hammerspoon -name '*.lua' -print0 | xargs -0 -n1 luac -p
}

run_macos_ime_toggle_setup_checks() {
	cd "$REPO_ROOT"
	bash scripts/test_macos_ime_toggle_setup.sh
}

run_hammerspoon_cleanup_checks() {
	cd "$REPO_ROOT"

	[[ ! -e .hammerspoon/modules/inputMethod.lua ]] || fail "obsolete .hammerspoon/modules/inputMethod.lua should be removed"
	[[ ! -e .hammerspoon/modules/systemInfoHelpers.lua ]] || fail "obsolete .hammerspoon/modules/systemInfoHelpers.lua should be removed"
	[[ ! -e .hammerspoon/modules/windowManagementHelpers.lua ]] || fail "obsolete .hammerspoon/modules/windowManagementHelpers.lua should be removed"
	[[ ! -e .hammerspoon/.DS_Store ]] || fail "repository junk file .hammerspoon/.DS_Store should be removed"
	if rg -n "enableCustomCmdBacktick|moveToFocusedScreen" .hammerspoon/config/KeyBinds.lua .hammerspoon/config/keyConfig.lua >/dev/null; then
		fail "obsolete Hammerspoon cmd+backtick compatibility branches should be removed"
	fi
}

run_hammerspoon_regression_checks() {
	cd "$REPO_ROOT"

	if ! command -v lua &>/dev/null; then
		if [[ "${CI:-}" == "true" ]]; then
			fail "lua is required in CI"
		fi
		warn "lua not found, skipping Hammerspoon regression checks"
		return 0
	fi

	lua scripts/test_hammerspoon_helpers.lua
}

run_ime_migration_cleanup_checks() {
	cd "$REPO_ROOT"

	if rg -n "remove_obsolete_managed_dotfiles_path|remove_obsolete_macos_ime_helper_chain" scripts/install_dotfiles.sh >/dev/null; then
		fail "obsolete IME migration cleanup helpers should be removed from install_dotfiles.sh"
	fi
}

run_shellcheck() {
	cd "$REPO_ROOT"
	if ! command -v shellcheck &>/dev/null; then
		if [[ "${CI:-}" == "true" ]]; then
			fail "shellcheck is required in CI"
		fi
		warn "shellcheck not found, skipping ShellCheck"
		return 0
	fi

	shellcheck -S warning install.sh uninstall.sh lib/*.sh scripts/*.sh scripts/wrappers/* sh-script/*.sh
}

run_test "Shell syntax" run_shell_syntax_checks
run_test "Banner width" run_banner_regression_checks
run_test "Install clone path" run_install_clone_path_regression_checks
run_test "Install clone does not retry GitHub SSH failures" run_install_clone_does_not_retry_github_ssh_failures
run_test "Install clone does not retry non-SSH failures" run_install_clone_does_not_retry_non_ssh_failures
run_test "Python syntax" run_python_checks
run_test "kitty config parse" run_kitty_config_checks
run_test "Lua syntax" run_lua_checks
run_test "macOS IME toggle setup" run_macos_ime_toggle_setup_checks
run_test "Hammerspoon cleanup" run_hammerspoon_cleanup_checks
run_test "Hammerspoon regressions" run_hammerspoon_regression_checks
run_test "IME migration cleanup" run_ime_migration_cleanup_checks
run_test "ShellCheck" run_shellcheck

section "Done"
pass "Static checks completed"
