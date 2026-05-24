#!/bin/bash
# shellcheck disable=SC2088
# Dotfiles 配置安装脚本
# 只同步明确列出的文件/目录，避免覆盖用户的其它配置

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/../lib/utils.sh"

record_deployed_path() {
	local src="$1" dest="$2"

	if [[ -d "$src" ]]; then
		local file rel
		while IFS= read -r file; do
			rel="${file#"$src"/}"
			dotfiles_manifest_add_file "$dest/$rel"
		done < <(find "$src" -type f | sort)
	else
		dotfiles_manifest_add_file "$dest"
	fi
}

sync_directory_contents() {
	local src="$1" dest="$2"

	mkdir -p "$dest"

	if command -v rsync &>/dev/null; then
		# 非破坏性合并：更新仓库内文件，但保留目标目录里的本机私有文件。
		rsync -a "$src/" "$dest/"
		return 0
	fi

	# 兜底：仅覆盖仓库提供的内容，不删除目标目录里的额外文件。
	cp -PRf "$src/." "$dest/"
}

copy_path() {
	local src="$DOTFILES_DIR/$1"
	local dest="$HOME/$2"

	[[ ! -e "$src" ]] && return 0

	if [[ -d "$src" ]]; then
		sync_directory_contents "$src" "$dest"
	else
		mkdir -p "$(dirname "$dest")"
		cp -f "$src" "$dest"
	fi

	record_deployed_path "$src" "$dest"

	print_dim "~/$2"
}

write_gitconfig_local() {
	local dest="$1" name="$2" email="$3" tmp
	tmp=$(mktemp)
	git config --file "$tmp" user.name "$name"
	git config --file "$tmp" user.email "$email"
	mkdir -p "$(dirname "$dest")"
	mv "$tmp" "$dest"
	chmod 600 "$dest"
}

