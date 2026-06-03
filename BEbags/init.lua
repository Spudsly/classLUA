
local mq = require('mq')
local ImGui = require('ImGui')

-- BEbags.lua
-- Inventory + bank snapshot browser for AscendantEQ / MacroQuest.

local SCRIPT_NAME = 'BEbags'
local FIRST_BAG_SLOT = 23
local LAST_BAG_SLOT = 32
local FIRST_BANK_SLOT = 2000
local LAST_BANK_SLOT = 2023
local EQ_ICON_OFFSET = 500

local animItems = mq.FindTextureAnimation('A_DragItem')
local animBox = mq.FindTextureAnimation('A_RecessedBox')

local baseConfigDir = (mq.configDir or '.')
local bebagsConfigDir = baseConfigDir .. '/BEbags'
local configPath = bebagsConfigDir .. '/BEbags_settings.lua'
local bankCachePath = bebagsConfigDir .. '/BEbags_bank_cache.lua'

local state = {
    running = true,
    mode = 'packed',
    hideEmptyInFull = false,
    rightClickEnabled = true,
    slotSize = 40,
    columns = 14,
    showBagInfo = false,
    showItemBackground = true,
    sortMode = 'bag',
    showValueGlow = true,
    showConfigWindow = false,
    autoResizeMain = true,
    mainNoScrollbar = true,
    mainNoTitleBar = false,
    showMainValueBar = true,
    showMainWindow = true,
    widthFudge = 56,
    heightFudge = 20,
    lastError = '',
    statusMessage = 'Ready.',
    showLauncher = true,
    showQuickHelp = false,
    pendingSell = nil,
    pendingSellQueue = nil,
    pendingSellQueueReadyAt = 0,
    showHelpDialog = false,
    activeView = 'inventory', -- inventory | bank
    bankCache = {
        entries = {},
        syncedAt = nil,
        character = nil,
        server = nil,
    },
    bankWasOpen = false,
    bankAutoSyncEnabled = true,
    bankLastSignature = nil,
    showBankSyncButton = false,
    showBankStatusText = false,
    depositMode = false,
    leftClickDelay = 0.24,
    pendingLeftClick = nil,
    diabloTheme = true,
    themePreset = 'Diablo',
    doNotSellItems = {},
    mainWindowHotkey = '',
    capturingHotkey = false,
    lowBagSpaceGreenPercent = 25,
    lowBagSpaceYellowPercent = 15,
    lowBagSpaceRedPercent = 8,
    showBagSpaceOverlay = true,
    bagSpaceOverlaySize = 'Medium',
    bagSpaceOverlayStyle = 'Bold',
    bagSpaceOverlayPosition = 'Center',
    bagSpaceOverlayOutline = 'Heavy',
    bagSpaceOverlayOffsetX = 0,
    bagSpaceOverlayOffsetY = 0,
}

local mainWindowHotkeyInput = ''
local lowBagSpaceGreenPercentInput = ''
local lowBagSpaceYellowPercentInput = ''
local lowBagSpaceRedPercentInput = ''

local headerFont = nil
local headerFontLoaded = false

local buildInventoryEntries
local sortEntries
local tryLoadHeaderFont


local function clampPercent(v)
    return math.max(0, math.min(100, math.floor(tonumber(v) or 0)))
end

local function normalizeLowBagSpaceThresholds()
    local green = clampPercent(state.lowBagSpaceGreenPercent or 25)
    local yellow = clampPercent(state.lowBagSpaceYellowPercent or 15)
    local red = clampPercent(state.lowBagSpaceRedPercent or 8)

    if yellow > green then yellow = green end
    if red > yellow then red = yellow end

    state.lowBagSpaceGreenPercent = green
    state.lowBagSpaceYellowPercent = yellow
    state.lowBagSpaceRedPercent = red

    lowBagSpaceGreenPercentInput = tostring(green)
    lowBagSpaceYellowPercentInput = tostring(yellow)
    lowBagSpaceRedPercentInput = tostring(red)
end


local function echo(msg)
    mq.cmdf('/echo [%s] %s', SCRIPT_NAME, tostring(msg))
end

