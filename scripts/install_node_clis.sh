#!/bin/bash
# shellcheck disable=SC2088
# Unified npm-global installer for Node-based CLIs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"

OS=""
STATE_FILE="$(node_cli_npm_state_file)"

NODE_CLI_PACKAGES=(
	"@anthropic-ai/claude-code"
	"@openai/codex"
	"ccusage"
	"@mermaid-js/mermaid-cli"
	"typescript-language-server"
	"typescript"
	"intelephense"
)

package_install_command() {
	local package="$1"
	printf '%s@latest\n' "$package"
}

run_brew_command() {
	if [[ -n "${DOTFILES_LOG:-}" ]]; then
		"$@" >>"$DOTFILES_LOG" 2>&1
	else
		"$@" >/dev/null 2>&1
	fi
}

release_macos_homebrew_node_cli_conflicts() {
	local brew_bin
	brew_bin="$(command -v brew 2>/dev/null || true)"
	[[ -n "$brew_bin" ]] || return 0

	if run_brew_command "$brew_bin" list --cask codex; then
		print_info "检测到 Homebrew 管理的 codex，改由 npm 接管..."
		if run_brew_command "$brew_bin" uninstall --cask codex; then
			print_dim "✓ Homebrew 已移除: codex (cask)"
		else
			print_warn "Homebrew 卸载失败: codex (cask)"
		fi
	fi

	local formula
	for formula in typescript typescript-language-server; do
		if run_brew_command "$brew_bin" list --formula "$formula"; then
			print_info "检测到 Homebrew 管理的 ${formula}，改由 npm 接管..."
			if run_brew_command "$brew_bin" uninstall "$formula"; then
				print_dim "✓ Homebrew 已移除: ${formula}"
			else
				print_warn "Homebrew 卸载失败: ${formula}"
			fi
		fi
	done
}

sync_linux_npm_prefix() {
	local desired_prefix npmrc tmp

	desired_prefix="$(linux_npm_global_prefix)"
	npmrc="$HOME/.npmrc"
	tmp="$(mktemp)"

	if [[ -f "$npmrc" ]]; then
		awk -v desired="$desired_prefix" '
			BEGIN { replaced = 0 }
			/^[[:space:]]*prefix[[:space:]]*=/ {
				if (!replaced) {
					print "prefix=" desired
					replaced = 1
				}
				next
			}
			{ print }
			END {
				if (!replaced) {
					print "prefix=" desired
				}
			}
		' "$npmrc" >"$tmp"
	else
		printf 'prefix=%s\n' "$desired_prefix" >"$tmp"
	fi

	mv "$tmp" "$npmrc"
	export npm_config_prefix="$desired_prefix"
	export NPM_CONFIG_PREFIX="$desired_prefix"
	local npm_global_bin
	npm_global_bin="$(linux_npm_global_bin_dir)"
	export PATH="$npm_global_bin:$PATH"
}

ensure_npm_ready() {
	if ! command -v npm &>/dev/null; then
		print_warn "npm 未找到，跳过 Node CLI 安装"
		return 1
	fi

	if [[ "$OS" == "linux" ]]; then
		sync_linux_npm_prefix
	elif [[ "$OS" == "macos" ]]; then
		release_macos_homebrew_node_cli_conflicts
	fi

	return 0
}

npm_prefix_for_state() {
	if [[ "$OS" == "linux" ]]; then
		linux_npm_global_prefix
		return 0
	fi

	npm prefix -g 2>/dev/null || npm config get prefix 2>/dev/null || true
}

npm_root_for_prefix() {
	local prefix="$1"
	[[ -n "$prefix" ]] || return 1
	printf '%s/lib/node_modules\n' "${prefix%/}"
}

package_preexisted() {
	local package="$1" npm_root="$2"
	[[ -d "$npm_root/$package" ]]
}

write_state_file() {
	local prefix="$1"
	shift
	local entries=("$@")

	mkdir -p "$(dirname "$STATE_FILE")"
	{
		printf 'prefix\t%s\n' "$prefix"
		printf '%s\n' "${entries[@]}"
	} >"$STATE_FILE"
}

previous_state_entry() {
	local package="$1"
	[[ -f "$STATE_FILE" ]] || return 1
	awk -F '\t' -v package="$package" '$1 == "package" && $2 == package { print $0; exit }' "$STATE_FILE"
}

run_npm_global_install() {
	local install_target="$1"

	if [[ -n "${DOTFILES_LOG:-}" ]]; then
		npm install -g "$install_target" >>"$DOTFILES_LOG" 2>&1
	else
		npm install -g "$install_target" >/dev/null 2>&1
	fi
}

install_node_clis() {
	local managed_prefix managed_root
	local installed=0 updated=0 skipped=0 failed=0
	local state_entries=()

	managed_prefix="$(npm_prefix_for_state)"
	managed_prefix="${managed_prefix%/}"
	[[ -n "$managed_prefix" ]] || {
		print_warn "无法解析 npm global prefix，跳过 Node CLI 安装"
		return 0
	}

	managed_root="$(npm_root_for_prefix "$managed_prefix")"

	print_info "安装 Node CLI（npm global）..."
	print_dim "npm prefix: $managed_prefix"

	local package install_target preexisting_marker
	for package in "${NODE_CLI_PACKAGES[@]}"; do
		install_target="$(package_install_command "$package")"
		preexisting_marker=0
		if package_preexisted "$package" "$managed_root"; then
			preexisting_marker=1
		fi

		if dotfiles_update_mode_is_fast && [[ "$preexisting_marker" == "1" ]]; then
			print_fast_mode_skip "$package"
			skipped=$((skipped + 1))
			local existing_entry
			existing_entry="$(previous_state_entry "$package" || true)"
			[[ -n "$existing_entry" ]] && state_entries+=("$existing_entry")
			continue
		fi

		if run_npm_global_install "$install_target"; then
			if [[ "$preexisting_marker" == "1" ]]; then
				updated=$((updated + 1))
			else
				installed=$((installed + 1))
			fi
			state_entries+=($'package\t'"${package}"$'\t'"${preexisting_marker}")
		else
			print_warn "Node CLI 安装失败: $package"
			failed=$((failed + 1))
		fi
	done

	if [[ ${#state_entries[@]} -gt 0 ]]; then
		write_state_file "$managed_prefix" "${state_entries[@]}"
	fi

	if [[ $failed -eq 0 ]]; then
		print_success "Node CLI: 新增 $installed, 更新 $updated, 跳过 $skipped"
	else
		print_warn "Node CLI: 新增 $installed, 更新 $updated, 跳过 $skipped, 失败 $failed"
	fi
}

main() {
	OS="$(detect_os)"

	ensure_npm_ready || return 0
	install_node_clis
}

main "$@"
