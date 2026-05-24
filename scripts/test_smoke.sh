#!/bin/bash
# shellcheck disable=SC2064

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=./lib_macos_ime_toggle.sh
source "$REPO_ROOT/scripts/lib_macos_ime_toggle.sh"

run_dotfiles_install() {
	local tmp_home="$1" fake_bin="$2" superpowers_repo="$3" log="$4"
	HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_DIR="$REPO_ROOT" \
		CODEX_LATEST_MODEL_URL="${CODEX_LATEST_MODEL_URL-}" \
		SUPERPOWERS_REPO_URL="$superpowers_repo" bash "$REPO_ROOT/scripts/install_dotfiles.sh" >"$log" 2>&1
}

run_deploy_superpowers_skills() {
	local tmp_home="$1" fake_bin="$2" clone_dir="$3" link_dir="$4" state_file="$5" log="$6"
	HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/deploy_superpowers_skills.sh" "$clone_dir" "$link_dir" "$state_file" >"$log" 2>&1
}

assert_karabiner_provider_shape() {
	local provider="$1" karabiner_file="$2"

	python3 - "$provider" "$karabiner_file" <<'PY'
import json
import sys

provider = sys.argv[1]
karabiner_file = sys.argv[2]

with open(karabiner_file, encoding="utf-8") as handle:
    data = json.load(handle)

rules = data["profiles"][0]["complex_modifications"]["rules"]
serialized = json.dumps(data, sort_keys=True)

def fail(message):
    raise SystemExit(message)

PARALLELS_MACVM_UNLESS = [
    {
        "type": "frontmost_application_unless",
        "bundle_identifiers": ["^com\\.parallels\\.macvm$"],
    }
]

def has_parallels_macvm_unless(manipulator):
    return manipulator.get("conditions") == PARALLELS_MACVM_UNLESS

def click_rule_matches(rule, from_key, to_key, to_if_alone_kind):
    manipulators = rule.get("manipulators", [])
    if len(manipulators) != 1:
        return False
    manipulator = manipulators[0]
    if manipulator.get("type") != "basic":
        return False
    from_ = manipulator.get("from", {})
    if from_.get("key_code") != from_key:
        return False
    if not has_parallels_macvm_unless(manipulator):
        return False
    if from_.get("modifiers", {}).get("optional") != ["any"]:
        return False
    if manipulator.get("parameters", {}).get("basic.to_if_alone_timeout_milliseconds") != 200:
        return False
    to_entries = manipulator.get("to", [])
    if len(to_entries) != 1:
        return False
    to_entry = to_entries[0]
    if to_entry.get("key_code") != to_key or to_entry.get("lazy") is not True:
        return False
    to_if_alone = manipulator.get("to_if_alone", [])
    if len(to_if_alone) != 1:
        return False
    entry = to_if_alone[0]
    if to_if_alone_kind == "control_space":
        return (
            set(entry) == {"key_code", "modifiers"}
            and entry.get("key_code") == "spacebar"
            and entry.get("modifiers") == ["left_control"]
        )
    if to_if_alone_kind == "key_code":
        return set(entry) == {"key_code"} and entry.get("key_code") == "left_shift"
    if to_if_alone_kind == "absent":
        return "to_if_alone" not in manipulator
    fail(f"unexpected click rule kind {to_if_alone_kind!r}")

def unique_click_rule(rule_kind, from_key, to_key, to_if_alone_kind):
    matches = [item for item in rules if click_rule_matches(item, from_key, to_key, to_if_alone_kind)]
    if len(matches) != 1:
        fail(f"expected exactly one {rule_kind} IME click rule for {from_key}")
    return matches[0]

def fallback_rule():
    matches = []
    for item in rules:
        manipulators = item.get("manipulators", [])
        if len(manipulators) != 1:
            continue
        manipulator = manipulators[0]
        if manipulator.get("from", {}).get("key_code") != "caps_lock":
            continue
        if manipulator.get("to", [{}])[0].get("key_code") != "left_shift":
            continue
        if manipulator.get("to", [{}])[0].get("lazy") is not True:
            continue
        if manipulator.get("to_if_alone"):
            continue
        if "parameters" in manipulator:
            continue
        if not has_parallels_macvm_unless(manipulator):
            continue
        matches.append(item)
    if len(matches) == 1:
        return matches[0]
    if len(matches) == 0:
        return None
    fail("expected exactly one plain caps fallback rule")

stale_symbols = tuple(
    "".join(parts)
    for parts in (
        ("ime_", "shift_session_active"),
        ("ime_", "keyboard_used"),
        ("ime_", "left_shift_pressed"),
        ("ime_", "right_shift_pressed"),
    )
)
for symbol in stale_symbols:
    if symbol in serialized:
        fail(f"stale session-state symbol {symbol!r} should not appear in generated Karabiner JSON")

right_rule = next(
    (
        item
        for item in rules
        if {manipulator.get("from", {}).get("key_code") for manipulator in item.get("manipulators", [])}
        == {"right_command", "right_option"}
    ),
    None,
)
if right_rule is None:
    fail("missing right-side remap rule")
if len(right_rule.get("manipulators", [])) != 4:
    fail("right-side remap rule should keep exactly 4 manipulators")

def assert_left_command_escape(manipulator, from_key):
    if manipulator.get("from", {}).get("key_code") != from_key:
        fail(f"left_command escape should start from {from_key}")
    modifiers = manipulator.get("from", {}).get("modifiers", {})
    if modifiers.get("mandatory") != ["left_command"]:
        fail(f"left_command escape from {from_key} should require left_command")
    if modifiers.get("optional") != ["any"]:
        fail(f"left_command escape from {from_key} should keep optional any")
    if manipulator.get("to", [{}])[0].get("key_code") != "right_command":
        fail(f"left_command escape from {from_key} should send right_command for Codex screenshot")
    if manipulator.get("to", [{}])[0].get("modifiers") != ["left_command"]:
        fail(f"left_command escape from {from_key} should send left_command with right_command")

def assert_right_remap(manipulator, from_key):
    if manipulator.get("from", {}).get("key_code") != from_key:
        fail(f"right-side remap should start from {from_key}")
    if manipulator.get("from", {}).get("modifiers", {}).get("optional") != ["any"]:
        fail(f"right-side remap from {from_key} should keep optional any")
    if "mandatory" in manipulator.get("from", {}).get("modifiers", {}):
        fail(f"right-side remap from {from_key} should not require mandatory modifiers")
    if manipulator.get("to", [{}])[0].get("key_code") != "left_command":
        fail(f"right-side remap from {from_key} should remap to left_command")
    if manipulator.get("to", [{}])[0].get("modifiers") != ["left_control", "left_option"]:
        fail(f"right-side remap from {from_key} should keep the command+control+option modifiers")

assert_left_command_escape(right_rule["manipulators"][0], "right_command")
assert_left_command_escape(right_rule["manipulators"][1], "right_option")
assert_right_remap(right_rule["manipulators"][2], "right_command")
assert_right_remap(right_rule["manipulators"][3], "right_option")

arrow_keys = {"left_arrow", "right_arrow", "up_arrow", "down_arrow"}
for rule in rules:
    for manipulator in rule.get("manipulators", []):
        from_ = manipulator.get("from", {})
        source_key = from_.get("key_code")
        if source_key in arrow_keys:
            fail(f"Karabiner should leave {source_key} to the Hammerspoon eventtap")
        if any("shell_command" in to_entry for to_entry in manipulator.get("to", [])):
            fail("Karabiner config should not depend on shell_command helpers")

if provider == "apple_pair":
    unique_click_rule("apple_pair", "left_shift", "left_shift", "control_space")
    unique_click_rule("apple_pair", "right_shift", "right_shift", "control_space")
    unique_click_rule("apple_pair", "caps_lock", "left_shift", "control_space")
    if fallback_rule() is not None:
        fail("apple_pair should not keep a plain caps fallback rule")
elif provider == "wetype":
    if any(
        click_rule_matches(item, "left_shift", "left_shift", kind)
        for item in rules
        for kind in ("control_space", "key_code")
    ):
        fail("wetype should leave physical left_shift untouched")
    if any(
        click_rule_matches(item, "right_shift", "right_shift", kind)
        for item in rules
        for kind in ("control_space", "key_code")
    ):
        fail("wetype should leave physical right_shift untouched")
    unique_click_rule("wetype", "caps_lock", "left_shift", "key_code")
    if fallback_rule() is not None:
        fail("wetype should not keep a plain caps fallback rule")
elif provider == "disabled":
    if any(
        click_rule_matches(item, "left_shift", "left_shift", kind)
        for item in rules
        for kind in ("control_space", "key_code")
    ):
        fail("disabled provider should remove the left shift click rule")
    if any(
        click_rule_matches(item, "right_shift", "right_shift", kind)
        for item in rules
        for kind in ("control_space", "key_code")
    ):
        fail("disabled provider should remove the right shift click rule")
    if any(
        click_rule_matches(item, "caps_lock", "left_shift", kind)
        for item in rules
        for kind in ("control_space", "key_code")
    ):
        fail("disabled provider should remove the caps click rule")
    caps_rule = fallback_rule()
    if caps_rule is None:
        fail("disabled provider should keep exactly one plain caps fallback rule")
    if len(caps_rule.get("manipulators", [])) != 1:
        fail("disabled provider should keep only one caps fallback manipulator")
    manipulator = caps_rule["manipulators"][0]
    if manipulator.get("from", {}).get("key_code") != "caps_lock":
        fail("disabled provider fallback should start from caps_lock")
    if len(manipulator.get("to", [])) != 1:
        fail("disabled provider fallback should keep exactly one to entry")
    if manipulator.get("to", [{}])[0].get("key_code") != "left_shift":
        fail("disabled provider fallback should map caps_lock to left_shift")
    if manipulator.get("to", [{}])[0].get("lazy") is not True:
        fail("disabled provider fallback should keep lazy=true")
    if manipulator.get("to_if_alone"):
        fail("disabled provider fallback should not keep to_if_alone")
    if "parameters" in manipulator:
        fail("disabled provider fallback should not keep parameters")
    if not has_parallels_macvm_unless(manipulator):
        fail("disabled provider fallback should let Parallels VM receive raw caps_lock")
else:
    fail(f"unexpected provider {provider!r}")
PY
}

write_fake_claude_cli() {
	local fake_bin="$1" mcp_list_output="$2" add_json_log="$3" remove_log="$4"
	cat >"$fake_bin/claude" <<EOF
#!/bin/sh
case "\$1" in
  --version)
    echo 'claude 1.0.0'
    exit 0
    ;;
  plugin)
    case "\$2" in
      list)
        exit 0
        ;;
      install|uninstall)
        exit 0
        ;;
      marketplace)
        case "\$3" in
          add|remove)
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
  mcp)
    case "\$2" in
      list)
        cat <<'INNER'
$mcp_list_output
INNER
        exit 0
        ;;
      add)
        exit 0
        ;;
      add-json)
        mkdir -p "$(dirname "$add_json_log")"
        printf '%s\n' "\$4" >"$add_json_log"
        exit 0
        ;;
      remove)
        mkdir -p "$(dirname "$remove_log")"
        printf '%s\n' "\$3" >>"$remove_log"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
EOF
	chmod +x "$fake_bin/claude"
}

write_fake_claude_cli_with_update_logs() {
	local fake_bin="$1" plugin_list_output="$2" mcp_list_output="$3" add_json_log="$4" remove_log="$5"
	local plugin_install_log="$6" plugin_update_log="$7" marketplace_update_log="$8"
	cat >"$fake_bin/claude" <<EOF
#!/bin/sh
case "\$1" in
  --version)
    echo 'claude 1.0.0'
    exit 0
    ;;
  plugin)
    case "\$2" in
      list)
        cat <<'INNER'
$plugin_list_output
INNER
        exit 0
        ;;
      install)
        mkdir -p "$(dirname "$plugin_install_log")"
        printf '%s\n' "\$3" >>"$plugin_install_log"
        exit 0
        ;;
      update)
        mkdir -p "$(dirname "$plugin_update_log")"
        printf '%s\n' "\$3" >>"$plugin_update_log"
        exit 0
        ;;
      uninstall)
        exit 0
        ;;
      marketplace)
        case "\$3" in
          add|remove)
            exit 0
            ;;
          update)
            mkdir -p "$(dirname "$marketplace_update_log")"
            if [ -n "\${4:-}" ]; then
              printf '%s\n' "\$4" >>"$marketplace_update_log"
            else
              printf '%s\n' "__all__" >>"$marketplace_update_log"
            fi
            exit 0
            ;;
        esac
        ;;
    esac
    ;;
  mcp)
    case "\$2" in
      list)
        cat <<'INNER'
$mcp_list_output
INNER
        exit 0
        ;;
      add)
        exit 0
        ;;
      add-json)
        mkdir -p "$(dirname "$add_json_log")"
        printf '%s\n' "\$4" >"$add_json_log"
        exit 0
        ;;
      remove)
        mkdir -p "$(dirname "$remove_log")"
        printf '%s\n' "\$3" >>"$remove_log"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
EOF
	chmod +x "$fake_bin/claude"
}

test_superpowers_clone_does_not_retry_github_ssh_failures() {
	local tmp_home fake_bin log git_log clone_dir link_dir state_file expected_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/deploy-superpowers.log"
	git_log="$tmp_home/git.log"
	clone_dir="$tmp_home/.codex/superpowers"
	link_dir="$tmp_home/.agents/skills/superpowers"
	state_file="$tmp_home/.local/state/dotfiles/superpowers.env"
	expected_repo="https://github.com/obra/superpowers.git"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

cat >"$fake_bin/git" <<EOF
#!/bin/sh
printf 'GIT_CONFIG_GLOBAL=%s|%s\n' "\${GIT_CONFIG_GLOBAL:-}" "\$*" >>"$git_log"
if [ "\$1" = "clone" ] && [ "\$2" = "$expected_repo" ] && [ "\$3" = "$clone_dir" ]; then
  printf '%s\n' 'git@github.com: Permission denied (publickey).' >&2
  exit 1
fi
if [ "\$1" = "-C" ] && [ "\$2" = "$clone_dir" ] && [ "\$3" = "remote" ] && [ "\$4" = "get-url" ] && [ "\$5" = "origin" ]; then
  printf '%s\n' "$expected_repo"
  exit 0
fi
printf '%s\n' "unexpected git invocation: \$*" >&2
exit 99
EOF
	chmod +x "$fake_bin/git"

	if run_deploy_superpowers_skills "$tmp_home" "$fake_bin" "$clone_dir" "$link_dir" "$state_file" "$log"; then
		cat "$log" >&2
		fail "deploy_superpowers_skills.sh should fail on GitHub SSH clone errors"
	fi

	assert_file_missing "$link_dir"
	assert_file_missing "$clone_dir/skills/using-superpowers/SKILL.md"
	assert_file_missing "$state_file"
	assert_grep "^GIT_CONFIG_GLOBAL=\\|clone $expected_repo $clone_dir\$" "$git_log"
	if grep -q "/dev/null" "$git_log"; then
		fail "deploy_superpowers_skills.sh retried GitHub SSH clone failure with HTTPS fallback"
	fi
}