local function safeCall(fn, fallback)
    local ok, result = pcall(fn)
    if ok then return result end
    return fallback
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local nextIndent = indent .. '  '
        local parts = {'{\n'}
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' and k:match('^[_%a][_%w]*$') then
                key = k
            else
                key = '[' .. serializeValue(k, nextIndent) .. ']'
            end
            parts[#parts + 1] = string.format('%s%s = %s,\n', nextIndent, key, serializeValue(val, nextIndent))
        end
        parts[#parts + 1] = indent .. '}'
        return table.concat(parts)
    end
    return 'nil'
end

local function saveSettings()
    local keys = {
        'mode', 'hideEmptyInFull', 'rightClickEnabled', 'slotSize', 'columns',
        'showBagInfo', 'showItemBackground', 'sortMode', 'showValueGlow',
        'showConfigWindow', 'autoResizeMain', 'mainNoScrollbar',
        'mainNoTitleBar', 'showMainValueBar', 'showMainWindow', 'showLauncher',
        'showHelpDialog', 'widthFudge', 'heightFudge', 'activeView',
        'showBankSyncButton', 'showBankStatusText', 'depositMode', 'leftClickDelay',
        'diabloTheme', 'themePreset', 'doNotSellItems', 'mainWindowHotkey',
        'lowBagSpaceGreenPercent', 'lowBagSpaceYellowPercent', 'lowBagSpaceRedPercent',
        'showSellAllButton', 'showBagSpaceOverlay', 'bagSpaceOverlaySize',
        'bagSpaceOverlayStyle', 'bagSpaceOverlayPosition', 'bagSpaceOverlayOutline',
        'bagSpaceOverlayOffsetX', 'bagSpaceOverlayOffsetY',
    }

    local data = {}
    for _, key in ipairs(keys) do
        data[key] = state[key]
    end

    local ok, err = pcall(function()
        mq.pickle(configPath, data)
    end)

    if not ok then
        echo('Failed to save settings: ' .. tostring(err))
        return false
    end
    return true
end

local function loadSettings()
    local chunk = loadfile(configPath)
    if not chunk then return false end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= 'table' then return false end
    for k, v in pairs(cfg) do
        if state[k] ~= nil then state[k] = v end
    end
    state.slotSize = math.max(24, math.min(56, math.floor(tonumber(state.slotSize) or 40)))
    state.columns = math.max(4, math.min(24, math.floor(tonumber(state.columns) or 14)))
    state.widthFudge = math.max(0, math.min(200, math.floor(tonumber(state.widthFudge) or 56)))
    state.heightFudge = math.max(0, math.min(120, math.floor(tonumber(state.heightFudge) or 20)))
    if state.activeView ~= 'inventory' and state.activeView ~= 'bank' then
        state.activeView = 'inventory'
    end
    if type(state.themePreset) ~= 'string' or state.themePreset == '' then
        state.themePreset = state.diabloTheme and 'Diablo' or 'Classic'
    end
    local validThemes = {
        Classic = true,
        Diablo = true,
        Emerald = true,
        Frost = true,
    }
    if not validThemes[state.themePreset] then
        state.themePreset = 'Diablo'
    end
    state.diabloTheme = state.themePreset ~= 'Classic'
    state.showBankSyncButton = false
    state.showBankStatusText = false
    state.mainWindowHotkey = tostring(state.mainWindowHotkey or '')
    state.capturingHotkey = false
    state.showSellAllButton = state.showSellAllButton ~= false
    if state.showBagSpaceOverlay == nil then
        state.showBagSpaceOverlay = false
    end
    state.bagSpaceOverlaySize = tostring(state.bagSpaceOverlaySize or 'Medium')
    state.bagSpaceOverlayStyle = tostring(state.bagSpaceOverlayStyle or 'Bold')
    state.bagSpaceOverlayPosition = tostring(state.bagSpaceOverlayPosition or 'Center')
    state.bagSpaceOverlayOutline = tostring(state.bagSpaceOverlayOutline or 'Heavy')
    state.bagSpaceOverlayOffsetX = math.max(-20, math.min(20, math.floor(tonumber(state.bagSpaceOverlayOffsetX) or 0)))
    state.bagSpaceOverlayOffsetY = math.max(-20, math.min(20, math.floor(tonumber(state.bagSpaceOverlayOffsetY) or 0)))
    mainWindowHotkeyInput = state.mainWindowHotkey
    normalizeLowBagSpaceThresholds()
    return true
end

local function saveBankCache()
    local ok, err = pcall(function()
        mq.pickle(bankCachePath, state.bankCache)
    end)

    if not ok then
        echo('Failed to save bank cache: ' .. tostring(err))
        return false
    end
    return true
end

local function loadBankCache()
    local chunk = loadfile(bankCachePath)
    if not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' then return false end
    if type(data.entries) ~= 'table' then
        data.entries = {}
    end

    local currentCharacter = safeCall(function()
        local n = mq.TLO.Me.CleanName()
        if n == nil or n == '' then n = mq.TLO.Me.Name() end
        return tostring(n or '')
    end, '') or ''

    local currentServer = safeCall(function()
        local n = mq.TLO.EverQuest.Server()
        return tostring(n or '')
    end, '') or ''

    local cacheCharacter = tostring(data.character or '')
    local cacheServer = tostring(data.server or '')

    if cacheCharacter ~= '' and cacheServer ~= '' then
        if cacheCharacter ~= currentCharacter or cacheServer ~= currentServer then
            state.bankCache = {
                entries = {},
                syncedAt = nil,
                character = currentCharacter,
                server = currentServer,
            }
            state.bankLastSignature = nil
            return false
        end
    end


    state.bankCache = data
    return true
end

local function normalizeHotkeyCombo(raw)
    local s = tostring(raw or ''):lower()
    s = s:gsub('%s+', '')
    s = s:gsub('%-', '+')
    s = s:gsub('control%+', 'ctrl+')
    s = s:gsub('option%+', 'alt+')
    s = s:gsub('command%+', 'ctrl+')
    s = s:gsub('^%++', '')
    s = s:gsub('%++$', '')
    if s == '' then return '' end

    local seen = {}
    local parts = {}
    local key = nil
    for token in s:gmatch('[^+]+') do
        if token == 'ctrl' or token == 'shift' or token == 'alt' then
            if not seen[token] then
                seen[token] = true
                parts[#parts + 1] = token
            end
        elseif token ~= '' then
            key = token
        end
    end

    if not key or key == '' then
        return ''
    end

    local ordered = {}
    if seen.ctrl then ordered[#ordered + 1] = 'ctrl' end
    if seen.shift then ordered[#ordered + 1] = 'shift' end
    if seen.alt then ordered[#ordered + 1] = 'alt' end
    ordered[#ordered + 1] = key
    return table.concat(ordered, '+')
end


local function formatHotkeyLabel(combo)
    local s = normalizeHotkeyCombo(combo)
    if s == '' then return 'None' end
    local pretty = {}
    for token in s:gmatch('[^+]+') do
        if token == 'ctrl' then
            pretty[#pretty + 1] = 'Ctrl'
        elseif token == 'shift' then
            pretty[#pretty + 1] = 'Shift'
        elseif token == 'alt' then
            pretty[#pretty + 1] = 'Alt'
        elseif token:match('^f%d+$') then
            pretty[#pretty + 1] = token:upper()
        elseif #token == 1 then
            pretty[#pretty + 1] = token:upper()
        else
            pretty[#pretty + 1] = token:gsub('^%l', string.upper)
        end
    end
    return table.concat(pretty, '+')
end

local function safeIsKeyDown(key)
    return safeCall(function() return ImGui.IsKeyDown(key) end, false) or false
end

local function safeIsKeyPressed(key)
    return safeCall(function() return ImGui.IsKeyPressed(key) end, false)
        or safeCall(function() return ImGui.IsKeyPressed(key, false) end, false)
        or false
end

local function getCapturedHotkeyCombo()
    local ctrlDown = safeIsKeyDown(ImGuiKey.LeftCtrl) or safeIsKeyDown(ImGuiKey.RightCtrl)
    local shiftDown = safeIsKeyDown(ImGuiKey.LeftShift) or safeIsKeyDown(ImGuiKey.RightShift)
    local altDown = safeIsKeyDown(ImGuiKey.LeftAlt) or safeIsKeyDown(ImGuiKey.RightAlt)

    if safeIsKeyPressed(ImGuiKey.Escape) then
        return '__cancel__'
    end

    local captureKeys = {
        { ImGuiKey.Tab, 'tab' },
        { ImGuiKey.Space, 'space' },
        { ImGuiKey.Insert, 'insert' },
        { ImGuiKey.Delete, 'delete' },
        { ImGuiKey.Home, 'home' },
        { ImGuiKey.End, 'end' },
        { ImGuiKey.PageUp, 'pageup' },
        { ImGuiKey.PageDown, 'pagedown' },
        { ImGuiKey.UpArrow, 'up' },
        { ImGuiKey.DownArrow, 'down' },
        { ImGuiKey.LeftArrow, 'left' },
        { ImGuiKey.RightArrow, 'right' },
    }

    for i = 1, 12 do
        local keyEnum = ImGuiKey['F' .. tostring(i)]
        if keyEnum then
            captureKeys[#captureKeys + 1] = { keyEnum, 'f' .. tostring(i) }
        end
    end

    for c = string.byte('A'), string.byte('Z') do
        local name = string.char(c)
        local keyEnum = ImGuiKey[name]
        if keyEnum then
            captureKeys[#captureKeys + 1] = { keyEnum, name:lower() }
        end
    end

    for i = 0, 9 do
        local keyName = tostring(i)
        local keyEnum = ImGuiKey[keyName]
        if keyEnum then
            captureKeys[#captureKeys + 1] = { keyEnum, keyName }
        end
    end

    for _, entry in ipairs(captureKeys) do
        if safeIsKeyPressed(entry[1]) then
            local keyName = entry[2]
            if keyName == 'delete' and not ctrlDown and not shiftDown and not altDown then
                return '__clear__'
            end

            local parts = {}
            if ctrlDown then parts[#parts + 1] = 'ctrl' end
            if shiftDown then parts[#parts + 1] = 'shift' end
            if altDown then parts[#parts + 1] = 'alt' end
            parts[#parts + 1] = keyName
            return table.concat(parts, '+')
        end
    end

    return nil
end

local function applyMainWindowHotkey(newCombo, quiet)
    local bindName = 'bebagsmain'
    local normalized = normalizeHotkeyCombo(newCombo)

    mq.cmdf('/bind %s clear', bindName)
    mq.cmdf('/bind ~%s clear', bindName)
    mq.cmdf('/custombind delete %s', bindName)

    state.mainWindowHotkey = normalized
    mainWindowHotkeyInput = normalized

    if normalized ~= '' then
        mq.cmdf('/custombind add %s', bindName)
        mq.cmdf('/custombind set %s /BEbags toggle', bindName)
        mq.cmdf('/bind %s %s', bindName, normalized)
    end

    saveSettings()

    if not quiet then
        if normalized ~= '' then
            echo('Main window hotkey set to ' .. normalized .. '.')
        else
            echo('Main window hotkey cleared.')
        end
    end

    return normalized ~= ''
end

local function resetSettings()
    state.mode = 'packed'
    state.hideEmptyInFull = false
    state.rightClickEnabled = true
    state.slotSize = 40
    state.columns = 14
    state.showBagInfo = false
    state.showItemBackground = true
    state.sortMode = 'bag'
    state.showValueGlow = true
    state.showConfigWindow = false
    state.autoResizeMain = true
    state.mainNoScrollbar = true
    state.mainNoTitleBar = false
    state.showMainValueBar = true
    state.showMainWindow = true
    state.showLauncher = true
    state.showHelpDialog = false
    state.widthFudge = 56
    state.heightFudge = 20
    state.activeView = 'inventory'
    state.showBankSyncButton = false
    state.showBankStatusText = false
    state.depositMode = false
    state.leftClickDelay = 0.24
    state.pendingLeftClick = nil
    state.diabloTheme = true
    state.themePreset = 'Diablo'
    state.doNotSellItems = {}
    state.mainWindowHotkey = ''
    state.capturingHotkey = false
    mainWindowHotkeyInput = ''
    saveSettings()
    echo('Settings reset to defaults.')
end

local function getBankBag(slot)
    local invslot = mq.TLO.InvSlot(slot)
    if not invslot then return nil end
    local item = safeCall(function() return invslot.Item end, nil)
    if not item then return nil end
    if safeCall(function() return item() end, nil) == nil then return nil end
    return item
end

local function getBag(slot)
    if slot >= FIRST_BANK_SLOT and slot <= LAST_BANK_SLOT then
        return getBankBag(slot)
    end

    local inv = mq.TLO.Me.Inventory(slot)
    if not inv then return nil end
    if safeCall(function() return inv() end, nil) == nil then return nil end
    return inv
end

local function getInventoryBagName(slot)
    local bag = getBag(slot)
    if not bag then return string.format('Bag %d', slot - 22) end
    return safeCall(function()
        local n = bag.Name()
        if n == nil or n == '' then return string.format('Bag %d', slot - 22) end
        return tostring(n)
    end, string.format('Bag %d', slot - 22))
end

local function getBagSlotCount(slot)
    local bag = getBag(slot)
    if not bag then return 0 end
    return safeCall(function() return tonumber(bag.Container()) or 0 end, 0)
end

local function getBagItem(slot, subslot)
    local bag = getBag(slot)
    if not bag then return nil end
    local item = safeCall(function() return bag.Item(subslot) end, nil)
    if not item then return nil end
    if safeCall(function() return item() end, nil) == nil then return nil end
    return item
end

local function getCursorItem()
    local item = mq.TLO.Cursor
    if not item then return nil end
    if safeCall(function() return item() end, nil) == nil then return nil end
    return item
end

local function getCursorName()
    local item = getCursorItem()
    if not item then return nil end
    return safeCall(function()
        local n = item.Name()
        if n == nil or n == '' or tostring(n) == 'NULL' then return nil end
        return tostring(n)
    end, nil)
end

local function hasCursorItem()
    return getCursorName() ~= nil
end

local function shouldIncludeEmptySlots()
    if state.depositMode then
        return true
    end
    return state.mode ~= 'packed'
end

local function getItemIcon(item)
    if not item then return 0 end
    return safeCall(function() return tonumber(item.Icon()) or 0 end, 0)
end

local function getItemStack(item)
    if not item then return 0 end
    return safeCall(function() return tonumber(item.Stack()) or 0 end, 0)
end

local function getItemStackSize(item)
    if not item then return 0 end
    return safeCall(function() return tonumber(item.StackSize()) or 0 end, 0)
end

local function isItemStackable(item)
    if not item then return false end
    return safeCall(function() return item.Stackable() end, false) and true or false
end

local function getItemID(item)
    if not item then return 0 end
    return safeCall(function() return tonumber(item.ID()) or 0 end, 0)
end

local function getItemValue(item)
    if not item then return 0 end
    return safeCall(function() return tonumber(item.Value()) or 0 end, 0)
end

local function getItemName(item, fallback)
    if not item then return fallback or '(empty)' end
    return safeCall(function()
        local n = item.Name()
        if n == nil or n == '' then return fallback or '(empty)' end
        return tostring(n)
    end, fallback or '(empty)')
end


local function getDoNotSellKeyFromItem(item)
    if not item then return nil end
    local itemID = getItemID(item)
    if itemID and itemID > 0 then
        return string.format('id:%d', itemID)
    end
    local itemName = string.lower(getItemName(item, '') or '')
    if itemName ~= '' then
        return 'name:' .. itemName
    end
    return nil
end

local function getDoNotSellKeyFromEntry(entry)
    if not entry or entry.isEmpty then return nil end
    if entry.doNotSellKey and entry.doNotSellKey ~= '' then
        return entry.doNotSellKey
    end
    if entry.item then
        return getDoNotSellKeyFromItem(entry.item)
    end
    local itemID = tonumber(entry.itemID or 0) or 0
    if itemID > 0 then
        return string.format('id:%d', itemID)
    end
    local itemName = string.lower(tostring(entry.itemName or ''))
    if itemName ~= '' and itemName ~= '(empty)' then
        return 'name:' .. itemName
    end
    return nil
end

local function isDoNotSellEntry(entry)
    local key = getDoNotSellKeyFromEntry(entry)
    return key ~= nil and state.doNotSellItems and state.doNotSellItems[key] == true
end

local function toggleDoNotSellEntry(entry)
    local key = getDoNotSellKeyFromEntry(entry)
    if not key then
        echo('Unable to flag that item.')
        return false
    end
    state.doNotSellItems = state.doNotSellItems or {}
    local newValue = not state.doNotSellItems[key]
    state.doNotSellItems[key] = newValue or nil
    entry.doNotSell = newValue
    entry.doNotSellKey = key
    saveSettings()
    echo(string.format('%s %s for Do Not Sell.', newValue and 'Flagged' or 'Removed', entry.itemName or 'item'))
    return true
end

local function getLauncherBagItem()
    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local bag = getBag(bagSlot)
        if bag and safeCall(function() return bag() end, nil) ~= nil then
            return bag
        end
    end
    return nil
end

local function getLauncherIconID()
    local bag = getLauncherBagItem()
    if not bag then return 0 end
    return safeCall(function() return tonumber(bag.Icon()) or 0 end, 0)
end

local function itemnotifyLeft(packNum, subslot)
    mq.cmdf('/itemnotify in pack%d %d leftmouseup', packNum, subslot)
end

local function itemnotifyRight(packNum, subslot)
    mq.cmdf('/itemnotify in pack%d %d rightmouseup', packNum, subslot)
end

local function inspectItem(item)
    if not item then return end
    safeCall(function() item.Inspect() end, nil)
end

local function bankItemnotifyLeft(bankNum, subslot)
    mq.cmdf('/itemnotify in bank%d %d leftmouseup', bankNum, subslot)
end

local function bankItemnotifyRight(bankNum, subslot)
    mq.cmdf('/itemnotify in bank%d %d rightmouseup', bankNum, subslot)
end

local function selectItemForMerchantSell(packNum, subslot)
    mq.cmdf('/nomodkey /itemnotify in pack%d %d leftmouseup', packNum, subslot)
end

local function sellSelectedMerchantItem(quantity)
    quantity = tonumber(quantity) or 1
    if quantity < 1 then quantity = 1 end
    mq.cmdf('/sellitem %d', quantity)
end

local function merchantWindowOpen()
    return safeCall(function()
        return mq.TLO.Window('MerchantWnd').Open()
    end, false) or false
end

local function bankWindowOpen()
    return (safeCall(function() return mq.TLO.Window('BigBankWnd').Open() end, false) or false)
        or (safeCall(function() return mq.TLO.Window('BankWnd').Open() end, false) or false)
end


local function queueMerchantSell(packNum, subslot, itemName, stackSize)
    if not merchantWindowOpen() then
        echo('Merchant window is not open.')
        return false
    end
    selectItemForMerchantSell(packNum, subslot)
    state.pendingSell = {
        packNum = packNum,
        subslot = subslot,
        itemName = itemName or '',
        stackSize = tonumber(stackSize) or 1,
        readyAt = os.clock() + 0.12,
    }
    echo(string.format('Queued vendor sell for %s x%d.', (itemName or 'item'), tonumber(stackSize) or 1))
    return true
end

local function startNextQueuedSell()
    if state.pendingSell then
        return false
    end
    if not state.pendingSellQueue or #state.pendingSellQueue == 0 then
        state.pendingSellQueue = nil
        state.pendingSellQueueReadyAt = 0
        return false
    end
    if not merchantWindowOpen() then
        echo('Merchant window is not open.')
        state.pendingSellQueue = nil
        state.pendingSellQueueReadyAt = 0
        return false
    end

    local nextSell = table.remove(state.pendingSellQueue, 1)
    if not nextSell then
        state.pendingSellQueue = nil
        state.pendingSellQueueReadyAt = 0
        return false
    end

    selectItemForMerchantSell(nextSell.packNum, nextSell.subslot)
    state.pendingSell = {
        packNum = nextSell.packNum,
        subslot = nextSell.subslot,
        itemName = nextSell.itemName or '',
        stackSize = tonumber(nextSell.stackSize) or 1,
        readyAt = os.clock() + 0.18,
    }
    state.pendingSellQueueReadyAt = 0
    return true
end

local function bulkSellByValue(minValue)
    local function quickFormatMoney(copper)
        copper = math.max(tonumber(copper) or 0, 0)
        local pp = math.floor(copper / 1000)
        local gp = math.floor((copper % 1000) / 100)
        local sp = math.floor((copper % 100) / 10)
        local cp = copper % 10
        return string.format('%dpp %dgp %dsp %dcp', pp, gp, sp, cp)
    end

    minValue = tonumber(minValue) or 0
    if minValue < 1 then minValue = 1 end

    if not merchantWindowOpen() then
        echo('You must have a merchant open to bulk sell.')
        return false
    end

    local entries = buildInventoryEntries()
    sortEntries(entries)

    local queue = {}
    local count = 0
    local totalValue = 0

    for _, entry in ipairs(entries) do
        if not entry.isEmpty then
            local totalItemValue = tonumber(entry.totalValue) or 0
            local isProtected = entry.doNotSell == true

            if not isProtected and totalItemValue >= minValue then
                queue[#queue + 1] = {
                    packNum = entry.packNum,
                    subslot = entry.subslot,
                    itemName = entry.itemName,
                    stackSize = tonumber(entry.stack) or 1,
                }
                count = count + 1
                totalValue = totalValue + totalItemValue
            end
        end
    end

    if count == 0 then
        echo(string.format('No eligible items worth %s or more were found.', quickFormatMoney(minValue)))
        return false
    end

    state.pendingSellQueue = queue
    state.pendingSellQueueReadyAt = 0
    echo(string.format(
        'Bulk sell queued: %d items worth %s or more (%s total), using current sort order.',
        count,
        quickFormatMoney(minValue),
        quickFormatMoney(totalValue)
    ))
    startNextQueuedSell()
    return true
end

local function formatMoney(cp)
    cp = tonumber(cp) or 0
    if cp < 0 then cp = 0 end
    local pp = math.floor(cp / 1000)
    local rem = cp % 1000
    local gp = math.floor(rem / 100)
    rem = rem % 100
    local sp = math.floor(rem / 10)
    local c = rem % 10
    return string.format('%dpp %dgp %dsp %dcp', pp, gp, sp, c)
end

local function getCharacterName()
    return safeCall(function()
        local n = mq.TLO.Me.CleanName()
        if n == nil or n == '' then n = mq.TLO.Me.Name() end
        return tostring(n or '')
    end, '')
end

local function getServerName()
    return safeCall(function()
        local n = mq.TLO.EverQuest.Server()
        return tostring(n or '')
    end, '')
end

local function getBankBagName(slotID)
    local bankNum = slotID - FIRST_BANK_SLOT + 1
    local bag = getBag(slotID)
    if not bag then return string.format('Bank %d', bankNum) end
    return safeCall(function()
        local n = bag.Name()
        if n == nil or n == '' then return string.format('Bank %d', bankNum) end
        return tostring(n)
    end, string.format('Bank %d', bankNum))
end

function buildInventoryEntries()
    local out = {}
    local order = 0
    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local bagName = getInventoryBagName(bagSlot)
        local slotCount = getBagSlotCount(bagSlot)
        local packNum = bagSlot - 22
        for subslot = 1, slotCount do
            order = order + 1
            local item = getBagItem(bagSlot, subslot)
            local isEmpty = (item == nil)
            local include = false
            if shouldIncludeEmptySlots() then
                include = not (state.hideEmptyInFull and isEmpty)
            else
                include = not isEmpty
            end
            if include then
                local stack = math.max(getItemStack(item), 1)
                local itemValue = getItemValue(item)
                local itemID = getItemID(item)
                local doNotSellKey = getDoNotSellKeyFromItem(item)
                out[#out + 1] = {
                    source = 'inventory',
                    interactive = true,
                    packNum = packNum,
                    subslot = subslot,
                    bagName = bagName,
                    item = item,
                    isEmpty = isEmpty,
                    order = order,
                    itemName = getItemName(item, '(empty)'),
                    stack = stack,
                    itemID = itemID,
                    doNotSellKey = doNotSellKey,
                    doNotSell = doNotSellKey ~= nil and state.doNotSellItems[doNotSellKey] == true or false,
                    itemValue = itemValue,
                    totalValue = itemValue * stack,
                    iconID = getItemIcon(item),
                }
            end
        end
    end
    return out
end

local function buildLiveBankEntries()
    local out = {}
    local order = 0
    for slotID = FIRST_BANK_SLOT, LAST_BANK_SLOT do
        local bankNum = slotID - FIRST_BANK_SLOT + 1
        local bagName = getBankBagName(slotID)
        local slotCount = getBagSlotCount(slotID)
        for subslot = 1, slotCount do
            order = order + 1
            local item = getBagItem(slotID, subslot)
            local isEmpty = (item == nil)
            local include = false
            if shouldIncludeEmptySlots() then
                include = not (state.hideEmptyInFull and isEmpty)
            else
                include = not isEmpty
            end
            if include then
                local stack = math.max(getItemStack(item), 1)
                local itemValue = getItemValue(item)
                local itemID = getItemID(item)
                local doNotSellKey = getDoNotSellKeyFromItem(item)
                out[#out + 1] = {
                    source = 'bank_live',
                    interactive = true,
                    bankNum = bankNum,
                    subslot = subslot,
                    bagName = bagName,
                    item = item,
                    isEmpty = isEmpty,
                    order = order,
                    itemName = getItemName(item, '(empty)'),
                    stack = stack,
                    itemID = itemID,
                    doNotSellKey = doNotSellKey,
                    doNotSell = doNotSellKey ~= nil and state.doNotSellItems[doNotSellKey] == true or false,
                    itemValue = itemValue,
                    totalValue = itemValue * stack,
                    iconID = getItemIcon(item),
                }
            end
        end
    end
    return out
end

local function getBankEntriesSignature(entries)
    local parts = {}
    for i, entry in ipairs(entries or {}) do
        parts[#parts + 1] = table.concat({
            tostring(entry.bankNum or ''),
            tostring(entry.subslot or ''),
            tostring(entry.itemName or ''),
            tostring(entry.stack or 0),
            tostring(entry.itemValue or 0),
            tostring(entry.iconID or 0),
            tostring(entry.isEmpty and 1 or 0),
        }, '|')
    end
    return table.concat(parts, '\n')
end

local function syncBankCache(silent)
    if not bankWindowOpen() then
        if not silent then
            echo('Open your bank first, then click Sync Bank.')
        end
        return false
    end

    local live = buildLiveBankEntries()
    local cached = {}
    for _, entry in ipairs(live) do
        cached[#cached + 1] = {
            source = 'bank_cache',
            interactive = false,
            bankNum = entry.bankNum,
            subslot = entry.subslot,
            bagName = entry.bagName,
            isEmpty = entry.isEmpty,
            order = entry.order,
            itemName = entry.itemName,
            stack = entry.stack,
            itemID = entry.itemID,
            doNotSellKey = entry.doNotSellKey,
            doNotSell = entry.doNotSell,
            itemValue = entry.itemValue,
            totalValue = entry.totalValue,
            iconID = entry.iconID,
        }
    end

    state.bankCache.entries = cached
    state.bankCache.syncedAt = os.date('%Y-%m-%d %H:%M:%S')
    state.bankLastSignature = getBankEntriesSignature(live)
    state.bankCache.character = getCharacterName()
    state.bankCache.server = getServerName()

    saveBankCache()
    if not silent then
        echo(string.format('Bank synced. Cached %d slots.', #cached))
    else
        state.statusMessage = string.format('Bank auto-synced. Cached %d slots.', #cached)
    end
    return true
end

local function pulseBankAutoSync()
    local open = bankWindowOpen()

    if not state.bankAutoSyncEnabled then
        state.bankWasOpen = open
        if not open then
            state.bankLastSignature = nil
        end
        return
    end

    if open then
        local live = buildLiveBankEntries()
        local signature = getBankEntriesSignature(live)

        if not state.bankWasOpen then
            syncBankCache(true)
            state.bankWasOpen = true
            state.bankLastSignature = signature
        elseif signature ~= state.bankLastSignature then
            syncBankCache(true)
            state.bankLastSignature = signature
        end
    elseif state.bankWasOpen then
        state.bankWasOpen = false
        state.bankLastSignature = nil
    end
end

local function buildBankEntries()
    if bankWindowOpen() then
        local live = buildLiveBankEntries()
        if #live > 0 then
            return live, 'live'
        end
    end

    local cacheEntries = state.bankCache and state.bankCache.entries or {}
    local out = {}
    for i, entry in ipairs(cacheEntries) do
        out[i] = {
            source = 'bank_cache',
            interactive = false,
            bankNum = entry.bankNum,
            subslot = entry.subslot,
            bagName = entry.bagName,
            item = nil,
            isEmpty = entry.isEmpty,
            order = entry.order,
            itemName = entry.itemName,
            stack = entry.stack,
            itemID = entry.itemID,
            doNotSellKey = entry.doNotSellKey,
            doNotSell = entry.doNotSellKey ~= nil and state.doNotSellItems[entry.doNotSellKey] == true or (entry.doNotSell == true),
            itemValue = entry.itemValue,
            totalValue = entry.totalValue,
            iconID = entry.iconID or 0,
        }
    end
    return out, 'cached'
end

local function buildEntries()
    if state.activeView == 'bank' then
        return buildBankEntries()
    end
    return buildInventoryEntries(), 'live'
end

function sortEntries(entries)
    local function keepLast(a, b)
        local adns = isDoNotSellEntry(a)
        local bdns = isDoNotSellEntry(b)
        if adns ~= bdns then
            return not adns
        end
        return nil
    end

    if state.sortMode == 'bag' then
        table.sort(entries, function(a, b)
            local keepCmp = keepLast(a, b)
            if keepCmp ~= nil then return keepCmp end
            return a.order < b.order
        end)
    elseif state.sortMode == 'stack_value_desc' then
        table.sort(entries, function(a, b)
            local keepCmp = keepLast(a, b)
            if keepCmp ~= nil then return keepCmp end
            if a.totalValue == b.totalValue then return a.order < b.order end
            return a.totalValue > b.totalValue
        end)
    elseif state.sortMode == 'stack_value_asc' then
        table.sort(entries, function(a, b)
            local keepCmp = keepLast(a, b)
            if keepCmp ~= nil then return keepCmp end
            if a.totalValue == b.totalValue then return a.order < b.order end
            return a.totalValue < b.totalValue
        end)
    elseif state.sortMode == 'name_asc' then
        table.sort(entries, function(a, b)
            local keepCmp = keepLast(a, b)
            if keepCmp ~= nil then return keepCmp end
            local an, bn = string.lower(a.itemName or ''), string.lower(b.itemName or '')
            if an == bn then return a.order < b.order end
            return an < bn
        end)
    elseif state.sortMode == 'name_desc' then
        table.sort(entries, function(a, b)
            local keepCmp = keepLast(a, b)
            if keepCmp ~= nil then return keepCmp end
            local an, bn = string.lower(a.itemName or ''), string.lower(b.itemName or '')
            if an == bn then return a.order < b.order end
            return an > bn
        end)
    end
end

local function computeInventoryValue(entries)
    local total = 0
    for _, entry in ipairs(entries) do
        if not entry.isEmpty then total = total + (entry.totalValue or 0) end
    end
    return total
end

local function getSlotUsage(bankMode)
    local used = 0
    local total = 0

    if state.activeView == 'bank' then
        if bankMode == 'cached' then
            for _, entry in ipairs((state.bankCache and state.bankCache.entries) or {}) do
                total = total + 1
                if not entry.isEmpty then
                    used = used + 1
                end
            end
            return used, total
        end

        for slotID = FIRST_BANK_SLOT, LAST_BANK_SLOT do
            local slotCount = getBagSlotCount(slotID)
            if slotCount > 0 then
                total = total + slotCount
                for subslot = 1, slotCount do
                    if getBagItem(slotID, subslot) ~= nil then
                        used = used + 1
                    end
                end
            end
        end
        return used, total
    end

    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local slotCount = getBagSlotCount(bagSlot)
        if slotCount > 0 then
            total = total + slotCount
            for subslot = 1, slotCount do
                if getBagItem(bagSlot, subslot) ~= nil then
                    used = used + 1
                end
            end
        end
    end

    return used, total
end

local function getInventorySlotUsage()
    local used = 0
    local total = 0
    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local slotCount = getBagSlotCount(bagSlot)
        if slotCount > 0 then
            total = total + slotCount
            for subslot = 1, slotCount do
                if getBagItem(bagSlot, subslot) ~= nil then
                    used = used + 1
                end
            end
        end
    end
    return used, total
end

local function getViewLabel()
    if state.activeView == 'bank' then
        return 'Bank'
    end
    return 'Inventory'
end

local function getBankStatusText(bankMode)
    if state.activeView ~= 'bank' then
        return ''
    end

    if bankMode == 'live' and bankWindowOpen() then
        return 'Bank source: live'
    end

    local syncedAt = state.bankCache and state.bankCache.syncedAt or nil
    if syncedAt then
        local who = ''
        if state.bankCache.character and state.bankCache.character ~= '' then
            who = state.bankCache.character
            if state.bankCache.server and state.bankCache.server ~= '' then
                who = who .. ' @ ' .. state.bankCache.server
            end
        end
        if who ~= '' then
            return string.format('Bank source: cached (%s, %s)', syncedAt, who)
        end
        return string.format('Bank source: cached (%s)', syncedAt)
    end

    return 'Bank source: no snapshot yet'
end

local function drawTooltip(entry, hasCursor, bankMode)
    if not ImGui.IsItemHovered() then return end
    ImGui.BeginTooltip()
    if not entry.isEmpty then
        ImGui.Text(entry.itemName)
        if entry.stack > 1 then
            ImGui.Text(string.format('Stack: %d', entry.stack))
        end
        ImGui.Text('Value: ' .. formatMoney(entry.itemValue))
        if entry.stack > 1 then
            ImGui.Text('Stack total: ' .. formatMoney(entry.totalValue))
        end
        if isDoNotSellEntry(entry) then
            ImGui.TextColored(0.82, 0.64, 1.0, 1.0, 'DO NOT SELL')
        end
    else
        ImGui.TextDisabled('Empty slot')
    end
    if state.showBagInfo then
        ImGui.Separator()
        if state.activeView == 'bank' then
            ImGui.Text(string.format('Bank %d, Slot %d', entry.bankNum or 0, entry.subslot or 0))
        else
            ImGui.Text(string.format('Bag %d, Slot %d', entry.packNum or 0, entry.subslot or 0))
        end
        ImGui.Text(entry.bagName or '')
    end
    ImGui.Separator()

    if state.activeView == 'bank' and not entry.interactive then
        ImGui.TextColored(0.85, 0.82, 0.55, 1.0, 'Cached bank snapshot only')
        ImGui.TextColored(0.80, 0.80, 0.80, 1.0, 'Open your bank and click Sync Bank to refresh')
    elseif hasCursor then
        ImGui.TextColored(0.70, 0.95, 0.70, 1.0, 'Click to place or swap')
    else
        ImGui.TextColored(0.80, 0.80, 0.80, 1.0, 'Left click: pick up/place/swap')
        if state.rightClickEnabled then
            ImGui.TextColored(0.80, 0.80, 0.80, 1.0, 'Right click: clicky/use')
            if state.activeView ~= 'bank' then
                ImGui.TextColored(0.80, 0.80, 0.80, 1.0, 'Ctrl + right click: sell full stack to merchant')
            end
            ImGui.TextColored(0.80, 0.80, 0.80, 1.0, 'Alt + right click: toggle Do Not Sell')
        end
    end

    if state.activeView == 'bank' and bankMode == 'live' then
        ImGui.Separator()
        ImGui.TextColored(0.70, 0.95, 0.70, 1.0, 'Live bank mode active')
    end
    ImGui.EndTooltip()
end

local function drawSlotBackground()
    if state.showItemBackground and animBox then
        ImGui.DrawTextureAnimation(animBox, state.slotSize, state.slotSize)
    end
end

local function drawStackText(stack)
    if stack <= 1 then return end
    local cx, cy = ImGui.GetCursorPos()
    ImGui.SetWindowFontScale(0.68)
    local s = tostring(stack)
    local textWidth = ImGui.CalcTextSize(s)
    ImGui.SetCursorPos(cx + math.max(0, state.slotSize - 1 - textWidth), cy + math.max(0, state.slotSize - 17))
    ImGui.TextUnformatted(s)
    ImGui.SetWindowFontScale(1.0)
end

local function pushGlowColors(entry, hasCursor)
    if state.activeView == 'bank' and not entry.interactive then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.08, 0.12, 0.20, 0.20)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.12, 0.18, 0.30, 0.28)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.16, 0.24, 0.40, 0.36)
        return
    end

    if hasCursor then
        if entry.isEmpty then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.08, 0.28, 0.08, 0.22)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.12, 0.40, 0.12, 0.34)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.16, 0.48, 0.16, 0.42)
        else
            ImGui.PushStyleColor(ImGuiCol.Button, 0.28, 0.22, 0.08, 0.22)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.42, 0.32, 0.10, 0.34)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.50, 0.38, 0.12, 0.42)
        end
        return
    end

    if entry.isEmpty then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.00, 0.00, 0.00, 0.06)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.10, 0.10, 0.10, 0.14)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.14, 0.14, 0.14, 0.20)
        return
    end

    local isProtected = isDoNotSellEntry(entry)

    if not state.showValueGlow or isProtected then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.00, 0.00, 0.00, 0.10)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.22, 0.22, 0.22, 0.18)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.28, 0.28, 0.28, 0.24)
        return
    end

    if entry.totalValue >= 100000 then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.78, 0.62, 0.10, 0.22)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.95, 0.78, 0.16, 0.34)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 1.00, 0.84, 0.20, 0.42)
    elseif entry.totalValue >= 10000 then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.12, 0.62, 0.20, 0.22)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.18, 0.84, 0.28, 0.34)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.22, 0.94, 0.34, 0.42)
    else
        ImGui.PushStyleColor(ImGuiCol.Button, 0.00, 0.00, 0.00, 0.10)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.22, 0.22, 0.22, 0.18)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.28, 0.28, 0.28, 0.24)
    end
