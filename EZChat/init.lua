local mq = require('mq')
local ImGui = require('ImGui')

local ScriptName = 'EZChat'
local Version = '1.0.0'
local ChatQueuePluginName = 'MQChat'

local gameState = mq.TLO.MacroQuest.GameState()
if gameState ~= 'INGAME' then
    printf('\aw[\at%s\aw] \arNot in game. Load after entering world.', ScriptName)
    return
end

local plugin = mq.TLO.Plugin(ChatQueuePluginName)
if plugin and plugin.IsLoaded and plugin.IsLoaded() then
    printf('\aw[\at%s\aw] \ay%s is loaded. Use the plugin-backed /ezchat instead of /lua run %s.',
        ScriptName, ChatQueuePluginName, string.lower(ScriptName))
    return
end

local meName = mq.TLO.Me.CleanName() or 'Unknown'
local myNameLower = string.lower(meName)
local lastPetNameUpdate = 0
local petNameLower = ''

local function getPetNameLower()
    local now = mq.gettime()
    if now - lastPetNameUpdate > 5000 then
        local petName = mq.TLO.Me.Pet.DisplayName()
        petNameLower = petName and string.lower(tostring(petName)) or ''
        lastPetNameUpdate = now
    end
    return petNameLower
end

local serverName = (mq.TLO.MacroQuest.Server() or 'Unknown'):gsub('%s+', '_')
local settingsFile = string.format('%s/%s_%s_%s.lua', mq.configDir, ScriptName, serverName, meName)
local imguiName = string.format('%s_UI_%s', ScriptName, meName)
local eventName = string.format('%s_ALL_%s', ScriptName, meName)

local ALL_CHANNEL_FONT_MULTIPLIER = 1.08
local CHANNEL_REINDEX_THRESHOLD = 2048
local EVENT_DRAIN_PASSES = 3
local EVENT_LOOP_DELAY_MS = 1
local VIRTUALIZATION_OVERSCAN_LINES = 4

local function vec4(r, g, b, a)
    return ImVec4(r, g, b, a or 1.0)
end

local colors = {
    white = vec4(1.00, 1.00, 1.00, 1.0),
    tells = vec4(0.88, 0.72, 0.98, 1.0),
    loot = vec4(0.94, 0.84, 0.42, 1.0),
    group = vec4(0.55, 0.95, 0.62, 1.0),
    guild = vec4(0.45, 0.90, 0.95, 1.0),
    raid = vec4(0.62, 0.84, 1.00, 1.0),
    say = vec4(1.00, 1.00, 1.00, 1.0),
    ooc = vec4(0.52, 0.95, 0.52, 1.0),
    auction = vec4(1.00, 0.78, 0.34, 1.0),
    combat = vec4(0.98, 0.46, 0.46, 1.0),
    system = vec4(0.62, 0.78, 0.98, 1.0),
    mq = vec4(0.90, 0.63, 0.25, 1.0),
    other = vec4(0.78, 0.78, 0.78, 1.0),
    external = vec4(0.82, 0.86, 1.00, 1.0),
    experience = vec4(1.00, 0.92, 0.30, 1.0),
    shout = vec4(1.00, 0.12, 0.12, 1.0),
    task = vec4(0.45, 0.95, 0.85, 1.0),
    link = vec4(1.00, 0.00, 0.67, 1.0),
    linkHover = vec4(1.00, 0.20, 0.75, 1.0),
}

local defaults = {
    fontScale = 1.15,
    timestamps = true,
    autoScroll = true,
    maxLines = 2000,
    lockWindow = false,
    showManager = true,
    mainChatFilters = {},
    mainChatDefaultChannels = {
        tells = true,
        say = true,
        ooc = true,
        raid = true,
        guild = true,
    },
    allInclude = {
        tells = true,
        loot = true,
        group = true,
        guild = true,
        raid = true,
        say = true,
        ooc = true,
        auction = true,
        combat = true,
        system = true,
        mq = false,
        other = true,
        external = true,
    },
}

local compactStyle = {
    windowPaddingX = 3,
    windowPaddingY = 2,
    framePaddingX = 4,
    framePaddingY = 1,
    itemSpacingX = 2,
    itemSpacingY = 1,
    itemInnerSpacingX = 2,
    itemInnerSpacingY = 1,
    cellPaddingX = 2,
    cellPaddingY = 1,
    tabBarBorderSize = 0,
}

local state = {
    running = true,
    showManager = true,
    settings = {},
    settingsDirty = false,
    lastSaveMs = 0,
    lastSortMs = 0,
    channels = {},
    channelOrder = {},
    lastFocusedChannelKey = 'all',
    prevFontGlobalScale = nil,
    canWriteFontGlobal = nil,
    prevMyChatLoaded = rawget(_G, 'MyUI_MyChatLoaded'),
    prevMyChatHandler = rawget(_G, 'MyUI_MyChatHandler'),
    filterPopupOpen = false,
    filterPopupPattern = '',
    filterPopupLinePreview = '',
    chatBackend = 'events',
    lastPluginSequence = nil,
}

local builtinChannelDefs = {
    { key = 'all', name = 'All', color = colors.white, echo = '/say', },
    { key = 'mainchat', name = 'Main Chat', color = colors.white, echo = '/say', },
    { key = 'tells', name = 'Tells', color = colors.tells, echo = '/reply', },
    { key = 'loot', name = 'Loot', color = colors.loot, echo = '/say', },
    { key = 'group', name = 'Group', color = colors.group, echo = '/g', },
    { key = 'guild', name = 'Guild', color = colors.guild, echo = '/gu', },
    { key = 'raid', name = 'Raid', color = colors.raid, echo = '/rs', },
    { key = 'say', name = 'Say', color = colors.say, echo = '/say', },
    { key = 'ooc', name = 'OOC', color = colors.ooc, echo = '/ooc', },
    { key = 'auction', name = 'Auction', color = colors.auction, echo = '/auc', },
    { key = 'combat', name = 'Combat', color = colors.combat, echo = '/say', },
    { key = 'system', name = 'System', color = colors.system, echo = '/say', },
    { key = 'mq', name = 'MQ', color = colors.mq, echo = '/say', },
    { key = 'other', name = 'Other', color = colors.other, echo = '/say', },
}

local function clamp(v, minV, maxV)
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

local function markSettingsDirty()
    state.settingsDirty = true
end

local function fileExists(path)
    local f = io.open(path, 'r')
    if not f then return false end
    f:close()
    return true
end

local function saveSettings(force)
    local now = mq.gettime()
    if not force and not state.settingsDirty then return end
    if not force and (now - state.lastSaveMs) < 1000 then return end
    mq.pickle(settingsFile, state.settings)
    state.settingsDirty = false
    state.lastSaveMs = now
end

local function getBaseFontScale()
    return clamp(tonumber(state.settings.fontScale) or 1.0, 0.75, 2.25)
end

local function applyGlobalFontScale()
    local io = ImGui.GetIO()
    if not io then return end
    if state.prevFontGlobalScale == nil then
        state.prevFontGlobalScale = io.FontGlobalScale or 1.0
    end
    local target = getBaseFontScale()
    if io.FontGlobalScale == target then
        if state.canWriteFontGlobal == nil then
            state.canWriteFontGlobal = true
        end
        return
    end

    local ok = pcall(function()
        io.FontGlobalScale = target
    end)
    state.canWriteFontGlobal = ok
end

local function loadSettings()
    state.settings = {}
    for k, v in pairs(defaults) do
        if type(v) == 'table' then
            local copy = {}
            for tk, tv in pairs(v) do
                copy[tk] = tv
            end
            state.settings[k] = copy
        else
            state.settings[k] = v
        end
    end

    if fileExists(settingsFile) then
        local ok, loaded = pcall(dofile, settingsFile)
        if ok and type(loaded) == 'table' then
            for k, v in pairs(loaded) do
                state.settings[k] = v
            end
        end
    end

    state.settings.fontScale = clamp(tonumber(state.settings.fontScale) or defaults.fontScale, 0.75, 2.25)
    state.settings.maxLines = clamp(math.floor(tonumber(state.settings.maxLines) or defaults.maxLines), 250, 10000)
    state.settings.timestamps = state.settings.timestamps == true
    state.settings.autoScroll = state.settings.autoScroll == true
    state.settings.lockWindow = state.settings.lockWindow == true
    state.settings.showManager = state.settings.showManager ~= false
    if type(state.settings.visibleChannels) ~= 'table' then
        state.settings.visibleChannels = {}
    end
    if type(state.settings.allInclude) ~= 'table' then
        state.settings.allInclude = {}
    end
    if type(state.settings.mainChatFilters) ~= 'table' then
        state.settings.mainChatFilters = {}
    end
    if type(state.settings.mainChatDefaultChannels) ~= 'table' then
        state.settings.mainChatDefaultChannels = {}
    end
    for k, v in pairs(defaults.allInclude) do
        if state.settings.allInclude[k] == nil then
            state.settings.allInclude[k] = v
        end
    end
    for k, v in pairs(defaults.mainChatDefaultChannels) do
        if state.settings.mainChatDefaultChannels[k] == nil then
            state.settings.mainChatDefaultChannels[k] = v
        end
    end
    if state.settings.allIncludeLootMigrated ~= true then
        state.settings.allInclude.loot = true
        state.settings.allIncludeLootMigrated = true
        markSettingsDirty()
    end
    state.showManager = state.settings.showManager
