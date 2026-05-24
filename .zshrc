# ============================================
# 终端环境
# ============================================

# TERM 为空时补默认值；TERM=dumb 时保持极简，避免 prompt / pager 输出控制序列。
[[ -z "$TERM" ]] && export TERM="xterm-256color"
if [[ "$TERM" == "dumb" ]]; then
	PROMPT='%n@%m:%~$ '
	RPROMPT=
	return
fi

# 在 kitty 终端中默认用 kitten ssh；SSH config 中 `SetEnv KITTEN_SSH=0`
# 或命令前缀 `KITTEN_SSH=0 ssh ...` 可对 Windows 等目标回退到原生 ssh。
if [[ -n "$KITTY_WINDOW_ID" ]]; then
	ssh() {
		emulate -L zsh

		local arg
		for arg in "$@"; do
			case "$arg" in
			-G | -Q | -V)
				command ssh "$@"
				return
				;;
			esac
		done

		case "${KITTEN_SSH:l}" in
		0 | false | no | off)
			command ssh "$@"
			return
			;;
		esac

		if ! (( $+commands[kitten] )); then
			command ssh "$@"
			return
		fi

		# `ssh -G` prints the final config after Host matching. We use SetEnv
		# as a harmless per-host opt-out marker instead of guessing remote OS.
		local ssh_config
		ssh_config="$(command ssh -G "$@" 2>/dev/null || true)"
		if [[ -n "$ssh_config" ]] &&
			print -r -- "$ssh_config" |
				command awk '
					tolower($1) == "setenv" {
						for (i = 2; i <= NF; i++) {
							field = tolower($i)
							if (field ~ /^kitten_ssh=(0|false|no|off)$/) found = 1
						}
					}
					END { exit found ? 0 : 1 }
				'; then
			command ssh "$@"
			return
		fi

		command kitten ssh "$@"
	}
	# 创建固定路径 symlink，供外部工具（如 VS Code 插件）定位 Kitty socket
	# kitty.conf 使用 kitty-{kitty_pid} 防多实例冲突，这里补一个稳定入口
	[[ -n "$KITTY_LISTEN_ON" ]] && ln -sf "${KITTY_LISTEN_ON#unix:}" /tmp/kitty-socket
fi

# SSH 会话 locale 回退（避免远程服务器没有安装本地 locale 导致乱码）
if [[ -n "$SSH_CONNECTION" ]]; then
    export LANG="${LANG:-en_US.UTF-8}"
    export LC_ALL="${LC_ALL:-en_US.UTF-8}"
fi

# ============================================
# Shell 基础配置
# ============================================

# 重设 HIST*（macOS /etc/zshrc 会覆盖 .zshenv 的值，必须在 .zshrc 中再次设置）
HISTFILE="$ZSH_CACHE_DIR/.zsh_history"
HISTSIZE=10000000
SAVEHIST=10000000
# history 直接适配 `history | fzf`：全部历史、最新在前、带 ISO 时间。
alias history='fc -lir 1'

setopt interactive_comments # 注释行不报错
setopt no_nomatch           # 通配符 * 匹配不到文件也不报错
setopt nocaseglob           # 路径名匹配时忽略大小写
setopt notify               # 后台任务完成后通知
setopt no_beep              # 关闭终端提示音
setopt no_bang_hist         # 不对双引号当中的叹号做历史记录拓展 "!"
setopt GLOB_DOTS            # 文件名展开（globbing）包括以点(dot)开始的文件
setopt rm_star_silent       # 取消 zsh 的安全防护功能（默认对 rm -rf ./* 删除操作触发）

# ============================================
# PATH 与平台配置（必须在插件加载之前，zinit 中的 eza 别名依赖 PATH）
# ============================================

# typeset -U path/fpath 已在 .zshenv 中设置（确保整个加载链去重）