end

local function drawKeepMarker(entry)
    if not isDoNotSellEntry(entry) then return end
    local cx, cy = ImGui.GetCursorPos()
    ImGui.SetWindowFontScale(0.56)
    ImGui.SetCursorPos(cx + 2, cy + 1)
    ImGui.TextColored(0.82, 0.64, 1.0, 0.95, 'KEEP')
    ImGui.SetWindowFontScale(1.0)
end

local function drawEntry(entry, index, hasCursor, bankMode)
    local iconID = tonumber(entry.iconID or 0) or 0
    local cx, cy = ImGui.GetCursorPos()

    drawSlotBackground()

    if iconID > 0 and animItems then
        ImGui.SetCursorPos(cx, cy)
        animItems:SetTextureCell(iconID - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, state.slotSize, state.slotSize)
    end

    if entry.stack > 1 then
        ImGui.SetCursorPos(cx, cy)
        drawStackText(entry.stack)
    end

    ImGui.SetCursorPos(cx, cy)
    drawKeepMarker(entry)

    ImGui.SetCursorPos(cx, cy)
    pushGlowColors(entry, hasCursor)

    local labelPrefix = state.activeView == 'bank' and 'bank' or 'flat'
    local slotA = entry.bankNum or entry.packNum or 0
    local label = string.format('##%s_%d_%d_%d', labelPrefix, slotA, entry.subslot or 0, index)
    local clickedLeft = ImGui.Button(label, state.slotSize, state.slotSize)
    if clickedLeft and entry.interactive then
        local now = os.clock()
        if state.pendingLeftClick
            and state.pendingLeftClick.view == state.activeView
            and ((state.activeView == 'bank' and state.pendingLeftClick.bankNum == entry.bankNum)
                or (state.activeView ~= 'bank' and state.pendingLeftClick.packNum == entry.packNum))
            and state.pendingLeftClick.subslot == entry.subslot
            and (now - (state.pendingLeftClick.startedAt or 0)) <= (state.leftClickDelay or 0.24) then
            state.pendingLeftClick = nil
            inspectItem(entry.item)
            echo('Inspect opened for ' .. (entry.itemName or 'item') .. '.')
        else
            state.pendingLeftClick = {
                view = state.activeView,
                packNum = entry.packNum,
                bankNum = entry.bankNum,
                subslot = entry.subslot,
                startedAt = now,
            }
        end
    end

    if entry.item and entry.interactive and state.rightClickEnabled and ImGui.IsItemHovered() and ImGui.IsMouseReleased(1) then
        local ctrlDown = (safeCall(function() return ImGui.IsKeyDown(ImGuiKey.LeftCtrl) end, false) or false)
            or (safeCall(function() return ImGui.IsKeyDown(ImGuiKey.RightCtrl) end, false) or false)
        local altDown = (safeCall(function() return ImGui.IsKeyDown(ImGuiKey.LeftAlt) end, false) or false)
            or (safeCall(function() return ImGui.IsKeyDown(ImGuiKey.RightAlt) end, false) or false)

        if altDown then
            toggleDoNotSellEntry(entry)
        elseif ctrlDown and state.activeView ~= 'bank' then
            if isDoNotSellEntry(entry) then
                echo(string.format('Protected item not sold: %s', entry.itemName or 'item'))
            else
                queueMerchantSell(entry.packNum, entry.subslot, entry.itemName, entry.stack)
            end
        else
            if state.activeView == 'bank' then
                bankItemnotifyRight(entry.bankNum, entry.subslot)
            else
                itemnotifyRight(entry.packNum, entry.subslot)
            end
        end
    end

    drawTooltip(entry, hasCursor, bankMode)
    ImGui.PopStyleColor(3)
