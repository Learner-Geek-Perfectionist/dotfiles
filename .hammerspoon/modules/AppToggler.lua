-- AppToggler.lua — 应用切换（已聚焦则隐藏，否则启动/聚焦并移动到当前屏幕）

local M = {}

local toggleHints = {
    ["com.mac.utility.clipboard.paste"] = "uPaste",
}

local codexBundleID = "com.openai.codex"
local codexCliPath = "/opt/homebrew/bin/codex"
local codexLaunchPath = "/usr/bin/env"
local codexLaunchEnvPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
local codexRuntimeServiceTier = "fast"
local codexDesktopServiceTier = "priority"
local codexLaunchDefaultsVersion = "2026-05-24-priority-fast-v3"
local codexFixedConfigArgs = {
    "-c", 'model="gpt-5.5"',
    "-c", "model_context_window=1050000",
    "-c", "model_auto_compact_token_limit=900000",
    "-c", 'model_reasoning_effort="xhigh"',
    "-c", 'model_reasoning_summary="detailed"',
    "-c", 'model_verbosity="low"',
    "-c", 'approvals_reviewer="guardian_subagent"',
    "-c", 'approval_policy="never"',
    "-c", 'sandbox_mode="danger-full-access"',
    "-c", 'file_opener="vscode"',
    "-c", "hide_agent_reasoning=false",
    "-c", "show_raw_agent_reasoning=false",
    "-c", "suppress_unstable_features_warning=true",
    "-c", 'service_tier="' .. codexRuntimeServiceTier .. '"',
    "-c", 'desktop.default-service-tier="' .. codexDesktopServiceTier .. '"',
    "-c", 'desktop.localeOverride="zh-CN"',
    "-c", "desktop.preventSleepWhileRunning=true",
    "-c", 'desktop.conversationDetailMode="STEPS_COMMANDS"',
}

local function showToggleHint(bundleID)
    local message = toggleHints[bundleID]
    if message and hs.alert and hs.alert.show then
        hs.alert.show(message)
    end
end

local function getTargetScreen()
    local focusedWin = hs.window.focusedWindow()
    if focusedWin then
        return focusedWin:screen()
    end

    return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

local function getStandardWindow(app)
    local win = app:focusedWindow() or app:mainWindow()
    if win and win:isStandard() then
        return win
    end

    return hs.fnutils.find(app:allWindows(), function(candidate)
        return candidate:isStandard()
    end)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function codexWorkspace()
    return os.getenv("HOME") or "~"
end

local function codexStatePath()
    local codexHome = os.getenv("CODEX_HOME")
    if codexHome and codexHome ~= "" then
        return codexHome .. "/.codex-global-state.json"
    end

    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end

    return home .. "/.codex/.codex-global-state.json"
end

local function codexConfigPath()
    local codexHome = os.getenv("CODEX_HOME")
    if codexHome and codexHome ~= "" then
        return codexHome .. "/config.toml"
    end

    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end

    return home .. "/.codex/config.toml"
end

local function codexLaunchMarkerPath()
    local codexHome = os.getenv("CODEX_HOME")
    if codexHome and codexHome ~= "" then
        return codexHome .. "/codex-launch-defaults-hammerspoon.json"
    end

    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end

    return home .. "/.codex/codex-launch-defaults-hammerspoon.json"
end

local function buildCodexDesktopState(state)
    if type(state) ~= "table" then
        state = {}
    end

    local persistedAtomState = state["electron-persisted-atom-state"]
    if type(persistedAtomState) ~= "table" then
        persistedAtomState = {}
        state["electron-persisted-atom-state"] = persistedAtomState
    end

    local agentModeByHostID = persistedAtomState["agent-mode-by-host-id"]
    if type(agentModeByHostID) ~= "table" then
        agentModeByHostID = {}
        persistedAtomState["agent-mode-by-host-id"] = agentModeByHostID
    end

    persistedAtomState["default-service-tier"] = codexDesktopServiceTier
    persistedAtomState["has-user-changed-service-tier"] = true
    persistedAtomState["has-seen-fast-mode-announcement"] = true
    persistedAtomState["skip-full-access-confirm"] = true
    agentModeByHostID["local"] = "full-access"

    return state