test_superpowers_pull_does_not_retry_github_ssh_failures() {
	local tmp_home fake_bin log git_log clone_dir link_dir state_file expected_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/deploy-superpowers.log"
	git_log="$tmp_home/git.log"
	clone_dir="$tmp_home/.codex/superpowers"
	link_dir="$tmp_home/.agents/skills/superpowers"
	state_file="$tmp_home/.local/state/dotfiles/superpowers.env"
	expected_repo="https://github.com/obra/superpowers.git"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$clone_dir/.git" "$clone_dir/skills/using-superpowers" "$(dirname "$link_dir")"
	printf '%s\n' 'old skill' >"$clone_dir/skills/using-superpowers/SKILL.md"

	cat >"$fake_bin/git" <<EOF
#!/bin/sh
printf 'GIT_CONFIG_GLOBAL=%s|%s\n' "\${GIT_CONFIG_GLOBAL:-}" "\$*" >>"$git_log"
if [ "\$1" = "-C" ] && [ "\$2" = "$clone_dir" ] && [ "\$3" = "remote" ] && [ "\$4" = "get-url" ] && [ "\$5" = "origin" ]; then
  printf '%s\n' 'git@github.com:obra/superpowers.git'
  exit 0
fi
if [ "\$1" = "-C" ] && [ "\$2" = "$clone_dir" ] && [ "\$3" = "pull" ] && [ "\$4" = "--ff-only" ]; then
  printf '%s\n' 'git@github.com: Permission denied (publickey).' >&2
  exit 1
fi
if [ "\$1" = "-C" ] && [ "\$2" = "$clone_dir" ] && [ "\$3" = "rev-parse" ] && [ "\$4" = "--abbrev-ref" ] && [ "\$5" = "HEAD" ]; then
  printf '%s\n' 'main'
  exit 0
fi
printf '%s\n' "unexpected git invocation: \$*" >&2
exit 99
EOF
	chmod +x "$fake_bin/git"

	if run_deploy_superpowers_skills "$tmp_home" "$fake_bin" "$clone_dir" "$link_dir" "$state_file" "$log"; then
		cat "$log" >&2
		fail "deploy_superpowers_skills.sh should fail on GitHub SSH pull errors"
	fi

	assert_file_exists "$clone_dir/skills/using-superpowers/SKILL.md"
	assert_contains 'old skill' "$clone_dir/skills/using-superpowers/SKILL.md"
	assert_file_missing "$state_file"
	assert_grep "^GIT_CONFIG_GLOBAL=\\|-C $clone_dir pull --ff-only\$" "$git_log"
	if grep -q "/dev/null" "$git_log"; then
		fail "deploy_superpowers_skills.sh retried GitHub SSH pull failure with HTTPS fallback"
	fi
}

test_dotfiles_manifest_and_ssh_block() {
	local tmp_home fake_bin log manifest superpowers_repo superpowers_state
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	manifest="$tmp_home/.local/state/dotfiles/dotfiles-manifest.tsv"
	superpowers_repo=$(make_fake_superpowers_repo)
	superpowers_state="$tmp_home/.local/state/dotfiles/superpowers.env"
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh failed"
	fi

	assert_file_exists "$manifest"
	assert_contains "$tmp_home/.zshrc" "$manifest"
	assert_contains "$tmp_home/.codex/config.toml" "$manifest"
	assert_contains "$tmp_home/.claude.json" "$manifest"
	assert_contains "$tmp_home/.ssh/config.d/00-dotfiles" "$manifest"
	assert_file_exists "$tmp_home/.codex/config.toml"
	assert_file_exists "$tmp_home/.claude.json"
	assert_file_exists "$superpowers_state"
	assert_symlink "$tmp_home/.agents/skills/superpowers"
	assert_file_exists "$tmp_home/.codex/superpowers/skills/using-superpowers/SKILL.md"
	assert_contains '"autoUpdates": false' "$tmp_home/.claude.json"
	assert_contains 'model = "gpt-5.5"' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.github]' "$tmp_home/.codex/config.toml"
	assert_contains 'bearer_token_env_var = "GITHUB_PERSONAL_ACCESS_TOKEN"' "$tmp_home/.codex/config.toml"
	assert_file_exists "$tmp_home/.ssh/config"
	assert_contains "# >>> Dotfiles SSH Include >>>" "$tmp_home/.ssh/config"
	assert_contains "Include config.d/*" "$tmp_home/.ssh/config"
}

test_dotfiles_macos_ime_detection_falls_back_without_jq_or_python() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Keyboard Layout","InputSourceID":"com.apple.keylayout.US"},{"InputSourceKind":"Keyboard Layout","InputSourceID":"com.apple.keylayout.ABC"},{"InputSourceKind":"Keyboard Input Method","InputSourceID":"com.apple.inputmethod.SCIM.ITABC"}]
INNER
		;;
	AppleSelectedInputSources|AppleInputSourceHistory)
		printf '%s\n' '[]'
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		printf '%s\n' 'com.apple.keylayout.US'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/jq" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/jq" "$fake_bin/python3" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh IME fallback parsing failed"
	fi

	assert_contains 'macOS IME toggle provider: apple_pair (set macOS input-source shortcut to Control-Space)' "$log"
	assert_not_contains 'macOS IME toggle disabled on this machine because no supported provider was detected' "$log"
	assert_not_contains 'Wide character in print' "$log"
}

test_dotfiles_macos_ime_detection_empty_fallback_still_installs() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources|AppleSelectedInputSources|AppleInputSourceHistory)
		printf '%s\n' '[]'
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		exit 1
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/jq" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/jq" "$fake_bin/python3" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh empty IME fallback should still succeed"
	fi

	assert_contains 'macOS IME toggle disabled on this machine because no supported provider was detected' "$log"
	assert_not_contains 'Wide character in print' "$log"
}

test_dotfiles_warns_when_macos_ime_provider_is_disabled() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Keyboard Layout","InputSourceID":"com.apple.keylayout.Dvorak"}]
INNER
		;;
	AppleSelectedInputSources|AppleInputSourceHistory)
		printf '%s\n' '[]'
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		printf '%s\n' 'com.apple.keylayout.Dvorak'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh disabled provider warning failed"
	fi

	assert_contains 'macOS IME toggle disabled on this machine because no supported provider was detected' "$log"
	assert_not_contains 'Wide character in print' "$log"
}

test_dotfiles_generates_apple_pair_karabiner_profile() {
	local tmp_home fake_bin log superpowers_repo karabiner_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	karabiner_file="$tmp_home/.config/karabiner/karabiner.json"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Keyboard Layout","InputSourceID":"com.apple.keylayout.ABC"},{"InputSourceKind":"Keyboard Input Method","InputSourceID":"com.apple.inputmethod.SCIM.ITABC"}]
INNER
		;;
	AppleSelectedInputSources|AppleInputSourceHistory)
		printf '%s\n' '[]'
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		printf '%s\n' 'com.apple.keylayout.ABC'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh apple_pair Karabiner generation failed"
	fi

	assert_contains 'macOS IME toggle provider: apple_pair (set macOS input-source shortcut to Control-Space)' "$log"
	assert_file_exists "$karabiner_file"
	assert_karabiner_provider_shape "apple_pair" "$karabiner_file"
}

test_dotfiles_generates_wetype_karabiner_profile_from_hitoolbox_state() {
	local tmp_home fake_bin log superpowers_repo karabiner_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	karabiner_file="$tmp_home/.config/karabiner/karabiner.json"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Input Mode","Bundle ID":"com.apple.inputmethod.SCIM","Input Mode":"com.apple.inputmethod.SCIM.ITABC"},{"InputSourceKind":"Non Keyboard Input Method","Bundle ID":"com.apple.PressAndHold"}]
INNER
		;;
	AppleInputSourceHistory)
		cat <<'INNER'
[{"InputSourceKind":"Input Mode","Bundle ID":"com.tencent.inputmethod.wetype","Input Mode":"com.tencent.inputmethod.wetype.pinyin"},{"InputSourceKind":"Keyboard Layout","KeyboardLayout Name":"ABC","KeyboardLayout ID":252}]
INNER
		;;
	AppleSelectedInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Non Keyboard Input Method","Bundle ID":"com.apple.PressAndHold"},{"InputSourceKind":"Input Mode","Bundle ID":"com.tencent.inputmethod.wetype","Input Mode":"com.tencent.inputmethod.wetype.pinyin"}]
INNER
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		printf '%s\n' 'com.apple.keylayout.US'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh wetype Karabiner generation failed"
	fi

	assert_contains "macOS IME toggle provider: wetype (enable WeType's Shift toggle inside WeChat Input Method)" "$log"
	assert_file_exists "$karabiner_file"
	assert_karabiner_provider_shape "wetype" "$karabiner_file"
	assert_not_contains 'Wide character in print' "$log"
}

test_dotfiles_generates_disabled_karabiner_without_ime_rules() {
	local tmp_home fake_bin log superpowers_repo karabiner_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	karabiner_file="$tmp_home/.config/karabiner/karabiner.json"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "Darwin"
EOF
	cat >"$fake_bin/plutil" <<'EOF'
#!/bin/sh
if [ "$1" = "-extract" ]; then
	case "$2" in
	AppleEnabledInputSources)
		cat <<'INNER'
[{"InputSourceKind":"Keyboard Layout","InputSourceID":"com.apple.keylayout.Dvorak"}]
INNER
		;;
	AppleSelectedInputSources|AppleInputSourceHistory)
		printf '%s\n' '[]'
		;;
	AppleCurrentKeyboardLayoutInputSourceID)
		printf '%s\n' 'com.apple.keylayout.Dvorak'
		;;
	*)
		exit 1
		;;
	esac
	exit 0
fi
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/plutil" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh disabled-provider Karabiner generation failed"
	fi

	assert_contains 'macOS IME toggle disabled on this machine because no supported provider was detected' "$log"
	assert_file_exists "$karabiner_file"
	assert_karabiner_provider_shape "disabled" "$karabiner_file"
	assert_not_contains 'Wide character in print' "$log"
}

test_dotfiles_wetype_karabiner_patching_fails_closed_on_malformed_click_rule() {
	local tmp_dir karabiner_file log
	tmp_dir=$(make_temp_dir)
	karabiner_file="$tmp_dir/karabiner.json"
	log="$tmp_dir/karabiner.log"
	trap "rm -rf '$tmp_dir'" RETURN

	cp "$REPO_ROOT/.config/karabiner/karabiner.json" "$karabiner_file"
	python3 - "$karabiner_file" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

rules = data["profiles"][0]["complex_modifications"]["rules"]
for rule in rules:
    manipulators = rule.get("manipulators", [])
    if any(manipulator.get("from", {}).get("key_code") == "left_shift" for manipulator in manipulators):
        manipulators[0]["to_if_alone"] = [{"key_code": "left_shift"}]
        break
else:
    raise SystemExit("failed to locate left_shift click rule")

with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY

	if macos_customize_home_karabiner_config "$karabiner_file" wetype >"$log" 2>&1; then
		cat "$log" >&2
		fail "wetype patching should fail closed on malformed click-rule input"
	fi

	assert_contains "expected exactly one IME click rule for left_shift" "$log"
}

test_dotfiles_precleans_zinit_stale_completions() {
	local tmp_home fake_bin log superpowers_repo zsh_calls stale_link
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	zsh_calls="$tmp_home/zsh-calls.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	stale_link="$tmp_home/.local/share/zinit/completions/_stale_completion"
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	mkdir -p "$tmp_home/.local/share/zinit/zinit.git" "$tmp_home/.local/share/zinit/completions"
	: >"$tmp_home/.local/share/zinit/zinit.git/zinit.zsh"
	ln -s /definitely/missing "$stale_link"

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
cmd="$2"
printf '%s\n' "$cmd" >>"$HOME/zsh-calls.log"
case "$cmd" in
  *"zinit cclear"* )
    rm -f "$HOME/.local/share/zinit/completions/_stale_completion"
    exit 0
    ;;
  *"ZINIT_SYNC=1 source '$HOME/.zshrc'"* )
    if [ -L "$HOME/.local/share/zinit/completions/_stale_completion" ]; then
      echo "stale completion still present before zshrc sync" >&2
      exit 17
    fi
    exit 0
    ;;
  * )
    exit 0
    ;;
esac
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh stale zinit completion cleanup failed"
	fi

	assert_file_missing "$stale_link"
	assert_contains "zinit cclear" "$zsh_calls"
	assert_contains "ZINIT_SYNC=1 source '$tmp_home/.zshrc'" "$zsh_calls"
}

test_dotfiles_warns_when_zinit_plugin_sync_fails() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	mkdir -p "$tmp_home/.local/share/zinit/zinit.git"
	: >"$tmp_home/.local/share/zinit/zinit.git/zinit.zsh"

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
cmd="$2"
case "$cmd" in
  *"zinit cclear"*)
    exit 0
    ;;
  *"ZINIT_SYNC=1 source '$HOME/.zshrc'"*)
    exit 23
    ;;
  *)
    exit 0
    ;;
esac
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh zinit sync warning test failed"
	fi

	assert_contains "Zinit completions 已清理" "$log"
	assert_contains "Zinit 插件安装失败" "$log"
}

test_zsh_open_wrapper_preserves_codex_deep_links() {
	local tmp_home fake_bin open_log codex_url bundle_id first_call second_call
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	open_log="$tmp_home/open.log"
	codex_url="codex://threads/019dcc72-81d8-7e41-bb02-cdd44b6cba4a"
	bundle_id="com.openai.codex"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zprofile" "$tmp_home/.zprofile"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"

	cat >"$fake_bin/open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/open.log"
exit 0
EOF
	chmod +x "$fake_bin/open"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM="xterm-256color" \
		zsh -ic "open -b $bundle_id -u '$codex_url'; open '$tmp_home/.zshrc'" >/dev/null 2>&1; then
		fail "zsh open wrapper regression fixture failed"
	fi

	assert_file_exists "$open_log"
	first_call=$(sed -n '1p' "$open_log")
	second_call=$(sed -n '2p' "$open_log")

	assert_equal "-b $bundle_id -u $codex_url" "$first_call" "deep-link open call"
	assert_equal "-R $tmp_home/.zshrc" "$second_call" "path reveal open call"
}

test_zsh_codex_wrapper_pins_interactive_launches() {
	local tmp_home fake_bin codex_log first_call second_call third_call
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	codex_log="$tmp_home/codex.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"

	cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
printf 'CALL\n' >>"$HOME/codex.log"
for arg in "$@"; do
	printf '[%s]\n' "$arg" >>"$HOME/codex.log"
done
EOF
	chmod +x "$fake_bin/codex"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM="xterm-256color" \
		zsh -ic 'codex "hello world"; codex app "$HOME"; codex exec "skip"' >/dev/null 2>&1; then
		fail "zsh codex wrapper fixture failed"
	fi

	first_call="$tmp_home/codex-call-1.log"
	second_call="$tmp_home/codex-call-2.log"
	third_call="$tmp_home/codex-call-3.log"
	awk 'BEGIN { n = 0 } /^CALL$/ { n++; next } n == 1 { print }' "$codex_log" >"$first_call"
	awk 'BEGIN { n = 0 } /^CALL$/ { n++; next } n == 2 { print }' "$codex_log" >"$second_call"
	awk 'BEGIN { n = 0 } /^CALL$/ { n++; next } n == 3 { print }' "$codex_log" >"$third_call"

	assert_contains '[model="gpt-5.5"]' "$first_call"
	assert_contains '[model_reasoning_effort="xhigh"]' "$first_call"
	assert_contains '[service_tier="fast"]' "$first_call"
	assert_contains '[desktop.default-service-tier="priority"]' "$first_call"
	assert_contains '[hello world]' "$first_call"

	assert_contains '[app]' "$second_call"
	assert_contains '[model="gpt-5.5"]' "$second_call"
	assert_contains '[sandbox_mode="danger-full-access"]' "$second_call"
	assert_contains '[desktop.default-service-tier="priority"]' "$second_call"

	assert_contains '[exec]' "$third_call"
	assert_not_contains '[model="gpt-5.5"]' "$third_call"
	assert_not_contains '[service_tier="fast"]' "$third_call"
	assert_not_contains '[desktop.default-service-tier="priority"]' "$third_call"
}