end

local function nowTimestamp()
    return mq.TLO.Time.Time24() or os.date('%H:%M:%S')
end

local function normalizeLine(line)
    line = tostring(line or '')
    return line:gsub('^%[%d%d:%d%d:%d%d%]%s*', '')
end

local function forEachIncomingLine(text, callback)
    local incoming = tostring(text or '')
    if incoming == '' then return end

    if not incoming:find('[\r\n]') then
        callback(incoming)
        return
    end

    incoming = incoming:gsub('\r\n', '\n'):gsub('\r', '\n')
    for line in (incoming .. '\n'):gmatch('(.-)\n') do
        if line ~= '' then
            callback(line)
        end
    end
end

local function newChannel(key, name, color, echo, isBuiltin)
    return {
        key = key,
        name = name,
        color = color or colors.white,
        echo = echo or '/say',
        builtin = isBuiltin == true,
        unread = 0,
        visible = true,
        isFocused = false,
        lines = {},
        lineFirst = 1,
        lineLast = 0,
        lineCount = 0,
    }
end

local function getChannelLineCount(channel)
    return channel and channel.lineCount or 0
end

local function getChannelLine(channel, logicalIndex)
    if not channel then return nil, nil end
    if logicalIndex < 1 or logicalIndex > channel.lineCount then return nil, nil end
    local storageIndex = channel.lineFirst + logicalIndex - 1
    return channel.lines[storageIndex], storageIndex
end

local function appendChannelLine(channel, entry)
    channel.lineLast = channel.lineLast + 1
    channel.lines[channel.lineLast] = entry
    channel.lineCount = channel.lineCount + 1
end

local function compactChannelLines(channel)
    if not channel then return end
    if channel.lineFirst <= CHANNEL_REINDEX_THRESHOLD then return end

    local compacted = {}
    for i = 1, channel.lineCount do
        compacted[i] = channel.lines[channel.lineFirst + i - 1]
    end
    channel.lines = compacted
    channel.lineFirst = 1
    channel.lineLast = channel.lineCount
end

local function addChannel(key, name, color, echo, isBuiltin, defaultVisible)
    if state.channels[key] then return state.channels[key] end
    local channel = newChannel(key, name, color, echo, isBuiltin)
    if state.settings.visibleChannels[key] == nil then
        state.settings.visibleChannels[key] = defaultVisible ~= false
        markSettingsDirty()
    end
    if state.settings.allInclude[key] == nil then
        state.settings.allInclude[key] = key ~= 'mq'
        markSettingsDirty()
    end
    channel.visible = state.settings.visibleChannels[key] ~= false
    state.channels[key] = channel
    table.insert(state.channelOrder, key)
    return channel
end

local function initChannels()
    state.channels = {}
    state.channelOrder = {}
    for i = 1, #builtinChannelDefs do
        local def = builtinChannelDefs[i]
        addChannel(def.key, def.name, def.color, def.echo, true, true)
    end
end

local function trimChannelHistory(channel)
    local limit = state.settings.maxLines
    while channel.lineCount > limit do
        channel.lines[channel.lineFirst] = nil
        channel.lineFirst = channel.lineFirst + 1
        channel.lineCount = channel.lineCount - 1
    end
    if channel.lineCount == 0 then
        channel.lineFirst = 1
        channel.lineLast = 0
    else
        compactChannelLines(channel)
    end
end

local function appendToChannel(channelKey, line, color)
    local channel = state.channels[channelKey]
    if not channel then return end

    local clean = normalizeLine(line)
    local rendered = clean
    if state.settings.timestamps then
        rendered = string.format('[%s] %s', nowTimestamp(), clean)
    end

    local entry = {
        text = rendered,
        color = color or channel.color,
    }

    appendChannelLine(channel, entry)
    trimChannelHistory(channel)

    if not channel.visible or not channel.isFocused then
        channel.unread = channel.unread + 1
    end
end

local function contains(lowerLine, token)
    return string.find(lowerLine, token, 1, true) ~= nil
end

local function stripColorCodes(text)
    -- Remove EQ color sequences like: \ag \ax \a-t
    local cleaned = tostring(text or '')
    cleaned = cleaned:gsub("\\\\a#%x%x%x%x%x%x", "")
    cleaned = cleaned:gsub("\\\\a%-.", "")
    cleaned = cleaned:gsub("\\\\a.", "")
    cleaned = cleaned:gsub("^#%x%x%x%x%x%x", "")
    return cleaned
end

local function isPluginQueueAvailable()
    local plugin = mq.TLO.Plugin(ChatQueuePluginName)
    return plugin and plugin.IsLoaded and plugin.IsLoaded() == true
end

local function parsePluginValue(expr)
    local ok, value = pcall(mq.parse, expr)
    if not ok then
        return nil
    end
    return value
end

local function getPluginQueueBounds()
    if not isPluginQueueAvailable() then
        return nil, nil
    end

    local oldest = tonumber(parsePluginValue('${MQChat.Oldest}') or 0) or 0
    local newest = tonumber(parsePluginValue('${MQChat.Newest}') or 0) or 0
    if oldest == nil or newest == nil then
        return nil, nil
    end

    return oldest, newest
end

local function getPluginQueueLine(sequence)
    local text = parsePluginValue(string.format('${MQChat.Text[%d]}', sequence))
    if text == nil then
        return nil
    end

    text = tostring(text or '')
    if text == '' then
        return nil
    end

    return text
end

local function matchesMainChatFilter(lowerLine)
    if not state.settings.mainChatFilters or #state.settings.mainChatFilters == 0 then
        return false
    end
    for _, pattern in ipairs(state.settings.mainChatFilters) do
        if pattern and pattern ~= '' then
            local lowerPattern = string.lower(pattern)
            if string.find(lowerLine, lowerPattern, 1, true) then
                return true
            end
        end
    end
    return false
end

local function isPetTell(lowerLine)
    -- Exclude pet tells from Main Chat
    if contains(lowerLine, " pet tells you, '") then
        return true
    end
    return false
end

local function isPetChatLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, " pet tells you, '")
        or contains(lowerLine, " pet says '") then
        return true
    end

    return false
end

local function isRaidChatLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, " tells the raid, '")
        or contains(lowerLine, "you tell the raid, '")
        or contains(lowerLine, ' tells the raid,')
        or contains(lowerLine, 'you tell the raid,')
        or contains(lowerLine, " tells raid, '")
        or contains(lowerLine, "you tell raid, '")
        or contains(lowerLine, ' tells raid,')
        or contains(lowerLine, 'you tell raid,') then
        return true
    end

    if lowerLine:match('^%[raid%]') then
        return true
    end

    return false
end

local function isTellLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, " tells you, '")
        or contains(lowerLine, 'you told ')
        or (contains(lowerLine, "you tell ")
            and not contains(lowerLine, "you tell your party, '")
            and not contains(lowerLine, "you tell the group, '")
            and not contains(lowerLine, "you tell your guild, '")
            and not contains(lowerLine, "you tell the guild, '")
            and not contains(lowerLine, "you tell the raid, '")
            and not contains(lowerLine, "you tell your raid, '")) then
        return true
    end

    return false
end

local shouldIncludeInAll
local getOrCreateTellChannel
local extractTellPartner

local function shouldDefaultToMainChat(channelKey)
    if not state.settings.mainChatDefaultChannels then
        return false
    end
    return state.settings.mainChatDefaultChannels[channelKey] == true
end

local function routeLineToChannel(channelKey, line, color, lowerLine)
    local tellPartner = extractTellPartner(line)
    if tellPartner then
        local tellChannel = getOrCreateTellChannel(tellPartner)
        if not tellChannel.visible then
            tellChannel.visible = true
            state.settings.visibleChannels[tellChannel.key] = true
            markSettingsDirty()
        end
        appendToChannel(tellChannel.key, line, color or tellChannel.color)
    end

    -- Pet tells should never go to Main Chat
    local isPet = isPetTell(lowerLine)

    -- Check if line matches Main Chat filters and route there first
    if not isPet and channelKey ~= 'mainchat' and matchesMainChatFilter(lowerLine) then
        appendToChannel('mainchat', line, color or state.channels[channelKey].color)
        return
    end

    -- Check if this channel should default to Main Chat
    local defaultToMain = not isPet and shouldDefaultToMainChat(channelKey)

    if defaultToMain then
        -- Main Chat defaults should mirror OOC there without hiding it from the dedicated OOC tab.
        appendToChannel('mainchat', line, color or state.channels[channelKey].color)
        if channelKey == 'ooc' then
            appendToChannel('ooc', line, color or state.channels.ooc.color)
        end
    else
        -- Route to original channel
        appendToChannel(channelKey, line, color)
    end

    -- OOC tells should still show in the OOC channel even though they also behave like tells.
    if channelKey == 'tells' and contains(lowerLine, 'out of character') then
        appendToChannel('ooc', line, color or state.channels.ooc.color)
    end

    -- Determine if it should also go to All
    local includeInAll = false
    if channelKey ~= 'all' and channelKey ~= 'mainchat' then
        if state.settings.allInclude[channelKey] ~= nil then
            includeInAll = state.settings.allInclude[channelKey]
        elseif string.sub(channelKey, 1, 4) == 'ext_' then
            includeInAll = state.settings.allInclude.external ~= false
        else
            includeInAll = true
        end
    end
    if includeInAll then
        includeInAll = shouldIncludeInAll(channelKey, line, lowerLine)
    end
    if includeInAll then
        appendToChannel('all', line, color or state.channels[channelKey].color)
    end