end

local function escapeLuaPattern(value)
    return tostring(value):gsub("([^%w])", "%%%1")
end

local function splitLines(content)
    local lines = {}
    content = tostring(content or ""):gsub("\r\n", "\n")
    if content == "" then
        return lines
    end
    if content:sub(-1) ~= "\n" then
        content = content .. "\n"
    end
    for line in content:gmatch("(.-)\n") do
        table.insert(lines, line)
    end
    return lines
end

local function joinLines(lines)
    return table.concat(lines, "\n") .. "\n"
end

local function upsertTomlKey(content, sectionName, key, valueLiteral)
    local lines = splitLines(content)
    local escapedKey = escapeLuaPattern(key)
    local firstSectionIndex = nil
    local targetStart = nil
    local targetEnd = nil

    if sectionName == nil then
        targetStart = 1
    end

    for index, line in ipairs(lines) do
        local header = line:match("^%s*%[([^%]]+)%]%s*$")
        if header then
            firstSectionIndex = firstSectionIndex or index
            if sectionName == nil then
                targetEnd = index - 1
                break
            elseif header == sectionName then
                targetStart = index
            elseif targetStart and not targetEnd then
                targetEnd = index - 1
                break
            end
        end
    end

    if sectionName == nil then
        targetEnd = targetEnd or #lines
    elseif targetStart then
        targetEnd = targetEnd or #lines
    else
        if #lines > 0 and lines[#lines] ~= "" then
            table.insert(lines, "")
        end
        table.insert(lines, "[" .. sectionName .. "]")
        table.insert(lines, key .. " = " .. valueLiteral)
        return joinLines(lines)
    end

    for index = targetStart, targetEnd do
        if lines[index]:match("^%s*" .. escapedKey .. "%s*=") then
            lines[index] = key .. " = " .. valueLiteral
            return joinLines(lines)
        end
    end

    local insertIndex
    if sectionName == nil then
        insertIndex = firstSectionIndex or (#lines + 1)
    else
        insertIndex = targetEnd + 1
    end
    table.insert(lines, insertIndex, key .. " = " .. valueLiteral)
    return joinLines(lines)
end

local function buildCodexConfig(content)
    content = upsertTomlKey(content, nil, "model", '"gpt-5.5"')
    content = upsertTomlKey(content, nil, "model_context_window", "1050000")
    content = upsertTomlKey(content, nil, "model_auto_compact_token_limit", "900000")
    content = upsertTomlKey(content, nil, "model_reasoning_effort", '"xhigh"')
    content = upsertTomlKey(content, nil, "model_reasoning_summary", '"detailed"')
    content = upsertTomlKey(content, nil, "model_verbosity", '"low"')
    content = upsertTomlKey(content, nil, "approvals_reviewer", '"guardian_subagent"')
    content = upsertTomlKey(content, nil, "approval_policy", '"never"')
    content = upsertTomlKey(content, nil, "sandbox_mode", '"danger-full-access"')
    content = upsertTomlKey(content, nil, "file_opener", '"vscode"')
    content = upsertTomlKey(content, nil, "hide_agent_reasoning", "false")
    content = upsertTomlKey(content, nil, "show_raw_agent_reasoning", "false")
    content = upsertTomlKey(content, nil, "suppress_unstable_features_warning", "true")
    content = upsertTomlKey(content, nil, "service_tier", '"' .. codexRuntimeServiceTier .. '"')
    content = upsertTomlKey(content, "desktop", "localeOverride", '"zh-CN"')
    content = upsertTomlKey(content, "desktop", "preventSleepWhileRunning", "true")
    content = upsertTomlKey(content, "desktop", "conversationDetailMode", '"STEPS_COMMANDS"')
    content = upsertTomlKey(content, "desktop", "default-service-tier", '"' .. codexDesktopServiceTier .. '"')
    content = upsertTomlKey(content, "desktop.open-in-target-preferences", "global", '"vscode"')
    return content
end

local function readFile(path)
    local handle, err = io.open(path, "r")
    if not handle then
        return nil, err
    end

    local content = handle:read("*a")
    handle:close()
    return content
end

local function writeFileAtomically(path, content)
    local tmpPath = path .. ".tmp"
    local handle, err = io.open(tmpPath, "w")
    if not handle then
        return false, err
    end

    local ok, writeErr = handle:write(content)
    local closeOk, closeErr = handle:close()
    if not ok or not closeOk then
        os.remove(tmpPath)
        return false, writeErr or closeErr
    end

    local renameOk, renameErr = os.rename(tmpPath, path)
    if not renameOk then
        os.remove(tmpPath)
        return false, renameErr
    end

    return true
end

local function decodeJsonTable(content)
    local decodeOk, decoded = pcall(hs.json.decode, content)
    if not decodeOk or type(decoded) ~= "table" then
        return nil
    end

    return decoded
end

local function writeCodexLaunchMarker(payload)
    if not hs.json or not hs.json.encode then
        return false, "hs.json unavailable"
    end

    local path = codexLaunchMarkerPath()
    if not path then
        return false, "CODEX_HOME/HOME unavailable"
    end

    local encodeOk, encoded = pcall(hs.json.encode, payload)
    if not encodeOk or type(encoded) ~= "string" then
        return false, "marker JSON encode failed"
    end

    return writeFileAtomically(path, encoded .. "\n")
end

local function syncCodexDesktopState()
    if not hs.json or not hs.json.decode or not hs.json.encode then
        return false, "hs.json unavailable"
    end

    local path = codexStatePath()
    if not path then
        return false, "CODEX_HOME/HOME unavailable"
    end

    local backupPath = path .. ".bak"
    local state = {}
    local content, readErr = readFile(path)
    if content and content ~= "" then
        local decoded = decodeJsonTable(content)
        if decoded then
            state = decoded
        else
            local backupContent = readFile(backupPath)
            local backupDecoded = backupContent and backupContent ~= "" and decodeJsonTable(backupContent) or nil
            if not backupDecoded then
                return false, "invalid state JSON"
            end
            state = backupDecoded
        end
    elseif readErr and not tostring(readErr):find("No such file", 1, true) then
        return false, readErr
    else
        local backupContent = readFile(backupPath)
        local backupDecoded = backupContent and backupContent ~= "" and decodeJsonTable(backupContent) or nil
        if backupDecoded then
            state = backupDecoded
        end
    end

    state = buildCodexDesktopState(state)

    local encodeOk, encoded = pcall(hs.json.encode, state)
    if not encodeOk or type(encoded) ~= "string" then
        return false, "state JSON encode failed"
    end

    local writeOk, writeErr = writeFileAtomically(path, encoded .. "\n")
    if not writeOk then
        return false, writeErr
    end

    return writeFileAtomically(backupPath, encoded .. "\n")
end

local function syncCodexConfig()
    local path = codexConfigPath()
    if not path then
        return false, "CODEX_HOME/HOME unavailable"
    end

    local content, readErr = readFile(path)
    if not content then
        if readErr and not tostring(readErr):find("No such file", 1, true) then
            return false, readErr
        end
        content = ""
    end

    return writeFileAtomically(path, buildCodexConfig(content))
end

local function syncCodexLaunchDefaults()
    local stateOk, stateErr = syncCodexDesktopState()
    local configOk, configErr = syncCodexConfig()

    writeCodexLaunchMarker({
        version = codexLaunchDefaultsVersion,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        runtime_service_tier = codexRuntimeServiceTier,
        desktop_service_tier = codexDesktopServiceTier,
        state_ok = stateOk,
        state_error = stateErr,
        config_ok = configOk,
        config_error = configErr,
    })

    if not stateOk then
        return false, stateErr
    end
    if not configOk then
        return false, configErr
    end

    return true
end

local function openCodexApp()
    local syncOk, syncErr = syncCodexLaunchDefaults()
    if not syncOk and hs.alert and hs.alert.show then
        hs.alert.show("Codex launch defaults sync skipped: " .. tostring(syncErr or "unknown error"))
    end

    if not hs.task or not hs.task.new then
        hs.execute("/usr/bin/env -u NO_COLOR /usr/bin/open -b " .. shellQuote(codexBundleID), true)
        return
    end

    local args = { "-u", "NO_COLOR", "PATH=" .. codexLaunchEnvPath, codexCliPath, "app" }
    for _, arg in ipairs(codexFixedConfigArgs) do
        table.insert(args, arg)
    end
    table.insert(args, codexWorkspace())

    hs.task.new(codexLaunchPath, function(exitCode, _, stdErr)
        if exitCode ~= 0 and hs.alert and hs.alert.show then
            hs.alert.show("Codex launch failed: " .. tostring(stdErr or ""))
        end
    end, args):start()
end

local function openApp(bundleID)
    if bundleID == codexBundleID then
        openCodexApp()
        return
    end

    hs.execute("/usr/bin/env -u NO_COLOR /usr/bin/open -b " .. shellQuote(bundleID), true)
end

local function prepareWindowForFocus(win, targetScreen)
    if not win then
        return nil
    end

    -- 先移再恢复：如果窗口被最小化，先尝试在最小化状态下挪到目标屏幕，
    -- 这样 unminimize 的动画直接在目标屏幕播放，避免在原屏幕闪一下。
    if targetScreen and win:screen() ~= targetScreen then
        win:moveToScreen(targetScreen, false, true)
    end

    if win:isMinimized() then
        win:unminimize()
        -- 兜底：某些 app 最小化时 moveToScreen 不生效，unminimize 后再补一次。
        if targetScreen and win:screen() ~= targetScreen then
            win:moveToScreen(targetScreen, false, true)
        end
    end

    return win
end

local function focusExistingWindow(app, targetScreen)
    local win = prepareWindowForFocus(getStandardWindow(app), targetScreen)
    if not win then
        return false
    end

    if app:isHidden() then
        app:unhide()
    end

    win:focus()
    return true
end

local function focusAppWindowOnScreen(bundleID, targetScreen, retries, reopenAttempted, activationAttempted)
    local app = hs.application.get(bundleID)
    if not app then
        if retries > 0 then
            hs.timer.doAfter(0.1, function()
                focusAppWindowOnScreen(bundleID, targetScreen, retries - 1, reopenAttempted, activationAttempted)
            end)
        end
        return
    end

    -- 现成窗口优先：先把窗口拉到当前屏幕，再聚焦，避免跨屏时先在旧屏幕闪一下。
    if focusExistingWindow(app, targetScreen) then
        return
    end

    if not activationAttempted then
        if app:isHidden() then
            app:unhide()
        end

        -- 只有在拿不到可聚焦窗口时才激活应用，降低跨屏切换的前台闪烁。
        app:activate()
        activationAttempted = true

        if focusExistingWindow(app, targetScreen) then
            return
        end
    end

    if not reopenAttempted then
        -- 某些应用只剩系统级窗口而没有标准窗口；补发 reopen 事件拉起可聚焦窗口。
        openApp(bundleID)
        reopenAttempted = true
    end

    if retries > 0 then
        -- 某些应用在 activate / reopen 之后才会异步创建或暴露窗口。
        hs.timer.doAfter(0.1, function()
            focusAppWindowOnScreen(bundleID, targetScreen, retries - 1, reopenAttempted, activationAttempted)
        end)
    end
end

function M.toggle(bundleID)
    showToggleHint(bundleID)

    local app = hs.application.get(bundleID)
    if app and app:isFrontmost() and getStandardWindow(app) then
        app:hide()
        return
    end

    local targetScreen = getTargetScreen()

    if app then
        local reopenAttempted = false
        if bundleID == codexBundleID then
            openCodexApp()
            reopenAttempted = true
        end
        focusAppWindowOnScreen(bundleID, targetScreen, 10, reopenAttempted, false)
        return
    end

    openApp(bundleID)
    focusAppWindowOnScreen(bundleID, targetScreen, 15, false, false)
end

M._codexDesktopStateForTest = buildCodexDesktopState
M._codexConfigForTest = buildCodexConfig
M._codexLaunchMarkerPathForTest = codexLaunchMarkerPath
M._syncCodexDesktopStateForTest = syncCodexDesktopState
M._syncCodexConfigForTest = syncCodexConfig

return M
