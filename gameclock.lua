---@class GameClock
---Lightweight in-game clock display for MacroQuest
---Shows the current EQ game time in a simple UI window

local mq = require('mq')
local ImGui = require('ImGui')

-- Try to load LuaFileSystem for directory operations
local lfs = nil
pcall(function()
    local PackageMan = require('mq.PackageMan')
    lfs = PackageMan.Require('luafilesystem', 'lfs')
end)

-- Script Info
local SCRIPT_NAME = "GameClock"
local VERSION = "1.1"

-- Settings with defaults
local Settings = {
    showTitleBar = true,
    transparentBg = false,
    bgAlpha = 0.85,
    textColor = { r = 1.0, g = 0.95, b = 0.7, a = 1.0 },
    showDayNight = true,
}

-- UI State
local openClock = true
local showSettings = false
local settingsDirty = false
local lastSaveTime = 0

-- Save/Load settings
local settingsDir = string.format('%s/%s', mq.configDir, SCRIPT_NAME)
local settingsFile = string.format('%s/%s.lua', settingsDir, mq.TLO.Me.CleanName())

local function EnsureDirectory(path)
    if lfs and lfs.attributes then
        -- Use LuaFileSystem if available
        local attr = lfs.attributes(path)
        if not attr then
            -- Try to create parent directories recursively
            local parent = path:match("^(.*)/[^/]+$")
            if parent then
                EnsureDirectory(parent)
            end
            lfs.mkdir(path)
        end
    else
        -- Fallback: try to create directory using io.open test
        -- This won't create dirs but won't freeze/pause either
        -- We'll just fail gracefully if dir doesn't exist
    end
end

local function SaveSettings()
    -- Try to ensure directory exists (non-blocking)
    if lfs then
        pcall(function()
            EnsureDirectory(settingsDir)
        end)
    end

    -- Write settings file
    local file, err = io.open(settingsFile, "w")
    if file then
        file:write("return {")
        file:write(string.format("\n    showTitleBar = %s,", tostring(Settings.showTitleBar)))
        file:write(string.format("\n    transparentBg = %s,", tostring(Settings.transparentBg)))
        file:write(string.format("\n    bgAlpha = %.2f,", Settings.bgAlpha))
        file:write(string.format("\n    textColor = { r = %.2f, g = %.2f, b = %.2f, a = %.2f },",
            Settings.textColor.r, Settings.textColor.g, Settings.textColor.b, Settings.textColor.a))
        file:write(string.format("\n    showDayNight = %s,", tostring(Settings.showDayNight)))
        file:write("\n}\n")
        file:close()
        settingsDirty = false
    else
        -- Silently fail - no popup, no freeze
        -- Settings just won't persist this session
    end
end

-- Queue a save to happen in the background (non-blocking)
local function QueueSave()
    settingsDirty = true
    lastSaveTime = os.clock()
end

