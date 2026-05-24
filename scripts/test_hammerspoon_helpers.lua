local repoRoot = (... and debug.getinfo(1, "S").source:sub(2):match("^(.*)/scripts/")) or "."

package.path = table.concat({
    repoRoot .. "/.hammerspoon/?.lua",
    repoRoot .. "/.hammerspoon/?/init.lua",
    package.path,
}, ";")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function assertTrue(actual, message)
    if not actual then
        error(message)
    end
end

local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local content = handle:read("*a")
    handle:close()
    return content
end

local function fileExists(path)
    local handle = io.open(path, "r")
    if not handle then
        return false
    end
    handle:close()
    return true
end

local windowManagement = require("modules.windowManagement")
local keyConfig = require("config.keyConfig")

local fakeApp = {
    allWindows = function()
        return {
            { id = function() return 30 end, isStandard = function() return true end },
            { id = function() return 10 end, isStandard = function() return false end },
            { id = function() return 20 end, isStandard = function() return true end },
        }
    end,
    visibleWindows = function()
        return {
            { id = function() return 30 end, isStandard = function() return true end },
        }
    end,
}
assertEqual(type(windowManagement._collectStandardWindows), "function", "windowManagement exposes its collection helper for regression tests")
assertEqual(type(windowManagement._nextIndex), "function", "windowManagement exposes its index helper for regression tests")
assertEqual(type(windowManagement.moveToPositionFromShortcut), "function", "windowManagement exposes the shared shortcut entrypoint")
assertEqual(type(windowManagement.startHyperArrowEventtap), "function", "windowManagement exposes the Hammerspoon eventtap entrypoint")
assertTrue(not readFile(repoRoot .. "/.hammerspoon/config/KeyBinds.lua"):find("moveToFocusedScreen", 1, true), "KeyBinds uses the default cross-screen switch behavior without redundant args")
assertTrue(not readFile(repoRoot .. "/.hammerspoon/config/KeyBinds.lua"):find("hs%.hotkey%.bind%(%{%}, key"), "KeyBinds does not depend on bare F17-F20 events")
assertTrue(readFile(repoRoot .. "/.hammerspoon/config/KeyBinds.lua"):find("startHyperArrowEventtap", 1, true), "KeyBinds routes Hyper arrows through eventtap")
assertTrue(not fileExists(repoRoot .. "/.hammerspoon/bin/move-window"), "Hyper arrow routing no longer depends on a shell helper")
assertTrue(readFile(repoRoot .. "/.hammerspoon/init.lua"):find("require%([\"']hs%.ipc[\"']%)"), "Hammerspoon init loads hs.ipc so the hs CLI can talk to the running app")
assertTrue(readFile(repoRoot .. "/.hammerspoon/modules/systemInfo.lua"):find("math.max(0, obj.current_down - obj.last_down)", 1, true), "systemInfo clamps negative download deltas")
assertTrue(readFile(repoRoot .. "/.hammerspoon/modules/systemInfo.lua"):find("math.max(0, obj.current_up - obj.last_up)", 1, true), "systemInfo clamps negative upload deltas")

local appMappingByKey = {}
for _, appMapping in ipairs(keyConfig.keyConfig) do
    appMappingByKey[appMapping[1]] = appMapping[2]
end
assertEqual(appMappingByKey["c"], "com.openai.codex", "Hyper/right_command+c opens Codex")