test_codex_launch_defaults_sync_script_pins_config_and_desktop_state() {
	local tmp_home tmp_codex config state state_bak state_check second_log
	local config_mtime state_mtime state_bak_mtime

	if ! command -v node >/dev/null 2>&1; then
		warn "node missing; skipping Codex launch defaults sync script test"
		return 0
	fi

	tmp_home=$(make_temp_dir)
	tmp_codex="$tmp_home/.codex"
	config="$tmp_codex/config.toml"
	state="$tmp_codex/.codex-global-state.json"
	state_bak="$state.bak"
	state_check="$tmp_home/state-check.json"
	second_log="$tmp_home/sync-second.log"
	trap "rm -rf '$tmp_home'" RETURN

	mkdir -p "$tmp_codex"
	cat >"$config" <<'EOF'
model = "old"
service_tier = "standard"

[desktop]
localeOverride = "en-US"
preventSleepWhileRunning = false
conversationDetailMode = "SUMMARY"
default-service-tier = "standard"

[desktop.open-in-target-preferences]
global = "none"
EOF
	cat >"$state" <<'EOF'
{
  "electron-persisted-atom-state": {
    "default-service-tier": "standard",
    "agent-mode-by-host-id": {
      "local": "read-write",
      "remote": "read-write"
    },
    "prompt-history": {
      "global": ["keep me"]
    }
  },
  "unrelated-root-key": "preserved"
}
EOF

	CODEX_HOME="$tmp_codex" HOME="$tmp_home" node "$REPO_ROOT/scripts/sync_codex_launch_defaults.js" >/dev/null

	assert_contains 'model = "gpt-5.5"' "$config"
	assert_contains 'model_context_window = 1050000' "$config"
	assert_contains 'model_auto_compact_token_limit = 900000' "$config"
	assert_contains 'model_reasoning_effort = "xhigh"' "$config"
	assert_contains 'approval_policy = "never"' "$config"
	assert_contains 'sandbox_mode = "danger-full-access"' "$config"
	assert_contains 'service_tier = "fast"' "$config"
	assert_contains 'localeOverride = "zh-CN"' "$config"
	assert_contains 'preventSleepWhileRunning = true' "$config"
	assert_contains 'conversationDetailMode = "STEPS_COMMANDS"' "$config"
	assert_contains 'default-service-tier = "priority"' "$config"
	assert_contains 'global = "vscode"' "$config"

	node - "$state" "$state_bak" >"$state_check" <<'NODE'
const fs = require("fs");
const [statePath, backupPath] = process.argv.slice(2);
for (const filePath of [statePath, backupPath]) {
  const state = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const atom = state["electron-persisted-atom-state"];
  if (atom["default-service-tier"] !== "priority") throw new Error(`${filePath}: speed not priority`);
  if (atom["has-user-changed-service-tier"] !== true) throw new Error(`${filePath}: speed not marked user-set`);
  if (atom["has-seen-fast-mode-announcement"] !== true) throw new Error(`${filePath}: announcement not acknowledged`);
  if (atom["skip-full-access-confirm"] !== true) throw new Error(`${filePath}: full-access prompt not skipped`);
  if (atom["agent-mode-by-host-id"].local !== "full-access") throw new Error(`${filePath}: local mode not full access`);
  if (atom["agent-mode-by-host-id"].remote !== "read-write") throw new Error(`${filePath}: remote mode not preserved`);
  if (atom["prompt-history"].global[0] !== "keep me") throw new Error(`${filePath}: prompt history not preserved`);
  if (state["unrelated-root-key"] !== "preserved") throw new Error(`${filePath}: root state not preserved`);
}
console.log("ok");
NODE
	assert_contains "ok" "$state_check"

	config_mtime="$(file_mtime "$config")"
	state_mtime="$(file_mtime "$state")"
	state_bak_mtime="$(file_mtime "$state_bak")"
	sleep 1
	CODEX_HOME="$tmp_codex" HOME="$tmp_home" node "$REPO_ROOT/scripts/sync_codex_launch_defaults.js" >"$second_log"
	assert_not_contains "Synced Codex launch defaults" "$second_log"
	assert_equal "$config_mtime" "$(file_mtime "$config")" "config mtime after idempotent sync"
	assert_equal "$state_mtime" "$(file_mtime "$state")" "state mtime after idempotent sync"
	assert_equal "$state_bak_mtime" "$(file_mtime "$state_bak")" "state backup mtime after idempotent sync"
}

test_zshrc_does_not_reload_zinit_plugins_when_resourced() {
	local tmp_home load_count
	tmp_home=$(make_temp_dir)
	load_count="$tmp_home/zinit-load-count"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.config/zsh/plugins"

	cat >"$tmp_home/.config/zsh/plugins/zinit.zsh" <<'EOF'
#!/bin/zsh
count=0
[[ -f "$HOME/zinit-load-count" ]] && count=$(<"$HOME/zinit-load-count")
count=$((count + 1))
printf '%s\n' "$count" >"$HOME/zinit-load-count"
EOF

	if ! HOME="$tmp_home" TERM="xterm-256color" zsh -c 'source ~/.zshrc; source ~/.zshrc' >/dev/null 2>&1; then
		fail "re-sourcing .zshrc should succeed in the zinit guard fixture"
	fi

	assert_file_exists "$load_count"
	assert_equal "1" "$(cat "$load_count")" "zinit plugin load count"
}

test_zshrc_detects_preloaded_zinit_without_resourcing_plugin_stack() {
	local tmp_home load_count flag_file
	tmp_home=$(make_temp_dir)
	load_count="$tmp_home/zinit-load-count"
	flag_file="$tmp_home/zinit-guard-flag"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.config/zsh/plugins"

	cat >"$tmp_home/.config/zsh/plugins/zinit.zsh" <<'EOF'
#!/bin/zsh
count=0
[[ -f "$HOME/zinit-load-count" ]] && count=$(<"$HOME/zinit-load-count")
count=$((count + 1))
printf '%s\n' "$count" >"$HOME/zinit-load-count"
EOF

	if ! HOME="$tmp_home" TERM="xterm-256color" zsh -c 'zinit() { :; }; source ~/.zshrc; print -r -- "${DOTFILES_ZINIT_LOADED:-unset}" >"$HOME/zinit-guard-flag"' >/dev/null 2>&1; then
		fail "preloaded-zinit .zshrc source should succeed"
	fi

	assert_file_exists "$flag_file"
	assert_equal "1" "$(cat "$flag_file")" "zinit guard flag"
	assert_file_missing "$load_count"
}

test_zshrc_kitty_ssh_wrapper_defaults_to_kitten_and_supports_opt_out() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/ssh-wrapper.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.cache/zsh"

	cat >"$fake_bin/ssh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-G" ]; then
	case " $* " in
	*" native-host "*)
		printf '%s\n' 'setenv KITTEN_SSH=0'
		;;
	*)
		printf '%s\n' 'hostname default-host'
		;;
	esac
	exit 0
fi
printf 'native:%s\n' "$*" >>"$SSH_WRAPPER_LOG"
EOF

	cat >"$fake_bin/kitten" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "ssh" ]; then
	shift
	printf 'kitten:%s\n' "$*" >>"$SSH_WRAPPER_LOG"
	exit 0
fi
exit 1
EOF
	chmod +x "$fake_bin/ssh" "$fake_bin/kitten"

	if ! HOME="$tmp_home" ZSH_CACHE_DIR="$tmp_home/.cache/zsh" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		TERM="xterm-256color" KITTY_WINDOW_ID=1 SSH_WRAPPER_LOG="$log" zsh -fic '
			source "$HOME/.zshrc"
			ssh default-host
			ssh native-host
			KITTEN_SSH=0 ssh env-opt-out-host
		' >/dev/null 2>&1; then
		fail "kitty ssh wrapper fixture should execute"
	fi

	assert_contains "kitten:default-host" "$log"
	assert_contains "native:native-host" "$log"
	assert_contains "native:env-opt-out-host" "$log"
}

test_zshrc_publishes_kitty_context_cwd_user_var() {
	local tmp_home log context_dir socket_path
	tmp_home=$(make_temp_dir)
	log="$tmp_home/kitty-context.log"
	context_dir="$tmp_home/project with spaces"
	socket_path="$tmp_home/kitty.sock"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.cache/zsh" "$context_dir"

	if ! HOME="$tmp_home" ZSH_CACHE_DIR="$tmp_home/.cache/zsh" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		TERM="xterm-256color" KITTY_WINDOW_ID=123 KITTY_LISTEN_ON="unix:$socket_path" \
		KITTY_CONTEXT_LOG="$log" CONTEXT_DIR="$context_dir" zsh -fic '
			zmodload zsh/net/socket
			zsocket -l "${KITTY_LISTEN_ON#unix:}"
			listener_fd=$REPLY
			source "$HOME/.zshrc"
			cd "$CONTEXT_DIR"
			_dotfiles_kitty_publish_context_cwd
			_dotfiles_kitty_publish_context_cwd
			zsocket -a -t "$listener_fd"
			connection_fd=$REPLY
			context_payload=""
			while IFS= read -r -u "$connection_fd" -k 1 context_char; do
				context_payload+="$context_char"
			done
			print -rn -- "$context_payload" >"$KITTY_CONTEXT_LOG"
			exec {connection_fd}>&-
			exec {listener_fd}>&-
		' >/dev/null 2>&1; then
		fail "kitty context cwd publisher fixture should execute"
	fi

	assert_contains "@kitty-cmd" "$log"
	assert_contains '"cmd":"set-user-vars"' "$log"
	assert_contains '"kitty_window_id":"123"' "$log"
	assert_contains "dotfiles_context_cwd=$context_dir" "$log"
	assert_equal "1" "$(grep -o '@kitty-cmd' "$log" | wc -l | tr -d ' ')" "kitty context cwd should publish only when changed"
}

test_zshrc_publishes_kitty_context_cwd_via_socket_fallback() {
	local tmp_home log context_dir socket_path
	tmp_home=$(make_temp_dir)
	log="$tmp_home/kitty-context-fallback.log"
	context_dir="$tmp_home/project"
	socket_path="$tmp_home/kitty.sock"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.cache/zsh" "$context_dir"

	if ! HOME="$tmp_home" ZSH_CACHE_DIR="$tmp_home/.cache/zsh" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		TERM="xterm-256color" KITTY_WINDOW_ID=123 KITTY_LISTEN_ON='' DOTFILES_KITTY_SOCKET_PATH="$socket_path" \
		KITTY_CONTEXT_LOG="$log" CONTEXT_DIR="$context_dir" zsh -fic '
			zmodload zsh/net/socket
			zsocket -l "$DOTFILES_KITTY_SOCKET_PATH"
			listener_fd=$REPLY
			source "$HOME/.zshrc"
			cd "$CONTEXT_DIR"
			_dotfiles_kitty_publish_context_cwd
			zsocket -a -t "$listener_fd"
			connection_fd=$REPLY
			context_payload=""
			while IFS= read -r -u "$connection_fd" -k 1 context_char; do
				context_payload+="$context_char"
			done
			print -rn -- "$context_payload" >"$KITTY_CONTEXT_LOG"
			exec {connection_fd}>&-
			exec {listener_fd}>&-
		' >/dev/null 2>&1; then
		fail "kitty context cwd fallback publisher fixture should execute"
	fi

	assert_contains '"cmd":"set-user-vars"' "$log"
	assert_contains '"kitty_window_id":"123"' "$log"
	assert_contains "dotfiles_context_cwd=$context_dir" "$log"
}

test_ssh_config_uses_setenv_for_kitten_ssh_opt_outs() {
	local config
	config="$REPO_ROOT/.ssh/config"

	[[ ! -e "$REPO_ROOT/.config/kitty/ssh.conf" ]] || fail "kitty ssh.conf should not be managed by dotfiles"
	python3 - "$config" <<'PY'
import pathlib
import sys

config = pathlib.Path(sys.argv[1])
blocks = {}
current_hosts = []
for raw_line in config.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if parts and parts[0].lower() == "host":
        current_hosts = [host.lower() for host in parts[1:]]
        for host in current_hosts:
            blocks.setdefault(host, [])
    elif current_hosts:
        for host in current_hosts:
            blocks.setdefault(host, []).append(line.lower())

fedora = blocks.get("fedora", [])
orb = blocks.get("orb", [])
if "setenv kitten_ssh=0" not in fedora:
    raise SystemExit("fedora should opt out of kitten ssh via SetEnv KITTEN_SSH=0")
if "setenv kitten_ssh=0" in orb:
    raise SystemExit("orb must keep kitten ssh enabled for Cmd+E remote cwd cloning")
PY
}

test_dotfiles_removes_legacy_managed_kitty_ssh_conf() {
	local tmp_home fake_bin log superpowers_repo legacy
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	legacy="$tmp_home/.config/kitty/ssh.conf"
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	mkdir -p "$(dirname "$legacy")"
	cat >"$legacy" <<'EOF'
# Hosts listed here are intentionally delegated to plain OpenSSH because their
# SSH config uses features that conflict with kitten ssh's remote bootstrap.
#
# Do not add OrbStack's `orb` host here: Cmd+E/Cmd+N remote directory cloning
# depends on the SSH kitten metadata and OSC 7 cwd reports that `delegate ssh`
# disables.
hostname fedora
delegate ssh
EOF

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh legacy kitty ssh.conf cleanup failed"
	fi

	assert_file_missing "$legacy"
}

test_zshrc_skips_prompt_stack_for_interactive_shell_without_tty() {
	local tmp_home prompt_stack_marker log timeout_cmd zsh_bin
	tmp_home=$(make_temp_dir)
	prompt_stack_marker="$tmp_home/prompt-stack-loaded"
	log="$tmp_home/no-tty-zsh.log"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"
	mkdir -p "$tmp_home/.config/zsh/plugins"

	cat >"$tmp_home/.config/zsh/plugins/zinit.zsh" <<'EOF'
#!/bin/zsh
printf 'loaded\n' >"$HOME/prompt-stack-loaded"
EOF

	if command -v gtimeout >/dev/null 2>&1; then
		timeout_cmd="gtimeout"
	elif command -v timeout >/dev/null 2>&1; then
		timeout_cmd="timeout"
	else
		timeout_cmd=""
	fi
	if [[ -x /bin/zsh ]]; then
		zsh_bin="/bin/zsh"
	else
		zsh_bin="$(command -v zsh)"
	fi

	if [[ -n "$timeout_cmd" ]]; then
		if ! HOME="$tmp_home" TERM="xterm-256color" "$timeout_cmd" 10 "$zsh_bin" -ic 'print -r -- no-tty-shell-ok' >"$log" 2>&1; then
			cat "$log" >&2
			fail "interactive zsh without tty should keep command execution usable"
		fi
	elif ! HOME="$tmp_home" TERM="xterm-256color" "$zsh_bin" -ic 'print -r -- no-tty-shell-ok' >"$log" 2>&1; then
		cat "$log" >&2
		fail "interactive zsh without tty should keep command execution usable"
	fi

	[[ "$(<"$log")" == *"no-tty-shell-ok"* ]] || fail "Expected no-tty shell command output in $log"
	assert_file_missing "$prompt_stack_marker"
}

