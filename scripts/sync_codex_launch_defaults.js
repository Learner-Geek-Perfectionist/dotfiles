#!/usr/bin/env node
// Keep Codex CLI runtime defaults and Codex.app persisted UI defaults aligned.

const fs = require("fs");
const os = require("os");
const path = require("path");

const runtimeDefaults = [
  ["model", '"gpt-5.5"'],
  ["model_context_window", "1050000"],
  ["model_auto_compact_token_limit", "900000"],
  ["model_reasoning_effort", '"xhigh"'],
  ["model_reasoning_summary", '"detailed"'],
  ["model_verbosity", '"low"'],
  ["approvals_reviewer", '"guardian_subagent"'],
  ["approval_policy", '"never"'],
  ["sandbox_mode", '"danger-full-access"'],
  ["file_opener", '"vscode"'],
  ["hide_agent_reasoning", "false"],
  ["show_raw_agent_reasoning", "false"],
  ["suppress_unstable_features_warning", "true"],
  ["service_tier", '"fast"'],
];

const desktopDefaults = [
  ["localeOverride", '"zh-CN"'],
  ["preventSleepWhileRunning", "true"],
  ["conversationDetailMode", '"STEPS_COMMANDS"'],
  // Codex.app currently exposes the Fast menu item as service tier id
  // "priority" for GPT-5.5. Runtime config still uses service_tier="fast".
  ["default-service-tier", '"priority"'],
];

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const configPath = path.join(codexHome, "config.toml");
const statePath = path.join(codexHome, ".codex-global-state.json");
const stateBackupPath = `${statePath}.bak`;

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return "";
    }
    throw error;
  }
}

function writeTextAtomically(filePath, content, mode) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmpPath = `${filePath}.tmp-${process.pid}`;
  fs.writeFileSync(tmpPath, content, { mode });
  fs.renameSync(tmpPath, filePath);
  if (mode != null) {
    fs.chmodSync(filePath, mode);
  }
}

function writeTextAtomicallyIfChanged(filePath, content, mode) {
  if (readText(filePath) === content) {
    return false;
  }
  writeTextAtomically(filePath, content, mode);
  return true;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function splitLines(content) {
  const normalized = String(content || "").replace(/\r\n/g, "\n");
  if (normalized === "") {
    return [];
  }
  return normalized.endsWith("\n")
    ? normalized.slice(0, -1).split("\n")
    : normalized.split("\n");
}

function joinLines(lines) {
  return `${lines.join("\n")}\n`;
}

function upsertTomlKey(content, sectionName, key, valueLiteral) {
  const lines = splitLines(content);
  const keyPattern = new RegExp(`^\\s*${escapeRegExp(key)}\\s*=`);
  let firstSectionIndex = null;
  let targetStart = sectionName == null ? 0 : null;
  let targetEnd = null;

  for (let index = 0; index < lines.length; index += 1) {
    const header = lines[index].match(/^\s*\[([^\]]+)\]\s*$/);
    if (!header) {
      continue;
    }

    if (firstSectionIndex == null) {
      firstSectionIndex = index;
    }

    if (sectionName == null) {
      targetEnd = index - 1;
      break;
    }

    if (header[1] === sectionName) {
      targetStart = index;
      continue;
    }

    if (targetStart != null && targetEnd == null) {
      targetEnd = index - 1;
      break;
    }
  }

  if (sectionName == null) {
    targetEnd = targetEnd == null ? lines.length - 1 : targetEnd;
  } else if (targetStart != null) {
    targetEnd = targetEnd == null ? lines.length - 1 : targetEnd;
  } else {
    if (lines.length > 0 && lines[lines.length - 1] !== "") {
      lines.push("");
    }
    lines.push(`[${sectionName}]`, `${key} = ${valueLiteral}`);
    return joinLines(lines);
  }

  for (let index = targetStart; index <= targetEnd; index += 1) {
    if (keyPattern.test(lines[index])) {
      lines[index] = `${key} = ${valueLiteral}`;
      return joinLines(lines);
    }
  }

  const insertIndex =
    sectionName == null ? firstSectionIndex ?? lines.length : targetEnd + 1;
  lines.splice(insertIndex, 0, `${key} = ${valueLiteral}`);
  return joinLines(lines);
}

function buildConfig(content) {
  let next = content;
  for (const [key, value] of runtimeDefaults) {
    next = upsertTomlKey(next, null, key, value);
  }
  for (const [key, value] of desktopDefaults) {
    next = upsertTomlKey(next, "desktop", key, value);
  }
  next = upsertTomlKey(
    next,
    "desktop.open-in-target-preferences",
    "global",
    '"vscode"',
  );
  return next;
}

function readState(filePath) {
  const content = readText(filePath);
  if (content.trim() === "") {
    return {};
  }
  return JSON.parse(content);
}

function buildState(state) {
  const next = state && typeof state === "object" && !Array.isArray(state) ? state : {};
  const persisted =
    next["electron-persisted-atom-state"] &&
    typeof next["electron-persisted-atom-state"] === "object" &&
    !Array.isArray(next["electron-persisted-atom-state"])
      ? next["electron-persisted-atom-state"]
      : {};
  next["electron-persisted-atom-state"] = persisted;

  const modeByHost =
    persisted["agent-mode-by-host-id"] &&
    typeof persisted["agent-mode-by-host-id"] === "object" &&
    !Array.isArray(persisted["agent-mode-by-host-id"])
      ? persisted["agent-mode-by-host-id"]
      : {};
  persisted["agent-mode-by-host-id"] = modeByHost;

  persisted["default-service-tier"] = "priority";
  persisted["has-user-changed-service-tier"] = true;
  persisted["has-seen-fast-mode-announcement"] = true;
  persisted["skip-full-access-confirm"] = true;
  modeByHost.local = "full-access";

  return next;
}

function syncConfig() {
  return writeTextAtomicallyIfChanged(
    configPath,
    buildConfig(readText(configPath)),
    0o600,
  );
}

function syncStateFile(filePath) {
  return writeTextAtomicallyIfChanged(
    filePath,
    `${JSON.stringify(buildState(readState(filePath)), null, 2)}\n`,
    0o600,
  );
}

function main() {
  let changed = false;
  changed = syncConfig() || changed;
  changed = syncStateFile(statePath) || changed;
  if (fs.existsSync(stateBackupPath)) {
    changed = syncStateFile(stateBackupPath) || changed;
  }
  if (changed) {
    console.log(`Synced Codex launch defaults in ${codexHome}`);
  }
}

main();