end

local function doAction(msg, fn)
    fn()
    saveSettings()
    echo(msg)
end

local function setDepositMode(enabled, quiet)
    enabled = not not enabled
    if state.depositMode == enabled then
        return
    end
    state.depositMode = enabled
    saveSettings()
    if not quiet then
        if enabled then
            echo('Deposit mode enabled. Empty slots are now visible for the current view.')
        else
            echo('Deposit mode disabled.')
        end
    end
end

local function pulseDepositMode()
    if state.depositMode and not hasCursorItem() then
        setDepositMode(false, true)
        state.statusMessage = 'Deposit mode ended because your cursor is empty.'
    end
end

local function findFirstStackableInventoryTarget(cursorItem)
    if not cursorItem or not isItemStackable(cursorItem) then
        return nil, nil
    end

    local cursorID = getItemID(cursorItem)
    local cursorName = string.lower(getItemName(cursorItem, '') or '')
    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local slotCount = getBagSlotCount(bagSlot)
        if slotCount > 0 then
            local packNum = bagSlot - 22
            for subslot = 1, slotCount do
                local item = getBagItem(bagSlot, subslot)
                if item then
                    local sameItem = false
                    local itemID = getItemID(item)
                    if cursorID > 0 and itemID > 0 then
                        sameItem = (cursorID == itemID)
                    else
                        sameItem = string.lower(getItemName(item, '') or '') == cursorName
                    end

                    if sameItem and isItemStackable(item) and getItemStack(item) < getItemStackSize(item) then
                        return packNum, subslot
                    end
                end
            end
        end
    end
    return nil, nil
end

local function findFirstEmptyInventorySlot()
    for bagSlot = FIRST_BAG_SLOT, LAST_BAG_SLOT do
        local slotCount = getBagSlotCount(bagSlot)
        if slotCount > 0 then
            local packNum = bagSlot - 22
            for subslot = 1, slotCount do
                if getBagItem(bagSlot, subslot) == nil then
                    return packNum, subslot
                end
            end
        end
    end
    return nil, nil
end

local function findFirstStackableBankTarget(cursorItem)
    if not cursorItem or not isItemStackable(cursorItem) then
        return nil, nil
    end

    local cursorID = getItemID(cursorItem)
    local cursorName = string.lower(getItemName(cursorItem, '') or '')
    for slotID = FIRST_BANK_SLOT, LAST_BANK_SLOT do
        local slotCount = getBagSlotCount(slotID)
        if slotCount > 0 then
            local bankNum = slotID - FIRST_BANK_SLOT + 1
            for subslot = 1, slotCount do
                local item = getBagItem(slotID, subslot)
                if item then
                    local sameItem = false
                    local itemID = getItemID(item)
                    if cursorID > 0 and itemID > 0 then
                        sameItem = (cursorID == itemID)
                    else
                        sameItem = string.lower(getItemName(item, '') or '') == cursorName
                    end

                    if sameItem and isItemStackable(item) and getItemStack(item) < getItemStackSize(item) then
                        return bankNum, subslot
                    end
                end
            end
        end
    end
    return nil, nil
end

local function findFirstEmptyBankSlot()
    for slotID = FIRST_BANK_SLOT, LAST_BANK_SLOT do
        local slotCount = getBagSlotCount(slotID)
        if slotCount > 0 then
            local bankNum = slotID - FIRST_BANK_SLOT + 1
            for subslot = 1, slotCount do
                if getBagItem(slotID, subslot) == nil then
                    return bankNum, subslot
                end
            end
        end
    end
    return nil, nil
end

local function performAutoDeposit()
    local cursorItem = getCursorItem()
    local cursorName = getCursorName()
    if not cursorItem or not cursorName then
        echo('There is no item on your cursor to deposit.')
        return false
    end

    if state.activeView == 'bank' then
        if not bankWindowOpen() then
            echo('Bank deposit requires the bank window to be open.')
            return false
        end

        local bankNum, subslot = findFirstStackableBankTarget(cursorItem)
        if bankNum and subslot then
            bankItemnotifyLeft(bankNum, subslot)
            state.statusMessage = string.format('Depositing %s into existing stack in Bank %d, Slot %d.', cursorName, bankNum, subslot)
            return true
        end

        bankNum, subslot = findFirstEmptyBankSlot()
        if not bankNum then
            echo('No empty bank bag slots were found.')
            return false
        end

        bankItemnotifyLeft(bankNum, subslot)
        state.statusMessage = string.format('Depositing %s into Bank %d, Slot %d.', cursorName, bankNum, subslot)
        return true
    end

    local packNum, subslot = findFirstStackableInventoryTarget(cursorItem)
    if packNum and subslot then
        itemnotifyLeft(packNum, subslot)
        state.statusMessage = string.format('Depositing %s into existing stack in Bag %d, Slot %d.', cursorName, packNum, subslot)
        return true
    end

    packNum, subslot = findFirstEmptyInventorySlot()
    if not packNum then
        echo('No empty inventory bag slots were found.')
        return false
    end

    itemnotifyLeft(packNum, subslot)
    state.statusMessage = string.format('Depositing %s into Bag %d, Slot %d.', cursorName, packNum, subslot)
    return true
end


local function destroyCursorItem()
    local cursorItem = getCursorItem()
    local cursorName = getCursorName()
    if not cursorItem or not cursorName then
        echo('There is no item on your cursor to destroy.')
        return false
    end

    mq.cmd('/destroy')
    state.statusMessage = string.format('Destroyed %s.', cursorName)
    return true
end

local function dropCursorItem()
    local cursorItem = getCursorItem()
    local cursorName = getCursorName()
    if not cursorItem or not cursorName then
        echo('There is no item on your cursor to drop.')
        return false
    end

    mq.cmd('/drop')
    state.statusMessage = string.format('Dropped %s on the ground.', cursorName)
    return true
end

local function getSortModeLabel(mode)
    if mode == 'stack_value_desc' then return 'High->Low' end
    if mode == 'stack_value_asc' then return 'Low->High' end
    if mode == 'name_asc' then return 'Name A->Z' end
    if mode == 'name_desc' then return 'Name Z->A' end
    return 'Bag Order'
end

local function getSortModeShortLabel(mode)
    if mode == 'stack_value_desc' then return 'High ↓' end
    if mode == 'stack_value_asc' then return 'Low ↑' end
    if mode == 'name_asc' then return 'Name A-Z' end
    if mode == 'name_desc' then return 'Name Z-A' end
    return 'Bag'
end

local function drawTopSortButtons()
    local options = {
        { label = 'Bag Order', mode = 'bag', msg = 'Sort set to bag order.' },
        { label = 'High->Low', mode = 'stack_value_desc', msg = 'Sort set to high to low.' },
        { label = 'Low->High', mode = 'stack_value_asc', msg = 'Sort set to low to high.' },
        { label = 'Name A->Z', mode = 'name_asc', msg = 'Sort set to name A to Z.' },
        { label = 'Name Z->A', mode = 'name_desc', msg = 'Sort set to name Z to A.' },
    }

    local preview = getSortModeLabel(state.sortMode)
    local comboLabel = '##bebags_sort_combo'
    local style = ImGui.GetStyle()
    local comboWidth = math.max(145, ImGui.CalcTextSize(preview) + (style.FramePadding.x * 2) + 18)

    -- Match SmallButton row height as closely as possible without shifting the shared row baseline.
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, style.FramePadding.x, 0)
    ImGui.SetNextItemWidth(comboWidth)

    if ImGui.BeginCombo(comboLabel, preview, ImGuiComboFlags.HeightLarge) then
        for _, opt in ipairs(options) do
            local selected = (state.sortMode == opt.mode)
            if ImGui.Selectable(opt.label, selected) then
                if state.sortMode ~= opt.mode then
                    state.sortMode = opt.mode
                    saveSettings()
                    echo(opt.msg)
                end
            end
            if selected then
                ImGui.SetItemDefaultFocus()
            end
        end
        ImGui.EndCombo()
    end

    ImGui.PopStyleVar()

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Choose how items are displayed and how Sell All queues items.')
    end
end

local function setMainWindowSize(entryCount)
    if not state.autoResizeMain then
        return
    end

    local cols = math.max(1, state.columns)
    local rows = math.max(1, math.ceil(entryCount / cols))

    local itemSpacingX = 4
    local itemSpacingY = 4
    local scrollbarAllowance = state.mainNoScrollbar and 0 or 20
    local titleBarAllowance = state.mainNoTitleBar and 0 or 28
    local valueBarAllowance = state.showMainValueBar and 26 or 0
    local toolbarAllowance = 86

    local width = (cols * state.slotSize)
        + ((cols - 1) * itemSpacingX)
        + scrollbarAllowance
        + state.widthFudge

    local height = (rows * state.slotSize)
        + ((rows - 1) * itemSpacingY)
        + titleBarAllowance
        + valueBarAllowance
        + toolbarAllowance
        + state.heightFudge

    ImGui.SetNextWindowSize(width, height, ImGuiCond.Always)
end

local pushDiabloWindowStyle
local popDiabloWindowStyle
local drawDiabloHeader