test_zsh_history_alias_shows_newest_first_with_timestamps() {
	local tmp_home log first_line second_line
	tmp_home=$(make_temp_dir)
	log="$tmp_home/history.log"
	trap "rm -rf '$tmp_home'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"

	if ! HOME="$tmp_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TERM="xterm-256color" zsh -f -c '
		source "$HOME/.zshenv"
		alias history="fc -l 1"
		typeset -g DOTFILES_ZINIT_LOADED=1
		source "$HOME/.zshrc"
		print -s -- "older command"
		print -s -- "newer command"
		eval history
	' >"$log" 2>&1; then
		cat "$log" >&2
		fail "history alias fixture failed"
	fi

	first_line=$(sed -n '1p' "$log")
	second_line=$(sed -n '2p' "$log")

	[[ "$first_line" == *"newer command" ]] || fail "Expected newest history entry first, got: $first_line"
	[[ "$second_line" == *"older command" ]] || fail "Expected older history entry second, got: $second_line"
	assert_grep '^[[:space:]]*[0-9]+[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}[[:space:]]+newer command$' "$log"
}

test_zsh_fzf_wrapper_streams_piped_input_without_prefetch() {
	local tmp_home fake_bin log fzf_start_line producer_done_line
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/fzf.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cp "$REPO_ROOT/.zshenv" "$tmp_home/.zshenv"
	cp "$REPO_ROOT/.zshrc" "$tmp_home/.zshrc"

	cat >"$fake_bin/fzf" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--zsh" ]; then
	exit 0
fi
printf '%s\n' "fzf-start" >>"$HOME/fzf.log"
IFS= read -r first_line || first_line=""
printf 'first=%s\n' "$first_line" >>"$HOME/fzf.log"
cat >/dev/null
EOF
	chmod +x "$fake_bin/fzf"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" TERM="xterm-256color" zsh -f -c '
		source "$HOME/.zshenv"
		source "$HOME/.zshrc"
		{
			print -r -- "producer-first" >>"$HOME/fzf.log"
			print -r -- $'\''\e[31mfirst\e[0m'\''
			sleep 1
			print -r -- "producer-done" >>"$HOME/fzf.log"
			print -r -- "second"
		} | fzf >/dev/null
	' >"$tmp_home/zsh.log" 2>&1; then
		cat "$tmp_home/zsh.log" >&2
		fail "fzf streaming fixture failed"
	fi

	assert_file_exists "$log"
	fzf_start_line=$(awk '/^fzf-start$/ { print NR; exit }' "$log")
	producer_done_line=$(awk '/^producer-done$/ { print NR; exit }' "$log")

	[[ -n "$fzf_start_line" ]] || fail "Expected fake fzf to start; log: $(cat "$log")"
	[[ -n "$producer_done_line" ]] || fail "Expected producer completion marker; log: $(cat "$log")"
	(( fzf_start_line < producer_done_line )) || fail "fzf should start before producer finishes; log: $(cat "$log")"
	assert_contains "first=first" "$log"
}

test_age_tokens_does_not_leak_decrypted_values_under_xtrace() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/age-tokens.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$tmp_home/.ssh"
	: >"$tmp_home/.ssh/id_ed25519"
	: >"$tmp_home/.ssh/id_ed25519.pub"
	: >"$tmp_home/.tokens.sh.age"

	cat >"$fake_bin/age" <<'EOF'
#!/bin/sh
cat <<'INNER'
export TEST_AGE_SECRET="super-secret"
INNER
EOF
	chmod +x "$fake_bin/age"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" zsh -c \
		'setopt xtrace; source "'"$REPO_ROOT"'/.config/zsh/plugins/age-tokens.zsh"' >"$log" 2>&1; then
		cat "$log" >&2
		fail "age-tokens xtrace fixture failed"
	fi

	assert_not_contains 'TEST_AGE_SECRET="super-secret"' "$log"
}

test_dotfiles_uninstall_preserves_modified_files() {
	local tmp_home fake_bin install_log uninstall_log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	install_log="$tmp_home/install-dotfiles.log"
	uninstall_log="$tmp_home/uninstall-dotfiles.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$install_log"; then
		cat "$install_log" >&2
		fail "install_dotfiles.sh failed"
	fi

	printf '\n# user change\n' >>"$tmp_home/.zshrc"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/uninstall.sh" --dotfiles --force >"$uninstall_log" 2>&1; then
		cat "$uninstall_log" >&2
		fail "uninstall.sh --dotfiles failed"
	fi

	assert_file_exists "$tmp_home/.zshrc"
	assert_file_missing "$tmp_home/.gitconfig"
	assert_file_missing "$tmp_home/.codex/config.toml"
	assert_file_missing "$tmp_home/.codex/superpowers"
	assert_file_missing "$tmp_home/.agents/skills/superpowers"
	assert_file_missing "$tmp_home/.local/state/dotfiles/superpowers.env"
	assert_file_exists "$tmp_home/.claude.json"
	assert_file_exists "$tmp_home/.claude/settings.json"
	if [[ -f "$tmp_home/.ssh/config" ]]; then
		assert_not_contains "# >>> Dotfiles SSH Include >>>" "$tmp_home/.ssh/config"
	fi
}

test_claude_runtime_config_preserves_existing_state() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-runtime-config.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$tmp_home/.claude.json" <<'EOF'
{
  "numStartups": 42,
  "installMethod": "native",
  "autoUpdates": true
}
EOF

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh runtime config merge failed"
	fi

	assert_contains '"numStartups": 42' "$tmp_home/.claude.json"
	assert_not_contains '"installMethod": "native"' "$tmp_home/.claude.json"
	assert_contains '"autoUpdates": false' "$tmp_home/.claude.json"
}

test_gitconfig_identity_migrates_to_local() {
	local tmp_home fake_bin install_log uninstall_log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	install_log="$tmp_home/install-gitconfig.log"
	uninstall_log="$tmp_home/uninstall-gitconfig.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$tmp_home/.gitconfig" <<'EOF'
[user]
	name = Legacy User
	email = legacy@example.com
EOF

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$install_log"; then
		cat "$install_log" >&2
		fail "install_dotfiles.sh gitconfig migration failed"
	fi

	assert_file_exists "$tmp_home/.gitconfig"
	assert_file_exists "$tmp_home/.gitconfig.local"
	assert_contains "[include]" "$tmp_home/.gitconfig"
	assert_contains "path = ~/.gitconfig.local" "$tmp_home/.gitconfig"
	assert_contains "name = Legacy User" "$tmp_home/.gitconfig.local"
	assert_contains "email = legacy@example.com" "$tmp_home/.gitconfig.local"
	assert_not_contains "Legacy User" "$tmp_home/.gitconfig"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/uninstall.sh" --dotfiles --force >"$uninstall_log" 2>&1; then
		cat "$uninstall_log" >&2
		fail "uninstall.sh gitconfig preservation failed"
	fi

	assert_file_missing "$tmp_home/.gitconfig"
	assert_file_exists "$tmp_home/.gitconfig.local"
	assert_contains "name = Legacy User" "$tmp_home/.gitconfig.local"
}

test_dotfiles_hook_free_fallback() {
	local tmp_home fake_bin log superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-fallback.log"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	cat >"$fake_bin/jq" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/python3" <<'EOF'
#!/bin/sh
exit 1
EOF
	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/jq" "$fake_bin/python3" "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh fallback failed"
	fi

	assert_file_exists "$tmp_home/.claude/settings.json"
	assert_file_exists "$tmp_home/.claude.json"
	assert_contains '"autoUpdates": false' "$tmp_home/.claude.json"
	assert_not_contains "PostToolUse" "$tmp_home/.claude/settings.json"
}

test_codex_config_installs_without_computer_use_cache() {
	local tmp_home codex_dest
	tmp_home=$(make_temp_dir)
	codex_dest="$tmp_home/.codex/config.toml"
	trap "rm -rf '$tmp_home'" RETURN

	if ! HOME="$tmp_home" CODEX_LATEST_MODEL_URL="" bash "$REPO_ROOT/scripts/deploy_codex_config.sh" "$REPO_ROOT/.codex/config.toml" "$codex_dest" "$tmp_home"; then
		fail "deploy_codex_config.sh should succeed without computer-use cache"
	fi

	assert_file_exists "$codex_dest"
	assert_contains '# Shared Codex CLI / Codex.app configuration baseline.' "$codex_dest"
	assert_contains '[marketplaces.openai-bundled]' "$codex_dest"
	assert_contains "source = \"$tmp_home/.codex/.tmp/bundled-marketplaces/openai-bundled\"" "$codex_dest"
	assert_contains "[projects.\"$tmp_home\"]" "$codex_dest"
	assert_not_contains 'notify = [' "$codex_dest"
}

test_codex_config_preserves_projects_and_keeps_home_subprojects() {
	local tmp_home fake_bin log external_project child_project superpowers_repo
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-codex.log"
	external_project="/tmp/codex-external-project"
	child_project="$tmp_home/redundant-project"
	superpowers_repo=$(make_fake_superpowers_repo)
	trap "rm -rf '$tmp_home' '$fake_bin' '$superpowers_repo'" RETURN

	mkdir -p "$tmp_home/.codex"
	mkdir -p "$tmp_home/.codex/plugins/cache/openai-bundled/computer-use/1.0.999/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS"
	: >"$tmp_home/.codex/plugins/cache/openai-bundled/computer-use/1.0.999/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
	cat >"$tmp_home/.codex/config.toml" <<EOF
model = "legacy"

[projects."$external_project"]
trust_level = "trusted"

[projects."$child_project"]
trust_level = "trusted"
EOF

	cat >"$fake_bin/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/keychain" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/zsh" "$fake_bin/keychain"

	if ! run_dotfiles_install "$tmp_home" "$fake_bin" "$superpowers_repo" "$log"; then
		cat "$log" >&2
		fail "install_dotfiles.sh codex merge failed"
	fi

	assert_contains 'model = "gpt-5.5"' "$tmp_home/.codex/config.toml"
	assert_contains '# Shared Codex CLI / Codex.app configuration baseline.' "$tmp_home/.codex/config.toml"
	assert_contains 'goals = true' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.openaiDeveloperDocs]' "$tmp_home/.codex/config.toml"
	assert_contains 'url = "https://developers.openai.com/mcp"' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.github]' "$tmp_home/.codex/config.toml"
	assert_contains 'url = "https://api.githubcopilot.com/mcp/"' "$tmp_home/.codex/config.toml"
	assert_contains 'bearer_token_env_var = "GITHUB_PERSONAL_ACCESS_TOKEN"' "$tmp_home/.codex/config.toml"
	assert_not_contains '[mcp_servers.cloudflare-api-full]' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.tavily]' "$tmp_home/.codex/config.toml"
	assert_contains 'args = ["-y", "tavily-mcp"]' "$tmp_home/.codex/config.toml"
	assert_contains 'env_vars = ["TAVILY_API_KEY"]' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.fetch]' "$tmp_home/.codex/config.toml"
	assert_contains 'args = ["-y", "@kazuph/mcp-fetch"]' "$tmp_home/.codex/config.toml"
	assert_contains '[mcp_servers.chrome-devtools]' "$tmp_home/.codex/config.toml"
	assert_contains 'command = "npx"' "$tmp_home/.codex/config.toml"
	assert_contains '"chrome-devtools-mcp@latest"' "$tmp_home/.codex/config.toml"
	assert_contains "\"--user-data-dir=$tmp_home/.cache/chrome-devtools-mcp/chrome-profile\"" "$tmp_home/.codex/config.toml"
	assert_contains '"--redact-network-headers"' "$tmp_home/.codex/config.toml"
	assert_contains '"--no-usage-statistics"' "$tmp_home/.codex/config.toml"
	assert_contains '"--viewport=1600x1000"' "$tmp_home/.codex/config.toml"
	assert_contains 'startup_timeout_sec = 120' "$tmp_home/.codex/config.toml"
	assert_not_contains 'args = ["-lc",' "$tmp_home/.codex/config.toml"
	assert_contains "notify = [\"$tmp_home/.codex/plugins/cache/openai-bundled/computer-use/1.0.999/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient\", \"turn-ended\"]" "$tmp_home/.codex/config.toml"
	assert_contains '[marketplaces.openai-bundled]' "$tmp_home/.codex/config.toml"
	assert_contains "source = \"$tmp_home/.codex/.tmp/bundled-marketplaces/openai-bundled\"" "$tmp_home/.codex/config.toml"
	assert_contains '[plugins."browser-use@openai-bundled"]' "$tmp_home/.codex/config.toml"
	assert_contains '[plugins."computer-use@openai-bundled"]' "$tmp_home/.codex/config.toml"
	assert_contains '[plugins."cloudflare@openai-curated"]' "$tmp_home/.codex/config.toml"
	assert_contains '[plugins."browser@openai-bundled"]' "$tmp_home/.codex/config.toml"
	assert_contains '[plugins."chrome@openai-bundled"]' "$tmp_home/.codex/config.toml"
	assert_contains '[desktop.open-in-target-preferences]' "$tmp_home/.codex/config.toml"
	assert_contains 'global = "vscode"' "$tmp_home/.codex/config.toml"
	assert_contains '[desktop.open-in-target-preferences.perPath]' "$tmp_home/.codex/config.toml"
	assert_contains "\"$tmp_home\" = \"vscode\"" "$tmp_home/.codex/config.toml"
	assert_contains "[projects.\"$external_project\"]" "$tmp_home/.codex/config.toml"
	assert_contains "[projects.\"$tmp_home\"]" "$tmp_home/.codex/config.toml"
	assert_contains "[projects.\"$child_project\"]" "$tmp_home/.codex/config.toml"
}

test_codex_config_uses_latest_model_guide_when_available() {
	local tmp_home fake_bin codex_dest curl_log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	codex_dest="$tmp_home/.codex/config.toml"
	curl_log="$tmp_home/curl.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$curl_log"
	cat <<'INNER'
---
latestModelInfo:
  model: gpt-9.9
  migrationGuide: /api/docs/guides/upgrading-to-gpt-9p9.md
  promptingGuide: /api/docs/guides/prompt-guidance.md
---
INNER
EOF
	chmod +x "$fake_bin/curl"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		CODEX_LATEST_MODEL_URL="https://example.test/latest-model.md" \
		bash "$REPO_ROOT/scripts/deploy_codex_config.sh" "$REPO_ROOT/.codex/config.toml" "$codex_dest" "$tmp_home"; then
		fail "deploy_codex_config.sh should resolve the latest model from the guide"
	fi

	assert_contains 'model = "gpt-9.9"' "$codex_dest"
	assert_contains "https://example.test/latest-model.md" "$curl_log"
}

test_codex_config_falls_back_when_latest_model_lookup_fails() {
	local tmp_home fake_bin codex_dest
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	codex_dest="$tmp_home/.codex/config.toml"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod +x "$fake_bin/curl"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		CODEX_LATEST_MODEL_URL="https://example.test/latest-model.md" \
		bash "$REPO_ROOT/scripts/deploy_codex_config.sh" "$REPO_ROOT/.codex/config.toml" "$codex_dest" "$tmp_home"; then
		fail "deploy_codex_config.sh should fall back when latest model lookup fails"
	fi

	assert_contains 'model = "gpt-5.5"' "$codex_dest"
}

test_pixi_prefers_managed_install_over_system_binary() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-pixi.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/pixi" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo 'pixi system 1.0.0' ;;
  install|list) exit 0 ;;
  *) exit 0 ;;
esac
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
cat <<'INNER'
#!/bin/sh
mkdir -p "$HOME/.pixi/bin"
cat >"$HOME/.pixi/bin/pixi" <<'EOF_PIXI'
#!/bin/sh
case "$1" in
  --version) echo 'pixi managed 2.0.0' ;;
  install|list) exit 0 ;;
  *) exit 0 ;;
esac
EOF_PIXI
chmod +x "$HOME/.pixi/bin/pixi"
INNER
EOF
	chmod +x "$fake_bin/pixi" "$fake_bin/curl"

	cat >"$tmp_home/pixi.toml" <<'EOF'