end

local function isMQConsoleLine(lowerLine)
    if contains(lowerLine, 'macroquest') then return true end
    if contains(lowerLine, 'mq2') then return true end
    if contains(lowerLine, '[e3]') then return true end
    if lowerLine:match("^%[e3[^%]]*%]") then return true end
    if lowerLine:match("^%[mq[^%]]*%]") then return true end
    if lowerLine:match("^%[[^%]]*macroquest[^%]]*%]") then return true end
    return false
end

local function isPlayerRelevantLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, 'you ') or contains(lowerLine, 'your ') or contains(lowerLine, "you're ") then
        return true
    end

    if myNameLower ~= '' and contains(lowerLine, myNameLower) then
        return true
    end

    local petName = getPetNameLower()
    if petName ~= '' and contains(lowerLine, petName) then
        return true
    end

    return false
end

local function isExperienceGainLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, 'you gained ') and contains(lowerLine, 'experience') then
        return true
    end

    if contains(lowerLine, 'you have gained ') and contains(lowerLine, 'ability point') then
        return true
    end

    if contains(lowerLine, 'you have gained ') and contains(lowerLine, 'aa point') then
        return true
    end

    return false
end

local function isShoutLine(lowerLine)
    if lowerLine == '' then return false end

    return contains(lowerLine, " shouts, '")
        or contains(lowerLine, " shouts '")
        or contains(lowerLine, "you shout, '")
        or contains(lowerLine, "you shout '")
end

local function isDiscordRelayLine(lowerLine)
    if lowerLine == '' then return false end

    return contains(lowerLine, ' says from discord, ')
        or contains(lowerLine, ' tells from discord, ')
end

local function isTaskUpdateLine(lowerLine)
    if lowerLine == '' then return false end

    return (contains(lowerLine, "your task '") or contains(lowerLine, "your task, '"))
        and contains(lowerLine, "' has been updated.")
end

local function isChangelogLine(line, lowerLine)
    if lowerLine == '' then return false end

    local stripped = stripColorCodes(tostring(line or ''))
    if stripped:match('^#+%s*%[[^%]]+%]%s*%[[^%]]+%]%s*%[[^%]]+%]%s+') then
        return true
    end

    if stripped:match('^=+$') then
        return true
    end

    return false
end

local function isCombatOnlyLine(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, 'you perform an exceptional heal')
        or contains(lowerLine, 'you bash ')
        or contains(lowerLine, 'your bash ')
        or contains(lowerLine, ' bashes you for ')
        or contains(lowerLine, 'you shake off the stun effect')
        or contains(lowerLine, 'your spell is interrupted')
        or contains(lowerLine, ' lands a crippling blow!') then
        return true
    end

    return false
end

local function lineHasTextLinks(line)
    if not mq.ExtractLinks then return false end

    local ok, links = pcall(mq.ExtractLinks, tostring(line or ''))
    return ok and type(links) == 'table' and #links > 0
end

local function isMenuDividerLine(line)
    local stripped = stripColorCodes(tostring(line or ''))
    if stripped == '' then return false end

    return stripped:match('^[-=]+%s*.-%s*[-=]+$') ~= nil
end

local function isWhoOutputLine(line, lowerLine)
    if lowerLine == '' then return false end

    local stripped = stripColorCodes(tostring(line or ''))
    if stripped == '' then return false end

    if lowerLine == 'players in everquest:' then
        return true
    end

    if contains(lowerLine, 'your who request was cut short') then
        return true
    end

    if stripped:match('^%[%d+ [^%]]+%]%s+[%a][%w`%-]+%s+%([^%)]+%)') then
        return true
    end

    return false
end

local function isFilteredFromAll(lowerLine)
    if lowerLine == '' then return false end

    if contains(lowerLine, 'spell has worn off') then
        return true
    end

    if isPetChatLine(lowerLine) then
        return true
    end

    return false
end

shouldIncludeInAll = function(channelKey, line, lowerLine)
    if isFilteredFromAll(lowerLine) then
        return false
    end

    -- Keep "All" readable: noisy categories only go through if relevant to this character.
    if channelKey == 'combat' then
        if isCombatOnlyLine(lowerLine) then
            return false
        end
        return isPlayerRelevantLine(lowerLine)
    end
    if channelKey == 'other' then
        if lineHasTextLinks(line) or isMenuDividerLine(line) or isWhoOutputLine(line, lowerLine) then
            return true
        end
        return isPlayerRelevantLine(lowerLine)
    end
    return true
end

local function classifyLine(line, lowerLine)
    if isChangelogLine(line, lowerLine) then
        return 'system'
    end

    if isMQConsoleLine(lowerLine) then
        return 'mq'
    end

    if isRaidChatLine(lowerLine) then
        return 'raid'
    end

    if contains(lowerLine, 'you have looted ')
        or contains(lowerLine, ' has looted ') then
        return 'loot'
    end

    if contains(lowerLine, " tells the group, '")
        or contains(lowerLine, " says to the group, '")
        or contains(lowerLine, "you tell your party, '")
        or contains(lowerLine, "you tell the group, '") then
        return 'group'
    end

    if contains(lowerLine, " tells the guild, '")
        or contains(lowerLine, "you tell your guild, '")
        or contains(lowerLine, "you tell the guild, '")
        or lowerLine:match('^%[guild%]') then
        return 'guild'
    end

    if contains(lowerLine, " tells the raid, '")
        or contains(lowerLine, "you tell the raid, '")
        or contains(lowerLine, "you tell your raid, '") then
        return 'raid'
    end

    if isTellLine(lowerLine) then
        return 'tells'
    end

    -- Pet combat chatter should follow combat filters (not general say/tell).
    if contains(lowerLine, " pet tells you, 'attacking ")
        or contains(lowerLine, " pet says 'sorry, master") then
        return 'combat'
    end

    -- Healing and ability feedback are combat-relevant and should follow combat filters.
    if contains(lowerLine, 'you have healed ')
        or contains(lowerLine, ' healed you for ')
        or contains(lowerLine, 'hit points by ')
        or contains(lowerLine, 'you perform an exceptional heal')
        or contains(lowerLine, 'you shake off the stun effect')
        or contains(lowerLine, 'your spell is interrupted')
        or contains(lowerLine, ' lands a crippling blow!')
        or contains(lowerLine, "you can't use that command right now") then
        return 'combat'
    end

    if contains(lowerLine, 'out of character') then
        return 'ooc'
    end

    if isDiscordRelayLine(lowerLine) then
        return 'ooc'
    end

    if contains(lowerLine, " auctions, '")
        or contains(lowerLine, "you auction, '")
        or contains(lowerLine, "you auction to the server, '") then
        return 'auction'
    end

    if contains(lowerLine, " says, '")
        or contains(lowerLine, "you say, '")
        or contains(lowerLine, " whispers, '")
        or contains(lowerLine, " shouts, '")
        or contains(lowerLine, " shouts '")
        or contains(lowerLine, "you shout, '")
        or contains(lowerLine, "you shout '") then
        return 'say'
    end

    -- Combat/noise indicators that commonly don't include the plain "points of damage" form.
    if contains(lowerLine, 'scores a critical hit')
        or contains(lowerLine, 'deliver a critical blast')
        or contains(lowerLine, 'critical blast!')
        or contains(lowerLine, 'points of non-melee damage')
        or contains(lowerLine, 'you taunt ')
        or contains(lowerLine, 'failed to taunt')
        or contains(lowerLine, 'too distracted to use a skill')
        or contains(lowerLine, 'unleash a flurry of attacks')
        or contains(lowerLine, 'target avoided your')
        or contains(lowerLine, 'avoided your')
        or contains(lowerLine, 'anticipation falters')
        or contains(lowerLine, 'perfect rhythm falters')
        or contains(lowerLine, 'you have taken ')
        or contains(lowerLine, ' damage from ') then
        return 'combat'
    end

    if contains(lowerLine, 'points of damage')
        or contains(lowerLine, 'point of damage')
        or contains(lowerLine, 'you have slain ')
        or contains(lowerLine, 'has been slain by ')
        or contains(lowerLine, 'begins to cast')
        or contains(lowerLine, 'begin casting')
        or contains(lowerLine, 'begins casting')
        or contains(lowerLine, 'casts ')
        or contains(lowerLine, 'you try to ')
        or contains(lowerLine, 'you miss ')
        or contains(lowerLine, 'you are hit ')
        or contains(lowerLine, 'you have been struck')
        or contains(lowerLine, 'resisted your')
        or contains(lowerLine, 'you cannot see your target')
        or contains(lowerLine, 'you are too far away') then
        return 'combat'
    end

    if contains(lowerLine, 'you have ')
        or contains(lowerLine, 'you gained ')
        or contains(lowerLine, 'you gain ')
        or contains(lowerLine, 'you cannot ')
        or contains(lowerLine, 'you must ')
        or contains(lowerLine, 'spell has worn off')
        or contains(lowerLine, 'you are now ')
        or contains(lowerLine, 'you no longer ')
        or contains(lowerLine, 'loading, please wait')
        or contains(lowerLine, 'you have entered ') then
        return 'system'
    end

    return 'other'