local function LoadSettings()
    local file, err = io.open(settingsFile, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local ok, loaded = pcall(loadstring(content))
        if ok and loaded then
            for k, v in pairs(loaded) do
                Settings[k] = v
            end
        end
    end
    -- If file doesn't exist, just use defaults - no error
end

-- Load settings on startup
LoadSettings()

---Format the game time string
---@return string
local function getFormattedGameTime()
    local gameTime = mq.TLO.GameTime()
    if not gameTime then
        return "--:--:--"
    end
    return tostring(gameTime)
end

---Get day/night indicator based on game time
---@return string icon
---@return string label
local function getTimeOfDay()
    local hour = mq.TLO.GameTime.Hour() or 12
    if hour >= 6 and hour < 18 then
        return "☀️", "Daytime"
    else
        return "🌙", "Nighttime"
    end
end

---Get window flags based on settings
---@return integer
local function getWindowFlags()
    local flags = bit32.bor(ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoFocusOnAppearing)
    if not Settings.showTitleBar then
        flags = bit32.bor(flags, ImGuiWindowFlags.NoTitleBar)
    end
    return flags
end

---Render the settings window
local function RenderSettings()
    if not showSettings then return end

    ImGui.SetNextWindowSize(ImVec2(350, 400), ImGuiCond.FirstUseEver)
    showSettings, _ = ImGui.Begin('GameClock Settings', showSettings)

    ImGui.SeparatorText('Window Options')

    -- Title bar toggle
    local showTitle, pressed = ImGui.Checkbox('Show Title Bar', Settings.showTitleBar)
    if pressed then
        Settings.showTitleBar = showTitle
        QueueSave()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Show or hide the window title bar')
    end

    -- Background transparency toggle
    local transparent, pressed = ImGui.Checkbox('Transparent Background', Settings.transparentBg)
    if pressed then
        Settings.transparentBg = transparent
        QueueSave()
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Make the window background fully transparent')
    end

    -- Background alpha slider (only if not fully transparent)
    if not Settings.transparentBg then
        ImGui.PushItemWidth(200)
        local alpha = Settings.bgAlpha
        local newAlpha = ImGui.SliderFloat('Background Opacity', alpha, 0.0, 1.0)
        if newAlpha ~= alpha then
            Settings.bgAlpha = newAlpha
            QueueSave()
        end
        ImGui.PopItemWidth()
    end

    -- Day/night indicator toggle
    local showDayNight, pressed = ImGui.Checkbox('Show Day/Night Indicator', Settings.showDayNight)
    if pressed then
        Settings.showDayNight = showDayNight
        QueueSave()
    end

    ImGui.Separator()
    ImGui.SeparatorText('Text Color')

    -- Text color picker
    local color = Settings.textColor
    local r, g, b, a = color.r, color.g, color.b, color.a
    local nr, ng, nb, na, changed = ImGui.ColorEdit4('Clock Text Color', r, g, b, a,
        bit32.bor(ImGuiColorEditFlags.NoInputs, ImGuiColorEditFlags.NoLabel))
    if changed then
        Settings.textColor.r = math.max(0, math.min(1, nr))
        Settings.textColor.g = math.max(0, math.min(1, ng))
        Settings.textColor.b = math.max(0, math.min(1, nb))
        Settings.textColor.a = math.max(0, math.min(1, na))
        QueueSave()
    end
    ImGui.SameLine()
    ImGui.Text('Clock Text Color')

    -- Preset colors
    ImGui.Text('Presets:')
    local presets = {
        { name = 'Default', r = 1.0, g = 0.95, b = 0.7 },
        { name = 'White', r = 1.0, g = 1.0, b = 1.0 },
        { name = 'Gold', r = 1.0, g = 0.84, b = 0.0 },
        { name = 'Cyan', r = 0.0, g = 1.0, b = 1.0 },
        { name = 'Green', r = 0.0, g = 1.0, b = 0.0 },
        { name = 'Red', r = 1.0, g = 0.0, b = 0.0 },
        { name = 'Magenta', r = 1.0, g = 0.0, b = 1.0 },
    }

    for i, preset in ipairs(presets) do
        if i > 1 then ImGui.SameLine() end
        if ImGui.ColorButton(preset.name, ImVec4(preset.r, preset.g, preset.b, 1.0), 0, ImVec2(40, 20)) then
            Settings.textColor.r = preset.r
            Settings.textColor.g = preset.g
            Settings.textColor.b = preset.b
            QueueSave()
        end
    end

    ImGui.Separator()

    if ImGui.Button('Reset to Defaults', ImVec2(150, 25)) then
        Settings.showTitleBar = true
        Settings.transparentBg = false
        Settings.bgAlpha = 0.85
        Settings.textColor = { r = 1.0, g = 0.95, b = 0.7, a = 1.0 }
        Settings.showDayNight = true
        QueueSave()
    end

    ImGui.End()
end

---Main render function
local function RenderGUI()
    if not openClock then return end

    -- Skip rendering if at character select
    if mq.TLO.MacroQuest.GameState() == "CHARSELECT" then
        return
    end

    -- Set background alpha
    local bgAlpha = Settings.transparentBg and 0.0 or Settings.bgAlpha
    ImGui.SetNextWindowBgAlpha(bgAlpha)
    ImGui.SetNextWindowSize(ImVec2(180, 80), ImGuiCond.FirstUseEver)

    local windowFlags = getWindowFlags()
    openClock = ImGui.Begin('Game Clock##GameClock', openClock, windowFlags)

    -- Context menu for right-click on title bar or window
    if ImGui.BeginPopupContextWindow('##GameClockContext') then
        if ImGui.MenuItem(Settings.showTitleBar and "Hide Title Bar" or "Show Title Bar") then
            Settings.showTitleBar = not Settings.showTitleBar
            QueueSave()
        end
        if ImGui.MenuItem('Settings...') then
            showSettings = true
        end
        ImGui.Separator()
        if ImGui.MenuItem(Settings.transparentBg and "Opaque Background" or "Transparent Background") then
            Settings.transparentBg = not Settings.transparentBg
            QueueSave()
        end
        if ImGui.MenuItem(Settings.showDayNight and "Hide Day/Night" or "Show Day/Night") then
            Settings.showDayNight = not Settings.showDayNight
            QueueSave()
        end
        ImGui.Separator()
        if ImGui.MenuItem('Hide Clock') then
            openClock = false
        end
        ImGui.EndPopup()
    end

    local timeStr = getFormattedGameTime()
    local icon, label = getTimeOfDay()

    -- Center the time display
    local textSize = ImGui.CalcTextSize(timeStr)
    local availWidth = ImGui.GetContentRegionAvail()
    local cursorX = ImGui.GetCursorPosX()
    ImGui.SetCursorPosX(cursorX + (availWidth - textSize) * 0.5)

    -- Draw the game time with custom color
    local color = Settings.textColor
    ImGui.PushStyleColor(ImGuiCol.Text, ImVec4(color.r, color.g, color.b, color.a))
    ImGui.Text(timeStr)
    ImGui.PopStyleColor()

    -- Day/night indicator
    if Settings.showDayNight then
        ImGui.Spacing()
        local indicatorText = string.format('%s %s', icon, label)
        textSize = ImGui.CalcTextSize(indicatorText)
        availWidth = ImGui.GetContentRegionAvail()
        cursorX = ImGui.GetCursorPosX()
        ImGui.SetCursorPosX(cursorX + (availWidth - textSize) * 0.5)

        local indicatorColor = label == "Daytime" and ImVec4(1.0, 0.85, 0.3, 1.0) or ImVec4(0.6, 0.7, 1.0, 1.0)
        ImGui.TextColored(indicatorColor, indicatorText)
    end

    ImGui.End()

    -- Render settings window if open
    RenderSettings()
end

-- Initialize the GUI
mq.imgui.init(SCRIPT_NAME, RenderGUI)

-- Command bindings
mq.bind("/gameclock", function(cmd, ...)
    local args = {...}
    if cmd == "hide" or cmd == "off" then
        openClock = false
    elseif cmd == "show" or cmd == "on" then
        openClock = true
    elseif cmd == "toggle" then
        openClock = not openClock
    elseif cmd == "settings" then
        showSettings = not showSettings
    elseif cmd == "titlebar" then
        Settings.showTitleBar = not Settings.showTitleBar
        QueueSave()
        printf("\ay[GameClock]\ax Title bar: %s", Settings.showTitleBar and "ON" or "OFF")
    elseif cmd == "transparent" then
        Settings.transparentBg = not Settings.transparentBg
        QueueSave()
        printf("\ay[GameClock]\ax Transparent background: %s", Settings.transparentBg and "ON" or "OFF")
    elseif cmd == "alpha" then
        local alpha = tonumber(args[1])
        if alpha then
            Settings.bgAlpha = math.max(0, math.min(1, alpha))
            QueueSave()
            printf("\ay[GameClock]\ax Background alpha set to: %.2f", Settings.bgAlpha)
        else
            printf("\ay[GameClock]\ax Usage: /gameclock alpha 0.5 (0.0 to 1.0)")
        end
    elseif cmd == "color" then
        -- Quick color presets
        local colorName = args[1] and args[1]:lower() or ""
        local presets = {
            default = { r = 1.0, g = 0.95, b = 0.7 },
            white = { r = 1.0, g = 1.0, b = 1.0 },
            gold = { r = 1.0, g = 0.84, b = 0.0 },
            yellow = { r = 1.0, g = 1.0, b = 0.0 },
            cyan = { r = 0.0, g = 1.0, b = 1.0 },
            green = { r = 0.0, g = 1.0, b = 0.0 },
            red = { r = 1.0, g = 0.0, b = 0.0 },
            magenta = { r = 1.0, g = 0.0, b = 1.0 },
            orange = { r = 1.0, g = 0.5, b = 0.0 },
            pink = { r = 1.0, g = 0.4, b = 0.7 },
        }
        if presets[colorName] then
            Settings.textColor.r = presets[colorName].r
            Settings.textColor.g = presets[colorName].g
            Settings.textColor.b = presets[colorName].b
            QueueSave()
            printf("\ay[GameClock]\ax Text color set to: %s", colorName)
        else
            printf("\ay[GameClock]\ax Available colors: default, white, gold, yellow, cyan, green, red, magenta, orange, pink")
        end
    elseif cmd == "daynight" then
        Settings.showDayNight = not Settings.showDayNight
        QueueSave()
        printf("\ay[GameClock]\ax Day/Night indicator: %s", Settings.showDayNight and "ON" or "OFF")
    elseif cmd == "reset" then
        Settings.showTitleBar = true
        Settings.transparentBg = false
        Settings.bgAlpha = 0.85
        Settings.textColor = { r = 1.0, g = 0.95, b = 0.7, a = 1.0 }
        Settings.showDayNight = true
        QueueSave()
        printf("\ay[GameClock]\ax Settings reset to defaults")
    else
        printf("\ay[GameClock v%s]\ax Commands:", VERSION)
        printf("  \ay/gameclock hide|show|toggle\ax - Control window visibility")
        printf("  \ay/gameclock settings\ax - Open settings window")
        printf("  \ay/gameclock titlebar\ax - Toggle title bar")
        printf("  \ay/gameclock transparent\ax - Toggle transparent background")
        printf("  \ay/gameclock alpha <0.0-1.0>\ax - Set background opacity")
        printf("  \ay/gameclock color <name>\ax - Set text color (default, white, gold, cyan, green, red, etc.)")
        printf("  \ay/gameclock daynight\ax - Toggle day/night indicator")
        printf("  \ay/gameclock reset\ax - Reset all settings to defaults")
        printf("\ayRight-click the clock for more options!\ax")
    end
end)

-- Print startup message
printf("\ag[%s v%s]\ax Loaded! Use /gameclock for help.", SCRIPT_NAME, VERSION)
printf("\ayRight-click the clock for settings!\ax")

-- Main loop - keep script running while window is open
-- Save settings in the background when dirty
while true do
    mq.delay(100)
    
    -- Save settings in background (non-blocking)
    if settingsDirty and (os.clock() - lastSaveTime) > 0.5 then
        SaveSettings()
    end
    
    if not openClock and not showSettings then
        -- Final save before exit
        if settingsDirty then
            SaveSettings()
        end
        break
    end
end