local function drawConfigWindow(entries, bankMode)
    if not state.showConfigWindow then return end

    ImGui.SetNextWindowPos(120, 120, ImGuiCond.Appearing)
    ImGui.SetNextWindowSize(700, 760, ImGuiCond.FirstUseEver)
    local pushedColors, pushedVars = pushDiabloWindowStyle()
    local shouldDraw = ImGui.Begin('BEbags Config', true, bit32.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse))
    if shouldDraw then
        if drawDiabloHeader('BEbags Config', 'showConfigWindow', 'Config window closed.', 'Forge your layout') then
            ImGui.End()
            popDiabloWindowStyle(pushedColors, pushedVars)
            return
        end

        ImGui.BeginChild('##config_content', 0, 0, false)

        local totalInventoryValue = computeInventoryValue(entries)
        local usedSlots, totalSlots = getSlotUsage(bankMode)
        local cursorName = getCursorName()

        ImGui.Text('BEbags Configuration')
        ImGui.Separator()

        local keepCount = 0
        for _ in pairs(state.doNotSellItems or {}) do keepCount = keepCount + 1 end

        ImGui.Text('Current View: ' .. getViewLabel())
        ImGui.SameLine(0, 16)
        ImGui.Text('Do Not Sell Flags: ' .. tostring(keepCount))
        if state.activeView == 'bank' and state.showBankStatusText then
            ImGui.TextWrapped(getBankStatusText(bankMode))
        end

        ImGui.Spacing()

        if ImGui.CollapsingHeader('General', ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.Text('Hotkey')
            if state.capturingHotkey then
                local capturedCombo = getCapturedHotkeyCombo()
                if capturedCombo == '__cancel__' then
                    state.capturingHotkey = false
                    echo('Hotkey capture canceled.')
                elseif capturedCombo == '__clear__' then
                    state.capturingHotkey = false
                    applyMainWindowHotkey('', false)
                elseif capturedCombo and capturedCombo ~= '' then
                    state.capturingHotkey = false
                    applyMainWindowHotkey(capturedCombo, false)
                end
            end

            local hotkeyButtonLabel = state.capturingHotkey and 'Press a key combo...' or 'Set Hotkey'
            if ImGui.SmallButton(hotkeyButtonLabel) then
                state.capturingHotkey = true
            end
            ImGui.SameLine()
            if ImGui.SmallButton('Clear Hotkey') then
                state.capturingHotkey = false
                applyMainWindowHotkey('', false)
            end
            ImGui.TextDisabled('Current: ' .. formatHotkeyLabel(state.mainWindowHotkey))
            if state.capturingHotkey then
                ImGui.TextWrapped('Listening... Press your desired key combination now. Esc cancels. Delete clears.')
            end

            ImGui.Spacing()

            local sellAllToggleLabel = state.showSellAllButton and '[X] Show Sell All Button' or '[ ] Show Sell All Button'
            if ImGui.SmallButton(sellAllToggleLabel) then
                local nextShowSellAll = not state.showSellAllButton
                doAction(nextShowSellAll and 'Sell All button enabled.' or 'Sell All button hidden.', function()
                    state.showSellAllButton = nextShowSellAll
                end)
            end

            ImGui.Spacing()

            local bagSpaceOverlayToggleLabel = state.showBagSpaceOverlay and '[X] Show Remaining Bag Space Number' or '[ ] Show Remaining Bag Space Number'
            if ImGui.SmallButton(bagSpaceOverlayToggleLabel) then
                local nextShowBagSpaceOverlay = not state.showBagSpaceOverlay
                doAction(nextShowBagSpaceOverlay and 'Bag space overlay enabled.' or 'Bag space overlay hidden.', function()
                    state.showBagSpaceOverlay = nextShowBagSpaceOverlay
                end)
            end
        end

        if ImGui.CollapsingHeader('Bag Space Alert') then
            ImGui.TextWrapped('Color the launcher number by free bag space percentage. Set Green to 0 to disable the overlay.')

            local currentGreenPercent = clampPercent(state.lowBagSpaceGreenPercent or 25)
            local currentYellowPercent = clampPercent(state.lowBagSpaceYellowPercent or 15)
            local currentRedPercent = clampPercent(state.lowBagSpaceRedPercent or 8)

            ImGui.Text('Green %')
            ImGui.SameLine()
            ImGui.SetNextItemWidth(90)
            local greenOk, greenChanged, greenValue = pcall(function()
                return ImGui.InputInt('##GreenPercent', currentGreenPercent, 1, 5)
            end)
            if greenOk then
                local nextGreen = currentGreenPercent
                local didChange = false
                if type(greenChanged) == 'boolean' then
                    didChange = greenChanged
                    if didChange then nextGreen = tonumber(greenValue) or currentGreenPercent end
                elseif type(greenChanged) == 'number' then
                    nextGreen = greenChanged
                    didChange = nextGreen ~= currentGreenPercent
                end
                if didChange then
                    doAction('Low bag space green threshold updated.', function()
                        state.lowBagSpaceGreenPercent = clampPercent(nextGreen)
                        normalizeLowBagSpaceThresholds()
                    end)
                end
            end

            ImGui.SameLine(0, 16)
            ImGui.Text('Yellow %')
            ImGui.SameLine()
            ImGui.SetNextItemWidth(90)
            local yellowOk, yellowChanged, yellowValue = pcall(function()
                return ImGui.InputInt('##YellowPercent', currentYellowPercent, 1, 5)
            end)
            if yellowOk then
                local nextYellow = currentYellowPercent
                local didChange = false
                if type(yellowChanged) == 'boolean' then
                    didChange = yellowChanged
                    if didChange then nextYellow = tonumber(yellowValue) or currentYellowPercent end
                elseif type(yellowChanged) == 'number' then
                    nextYellow = yellowChanged
                    didChange = nextYellow ~= currentYellowPercent
                end
                if didChange then
                    doAction('Low bag space yellow threshold updated.', function()
                        state.lowBagSpaceYellowPercent = clampPercent(nextYellow)
                        normalizeLowBagSpaceThresholds()
                    end)
                end
            end

            ImGui.SameLine(0, 16)
            ImGui.Text('Red %')
            ImGui.SameLine()
            ImGui.SetNextItemWidth(90)
            local redOk, redChanged, redValue = pcall(function()
                return ImGui.InputInt('##RedPercent', currentRedPercent, 1, 5)
            end)
            if redOk then
                local nextRed = currentRedPercent
                local didChange = false
                if type(redChanged) == 'boolean' then
                    didChange = redChanged
                    if didChange then nextRed = tonumber(redValue) or currentRedPercent end
                elseif type(redChanged) == 'number' then
                    nextRed = redChanged
                    didChange = nextRed ~= currentRedPercent
                end
                if didChange then
                    doAction('Low bag space red threshold updated.', function()
                        state.lowBagSpaceRedPercent = clampPercent(nextRed)
                        normalizeLowBagSpaceThresholds()
                    end)
                end
            end

            ImGui.TextDisabled('Green >= ' .. tostring(state.lowBagSpaceGreenPercent) .. '%   Yellow >= ' .. tostring(state.lowBagSpaceYellowPercent) .. '%   Red < ' .. tostring(state.lowBagSpaceRedPercent) .. '%')

            ImGui.Spacing()
            ImGui.Text('Overlay Look')

            local overlaySizeOptions = {'Small', 'Medium', 'Large'}
            for i, option in ipairs(overlaySizeOptions) do
                if i > 1 then ImGui.SameLine() end
                local label = (state.bagSpaceOverlaySize == option) and ('[' .. option .. ']') or option
                if ImGui.SmallButton(label .. '##BagOverlaySize') then
                    doAction('Bag space overlay size set to ' .. option .. '.', function()
                        state.bagSpaceOverlaySize = option
                    end)
                end
            end

            ImGui.TextDisabled('Style changes the text fill. Outline changes the shadow around it.')
            local overlayStyleOptions = {'Clean', 'Bold'}
            for i, option in ipairs(overlayStyleOptions) do
                if i > 1 then ImGui.SameLine() end
                local label = (state.bagSpaceOverlayStyle == option) and ('[' .. option .. ']') or option
                if ImGui.SmallButton(label .. '##BagOverlayStyle') then
                    doAction('Bag space overlay style set to ' .. option .. '.', function()
                        state.bagSpaceOverlayStyle = option
                    end)
                end
            end

            local overlayPositionOptions = {'Center', 'Top Right', 'Bottom Right', 'Top Left', 'Bottom Left'}
            for i, option in ipairs(overlayPositionOptions) do
                if i > 1 then ImGui.SameLine() end
                local label = (state.bagSpaceOverlayPosition == option) and ('[' .. option .. ']') or option
                if ImGui.SmallButton(label .. '##BagOverlayPosition') then
                    doAction('Bag space overlay position set to ' .. option .. '.', function()
                        state.bagSpaceOverlayPosition = option
                    end)
                end
            end

            local overlayOutlineOptions = {'Off', 'Light', 'Heavy'}
            for i, option in ipairs(overlayOutlineOptions) do
                if i > 1 then ImGui.SameLine() end
                local label = (state.bagSpaceOverlayOutline == option) and ('[' .. option .. ']') or option
                if ImGui.SmallButton(label .. '##BagOverlayOutline') then
                    doAction('Bag space overlay outline set to ' .. option .. '.', function()
                        state.bagSpaceOverlayOutline = option
                    end)
                end
            end

            ImGui.Text('Offset X')
            ImGui.SameLine()
            ImGui.SetNextItemWidth(80)
            local offsetXOk, offsetXChanged, offsetXValue = pcall(function()
                return ImGui.InputInt('##BagOverlayOffsetX', state.bagSpaceOverlayOffsetX or 0, 1, 5)
            end)
            if offsetXOk then
                local nextOffsetX = state.bagSpaceOverlayOffsetX or 0
                local didChange = false
                if type(offsetXChanged) == 'boolean' then
                    didChange = offsetXChanged
                    if didChange then nextOffsetX = tonumber(offsetXValue) or nextOffsetX end
                elseif type(offsetXChanged) == 'number' then
                    nextOffsetX = offsetXChanged
                    didChange = nextOffsetX ~= (state.bagSpaceOverlayOffsetX or 0)
                end
                if didChange then
                    doAction('Bag space overlay X offset updated.', function()
                        state.bagSpaceOverlayOffsetX = math.max(-20, math.min(20, math.floor(tonumber(nextOffsetX) or 0)))
                    end)
                end
            end

            ImGui.SameLine(0, 16)
            ImGui.Text('Offset Y')
            ImGui.SameLine()
            ImGui.SetNextItemWidth(80)
            local offsetYOk, offsetYChanged, offsetYValue = pcall(function()
                return ImGui.InputInt('##BagOverlayOffsetY', state.bagSpaceOverlayOffsetY or 0, 1, 5)
            end)
            if offsetYOk then
                local nextOffsetY = state.bagSpaceOverlayOffsetY or 0
                local didChange = false
                if type(offsetYChanged) == 'boolean' then
                    didChange = offsetYChanged
                    if didChange then nextOffsetY = tonumber(offsetYValue) or nextOffsetY end
                elseif type(offsetYChanged) == 'number' then
                    nextOffsetY = offsetYChanged
                    didChange = nextOffsetY ~= (state.bagSpaceOverlayOffsetY or 0)
                end
                if didChange then
                    doAction('Bag space overlay Y offset updated.', function()
                        state.bagSpaceOverlayOffsetY = math.max(-20, math.min(20, math.floor(tonumber(nextOffsetY) or 0)))
                    end)
                end
            end
        end

        if ImGui.CollapsingHeader('Layout') then
            ImGui.Text('Mode')
            if ImGui.SmallButton('Packed') then doAction('Mode set to packed.', function() state.mode = 'packed' end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Full') then doAction('Mode set to full.', function() state.mode = 'full' end) end
            ImGui.SameLine()
            ImGui.TextDisabled('Current: ' .. state.mode)

            ImGui.Text('Size')
            if ImGui.SmallButton('Cols -1') then doAction('Columns decreased.', function() state.columns = math.max(4, state.columns - 1) end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Cols +1') then doAction('Columns increased.', function() state.columns = math.min(24, state.columns + 1) end) end
            ImGui.SameLine()
            ImGui.TextDisabled('Columns: ' .. tostring(state.columns))

            if ImGui.SmallButton('Size -2') then doAction('Slot size decreased.', function() state.slotSize = math.max(24, state.slotSize - 2) end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Size +2') then doAction('Slot size increased.', function() state.slotSize = math.min(56, state.slotSize + 2) end) end
            ImGui.SameLine()
            ImGui.TextDisabled('Slot Size: ' .. tostring(state.slotSize))

            if ImGui.SmallButton('Width -8') then doAction('Width fudge decreased.', function() state.widthFudge = math.max(0, state.widthFudge - 8) end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Width +8') then doAction('Width fudge increased.', function() state.widthFudge = math.min(200, state.widthFudge + 8) end) end
            ImGui.SameLine()
            ImGui.TextDisabled('Width Fudge: ' .. tostring(state.widthFudge))

            if ImGui.SmallButton('Height -4') then doAction('Height fudge decreased.', function() state.heightFudge = math.max(0, state.heightFudge - 4) end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Height +4') then doAction('Height fudge increased.', function() state.heightFudge = math.min(120, state.heightFudge + 4) end) end
            ImGui.SameLine()
            ImGui.TextDisabled('Height Fudge: ' .. tostring(state.heightFudge))

            if ImGui.SmallButton(state.autoResizeMain and 'Auto Resize: ON' or 'Auto Resize: OFF') then
                doAction('Toggled auto resize.', function() state.autoResizeMain = not state.autoResizeMain end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.mainNoScrollbar and 'Scrollbar: OFF' or 'Scrollbar: ON') then
                doAction('Toggled main scrollbar.', function() state.mainNoScrollbar = not state.mainNoScrollbar end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.mainNoTitleBar and 'Native Title: OFF' or 'Native Title: ON') then
                doAction('Toggled native title bar preference.', function() state.mainNoTitleBar = not state.mainNoTitleBar end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.showMainValueBar and 'Value Bar: ON' or 'Value Bar: OFF') then
                doAction('Toggled main value bar.', function() state.showMainValueBar = not state.showMainValueBar end)
            end
        end

        if ImGui.CollapsingHeader('Visuals') then
            if ImGui.SmallButton(state.hideEmptyInFull and 'Full Empty: Hidden' or 'Full Empty: Shown') then
                doAction('Toggled full empty visibility.', function() state.hideEmptyInFull = not state.hideEmptyInFull end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.showBagInfo and 'Bag Info: ON' or 'Bag Info: OFF') then
                doAction('Toggled bag info.', function() state.showBagInfo = not state.showBagInfo end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.showItemBackground and 'Slot BG: ON' or 'Slot BG: OFF') then
                doAction('Toggled slot background.', function() state.showItemBackground = not state.showItemBackground end)
            end

            if ImGui.SmallButton(state.showValueGlow and 'Value Glow: ON' or 'Value Glow: OFF') then
                doAction('Toggled value glow.', function() state.showValueGlow = not state.showValueGlow end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.rightClickEnabled and 'Right Click: ON' or 'Right Click: OFF') then
                doAction('Toggled right click.', function() state.rightClickEnabled = not state.rightClickEnabled end)
            end

            ImGui.Text('Theme')
            local themeOrder = {'Classic', 'Diablo', 'Emerald', 'Frost'}
            for i, themeName in ipairs(themeOrder) do
                if i > 1 then
                    ImGui.SameLine()
                end
                local label = (state.themePreset == themeName) and ('[' .. themeName .. ']') or themeName
                if ImGui.SmallButton(label) then
                    doAction('Theme set to ' .. themeName .. '.', function()
                        state.themePreset = themeName
                        state.diabloTheme = themeName ~= 'Classic'
                    end)
                end
            end
        end

        if ImGui.CollapsingHeader('Behavior') then
            ImGui.Text('Views')
            if ImGui.SmallButton(state.activeView == 'inventory' and 'Inventory: ON' or 'Inventory') then
                doAction('Switched to inventory view.', function() state.activeView = 'inventory' end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.activeView == 'bank' and 'Bank: ON' or 'Bank') then
                doAction('Switched to bank view.', function() state.activeView = 'bank' end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton(state.depositMode and 'Manual Deposit Mode: ON' or 'Manual Deposit Mode: OFF') then
                setDepositMode(not state.depositMode)
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Manual fallback: shows empty slots even while you normally use Packed mode. It turns itself off after your cursor is empty.')
            end

            if ImGui.SmallButton(state.bankAutoSyncEnabled and 'Auto Sync: ON' or 'Auto Sync: OFF') then
                doAction('Toggled bank auto sync.', function() state.bankAutoSyncEnabled = not state.bankAutoSyncEnabled end)
            end
            if state.showBankSyncButton then
                ImGui.SameLine()
                if ImGui.SmallButton('Sync Bank Now') then
                    syncBankCache()
                end
            end
        end

        if ImGui.CollapsingHeader('Sorting') then
            if ImGui.SmallButton('Bag Order') then doAction('Sort set to bag order.', function() state.sortMode = 'bag' end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Value High->Low') then doAction('Sort set to value high to low.', function() state.sortMode = 'stack_value_desc' end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Value Low->High') then doAction('Sort set to value low to high.', function() state.sortMode = 'stack_value_asc' end) end
            if ImGui.SmallButton('Name A->Z') then doAction('Sort set to name A to Z.', function() state.sortMode = 'name_asc' end) end
            ImGui.SameLine()
            if ImGui.SmallButton('Name Z->A') then doAction('Sort set to name Z to A.', function() state.sortMode = 'name_desc' end) end
        end

        if ImGui.CollapsingHeader('Advanced') then
            if ImGui.SmallButton('Save Settings') then saveSettings(); echo('Settings saved.') end
            ImGui.SameLine()
            if ImGui.SmallButton('Reset Defaults') then resetSettings(); echo('Settings reset.') end
            ImGui.SameLine()
            if ImGui.SmallButton('Close Config') then state.showConfigWindow = false; saveSettings(); echo('Config closed.') end
        end

        ImGui.EndChild()

        ImGui.Separator()
        ImGui.Text('Visible Slots: ' .. tostring(#entries))
        ImGui.Text(string.format('Slots Used / Total: %d/%d', usedSlots, totalSlots))
        ImGui.Text('Total Visible Value: ' .. formatMoney(totalInventoryValue))
        ImGui.Text('Status: ' .. tostring(state.statusMessage))
        if cursorName then
            ImGui.Text('Cursor: ' .. cursorName)
        else
            ImGui.Text('Cursor: empty')
        end
        if state.activeView == 'bank' and state.showBankStatusText then
            ImGui.TextWrapped(getBankStatusText(bankMode))
        end
        if state.lastError ~= '' then
            ImGui.TextColored(1.0, 0.5, 0.5, 1.0, 'Last UI error: ' .. state.lastError)
        end
    end
    ImGui.End()
    popDiabloWindowStyle(pushedColors, pushedVars)
end

local function drawLauncher()
    if not state.showLauncher then
        return
    end

    local flags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.AlwaysAutoResize,
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoResize
    )

    ImGui.SetNextWindowBgAlpha(0.6)

    local shouldDraw = ImGui.Begin('BEbagsLauncher', true, flags)
    if shouldDraw then
        local launcherIconID = getLauncherIconID()
        local buttonSize = 40
        local clickedLeft = false

        local startX, startY = ImGui.GetCursorPos()
        local greenThresholdPercent = clampPercent(state.lowBagSpaceGreenPercent or 25)
        local yellowThresholdPercent = clampPercent(state.lowBagSpaceYellowPercent or 15)
        local redThresholdPercent = clampPercent(state.lowBagSpaceRedPercent or 8)
        local usedInventorySlots, totalInventorySlots = getInventorySlotUsage()
        local freeInventorySlots = math.max(0, totalInventorySlots - usedInventorySlots)
        local freeInventoryPercent = totalInventorySlots > 0 and ((freeInventorySlots / totalInventorySlots) * 100.0) or 100.0
        local showLowSpaceOverlay = state.showBagSpaceOverlay and greenThresholdPercent > 0 and totalInventorySlots > 0

        if launcherIconID > 0 and animItems then
            if animBox then
                ImGui.DrawTextureAnimation(animBox, buttonSize, buttonSize)
                ImGui.SetCursorPos(startX, startY)
            end

            animItems:SetTextureCell(launcherIconID - EQ_ICON_OFFSET)
            ImGui.DrawTextureAnimation(animItems, buttonSize, buttonSize)
            ImGui.SetCursorPos(startX, startY)
        end

        if showLowSpaceOverlay then
            tryLoadHeaderFont()
            local overlayText = tostring(freeInventorySlots)
            local overlayR, overlayG, overlayB = 1.00, 0.18, 0.18
            if freeInventoryPercent >= greenThresholdPercent then
                overlayR, overlayG, overlayB = 0.20, 0.90, 0.20
            elseif freeInventoryPercent >= yellowThresholdPercent then
                overlayR, overlayG, overlayB = 1.00, 0.82, 0.18
            elseif freeInventoryPercent >= redThresholdPercent then
                overlayR, overlayG, overlayB = 1.00, 0.18, 0.18
            end

            local overlaySize = tostring(state.bagSpaceOverlaySize or 'Medium')
            local overlayStyle = tostring(state.bagSpaceOverlayStyle or 'Bold')
            local overlayPosition = tostring(state.bagSpaceOverlayPosition or 'Center')
            local overlayOutline = tostring(state.bagSpaceOverlayOutline or 'Heavy')
            local overlayOffsetX = math.max(-20, math.min(20, math.floor(tonumber(state.bagSpaceOverlayOffsetX) or 0)))
            local overlayOffsetY = math.max(-20, math.min(20, math.floor(tonumber(state.bagSpaceOverlayOffsetY) or 0)))

            local overlayScale = 1.0
            if overlaySize == 'Small' then
                overlayScale = 0.85
            elseif overlaySize == 'Large' then
                overlayScale = 1.20
            end

            if headerFont then ImGui.PushFont(headerFont) end
            local textWidth = ImGui.CalcTextSize(overlayText) * overlayScale
            local overlayX = startX + math.floor((buttonSize - textWidth) * 0.5)
            local overlayY = startY + math.floor((buttonSize - 18) * 0.5) - 2

            if overlayPosition == 'Top Right' then
                overlayX = startX + math.max(1, buttonSize - textWidth - 3)
                overlayY = startY + 2
            elseif overlayPosition == 'Bottom Right' then
                overlayX = startX + math.max(1, buttonSize - textWidth - 3)
                overlayY = startY + buttonSize - 18
            elseif overlayPosition == 'Top Left' then
                overlayX = startX + 2
                overlayY = startY + 2
            elseif overlayPosition == 'Bottom Left' then
                overlayX = startX + 2
                overlayY = startY + buttonSize - 18
            end

            overlayX = overlayX + overlayOffsetX
            overlayY = overlayY + overlayOffsetY

            if overlayScale ~= 1.0 and ImGui.SetWindowFontScale then
                ImGui.SetWindowFontScale(overlayScale)
            end

            if overlayOutline == 'Heavy' then
                ImGui.SetCursorPos(overlayX - 1, overlayY)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.92, overlayText)
                ImGui.SetCursorPos(overlayX + 1, overlayY)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.92, overlayText)
                ImGui.SetCursorPos(overlayX, overlayY - 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.92, overlayText)
                ImGui.SetCursorPos(overlayX, overlayY + 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.92, overlayText)
                ImGui.SetCursorPos(overlayX - 1, overlayY - 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.80, overlayText)
                ImGui.SetCursorPos(overlayX + 1, overlayY - 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.80, overlayText)
                ImGui.SetCursorPos(overlayX - 1, overlayY + 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.80, overlayText)
                ImGui.SetCursorPos(overlayX + 1, overlayY + 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.80, overlayText)
            elseif overlayOutline == 'Light' then
                ImGui.SetCursorPos(overlayX + 1, overlayY + 1)
                ImGui.TextColored(0.00, 0.00, 0.00, 0.75, overlayText)
            end

            if overlayStyle == 'Bold' then
                ImGui.SetCursorPos(overlayX - 0.6, overlayY)
                ImGui.TextColored(overlayR, overlayG, overlayB, 0.95, overlayText)
                ImGui.SetCursorPos(overlayX + 0.6, overlayY)
                ImGui.TextColored(overlayR, overlayG, overlayB, 0.95, overlayText)
            end

            ImGui.SetCursorPos(overlayX, overlayY)
            ImGui.TextColored(overlayR, overlayG, overlayB, 1.00, overlayText)

            if overlayScale ~= 1.0 and ImGui.SetWindowFontScale then
                ImGui.SetWindowFontScale(1.0)
            end
            if headerFont then ImGui.PopFont() end
            ImGui.SetCursorPos(startX, startY)
        end

        if launcherIconID > 0 and animItems then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.00, 0.00, 0.00, 0.05)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.90, 0.82, 0.28, 0.18)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.95, 0.86, 0.32, 0.24)
            clickedLeft = ImGui.Button('##bebags_launcher_icon', buttonSize, buttonSize)
            ImGui.PopStyleColor(3)
        else
            clickedLeft = ImGui.Button('BAG', buttonSize, buttonSize)
        end

        local launcherHovered = ImGui.IsItemHovered()
        local launcherRightReleased = launcherHovered and ImGui.IsMouseReleased(1)
        local launcherMiddleReleased = launcherHovered and ImGui.IsMouseReleased(2)

        if clickedLeft then
            state.showMainWindow = not state.showMainWindow
            saveSettings()
            echo(state.showMainWindow and 'Main window shown.' or 'Main window hidden.')
        end

        if launcherRightReleased then
            state.showConfigWindow = not state.showConfigWindow
            ImGui.SetNextWindowPos(120, 120, ImGuiCond.Appearing)
            saveSettings()
            echo(state.showConfigWindow and 'Config window opened.' or 'Config window hidden.')
        end

        if launcherMiddleReleased then
            state.showQuickHelp = not state.showQuickHelp
        end

        if launcherHovered then
            ImGui.BeginTooltip()
            ImGui.Text('BEbags')
            ImGui.Text('Left click: Show/Hide Bags')
            ImGui.Text('Right click: Open/Close Config')
            ImGui.Text('Middle click: Quick Help')
            ImGui.EndTooltip()
        end

        if state.showQuickHelp then
            ImGui.Separator()
            ImGui.Text('Quick Actions')
            if ImGui.SmallButton(state.mode == 'packed' and 'Mode: Packed' or 'Mode: Full') then
                state.mode = (state.mode == 'packed') and 'full' or 'packed'
                saveSettings()
                echo('Mode set to ' .. state.mode .. '.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Toggle packed/full mode')
            end

            ImGui.SameLine()
            if ImGui.SmallButton(state.sortMode == 'bag' and 'Bag Order' or 'Sort Reset') then
                state.sortMode = 'bag'
                saveSettings()
                echo('Sort set to bag order.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Reset sorting to bag order')
            end

            if ImGui.SmallButton(state.showMainValueBar and 'Value Bar: ON' or 'Value Bar: OFF') then
                state.showMainValueBar = not state.showMainValueBar
                saveSettings()
                echo(state.showMainValueBar and 'Main value bar enabled.' or 'Main value bar disabled.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Toggle total inventory value display')
            end

            ImGui.SameLine()
            if ImGui.SmallButton(state.rightClickEnabled and 'Right Click: ON' or 'Right Click: OFF') then
                state.rightClickEnabled = not state.rightClickEnabled
                saveSettings()
                echo(state.rightClickEnabled and 'Right click enabled.' or 'Right click disabled.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Toggle right-click item use')
            end

            if ImGui.SmallButton('Help') then
                state.showHelpDialog = true
                saveSettings()
                echo('Help dialog opened.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Open the plain-language help dialog')
            end

            ImGui.SameLine()
            if ImGui.SmallButton('Hide Launcher') then
                state.showLauncher = false
                saveSettings()
                echo('Launcher hidden. Use /BEbags launcher show to bring it back.')
            end
            if ImGui.IsItemHovered() then
                ImGui.SetTooltip('Hide the floating launcher button')
            end
        end
    end
    ImGui.End()
end

local function drawViewButtons(bankMode)
    local function drawViewButton(label, active, onClick, tooltip, style)
        style = style or 'default'

        if style == 'primary' then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.34, 0.25, 0.10, 0.90)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.44, 0.32, 0.13, 0.96)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.52, 0.38, 0.16, 1.00)
        elseif active then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.18, 0.45, 0.18, 0.45)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.18, 0.55, 0.18, 0.55)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.18, 0.65, 0.18, 0.65)
        elseif style == 'secondary' then
            ImGui.PushStyleColor(ImGuiCol.Button, 0.24, 0.18, 0.10, 0.82)
            ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.34, 0.24, 0.12, 0.90)
            ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.42, 0.30, 0.15, 0.95)
        end

        local clicked = ImGui.SmallButton(label)

        if style == 'primary' or active or style == 'secondary' then
            ImGui.PopStyleColor(3)
        end

        if clicked then
            onClick()
        end
        if ImGui.IsItemHovered() and tooltip then
            ImGui.SetTooltip(tooltip)
        end
    end

    local function drawDangerButton(label, onClick, tooltip)
        ImGui.PushStyleColor(ImGuiCol.Button, 0.36, 0.10, 0.10, 0.88)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.54, 0.14, 0.14, 0.95)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.66, 0.18, 0.18, 0.98)
        local clicked = ImGui.SmallButton(label)
        ImGui.PopStyleColor(3)
        if clicked then
            onClick()
        end
        if ImGui.IsItemHovered() and tooltip then
            ImGui.SetTooltip(tooltip)
        end
    end

    local function approxButtonWidth(label)
        local style = ImGui.GetStyle()
        return ImGui.CalcTextSize(label) + (style.FramePadding.x * 2) + 2
    end

    local contentRight = ImGui.GetWindowContentRegionMax()
    local sellLabel = state.activeView == 'bank' and 'Sell All (Inv)' or 'Sell All'
    local style = ImGui.GetStyle()
    local dangerSpacing = style.ItemSpacing.x
    local sellWidth = approxButtonWidth(sellLabel)
    local dangerWidth = approxButtonWidth('Destroy') + dangerSpacing + approxButtonWidth('Drop')
    local rightAnchorWidth = math.max(sellWidth, dangerWidth)
    local rightAnchorX = contentRight - rightAnchorWidth

    drawViewButton('Inventory', state.activeView == 'inventory', function()
        state.activeView = 'inventory'
        saveSettings()
        echo('Switched to inventory view.')
    end, 'Show your carried bags')

    ImGui.SameLine()
    drawViewButton('Bank', state.activeView == 'bank', function()
        state.activeView = 'bank'
        saveSettings()
        echo('Switched to bank view.')
    end, 'Show live bank contents while bank is open, otherwise your last synced bank snapshot')

    if rightAnchorX < ImGui.GetCursorPosX() + 12 then
        rightAnchorX = ImGui.GetCursorPosX() + 12
    end

    if state.showSellAllButton then
        ImGui.SameLine(0, 8)
        ImGui.SetCursorPosX(rightAnchorX)
        ImGui.BeginGroup()
        if rightAnchorWidth > sellWidth then
            ImGui.Dummy(rightAnchorWidth - sellWidth, 0)
            ImGui.SameLine(0, 0)
        end
        drawViewButton(sellLabel, false, function()
            bulkSellByValue(1000)
        end, 'Sell all inventory items worth 1pp or more. Skips items marked KEEP / Do Not Sell. Uses the current sort order.', 'primary')
        ImGui.EndGroup()
    end

    ImGui.NewLine()

    drawViewButton('Deposit', false, function()
        performAutoDeposit()
    end, 'Place the item on your cursor into the first matching stack or first empty bag slot in bag order for the current view. Bank deposits require the bank window to be open.', 'secondary')

    ImGui.SameLine(0, 6)
    drawViewButton('Help', false, function()
        state.showHelpDialog = true
        saveSettings()
        echo('Help dialog opened.')
    end, 'Open the field manual.', 'secondary')

    -- Keep the sort dropdown grouped with the utility controls and aligned to the same row height.
    ImGui.SameLine(0, 6)
    drawTopSortButtons()

    local dangerX = contentRight - dangerWidth
    if dangerX < ImGui.GetCursorPosX() + 12 then
        dangerX = ImGui.GetCursorPosX() + 12
    end

    ImGui.SameLine(0, 8)
    ImGui.SetCursorPosX(dangerX)
    drawDangerButton('Destroy', function()
        destroyCursorItem()
    end, 'Destroy the item currently on your cursor. This cannot be undone.')

    ImGui.SameLine()
    drawDangerButton('Drop', function()
        dropCursorItem()
    end, 'Drop the item currently on your cursor onto the ground.')