end

local function logToSystem(fmt, ...)
    local msg = string.format(fmt, ...)
    local lower = string.lower(stripColorCodes(msg))
    routeLineToChannel('system', msg, colors.system, lower)
end

local function clearChannel(channel)
    channel.lines = {}
    channel.lineFirst = 1
    channel.lineLast = 0
    channel.lineCount = 0
    channel.unread = 0
end

local function clearAllChannels()
    for _, key in ipairs(state.channelOrder) do
        local channel = state.channels[key]
        if channel then
            clearChannel(channel)
        end
    end
end

local function normalizeExternalKey(name)
    local key = tostring(name or 'External'):lower()
    key = key:gsub('%s+', '_')
    key = key:gsub('[^%w_]', '')
    if key == '' then key = 'external' end
    return 'ext_' .. key
end

local function normalizeTellKey(name)
    local key = tostring(name or 'tell'):lower()
    key = key:gsub('%s+', '_')
    key = key:gsub('[^%w_]', '')
    if key == '' then key = 'tell' end
    return 'tell_' .. key
end

local function getOrCreateExternalChannel(name)
    local key = normalizeExternalKey(name)
    if state.channels[key] then return state.channels[key] end
    return addChannel(key, tostring(name), colors.external, '/say', false, false)
end

function getOrCreateTellChannel(name)
    local displayName = tostring(name or ''):match('^%s*(.-)%s*$') or ''
    if displayName == '' then
        displayName = 'Tell'
    end
    local key = normalizeTellKey(displayName)
    if state.channels[key] then return state.channels[key] end
    return addChannel(key, displayName, colors.tells, '/tell ' .. displayName, false, true)
end

local function canonicalizeTellPartner(name)
    local partner = tostring(name or ''):match('^%s*(.-)%s*$') or ''
    if partner == '' then
        return nil
    end

    partner = partner:gsub('%s+', ' ')
    partner = partner:gsub(',?%s+[Oo]ut of character$', '')
    partner = partner:gsub("^[^%a]+", "")

    local lowerPartner = partner:lower()
    if lowerPartner == 'your raid' or lowerPartner == 'the raid'
        or lowerPartner == 'your group' or lowerPartner == 'the group'
        or lowerPartner == 'your guild' or lowerPartner == 'the guild'
        or lowerPartner == 'your party' then
        return nil
    end
    if lowerPartner:find(' pet$', 1, false) then
        return nil
    end

    return partner
end

function extractTellPartner(line)
    local stripped = stripColorCodes(tostring(line or ''))
    if stripped == '' then return nil end

    local partner = stripped:match("^(.-) tells you, '")
        or stripped:match("^You told (.-), '")
        or stripped:match("^You tell (.-), '")

    return canonicalizeTellPartner(partner)
end

local function externalMyChatHandler(consoleName, message)
    local targetName = tostring(consoleName or 'External')
    local isMainConsole = string.lower(targetName) == 'main'
    local channel = not isMainConsole and getOrCreateExternalChannel(targetName) or nil

    forEachIncomingLine(message, function(text)
        local lower = string.lower(stripColorCodes(text))

        if isMainConsole then
            routeLineToChannel('system', text, colors.system, lower)
            return
        end

        if not channel then return end
        routeLineToChannel(channel.key, text, channel.color, lower)
    end)
end

local function processIncomingChatLine(line)
    if not line or line == '' then return end
    local lower = string.lower(stripColorCodes(line))
    local channelKey = classifyLine(line, lower)
    local color = state.channels[channelKey] and state.channels[channelKey].color or colors.white
    if isExperienceGainLine(lower) then
        color = colors.experience
    elseif isShoutLine(lower) then
        color = colors.shout
    elseif isTaskUpdateLine(lower) then
        color = colors.task
    end
    routeLineToChannel(channelKey, line, color, lower)
end

local function pollPluginChatQueue()
    local oldest, newest = getPluginQueueBounds()
    if not oldest then
        if state.chatBackend == 'plugin' then
            state.chatBackend = 'events'
            state.lastPluginSequence = nil
            logToSystem('%s plugin queue unavailable; using MQ events.', ChatQueuePluginName)
        end
        return
    end

    if state.chatBackend ~= 'plugin' then
        state.chatBackend = 'plugin'
        state.lastPluginSequence = math.max(0, oldest - 1)
        logToSystem('Using %s plugin queue for chat capture.', ChatQueuePluginName)
    end

    if newest == 0 then
        return
    end

    if state.lastPluginSequence == nil then
        state.lastPluginSequence = newest
        return
    end

    if oldest > (state.lastPluginSequence + 1) then
        local skipped = oldest - (state.lastPluginSequence + 1)
        state.lastPluginSequence = oldest - 1
        logToSystem('%s queue overran; skipped %d chat line%s.',
            ChatQueuePluginName, skipped, skipped == 1 and '' or 's')
    end

    for sequence = state.lastPluginSequence + 1, newest do
        local text = getPluginQueueLine(sequence)
        if text then
            processIncomingChatLine(text)
        end
        state.lastPluginSequence = sequence
    end
end

local function onAnyChatLine(line)
    if state.chatBackend == 'plugin' then
        return
    end
    forEachIncomingLine(line, processIncomingChatLine)
end

local function setChannelVisible(channel, visible)
    if not channel then return end
    visible = visible == true
    if channel.visible == visible then return end
    channel.visible = visible
    state.settings.visibleChannels[channel.key] = visible
    markSettingsDirty()
end

local function channelWindowName(channel)
    local unread = channel.unread > 0 and string.format(' (%d)', channel.unread) or ''
    return string.format('%s%s###%s_%s', channel.name, unread, ScriptName, channel.key)
end

local function pushCompactWindowStyle()
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, compactStyle.windowPaddingX, compactStyle.windowPaddingY)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, compactStyle.framePaddingX, compactStyle.framePaddingY)
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, compactStyle.itemSpacingX, compactStyle.itemSpacingY)
    ImGui.PushStyleVar(ImGuiStyleVar.ItemInnerSpacing, compactStyle.itemInnerSpacingX, compactStyle.itemInnerSpacingY)
    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, compactStyle.cellPaddingX, compactStyle.cellPaddingY)
end

local function popCompactWindowStyle()
    ImGui.PopStyleVar(5)
end

local function getStyleColorRGB(colorId, fallbackR, fallbackG, fallbackB)
    local r, g, b = fallbackR, fallbackG, fallbackB
    local ok, style = pcall(ImGui.GetStyle)
    if ok and style and style.Colors then
        local color = style.Colors[colorId]
        if color then
            r = color.x or color.r or r
            g = color.y or color.g or g
            b = color.z or color.b or b
        end
    end
    return r, g, b
end

local function pushOpaqueBackgroundStyle()
    local wr, wg, wb = getStyleColorRGB(ImGuiCol.WindowBg, 0.10, 0.10, 0.10)
    local cr, cg, cb = getStyleColorRGB(ImGuiCol.ChildBg, 0.10, 0.10, 0.10)
    local pr, pg, pb = getStyleColorRGB(ImGuiCol.PopupBg, 0.10, 0.10, 0.10)

    ImGui.PushStyleColor(ImGuiCol.WindowBg, wr, wg, wb, 1.0)
    ImGui.PushStyleColor(ImGuiCol.ChildBg, cr, cg, cb, 1.0)
    ImGui.PushStyleColor(ImGuiCol.PopupBg, pr, pg, pb, 1.0)
end

local function popOpaqueBackgroundStyle()
    ImGui.PopStyleColor(3)
end

local function getChannelFontScale(channel)
    if state.canWriteFontGlobal ~= false then return 1.0 end
    local scale = getBaseFontScale()
    if channel and channel.key == 'all' then
        scale = scale * ALL_CHANNEL_FONT_MULTIPLIER
    end
    return scale
end

local function getColorRGBA(color, fallback)
    local c = color or fallback or colors.white
    local r = c.x or c.r or 0.95
    local g = c.y or c.g or 0.95
    local b = c.z or c.b or 0.95
    local a = c.w or c.a or 1.0
    return r, g, b, a
end

local function sanitizeLineForCopy(rawText, alreadyColorStripped)
    local line = tostring(rawText or '')
    if not alreadyColorStripped then
        line = stripColorCodes(line)
    end
    if mq.StripTextLinks then
        local ok, stripped = pcall(mq.StripTextLinks, line)
        if ok and type(stripped) == 'string' then
            line = stripped
        end
    end
    return line
end

local function copyTextToClipboard(text)
    pcall(ImGui.SetClipboardText, tostring(text or ''))
end

local function copyLastChannelLine(channel)
    local lineCount = getChannelLineCount(channel)
    if lineCount == 0 then return end
    local entry = getChannelLine(channel, lineCount)
    local cached = entry and entry.manualRenderCache
    copyTextToClipboard((cached and cached.plainLine) or sanitizeLineForCopy(entry and entry.text or ''))
