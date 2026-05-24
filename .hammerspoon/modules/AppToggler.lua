-- AppToggler.lua — 应用切换（已聚焦则隐藏，否则启动/聚焦并移动到当前屏幕）

local M = {}

local toggleHints = {
    ["com.mac.utility.clipboard.paste"] = "uPaste",
}

local codexBundleID = "com.openai.codex"
local codexCliPath = "/opt/homebrew/bin/codex"
local codexLaunchPath = "/usr/bin/env"
local codexLaunchEnvPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
    "-c", 'service_tier="fast"',
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

local function openCodexApp()
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
        focusAppWindowOnScreen(bundleID, targetScreen, 10, false, false)
        return
    end

    openApp(bundleID)
    focusAppWindowOnScreen(bundleID, targetScreen, 15, false, false)
end

return M
