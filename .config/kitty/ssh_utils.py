# ssh_utils.py — smart_tab.py 和 smart_window.py 共享的 SSH 工具函数

import os
import socket
from functools import lru_cache
from urllib.parse import unquote, urlparse

from kitty.launch import launch as kitty_launch, parse_launch_args
from kittens.ssh.utils import get_connection_data, is_kitten_cmdline

# Smart launch deliberately keeps only two small pieces of state in Kitty window
# user vars:
#
# - smart_launch_source_window_id: a back pointer for rapid Cmd+E/Cmd+N repeats.
#   A newly-created tab can become active before shell integration reports its
#   cwd, so the next key press must be able to walk back to the original stable
#   source window.
# - dotfiles_context_cwd: the local shell/TUI context cwd published by .zshrc.
#   This is for local long-running TUIs such as codex/claude whose foreground
#   process cwd may drift into helper/plugin directories. It is not a remote SSH
#   cwd cache; SSH remote cwd must come from Kitty's ssh kitten metadata and OSC 7
#   last_reported_cwd.
#
# Pitfall: an SSH tab opened by the ssh kitten exposes local bootstrap/helper
# processes immediately, often with cwd=$HOME, while the remote OSC 7 cwd arrives
# later. Do not treat that local helper cwd as a stable SSH cwd during rapid
# repeats, or the second Cmd+E will open at local HOME instead of the remote dir.
_SMART_SOURCE_WINDOW_ID_VAR = 'smart_launch_source_window_id'
_DOTFILES_CONTEXT_CWD_VAR = 'dotfiles_context_cwd'


def _extract_kitten_cmdline_destination(cmdline):
    """识别 kitty/kitten ssh 命令行中的目标主机。"""
    if not cmdline or not is_kitten_cmdline(cmdline):
        return None

    connection_data = get_connection_data(list(cmdline), extra_args=('--kitten',))
    if connection_data is None:
        return None

    return connection_data.hostname


def _resolve_source_window(boss, target_window_id=None):
    if target_window_id is not None:
        window = boss.window_id_map.get(target_window_id)
        if window is not None:
            return window
    return boss.active_window


def _extract_last_reported_cwd(window):
    parsed = _parse_last_reported_cwd(window)
    if parsed is None:
        return None

    if not parsed.path:
        return None

    return unquote(parsed.path)


def _parse_last_reported_cwd(window):
    try:
        reported_cwd = window.screen.last_reported_cwd
    except (AttributeError, OSError):
        return None

    if not reported_cwd:
        return None

    if isinstance(reported_cwd, (bytes, memoryview)):
        reported_cwd = bytes(reported_cwd).decode('utf-8', errors='replace')

    return urlparse(reported_cwd)


def _extract_ssh_kitten_cmdline(window):
    try:
        ssh_kitten_cmdline = window.ssh_kitten_cmdline
    except (AttributeError, OSError):
        return None

    if not callable(ssh_kitten_cmdline):
        return None

    try:
        cmdline = ssh_kitten_cmdline()
    except OSError:
        return None

    return list(cmdline) if cmdline else None


def _extract_cwd_of_child(window):
    try:
        cwd = window.cwd_of_child
    except (AttributeError, OSError):
        return None
    return cwd if cwd else None


def _extract_foreground_process_cwd(window):
    try:
        foreground_processes = window.child.foreground_processes
    except (AttributeError, OSError):
        return None

    if not foreground_processes:
        return None

    # Kitty 会把前台进程链按“helper -> 主 TUI” 的顺序暴露出来，末尾通常才是
    # 真正持有用户工作目录的交互程序（如 claude/codex）。倒序取第一个非空 cwd，
    # 可以避开 pyright/mcp 等 helper 抢占 cwd 的情况。
    for process in reversed(foreground_processes):
        cwd = process.get('cwd') if isinstance(process, dict) else None
        if not cwd:
            continue
        if isinstance(cwd, (bytes, memoryview)):
            cwd = bytes(cwd).decode('utf-8', errors='replace')
        return str(cwd)

    return None