end


local THEME_PRESETS = {
    Classic = {
        windowBg = {0.06, 0.06, 0.06, 0.94},
        border = {0.45, 0.45, 0.45, 0.85},
        titleBg = {0.10, 0.10, 0.10, 0.95},
        titleBgActive = {0.14, 0.14, 0.14, 0.98},
        frameBg = {0.16, 0.16, 0.16, 0.90},
        frameBgHovered = {0.24, 0.24, 0.24, 0.92},
        frameBgActive = {0.30, 0.30, 0.30, 0.95},
        button = {0.20, 0.20, 0.20, 0.90},
        buttonHovered = {0.30, 0.30, 0.30, 0.95},
        buttonActive = {0.38, 0.38, 0.38, 0.98},
        header = {0.22, 0.22, 0.22, 0.92},
        headerHovered = {0.30, 0.30, 0.30, 0.96},
        headerActive = {0.38, 0.38, 0.38, 0.98},
        childBg = {0.10, 0.10, 0.10, 0.95},
        headerBorder = {0.60, 0.60, 0.60, 0.92},
        titleText = {0.92, 0.92, 0.92, 0.98},
        glowText = {0.82, 0.82, 0.82, 0.26},
        accentText = {1.00, 1.00, 1.00, 1.00},
        closeButton = {0.34, 0.18, 0.18, 0.96},
        closeHover = {0.52, 0.24, 0.24, 1.00},
        closeActive = {0.64, 0.30, 0.30, 1.00},
        windowRounding = 8,
        windowBorderSize = 1.2,
        frameRounding = 4,
        frameBorderSize = 1.0,
        headerHeight = 42,
    },
    Diablo = {
        windowBg = {0.07, 0.05, 0.04, 0.96},
        border = {0.58, 0.43, 0.18, 0.85},
        titleBg = {0.12, 0.06, 0.03, 0.95},
        titleBgActive = {0.18, 0.09, 0.04, 0.98},
        frameBg = {0.13, 0.10, 0.07, 0.90},
        frameBgHovered = {0.24, 0.18, 0.10, 0.90},
        frameBgActive = {0.32, 0.24, 0.12, 0.92},
        button = {0.22, 0.13, 0.06, 0.88},
        buttonHovered = {0.36, 0.22, 0.09, 0.94},
        buttonActive = {0.46, 0.28, 0.10, 0.98},
        header = {0.24, 0.14, 0.06, 0.92},
        headerHovered = {0.36, 0.22, 0.08, 0.96},
        headerActive = {0.48, 0.28, 0.10, 0.98},
        childBg = {0.14, 0.07, 0.03, 0.92},
        headerBorder = {0.68, 0.52, 0.18, 0.95},
        titleText = {0.84, 0.76, 0.58, 0.98},
        glowText = {0.70, 0.50, 0.18, 0.28},
        accentText = {0.96, 0.84, 0.36, 1.00},
        closeButton = {0.35, 0.09, 0.06, 0.96},
        closeHover = {0.58, 0.20, 0.10, 1.00},
        closeActive = {0.72, 0.28, 0.14, 1.00},
        windowRounding = 10,
        windowBorderSize = 1.5,
        frameRounding = 5,
        frameBorderSize = 1.0,
        headerHeight = 48,
    },
    Emerald = {
        windowBg = {0.03, 0.08, 0.06, 0.96},
        border = {0.18, 0.62, 0.42, 0.88},
        titleBg = {0.04, 0.11, 0.08, 0.96},
        titleBgActive = {0.06, 0.16, 0.11, 0.98},
        frameBg = {0.08, 0.16, 0.12, 0.92},
        frameBgHovered = {0.12, 0.25, 0.18, 0.94},
        frameBgActive = {0.18, 0.34, 0.24, 0.96},
        button = {0.08, 0.24, 0.18, 0.90},
        buttonHovered = {0.12, 0.38, 0.28, 0.95},
        buttonActive = {0.16, 0.48, 0.36, 0.98},
        header = {0.08, 0.22, 0.16, 0.92},
        headerHovered = {0.12, 0.34, 0.24, 0.96},
        headerActive = {0.16, 0.46, 0.32, 0.98},
        childBg = {0.04, 0.12, 0.09, 0.94},
        headerBorder = {0.34, 0.84, 0.62, 0.96},
        titleText = {0.74, 0.96, 0.86, 0.98},
        glowText = {0.20, 0.70, 0.52, 0.28},
        accentText = {0.86, 1.00, 0.94, 1.00},
        closeButton = {0.18, 0.28, 0.18, 0.96},
        closeHover = {0.28, 0.44, 0.28, 1.00},
        closeActive = {0.36, 0.56, 0.36, 1.00},
        windowRounding = 10,
        windowBorderSize = 1.5,
        frameRounding = 5,
        frameBorderSize = 1.0,
        headerHeight = 48,
    },
    Frost = {
        windowBg = {0.04, 0.06, 0.10, 0.96},
        border = {0.46, 0.66, 0.92, 0.88},
        titleBg = {0.05, 0.09, 0.15, 0.96},
        titleBgActive = {0.08, 0.12, 0.20, 0.98},
        frameBg = {0.10, 0.14, 0.22, 0.92},
        frameBgHovered = {0.16, 0.22, 0.34, 0.94},
        frameBgActive = {0.20, 0.30, 0.46, 0.96},
        button = {0.10, 0.18, 0.30, 0.90},
        buttonHovered = {0.16, 0.28, 0.46, 0.95},
        buttonActive = {0.22, 0.38, 0.58, 0.98},
        header = {0.12, 0.20, 0.32, 0.92},
        headerHovered = {0.18, 0.30, 0.48, 0.96},
        headerActive = {0.24, 0.40, 0.62, 0.98},
        childBg = {0.06, 0.10, 0.18, 0.94},
        headerBorder = {0.64, 0.82, 1.00, 0.96},
        titleText = {0.84, 0.92, 1.00, 0.98},
        glowText = {0.36, 0.58, 0.88, 0.28},
        accentText = {0.96, 0.98, 1.00, 1.00},
        closeButton = {0.20, 0.24, 0.34, 0.96},
        closeHover = {0.30, 0.38, 0.52, 1.00},
        closeActive = {0.38, 0.48, 0.66, 1.00},
        windowRounding = 10,
        windowBorderSize = 1.5,
        frameRounding = 5,
        frameBorderSize = 1.0,
        headerHeight = 48,
    },
}

