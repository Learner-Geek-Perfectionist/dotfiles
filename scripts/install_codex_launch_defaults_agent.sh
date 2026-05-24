#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync_codex_launch_defaults.js"
LABEL="com.dotfiles.codex-launch-defaults"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CODEX_HOME_DIR="$HOME/.codex"
LOG_DIR="$HOME/Library/Logs"
LAUNCHD_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(uname -s)" != "Darwin" ]]; then
	exit 0
fi

if [[ ! -f "$SYNC_SCRIPT" ]]; then
	printf 'Missing Codex launch defaults sync script: %s\n' "$SYNC_SCRIPT" >&2
	exit 1
fi

if ! PATH="$LAUNCHD_PATH" command -v node >/dev/null 2>&1; then
	printf 'node is not available; skipping Codex launch defaults LaunchAgent\n' >&2
	exit 0
fi

REAL_HOME="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{ print $2; exit }' || true)"
if [[ -n "$REAL_HOME" && "$HOME" != "$REAL_HOME" ]]; then
	mkdir -p "$CODEX_HOME_DIR"
	CODEX_HOME="$CODEX_HOME_DIR" PATH="$LAUNCHD_PATH" node "$SYNC_SCRIPT" >/dev/null
	printf 'Skipped Codex launch defaults LaunchAgent because HOME is not the account home: %s\n' "$HOME"
	exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$CODEX_HOME_DIR" "$LOG_DIR"

tmp_plist="$(mktemp)"
trap 'rm -f "$tmp_plist"' EXIT

cat >"$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/env</string>
		<string>node</string>
		<string>$SYNC_SCRIPT</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>CODEX_HOME</key>
		<string>$CODEX_HOME_DIR</string>
		<key>PATH</key>
		<string>$LAUNCHD_PATH</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>WatchPaths</key>
	<array>
		<string>$CODEX_HOME_DIR/config.toml</string>
		<string>$CODEX_HOME_DIR/.codex-global-state.json</string>
		<string>$CODEX_HOME_DIR/.codex-global-state.json.bak</string>
	</array>
	<key>ThrottleInterval</key>
	<integer>2</integer>
	<key>StandardOutPath</key>
	<string>$LOG_DIR/$LABEL.log</string>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR/$LABEL.err.log</string>
</dict>
</plist>
EOF

if [[ -f "$PLIST" ]] && cmp -s "$PLIST" "$tmp_plist"; then
	rm -f "$tmp_plist"
else
	mv "$tmp_plist" "$PLIST"
fi
chmod 644 "$PLIST"

CODEX_HOME="$CODEX_HOME_DIR" PATH="$LAUNCHD_PATH" node "$SYNC_SCRIPT" >/dev/null

if command -v launchctl >/dev/null 2>&1; then
	domain="gui/$(id -u)"
	launchctl bootout "$domain/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
	if launchctl bootstrap "$domain" "$PLIST" >/dev/null 2>&1; then
		launchctl enable "$domain/$LABEL" >/dev/null 2>&1 || true
		launchctl kickstart -k "$domain/$LABEL" >/dev/null 2>&1 || true
	else
		launchctl load -w "$PLIST" >/dev/null 2>&1 || {
			printf 'Wrote LaunchAgent, but launchctl could not load it: %s\n' "$PLIST" >&2
			exit 1
		}
	fi
fi

printf 'Codex launch defaults LaunchAgent installed: %s\n' "$PLIST"