def _extract_user_var(window, key):
    try:
        user_vars = window.user_vars
    except (AttributeError, OSError):
        return None

    if not user_vars:
        return None

    value = user_vars.get(key)
    if not value:
        return None

    if isinstance(value, (bytes, memoryview)):
        value = bytes(value).decode('utf-8', errors='replace')

    return str(value)


def _extract_context_cwd(window):
    cwd = _extract_user_var(window, _DOTFILES_CONTEXT_CWD_VAR)
    if cwd is None:
        return None

    if not os.path.isabs(cwd) or not os.path.isdir(cwd):
        return None

    return cwd


def _window_has_stable_repeat_cwd(window):
    # For local windows, a foreground cwd can be a useful early signal and keeps
    # codex/claude rapid repeats from falling back to HOME. For SSH-shaped
    # windows, however, foreground cwd is usually the local ssh/kitten helper cwd
    # during bootstrap. Wait for last_reported_cwd instead, or walk back through
    # smart_launch_source_window_id to the previous stable SSH source.
    if _extract_last_reported_cwd(window) is not None:
        return True

    ssh_kitten_cmdline = _extract_ssh_kitten_cmdline(window)
    if _window_looks_ssh_shaped(window, ssh_kitten_cmdline=ssh_kitten_cmdline):
        return False

    return _extract_foreground_process_cwd(window) is not None


def _resolve_repeat_source_window(boss, window):
    seen_window_ids = {window.id}
    current_window = window

    # 新开的标签页可能先获得焦点，但此时还没有任何可信的工作目录元数据。
    # 这种情况下沿着记录下来的源窗口链一路回溯，直到找到一个已经稳定上报
    # 工作目录的窗口；SSH bootstrap 暴露的本地 helper cwd 不算稳定远端目录。
    # 如果链断了，就停止回溯。
    while not _window_has_stable_repeat_cwd(current_window):
        source_window_id = _extract_user_var(current_window, _SMART_SOURCE_WINDOW_ID_VAR)
        if source_window_id is None:
            break

        try:
            source_window = boss.window_id_map.get(int(source_window_id))
        except ValueError:
            break

        if source_window is None or source_window.id in seen_window_ids:
            break

        seen_window_ids.add(source_window.id)
        current_window = source_window

    return current_window


def _window_looks_ssh_shaped(window, ssh_kitten_cmdline=None):
    if ssh_kitten_cmdline is not None:
        return True

    try:
        foreground_processes = window.child.foreground_processes
    except (AttributeError, OSError):
        return False

    for process in foreground_processes:
        cmdline = process.get('cmdline', []) or []
        if not cmdline:
            continue

        basename = cmdline[0].rsplit('/', 1)[-1]
        if basename == 'ssh' or is_kitten_cmdline(cmdline):
            return True

    return False


def _source_window_arg(window):
    return f'--source-window=id:{window.id}'


def _build_local_launch_args(launch_type, window, explicit_cwd=None):
    return [
        f'--type={launch_type}',
        _source_window_arg(window),
        f'--cwd={explicit_cwd}' if explicit_cwd else '--cwd=last_reported',
    ]


def _build_native_current_launch_args(launch_type, window):
    return [
        f'--type={launch_type}',
        _source_window_arg(window),
        # `current` 由 kitty 直接基于源窗口立即解析，
        # 可以避开快速连按时 shell integration 上报滞后的竞争。
        '--cwd=current',
    ]


def _build_local_launch_args_without_cwd(launch_type, window):
    return [
        f'--type={launch_type}',
        _source_window_arg(window),
    ]


def _build_established_ssh_launch_args(launch_type, window):
    return [
        f'--type={launch_type}',
        _source_window_arg(window),
        # 对已经建立的 ssh-kitten 会话，kitty 原生的 `current`
        # 语义就能保住远端工作目录，不需要我们再重写 argv。
        '--cwd=current',
        '--hold-after-ssh',
    ]