local function getActiveTheme()
    return THEME_PRESETS[state.themePreset] or THEME_PRESETS.Diablo
end



tryLoadHeaderFont = function()
    if headerFontLoaded then return end
    headerFontLoaded = true

    safeCall(function()
        local io = ImGui.GetIO and ImGui.GetIO() or nil
        if not io or not io.Fonts or not io.Fonts.AddFontFromFileTTF then
            return
        end

        local candidates = {
            'C:/Windows/Fonts/ariblk.ttf',
            'C:/Windows/Fonts/impact.ttf',
            'C:/Windows/Fonts/arialbd.ttf',
        }

        for _, fontPath in ipairs(candidates) do
            local f = io.Fonts:AddFontFromFileTTF(fontPath, 22)
            if f then
                headerFont = f
                break
            end
        end
    end, nil)
end

pushDiabloWindowStyle = function()
    local theme = getActiveTheme()
    local pushedColors = 0
    local pushedVars = 0

    ImGui.PushStyleColor(ImGuiCol.WindowBg, unpack(theme.windowBg)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.Border, unpack(theme.border)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.TitleBg, unpack(theme.titleBg)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, unpack(theme.titleBgActive)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.FrameBg, unpack(theme.frameBg)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, unpack(theme.frameBgHovered)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, unpack(theme.frameBgActive)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.Button, unpack(theme.button)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, unpack(theme.buttonHovered)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, unpack(theme.buttonActive)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.Header, unpack(theme.header)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, unpack(theme.headerHovered)); pushedColors = pushedColors + 1
    ImGui.PushStyleColor(ImGuiCol.HeaderActive, unpack(theme.headerActive)); pushedColors = pushedColors + 1

    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, theme.windowRounding or 10); pushedVars = pushedVars + 1
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, theme.windowBorderSize or 1.5); pushedVars = pushedVars + 1
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, theme.frameRounding or 5); pushedVars = pushedVars + 1
    ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, theme.frameBorderSize or 1.0); pushedVars = pushedVars + 1
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 10, 10); pushedVars = pushedVars + 1

    return pushedColors, pushedVars
end

popDiabloWindowStyle = function(pushedColors, pushedVars)
    if pushedVars and pushedVars > 0 then ImGui.PopStyleVar(pushedVars) end
    if pushedColors and pushedColors > 0 then ImGui.PopStyleColor(pushedColors) end
end

drawDiabloHeader = function(title, targetKey, closeMessage, subtitle)
    tryLoadHeaderFont()
    local theme = getActiveTheme()
    local avail = ImGui.GetContentRegionAvail()
    local width = type(avail) == 'number' and avail or (avail.x or 0)
    local headerHeight = theme.headerHeight or 48
    local xsize = 28

    ImGui.PushStyleColor(ImGuiCol.ChildBg, unpack(theme.childBg))
    ImGui.PushStyleColor(ImGuiCol.Border, unpack(theme.headerBorder))
    ImGui.BeginChild('##header_' .. tostring(targetKey), 0, headerHeight, true, bit32.bor(ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse))

    local startX, startY = ImGui.GetCursorPos()
    local closeX = math.max(startX, width - xsize - 8)
    local pulse = 0.5 + (math.sin(os.clock() * 2.8) * 0.5)

    local fullTitle = title or 'BEbags'
    if subtitle and subtitle ~= '' then
        fullTitle = fullTitle .. ' — ' .. subtitle
    end

    local leftPad = startX + 10
    local rightPad = closeX - 12

    if headerFont then ImGui.PushFont(headerFont) end
    local fullWidth = ImGui.CalcTextSize(fullTitle)
    local textX = leftPad + math.max(0, (rightPad - leftPad - fullWidth) * 0.5)
    local textY = startY + math.max(0, math.floor((headerHeight - 24) * 0.5) - 1)

    ImGui.SetCursorPos(textX, textY)
    ImGui.TextColored(theme.titleText[1], theme.titleText[2], theme.titleText[3], theme.titleText[4], fullTitle)

    if title and title ~= '' then
        local glowA = (theme.glowText[4] or 0.24) + pulse * 0.08
        local gr, gg, gb = theme.glowText[1], theme.glowText[2], theme.glowText[3]
        ImGui.SetCursorPos(textX - 1, textY)
        ImGui.TextColored(gr, gg, gb, glowA, title)
        ImGui.SetCursorPos(textX + 1, textY)
        ImGui.TextColored(gr, gg, gb, glowA, title)
        ImGui.SetCursorPos(textX, textY - 1)
        ImGui.TextColored(gr, gg, gb, glowA * 0.85, title)
        ImGui.SetCursorPos(textX, textY + 1)
        ImGui.TextColored(gr, gg, gb, glowA * 0.85, title)
        ImGui.SetCursorPos(textX, textY)
        local ar, ag, ab, aa = unpack(theme.accentText)
        ImGui.TextColored(ar, ag, ab, aa or 1.0, title)
    end
    if headerFont then ImGui.PopFont() end

    ImGui.SetCursorPos(closeX, startY + math.max(6, math.floor((headerHeight - 20) * 0.5)))
    local hoverPulse = 0.5 + (math.sin(os.clock() * 10.0) * 0.5)
    local btn = theme.closeButton
    local hov = theme.closeHover
    local act = theme.closeActive
    local pulseMix = hoverPulse * 0.08
    ImGui.PushStyleColor(ImGuiCol.Button, btn[1], btn[2], btn[3], btn[4])
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, math.min(1.0, hov[1] + pulseMix), math.min(1.0, hov[2] + pulseMix), math.min(1.0, hov[3] + pulseMix), hov[4])
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, act[1], act[2], act[3], act[4])
    if ImGui.SmallButton('X##' .. tostring(targetKey)) then
        state[targetKey] = false
        saveSettings()
        if closeMessage then echo(closeMessage) end
        ImGui.PopStyleColor(3)
        ImGui.EndChild()
        ImGui.PopStyleColor(2)
        return true
    end
    ImGui.PopStyleColor(3)

    ImGui.EndChild()
    ImGui.PopStyleColor(2)
    ImGui.Spacing()
    return false