[workspace]
name = "home"
channels = ["conda-forge"]
platforms = ["linux-64"]
EOF

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh \
		bash "$REPO_ROOT/scripts/install_pixi.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_pixi.sh failed"
	fi

	assert_executable "$tmp_home/.pixi/bin/pixi"
	assert_contains "Pixi 已可用: pixi managed 2.0.0" "$log"
}

test_claude_optional_on_macos_when_missing() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-claude-macos.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Darwin
else
  echo arm64
fi
EOF
	cat >"$fake_bin/rustup" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/npm" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/dotnet" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/rustup" "$fake_bin/npm" "$fake_bin/dotnet" "$fake_bin/curl"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/scripts/install_claude_code.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_claude_code.sh should be optional on macOS"
	fi

	assert_contains "跳过 Claude 插件/MCP 配置" "$log"
}

test_install_node_clis_linux_uses_home_local_prefix() {
	local tmp_home fake_bin log npm_log state_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-node-clis-linux.log"
	npm_log="$tmp_home/npm-node-clis-linux.log"
	state_file="$tmp_home/.local/state/dotfiles/node-cli-npm-global.tsv"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Linux
else
  echo x86_64
fi
EOF
	cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$npm_log"
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/npm"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/install_node_clis.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_node_clis.sh Linux test failed"
	fi

	assert_file_exists "$tmp_home/.npmrc"
	assert_contains "prefix=$tmp_home/.local" "$tmp_home/.npmrc"
	assert_file_exists "$state_file"
	assert_contains $'prefix\t'"$tmp_home/.local" "$state_file"
	assert_contains "install -g @anthropic-ai/claude-code@latest" "$npm_log"
	assert_contains "install -g @openai/codex@latest" "$npm_log"
	assert_contains "install -g ccusage@latest" "$npm_log"
	assert_contains "install -g @mermaid-js/mermaid-cli@latest" "$npm_log"
	assert_contains "install -g typescript-language-server@latest" "$npm_log"
	assert_contains "install -g typescript@latest" "$npm_log"
	assert_contains "install -g intelephense@latest" "$npm_log"
}

test_install_node_clis_macos_keeps_default_prefix() {
	local tmp_home fake_bin log npm_log brew_log state_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-node-clis-macos.log"
	npm_log="$tmp_home/npm-node-clis-macos.log"
	brew_log="$tmp_home/brew-node-clis-macos.log"
	state_file="$tmp_home/.local/state/dotfiles/node-cli-npm-global.tsv"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Darwin
else
  echo arm64
fi
EOF
	cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$npm_log"
if [ "\$1" = "prefix" ] && [ "\$2" = "-g" ]; then
  echo /opt/homebrew
  exit 0
fi
if [ "\$1" = "config" ] && [ "\$2" = "get" ] && [ "\$3" = "prefix" ]; then
  echo /opt/homebrew
  exit 0
	fi
	exit 0
EOF
	cat >"$fake_bin/brew" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$brew_log"
case "\$1 \$2 \$3" in
  "list --cask codex")
    exit 0
    ;;
  "list --formula typescript"|"list --formula typescript-language-server")
    exit 0
    ;;
esac
case "\$1 \$2 \$3" in
  "uninstall --cask codex")
    exit 0
    ;;
esac
case "\$1 \$2" in
  "uninstall typescript"|"uninstall typescript-language-server")
    exit 0
    ;;
esac
exit 1
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/npm" "$fake_bin/brew"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" DOTFILES_UPDATE_MODE="upgrade" \
		bash "$REPO_ROOT/scripts/install_node_clis.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_node_clis.sh macOS test failed"
	fi

	assert_file_missing "$tmp_home/.npmrc"
	assert_file_exists "$state_file"
	assert_contains $'prefix\t/opt/homebrew' "$state_file"
	assert_contains "uninstall --cask codex" "$brew_log"
	assert_contains "uninstall typescript" "$brew_log"
	assert_contains "uninstall typescript-language-server" "$brew_log"
	assert_contains "install -g @anthropic-ai/claude-code@latest" "$npm_log"
	assert_contains "install -g ccusage@latest" "$npm_log"
}

test_claude_optional_on_linux_when_install_fails() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-claude-linux.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Linux
else
  echo x86_64
fi
EOF
	cat >"$fake_bin/rustup" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/npm" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/dotnet" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 99
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/rustup" "$fake_bin/npm" "$fake_bin/dotnet" "$fake_bin/curl"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/scripts/install_claude_code.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_claude_code.sh should be optional on Linux"
	fi

	assert_contains "Claude Code CLI 未安装，跳过 Claude 插件/MCP 配置" "$log"
}

test_dotfiles_uninstall_removes_managed_node_clis() {
	local tmp_home fake_bin log npm_log state_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/uninstall-node-clis.log"
	npm_log="$tmp_home/npm-uninstall-node-clis.log"
	state_file="$tmp_home/.local/state/dotfiles/node-cli-npm-global.tsv"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$npm_log"
exit 0
EOF
	chmod +x "$fake_bin/npm"

	mkdir -p "$(dirname "$state_file")"
	cat >"$state_file" <<EOF
prefix	$tmp_home/.local
package	@anthropic-ai/claude-code	0
package	@openai/codex	1
package	@mermaid-js/mermaid-cli	0
package	ccusage	0
EOF

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/uninstall.sh" --dotfiles --force >"$log" 2>&1; then
		cat "$log" >&2
		fail "uninstall.sh managed node cli cleanup failed"
	fi

	assert_contains "uninstall -g @anthropic-ai/claude-code" "$npm_log"
	assert_contains "uninstall -g @mermaid-js/mermaid-cli" "$npm_log"
	assert_contains "uninstall -g ccusage" "$npm_log"
	assert_not_contains "@openai/codex" "$npm_log"
	assert_file_missing "$state_file"
}

test_dotfiles_uninstall_clears_node_cli_state_when_prefix_is_gone() {
	local tmp_home fake_bin log state_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/uninstall-node-clis-missing-prefix.log"
	state_file="$tmp_home/.local/state/dotfiles/node-cli-npm-global.tsv"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$(dirname "$state_file")"
	cat >"$state_file" <<EOF
prefix	$tmp_home/.local/missing-prefix
package	@anthropic-ai/claude-code	0
EOF

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/uninstall.sh" --dotfiles --force >"$log" 2>&1; then
		cat "$log" >&2
		fail "uninstall.sh missing-prefix state cleanup failed"
	fi

	assert_file_missing "$state_file"
	assert_contains "Node CLI 托管状态" "$log"
}

test_claude_known_hosts_preserves_symlink() {
	local tmp_home fake_bin log real_known_hosts
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-claude-known-hosts.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo 'claude 1.0.0'; exit 0 ;;
  plugin)
    case "$2" in
      list|install|uninstall) exit 0 ;;
      marketplace) exit 0 ;;
    esac
    ;;
  mcp)
    case "$2" in
      list|add|add-json|remove) exit 0 ;;
    esac
    ;;
esac
exit 0
EOF
	cat >"$fake_bin/rustup" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/npm" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/dotnet" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$fake_bin/claude" "$fake_bin/rustup" "$fake_bin/npm" "$fake_bin/dotnet" "$fake_bin/curl"

	mkdir -p "$tmp_home/.ssh"
	cat >"$tmp_home/.claude.json" <<'EOF'
{
  "installMethod": "native",
  "autoUpdates": true
}
EOF
	real_known_hosts="$tmp_home/shared-known-hosts"
	printf 'existing.example ssh-ed25519 AAAAOLD\n' >"$real_known_hosts"
	ln -s "$real_known_hosts" "$tmp_home/.ssh/known_hosts"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$REPO_ROOT/scripts/install_claude_code.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_claude_code.sh symlink known_hosts test failed"
	fi

	assert_symlink "$tmp_home/.ssh/known_hosts"
	assert_grep '^github.com ssh-ed25519 ' "$real_known_hosts"
	assert_file_exists "$tmp_home/.claude.json"
	assert_not_contains '"installMethod": "native"' "$tmp_home/.claude.json"
	assert_contains '"autoUpdates": false' "$tmp_home/.claude.json"
}

test_github_latest_release_uses_github_token() {
	local tmp_home fake_bin curl_log output
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	curl_log="$tmp_home/curl.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$CURL_LOG"
printf '{"tag_name":"v1.2.3"}\n200'
EOF
	chmod +x "$fake_bin/curl"

	output=$(env -u GH_TOKEN HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		CURL_LOG="$curl_log" GITHUB_TOKEN="github-token-value" DOTFILES_LOG_DIR="$tmp_home/logdir" \
		DOTFILES_LOG="$tmp_home/install.log" bash -c ". \"$REPO_ROOT/lib/utils.sh\"; github_latest_release owner/repo")

	assert_equal "v1.2.3" "$output" "latest release tag"
	assert_contains "Authorization: Bearer github-token-value" "$curl_log"
	assert_contains "https://api.github.com/repos/owner/repo/releases/latest" "$curl_log"
}

test_check_github_update_reports_rate_limit_actionably() {
	local tmp_home fake_bin log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
printf '{"message":"API rate limit exceeded for 1.2.3.4."}\n403'
EOF
	chmod +x "$fake_bin/curl"

	if env -u GH_TOKEN -u GITHUB_TOKEN HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		DOTFILES_LOG_DIR="$tmp_home/logdir" DOTFILES_LOG="$log" \
		bash -c ". \"$REPO_ROOT/lib/utils.sh\"; check_github_update 'Kotlin/Native' owner/repo \"$tmp_home/install-dir\""; then
		fail "check_github_update should skip when GitHub API rate limit is exceeded"
	fi

	assert_contains "GitHub API 匿名配额已耗尽" "$log"
	assert_contains "GH_TOKEN" "$log"
	assert_contains "GITHUB_TOKEN" "$log"
}

test_check_github_update_fast_mode_skips_remote_lookup_with_local_version() {
	local tmp_home fake_bin log install_dir curl_log
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install.log"
	install_dir="$tmp_home/install-dir"
	curl_log="$tmp_home/curl.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$install_dir"
	printf 'v1.2.3\n' >"$install_dir/.version"

	cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$curl_log"
printf '{"tag_name":"v9.9.9"}\n200'
EOF
	chmod +x "$fake_bin/curl"

	if env HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		DOTFILES_LOG_DIR="$tmp_home/logdir" DOTFILES_LOG="$log" \
		bash -c ". \"$REPO_ROOT/lib/utils.sh\"; check_github_update 'Kotlin/Native' owner/repo \"$install_dir\""; then
		fail "check_github_update should skip in fast mode when local version exists"
	fi

	assert_file_missing "$curl_log"
	assert_contains "快速模式跳过更新检查" "$log"
}

test_check_github_update_fast_mode_does_not_reuse_local_version_as_remote() {
	local tmp_home fake_bin log install_dir result_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install.log"
	install_dir="$tmp_home/install-dir"
	result_file="$tmp_home/github-latest.txt"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$install_dir"
	printf 'v1.2.3\n' >"$install_dir/.version"

	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 99
EOF
	chmod +x "$fake_bin/curl"

	if env HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		DOTFILES_LOG_DIR="$tmp_home/logdir" DOTFILES_LOG="$log" \
		bash -c ". \"$REPO_ROOT/lib/utils.sh\"; status=0; check_github_update 'Kotlin/Native' owner/repo \"$install_dir\" || status=\$?; printf '%s\n' \"\${_GITHUB_LATEST-unset}\" >\"$result_file\"; exit \"\$status\""; then
		fail "check_github_update should skip in fast mode when local version exists"
	fi

	assert_contains "unset" "$result_file"
}

test_install_node_clis_fast_mode_skips_installed_packages() {
	local tmp_home fake_bin log npm_log state_file
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-node-clis-fast.log"
	npm_log="$tmp_home/npm-node-clis-fast.log"
	state_file="$tmp_home/.local/state/dotfiles/node-cli-npm-global.tsv"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	mkdir -p "$tmp_home/.local/lib/node_modules/@anthropic-ai/claude-code"
	mkdir -p "$tmp_home/.local/lib/node_modules/typescript"
	mkdir -p "$(dirname "$state_file")"
	cat >"$state_file" <<EOF
prefix	$tmp_home/.local
package	@anthropic-ai/claude-code	0
package	typescript	0
EOF

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Linux
else
  echo x86_64
fi
EOF
	cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$npm_log"
exit 0
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/npm"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/install_node_clis.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_node_clis.sh fast-mode test failed"
	fi

	assert_not_contains "install -g @anthropic-ai/claude-code@latest" "$npm_log"
	assert_not_contains "install -g typescript@latest" "$npm_log"
	assert_contains "install -g @openai/codex@latest" "$npm_log"
	assert_contains "install -g ccusage@latest" "$npm_log"
	assert_contains $'package\t@anthropic-ai/claude-code\t0' "$state_file"
	assert_contains $'package\ttypescript\t0' "$state_file"
	assert_contains "快速模式跳过" "$log"
}

test_install_claude_code_fast_mode_skips_plugin_and_marketplace_updates() {
	local tmp_home fake_bin log add_json_log remove_log plugin_install_log plugin_update_log marketplace_update_log
	local plugin_list_output mcp_list_output known_marketplaces repo_dir skill_src
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-claude-fast.log"
	add_json_log="$tmp_home/claude-mcp-add-json.json"
	remove_log="$tmp_home/claude-mcp-remove.log"
	plugin_install_log="$tmp_home/claude-plugin-install.log"
	plugin_update_log="$tmp_home/claude-plugin-update.log"
	marketplace_update_log="$tmp_home/claude-marketplace-update.log"
	known_marketplaces="$tmp_home/.claude/plugins/known_marketplaces.json"
	repo_dir="$tmp_home/.claude/vendor/agent-study-skills"
	skill_src="$repo_dir/study-master-skill"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	plugin_list_output=$'pyright-lsp@claude-plugins-official\ntypescript-lsp@claude-plugins-official\ngopls-lsp@claude-plugins-official\nrust-analyzer-lsp@claude-plugins-official\njdtls-lsp@claude-plugins-official\nclangd-lsp@claude-plugins-official\ncsharp-lsp@claude-plugins-official\nphp-lsp@claude-plugins-official\nkotlin-lsp@claude-plugins-official\nswift-lsp@claude-plugins-official\nlua-lsp@claude-plugins-official\ngithub@claude-plugins-official\ncommit-commands@claude-plugins-official\ncode-simplifier@claude-plugins-official\nclaude-hud@claude-hud\ncodex@openai-codex\nexample-skills@anthropic-agent-skills\nsuperpowers@superpowers-marketplace'
	mcp_list_output=""

	write_fake_claude_cli_with_update_logs "$fake_bin" "$plugin_list_output" "$mcp_list_output" "$add_json_log" "$remove_log" "$plugin_install_log" "$plugin_update_log" "$marketplace_update_log"

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Darwin
else
  echo arm64
fi
EOF
	cat >"$fake_bin/rust-analyzer" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/csharp-ls" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
printf '{"tag_name":"v1.3.13"}\n200'
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/rust-analyzer" "$fake_bin/csharp-ls" "$fake_bin/curl"

	mkdir -p "$(dirname "$known_marketplaces")"
	cat >"$known_marketplaces" <<'EOF'
[
  {"source":{"repo":"anthropics/claude-plugins-official"}},
  {"source":{"repo":"anthropics/skills"}},
  {"source":{"repo":"obra/superpowers-marketplace"}},
  {"source":{"repo":"jarrodwatts/claude-hud"}},
  {"source":{"repo":"openai/codex-plugin-cc"}}
]
EOF

	mkdir -p "$tmp_home/.local/share/lsp/kotlin-language-server"
	printf 'v1.3.13\n' >"$tmp_home/.local/share/lsp/kotlin-language-server/.version"

	git init "$repo_dir" >/dev/null 2>&1
	git -C "$repo_dir" remote add origin "https://github.com/Learner-Geek-Perfectionist/agent-study-skills.git"
	mkdir -p "$skill_src/hooks"
	cat >"$skill_src/SKILL.md" <<'EOF'
# study-master
EOF
	cat >"$skill_src/hooks/check-study_master.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$skill_src/hooks/check-study_master.sh"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/install_claude_code.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_claude_code.sh fast-mode plugin test failed"
	fi

	assert_file_missing "$plugin_install_log"
	assert_file_missing "$plugin_update_log"
	assert_file_missing "$marketplace_update_log"
	assert_file_missing "$tmp_home/.claude/skills/study-master"
	assert_file_missing "$tmp_home/.claude/hooks/check-study_master.sh"
	assert_not_contains 'check-study_master.sh' "$tmp_home/.claude/settings.json"
	assert_contains "快速模式跳过" "$log"
}