_deploy_gitconfig_identity() {
	local gitconfig_local="$HOME/.gitconfig.local"
	local current_gitconfig="$HOME/.gitconfig"
	local name="" email=""

	[[ -f "$gitconfig_local" ]] && return 0

	if [[ -n "${DOTFILES_GIT_USER_NAME:-}" && -n "${DOTFILES_GIT_USER_EMAIL:-}" ]]; then
		name="$DOTFILES_GIT_USER_NAME"
		email="$DOTFILES_GIT_USER_EMAIL"
	elif [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
		name="$GIT_USER_NAME"
		email="$GIT_USER_EMAIL"
	elif [[ -f "$current_gitconfig" ]]; then
		name=$(git config --file "$current_gitconfig" user.name 2>/dev/null || true)
		email=$(git config --file "$current_gitconfig" user.email 2>/dev/null || true)
	fi

	if [[ -n "$name" && -n "$email" ]]; then
		write_gitconfig_local "$gitconfig_local" "$name" "$email"
		print_success "~/.gitconfig.local"
	else
		print_warn "未检测到 Git 身份；请创建 ~/.gitconfig.local（可参考 ~/Dotfiles/.gitconfig.local.example）"
	fi
}

_deploy_gitconfig() {
	_deploy_gitconfig_identity
	copy_path ".gitconfig" ".gitconfig"
}

# 部署 settings.json 并剥离项目级 hooks（jq → python3 → 原样拷贝）
_deploy_without_hooks() {
	local src="$1" dest="$2"
	local fallback_template="$DOTFILES_DIR/.claude/settings.global.json"
	if command -v jq &>/dev/null; then
		jq 'del(.hooks)' "$src" >"$dest" 2>/dev/null && return
	fi
	python3 -c "
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d.pop('hooks', None)
with open(sys.argv[2], 'w') as f: json.dump(d, f, indent=4, ensure_ascii=False)
" "$src" "$dest" 2>/dev/null && return
	# 兜底：使用仓库内的无 hooks 模板，避免把项目级 hooks 泄漏到全局配置
	[[ -f "$fallback_template" ]] && cp -f "$fallback_template" "$dest" && return
	return 1
}

# 部署 Claude Code settings.json（jq 合并：静态设置覆盖，动态字段保留）
# repo 的 hooks 是项目级（如 check-file-deps.sh），不应提升到全局配置
# 合并时排除 repo hooks，仅保留 home 已有的用户级 hooks
_deploy_claude_settings() {
	local claude_src="$DOTFILES_DIR/.claude/settings.json"
	local claude_dest="$HOME/.claude/settings.json"
	[[ -f "$claude_src" ]] || return 0

	mkdir -p "$HOME/.claude"
	if [[ -f "$claude_dest" ]] && command -v jq &>/dev/null; then
		local tmp_merged
		tmp_merged=$(mktemp)
		if jq -s '
			.[0].hooks as $home_hooks |
			(.[0] | del(.hooks)) * (.[1] | del(.hooks)) |
			if $home_hooks then .hooks = $home_hooks else . end
		' "$claude_dest" "$claude_src" >"$tmp_merged" 2>/dev/null; then
			mv "$tmp_merged" "$claude_dest"
		else
			rm -f "$tmp_merged"
			_deploy_without_hooks "$claude_src" "$claude_dest" || {
				print_warn "无法安全部署 ~/.claude/settings.json，跳过"
				return 0
			}
		fi
	else
		_deploy_without_hooks "$claude_src" "$claude_dest" || {
			print_warn "无法安全部署 ~/.claude/settings.json，跳过"
			return 0
		}
	fi
	print_success "~/.claude/settings.json"
}

_deploy_claude_runtime_config() {
	local claude_runtime_src="$DOTFILES_DIR/.claude/runtime.json"
	local claude_runtime_dest="$HOME/.claude.json"
	[[ -f "$claude_runtime_src" ]] || return 0

	if ! merge_json_object_file "$claude_runtime_dest" "$claude_runtime_src"; then
		print_warn "无法安全部署 ~/.claude.json，跳过"
		return 0
	fi
	if ! sanitize_claude_runtime_state_file "$claude_runtime_dest"; then
		print_warn "无法安全清理 ~/.claude.json 的安装状态字段，跳过"
		return 0
	fi

	dotfiles_manifest_add_file "$claude_runtime_dest"
	print_success "~/.claude.json"
}

_deploy_codex_config() {
	local codex_src="$DOTFILES_DIR/.codex/config.toml"
	local codex_dest="$HOME/.codex/config.toml"
	[[ -f "$codex_src" ]] || return 0

	if bash "$SCRIPT_DIR/deploy_codex_config.sh" "$codex_src" "$codex_dest" "$HOME"; then
		dotfiles_manifest_add_file "$codex_dest"
		print_success "~/.codex/config.toml"
		[[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]] || print_warn "GitHub MCP 已写入 ~/.codex/config.toml，但未检测到 GITHUB_PERSONAL_ACCESS_TOKEN"
		[[ -n "${TAVILY_API_KEY:-}" ]] || print_warn "Tavily MCP 已写入 ~/.codex/config.toml，但未检测到 TAVILY_API_KEY"
	else
		print_warn "无法部署 ~/.codex/config.toml，跳过"
	fi
}

_deploy_superpowers_skills() {
	local clone_dir="$HOME/.codex/superpowers"
	local link_dir="$HOME/.agents/skills/superpowers"
	local state_file
	state_file="$(superpowers_state_file)"

	if bash "$SCRIPT_DIR/deploy_superpowers_skills.sh" "$clone_dir" "$link_dir" "$state_file"; then
		print_success "~/.agents/skills/superpowers"
	else
		print_warn "无法部署 superpowers skills，跳过"
	fi
}

remove_legacy_kitty_ssh_conf() {
	local legacy="$HOME/.config/kitty/ssh.conf"
	[[ -f "$legacy" ]] || return 0

	if grep -qF "Do not add OrbStack's \`orb\` host here" "$legacy" &&
		grep -qF "hostname fedora" "$legacy" &&
		grep -qF "delegate ssh" "$legacy"; then
		rm -f "$legacy"
		dotfiles_manifest_remove_file "$legacy" 2>/dev/null || :
		print_success "~/.config/kitty/ssh.conf legacy cleanup"
	fi
}

refresh_zinit_completions() {
	local zinit_bootstrap="$HOME/.local/share/zinit/zinit.git/zinit.zsh"
	local zcompdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/.zcompdump"

	# zinit 的 completions 目录是派生状态；插件上游删掉 completion 文件后，
	# 旧 symlink 可能残留，下一次 compinit 全量扫描才暴露成 no such file 错误。
	# 部署阶段先用 zinit cclear 清理坏/未知 completion，再重建插件和 compdump。
	if [[ -f "$zinit_bootstrap" ]]; then
		if _run_and_log zsh -c "source '$zinit_bootstrap' && zinit cclear && rm -f '$zcompdump'"; then
			print_success "Zinit completions 已清理"
		else
			print_warn "Zinit completions 清理失败，继续安装插件"
		fi
	fi

	# ZINIT_SYNC=1 同步加载，确保所有插件安装完成再退出。
	if _run_and_log zsh -c "ZINIT_SYNC=1 source '$HOME/.zshrc'"; then
		print_success "Zinit 插件安装完成"
	else
		print_warn "Zinit 插件安装失败，请检查日志"
	fi
}

ensure_ssh_include_block() {
	local ssh_config="$HOME/.ssh/config"
	local start_marker end_marker tmp
	start_marker="$(dotfiles_ssh_include_block_start)"
	end_marker="$(dotfiles_ssh_include_block_end)"

	if [[ ! -f "$ssh_config" ]]; then
		printf "%s\nInclude config.d/*\n%s\n" "$start_marker" "$end_marker" >"$ssh_config"
		return 0
	fi

	if grep -qF "$start_marker" "$ssh_config"; then
		return 0
	fi

	if grep -qF "Include config.d/*" "$ssh_config"; then
		print_warn "~/.ssh/config 已存在 Include config.d/*，保留现有配置"
		return 0
	fi

	tmp=$(mktemp)
	{
		printf "%s\nInclude config.d/*\n%s\n\n" "$start_marker" "$end_marker"
		cat "$ssh_config"
	} >"$tmp"
	mv "$tmp" "$ssh_config"
}

main() {
	local vscode_cmd="" cursor_cmd=""

	print_info "📁 Dotfiles 配置安装"
	dotfiles_manifest_begin
	trap 'dotfiles_manifest_discard' EXIT

	vscode_cmd="$(find_editor_cli vscode 2>/dev/null || true)"
	cursor_cmd="$(find_editor_cli cursor 2>/dev/null || true)"

	# 点文件
	copy_path ".zshrc" ".zshrc"
	copy_path ".zprofile" ".zprofile"
	copy_path ".zshenv" ".zshenv"
	copy_path ".envrc" ".envrc"

	# .config 子目录（通用）
	copy_path ".config/zsh" ".config/zsh"
	copy_path ".config/kitty" ".config/kitty"
	remove_legacy_kitty_ssh_conf
	copy_path ".config/ripgrep" ".config/ripgrep"

	# direnv 配置（替换 __HOME__ 为实际路径）
	if [[ -f "$DOTFILES_DIR/.config/direnv/direnv.toml" ]]; then
		mkdir -p "$HOME/.config/direnv"
		sed "s|__HOME__|$HOME|g" "$DOTFILES_DIR/.config/direnv/direnv.toml" > "$HOME/.config/direnv/direnv.toml"
		dotfiles_manifest_add_file "$HOME/.config/direnv/direnv.toml"
		print_success "~/.config/direnv/direnv.toml"
	fi

	# VSCode/Cursor 配置（只复制 settings.json 和 keybindings.json，避免覆盖用户的其它配置）
	if [[ "$(uname)" == "Darwin" ]]; then
			local hitoolbox_provider_state_json provider_info provider

		# macOS: ~/Library/Application Support/
		[[ -n "$vscode_cmd" ]] && copy_path "Library/Application Support/Code/User/settings.json" "Library/Application Support/Code/User/settings.json"
		[[ -n "$vscode_cmd" ]] && copy_path "Library/Application Support/Code/User/keybindings.json" "Library/Application Support/Code/User/keybindings.json"
		[[ -n "$cursor_cmd" ]] && copy_path "Library/Application Support/Cursor/User/settings.json" "Library/Application Support/Cursor/User/settings.json"
		[[ -n "$cursor_cmd" ]] && copy_path "Library/Application Support/Cursor/User/keybindings.json" "Library/Application Support/Cursor/User/keybindings.json"
		# macOS 专属
		copy_path ".config/karabiner" ".config/karabiner"
		copy_path ".hammerspoon" ".hammerspoon"
		# shellcheck source=./lib_macos_ime_toggle.sh
		source "$SCRIPT_DIR/lib_macos_ime_toggle.sh"
			hitoolbox_provider_state_json="$(
				macos_read_hitoolbox_provider_state_json "$HOME/Library/Preferences/com.apple.HIToolbox.plist"
			)"
			provider_info="$(
				macos_select_ime_provider "$hitoolbox_provider_state_json"
			)"
		provider="$(
			awk -F= '$1=="provider"{print $2}' <<<"$provider_info"
		)"
		case "$provider" in
		wetype)
			print_info "macOS IME toggle provider: wetype (enable WeType's Shift toggle inside WeChat Input Method)"
			;;
		apple_pair)
			print_info "macOS IME toggle provider: apple_pair (set macOS input-source shortcut to Control-Space)"
			;;
		disabled)
			print_warn "macOS IME toggle disabled on this machine because no supported provider was detected"
			;;
		esac
		macos_customize_home_karabiner_config \
			"$HOME/.config/karabiner/karabiner.json" \
			"$provider"
		dotfiles_manifest_add_file "$HOME/.config/karabiner/karabiner.json"
	else
		# Linux: ~/.config/
		if is_remote_server; then
			print_info "检测到远程服务器环境，跳过 VSCode/Cursor 设置（设置从本地自动同步）"
		else
			[[ -n "$vscode_cmd" ]] && copy_path ".config/Code/User/settings.json" ".config/Code/User/settings.json"
			[[ -n "$vscode_cmd" ]] && copy_path ".config/Code/User/keybindings.json" ".config/Code/User/keybindings.json"
			[[ -n "$cursor_cmd" ]] && copy_path ".config/Cursor/User/settings.json" ".config/Cursor/User/settings.json"
			[[ -n "$cursor_cmd" ]] && copy_path ".config/Cursor/User/keybindings.json" ".config/Cursor/User/keybindings.json"
		fi
	fi

	# Git 配置
	_deploy_gitconfig
	copy_path ".gitignore" ".gitignore"

	# Claude Code 配置
	_deploy_claude_settings
	_deploy_claude_runtime_config
	# Codex（CLI / App）共享配置
	_deploy_codex_config
	_deploy_superpowers_skills
	# SSH 配置：通过 Include 浅合并，避免覆盖机器本地的 Host 定义
	mkdir -p "$HOME/.ssh/config.d"
	cp -f "$DOTFILES_DIR/.ssh/config" "$HOME/.ssh/config.d/00-dotfiles"
	dotfiles_manifest_add_file "$HOME/.ssh/config.d/00-dotfiles"
	chmod 600 "$HOME/.ssh/config.d/00-dotfiles"
	ensure_ssh_include_block
	chmod 600 "$HOME/.ssh/config"
	print_success "~/.ssh/config.d/00-dotfiles (via Include)"
	# Linux: 安装 keychain（SSH agent 管理器，纯 shell 脚本）
	if [[ "$(uname)" != "Darwin" ]] && ! command -v keychain &>/dev/null; then
		mkdir -p "$HOME/.local/bin"
		if curl -fsSL "https://github.com/funtoo/keychain/raw/master/keychain.sh" -o "$HOME/.local/bin/keychain"; then
			chmod +x "$HOME/.local/bin/keychain"
			dotfiles_manifest_add_file "$HOME/.local/bin/keychain"
			print_success "keychain (SSH agent manager)"
		else
			print_warn "keychain 下载失败，SSH agent 需手动管理"
		fi
	fi
	# pixi.toml 由 install.sh 的 sync_pixi_tools() 统一部署，避免重复
	copy_path "sh-script" "sh-script"

	# 权限
	[[ -d "$HOME/.ssh" ]] && chmod 700 "$HOME/.ssh" && find "$HOME/.ssh" -maxdepth 2 -type f -exec chmod 600 {} + 2>/dev/null
	[[ -f "$HOME/.config/zsh/fzf/fzf-preview.sh" ]] && chmod +x "$HOME/.config/zsh/fzf/fzf-preview.sh"
	[[ -d "$HOME/sh-script" ]] && chmod +x "$HOME/sh-script"/*.sh 2>/dev/null
	dotfiles_manifest_commit
	trap - EXIT

	# 安装 zinit 插件
	_echo_blank
	print_info "🔌 安装 Zinit 插件..."
	if command -v zsh &>/dev/null; then
		refresh_zinit_completions
	else
		print_warn "未找到 zsh，跳过 zinit 插件安装"
	fi

	print_success "Dotfiles 配置部署完成"
}

main