end

local function drawWindowCloseX(targetKey, closeMessage)
    local avail = ImGui.GetContentRegionAvail()
    local xsize = 22
    if avail > xsize then
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + avail - xsize)
    end
    if ImGui.SmallButton('X##' .. tostring(targetKey)) then
        state[targetKey] = false
        saveSettings()
        if closeMessage then
            echo(closeMessage)
        end
        return true
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Close this window')
    end
    return false
end

local function drawMainWindow(entries, bankMode)
    setMainWindowSize(#entries)

    local flags = bit32.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse)

    local pushedColors, pushedVars = pushDiabloWindowStyle()
    local shouldDraw = ImGui.Begin('BEbags', true, flags)
    if shouldDraw then
        local subtitle = state.activeView == 'bank' and 'Vault of the Hoard' or 'Adventurer\'s Pack'
        if drawDiabloHeader('BEbags', 'showMainWindow', 'Main window hidden.', subtitle) then
            ImGui.End()
            popDiabloWindowStyle(pushedColors, pushedVars)
            return
        end

        local contentChildFlags = 0
        if state.mainNoScrollbar then
            contentChildFlags = bit32.bor(contentChildFlags, ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse)
        else
            contentChildFlags = bit32.bor(contentChildFlags, ImGuiWindowFlags.AlwaysVerticalScrollbar)
        end
        ImGui.BeginChild('##main_content', 0, 0, false, contentChildFlags)

        local totalInventoryValue = computeInventoryValue(entries)
        local usedSlots, totalSlots = getSlotUsage(bankMode)
        if state.showMainValueBar then
            local label = (state.activeView == 'bank') and 'Bank Total: ' or 'Total: '
            ImGui.TextColored(0.95, 0.88, 0.30, 1.0, label .. formatMoney(totalInventoryValue))
            ImGui.SameLine()
        end
        ImGui.TextColored(0.78, 0.86, 0.96, 1.0, string.format('Slots: %d/%d', usedSlots, totalSlots))
        ImGui.SameLine()

        drawViewButtons(bankMode)
        ImGui.Dummy(0, 3)
        ImGui.Separator()
        ImGui.Dummy(0, 2)

        local cursorPresent = hasCursorItem()
        for i, entry in ipairs(entries) do
            drawEntry(entry, i, cursorPresent, bankMode)
            if (i % state.columns) ~= 0 then
                ImGui.SameLine()
            end
        end

        ImGui.EndChild()
    end
    ImGui.End()
    popDiabloWindowStyle(pushedColors, pushedVars)
end

local function processPendingLeftClick()
    if not state.pendingLeftClick then
        return
    end

    if os.clock() < ((state.pendingLeftClick.startedAt or 0) + (state.leftClickDelay or 0.24)) then
        return
    end

    if state.pendingLeftClick.view == 'bank' then
        bankItemnotifyLeft(state.pendingLeftClick.bankNum, state.pendingLeftClick.subslot)
    else
        itemnotifyLeft(state.pendingLeftClick.packNum, state.pendingLeftClick.subslot)
    end
    state.pendingLeftClick = nil
end

local function processPendingSell()
    if not state.pendingSell then
        if state.pendingSellQueue and #state.pendingSellQueue > 0 then
            if os.clock() >= (state.pendingSellQueueReadyAt or 0) then
                startNextQueuedSell()
            end
        end
        return
    end

    if os.clock() < (state.pendingSell.readyAt or 0) then
        return
    end

    if not merchantWindowOpen() then
        echo('Merchant window closed before sell completed.')
        state.pendingSell = nil
        state.pendingSellQueue = nil
        state.pendingSellQueueReadyAt = 0
        return
    end

    local qty = tonumber(state.pendingSell.stackSize) or 1
    if qty < 1 then qty = 1 end
    sellSelectedMerchantItem(qty)
    echo(string.format('Sent merchant sell for %s x%d.', (state.pendingSell.itemName or 'item'), qty))
    state.pendingSell = nil

    if state.pendingSellQueue and #state.pendingSellQueue > 0 then
        state.pendingSellQueueReadyAt = os.clock() + 0.35
    else
        state.pendingSellQueue = nil
        state.pendingSellQueueReadyAt = 0
    end
end

local function drawHelpDialog()
    if not state.showHelpDialog then
        return
    end

    ImGui.SetNextWindowPos(140, 140, ImGuiCond.Appearing)
    ImGui.SetNextWindowSize(760, 520, ImGuiCond.FirstUseEver)
    local pushedColors, pushedVars = pushDiabloWindowStyle()
    local shouldDraw = ImGui.Begin('BEbags Help', true, bit32.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse))
    local requestClose = false

    if shouldDraw then
        if drawDiabloHeader('BEbags Help', 'showHelpDialog', nil, 'Field manual') then
            ImGui.End()
            popDiabloWindowStyle(pushedColors, pushedVars)
            state.showHelpDialog = false
            saveSettings()
            echo('Help dialog closed.')
            return
        end

        ImGui.BeginChild('##help_content', 0, 0, false)

        ImGui.TextWrapped('BEbags puts your bags and synced bank view into one cleaner window.')

        if ImGui.CollapsingHeader('Getting Started', ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.BulletText('Inventory shows all carried bag items in one place.')
            ImGui.BulletText('Bank shows live contents when open, otherwise your last synced snapshot.')
            ImGui.BulletText('Opening the bank auto-syncs a fresh snapshot for that character.')
            ImGui.BulletText('Switch views with Inventory / Bank on the main window.')
        end

        
        
        if ImGui.CollapsingHeader('Selling & KEEP') then
            ImGui.BulletText('Sell All sells items worth 1pp+ at a merchant.')
            ImGui.BulletText('Sell All respects KEEP flags and your current sort order.')
            ImGui.BulletText('Ctrl + Right Click sells a full stack at a merchant.')
            ImGui.TextColored(1.0, 0.85, 0.20, 1.0, 'Gold')
            ImGui.SameLine()
            ImGui.Text(' - item is worth 100pp or more')
            ImGui.TextColored(0.60, 1.0, 0.60, 1.0, 'Green')
            ImGui.SameLine()
            ImGui.Text(' - item is worth 10pp or more')
            ImGui.TextColored(0.82, 0.64, 1.0, 1.0, 'KEEP')
            ImGui.SameLine()
            ImGui.Text(' - protected from selling and glow')
        end

        if ImGui.CollapsingHeader('Sorting') then
            ImGui.BulletText('Bag Order')
            ImGui.BulletText('High->Low')
            ImGui.BulletText('Low->High')
            ImGui.BulletText('Name A->Z')
            ImGui.BulletText('Name Z->A')
            ImGui.BulletText('Selling follows the current sort order.')
        end

        if ImGui.CollapsingHeader('Bag Space Indicator') then
            ImGui.BulletText('Optional number on the launcher icon shows remaining free bag slots.')
            ImGui.BulletText('Color changes by your free-space percentage thresholds.')
            ImGui.BulletText('Customize size, position, style, outline, and offsets in Config.')
            ImGui.BulletText('The overlay is off by default and can be enabled any time.')
        end

        if ImGui.CollapsingHeader('Controls') then
            ImGui.BulletText('Left Click: pick up, place, or swap an item.')
            ImGui.BulletText('Double Left Click: inspect item.')
            ImGui.BulletText('Right Click: use a clicky item.')
            ImGui.BulletText('Alt + Right Click: toggle KEEP on an item.')
            ImGui.BulletText('Set a hotkey in Config to toggle the main window.')
        end

                if ImGui.CollapsingHeader('Quick Tips', ImGuiTreeNodeFlags.DefaultOpen) then
            ImGui.BulletText('Sort High->Low, then use Sell All to clean junk fast.')
            ImGui.BulletText('Mark important items as KEEP so they never sell or glow.')
            ImGui.BulletText('Use Packed mode for a tighter inventory view.')
            ImGui.BulletText('Open your bank once to refresh its saved snapshot.')
        end

if ImGui.CollapsingHeader('More Tips') then
            ImGui.BulletText('Deposit moves your cursor item into the first valid slot.')
            ImGui.BulletText('Destroy permanently deletes the cursor item.')
            ImGui.BulletText('Drop places the cursor item on the ground.')
            ImGui.BulletText('Most settings save automatically.')
        end

        ImGui.Spacing()
        if ImGui.SmallButton('Close Help') then
            requestClose = true
        end
        ImGui.EndChild()
    end
    ImGui.End()
    popDiabloWindowStyle(pushedColors, pushedVars)

    if requestClose then
        state.showHelpDialog = false
        saveSettings()
        echo('Help dialog closed.')
    end
end

local function drawUI()
    local ok, err = pcall(function()
        processPendingSell()
        processPendingLeftClick()
        pulseDepositMode()
        local entries, bankMode = buildEntries()
        sortEntries(entries)
        drawLauncher()
        if state.showMainWindow then
            drawMainWindow(entries, bankMode)
        end
        drawConfigWindow(entries, bankMode)
        drawHelpDialog()
    end)
    if not ok then
        state.lastError = tostring(err)
        echo('UI error: ' .. state.lastError)
    end
end

mq.bind('/BEbags', function(line)
    local arg = (line or ''):lower():match('^%s*(.-)%s*$')
    if arg == '' or arg == 'config' then
        state.showConfigWindow = not state.showConfigWindow
        ImGui.SetNextWindowPos(120, 120, ImGuiCond.Appearing)
        saveSettings()
        echo(state.showConfigWindow and 'Config window opened.' or 'Config window hidden.')
    elseif arg == 'packed' then
        doAction('Mode set to packed.', function() state.mode = 'packed' end)
    elseif arg == 'full' then
        doAction('Mode set to full.', function() state.mode = 'full' end)
    elseif arg == 'showempty' then
        doAction('Full mode will show empty slots.', function() state.hideEmptyInFull = false end)
    elseif arg == 'hideempty' then
        doAction('Full mode will hide empty slots.', function() state.hideEmptyInFull = true end)
    elseif arg == 'bank' then
        doAction('Switched to bank view.', function() state.activeView = 'bank' end)
    elseif arg == 'inventory' or arg == 'inv' then
        doAction('Switched to inventory view.', function() state.activeView = 'inventory' end)
    elseif arg == 'syncbank' then
        syncBankCache()
    elseif arg == 'deposit' then
        performAutoDeposit()
    elseif arg == 'destroy' then
        destroyCursorItem()
    elseif arg == 'drop' then
        dropCursorItem()
    elseif arg == 'depositmode' then
        setDepositMode(not state.depositMode)
    elseif arg == 'save' then
        saveSettings()
        echo('Settings saved.')
    elseif arg == 'reset' then
        resetSettings()
        echo('Settings reset.')
    elseif arg == 'autoresize on' then
        doAction('Auto resize enabled.', function() state.autoResizeMain = true end)
    elseif arg == 'autoresize off' then
        doAction('Auto resize disabled.', function() state.autoResizeMain = false end)
    elseif arg == 'value on' then
        doAction('Main value bar enabled.', function() state.showMainValueBar = true end)
    elseif arg == 'value off' then
        doAction('Main value bar disabled.', function() state.showMainValueBar = false end)
    elseif arg == 'right on' then
        doAction('Right click enabled.', function() state.rightClickEnabled = true end)
    elseif arg == 'right off' then
        doAction('Right click disabled.', function() state.rightClickEnabled = false end)
    elseif arg == 'show' then
        doAction('Main window shown.', function() state.showMainWindow = true end)
    elseif arg == 'hide' then
        doAction('Main window hidden.', function() state.showMainWindow = false end)
    elseif arg == 'toggle' then
        doAction(state.showMainWindow and 'Main window hidden.' or 'Main window shown.', function() state.showMainWindow = not state.showMainWindow end)
    elseif arg == 'launcher show' then
        doAction('Launcher shown.', function() state.showLauncher = true end)
    elseif arg == 'launcher hide' then
        doAction('Launcher hidden.', function() state.showLauncher = false end)
    elseif arg == 'help' then
        state.showHelpDialog = not state.showHelpDialog
        saveSettings()
        echo(state.showHelpDialog and 'Help dialog opened.' or 'Help dialog closed.')
    else
        echo('Usage: /BEbags config | packed | full | showempty | hideempty | inventory | bank | deposit | destroy | depositmode | syncbank | save | reset | autoresize on|off | value on|off | right on|off | show | hide | toggle | launcher show|hide | help')
    end
end)

if loadSettings() then
    echo('Loaded saved settings from ' .. configPath)
else
    echo('No saved settings found; using defaults.')
end

if loadBankCache() then
    echo('Loaded bank snapshot from ' .. bankCachePath)
else
    echo('No bank snapshot found yet. Open your bank once to auto-sync it.')
end

if tostring(state.mainWindowHotkey or '') ~= '' then
    applyMainWindowHotkey(state.mainWindowHotkey, true)
    echo('Registered main window hotkey: ' .. state.mainWindowHotkey)
end

echo('Started. Use /BEbags config for the config UI.')
mq.imgui.init(SCRIPT_NAME, drawUI)

while state.running do
    pulseBankAutoSync()
    mq.delay(50)
end