configure_open_reveal_wrapper() {
	(( $+commands[open] )) || return 0
	unalias open 2>/dev/null

	open() {
		emulate -L zsh
		local arg

		if (( $# == 0 )); then
			command open
			return
		fi

		# 仅对纯路径参数保留 Finder reveal；显式选项和 deep link 必须原样透传。
		for arg in "$@"; do
			if [[ "$arg" == -* || "$arg" == *://* ]]; then
				command open "$@"
				return
			fi
		done

		command open -R "$@"
	}
}

if [[ "$OSTYPE" == darwin* ]]; then
	path=(
		"$HOME/.local/bin"
		"$HOME/.cargo/bin"
		/opt/homebrew/opt/openjdk/bin
		"/Applications/IntelliJ IDEA.app/Contents/MacOS"
		"/Applications/PyCharm.app/Contents/MacOS"
		"/Applications/CLion.app/Contents/MacOS"
		"/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
		"/Applications/Cursor.app/Contents/Resources/app/bin"
		/opt/homebrew/opt/grep/libexec/gnubin
		/opt/homebrew/opt/bash/bin
		/opt/homebrew/opt/make/libexec/gnubin
		/opt/homebrew/opt/less/bin
		/opt/homebrew/opt/git/bin
		/opt/homebrew/opt/ruby/bin
		/opt/homebrew/opt/llvm/bin
		$path
	)
	export HOMEBREW_NO_ENV_HINTS=1
	alias cl=clion
	alias py=pycharm
	configure_open_reveal_wrapper

else
	path=(
		"$HOME/.local/bin"
		"$HOME/.pixi/envs/default/bin"
		"$HOME/.pixi/bin"
		/opt/visual-studio-code/bin
		/opt/Cursor/resources/app/bin
		$path
	)

	# Pixi + direnv：进入/离开目录自动加载/卸载环境变量
	if (( $+commands[direnv] )); then  # $+commands[x]: 若 x 在 PATH 中则为 1，否则为 0
		_direnv_cache="$ZSH_CACHE_DIR/direnv-hook.zsh"
		if [[ ! -f "$_direnv_cache" || "$commands[direnv]" -nt "$_direnv_cache" ]]; then  # $commands[x] = x 的绝对路径；-nt = newer than
			direnv hook zsh > "$_direnv_cache"
		fi
		source "$_direnv_cache"
		unset _direnv_cache
	fi

	# OrbStack Linux 支持 open 命令打开 macOS Finder
	[[ -d "/opt/orbstack-guest" ]] && configure_open_reveal_wrapper
fi
unfunction configure_open_reveal_wrapper 2>/dev/null

# Codex stable launch defaults. `-c` overrides these keys after Codex loads the
# normal ~/.codex/config.toml baseline, so MCP/plugins/projects still come from
# the shared config file.
typeset -ga DOTFILES_CODEX_FIXED_CONFIG_ARGS=(
	-c 'model="gpt-5.5"'
	-c 'model_context_window=1050000'
	-c 'model_auto_compact_token_limit=900000'
	-c 'model_reasoning_effort="xhigh"'
	-c 'model_reasoning_summary="detailed"'
	-c 'model_verbosity="low"'
	-c 'approvals_reviewer="guardian_subagent"'
	-c 'approval_policy="never"'
	-c 'sandbox_mode="danger-full-access"'
	-c 'file_opener="vscode"'
	-c 'hide_agent_reasoning=false'
	-c 'show_raw_agent_reasoning=false'
	-c 'suppress_unstable_features_warning=true'
	-c 'service_tier="fast"'
	-c 'desktop.default-service-tier="priority"'
)

codex-raw() {
	emulate -L zsh
	command codex "$@"
}

_dotfiles_codex_first_non_option_arg() {
	emulate -L zsh
	local arg skip_next=0
	REPLY=""

	for arg in "$@"; do
		if (( skip_next )); then
			skip_next=0
			continue
		fi

		case "$arg" in
		--)
			return 1
			;;
		-c | --config | -m | --model | -p | --profile | --profile-v2 | -s | --sandbox | -C | --cd | --add-dir | -a | --ask-for-approval | --remote | --remote-auth-token-env | -i | --image | --enable | --disable)
			skip_next=1
			;;
		--config=* | --model=* | --profile=* | --profile-v2=* | --sandbox=* | --cd=* | --add-dir=* | --ask-for-approval=* | --remote=* | --remote-auth-token-env=* | --image=* | --enable=* | --disable=*)
			;;
		-*)
			;;
		*)
			REPLY="$arg"
			return 0
			;;
		esac
	done

	return 1
}