test_install_claude_code_hides_superpowers_deprecated_commands() {
	local tmp_home fake_bin log add_json_log remove_log plugin_install_log plugin_update_log marketplace_update_log
	local plugin_list_output mcp_list_output known_marketplaces repo_dir skill_src superpowers_dir hidden_dir
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-claude-hide-superpowers.log"
	add_json_log="$tmp_home/claude-mcp-add-json.json"
	remove_log="$tmp_home/claude-mcp-remove.log"
	plugin_install_log="$tmp_home/claude-plugin-install.log"
	plugin_update_log="$tmp_home/claude-plugin-update.log"
	marketplace_update_log="$tmp_home/claude-marketplace-update.log"
	known_marketplaces="$tmp_home/.claude/plugins/known_marketplaces.json"
	repo_dir="$tmp_home/.claude/vendor/agent-study-skills"
	skill_src="$repo_dir/study-master-skill"
	superpowers_dir="$tmp_home/.claude/plugins/cache/superpowers-marketplace/superpowers/5.0.7"
	hidden_dir="$superpowers_dir/.dotfiles-hidden-commands"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	plugin_list_output=$'pyright-lsp@claude-plugins-official\ntypescript-lsp@claude-plugins-official\ngopls-lsp@claude-plugins-official\nrust-analyzer-lsp@claude-plugins-official\njdtls-lsp@claude-plugins-official\nclangd-lsp@claude-plugins-official\ncsharp-lsp@claude-plugins-official\nphp-lsp@claude-plugins-official\nkotlin-lsp@claude-plugins-official\nswift-lsp@claude-plugins-official\nlua-lsp@claude-plugins-official\ngithub@claude-plugins-official\ncommit-commands@claude-plugins-official\ncode-simplifier@claude-plugins-official\nclaude-hud@claude-hud\ncodex@openai-codex\nexample-skills@anthropic-agent-skills\nsuperpowers@superpowers-marketplace'
	mcp_list_output=""

	write_fake_claude_cli_with_update_logs "$fake_bin" "$plugin_list_output" "$mcp_list_output" "$add_json_log" "$remove_log" "$plugin_install_log" "$plugin_update_log" "$marketplace_update_log"

	cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
if [ "$1" = "-s" ]; then
  echo Darwin
else
  echo arm64
fi
EOF
	cat >"$fake_bin/rust-analyzer" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/csharp-ls" <<'EOF'
#!/bin/sh
exit 0
EOF
	cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
printf '{"tag_name":"v1.3.13"}\n200'
EOF
	chmod +x "$fake_bin/uname" "$fake_bin/rust-analyzer" "$fake_bin/csharp-ls" "$fake_bin/curl"

	mkdir -p "$(dirname "$known_marketplaces")"
	cat >"$known_marketplaces" <<'EOF'
[
  {"source":{"repo":"anthropics/claude-plugins-official"}},
  {"source":{"repo":"anthropics/skills"}},
  {"source":{"repo":"obra/superpowers-marketplace"}},
  {"source":{"repo":"jarrodwatts/claude-hud"}},
  {"source":{"repo":"openai/codex-plugin-cc"}}
]
EOF

	mkdir -p "$tmp_home/.local/share/lsp/kotlin-language-server"
	printf 'v1.3.13\n' >"$tmp_home/.local/share/lsp/kotlin-language-server/.version"

	git init "$repo_dir" >/dev/null 2>&1
	git -C "$repo_dir" remote add origin "https://github.com/Learner-Geek-Perfectionist/agent-study-skills.git"
	mkdir -p "$skill_src/hooks"
	cat >"$skill_src/SKILL.md" <<'EOF'
# study-master
EOF
	cat >"$skill_src/hooks/check-study_master.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$skill_src/hooks/check-study_master.sh"

	mkdir -p "$superpowers_dir/commands"
	printf 'deprecated brainstorm\n' >"$superpowers_dir/commands/brainstorm.md"
	printf 'deprecated write-plan\n' >"$superpowers_dir/commands/write-plan.md"
	printf 'deprecated execute-plan\n' >"$superpowers_dir/commands/execute-plan.md"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/install_claude_code.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_claude_code.sh should hide deprecated superpowers commands"
	fi

	assert_file_missing "$superpowers_dir/commands/brainstorm.md"
	assert_file_missing "$superpowers_dir/commands/write-plan.md"
	assert_file_missing "$superpowers_dir/commands/execute-plan.md"
	assert_file_exists "$hidden_dir/brainstorm.md"
	assert_file_exists "$hidden_dir/write-plan.md"
	assert_file_exists "$hidden_dir/execute-plan.md"
	assert_file_missing "$tmp_home/.claude/skills/study-master"
	assert_file_missing "$tmp_home/.claude/hooks/check-study_master.sh"
	assert_not_contains 'check-study_master.sh' "$tmp_home/.claude/settings.json"
}

test_install_vscode_ext_fast_mode_skips_github_vsix_release_lookup_when_installed() {
	local tmp_home fake_bin log curl_log
	local installed_with_versions installed_without_versions cursor_with_versions cursor_without_versions
	tmp_home=$(make_temp_dir)
	fake_bin=$(make_temp_dir)
	log="$tmp_home/install-vscode-fast.log"
	curl_log="$tmp_home/curl.log"
	trap "rm -rf '$tmp_home' '$fake_bin'" RETURN

	installed_with_versions=$'ms-ceintl.vscode-language-pack-zh-hans@1.0.0\nxaver.clang-format@1.0.0\nrust-lang.rust-analyzer@1.0.0\nfill-labs.dependi@1.0.0\ntamasfe.even-better-toml@1.0.0\ngolang.go@1.0.0\ncharliermarsh.ruff@1.0.0\nvscjava.vscode-java-pack@1.0.0\nfwcd.kotlin@1.0.0\nsumneko.lua@1.0.0\nmkhl.shfmt@1.0.0\nbierner.markdown-mermaid@1.0.0\nmhutchie.git-graph@1.0.0\nms-azuretools.vscode-docker@1.0.0\nhuacnlee.autocorrect@1.0.0\nms-vscode.cpptools@1.0.0\nms-vscode.cpptools-extension-pack@1.0.0\nms-vscode.cmake-tools@1.0.0\nvadimcn.vscode-lldb@1.0.0\nms-python.python@1.0.0\nms-python.vscode-pylance@1.0.0\nms-python.debugpy@1.0.0\nms-vscode-remote.remote-ssh@1.0.0\nms-vscode-remote.remote-ssh-edit@1.0.0\nms-vscode.remote-explorer@1.0.0\nms-vscode-remote.remote-containers@1.0.0\nxin.claude-code-ref@1.0.0'
	installed_without_versions=$(printf '%s\n' "$installed_with_versions" | cut -d@ -f1)
	cursor_with_versions=$'ms-ceintl.vscode-language-pack-zh-hans@1.0.0\nxaver.clang-format@1.0.0\nrust-lang.rust-analyzer@1.0.0\nfill-labs.dependi@1.0.0\ntamasfe.even-better-toml@1.0.0\ngolang.go@1.0.0\ncharliermarsh.ruff@1.0.0\nvscjava.vscode-java-pack@1.0.0\nfwcd.kotlin@1.0.0\nsumneko.lua@1.0.0\nmkhl.shfmt@1.0.0\nbierner.markdown-mermaid@1.0.0\nmhutchie.git-graph@1.0.0\nms-azuretools.vscode-docker@1.0.0\nanysphere.cpptools@1.0.0\nanysphere.cursorpyright@1.0.0\nanysphere.remote-ssh@1.0.0\nanysphere.remote-containers@1.0.0\nhuacnlee.autocorrect@1.0.0\nxin.claude-code-ref@1.0.0'
	cursor_without_versions=$(printf '%s\n' "$cursor_with_versions" | cut -d@ -f1)

cat >"$fake_bin/code" <<EOF
#!/bin/sh
case "\$1" in
  --help)
    echo 'Visual Studio Code'
    exit 0
    ;;
  --list-extensions)
    if [ "\${2:-}" = "--show-versions" ]; then
      cat <<'INNER'
$installed_with_versions
INNER
    else
      cat <<'INNER'
$installed_without_versions
INNER
    fi
    exit 0
    ;;
  --install-extension)
    exit 0
    ;;
esac
exit 0
EOF
cat >"$fake_bin/cursor" <<EOF
#!/bin/sh
case "\$1" in
  --help)
    echo 'Cursor'
    exit 0
    ;;
  --list-extensions)
    if [ "\${2:-}" = "--show-versions" ]; then
      cat <<'INNER'
$cursor_with_versions
INNER
    else
      cat <<'INNER'
$cursor_without_versions
INNER
    fi
    exit 0
    ;;
  --install-extension)
    exit 0
    ;;
esac
exit 0
EOF
	cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$curl_log"
printf '{"tag_name":"v9.9.9"}\n200'
EOF
	chmod +x "$fake_bin/code" "$fake_bin/cursor" "$fake_bin/curl"

	if ! HOME="$tmp_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" DOTFILES_LOG="$log" \
		bash "$REPO_ROOT/scripts/install_vscode_ext.sh" >"$log" 2>&1; then
		cat "$log" >&2
		fail "install_vscode_ext.sh fast-mode VSIX test failed"
	fi

	assert_file_missing "$curl_log"
}