def _build_explicit_local_fallback_launch_args(launch_type, window, cwd, local_cwd, prefer_known_local_cwd=False):
    # 在“看起来像 SSH，但状态并不明确”的场景里，优先使用已知的本地
    # 子进程工作目录。只有拿不到更可靠的本地信号时，才退回到 `cwd`，因为
    # `cwd` 可能只是陈旧的、或者看起来像远端的 OSC 7 上报。
    explicit_cwd = local_cwd if prefer_known_local_cwd else cwd
    if explicit_cwd is None:
        explicit_cwd = cwd if prefer_known_local_cwd else local_cwd

    # 把 /tmp 和 /private/tmp 这类别名视为同一位置，但保留当前已有的、
    # 用户可见的路径表示，不要强行规范化成 realpath。否则 burst 场景会
    # 看起来像目录“跳变”。
    if cwd is not None and local_cwd is not None and _paths_equivalent(cwd, local_cwd):
        explicit_cwd = cwd
    if explicit_cwd is None:
        return _build_local_launch_args_without_cwd(launch_type, window)

    return _build_local_launch_args(launch_type, window, explicit_cwd=explicit_cwd)


def _with_source_window_var(launch_args, source_window):
    # 给每个新开的窗口都打上“原始稳定源窗口 id”，这样在刚开的标签页上
    # 继续快速连按时，还能在它完成 cwd/ssh 元数据上报前，找回正确的
    # 源窗口。
    var_args = [
        '--var',
        f'{_SMART_SOURCE_WINDOW_ID_VAR}={source_window.id}',
    ]

    context_cwd = _extract_context_cwd(source_window)
    if context_cwd is not None:
        var_args.extend([
            '--var',
            f'{_DOTFILES_CONTEXT_CWD_VAR}={context_cwd}',
        ])

    return [
        launch_args[0],
        launch_args[1],
        *var_args,
        *launch_args[2:],
    ]


def _paths_equivalent(left, right):
    if not left or not right:
        return False

    return os.path.realpath(left) == os.path.realpath(right)


def _normalize_hostname(hostname):
    if not hostname:
        return None

    normalized = hostname.strip().rstrip('.').lower()
    return normalized or None


def _short_hostname(hostname):
    normalized = _normalize_hostname(hostname)
    if normalized is None:
        return None

    return normalized.partition('.')[0]


def _is_plain_hostname_label(hostname):
    normalized = _normalize_hostname(hostname)
    if normalized is None:
        return False

    return '.' not in normalized and ':' not in normalized


def _resolve_host_addresses(hostname):
    normalized = _normalize_hostname(hostname)
    if normalized is None:
        return set()

    addresses = set()
    try:
        addrinfos = socket.getaddrinfo(normalized, None)
    except OSError:
        return addresses

    for addrinfo in addrinfos:
        sockaddr = addrinfo[4] if len(addrinfo) > 4 else None
        if not sockaddr:
            continue

        address = _normalize_hostname(sockaddr[0])
        if address is not None:
            addresses.add(address)

    return addresses


@lru_cache(maxsize=1)
def _local_host_identity_sets():
    full_identities = {'localhost', '127.0.0.1', '::1'}
    short_identities = {'localhost'}

    for candidate in (socket.gethostname(), socket.getfqdn()):
        normalized = _normalize_hostname(candidate)
        if normalized is None:
            continue

        full_identities.add(normalized)
        for address in _resolve_host_addresses(normalized):
            full_identities.add(address)

        short = _short_hostname(normalized)
        if short is not None:
            short_identities.add(short)

    return full_identities, short_identities


def _hostname_matches_local_machine(hostname):
    normalized = _normalize_hostname(hostname)
    if normalized is None:
        return False

    full_identities, short_identities = _local_host_identity_sets()
    if normalized in full_identities:
        return True

    # 短名只能作为弱兜底，并且只在“上报 host 本身不带域名”时才使用。
    # 否则 `dev.local` 和 `dev.corp` 这种同短名不同主机也会被误判成本机。
    if _is_plain_hostname_label(normalized) and normalized in short_identities:
        return True

    return False