_dotfiles_codex_should_pin_launch() {
	emulate -L zsh
	local arg first

	for arg in "$@"; do
		case "$arg" in
		-h | --help | -V | --version)
			return 1
			;;
		esac
	done

	if ! _dotfiles_codex_first_non_option_arg "$@"; then
		return 0
	fi

	first="$REPLY"
	case "$first" in
	app)
		return 0
		;;
	exec | e | review | login | logout | mcp | plugin | mcp-server | app-server | remote-control | completion | update | doctor | sandbox | debug | apply | a | resume | fork | cloud | exec-server | features | help)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

codex() {
	emulate -L zsh

	if _dotfiles_codex_should_pin_launch "$@"; then
		codex-raw "${DOTFILES_CODEX_FIXED_CONFIG_ARGS[@]}" "$@"
	else
		codex-raw "$@"
	fi
}

# Kitty smart launch context：记录“本地 shell/TUI 会话代表的目录”，直接写入
# Kitty window user_vars（Kitty 进程内存），不落盘，也不启动 kitten 子进程。
#
# 设计意图：
# - 本地 codex/claude 这类长生命周期 TUI 可能让 foreground cwd 暴露成
#   zinit/fzf-tab/helper/node 包目录；Cmd+E/Cmd+N 应继承启动 TUI 的项目目录。
# - 这个 dotfiles_context_cwd 只服务本地窗口，不是 SSH 远端 cwd 缓存。
#   SSH 远端目录必须交给 kitty ssh kitten 的 ssh_kitten_cmdline +
#   last_reported_cwd/OSC 7 + --cwd=current --hold-after-ssh。
# - 快速连按时真正负责回溯源窗口的是 smart_launch_source_window_id；
#   不要把这里改成 last_reported/current 的全局 cwd 缓存，否则会重新引入
#   plugin/helper cwd 把目录带跑的问题。
if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
	typeset -g DOTFILES_KITTY_CONTEXT_CWD=""

	_dotfiles_kitty_json_escape() {
		emulate -L zsh
		local s="$1"
		s=${s//\\/\\\\}
		s=${s//\"/\\\"}
		s=${s//$'\b'/\\b}
		s=${s//$'\f'/\\f}
		s=${s//$'\n'/\\n}
		s=${s//$'\r'/\\r}
		s=${s//$'\t'/\\t}
		REPLY="$s"
	}

	_dotfiles_kitty_set_context_cwd() {
		emulate -L zsh
		local socket_path=""
		local escaped_cwd escaped_window_id payload socket_fd rc

		if [[ "${KITTY_LISTEN_ON:-}" == unix:* ]]; then
			socket_path="${KITTY_LISTEN_ON#unix:}"
		elif [[ -n "${DOTFILES_KITTY_SOCKET_PATH:-}" && -S "$DOTFILES_KITTY_SOCKET_PATH" ]]; then
			socket_path="$DOTFILES_KITTY_SOCKET_PATH"
		elif [[ -S /tmp/kitty-socket ]]; then
			socket_path="/tmp/kitty-socket"
		else
			return 0
		fi

		[[ -n "$socket_path" ]] || return 0
		zmodload zsh/net/socket 2>/dev/null || return 0

		_dotfiles_kitty_json_escape "$PWD"
		escaped_cwd="$REPLY"
		_dotfiles_kitty_json_escape "$KITTY_WINDOW_ID"
		escaped_window_id="$REPLY"
		payload='{"cmd":"set-user-vars","version":[0,47,0],"no_response":true,"kitty_window_id":"'$escaped_window_id'","payload":{"var":["dotfiles_context_cwd='$escaped_cwd'"]}}'

		zsocket "$socket_path" 2>/dev/null || return 0
		socket_fd="$REPLY"
		print -rn -- $'\eP@kitty-cmd' "$payload" $'\e\\' >&$socket_fd
		rc=$?
		exec {socket_fd}>&- 2>/dev/null || :
		return "$rc"
	}

	_dotfiles_kitty_publish_context_cwd() {
		emulate -L zsh
		[[ -n "${KITTY_WINDOW_ID:-}" ]] || return 0
		[[ -n "${PWD:-}" && -d "$PWD" ]] || return 0
		[[ "${DOTFILES_KITTY_CONTEXT_CWD:-}" == "$PWD" ]] && return 0

		DOTFILES_KITTY_CONTEXT_CWD="$PWD"
		_dotfiles_kitty_set_context_cwd || :
	}

	_dotfiles_kitty_precmd_context() {
		_dotfiles_kitty_publish_context_cwd
	}

	_dotfiles_kitty_preexec_context() {
		_dotfiles_kitty_publish_context_cwd
	}

	autoload -Uz add-zsh-hook
	add-zsh-hook precmd _dotfiles_kitty_precmd_context
	add-zsh-hook preexec _dotfiles_kitty_preexec_context
fi

# 生成 GNU 风格 LS_COLORS，供 completion/fzf-tab 与 ls 类工具共享完整颜色规则。
# 仅在用户未显式设置时初始化，优先使用 Homebrew coreutils 的 gdircolors。
if [[ -z "${LS_COLORS:-}" ]]; then
	typeset _dircolors_cmd=""
	if (( $+commands[gdircolors] )); then
		_dircolors_cmd="$commands[gdircolors]"
	elif (( $+commands[dircolors] )); then
		_dircolors_cmd="$commands[dircolors]"
	fi
	if [[ -n "$_dircolors_cmd" ]]; then
		eval "$("$_dircolors_cmd" -b 2>/dev/null)" 2>/dev/null
	fi
	unset _dircolors_cmd
fi

# p10k/gitstatus and zle widgets require a real terminal. Keep the shell
# utilities above available for automation that invokes `zsh -ic` without a tty.
if [[ -o interactive && ( ! -t 0 || ! -t 1 || ! -t 2 || ! -o zle ) ]]; then
	PROMPT='%n@%m:%~$ '
	RPROMPT=
	return
fi

# ============================================
# 插件加载（PATH 已就绪，插件可安全检测命令是否存在）
# ============================================
[[ -f "${HOME}/.config/zsh/plugins/platform.zsh" ]] && source "${HOME}/.config/zsh/plugins/platform.zsh"
if [[ -f "${HOME}/.config/zsh/plugins/zinit.zsh" && -z "${DOTFILES_ZINIT_LOADED:-}" ]]; then
	# `source ~/.zshrc` 时避免重复初始化 zle/widget 插件；完整刷新请用 `reload`。
	if (( ! ${+functions[zinit]} )); then
		source "${HOME}/.config/zsh/plugins/zinit.zsh"
	fi
	typeset -g DOTFILES_ZINIT_LOADED=1
fi
[[ -f "${HOME}/.config/zsh/plugins/double-esc-clear.zsh" ]] && source "${HOME}/.config/zsh/plugins/double-esc-clear.zsh"
# ============================================
# 凭证与密钥
# ============================================

# age 加密的 tokens（必须在 PATH 设置之后，因为 age 在 pixi 环境中）
[[ -f "${HOME}/.config/zsh/plugins/age-tokens.zsh" ]] && source "${HOME}/.config/zsh/plugins/age-tokens.zsh"

# macOS Keychain 自动解锁（SSH 会话，依赖 age-tokens 提供 MACOS_KEYCHAIN_PASS）
[[ -f "${HOME}/.config/zsh/plugins/ssh-keychain-unlock.zsh" ]] && source "${HOME}/.config/zsh/plugins/ssh-keychain-unlock.zsh"

# SSH Agent (keychain)
# 仅本地运行：keychain 管理 agent，远程依赖 ForwardAgent 转发
# 测试：ssh-add -l && ssh -T git@github.com
_kc_cache="$ZSH_CACHE_DIR/keychain-env.zsh"
if [[ -z "$SSH_CONNECTION" && -f "$HOME/.ssh/id_ed25519" ]] && (( $+commands[keychain] )); then  # $+commands[]: PATH 中是否存在
	if ! { [[ -f "$_kc_cache" ]] && source "$_kc_cache" 2>/dev/null \
		&& [[ -S "$SSH_AUTH_SOCK" ]] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; }; then
		eval "$(keychain --eval --quiet --inherit any --agents ssh id_ed25519 2>/dev/null)" \
			&& typeset -p SSH_AUTH_SOCK SSH_AGENT_PID > "$_kc_cache" 2>/dev/null  # typeset -p: 输出变量的声明语句（可直接 source 还原）
	fi
fi
unset _kc_cache

# ============================================
# 工具配置（ripgrep / fzf / fd）
# ============================================

# ripgrep 全局配置（忽略文件路径须由 shell 展开，不能放 config 里）
export RIPGREP_CONFIG_PATH="$HOME/.config/ripgrep/config"
alias rg='command rg --ignore-file "$HOME/.config/ripgrep/ignore"'

# 加载 fzf 快捷键（Ctrl+T, Ctrl+R, Alt+C），但保留 fzf-tab 的 Tab 补全
if (( $+commands[fzf] )); then  # fzf 是否已安装
	_fzf_cache="$ZSH_CACHE_DIR/fzf-keybindings.zsh"
	if [[ ! -f "$_fzf_cache" || "$commands[fzf]" -nt "$_fzf_cache" ]]; then  # fzf 二进制更新了 → 重新生成缓存
		fzf --zsh > "$_fzf_cache"
	fi
	source "$_fzf_cache"
	unset _fzf_cache
	# 不要在这里 bindkey '^I' fzf-tab-complete ！
	# fzf-tab 通过 zinit turbo 延迟加载，在 enable-fzf-tab 中会自动绑定 ^I。
	# 如果在这里提前绑定，enable-fzf-tab 会误把 fzf-tab-complete 当作"原始 widget"，
	# 导致递归调用自身 → "job table full or recursion limit exceeded"。
fi

# fzf 默认选项：--exact 精确匹配（连续字符），搜索时加 ' 前缀可切换回模糊匹配
export FZF_DEFAULT_OPTS='--no-mouse --exact --preview "${HOME}/.config/zsh/fzf/fzf-preview.sh {}" --bind "shift-left:preview-page-up,shift-right:preview-page-down"'
export FZF_CTRL_R_OPTS='--tac'

# fd 基础参数（手动调用时保持激进搜索）
typeset -ga _fd_opts  # -g = 全局变量，-a = 数组类型
_fd_opts=( -g -H -I -i -a )
if [[ "$OSTYPE" == darwin* ]]; then
	_fd_opts+=( -E .Trash -E /System/Volumes/Data )
else
	_fd_opts+=( -E .local/share/Trash )
fi

# fzf 的默认源额外排除常见大目录，避免 Ctrl+T 在大仓库里遍历过慢。
typeset -ga _fd_fzf_opts
_fd_fzf_opts=( "${_fd_opts[@]}" -E .git -E node_modules -E dist -E target )

# fzf 读取列表时不要走包装函数（避免任何额外输出）
export FZF_DEFAULT_COMMAND="command fd --color=never ${(j: :)_fd_fzf_opts}"  # ${(j: :)arr}: 用空格拼接数组元素为字符串

# fd 智能函数：有免密 sudo 就提权，否则回退普通模式
fd() {
	emulate -L zsh
	local -a pre; sudo -n true 2>/dev/null && pre=(sudo)
	"${pre[@]}" =fd --color=always "${_fd_opts[@]}" "$@" 2>/dev/null  # =fd: 展开为 fd 的绝对路径（绕过本函数自身的递归）
}

# fzf 包装函数：流式清洗管道输入，避免 `history | fzf` 等场景等待上游全量结束。
fzf() {
	if [ -p /dev/stdin ]; then
		# 清除常见 ANSI 控制序列，避免 fzf 读取到颜色码或终端控制指令。
		env -u NO_COLOR command fzf "$@" < <(
			command perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e\][^\a]*(?:\a|\e\\\\)//g; s/\e[P^_][^\e]*(?:\e\\\\)//g; s/\e[@-_]//g'
		)
	else
		env -u NO_COLOR command fzf "$@"
	fi
}

# ============================================
# 命令增强
# ============================================

# bat 映射到 cat（仅当所有参数都是不含 ANSI 的普通文件时才用 bat，其余回退系统 cat）
if (( $+commands[bat] )); then
	cat() {
		emulate -L zsh
		(( $# )) || { command cat; return }
		local f
		for f in "$@"; do
			# 有标志(-x/--x/-)、非普通文件、含 ANSI 转义 → 回退系统 cat
			if [[ "$f" == -* || ! -f "$f" ]]; then
				command cat "$@"; return
			fi
			if LC_ALL=C command grep -q $'\x1b' -- "$f" 2>/dev/null; then
				command cat "$@"; return
			fi
		done
		command bat -- "$@"
	}
fi

# tldr 替代 man（更简洁的命令手册）
(( $+commands[tldr] )) && alias man='tldr'  # tldr 已安装则用它替代 man

# ============================================
# 别名定义
# ============================================

# 工具脚本
alias getip="$HOME/sh-script/get-my-ip.sh"

# 终端操作
alias clear='clear && printf '\''\e[3J'\'''  # 清除整个屏幕（含回滚）
alias reload='exec zsh -l'

# Dotfiles 管理
alias upgrade='/bin/bash -c "$(curl -H '\''Cache-Control: no-cache'\'' -fsSL "https://raw.githubusercontent.com/Learner-Geek-Perfectionist/Dotfiles/refs/heads/beta/install.sh?$(date +%s)")" -- --dotfiles-only && reload'
alias uninstall='/bin/bash -c "$(curl -H '\''Cache-Control: no-cache'\'' -fsSL "https://raw.githubusercontent.com/Learner-Geek-Perfectionist/Dotfiles/refs/heads/beta/uninstall.sh?$(date +%s)")"'

# 常用命令简化
alias python=python3
alias g1='git clone --depth=1 --recursive'
alias mkdir='mkdir -p'
alias cp='cp -r'
alias show='kitty +kitten icat'
alias reboot='sudo reboot'

# claude
alias claude='claude --dangerously-skip-permissions'

# ============================================
# 预编译：加速下次启动（后台执行，不阻塞当前启动）
# ============================================
{
	local f
	# 只编译 ~/.config 和 ~/.cache 下的脚本
	# 不编译 ~/.zshrc ~/.zshenv ~/.zprofile ——避免在 $HOME 下生成 .zwc 缓存文件
	# （对这些小文件，编译带来的启动加速可忽略）
	# 跳过 keychain-env.zsh（含 PID，频繁变更，编译无收益）
	for f in ~/.config/zsh/plugins/*.zsh \
		~/.config/zsh/.p10k.zsh \
		"$ZSH_CACHE_DIR"/*.zsh(N); do  # (N): glob qualifier — 无匹配时返回空（不报错）
		[[ "$f" == *keychain-env.zsh ]] && continue
		[[ -f "$f" && ( ! -f "${f}.zwc" || "$f" -nt "${f}.zwc" ) ]] && zcompile "$f"  # zcompile: 编译为字节码 .zwc，source 时更快
	done
} &!  # &! = 后台执行 + disown（不受 HUP 信号影响，不阻塞启动）