run_kitty_ssh_utils_case() {
	local scenario="$1" cwd_value="$2" output_file="$3"

	REPO_ROOT="$REPO_ROOT" SCENARIO="$scenario" CASE_CWD="$cwd_value" python3 - <<'PY' >"$output_file"
import importlib.util
import json
import os
import pathlib
import sys
import types
from urllib.parse import urlparse

captured = {}

class FakeConnectionData:
    def __init__(self, hostname):
        self.hostname = hostname

def fake_is_kitten_cmdline(argv):
    basename0 = os.path.basename(argv[0]) if argv else ""
    return (basename0 == "kitten" and argv[1:2] == ["ssh"]) or argv[:3] == ["kitty", "+kitten", "ssh"]

def fake_get_connection_data(argv, extra_args=()):
    if not fake_is_kitten_cmdline(argv):
        return None

    for token in reversed(argv):
        if token in {"kitty", "kitten", "+kitten", "ssh"} or os.path.basename(token) == "kitten":
            continue
        if token.startswith("-") or token.startswith("cwd="):
            continue
        if token.startswith("--kitten"):
            if "--kitten" in extra_args:
                continue
            return None
        if token.startswith("ssh://"):
            parsed = urlparse(token)
            return FakeConnectionData(parsed.hostname or "")
        return FakeConnectionData(token)

    return None

def fake_parse_launch_args(args):
    captured["args"] = args
    return args, []

def fake_launch(boss, opts, remaining):
    captured["opts"] = opts
    captured["remaining"] = remaining

kitty_pkg = types.ModuleType("kitty")
kitty_pkg.__path__ = []
kitty_constants_mod = types.ModuleType("kitty.constants")
kitty_launch_mod = types.ModuleType("kitty.launch")
kitty_kittens_mod = types.ModuleType("kittens")
kitty_kittens_mod.__path__ = []
kitty_kittens_ssh_mod = types.ModuleType("kittens.ssh")
kitty_kittens_ssh_mod.__path__ = []
kitty_kittens_ssh_utils_mod = types.ModuleType("kittens.ssh.utils")
kitty_launch_mod.launch = fake_launch
kitty_launch_mod.parse_launch_args = fake_parse_launch_args
kitty_kittens_ssh_utils_mod.is_kitten_cmdline = fake_is_kitten_cmdline
kitty_kittens_ssh_utils_mod.get_connection_data = fake_get_connection_data
sys.modules["kitty"] = kitty_pkg
sys.modules["kitty.constants"] = kitty_constants_mod
sys.modules["kitty.launch"] = kitty_launch_mod
sys.modules["kittens"] = kitty_kittens_mod
sys.modules["kittens.ssh"] = kitty_kittens_ssh_mod
sys.modules["kittens.ssh.utils"] = kitty_kittens_ssh_utils_mod

repo_root = pathlib.Path(os.environ["REPO_ROOT"])
spec = importlib.util.spec_from_file_location(
    "ssh_utils_under_test",
    repo_root / ".config/kitty/ssh_utils.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

scenario = os.environ["SCENARIO"]
cwd_value = os.environ.get("CASE_CWD") or None

if scenario == "ssh-shortname-fqdn-collision":
    module.socket.gethostname = lambda: "dev.local"
    module.socket.getfqdn = lambda: "dev.local"
    module.socket.getaddrinfo = lambda *args, **kwargs: []
elif scenario == "ssh-alias-reported-fqdn":
    module.socket.gethostname = lambda: "mbp"
    module.socket.getfqdn = lambda: "mbp.local"
    module.socket.getaddrinfo = lambda *args, **kwargs: []
elif scenario == "plain-ssh-with-remote-cwd":
    module.socket.gethostname = lambda: "mbp"
    module.socket.getfqdn = lambda: "mbp.local"
    module.socket.getaddrinfo = lambda *args, **kwargs: []
elif scenario == "ssh-alias-reported-shortname-host":
    module.socket.gethostname = lambda: "mbp"
    module.socket.getfqdn = lambda: "mbp.local"
    module.socket.getaddrinfo = lambda *args, **kwargs: []
elif scenario == "ssh-local-interface-ip":
    module.socket.gethostname = lambda: "mbp"
    module.socket.getfqdn = lambda: "mbp.local"

    def fake_local_getaddrinfo(host, port, *args, **kwargs):
        normalized_host = (host or "").lower()
        if normalized_host in {"mbp", "mbp.local"}:
            return [
                (module.socket.AF_INET, module.socket.SOCK_STREAM, 6, "", ("192.168.1.100", 0)),
            ]
        return []

    module.socket.getaddrinfo = fake_local_getaddrinfo

class Child:
    foreground_processes = []

class Screen:
    last_reported_cwd = None

class Window:
    id = 42
    child = Child()
    cwd_of_child = "/Users/local/path"
    at_prompt = False
    screen = Screen()
    user_vars = {}

    def ssh_kitten_cmdline(self):
        if scenario in {"ssh", "ssh-connecting", "ssh-same-cwd", "ssh-connecting-realpath", "burst-ssh"}:
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
        if scenario == "ssh-shortname-fqdn-collision":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "dev.corp"]
        if scenario == "ssh-alias-reported-fqdn":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]
        if scenario == "plain-ssh-with-remote-cwd":
            return None
        if scenario == "ssh-alias-reported-shortname-host":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]
        if scenario == "ssh-local-interface-ip":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "192.168.1.100"]
        if scenario == "ssh-reported-host-mismatch":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
        if scenario == "ssh-prompt-before-cwd":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]
        if scenario == "ssh-helper-before-prompt-or-cwd":
            return ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]
        if scenario == "shared-control-kitten":
            return [
                "kitten",
                "ssh",
                "-o",
                "ControlMaster=auto",
                "-oControlPath=/tmp/kssh-rdir-501/kssh-8459-%C",
                "-o",
                "ControlPersist=yes",
                "--kitten",
                "cwd=/placeholder",
                "yumi",
            ]
        if scenario == "kitty-ssh":
            return ["kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
        if scenario == "inline-kitten":
            return ["kitten", "ssh", "--kitten=cwd=/placeholder", "yumi"]
        if scenario == "kitty-inline-kitten":
            return ["kitty", "+kitten", "ssh", "--kitten=cwd=/placeholder", "yumi"]
        if scenario == "uri-kitten":
            return ["kitty", "+kitten", "ssh", "--kitten=cwd=/placeholder", "ssh://alice@example.com:2222"]
        if scenario == "wrapped-kitty-ssh":
            return ["kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
        if scenario == "combined-short-flags":
            return ["kitty", "+kitten", "ssh", "-vp", "2222", "--kitten=cwd=/placeholder", "yumi"]
        return None

window = Window()
active_window = window
window_id_map = {42: window}
target_window_id = 42
cmdline = None
if scenario in {"ssh", "ssh-connecting", "ssh-same-cwd", "inline-kitten", "missing-cwd", "missing-all-cwd", "ssh-connecting-realpath"}:
    cmdline = ["ssh", "yumi"]
elif scenario == "ssh-shortname-fqdn-collision":
    cmdline = ["ssh", "dev.corp"]
elif scenario == "ssh-alias-reported-fqdn":
    cmdline = ["ssh", "orb"]
elif scenario == "plain-ssh-with-remote-cwd":
    cmdline = ["ssh", "legacy"]
elif scenario == "ssh-alias-reported-shortname-host":
    cmdline = ["ssh", "orb"]
elif scenario == "ssh-local-interface-ip":
    cmdline = ["ssh", "192.168.1.100"]
elif scenario == "ssh-reported-host-mismatch":
    cmdline = ["ssh", "yumi"]
elif scenario in {"ssh-prompt-before-cwd", "ssh-helper-before-prompt-or-cwd"}:
    cmdline = ["ssh", "orb"]
elif scenario in {"kitty-ssh", "kitty-inline-kitten"}:
    cmdline = ["kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
elif scenario == "uri-kitten":
    cmdline = ["kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "ssh://alice@example.com:2222"]
elif scenario == "wrapped-kitty-ssh":
    cmdline = ["kitten", "run-shell", "kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "yumi"]
elif scenario == "kitty-uri-no-helper":
    cmdline = ["kitty", "+kitten", "ssh", "--kitten", "cwd=/placeholder", "ssh://alice@example.com:2222"]
elif scenario == "combined-short-flags":
    cmdline = ["kitty", "+kitten", "ssh", "-vp", "2222", "--kitten", "cwd=/placeholder", "yumi"]
if cmdline is not None:
    window.child.foreground_processes = [{"cmdline": cmdline}]
if scenario == "ssh-same-cwd" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://yumi{cwd_value.replace(' ', '%20')}"
elif scenario == "ssh-shortname-fqdn-collision" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://dev.corp{cwd_value.replace(' ', '%20')}"
elif scenario == "ssh-alias-reported-fqdn" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://ubuntu.orb.local{cwd_value.replace(' ', '%20')}"
elif scenario == "plain-ssh-with-remote-cwd" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://legacy.example.com{cwd_value.replace(' ', '%20')}"
elif scenario == "ssh-alias-reported-shortname-host" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://ubuntu{cwd_value.replace(' ', '%20')}"
elif scenario == "ssh-local-interface-ip" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://192.168.1.100{cwd_value.replace(' ', '%20')}"
elif scenario == "ssh-reported-host-mismatch" and cwd_value is not None:
    window.screen.last_reported_cwd = f"kitty-shell-cwd://orb{cwd_value.replace(' ', '%20')}"
elif scenario in {"ssh", "ssh-connecting", "shared-control-kitten", "kitty-ssh", "inline-kitten", "kitty-inline-kitten", "uri-kitten", "wrapped-kitty-ssh", "kitty-uri-no-helper", "combined-short-flags", "ssh-prompt-before-cwd", "ssh-connecting-realpath"} and cwd_value is not None:
    window.screen.last_reported_cwd = f"file://{cwd_value.replace(' ', '%20')}"
if scenario == "missing-cwd":
    window.screen.last_reported_cwd = None
if scenario == "missing-all-cwd":
    window.screen.last_reported_cwd = None
if scenario == "ssh-helper-before-prompt-or-cwd":
    window.screen.last_reported_cwd = None
if scenario == "ssh-prompt-before-cwd":
    window.at_prompt = True
if scenario == "ssh-connecting-realpath":
    window.cwd_of_child = "/private/tmp"
if scenario == "missing-all-cwd":
    window.cwd_of_child = None
if scenario == "local-foreground-stack":
    window.screen.last_reported_cwd = None
    window.cwd_of_child = "/Users/local/path"
    window.child.foreground_processes = [
        {
            "cmdline": [
                "node",
                "/opt/homebrew/Cellar/pyright/1.1.408/libexec/lib/node_modules/pyright/dist/main.js",
            ],
            "cwd": "/opt/homebrew/Cellar/pyright/1.1.408/libexec/lib/node_modules/pyright/dist",
        },
        {
            "cmdline": [
                "claude",
            ],
            "cwd": "/Users/work/current-project",
        },
    ]
if scenario == "local-context-cwd":
    window.user_vars = {"dotfiles_context_cwd": cwd_value}
    window.screen.last_reported_cwd = "file:///Users/local/path"
    window.cwd_of_child = "/Users/local/path"
    window.child.foreground_processes = [
        {
            "cmdline": ["zsh"],
            "cwd": "/Users/local/.local/share/zinit/plugins/Aloxaf---fzf-tab",
        },
    ]

if scenario == "burst-local":
    source_window = Window()
    source_window.id = 42
    source_window.cwd_of_child = "/tmp"
    source_window.screen = type("Screen", (), {"last_reported_cwd": "file:///tmp"})()
    source_window.child = Child()
    source_window.child.foreground_processes = []
    source_window.user_vars = {}

    active_window = Window()
    active_window.id = 43
    active_window.cwd_of_child = str(pathlib.Path.home())
    active_window.screen = type("Screen", (), {"last_reported_cwd": None})()
    active_window.child = Child()
    active_window.child.foreground_processes = []
    active_window.user_vars = {"smart_launch_source_window_id": "42"}
    window_id_map = {42: source_window, 43: active_window}
    target_window_id = 43

if scenario == "burst-local-foreground-cwd":
    source_window = Window()
    source_window.id = 42
    source_window.cwd_of_child = "/Users/previous/project"
    source_window.screen = type("Screen", (), {"last_reported_cwd": "file:///Users/previous/project"})()
    source_window.child = Child()
    source_window.child.foreground_processes = [{"cmdline": ["codex"], "cwd": "/Users/previous/project"}]
    source_window.user_vars = {}

    active_window = Window()
    active_window.id = 43
    active_window.cwd_of_child = "/Users/previous/project"
    active_window.screen = type("Screen", (), {"last_reported_cwd": None})()
    active_window.child = Child()
    active_window.child.foreground_processes = [
        {"cmdline": ["node", "/opt/homebrew/Cellar/pyright/1.1.408/libexec/lib/node_modules/pyright/dist/main.js"], "cwd": "/opt/homebrew/Cellar/pyright/1.1.408/libexec/lib/node_modules/pyright/dist"},
        {"cmdline": ["claude"], "cwd": "/Users/work/current-project"},
    ]
    active_window.user_vars = {"smart_launch_source_window_id": "42"}
    window_id_map = {42: source_window, 43: active_window}
    target_window_id = 43

if scenario == "burst-ssh":
    source_window = Window()
    source_window.id = 42
    source_window.cwd_of_child = "/private/tmp"
    source_window.screen = type("Screen", (), {"last_reported_cwd": "kitty-shell-cwd://orb/tmp"})()
    source_window.child = Child()
    source_window.child.foreground_processes = [{"cmdline": ["ssh", "orb"]}]
    source_window.user_vars = {}
    source_window.ssh_kitten_cmdline = lambda: ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]

    active_window = Window()
    active_window.id = 43
    active_window.cwd_of_child = str(pathlib.Path.home())
    active_window.screen = type("Screen", (), {"last_reported_cwd": None})()
    active_window.child = Child()
    active_window.child.foreground_processes = []
    active_window.user_vars = {"smart_launch_source_window_id": "42"}
    active_window.ssh_kitten_cmdline = lambda: None
    window_id_map = {42: source_window, 43: active_window}
    target_window_id = 43

if scenario == "burst-ssh-local-helper-cwd":
    source_window = Window()
    source_window.id = 42
    source_window.cwd_of_child = "/private/tmp"
    source_window.screen = type("Screen", (), {"last_reported_cwd": "kitty-shell-cwd://orb/home/ouyangzhaoxin/project"})()
    source_window.child = Child()
    source_window.child.foreground_processes = [{"cmdline": ["ssh", "orb"], "cwd": "/Users/ouyangzhaoxin"}]
    source_window.user_vars = {}
    source_window.ssh_kitten_cmdline = lambda: ["kitten", "ssh", "--kitten", "cwd=/placeholder", "orb"]

    active_window = Window()
    active_window.id = 43
    active_window.cwd_of_child = "/Users/ouyangzhaoxin"
    active_window.screen = type("Screen", (), {"last_reported_cwd": None})()
    active_window.child = Child()
    active_window.child.foreground_processes = [
        {"cmdline": ["kitten", "run-shell", "kitten", "ssh", "--kitten=cwd=/home/ouyangzhaoxin/project", "orb"], "cwd": "/Users/ouyangzhaoxin"},
        {"cmdline": ["kitten", "ssh", "--kitten=cwd=/home/ouyangzhaoxin/project", "orb"], "cwd": "/Users/ouyangzhaoxin"},
        {"cmdline": ["/usr/bin/ssh", "orb"], "cwd": "/Users/ouyangzhaoxin"},
    ]
    active_window.user_vars = {"smart_launch_source_window_id": "42"}
    active_window.ssh_kitten_cmdline = lambda: ["kitten", "ssh", "--kitten=cwd=/home/ouyangzhaoxin/project", "orb"]
    window_id_map = {42: source_window, 43: active_window}
    target_window_id = 43

class Boss:
    active_window = active_window
    window_id_map = window_id_map

module.smart_launch(Boss(), "tab", target_window_id)
print(json.dumps({"args": captured["args"], "remaining": captured["remaining"]}))
PY
}

assert_kitty_remote_launch_matches() {
	local output_file="$1"
	python3 - "$output_file" <<'PY'
import json
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1])
data = json.loads(output_path.read_text())
args = data["args"]
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--cwd=current",
    "--hold-after-ssh",
]
if args != expected_args:
	    raise SystemExit(f"Expected native Kitty SSH launch args: {args!r}")
PY
}

assert_kitty_local_fallback_matches() {
	local output_file="$1" expected_cwd="$2"
	python3 - "$output_file" "$expected_cwd" <<'PY'
import json
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1])
expected_cwd = sys.argv[2]
data = json.loads(output_path.read_text())
args = data["args"]
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    f"--cwd={expected_cwd}",
]
if args != expected_args:
    raise SystemExit(f"Expected local fallback launch args: {args!r}")
if any("kitten" in token or "ssh" in token for token in args):
    raise SystemExit(f"Unexpected remote markers in local fallback args: {args!r}")
PY
}

assert_kitty_fail_closed_without_cwd_matches() {
	local output_file="$1"
	python3 - "$output_file" <<'PY'
import json
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1])
data = json.loads(output_path.read_text())
args = data["args"]
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
]
if args != expected_args:
    raise SystemExit(f"Expected fail-closed launch args without cwd: {args!r}")
if any(token.startswith("--cwd=") for token in args):
    raise SystemExit(f"Unexpected cwd marker in fail-closed args: {args!r}")
if any("kitten" in token or "ssh" in token for token in args):
    raise SystemExit(f"Unexpected remote markers in fail-closed args: {args!r}")
PY
}

test_kitty_conf_enables_native_smart_hotkeys() {
	assert_contains "map cmd+n kitten ./smart_window.py" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_contains "map cmd+e kitten ./smart_tab.py" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_contains "copy_on_select yes" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_contains "mouse_map left             press       grabbed,ungrabbed mouse_selection normal" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_contains "mouse_map left             doublepress grabbed,ungrabbed mouse_selection word" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_contains "mouse_map left             triplepress grabbed,ungrabbed mouse_selection line" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_not_contains "# map cmd+n kitten ./smart_window.py" "$REPO_ROOT/.config/kitty/kitty.conf"
	assert_not_contains "# map cmd+e kitten ./smart_tab.py" "$REPO_ROOT/.config/kitty/kitty.conf"
}

test_kitty_custom_kitten_entrypoints_do_not_require___file__() {
	python3 - <<PY
import pathlib
import sys
import types

repo_root = pathlib.Path("$REPO_ROOT")
kitty_dir = repo_root / ".config/kitty"

def fake_result_handler(**kwargs):
    def decorate(fn):
        fn.no_ui = kwargs.get("no_ui", False)
        return fn

    return decorate

kittens_pkg = types.ModuleType("kittens")
kittens_pkg.__path__ = []
kittens_tui_pkg = types.ModuleType("kittens.tui")
kittens_tui_pkg.__path__ = []
kittens_tui_handler_mod = types.ModuleType("kittens.tui.handler")
kittens_tui_handler_mod.result_handler = fake_result_handler
sys.modules["kittens"] = kittens_pkg
sys.modules["kittens.tui"] = kittens_tui_pkg
sys.modules["kittens.tui.handler"] = kittens_tui_handler_mod

sys.path.insert(0, str(kitty_dir))

for name in ("smart_window.py", "smart_tab.py"):
    module_path = kitty_dir / name
    code = compile(module_path.read_text(), str(module_path), "exec")
    module_globals = {"__name__": "kitten"}
    exec(code, module_globals)

    if not callable(module_globals.get("main")):
        raise SystemExit(f"{name} did not expose a callable main()")
    if not callable(module_globals.get("handle_result")):
        raise SystemExit(f"{name} did not expose a callable handle_result()")
PY
}

test_kitty_smart_launcher_does_not_cache_ssh_utils_module() {
	assert_not_contains "from functools import lru_cache" "$REPO_ROOT/.config/kitty/smart_launcher.py"
	assert_not_contains "@lru_cache" "$REPO_ROOT/.config/kitty/smart_launcher.py"
}

test_kitty_ssh_utils_does_not_keep_dead_plain_ssh_helpers() {
	assert_not_contains "_SSH_OPTS_WITH_ARG" "$REPO_ROOT/.config/kitty/ssh_utils.py"
	assert_not_contains "def _extract_kitty_ssh_destination" "$REPO_ROOT/.config/kitty/ssh_utils.py"
	assert_not_contains "def _extract_plain_ssh_destination" "$REPO_ROOT/.config/kitty/ssh_utils.py"
	assert_not_contains "def extract_ssh_destination" "$REPO_ROOT/.config/kitty/ssh_utils.py"
}

test_kitty_smart_launch_uses_native_current_cwd_for_local_windows() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/local-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case local "/Users/local/path" "$output_file"

	python3 - <<PY
import json
import pathlib

data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--cwd=current",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected local args: {data['args']!r}")
if "kitten" in data["args"] or "ssh" in data["args"]:
    raise SystemExit(f"Unexpected remote markers in local args: {data['args']!r}")