def _extract_last_reported_cwd_host(window):
    parsed = _parse_last_reported_cwd(window)
    if parsed is None:
        return None

    return _normalize_hostname(parsed.hostname)


def _reported_cwd_host_confirms_remote(reported_host, destination=None):
    normalized_host = _normalize_hostname(reported_host)
    if normalized_host is None or _hostname_matches_local_machine(normalized_host):
        return False

    return True


def _reported_cwd_path_looks_nonlocal(cwd=None, local_cwd=None):
    return cwd is not None and local_cwd is not None and not _paths_equivalent(cwd, local_cwd)


def _reported_cwd_supports_remote_clone(window, destination=None, cwd=None, local_cwd=None):
    reported_host = _extract_last_reported_cwd_host(window)
    if _reported_cwd_host_confirms_remote(reported_host, destination=destination):
        return True

    # 只有在 OSC 7 根本没有 host 时，路径差异才作为弱证据使用；否则
    # “host 已经上报但和 destination/本机关系不明确”必须 fail closed。
    if reported_host is not None:
        return False

    return _reported_cwd_path_looks_nonlocal(cwd, local_cwd)


def smart_launch(boss, launch_type, target_window_id=None):
    """智能启动新 tab 或 os-window。已建立 SSH 会话走 kitty 原生 launch，connecting 状态直接回本地。"""
    window = _resolve_source_window(boss, target_window_id)
    if window is None:
        return

    # 这里是“快速连按”问题的关键修复：如果当前活跃窗口只是刚打开、还处于
    # “空壳”状态，就先回退到上一个稳定源窗口，再决定 cwd/ssh 行为。
    window = _resolve_repeat_source_window(boss, window)

    ssh_kitten_cmdline = _extract_ssh_kitten_cmdline(window)
    trusted_destination = None
    if ssh_kitten_cmdline is not None:
        trusted_destination = _extract_kitten_cmdline_destination(ssh_kitten_cmdline)

    cwd = _extract_last_reported_cwd(window)
    local_cwd = _extract_cwd_of_child(window)
    foreground_cwd = _extract_foreground_process_cwd(window)
    context_cwd = _extract_context_cwd(window)
    ssh_shaped = _window_looks_ssh_shaped(window, ssh_kitten_cmdline=ssh_kitten_cmdline)
    remote_clone_allowed = (
        trusted_destination is not None
        and cwd is not None
        and _reported_cwd_supports_remote_clone(
            window,
            destination=trusted_destination,
            cwd=cwd,
            local_cwd=local_cwd,
        )
    )

    if remote_clone_allowed:
        # 只有 Kitty 自己确认过的 ssh kitten 元数据，才允许触发远端克隆。
        # 纯 `ssh host` 命令行和前台进程列表只作为“像 SSH” 的弱信号使用，
        # 最多触发本地 fail-closed，不再授权远端目录继承。
        launch_args = _build_established_ssh_launch_args(launch_type, window)
    elif ssh_shaped:
        # 看起来像 SSH，但没有足够证据证明远端克隆目标是安全的。
        # 这里必须 fail closed 到本地，并优先使用已知的本地 cwd 信号。
        launch_args = _build_explicit_local_fallback_launch_args(
            launch_type,
            window,
            cwd,
            local_cwd,
            prefer_known_local_cwd=True,
        )
    else:
        # 优先使用 shell 明确发布的用户上下文目录。它表示“命令从哪里启动”，
        # 不会被 zinit、补全或脚本内部的临时 cd 污染。
        if context_cwd is not None:
            launch_args = _build_local_launch_args(launch_type, window, explicit_cwd=context_cwd)
        elif foreground_cwd is not None:
            launch_args = _build_local_launch_args(launch_type, window, explicit_cwd=foreground_cwd)
        else:
            launch_args = _build_native_current_launch_args(launch_type, window)

    launch_args = _with_source_window_var(launch_args, window)
    opts, remaining = parse_launch_args(launch_args)
    kitty_launch(boss, opts, remaining)