end

local function copyAllChannelLines(channel)
    local lineCount = getChannelLineCount(channel)
    if lineCount == 0 then return end
    local lines = {}
    for i = 1, lineCount do
        local entry = getChannelLine(channel, i)
        local cached = entry and entry.manualRenderCache
        lines[#lines + 1] = (cached and cached.plainLine) or sanitizeLineForCopy(entry and entry.text or '')
    end
    copyTextToClipboard(table.concat(lines, '\n'))
end

local function appendWrappedTokens(tokens, segmentType, text, linkInfo)
    local i = 1
    local textLen = #text
    while i <= textLen do
        local c = string.sub(text, i, i)
        if c == '\r' or c == '\n' then
            if c == '\r' and i < textLen and string.sub(text, i + 1, i + 1) == '\n' then
                i = i + 1
            end
            tokens[#tokens + 1] = { type = 'newline' }
        elseif c:match('%s') then
            local startIdx = i
            while i <= textLen do
                local spaceChar = string.sub(text, i, i)
                if spaceChar == '\r' or spaceChar == '\n' or not spaceChar:match('%s') then
                    break
                end
                i = i + 1
            end
            tokens[#tokens + 1] = { type = 'space', text = string.sub(text, startIdx, i - 1) }
            i = i - 1
        else
            local startIdx = i
            while i <= textLen do
                local chunkChar = string.sub(text, i, i)
                if chunkChar == '\r' or chunkChar == '\n' or chunkChar:match('%s') then
                    break
                end
                i = i + 1
            end
            tokens[#tokens + 1] = {
                type = segmentType == 'link' and 'link' or 'text',
                text = string.sub(text, startIdx, i - 1),
                link = linkInfo,
            }
            i = i - 1
        end
        i = i + 1
    end
end

local function formatNumberWithCommas(numberText)
    local len = #numberText
    if len <= 3 then
        return numberText
    end

    local out = {}
    local firstGroup = len % 3
    if firstGroup == 0 then
        firstGroup = 3
    end

    out[#out + 1] = string.sub(numberText, 1, firstGroup)
    local i = firstGroup + 1
    while i <= len do
        out[#out + 1] = ','
        out[#out + 1] = string.sub(numberText, i, i + 2)
        i = i + 3
    end

    return table.concat(out)
end

local function isAlphaNumeric(char)
    return char ~= '' and char:match('[%w]')
end

local function formatNumbersForDisplay(text)
    local source = tostring(text or '')
    if source == '' then
        return source
    end

    local formatted = {}
    local cursor = 1

    while true do
        local startIdx, endIdx = string.find(source, '%d+', cursor)
        if not startIdx then
            formatted[#formatted + 1] = string.sub(source, cursor)
            break
        end

        formatted[#formatted + 1] = string.sub(source, cursor, startIdx - 1)

        local numberText = string.sub(source, startIdx, endIdx)
        local prevChar = startIdx > 1 and string.sub(source, startIdx - 1, startIdx - 1) or ''
        local nextChar = endIdx < #source and string.sub(source, endIdx + 1, endIdx + 1) or ''
        local shouldFormat = #numberText >= 4
            and not isAlphaNumeric(prevChar)
            and not isAlphaNumeric(nextChar)
            and prevChar ~= '.'
            and nextChar ~= '.'

        formatted[#formatted + 1] = shouldFormat and formatNumberWithCommas(numberText) or numberText
        cursor = endIdx + 1
    end

    return table.concat(formatted)
end

local function buildManualRenderCache(rawText, normalizeNumbers)
    local line = stripColorCodes(tostring(rawText or ''))
    local plainLine = sanitizeLineForCopy(line, true)
    local links = nil

    if mq.ExtractLinks then
        local ok, extracted = pcall(mq.ExtractLinks, line)
        if ok and type(extracted) == 'table' and #extracted > 0 then
            links = extracted
        end
    end

    local segments = {}
    local tokens = {}
    if not links or #links == 0 then
        local displayLine = normalizeNumbers and formatNumbersForDisplay(plainLine) or plainLine
        segments[1] = { type = 'text', text = displayLine }
        return { plainLine = plainLine, displayLine = displayLine, segments = segments, tokens = tokens, hasLinks = false }
    end

    local cursor = 1
    local matchedAny = false
    for i = 1, #links do
        local info = links[i]
        local linkText = tostring(info and info.text or '')
        if linkText ~= '' then
            local s, e = string.find(plainLine, linkText, cursor, true)
            if s then
                matchedAny = true
                local prefix = string.sub(plainLine, cursor, s - 1)
                if prefix ~= '' then
                    segments[#segments + 1] = { type = 'text', text = prefix }
                    appendWrappedTokens(tokens, 'text', prefix)
                end
                segments[#segments + 1] = { type = 'link', text = linkText, link = info }
                appendWrappedTokens(tokens, 'link', linkText, info)
                cursor = e + 1
            end
        end
    end

    if not matchedAny then
        local displayLine = normalizeNumbers and formatNumbersForDisplay(plainLine) or plainLine
        segments[1] = { type = 'text', text = displayLine }
        return { plainLine = plainLine, displayLine = displayLine, segments = segments, tokens = tokens, hasLinks = false }
    end

    local suffix = string.sub(plainLine, cursor)
    if suffix ~= '' then
        segments[#segments + 1] = { type = 'text', text = suffix }
    end

    local displaySegments = {}
    local displayTokens = {}
    local displayLineParts = {}
    for i = 1, #segments do
        local segment = segments[i]
        local displayText = segment.text or ''
        if normalizeNumbers and displayText ~= '' then
            displayText = formatNumbersForDisplay(displayText)
        end
        displaySegments[#displaySegments + 1] = {
            type = segment.type,
            text = displayText,
            link = segment.link,
        }
        displayLineParts[#displayLineParts + 1] = displayText
        appendWrappedTokens(displayTokens, segment.type, displayText, segment.link)
    end

    return {
        plainLine = plainLine,
        displayLine = table.concat(displayLineParts),
        segments = displaySegments,
        tokens = displayTokens,
        hasLinks = true,
    }
end

local function getManualRenderCache(entry, normalizeNumbers)
    if not entry then
        return buildManualRenderCache('', normalizeNumbers)
    end
    local cacheKey = normalizeNumbers and 'manualRenderCacheNormalized' or 'manualRenderCache'
    if not entry[cacheKey] then
        entry[cacheKey] = buildManualRenderCache(entry.text or '', normalizeNumbers)
    end
    return entry[cacheKey]
end

local function getTokenWidth(token, scaleKey)
    if not token then return 0 end

    local cachedWidths = token.widthCache
    if not cachedWidths then
        cachedWidths = {}
        token.widthCache = cachedWidths
    end

    local cached = cachedWidths[scaleKey]
    if cached ~= nil then
        return cached
    end

    local tokenText = tostring(token.text or '')
    cached = tonumber((select(1, ImGui.CalcTextSize(tokenText)))) or 0
    cachedWidths[scaleKey] = cached
    return cached
end

local function drawTextSegment(text, r, g, b, a, first)
    if not first then
        ImGui.SameLine(0, 0)
    end
    ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
    ImGui.TextUnformatted(text)
    ImGui.PopStyleColor()
end

local function drawLinkSegment(linkInfo, linkText, first)
    if not first then
        ImGui.SameLine(0, 0)
    end
    local r, g, b, a = getColorRGBA(colors.link, colors.white)
    ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
    ImGui.TextUnformatted(linkText)
    ImGui.PopStyleColor()
    if ImGui.IsItemHovered() then
        ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)
        if ImGui.IsMouseReleased(ImGuiMouseButton.Left) then
            pcall(mq.ExecuteTextLink, linkInfo)
        end
    end
end

local function drawWrappedToken(token, textColor, first)
    local tokenText = tostring(token and token.text or '')
    if tokenText == '' then return end

    if token and token.type == 'link' then
        drawLinkSegment(token.link, tokenText, first)
        return
    end

    local r, g, b, a = getColorRGBA(textColor, colors.white)
    drawTextSegment(tokenText, r, g, b, a, first)
end

local function drawRichLine(entry, color, lineId, normalizeNumbers, scaleKey)
    local cache = getManualRenderCache(entry, normalizeNumbers)
    local plainLine = cache.plainLine or ''
    local displayLine = cache.displayLine or plainLine
    local r, g, b, a = getColorRGBA(color, colors.white)
    ImGui.PushID(lineId or 0)
    ImGui.BeginGroup()

    if not cache.hasLinks then
        ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
        ImGui.PushTextWrapPos(0.0)
        ImGui.TextUnformatted(displayLine)
        ImGui.PopTextWrapPos()
        ImGui.PopStyleColor()
    else
        local tokens = cache.tokens or {}
        local wrapWidth = math.max(1, tonumber((select(1, ImGui.GetContentRegionAvail()))) or 1)
        local firstOnLine = true
        local lineWidth = 0

        for i = 1, #tokens do
            local token = tokens[i]
            local tokenType = token and token.type or 'text'
            local tokenText = tostring(token and token.text or '')

            if tokenType == 'newline' then
                firstOnLine = true
                lineWidth = 0
            elseif tokenText ~= '' then
                local tokenWidth = getTokenWidth(token, scaleKey)
                if tokenType ~= 'space' and not firstOnLine and (lineWidth + tokenWidth) > wrapWidth then
                    firstOnLine = true
                    lineWidth = 0
                end

                if not (tokenType == 'space' and firstOnLine) then
                    drawWrappedToken(token, color, firstOnLine)
                    firstOnLine = false
                    lineWidth = lineWidth + tokenWidth
                end
            end
        end
        if #tokens == 0 then
            ImGui.PushStyleColor(ImGuiCol.Text, r, g, b, a)
            ImGui.PushTextWrapPos(0.0)
            ImGui.TextUnformatted(displayLine)
            ImGui.PopTextWrapPos()
            ImGui.PopStyleColor()
        end
    end

    ImGui.EndGroup()
    if ImGui.BeginPopupContextItem('line_ctx') then
        if ImGui.MenuItem('Copy Line') then
            copyTextToClipboard(plainLine)
        end
        ImGui.EndPopup()
    end
    ImGui.PopID()
end

local function estimateWrappedTokenLineCount(cache, wrapWidth, scaleKey)
    local tokens = cache.tokens or {}
    if #tokens == 0 then
        return 1
    end

    local lineCount = 1
    local firstOnLine = true
    local lineWidth = 0

    for i = 1, #tokens do
        local token = tokens[i]
        local tokenType = token and token.type or 'text'
        local tokenText = tostring(token and token.text or '')

        if tokenType == 'newline' then
            lineCount = lineCount + 1
            firstOnLine = true
            lineWidth = 0
        elseif tokenText ~= '' then
            local tokenWidth = getTokenWidth(token, scaleKey)
            if tokenType ~= 'space' and not firstOnLine and (lineWidth + tokenWidth) > wrapWidth then
                lineCount = lineCount + 1
                firstOnLine = true
                lineWidth = 0
            end

            if not (tokenType == 'space' and firstOnLine) then
                firstOnLine = false
                lineWidth = lineWidth + tokenWidth
            end
        end
    end

    return math.max(1, lineCount)
end

local function estimateRichLineHeight(entry, normalizeNumbers, scaleKey, wrapWidth, lineHeight)
    if not entry then
        return lineHeight
    end

    local cache = getManualRenderCache(entry, normalizeNumbers)
    local cacheKey = string.format('%d:%d', scaleKey or 100, math.floor((wrapWidth or 1) + 0.5))
    local heightCacheKey = normalizeNumbers and 'heightEstimateCacheNormalized' or 'heightEstimateCache'
    entry[heightCacheKey] = entry[heightCacheKey] or {}

    local cachedHeight = entry[heightCacheKey][cacheKey]
    if cachedHeight ~= nil then
        return cachedHeight
    end

    local estimatedHeight = lineHeight
    if cache.hasLinks then
        estimatedHeight = estimateWrappedTokenLineCount(cache, wrapWidth, scaleKey) * lineHeight
    else
        local _, textHeight = ImGui.CalcTextSize(cache.displayLine or cache.plainLine or '', false, wrapWidth)
        estimatedHeight = tonumber(textHeight) or lineHeight
    end

    estimatedHeight = math.max(lineHeight, estimatedHeight)
    entry[heightCacheKey][cacheKey] = estimatedHeight
    return estimatedHeight
end

local function drawChannelLines(channel)
    local stickToBottom = false
    local normalizeNumbers = channel.key == 'all'
    if state.settings.autoScroll then
        local maxY = ImGui.GetScrollMaxY()
        local curY = ImGui.GetScrollY()
        local bottomThreshold = math.max(2.0, (tonumber(ImGui.GetTextLineHeightWithSpacing()) or 0) * 2)
        stickToBottom = (maxY - curY) <= bottomThreshold
    end

    local lineCount = getChannelLineCount(channel)
    if lineCount > 0 then
        local scale = getChannelFontScale(channel)
        local scaleKey = math.floor((scale * 100) + 0.5)
        local wrapWidth = math.max(1, tonumber((select(1, ImGui.GetContentRegionAvail()))) or 1)
        local viewportHeight = math.max(1, tonumber((select(2, ImGui.GetContentRegionAvail()))) or tonumber(ImGui.GetWindowHeight()) or 1)
        local lineHeight = math.max(1, tonumber(ImGui.GetTextLineHeightWithSpacing()) or 1)
        local overscanHeight = lineHeight * VIRTUALIZATION_OVERSCAN_LINES
        local viewTop = math.max(0, tonumber(ImGui.GetScrollY()) or 0)
        local viewBottom = viewTop + viewportHeight
        local visibleStart = 1
        local visibleEnd = lineCount
        local topSpacerHeight = 0
        local totalHeight = 0
        local foundVisibleStart = false

        for i = 1, lineCount do
            local entry = select(1, getChannelLine(channel, i))
            local entryHeight = estimateRichLineHeight(entry, normalizeNumbers, scaleKey, wrapWidth, lineHeight)
            local lineTop = totalHeight
            local lineBottom = totalHeight + entryHeight

            if not foundVisibleStart and lineBottom >= (viewTop - overscanHeight) then
                visibleStart = i
                topSpacerHeight = lineTop
                foundVisibleStart = true
            end
            if lineTop <= (viewBottom + overscanHeight) then
                visibleEnd = i
            end

            totalHeight = lineBottom
        end

        if visibleStart > 1 then
            ImGui.Dummy(0, topSpacerHeight)
        end

        local renderedHeight = 0
        for i = visibleStart, visibleEnd do
            local entry, storageIndex = getChannelLine(channel, i)
            if entry then
                drawRichLine(entry, entry.color or channel.color, storageIndex or i, normalizeNumbers, scaleKey)
                renderedHeight = renderedHeight + estimateRichLineHeight(entry, normalizeNumbers, scaleKey, wrapWidth, lineHeight)
            end
        end

        local bottomSpacerHeight = math.max(0, totalHeight - topSpacerHeight - renderedHeight)
        if bottomSpacerHeight > 0 then
            ImGui.Dummy(0, bottomSpacerHeight)
        end
    end

    if state.settings.autoScroll and stickToBottom and lineCount > 0 then
        ImGui.SetScrollHereY(1.0)
    end
end

local function pushChannelGlobalFontScale(channel)
    if state.canWriteFontGlobal ~= true then return nil end
    local io = ImGui.GetIO()
    if not io then return nil end

    local target = getBaseFontScale()
    if channel and channel.key == 'all' then
        target = target * ALL_CHANNEL_FONT_MULTIPLIER
    end

    local previous = io.FontGlobalScale or 1.0
    if previous == target then return nil end

    local ok = pcall(function()
        io.FontGlobalScale = target
    end)
    if ok then
        return previous
    end

    state.canWriteFontGlobal = false
    return nil
end

local function popChannelGlobalFontScale(previous)
    if previous == nil then return end
    local io = ImGui.GetIO()
    if not io then return end
    pcall(function()
        io.FontGlobalScale = previous
    end)
end

local function drawChannelWindow(channel)
    if not channel.visible then return end

    local flags = bit32.bor(ImGuiWindowFlags.NoScrollbar)
    if state.settings.lockWindow then
        flags = bit32.bor(flags, ImGuiWindowFlags.NoMove)
    end

    local previousGlobalScale = pushChannelGlobalFontScale(channel)
    pushOpaqueBackgroundStyle()
    ImGui.SetNextWindowSize(ImVec2(560, 340), ImGuiCond.FirstUseEver)
    local open, draw = ImGui.Begin(channelWindowName(channel), channel.visible, flags)
    if open ~= channel.visible then
        setChannelVisible(channel, open)
    end
    if not open then
        ImGui.End()
        popOpaqueBackgroundStyle()
        popChannelGlobalFontScale(previousGlobalScale)
        return
    end

    channel.isFocused = ImGui.IsWindowFocused(0)
    if channel.isFocused then
        channel.unread = 0
        state.lastFocusedChannelKey = channel.key
    end

    if draw then
        pushCompactWindowStyle()
        if ImGui.BeginChild('##msg_' .. channel.key, 0, 0, 0, ImGuiWindowFlags.None) then
            local channelFontScale = getChannelFontScale(channel)
            if channelFontScale ~= 1.0 then
                -- Apply channel-specific scaling to the scrolling child content.
                ImGui.SetWindowFontScale(channelFontScale)
            end

            drawChannelLines(channel)
            if ImGui.BeginPopupContextWindow('ctx_' .. channel.key) then
                if ImGui.MenuItem('Clear') then
                    clearChannel(channel)
                end
                if ImGui.MenuItem('Hide Window') then
                    setChannelVisible(channel, false)
                end
                if ImGui.MenuItem('Copy Last Line') then
                    copyLastChannelLine(channel)
                end
                if ImGui.MenuItem('Copy All Lines') then
                    copyAllChannelLines(channel)
                end
                -- Add filter option for All window
                if channel.key == 'all' then
                    ImGui.Separator()
                    if ImGui.MenuItem('Filter lines like this...') then
                        state.filterPopupOpen = true
                        state.filterPopupPattern = ''
                        state.filterPopupLinePreview = ''
                        -- Try to get selected text or use a placeholder
                        local clipboard = ImGui.GetClipboardText()
                        if clipboard and clipboard ~= '' then
                            state.filterPopupLinePreview = clipboard:sub(1, 100)
                        end
                    end
                end
                ImGui.EndPopup()
            end

            if channelFontScale ~= 1.0 then
                ImGui.SetWindowFontScale(1.0)
            end
            ImGui.EndChild()
        end
        popCompactWindowStyle()
    end

    ImGui.End()
    popOpaqueBackgroundStyle()
    popChannelGlobalFontScale(previousGlobalScale)
end

local function drawManagerWindow()
    if not state.showManager then return end

    local managerFlags = bit32.bor(ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.AlwaysAutoResize)
    if state.settings.lockWindow then
        managerFlags = bit32.bor(managerFlags, ImGuiWindowFlags.NoMove)
    end

    pushOpaqueBackgroundStyle()
    ImGui.SetNextWindowSize(ImVec2(300, 460), ImGuiCond.FirstUseEver)
    local open, draw = ImGui.Begin(string.format('EZChat Manager###%s_Manager', ScriptName), state.showManager, managerFlags)
    if open ~= state.showManager then
        state.showManager = open
        state.settings.showManager = open
        markSettingsDirty()
    end
    if not open then
        ImGui.End()
        popOpaqueBackgroundStyle()
        return
    end

    if draw then
        pushCompactWindowStyle()
        if state.canWriteFontGlobal == false then
            ImGui.SetWindowFontScale(getBaseFontScale())
        end

        ImGui.Text('Drag chat windows onto each other to dock.')
        ImGui.Separator()

        if ImGui.Button('Open All') then
            for _, key in ipairs(state.channelOrder) do
                setChannelVisible(state.channels[key], true)
            end
        end
        ImGui.SameLine()
        if ImGui.Button('Close All') then
            for _, key in ipairs(state.channelOrder) do
                setChannelVisible(state.channels[key], false)
            end
        end
        ImGui.SameLine()
        if ImGui.Button('Clear All') then
            clearAllChannels()
        end

        ImGui.Separator()
        ImGui.Text('Windows')
        for _, key in ipairs(state.channelOrder) do
            local channel = state.channels[key]
            if channel then
                local label = channel.unread > 0 and string.format('%s (%d)', channel.name, channel.unread) or channel.name
                local newVisible = ImGui.Checkbox(label .. '##visible_' .. key, channel.visible)
                if newVisible ~= channel.visible then
                    setChannelVisible(channel, newVisible)
                end
            end
        end

        ImGui.Separator()
        ImGui.Text('Main Chat Filters')
        ImGui.TextDisabled('Lines matching these patterns go to Main Chat instead of All.')
        if not state.settings.mainChatFilters or #state.settings.mainChatFilters == 0 then
            ImGui.TextDisabled('No filters configured.')
        else
            for i = #state.settings.mainChatFilters, 1, -1 do
                local filter = state.settings.mainChatFilters[i]
                ImGui.Text('"' .. filter .. '"')
                ImGui.SameLine(ImGui.GetContentRegionAvail() - 60)
                if ImGui.Button('Remove##' .. i, ImVec2(60, 0)) then
                    removeMainChatFilter(i)
                end
            end
        end
        if ImGui.Button('Manage Filters##mainchat', ImVec2(-1, 0)) then
            state.filterPopupOpen = true
            state.filterPopupPattern = ''
            state.filterPopupLinePreview = ''
        end

        ImGui.Separator()
        ImGui.Text('Main Chat Default Channels')
        ImGui.TextDisabled('Selected channels route to Main Chat instead of their own window.')
        local mainChatChannels = {'tells', 'say', 'ooc', 'raid', 'guild'}
        for _, key in ipairs(mainChatChannels) do
            local channel = state.channels[key]
            if channel then
                local current = state.settings.mainChatDefaultChannels[key] == true
                local updated = ImGui.Checkbox(channel.name .. '##mainchat_' .. key, current)
                if updated ~= current then
                    state.settings.mainChatDefaultChannels[key] = updated
                    markSettingsDirty()
                end
            end
        end

        ImGui.Separator()
        ImGui.Text('All Feed Filters')
        for _, key in ipairs(state.channelOrder) do
            local channel = state.channels[key]
            if channel and key ~= 'all' and key ~= 'mainchat' and string.sub(key, 1, 4) ~= 'ext_' and string.sub(key, 1, 5) ~= 'tell_' then
                local current = state.settings.allInclude[key] ~= false
                local updated = ImGui.Checkbox(channel.name .. '##all_' .. key, current)
                if updated ~= current then
                    state.settings.allInclude[key] = updated
                    markSettingsDirty()
                end
            end
        end
        local currentExt = state.settings.allInclude.external ~= false
        local updatedExt = ImGui.Checkbox('External##all_external', currentExt)
        if updatedExt ~= currentExt then
            state.settings.allInclude.external = updatedExt
            markSettingsDirty()
        end

        ImGui.Separator()
        local newScale = ImGui.SliderFloat('Font Scale##Manager', state.settings.fontScale, 0.75, 2.25)
        if newScale ~= state.settings.fontScale then
            state.settings.fontScale = newScale
            markSettingsDirty()
        end
        local newMax = ImGui.SliderInt('Max Lines##Manager', state.settings.maxLines, 250, 10000)
        if newMax ~= state.settings.maxLines then
            state.settings.maxLines = newMax
            markSettingsDirty()
        end
        local newAuto = ImGui.Checkbox('Auto Scroll##Manager', state.settings.autoScroll)
        if newAuto ~= state.settings.autoScroll then
            state.settings.autoScroll = newAuto
            markSettingsDirty()
        end
        local newTs = ImGui.Checkbox('Timestamps##Manager', state.settings.timestamps)
        if newTs ~= state.settings.timestamps then
            state.settings.timestamps = newTs
            markSettingsDirty()
        end
        local newLock = ImGui.Checkbox('Lock Windows##Manager', state.settings.lockWindow)
        if newLock ~= state.settings.lockWindow then
            state.settings.lockWindow = newLock
            markSettingsDirty()
        end

        if state.canWriteFontGlobal == false then
            ImGui.SetWindowFontScale(1.0)
        end
        popCompactWindowStyle()
    end

    ImGui.End()
    popOpaqueBackgroundStyle()
end

local function addMainChatFilter(pattern)
    if not pattern or pattern == '' then return end
    if not state.settings.mainChatFilters then
        state.settings.mainChatFilters = {}
    end
    -- Check if already exists
    for _, existing in ipairs(state.settings.mainChatFilters) do
        if existing == pattern then return end
    end
    table.insert(state.settings.mainChatFilters, pattern)
    markSettingsDirty()
end

local function removeMainChatFilter(index)
    if not state.settings.mainChatFilters then return end
    table.remove(state.settings.mainChatFilters, index)
    markSettingsDirty()
end

local function drawFilterPopup()
    if not state.filterPopupOpen then return end

    local open = true
    pushOpaqueBackgroundStyle()
    ImGui.SetNextWindowSize(ImVec2(500, 350), ImGuiCond.FirstUseEver)
    open, state.filterPopupOpen = ImGui.Begin('Filter to Main Chat###ezchat_filter_popup', open, ImGuiWindowFlags.NoCollapse)

    if open and state.filterPopupOpen then
        pushCompactWindowStyle()

        ImGui.Text('Enter a pattern to filter matching lines to Main Chat:')
        ImGui.Spacing()

        -- Pattern input
        ImGui.SetNextItemWidth(-1)
        local changed
        state.filterPopupPattern, changed = ImGui.InputText('Pattern##filter_pattern', state.filterPopupPattern, 256)

        ImGui.Spacing()
        if ImGui.Button('Add Filter', ImVec2(120, 0)) then
            if state.filterPopupPattern and state.filterPopupPattern ~= '' then
                addMainChatFilter(state.filterPopupPattern)
                state.filterPopupPattern = ''
            end
        end

        ImGui.SameLine()
        if ImGui.Button('Close', ImVec2(120, 0)) then
            state.filterPopupOpen = false
        end

        ImGui.Separator()
        ImGui.Text('Active Filters (matching lines go to Main Chat):')
        ImGui.Spacing()

        if not state.settings.mainChatFilters or #state.settings.mainChatFilters == 0 then
            ImGui.TextDisabled('No filters configured.')
        else
            for i = #state.settings.mainChatFilters, 1, -1 do
                local filter = state.settings.mainChatFilters[i]
                ImGui.Text('"' .. filter .. '"')
                ImGui.SameLine(ImGui.GetContentRegionAvail() - 60)
                if ImGui.Button('Remove##' .. i, ImVec2(60, 0)) then
                    removeMainChatFilter(i)
                end
            end
        end

        popCompactWindowStyle()
    end

    ImGui.End()
    popOpaqueBackgroundStyle()

    -- Close if window was X'd out
    if not open then
        state.filterPopupOpen = false
    end
end

local function renderUI()
    applyGlobalFontScale()

    drawManagerWindow()
    for i = 1, #state.channelOrder do
        local key = state.channelOrder[i]
        local channel = state.channels[key]
        if channel and key ~= 'all' then
            drawChannelWindow(channel)
        end
    end

    local allChannel = state.channels.all
    if allChannel then
        drawChannelWindow(allChannel)
    end

    drawFilterPopup()
end

local function tryParseBool(token, current)
    if not token or token == '' then return not current, true end
    token = string.lower(token)
    if token == 'on' or token == 'true' or token == '1' then return true, true end
    if token == 'off' or token == 'false' or token == '0' then return false, true end
    if token == 'toggle' then return not current, true end
    return current, false
end

local function findChannelByName(name)
    local needle = string.lower(name or '')
    for _, key in ipairs(state.channelOrder) do
        local channel = state.channels[key]
        if channel then
            if string.lower(channel.name) == needle or string.lower(channel.key) == needle then
                return channel
            end
        end
    end
    return nil
end

local function printHelp()
    logToSystem('Commands:')
    logToSystem('/ezchat                      - Toggle manager window')
    logToSystem('/ezchat show [all|manager|channel]')
    logToSystem('/ezchat hide [all|manager|channel]')
    logToSystem('/ezchat lock [on|off]  - Toggle lock')
    logToSystem('/ezchat timestamps [on|off]')
    logToSystem('/ezchat autoscroll [on|off]')
    logToSystem('/ezchat scale <0.75-2.25>')
    logToSystem('/ezchat lines <250-10000>')
    logToSystem('/ezchat allinclude <channel|external> [on|off|toggle]')
    logToSystem('/ezchat clear [all|channel]')
    logToSystem('/ezchat reset          - Restore default settings')
    logToSystem('/ezchat manager [on|off|toggle]')
    logToSystem('/ezchat exit           - Stop script')
    logToSystem('')
    logToSystem('Main Chat: Right-click in "All" window and select "Filter lines like this"')
    logToSystem('to route matching lines to the Main Chat window instead.')
end

local function commandHandler(...)
    local args = { ... }
    local command = string.lower(args[1] or '')
    local arg2 = string.lower(args[2] or '')

    if command == '' then
        state.showManager = not state.showManager
        state.settings.showManager = state.showManager
        markSettingsDirty()
        return
    end

    if command == 'show' or command == 'ui' then
        if arg2 == '' or arg2 == 'manager' then
            state.showManager = true
            state.settings.showManager = true
            markSettingsDirty()
            return
        end
        if arg2 == 'all' then
            for _, key in ipairs(state.channelOrder) do
                setChannelVisible(state.channels[key], true)
            end
            state.showManager = true
            state.settings.showManager = true
            markSettingsDirty()
            return
        end
        local channel = findChannelByName(arg2)
        if channel then
            setChannelVisible(channel, true)
        else
            logToSystem('No channel named "%s".', tostring(args[2]))
        end
        return
    end

    if command == 'hide' then
        if arg2 == '' or arg2 == 'manager' then
            state.showManager = false
            state.settings.showManager = false
            markSettingsDirty()
            return
        end
        if arg2 == 'all' then
            for _, key in ipairs(state.channelOrder) do
                setChannelVisible(state.channels[key], false)
            end
            return
        end
        local channel = findChannelByName(arg2)
        if channel then
            setChannelVisible(channel, false)
        else
            logToSystem('No channel named "%s".', tostring(args[2]))
        end
        return
    end

    if command == 'toggle' then
        if arg2 == '' or arg2 == 'manager' then
            state.showManager = not state.showManager
            state.settings.showManager = state.showManager
            markSettingsDirty()
            return
        end
        if arg2 == 'all' then
            local anyHidden = false
            for _, key in ipairs(state.channelOrder) do
                if not state.channels[key].visible then
                    anyHidden = true
                    break
                end
            end
            for _, key in ipairs(state.channelOrder) do
                setChannelVisible(state.channels[key], anyHidden)
            end
            return
        end
        local channel = findChannelByName(arg2)
        if channel then
            setChannelVisible(channel, not channel.visible)
        else
            logToSystem('No channel named "%s".', tostring(args[2]))
        end
        return
    end

    if command == 'manager' then
        local value, ok = tryParseBool(args[2], state.showManager)
        if ok then
            state.showManager = value
            state.settings.showManager = value
            markSettingsDirty()
        else
            logToSystem('Invalid manager value: %s', tostring(args[2]))
        end
        return
    end

    if command == 'lock' then
        local value, ok = tryParseBool(args[2], state.settings.lockWindow)
        if ok then
            state.settings.lockWindow = value
            markSettingsDirty()
        else
            logToSystem('Invalid value for lock: %s', tostring(args[2]))
        end
        return
    end

    if command == 'timestamps' then
        local value, ok = tryParseBool(args[2], state.settings.timestamps)
        if ok then
            state.settings.timestamps = value
            markSettingsDirty()
        else
            logToSystem('Invalid value for timestamps: %s', tostring(args[2]))
        end
        return
    end

    if command == 'autoscroll' then
        local value, ok = tryParseBool(args[2], state.settings.autoScroll)
        if ok then
            state.settings.autoScroll = value
            markSettingsDirty()
        else
            logToSystem('Invalid value for autoscroll: %s', tostring(args[2]))
        end
        return
    end

    if command == 'scale' then
        local value = tonumber(args[2] or '')
        if not value then
            logToSystem('Usage: /ezchat scale <0.75-2.25>')
            return
        end
        state.settings.fontScale = clamp(value, 0.75, 2.25)
        markSettingsDirty()
        return
    end

    if command == 'lines' then
        local value = tonumber(args[2] or '')
        if not value then
            logToSystem('Usage: /ezchat lines <250-10000>')
            return
        end
        state.settings.maxLines = clamp(math.floor(value), 250, 10000)
        markSettingsDirty()
        return
    end

    if command == 'allinclude' then
        local target = string.lower(args[2] or '')
        if target == '' then
            logToSystem('Usage: /ezchat allinclude <channel|external> [on|off|toggle]')
            return
        end

        local includeKey = nil
        if target == 'external' then
            includeKey = 'external'
        else
            local channel = findChannelByName(target)
            if channel and channel.key ~= 'all' and channel.key ~= 'mainchat' then
                includeKey = channel.key
            elseif state.settings.allInclude[target] ~= nil and target ~= 'all' and target ~= 'mainchat' then
                includeKey = target
            end
        end

        if not includeKey then
            logToSystem('No filter target named "%s".', tostring(args[2]))
            return
        end

        local current = state.settings.allInclude[includeKey] ~= false
        local value, ok = tryParseBool(args[3], current)
        if not ok then
            logToSystem('Invalid value: %s (use on/off/toggle).', tostring(args[3]))
            return
        end
        state.settings.allInclude[includeKey] = value
        markSettingsDirty()
        logToSystem('All feed include for %s: %s', includeKey, value and 'ON' or 'OFF')
        return
    end

    if command == 'clear' then
        local target = args[2]
        if not target then
            local focused = state.channels[state.lastFocusedChannelKey]
            if focused then
                clearChannel(focused)
            end
            return
        end

        if string.lower(target) == 'all' then
            clearAllChannels()
            return
        end

        local channel = findChannelByName(target)
        if channel then
            clearChannel(channel)
        else
            logToSystem('No channel named "%s".', tostring(target))
        end
        return
    end

    if command == 'reset' then
        for k, v in pairs(defaults) do
            state.settings[k] = v
        end
        state.showManager = state.settings.showManager
        markSettingsDirty()
        logToSystem('Settings reset to defaults.')
        return
    end

    if command == 'help' then
        printHelp()
        return
    end

    if command == 'exit' or command == 'quit' then
        state.running = false
        return
    end

    logToSystem('Unknown command: %s', tostring(args[1]))
    logToSystem('Use /ezchat help')
end

local function installCompatibilityHandler()
    _G.MyUI_MyChatLoaded = true
    _G.MyUI_MyChatHandler = externalMyChatHandler
end

local function restoreCompatibilityHandler()
    _G.MyUI_MyChatLoaded = state.prevMyChatLoaded
    _G.MyUI_MyChatHandler = state.prevMyChatHandler
end

local function cleanup()
    saveSettings(true)
    if state.prevFontGlobalScale ~= nil then
        local io = ImGui.GetIO()
        if io then
            pcall(function()
                io.FontGlobalScale = state.prevFontGlobalScale
            end)
        end
    end
    pcall(mq.unbind, '/ezchat')
    pcall(mq.unevent, eventName)
    if mq.imgui and mq.imgui.destroy then
        pcall(mq.imgui.destroy, imguiName)
    end
    restoreCompatibilityHandler()
end

local function init()
    loadSettings()
    initChannels()

    mq.event(eventName, '#*#', onAnyChatLine, { keepLinks = true })
    mq.bind('/ezchat', commandHandler)
    installCompatibilityHandler()
    mq.imgui.init(imguiName, renderUI)

    logToSystem('Loaded %s v%s', ScriptName, Version)
    logToSystem('Use /ezchat help for commands')
end

local function main()
    init()
    while state.running do
        pollPluginChatQueue()
        for _ = 1, EVENT_DRAIN_PASSES do
            mq.doevents()
        end
        saveSettings(false)
        mq.delay(EVENT_LOOP_DELAY_MS)
    end
    cleanup()
end

main()