PY
}

test_kitty_smart_launch_prefers_last_foreground_process_cwd_for_local_tui() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/local-foreground-stack-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case local-foreground-stack "" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/work/current-project"
}

test_kitty_smart_launch_prefers_explicit_context_cwd_for_local_windows() {
	local tmp_dir context_dir output_file
	tmp_dir=$(make_temp_dir)
	context_dir="$tmp_dir/project with spaces"
	output_file="$tmp_dir/local-context-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN
	mkdir -p "$context_dir"

	run_kitty_ssh_utils_case local-context-cwd "$context_dir" "$output_file"

	python3 - <<PY
import json
import pathlib

context_dir = "$context_dir"
data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--var",
    f"dotfiles_context_cwd={context_dir}",
    f"--cwd={context_dir}",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected context cwd args: {data['args']!r}")
PY
}

test_kitty_smart_launch_skips_ssh_when_session_not_established() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-connecting-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# SSH is still connecting, so smart launch should stay local.
	run_kitty_ssh_utils_case ssh-connecting "/Users/local/path" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_clones_when_remote_cwd_matches_local_path() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-same-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# Remote CWD equals cwd_of_child but URL hostname is "yumi" (remote)
	run_kitty_ssh_utils_case ssh-same-cwd "/Users/local/path" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_treats_different_fqdns_with_same_shortname_as_remote() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-shortname-fqdn-collision-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-shortname-fqdn-collision "/Users/local/path" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_accepts_reported_remote_fqdn_for_ssh_alias() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-alias-reported-fqdn-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-alias-reported-fqdn "/srv/my project" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_accepts_reported_remote_short_hostname_for_ssh_alias() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-alias-reported-shortname-host-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-alias-reported-shortname-host "/srv/my project" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_falls_back_locally_without_kitty_ssh_metadata() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/plain-ssh-with-remote-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case plain-ssh-with-remote-cwd "/srv/my project" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_accepts_different_reported_remote_hostname() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-reported-host-mismatch-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-reported-host-mismatch "/srv/my project" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_treats_local_interface_ip_as_local_host() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-local-interface-ip-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-local-interface-ip "/Users/local/path" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_uses_native_hold_after_ssh_for_established_sessions() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh "/srv/my project" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_prefers_native_hold_after_ssh_over_helper_rewriting() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/shared-control-kitten-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case shared-control-kitten "/srv/my project" "$output_file"
	assert_kitty_remote_launch_matches "$output_file"
}

test_kitty_smart_launch_falls_back_to_local_when_prompt_visible_session_is_seen() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-prompt-before-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# Prompt-visible SSH should now resolve to the same local fallback path.
	run_kitty_ssh_utils_case ssh-prompt-before-cwd "/Users/local/path" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_falls_back_to_local_when_helper_is_available_before_prompt_or_cwd() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-helper-before-prompt-or-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# Helper availability no longer overrides the local fallback path.
	run_kitty_ssh_utils_case ssh-helper-before-prompt-or-cwd "" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_fails_closed_for_kitty_uri_without_helper_cmdline() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/kitty-uri-no-helper-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case kitty-uri-no-helper "/srv/my project" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_falls_back_to_local_when_remote_cwd_is_missing() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/missing-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case missing-cwd "" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/Users/local/path"
}

test_kitty_smart_launch_fails_closed_without_cwd_when_ssh_metadata_is_missing() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/missing-all-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case missing-all-cwd "" "$output_file"
	assert_kitty_fail_closed_without_cwd_matches "$output_file"
}

test_kitty_smart_launch_skips_ssh_when_connecting_paths_match_via_realpath() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/ssh-connecting-realpath-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case ssh-connecting-realpath "/tmp" "$output_file"
	assert_kitty_local_fallback_matches "$output_file" "/tmp"
}

test_kitty_smart_launch_reuses_previous_stable_local_source_during_rapid_repeats() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/burst-local-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case burst-local "" "$output_file"

	python3 - <<PY
import json
import pathlib

data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--cwd=current",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected burst-local args: {data['args']!r}")
PY
}

test_kitty_smart_launch_treats_foreground_process_cwd_as_stable_during_rapid_repeats() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/burst-local-foreground-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case burst-local-foreground-cwd "" "$output_file"

	python3 - <<PY
import json
import pathlib

data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:43",
    "--var",
    "smart_launch_source_window_id=43",
    "--cwd=/Users/work/current-project",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected burst-local foreground args: {data['args']!r}")
PY
}

test_kitty_smart_launch_reuses_previous_stable_ssh_source_during_rapid_repeats() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/burst-ssh-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case burst-ssh "" "$output_file"
	python3 - <<PY
import json
import pathlib

data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--cwd=current",
    "--hold-after-ssh",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected burst-ssh args: {data['args']!r}")
PY
}

test_kitty_smart_launch_reuses_previous_stable_ssh_source_when_new_helper_has_local_cwd() {
	local tmp_dir output_file
	tmp_dir=$(make_temp_dir)
	output_file="$tmp_dir/burst-ssh-local-helper-cwd-launch.json"
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	run_kitty_ssh_utils_case burst-ssh-local-helper-cwd "" "$output_file"
	python3 - <<PY
import json
import pathlib

data = json.loads(pathlib.Path("$output_file").read_text())
expected_args = [
    "--type=tab",
    "--source-window=id:42",
    "--var",
    "smart_launch_source_window_id=42",
    "--cwd=current",
    "--hold-after-ssh",
]
if data["args"] != expected_args:
    raise SystemExit(f"Unexpected burst-ssh local helper cwd args: {data['args']!r}")
PY
}

run_test "Dotfiles manifest and SSH include block" test_dotfiles_manifest_and_ssh_block
run_test "Dotfiles falls back for macOS IME detection without jq or python" test_dotfiles_macos_ime_detection_falls_back_without_jq_or_python
run_test "Dotfiles empty macOS IME fallback still installs" test_dotfiles_macos_ime_detection_empty_fallback_still_installs
run_test "Dotfiles warns when macOS IME provider is disabled" test_dotfiles_warns_when_macos_ime_provider_is_disabled
run_test "Dotfiles generates apple_pair Karabiner profile" test_dotfiles_generates_apple_pair_karabiner_profile
run_test "Dotfiles generates wetype Karabiner profile from HIToolbox state" test_dotfiles_generates_wetype_karabiner_profile_from_hitoolbox_state
run_test "Dotfiles generates disabled Karabiner without IME rules" test_dotfiles_generates_disabled_karabiner_without_ime_rules
run_test "Dotfiles wetype Karabiner patching fails closed on malformed click rule" test_dotfiles_wetype_karabiner_patching_fails_closed_on_malformed_click_rule
run_test "superpowers clone does not retry GitHub SSH failures" test_superpowers_clone_does_not_retry_github_ssh_failures
run_test "superpowers pull does not retry GitHub SSH failures" test_superpowers_pull_does_not_retry_github_ssh_failures
run_test "Dotfiles pre-cleans stale zinit completions" test_dotfiles_precleans_zinit_stale_completions
run_test "Dotfiles warns when zinit plugin sync fails" test_dotfiles_warns_when_zinit_plugin_sync_fails
run_test "zsh open wrapper preserves Codex deep links" test_zsh_open_wrapper_preserves_codex_deep_links
run_test "Codex launch defaults sync pins config and Desktop state" test_codex_launch_defaults_sync_script_pins_config_and_desktop_state
run_test "zsh codex wrapper pins interactive launches" test_zsh_codex_wrapper_pins_interactive_launches
run_test "zshrc does not reload zinit plugins when re-sourced" test_zshrc_does_not_reload_zinit_plugins_when_resourced
run_test "zshrc detects preloaded zinit without re-sourcing plugin stack" test_zshrc_detects_preloaded_zinit_without_resourcing_plugin_stack
run_test "zshrc kitty ssh wrapper defaults to kitten and supports opt-out" test_zshrc_kitty_ssh_wrapper_defaults_to_kitten_and_supports_opt_out
run_test "zshrc publishes kitty context cwd user var" test_zshrc_publishes_kitty_context_cwd_user_var
run_test "zshrc publishes kitty context cwd via socket fallback" test_zshrc_publishes_kitty_context_cwd_via_socket_fallback
run_test "SSH config uses SetEnv for kitten ssh opt-outs" test_ssh_config_uses_setenv_for_kitten_ssh_opt_outs
run_test "Dotfiles removes legacy managed kitty ssh.conf" test_dotfiles_removes_legacy_managed_kitty_ssh_conf
run_test "zshrc skips prompt stack for interactive shell without tty" test_zshrc_skips_prompt_stack_for_interactive_shell_without_tty
run_test "zsh history alias shows newest first with timestamps" test_zsh_history_alias_shows_newest_first_with_timestamps
run_test "zsh fzf wrapper streams piped input without prefetch" test_zsh_fzf_wrapper_streams_piped_input_without_prefetch
run_test "age-tokens does not leak decrypted values under xtrace" test_age_tokens_does_not_leak_decrypted_values_under_xtrace
run_test "kitty conf enables native smart hotkeys" test_kitty_conf_enables_native_smart_hotkeys
run_test "kitty custom kitten entrypoints do not require __file__" test_kitty_custom_kitten_entrypoints_do_not_require___file__
run_test "kitty smart launcher does not cache ssh utils module" test_kitty_smart_launcher_does_not_cache_ssh_utils_module
run_test "kitty ssh utils does not keep dead plain ssh helpers" test_kitty_ssh_utils_does_not_keep_dead_plain_ssh_helpers
run_test "kitty ssh utils falls back locally when helper cmdline is unavailable" test_kitty_smart_launch_fails_closed_for_kitty_uri_without_helper_cmdline
run_test "Dotfiles uninstall preserves modified files" test_dotfiles_uninstall_preserves_modified_files
run_test "Claude runtime config preserves existing state" test_claude_runtime_config_preserves_existing_state
run_test "Git config identity migrates to local include" test_gitconfig_identity_migrates_to_local
run_test "Dotfiles hook-free fallback" test_dotfiles_hook_free_fallback
run_test "Codex shared config installs without computer-use cache" test_codex_config_installs_without_computer_use_cache
run_test "Codex shared config preserves subprojects" test_codex_config_preserves_projects_and_keeps_home_subprojects
run_test "Codex shared config uses latest model guide when available" test_codex_config_uses_latest_model_guide_when_available
run_test "Codex shared config falls back when latest model lookup fails" test_codex_config_falls_back_when_latest_model_lookup_fails
run_test "Node CLI installer uses ~/.local prefix on Linux" test_install_node_clis_linux_uses_home_local_prefix
run_test "Node CLI installer keeps default npm prefix on macOS" test_install_node_clis_macos_keeps_default_prefix
run_test "Pixi prefers managed install" test_pixi_prefers_managed_install_over_system_binary
run_test "Claude optional on macOS" test_claude_optional_on_macos_when_missing
run_test "Claude optional on Linux" test_claude_optional_on_linux_when_install_fails
run_test "Dotfiles uninstall removes managed Node CLIs" test_dotfiles_uninstall_removes_managed_node_clis
run_test "Dotfiles uninstall clears missing Node CLI state" test_dotfiles_uninstall_clears_node_cli_state_when_prefix_is_gone
run_test "Claude known_hosts preserves symlink" test_claude_known_hosts_preserves_symlink
run_test "GitHub release lookup uses GITHUB_TOKEN" test_github_latest_release_uses_github_token
run_test "GitHub update check reports rate limit actionably" test_check_github_update_reports_rate_limit_actionably
run_test "GitHub update check skips remote lookup in fast mode" test_check_github_update_fast_mode_skips_remote_lookup_with_local_version
run_test "GitHub update fast mode does not leak local version into remote state" test_check_github_update_fast_mode_does_not_reuse_local_version_as_remote
run_test "Node CLI installer skips installed packages in fast mode" test_install_node_clis_fast_mode_skips_installed_packages
run_test "Claude installer skips plugin updates in fast mode" test_install_claude_code_fast_mode_skips_plugin_and_marketplace_updates
run_test "Claude installer hides deprecated superpowers commands" test_install_claude_code_hides_superpowers_deprecated_commands
run_test "VSCode installer skips GitHub VSIX release lookup in fast mode" test_install_vscode_ext_fast_mode_skips_github_vsix_release_lookup_when_installed
run_test "kitty smart launch uses native current cwd for local windows" test_kitty_smart_launch_uses_native_current_cwd_for_local_windows
run_test "kitty smart launch prefers last foreground process cwd for local TUI" test_kitty_smart_launch_prefers_last_foreground_process_cwd_for_local_tui
run_test "kitty smart launch prefers explicit context cwd for local windows" test_kitty_smart_launch_prefers_explicit_context_cwd_for_local_windows
run_test "kitty smart launch skips ssh when session not established" test_kitty_smart_launch_skips_ssh_when_session_not_established
run_test "kitty smart launch clones when remote cwd matches local path" test_kitty_smart_launch_clones_when_remote_cwd_matches_local_path
run_test "kitty smart launch treats different FQDNs with same shortname as remote" test_kitty_smart_launch_treats_different_fqdns_with_same_shortname_as_remote
run_test "kitty smart launch accepts reported remote FQDN for ssh alias" test_kitty_smart_launch_accepts_reported_remote_fqdn_for_ssh_alias
run_test "kitty smart launch accepts reported remote short hostname for ssh alias" test_kitty_smart_launch_accepts_reported_remote_short_hostname_for_ssh_alias
run_test "kitty smart launch falls back locally without kitty ssh metadata" test_kitty_smart_launch_falls_back_locally_without_kitty_ssh_metadata
run_test "kitty smart launch accepts different reported remote hostname" test_kitty_smart_launch_accepts_different_reported_remote_hostname
run_test "kitty smart launch treats local interface IP as local host" test_kitty_smart_launch_treats_local_interface_ip_as_local_host
run_test "kitty smart launch uses native hold-after-ssh for established sessions" test_kitty_smart_launch_uses_native_hold_after_ssh_for_established_sessions
run_test "kitty smart launch prefers native hold-after-ssh over helper rewriting" test_kitty_smart_launch_prefers_native_hold_after_ssh_over_helper_rewriting
run_test "kitty smart launch falls back to local when prompt-visible SSH is seen" test_kitty_smart_launch_falls_back_to_local_when_prompt_visible_session_is_seen
run_test "kitty smart launch falls back to local when helper exists before prompt or cwd" test_kitty_smart_launch_falls_back_to_local_when_helper_is_available_before_prompt_or_cwd
run_test "kitty smart launch falls back to local when remote cwd is missing" test_kitty_smart_launch_falls_back_to_local_when_remote_cwd_is_missing
run_test "kitty smart launch fails closed without cwd when ssh metadata is missing" test_kitty_smart_launch_fails_closed_without_cwd_when_ssh_metadata_is_missing
run_test "kitty smart launch realpath-matches local cwd while connecting" test_kitty_smart_launch_skips_ssh_when_connecting_paths_match_via_realpath
run_test "kitty smart launch reuses previous stable local source during rapid repeats" test_kitty_smart_launch_reuses_previous_stable_local_source_during_rapid_repeats
run_test "kitty smart launch treats foreground process cwd as stable during rapid repeats" test_kitty_smart_launch_treats_foreground_process_cwd_as_stable_during_rapid_repeats
run_test "kitty smart launch reuses previous stable ssh source during rapid repeats" test_kitty_smart_launch_reuses_previous_stable_ssh_source_during_rapid_repeats
run_test "kitty smart launch reuses previous stable ssh source when new helper has local cwd" test_kitty_smart_launch_reuses_previous_stable_ssh_source_when_new_helper_has_local_cwd

section "Done"
pass "Smoke checks completed"