local collected = windowManagement._collectStandardWindows(fakeApp)
assertEqual(#collected, 2, "window collection uses all app windows, not only visible ones")
assertEqual(collected[1]:id(), 20, "window collection sorts windows by id")
assertEqual(collected[2]:id(), 30, "window collection preserves the remaining standard window")

local collectedWithNilId = windowManagement._collectStandardWindows({
    allWindows = function()
        return {
            { id = function() return nil end, isStandard = function() return true end },
            { id = function() return 20 end, isStandard = function() return true end },
        }
    end,
})
assertEqual(#collectedWithNilId, 2, "window collection keeps standard windows even when one id is missing")
assertEqual(collectedWithNilId[1]:id(), nil, "missing ids sort safely to the front")
assertEqual(collectedWithNilId[2]:id(), 20, "non-nil ids remain available after safe sort")

assertEqual(windowManagement._nextIndex({ 101, 202, 303 }, 101), 2, "cycles to the next window")
assertEqual(windowManagement._nextIndex({ 101, 202, 303 }, 303), 1, "wraps to the first window")
assertEqual(windowManagement._nextIndex({ 101, 202, 303 }, 999), 1, "falls back to the first window when focus is missing")
assertEqual(windowManagement._nextIndex({}, 999), nil, "returns nil for an empty window list")

local shortcutMovedFrame = nil
local focusedShortcutWindow = {
    screen = function()
        return {
            frame = function()
                return { x = 0, y = 0, w = 1000, h = 800 }
            end,
        }
    end,
    setFrame = function(_, frame)
        shortcutMovedFrame = frame
    end,
}
hs = {
    application = {
        get = function()
            return nil
        end,
    },
    mouse = {
        absolutePosition = function()
            return { x = 0, y = 0 }
        end,
    },
    window = {
        focusedWindow = function()
            return focusedShortcutWindow
        end,
    },
}
assertTrue(windowManagement.moveToPositionFromShortcut("up"), "Karabiner shortcut entrypoint falls back to the focused window outside Parallels")
assertEqual(shortcutMovedFrame.w, 1000, "focused-window fallback can still maximize the focused window")

local inactiveParallelsMoved = false
local focusedFallbackMoved = false
local inactiveParallelsWindow = {
    id = function()
        return 1
    end,
    isStandard = function()
        return true
    end,
    isVisible = function()
        return true
    end,
    frame = function()
        return { x = 900, y = 900, w = 100, h = 100 }
    end,
    screen = function()
        return {
            frame = function()
                return { x = 0, y = 0, w = 1000, h = 800 }
            end,
        }
    end,
    setFrame = function()
        inactiveParallelsMoved = true
    end,
}
local focusedFallbackWindow = {
    screen = inactiveParallelsWindow.screen,
    setFrame = function()
        focusedFallbackMoved = true
    end,
}
hs = {
    application = {
        get = function(bundleID)
            if bundleID == "com.parallels.macvm" then
                return {
                    allWindows = function()
                        return { inactiveParallelsWindow }
                    end,
                    isFrontmost = function()
                        return false
                    end,
                }
            end
            return nil
        end,
    },
    mouse = {
        absolutePosition = function()
            return { x = 0, y = 0 }
        end,
    },
    window = {
        focusedWindow = function()
            return focusedFallbackWindow
        end,
    },
}
assertTrue(windowManagement.moveToPositionFromShortcut("left"), "Karabiner shortcut entrypoint moves the focused window when Parallels is only running in the background")
assertTrue(focusedFallbackMoved, "focused window receives the global Hyper arrow command")
assertTrue(not inactiveParallelsMoved, "background Parallels VM is not moved by global Hyper arrows")

local eventtapCallback = nil
local eventtapStarted = false
local eventtapMovedFrame = nil
local eventtapFocusedWindow = {
    screen = function()
        return {
            frame = function()
                return { x = 0, y = 0, w = 1440, h = 900 }
            end,
        }
    end,
    setFrame = function(_, frame)
        eventtapMovedFrame = frame
    end,
}
hs = {
    application = {
        get = function()
            return nil
        end,
    },
    eventtap = {
        event = {
            types = {
                keyDown = "keyDown",
            },
        },
        new = function(types, callback)
            assertEqual(types[1], "keyDown", "Hyper arrow eventtap listens only to keyDown")
            eventtapCallback = callback
            return {
                start = function()
                    eventtapStarted = true
                end,
            }
        end,
    },
    keycodes = {
        map = {
            left = 123,
            right = 124,
            down = 125,
            up = 126,
        },
    },
    mouse = {
        absolutePosition = function()
            return { x = 0, y = 0 }
        end,
    },
    window = {
        focusedWindow = function()
            return eventtapFocusedWindow
        end,
    },
}
windowManagement.startHyperArrowEventtap()
assertTrue(eventtapStarted, "Hyper arrow eventtap starts immediately")
assertTrue(eventtapCallback({
    getFlags = function()
        return { ctrl = true, alt = true, cmd = true }
    end,
    getKeyCode = function()
        return 126
    end,
}), "Hyper up is consumed by the eventtap")
assertEqual(eventtapMovedFrame.w, 1440, "Hyper up maximizes through the eventtap")
assertTrue(eventtapCallback({
    getFlags = function()
        return { ctrl = true, alt = true, cmd = true, fn = true }
    end,
    getKeyCode = function()
        return 126
    end,
}), "Hyper arrows are consumed even when macOS marks arrow keys with fn")
assertTrue(not eventtapCallback({
    getFlags = function()
        return { ctrl = true }
    end,
    getKeyCode = function()
        return 126
    end,
}), "Plain Ctrl-Up is left for macOS")
assertTrue(not eventtapCallback({
    getFlags = function()
        return { ctrl = true, alt = true, cmd = true }
    end,
    getKeyCode = function()
        return 36
    end,
}), "Non-arrow Hyper keys pass through")

local function createHeadlessAppTogglerFixture()
    local reopenedCommand = nil
    local activated = false
    local fakeScreen = {}
    local fakeApp = {
        focusedWindow = function()
            return nil
        end,
        mainWindow = function()
            return nil
        end,
        allWindows = function()
            return {}
        end,
        isHidden = function()
            return false
        end,
        isFrontmost = function()
            return false
        end,
        pid = function()
            return 123
        end,
        activate = function()
            activated = true
        end,
    }

    hs = {
        application = {
            get = function(bundleID)
                return bundleID == "com.example.Headless" and fakeApp or nil
            end,
            launchOrFocusByBundleID = function() end,
        },
        execute = function(command)
            reopenedCommand = command
        end,
        fnutils = {
            find = function(items, predicate)
                for _, item in ipairs(items) do
                    if predicate(item) then
                        return item
                    end
                end
                return nil
            end,
        },
        mouse = {
            getCurrentScreen = function()
                return fakeScreen
            end,
        },
        screen = {
            mainScreen = function()
                return fakeScreen
            end,
        },
        timer = {
            doAfter = function() end,
        },
        window = {
            focusedWindow = function()
                return nil
            end,
            list = function()
                return {
                    { pid = 123 },
                }
            end,
        },
    }

    package.loaded["modules.AppToggler"] = nil
    return require("modules.AppToggler"), function()
        return reopenedCommand, activated
    end
end

local appToggler, getHeadlessAppTogglerResult = createHeadlessAppTogglerFixture()
appToggler.toggle("com.example.Headless")
local reopenedCommand, activated = getHeadlessAppTogglerResult()
assertTrue(activated, "headless running app is activated before reopening")
assertEqual(reopenedCommand, "/usr/bin/env -u NO_COLOR /usr/bin/open -b 'com.example.Headless'", "running app with only system windows is reopened without inherited NO_COLOR")

local function createMissingAppLaunchFixture()
    local openedCommand = nil
    local launchOrFocusCalled = false
    local fakeScreen = {}

    hs = {
        application = {
            get = function()
                return nil
            end,
            launchOrFocusByBundleID = function()
                launchOrFocusCalled = true
            end,
        },
        execute = function(command)
            openedCommand = command
        end,
        mouse = {
            getCurrentScreen = function()
                return fakeScreen
            end,
        },
        screen = {
            mainScreen = function()
                return fakeScreen
            end,
        },
        timer = {
            doAfter = function() end,
        },
        window = {
            focusedWindow = function()
                return nil
            end,
        },
    }

    package.loaded["modules.AppToggler"] = nil
    return require("modules.AppToggler"), function()
        return openedCommand, launchOrFocusCalled
    end
end

local missingAppToggler, getMissingAppLaunchResult = createMissingAppLaunchFixture()
missingAppToggler.toggle("net.kovidgoyal.kitty")
local openedCommand, launchOrFocusCalled = getMissingAppLaunchResult()
assertEqual(openedCommand, "/usr/bin/env -u NO_COLOR /usr/bin/open -b 'net.kovidgoyal.kitty'", "missing app launch strips inherited NO_COLOR")
assertTrue(not launchOrFocusCalled, "missing app launch avoids Hammerspoon launchOrFocus inherited environment")

local function createAgentAppAlertFixture()
    local alertMessage = nil
    local fakeScreen = {}
    local fakeApp = {
        focusedWindow = function()
            return nil
        end,
        mainWindow = function()
            return nil
        end,
        allWindows = function()
            return {}
        end,
        isHidden = function()
            return false
        end,
        isFrontmost = function()
            return false
        end,
        activate = function() end,
    }

    hs = {
        alert = {
            show = function(message)
                alertMessage = message
            end,
        },
        application = {
            get = function(bundleID)
                return bundleID == "com.mac.utility.clipboard.paste" and fakeApp or nil
            end,
            launchOrFocusByBundleID = function() end,
        },
        execute = function() end,
        fnutils = {
            find = function(items, predicate)
                for _, item in ipairs(items) do
                    if predicate(item) then
                        return item
                    end
                end
                return nil
            end,
        },
        mouse = {
            getCurrentScreen = function()
                return fakeScreen
            end,
        },
        screen = {
            mainScreen = function()
                return fakeScreen
            end,
        },
        timer = {
            doAfter = function() end,
        },
        window = {
            focusedWindow = function()
                return nil
            end,
        },
    }

    package.loaded["modules.AppToggler"] = nil
    return require("modules.AppToggler"), function()
        return alertMessage
    end
end

local agentAppToggler, getAgentAppAlert = createAgentAppAlertFixture()
agentAppToggler.toggle("com.mac.utility.clipboard.paste")
assertEqual(getAgentAppAlert(), "uPaste", "agent app toggle shows a visible hint")

print("test_hammerspoon_helpers.lua: ok")
