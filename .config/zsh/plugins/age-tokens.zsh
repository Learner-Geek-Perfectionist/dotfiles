# age-tokens: 使用 age + SSH 密钥加密管理环境变量 tokens
# 依赖: age (https://github.com/FiloSottile/age)
# 密钥: 复用 ~/.ssh/id_ed25519，无需额外管理 age 专用密钥

if (( ! ${+AGE_SSH_KEY} )); then
  readonly AGE_SSH_KEY="${HOME}/.ssh/id_ed25519"
  readonly AGE_SSH_PUB="${HOME}/.ssh/id_ed25519.pub"
  readonly AGE_TOKENS="${HOME}/.tokens.sh.age"
fi

# 启动时自动加载加密的 tokens
() {
  emulate -L zsh
  setopt local_options no_xtrace

  if (( $+commands[age] )) && [[ -f "$AGE_TOKENS" && -f "$AGE_SSH_KEY" ]]; then
    local _age_out
    if _age_out=$(age -d -i "$AGE_SSH_KEY" "$AGE_TOKENS" 2>/dev/null); then
      [[ -n "$_age_out" ]] && eval "$_age_out"
    else
      print -P "%F{yellow}[age-tokens] 解密失败，tokens 未加载%f" >&2
    fi
  fi
}

# 编辑 tokens 的便捷函数
edit-tokens() {
  if [[ ! -f "$AGE_SSH_KEY" ]]; then
    echo "错误：未找到 SSH 密钥 $AGE_SSH_KEY"
    echo "请先生成：ssh-keygen -t ed25519"
    return 1
  fi

  if [[ ! -f "$AGE_SSH_PUB" ]]; then
    echo "错误：未找到 SSH 公钥 $AGE_SSH_PUB"
    return 1
  fi

  local tmp tmp_age before_digest after_digest
  local -a digest_cmd
  tmp=$(umask 077 && mktemp) || { echo "无法创建临时文件"; return 1; }
  trap "rm -f ${(q)tmp}" EXIT INT TERM

  if [[ -f "$AGE_TOKENS" ]]; then
    age -d -i "$AGE_SSH_KEY" "$AGE_TOKENS" > "$tmp" || { echo "解密失败"; rm -f "$tmp"; trap - EXIT INT TERM; return 1; }
  else
    echo '# 每行一个 export，例如：' > "$tmp"
    echo '# export GITHUB_TOKEN="ghp_xxx"' >> "$tmp"
  fi

  if (( $+commands[shasum] )); then
    digest_cmd=(shasum -a 256)
  elif (( $+commands[sha256sum] )); then
    digest_cmd=(sha256sum)
  elif (( $+commands[openssl] )); then
    digest_cmd=(openssl dgst -sha256)
  elif (( $+commands[cksum] )); then
    digest_cmd=(cksum)
  else
    echo "错误：未找到 shasum、sha256sum、openssl 或 cksum"
    rm -f "$tmp"; trap - EXIT INT TERM; return 1
  fi

  before_digest=$("${digest_cmd[@]}" "$tmp") || { echo "无法读取临时文件"; rm -f "$tmp"; trap - EXIT INT TERM; return 1; }

  local editor=$(command -v nvim || command -v vim)
  local -a editor_args
  if [[ -z "$editor" ]]; then
    echo "错误：未找到 nvim 或 vim"
    rm -f "$tmp"; trap - EXIT INT TERM; return 1
  fi

  if [[ "${editor:t}" == "nvim" ]]; then
    editor_args=(-n -i NONE --cmd 'silent! set noswapfile' -c 'silent! setlocal noswapfile noundofile' -c 'silent! set nobackup nowritebackup shada=')
  else
    editor_args=(-n -i NONE --cmd 'silent! set noswapfile' -c 'silent! setlocal noswapfile noundofile' -c 'silent! set nobackup nowritebackup viminfo=')
  fi

  if ! "$editor" "${editor_args[@]}" "$tmp"; then
    echo "编辑器异常退出，放弃保存"
    rm -f "$tmp"; trap - EXIT INT TERM; return 1
  fi

  after_digest=$("${digest_cmd[@]}" "$tmp") || { echo "无法读取临时文件"; rm -f "$tmp"; trap - EXIT INT TERM; return 1; }
  if [[ "$before_digest" == "$after_digest" ]]; then
    rm -f "$tmp"
    trap - EXIT INT TERM
    echo "Tokens unchanged; skipped save and reload."
    return 0
  fi

  # 先加密到临时文件，成功后原子替换，避免损坏原文件
  tmp_age=$(umask 077 && mktemp)
  trap "rm -f ${(q)tmp} ${(q)tmp_age}" EXIT INT TERM
  if age -R "$AGE_SSH_PUB" -o "$tmp_age" "$tmp"; then
    mv "$tmp_age" "$AGE_TOKENS"
  else
    echo "加密失败，原文件未修改"
    rm -f "$tmp_age" "$tmp"; trap - EXIT INT TERM; return 1
  fi

  # 从仍在内存可达的明文直接 source，避免多余的解密
  source "$tmp"
  rm -f "$tmp"
  trap - EXIT INT TERM
  echo "Tokens updated and reloaded."
}
