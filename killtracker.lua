local mq = require('mq')
local ImGui = require('ImGui')
local json = require('dkjson')
local ok_pm, PackageMan = pcall(require, 'mq.PackageMan')
local sqlite3
if ok_pm then
    sqlite3 = PackageMan.Require('lsqlite3')
else
    error('Failed to load mq.PackageMan')
end

-- Kill Tracker Script
-- Tracks kill counts persistently with ImGui interface using SQLite

-- Configuration
local config = {
    showWindow = true,
    windowTitle = "Kill Tracker",
    configFile = mq.configDir .. '/killtracker_config.json',
    dbFile = mq.configDir .. '/killtracker_data.db',
    excludedMobNames = {},
    trackAggressiveOnly = true,
    selectedTimeFilter = 'all_time',
    selectedZone = nil,
    miniMode = false,
    timerMode = false
}

local timeFilterOptions = {
    { id = 'last_30_min', label = 'Last 30 Minutes' },
    { id = 'last_60_min', label = 'Last 60 Minutes' },
    { id = 'today', label = 'Today' },
    { id = 'yesterday', label = 'Yesterday' },
    { id = 'this_week', label = 'This Week' },
    { id = 'this_month', label = 'This Month' },
    { id = 'all_time', label = 'All Time' }
}
local defaultTimeFilter = 'all_time'
local secondsPerDay = 86400

local function isValidTimeFilter(filterId)
    if not filterId then return false end
    for _, option in ipairs(timeFilterOptions) do
        if option.id == filterId then
            return true
        end
    end
    return false
end

local filteredZoneData = {
    zone = nil,
    timeFilter = nil,
    rangeStart = nil,
    rangeEnd = nil,
    total = 0,
    kills = {}
}
local filteredZoneDataDirty = true
local zoneList = {}
local zoneListDirty = true

local db = nil
local sessionKills = 0
local sessionMobKills = {}
local sessionZoneKills = {}
local sessionZoneDurations = {}
local lastKillTime = 0
local totalKills = 0
local killData = {}
local trapStats = {
    totalSprung = 0,
    spawns = {
        ["a Blightfire Ambusher"] = 0,
        ["Chief Drakkar"] = 0
    }
}
local currentZoneName = nil
local currentZoneStartTime = nil
local activeZoneSessionId = nil
local zoneTimeCache = {}
local shouldExit = false

-- Bonus group tracking for Beasts' Domain
local BEASTS_DOMAIN_ZONE = "Beasts' Domain"
local bonusGroupPopupOpen = false
local currentBonusGroup = ""
local selectedBonusGroupIndex = 0

local function clearBonusGroupTracking()
    currentBonusGroup = ''
    bonusGroupPopupOpen = false
end

local function createKillEntry()
    return { count = 0, zones = {} }
end

local function ensureKillEntry(mobName)
    local entry = killData[mobName]
    if not entry then
        entry = createKillEntry()
        killData[mobName] = entry
    end
    entry.count = entry.count or 0
    entry.zones = entry.zones or {}
    return entry
end

local function ensureSessionKillEntry(mobName)
    local entry = sessionMobKills[mobName]
    if not entry then
        entry = createKillEntry()
        sessionMobKills[mobName] = entry
    end
    entry.count = entry.count or 0
    entry.zones = entry.zones or {}
    return entry
end

local function normalizeZoneName(zoneName)
    if not zoneName or zoneName == '' then
        return 'Unknown'
    end
    return zoneName
end

local aggressiveNameInfo = {}
local trackedAggressiveIDs = {}
local aggressiveCacheTimeout = 120 -- seconds to consider a mob "recently aggressive"

local function normalizeMobName(mobName)
    if not mobName then return '' end
    local trimmedName = mobName:match('^%s*(.-)%s*$')
    if not trimmedName then return '' end
    return trimmedName
end

local function getMobKey(mobName)
    local normalizedName = normalizeMobName(mobName)
    if normalizedName == '' then return '' end
    return normalizedName:lower()
end

-- Determine if the slain target is a player's pet ("Bob's pet")
local function isPetEntity(mobName)
    local normalizedName = normalizeMobName(mobName)
    if normalizedName == '' then return false end
    return normalizedName:lower():match("['`]s%s*pet$") ~= nil
end

local function isExcludedMob(mobName)
    local key = getMobKey(mobName)
    if key == '' then return false end
    local excluded = config.excludedMobNames or {}
    return excluded[key] == true
end

local function normalizeExcludedConfig()
    local normalized = {}
    local existing = config.excludedMobNames
    if type(existing) == 'table' then
        for key, value in pairs(existing) do
            local name = nil
            if type(key) == 'string' and type(value) == 'boolean' then
                if value then name = key end
            elseif type(key) == 'string' and type(value) == 'string' then
                if value == 'true' or value == '1' then
                    name = key
                end
            elseif type(key) == 'number' and type(value) == 'string' then
                name = value
            elseif type(value) == 'string' and (value == 'true' or value == '1') then
                name = key
            elseif type(value) == 'table' and type(value.name) == 'string' then
                name = value.name
            end

            if name then
                local normalizedKey = getMobKey(name)
                if normalizedKey ~= '' then
                    normalized[normalizedKey] = true
                end
            end
        end
    end
    config.excludedMobNames = normalized
end

local function pruneAggressiveInfo(now)
    for name, info in pairs(aggressiveNameInfo) do
        if info.count <= 0 and (now - info.lastSeen) > aggressiveCacheTimeout then
            aggressiveNameInfo[name] = nil
        end
    end
end

local function updateAggressiveMobCache()
    if not config.trackAggressiveOnly then
        aggressiveNameInfo = {}
        trackedAggressiveIDs = {}
        return
    end

    local now = os.time()
    local seenIDs = {}
    local slots = mq.TLO.Me.XTargetSlots() or 0
    if slots > 0 then
        for i = 1, slots do
            local xtarg = mq.TLO.Me.XTarget(i)
            if xtarg and xtarg.ID and xtarg.ID() > 0 then
                local targetType = xtarg.TargetType and xtarg.TargetType() or ''
                local isAggro = false
                if xtarg.Aggressive and xtarg.Aggressive() then
                    isAggro = true
                elseif targetType ~= '' and targetType:lower() == 'auto hater' then
                    isAggro = true
                end

                if isAggro and (not xtarg.Type or xtarg.Type() ~= 'Corpse') then
                    local id = xtarg.ID()
                    local cleanName = ''
                    if xtarg.CleanName then
                        cleanName = xtarg.CleanName()
                    elseif xtarg.Name then
                        cleanName = xtarg.Name()
                    end
                    local mobName = normalizeMobName(cleanName)
                    if mobName ~= '' then
                        seenIDs[id] = true
                        if not trackedAggressiveIDs[id] then
                            trackedAggressiveIDs[id] = mobName
                            local info = aggressiveNameInfo[mobName] or { count = 0, lastSeen = now }
                            info.count = info.count + 1
                            info.lastSeen = now
                            aggressiveNameInfo[mobName] = info
                        else
                            local existingName = trackedAggressiveIDs[id]
                            local info = aggressiveNameInfo[existingName]
                            if info then
                                info.lastSeen = now
                            end
                        end
                    end
                end
            end
        end
    end

    for id, name in pairs(trackedAggressiveIDs) do
        if not seenIDs[id] then
            trackedAggressiveIDs[id] = nil
            local info = aggressiveNameInfo[name]
            if info then
                info.count = math.max(0, (info.count or 0) - 1)
                info.lastSeen = now
            end
        end
    end

    pruneAggressiveInfo(now)
end

local function wasAggressiveMob(mobName)
    if not config.trackAggressiveOnly then return true end
    local normalizedName = normalizeMobName(mobName)
    if normalizedName == '' then return false end
    local info = aggressiveNameInfo[normalizedName]
    if not info then return false end
    if info.count and info.count > 0 then return true end
    if (os.time() - info.lastSeen) <= aggressiveCacheTimeout then
        return true
    end
    return false
end

local function getCurrentZoneName()
    local zoneName = nil
    if mq.TLO.Zone and mq.TLO.Zone.Name then
        zoneName = mq.TLO.Zone.Name()
    end
    return normalizeZoneName(zoneName)
end

local function isBeastsDomain()
    return getCurrentZoneName() == BEASTS_DOMAIN_ZONE
end

local function getSelectedZoneName()
    if config.selectedZone and config.selectedZone ~= '' then
        return normalizeZoneName(config.selectedZone)
    end
    local current = getCurrentZoneName()
    config.selectedZone = current
    return current
end

local function markZoneListDirty()
    zoneListDirty = true
end

local function getZoneSessionKills(zoneName)
    local normalizedZone = normalizeZoneName(zoneName)
    return sessionZoneKills[normalizedZone] or 0
end

local function markFilteredZoneDataDirty()
    filteredZoneDataDirty = true
end

local function getStartOfDay(now)
    local dayTable = os.date('*t', now)
    dayTable.hour = 0
    dayTable.min = 0
    dayTable.sec = 0
    return os.time(dayTable)
end

local function getTimeFilterBounds(filterId)
    local filter = filterId or defaultTimeFilter
    local now = os.time()
    local startOfToday = getStartOfDay(now)
    if filter == 'last_30_min' then
        return now - (30 * 60), now + 1
    elseif filter == 'last_60_min' then
        return now - (60 * 60), now + 1
    elseif filter == 'today' then
        return startOfToday, startOfToday + secondsPerDay
    elseif filter == 'yesterday' then
        local startOfYesterday = startOfToday - secondsPerDay
        return startOfYesterday, startOfToday
    elseif filter == 'this_week' then
        local nowTable = os.date('*t', now)
        local wday = nowTable.wday or 1 -- Lua weeks start on Sunday
        local daysFromWeekStart = wday - 1
        local startOfWeek = startOfToday - (daysFromWeekStart * secondsPerDay)
        return startOfWeek, startOfWeek + (7 * secondsPerDay)
    elseif filter == 'this_month' then
        local nowTable = os.date('*t', now)
        local dayOfMonth = nowTable.day
        local startOfMonth = startOfToday - ((dayOfMonth - 1) * secondsPerDay)
        -- Calculate days in current month
        local nextMonthTable = os.date('*t', startOfMonth + (32 * secondsPerDay))
        local daysInMonth = 31 - (nextMonthTable.day == 1 and 1 or 0)
        return startOfMonth, startOfMonth + (daysInMonth * secondsPerDay)
    end
    return nil, nil
end

local function epochToSqlTimestamp(epoch)
    if not epoch then return nil end
    return os.date('%Y-%m-%d %H:%M:%S', epoch)
end


-- Load configuration
local function loadConfig()
    local file = io.open(config.configFile, 'r')
    if file then
        local content = file:read('*all')
        file:close()
        local loadedConfig = json.decode(content)
        if loadedConfig then
            for key, value in pairs(loadedConfig) do
                config[key] = value
            end
        end
    end
    if not config.excludedMobNames then
        config.excludedMobNames = {}
    end
    if config.trackAggressiveOnly == nil then
        config.trackAggressiveOnly = true
    end
    if not config.selectedTimeFilter or not isValidTimeFilter(config.selectedTimeFilter) then
        config.selectedTimeFilter = defaultTimeFilter
    end
    normalizeExcludedConfig()
end

-- Save configuration
local function saveConfig()
    local file = io.open(config.configFile, 'w')
    if file then
        file:write(json.encode(config, { indent = true }))
        file:close()
    end
end

-- Initialize SQLite database
local function initDatabase()
    db = sqlite3.open(config.dbFile)
    
    -- Create kills table if it doesn't exist
    db:exec([[
        CREATE TABLE IF NOT EXISTS kills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mob_name TEXT NOT NULL,
            kill_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            killer_name TEXT,
            zone_name TEXT,
            x_coord REAL,
            y_coord REAL,
            z_coord REAL,
            bonus_group TEXT
        );
        
        CREATE INDEX IF NOT EXISTS idx_mob_name ON kills(mob_name);
        CREATE INDEX IF NOT EXISTS idx_kill_time ON kills(kill_time);
        CREATE INDEX IF NOT EXISTS idx_killer_name ON kills(killer_name);
        CREATE INDEX IF NOT EXISTS idx_bonus_group ON kills(bonus_group);
    ]])

    -- Migration: Add bonus_group column if it doesn't exist (older databases)
    local hasColumn = false
    for row in db:nrows("PRAGMA table_info(kills)") do
        if row.name == 'bonus_group' then
            hasColumn = true
            break
        end
    end
    if not hasColumn then
        db:exec("ALTER TABLE kills ADD COLUMN bonus_group TEXT")
    end

    db:exec([[
        CREATE TABLE IF NOT EXISTS zone_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            zone_name TEXT,
            start_epoch INTEGER NOT NULL,
            end_epoch INTEGER,
            duration_seconds INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_zone_sessions_zone ON zone_sessions(zone_name);
        CREATE INDEX IF NOT EXISTS idx_zone_sessions_start ON zone_sessions(start_epoch);
    ]])
    
    return db
end

local function ensureDatabase()
    if not db then
        db = initDatabase()
    end
    return db
end

local function invalidateZoneTimeCache()
    zoneTimeCache = {}
end

local function ensureZoneList()
    if not zoneListDirty and zoneList and #zoneList > 0 then
        return zoneList
    end

    zoneList = {}
    if ensureDatabase() then
        for row in db:nrows('SELECT DISTINCT zone_name FROM kills ORDER BY zone_name') do
            local z = normalizeZoneName(row.zone_name)
            if z ~= '' then table.insert(zoneList, z) end
        end
    end

    local current = getCurrentZoneName()
    local currentInList = false
    for _, z in ipairs(zoneList) do
        if z == current then currentInList = true break end
    end
    if not currentInList and current ~= '' then
        table.insert(zoneList, current)
        table.sort(zoneList)
    end

    zoneListDirty = false
    return zoneList
end

local function ensureFilteredZoneData(zoneName)
    local normalizedZone = normalizeZoneName(zoneName)
    local activeFilter = config.selectedTimeFilter or defaultTimeFilter
    local startEpoch, endEpoch = getTimeFilterBounds(activeFilter)
    local startStr = epochToSqlTimestamp(startEpoch)
    local endStr = epochToSqlTimestamp(endEpoch)

    local needsRefresh = filteredZoneDataDirty
    if not needsRefresh then
        if filteredZoneData.zone ~= normalizedZone or filteredZoneData.timeFilter ~= activeFilter then
            needsRefresh = true
        elseif filteredZoneData.rangeStart ~= startStr or filteredZoneData.rangeEnd ~= endStr then
            needsRefresh = true
        end
    end
    if not needsRefresh then
        return filteredZoneData
    end

    local kills = {}
    local total = 0

    if ensureDatabase() then
        local query = [[
            SELECT mob_name, COUNT(*) AS count
            FROM kills
            WHERE zone_name = ?
        ]]
        if startStr and endStr then
            query = query .. ' AND kill_time >= ? AND kill_time < ?'
        end
        query = query .. ' GROUP BY mob_name'

        local stmt = db:prepare(query)
        if stmt then
            if startStr and endStr then
                stmt:bind_values(normalizedZone, startStr, endStr)
            else
                stmt:bind_values(normalizedZone)
            end

            for row in stmt:nrows() do
                local mobName = normalizeMobName(row.mob_name)
                local count = tonumber(row.count) or 0
                if mobName ~= '' and not isExcludedMob(mobName) then
                    table.insert(kills, { name = mobName, zoneCount = count })
                    total = total + count
                end
            end
            stmt:finalize()
        end
    end

    filteredZoneData.zone = normalizedZone
    filteredZoneData.timeFilter = activeFilter
    filteredZoneData.rangeStart = startStr
    filteredZoneData.rangeEnd = endStr
    filteredZoneData.total = total
    filteredZoneData.kills = kills
    filteredZoneDataDirty = false
    return filteredZoneData
end

local function getTimeFilterLabel(filterId)
    local target = filterId or defaultTimeFilter
    for _, option in ipairs(timeFilterOptions) do
        if option.id == target then
            return option.label
        end
    end
    return 'All Time'
end

local function formatDuration(seconds)
    local totalSeconds = math.floor(math.max(0, seconds or 0))
    if totalSeconds <= 0 then
        return '0m'
    end
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    local secs = totalSeconds % 60
    if hours > 0 then
        return string.format('%dh %02dm', hours, minutes)
    elseif minutes > 0 then
        return string.format('%dm %02ds', minutes, secs)
    end
    return string.format('%ds', secs)
end

-- Load kill data from SQLite into in-memory cache for ImGui
local function loadKillData()
    if not ensureDatabase() then return end

    killData = {}
    totalKills = 0

    for row in db:nrows([[
        SELECT mob_name, zone_name, COUNT(*) as count
        FROM kills
        GROUP BY mob_name, zone_name
    ]]) do
        local mobName = row.mob_name
        local zoneName = normalizeZoneName(row.zone_name)
        if not isExcludedMob(mobName) then
            local entry = ensureKillEntry(mobName)
            entry.count = (entry.count or 0) + row.count
            entry.zones[zoneName] = (entry.zones[zoneName] or 0) + row.count
            totalKills = totalKills + row.count
        end
    end
end

local function loadTrapData()
    if not ensureDatabase() then return end
    
    -- Create trap tracking table if it doesn't exist
    db:exec([[
        CREATE TABLE IF NOT EXISTS traps (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trap_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            zone_name TEXT,
            spawned_mob TEXT
        );
        
        CREATE INDEX IF NOT EXISTS idx_trap_time ON traps(trap_time);
        CREATE INDEX IF NOT EXISTS idx_spawned_mob ON traps(spawned_mob);
    ]])
end

local function cleanupDanglingZoneSessions()
    if not ensureDatabase() then return end
    db:exec('UPDATE zone_sessions SET end_epoch = start_epoch, duration_seconds = 0 WHERE end_epoch IS NULL')
    invalidateZoneTimeCache()
end

local function startZoneSession(zoneName, epoch)
    if not zoneName or zoneName == '' or zoneName == 'Unknown' then return end
    local normalizedZone = normalizeZoneName(zoneName)
    currentZoneName = normalizedZone
    currentZoneStartTime = epoch or os.time()
    activeZoneSessionId = nil

    if ensureDatabase() then
        local stmt = db:prepare('INSERT INTO zone_sessions (zone_name, start_epoch) VALUES (?, ?)')
        if stmt then
            stmt:bind_values(normalizedZone, currentZoneStartTime)
            stmt:step()
            stmt:finalize()
            activeZoneSessionId = db:last_insert_rowid()
        end
    end
    invalidateZoneTimeCache()
end

local function endZoneSession(epoch)
    if not currentZoneName or not currentZoneStartTime then return end
    local finishEpoch = epoch or os.time()
    local duration = math.max(0, finishEpoch - currentZoneStartTime)
    sessionZoneDurations[currentZoneName] = (sessionZoneDurations[currentZoneName] or 0) + duration

    if ensureDatabase() and activeZoneSessionId then
        local stmt = db:prepare('UPDATE zone_sessions SET end_epoch = ?, duration_seconds = ? WHERE id = ?')
        if stmt then
            stmt:bind_values(finishEpoch, duration, activeZoneSessionId)
            stmt:step()
            stmt:finalize()
        end
    end

    currentZoneName = nil
    currentZoneStartTime = nil
    activeZoneSessionId = nil
    invalidateZoneTimeCache()
end

local function ensureZoneSessionTracking(forceRestart)
    local zoneName = getCurrentZoneName()
    if zoneName == 'Unknown' then return end

    if not currentZoneName or forceRestart then
        if forceRestart then
            endZoneSession(os.time())
        end
        startZoneSession(zoneName, os.time())
        return
    end

    if zoneName ~= currentZoneName then
        endZoneSession(os.time())
        startZoneSession(zoneName, os.time())
    end
end

local function updateZoneSessionTracking()
    ensureZoneSessionTracking(false)
end

local function getZoneSessionDuration(zoneName)
    local normalizedZone = normalizeZoneName(zoneName)
    local duration = sessionZoneDurations[normalizedZone] or 0
    if currentZoneName == normalizedZone and currentZoneStartTime then
        duration = duration + (os.time() - currentZoneStartTime)
    end
    return duration
end

local function computeZoneTimeSeconds(zoneName, filterId, now)
    if not ensureDatabase() then return 0 end
    local startEpoch, endEpoch = getTimeFilterBounds(filterId)
    local totalSeconds = 0
    local stmt = db:prepare('SELECT start_epoch, end_epoch FROM zone_sessions WHERE zone_name = ?')
    if stmt then
        stmt:bind_values(zoneName)
        for row in stmt:nrows() do
            local sessionStart = tonumber(row.start_epoch) or 0
            if sessionStart > 0 then
                local sessionEnd = tonumber(row.end_epoch)
                if not sessionEnd or sessionEnd <= 0 then
                    sessionEnd = now
                end
                if sessionEnd > sessionStart then
                    local effectiveStart = sessionStart
                    local effectiveEnd = sessionEnd
                    if startEpoch and effectiveStart < startEpoch then
                        effectiveStart = startEpoch
                    end
                    if endEpoch and effectiveEnd > endEpoch then
                        effectiveEnd = endEpoch
                    end
                    if (not startEpoch or sessionEnd > startEpoch) and (not endEpoch or sessionStart < endEpoch) then
                        if effectiveEnd > effectiveStart then
                            totalSeconds = totalSeconds + (effectiveEnd - effectiveStart)
                        end
                    end
                end
            end
        end
        stmt:finalize()
    end
    return totalSeconds
end

local function getZoneTimeSeconds(zoneName, filterId)
    local normalizedZone = normalizeZoneName(zoneName)
    if normalizedZone == '' or normalizedZone == 'Unknown' then return 0 end
    local filterKey = filterId or defaultTimeFilter
    local cacheKey = normalizedZone .. '|' .. filterKey
    local now = os.time()
    local refreshInterval = (currentZoneName == normalizedZone) and 1 or 30
    local cacheEntry = zoneTimeCache[cacheKey]
    if cacheEntry and (now - cacheEntry.timestamp) < refreshInterval then
        return cacheEntry.seconds
    end

    local seconds = computeZoneTimeSeconds(normalizedZone, filterKey, now)
    zoneTimeCache[cacheKey] = { seconds = seconds, timestamp = now }
    return seconds
end

local function resetZoneTimeData()
    if ensureDatabase() then
        db:exec('DELETE FROM zone_sessions')
    end
    sessionZoneDurations = {}
    currentZoneName = nil
    currentZoneStartTime = nil
    activeZoneSessionId = nil
    invalidateZoneTimeCache()
    ensureZoneSessionTracking(true)
end

local function getTrapStats(zoneName, timeFilter)
    if not ensureDatabase() then return 0, 0 end
    
    local normalizedZone = normalizeZoneName(zoneName)
    local activeFilter = timeFilter or defaultTimeFilter
    local startEpoch, endEpoch = getTimeFilterBounds(activeFilter)
    local startStr = epochToSqlTimestamp(startEpoch)
    local endStr = epochToSqlTimestamp(endEpoch)
    
    -- Build query with zone and time filters
    local query = 'SELECT COUNT(*) as total FROM traps WHERE zone_name = ?'
    if startStr and endStr then
        query = query .. ' AND trap_time >= ? AND trap_time < ?'
    end
    
    local totalTraps = 0
    local stmt = db:prepare(query)
    if stmt then
        if startStr and endStr then
            stmt:bind_values(normalizedZone, startStr, endStr)
        else
            stmt:bind_values(normalizedZone)
        end
        for row in stmt:nrows() do
            totalTraps = row.total or 0
        end
        stmt:finalize()
    end
    
    -- Get Drakkar count with same filters
    query = 'SELECT COUNT(*) as count FROM traps WHERE zone_name = ? AND spawned_mob LIKE "%drakkar%"'
    if startStr and endStr then
        query = query .. ' AND trap_time >= ? AND trap_time < ?'
    end
    
    local drakkarCount = 0
    stmt = db:prepare(query)
    if stmt then
        if startStr and endStr then
            stmt:bind_values(normalizedZone, startStr, endStr)
        else
            stmt:bind_values(normalizedZone)
        end
        for row in stmt:nrows() do
            drakkarCount = row.count or 0
        end
        stmt:finalize()
    end
    
    return totalTraps, drakkarCount
end

local function getLastTrapTime(zoneName)
    if not ensureDatabase() then return nil end
    
    local normalizedZone = normalizeZoneName(zoneName)
    local stmt = db:prepare([[
        SELECT trap_time FROM traps 
        WHERE zone_name = ? 
        ORDER BY trap_time DESC 
        LIMIT 1
    ]])
    
    local lastTrapTime = nil
    if stmt then
        stmt:bind_values(normalizedZone)
        for row in stmt:nrows() do
            if row.trap_time then
                -- Parse SQL timestamp to epoch
                local year, month, day, hour, min, sec = row.trap_time:match('(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)')
                if year then
                    lastTrapTime = os.time({
                        year = tonumber(year),
                        month = tonumber(month),
                        day = tonumber(day),
                        hour = tonumber(hour),
                        min = tonumber(min),
                        sec = tonumber(sec)
                    })
                end
            end
        end
        stmt:finalize()
    end
    
    return lastTrapTime
end

local function addTrap(spawnedMob)
    if not ensureDatabase() then return end
    
    local zoneName = normalizeZoneName(mq.TLO.Zone.Name())
    local mobName = spawnedMob or "Unknown"
    
    local stmt = db:prepare([[
        INSERT INTO traps (trap_time, zone_name, spawned_mob)
        VALUES (datetime('now','localtime'), ?, ?)
    ]])
    
    if stmt then
        stmt:bind_values(zoneName, mobName)
        stmt:step()
        stmt:finalize()
    end
end

local function resetSessionStats()
    sessionKills = 0
    sessionMobKills = {}
    sessionZoneKills = {}
    sessionZoneDurations = {}
end

local function resetKillData()
    if ensureDatabase() then
        db:exec('DELETE FROM kills')
    end
    killData = {}
    totalKills = 0
    resetSessionStats()
    markFilteredZoneDataDirty()
    resetZoneTimeData()
end

-- Add a kill to tracking
local function addKill(mobName, killerName)
    local normalizedName = normalizeMobName(mobName)
    if normalizedName == '' then return end
    if isPetEntity(normalizedName) or isExcludedMob(normalizedName) then return end
    if not wasAggressiveMob(normalizedName) then return end
    mobName = normalizedName
    
    -- Get current zone and position
    local zoneName = normalizeZoneName(mq.TLO.Zone.Name())
    local x, y, z = 0, 0, 0
    if mq.TLO.Me() then
        x = mq.TLO.Me.X() or 0
        y = mq.TLO.Me.Y() or 0
        z = mq.TLO.Me.Z() or 0
    end
    
    -- Determine bonus group for Beasts' Domain
    local bonusGroup = nil
    if zoneName == BEASTS_DOMAIN_ZONE and currentBonusGroup and currentBonusGroup ~= '' then
        bonusGroup = currentBonusGroup
    end
    
    -- Insert kill into database
    local stmt = db:prepare([[
        INSERT INTO kills (mob_name, kill_time, killer_name, zone_name, x_coord, y_coord, z_coord, bonus_group)
        VALUES (?, datetime('now','localtime'), ?, ?, ?, ?, ?, ?)
    ]])
    
    if stmt then
        stmt:bind_values(mobName, killerName or "Unknown", zoneName, x, y, z, bonusGroup)
        stmt:step()
        stmt:finalize()
        
        sessionKills = sessionKills + 1
        sessionZoneKills[zoneName] = (sessionZoneKills[zoneName] or 0) + 1
        local sessionEntry = ensureSessionKillEntry(mobName)
        sessionEntry.count = (sessionEntry.count or 0) + 1
        sessionEntry.zones[zoneName] = (sessionEntry.zones[zoneName] or 0) + 1
        lastKillTime = os.time()
        local entry = ensureKillEntry(mobName)
        entry.count = (entry.count or 0) + 1
        local zoneCounts = entry.zones or {}
        entry.zones = zoneCounts
        zoneCounts[zoneName] = (zoneCounts[zoneName] or 0) + 1
        totalKills = totalKills + 1
        markFilteredZoneDataDirty()
        markZoneListDirty()
    end
end

-- Event handlers
local function setupEvents()
    -- Track "You have slain" messages
    mq.event('YouSlain', 'You have slain #1#!', function(line, mobName)
        addKill(mobName, mq.TLO.Me.CleanName())
    end)
    
    -- Track "has been slain" messages (for all kills, regardless of killer)
    mq.event('BeenSlain', '#1# has been slain by #2#!', function(line, mobName, killer)
        addKill(mobName, killer)
    end)
    
    -- Track "has been slain by you!" messages
    mq.event('SlainByYou', '#1# has been slain by you!', function(line, mobName)
        addKill(mobName, mq.TLO.Me.CleanName())
    end)

    mq.event('TrapSprung', 'A trap is sprung!#*#', function(line, extra)
        -- The trap message doesn't tell us what spawned, so we need to check for nearby spawns
        local spawnedMob = "Unknown"
        
        -- Check the full line for mob mentions (sometimes included)
        if line then
            local lineLower = line:lower()
            if lineLower:find("blightfire ambusher") then
                spawnedMob = "a Blightfire Ambusher"
            elseif lineLower:find("chief drakkar") then
                spawnedMob = "Chief Drakkar"
            end
        end
        
        -- Check for nearby Chief Drakkar (within 200 radius)
        if spawnedMob == "Unknown" then
            local spawn = mq.TLO.NearestSpawn('npc "Chief Drakkar" radius 200')
            if spawn and spawn.ID then
                local id = spawn.ID()
                if id and id > 0 then
                    spawnedMob = "Chief Drakkar"
                end
            end
        end
        
        -- Check for nearby Blightfire Ambusher
        if spawnedMob == "Unknown" then
            local spawn = mq.TLO.NearestSpawn('npc "a Blightfire Ambusher" radius 200')
            if spawn and spawn.ID then
                local id = spawn.ID()
                if id and id > 0 then
                    spawnedMob = "a Blightfire Ambusher"
                end
            end
        end
        
        addTrap(spawnedMob)
        printf('Trap sprung!' .. (spawnedMob ~= "Unknown" and ' Spawned: ' .. spawnedMob or ''))
    end)
    
    mq.event('TrapChief', "Chief Drakkar shouts, 'Which one of you called me a mid-tier boss?!'#*#", function(line, extra)
        addTrap("Chief Drakkar")
        printf('Trap sprung! Spawned: Chief Drakkar')
    end)

    -- Zone change event for Beasts' Domain bonus group tracking
    mq.event('ZoneChange', 'You have entered #1#.', function(line, zoneName)
        local newZone = (zoneName and normalizeZoneName(zoneName)) or getCurrentZoneName()
        if newZone == BEASTS_DOMAIN_ZONE then
            if not bonusGroupPopupOpen and currentBonusGroup == '' then
                bonusGroupPopupOpen = true
            end
        else
            clearBonusGroupTracking()
        end
    end)
end

-- ImGui render function
local function renderKillTracker()
    if not config.showWindow then return end
    
    -- Optional theme: apply rounding locally for this window only
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 10.0)
    ImGui.PushStyleVar(ImGuiStyleVar.ChildRounding, 8.0)
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6.0)
    ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, 8.0)
    
    -- Set window flags
    local windowFlags = bit32.bor(
        ImGuiWindowFlags.None,
        ImGuiWindowFlags.NoScrollbar
    )
    
    -- Begin window
    local isOpen = config.showWindow
    config.showWindow = ImGui.Begin(config.windowTitle, isOpen, windowFlags)
    
    if config.showWindow then
        -- Display summary stats for current zone
        local selectedZoneName = getSelectedZoneName()
        local availableZones = ensureZoneList()
        ImGui.SetNextItemWidth(200)
        if ImGui.BeginCombo('Zone', selectedZoneName) then
            for _, zone in ipairs(availableZones) do
                local isSelected = (zone == selectedZoneName)
                if ImGui.Selectable(zone, isSelected) then
                    config.selectedZone = zone
                    selectedZoneName = zone
                    markFilteredZoneDataDirty()
                    saveConfig()
                end
                if isSelected then ImGui.SetItemDefaultFocus() end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        if ImGui.Button('Current Zone') then
            local current = getCurrentZoneName()
            config.selectedZone = current
            selectedZoneName = current
            markFilteredZoneDataDirty()
            saveConfig()
        end

        local selectedFilterId = config.selectedTimeFilter or defaultTimeFilter
        local zoneData = ensureFilteredZoneData(selectedZoneName)
        local zoneTotalKills = zoneData.total or 0
        local zoneSessionKills = getZoneSessionKills(selectedZoneName)
        local activeFilterLabel = getTimeFilterLabel(selectedFilterId)
        ImGui.Text(string.format('Zone Kills (%s - %s): %d', selectedZoneName, activeFilterLabel, zoneTotalKills))
        ImGui.SameLine()
        ImGui.Text('  Session: ' .. zoneSessionKills)

        local zoneTimeSeconds = getZoneTimeSeconds(selectedZoneName, selectedFilterId)
        local zoneSessionSeconds = getZoneSessionDuration(selectedZoneName)
        ImGui.Text(string.format('Time in Zone (%s): %s', activeFilterLabel, formatDuration(zoneTimeSeconds)))
        ImGui.SameLine()
        ImGui.Text('  Session: ' .. formatDuration(zoneSessionSeconds))
        local hasSessionRate = zoneSessionSeconds > 0 and zoneSessionKills > 0
        if zoneTimeSeconds > 0 then
            local killsPerHour = (zoneTotalKills / zoneTimeSeconds) * 3600
            ImGui.Text(string.format('  Kill Rate: %.1f/hr', killsPerHour))
            if hasSessionRate then
                local sessionRate = (zoneSessionKills / zoneSessionSeconds) * 3600
                ImGui.SameLine()
                ImGui.Text(string.format('Session Rate: %.1f/hr', sessionRate))
            end
        elseif hasSessionRate then
            local sessionRate = (zoneSessionKills / zoneSessionSeconds) * 3600
            ImGui.Text(string.format('Session Rate: %.1f/hr', sessionRate))
        end
        
        -- Display Drakkar to Total Traps ratio for selected zone and time range
        local totalTraps, drakkarCount = getTrapStats(selectedZoneName, selectedFilterId)
        
        if totalTraps > 0 then
            local ratio = (drakkarCount / totalTraps) * 100
            ImGui.Text(string.format('  Traps: Drakkar %d / Total %d (%.1f%%)', drakkarCount, totalTraps, ratio))
        elseif drakkarCount > 0 or totalTraps > 0 then
            ImGui.Text(string.format('  Traps: Drakkar %d / Total %d', drakkarCount, totalTraps))
        end
        
        -- Display trap reset timer
        ImGui.SameLine()
        local lastTrapTime = getLastTrapTime(selectedZoneName)
        if lastTrapTime then
            local now = os.time()
            local elapsed = now - lastTrapTime
            local resetTime = 21 * 60 -- 20 minutes in seconds
            
            local elapsedMin = math.floor(elapsed / 60)
            local elapsedSec = elapsed % 60
            
            if elapsed < resetTime then
                -- Show countdown in red
                local remaining = resetTime - elapsed
                local minutes = math.floor(remaining / 60)
                local seconds = remaining % 60
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.2, 0.2, 1.0) -- Red
                ImGui.Text(string.format('  %d:%02d (elapsed: %d:%02d)', minutes, seconds, elapsedMin, elapsedSec))
                ImGui.PopStyleColor()
            else
                -- Show Ready in green
                ImGui.PushStyleColor(ImGuiCol.Text, 0.2, 1.0, 0.2, 1.0) -- Green
                ImGui.Text(string.format('  Ready (elapsed: %d:%02d)', elapsedMin, elapsedSec))
                ImGui.PopStyleColor()
            end
        end

        ImGui.SetNextItemWidth(140)
        if ImGui.BeginCombo('Time Range', activeFilterLabel) then
            for _, option in ipairs(timeFilterOptions) do
                local isSelected = option.id == selectedFilterId
                if ImGui.Selectable(option.label, isSelected) and not isSelected then
                    config.selectedTimeFilter = option.id
                    selectedFilterId = option.id
                    activeFilterLabel = option.label
                    saveConfig()
                    markFilteredZoneDataDirty()
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(200)
        local searchText = ImGui.InputText('Filter', '', 64) or ''

        if not config.miniMode then
            ImGui.Separator()
            
            -- Kill list
            local childOpen = ImGui.BeginChild('KillList', 0, -ImGui.GetFrameHeight() - 10, true)
            if childOpen then
            -- Sort kills by count (descending)
            local sortedKills = {}
            local searchLower = ''
            if searchText ~= '' then
                searchLower = searchText:lower()
            end
            for _, kill in ipairs(zoneData.kills or {}) do
                table.insert(sortedKills, { name = kill.name, zoneCount = kill.zoneCount })
            end
            table.sort(sortedKills, function(a, b)
                if a.zoneCount == b.zoneCount then
                    return a.name < b.name
                end
                return a.zoneCount > b.zoneCount
            end)
            
            -- Display kills in table format
            local tableFlags = bit32.bor(
                ImGuiTableFlags.Resizable,
                ImGuiTableFlags.RowBg,
                ImGuiTableFlags.Borders,
                ImGuiTableFlags.SizingStretchProp
            )
            if ImGui.BeginTable('Kills', 2, tableFlags) then
                ImGui.TableSetupColumn('Mob Name', ImGuiTableColumnFlags.WidthStretch, 1.0)
                ImGui.TableSetupColumn('Zone Kills', ImGuiTableColumnFlags.WidthFixed, 90)

                ImGui.TableHeadersRow()

                for _, kill in ipairs(sortedKills) do
                    -- Apply filter
                    local matchesFilter = true
                    if searchText ~= '' then
                        matchesFilter = kill.name:lower():find(searchLower, 1, true) ~= nil
                    end
                    if matchesFilter then
                        ImGui.TableNextRow()
                        
                        -- Mob name
                        ImGui.TableSetColumnIndex(0)
                        ImGui.Text(kill.name)
                        
                        -- Kill count for current zone
                        ImGui.TableSetColumnIndex(1)
                        ImGui.Text(tostring(kill.zoneCount or 0))
                    end
                end
                ImGui.EndTable()
            end
        end
        ImGui.EndChild()
        ImGui.Separator()
        end
    end
    
    ImGui.End()

    -- Pop style vars we set for local rounding
    ImGui.PopStyleVar(4)
end

-- Floating timer render function
local function renderFloatingTimer()
    if not config.timerMode then return end

    -- Only show timer in moors zone (shortname)
    local currentZoneShortName = mq.TLO.Zone.ShortName() or ''
    if currentZoneShortName:lower() ~= 'moors' then return end

    -- Transparent background style
    ImGui.PushStyleColor(ImGuiCol.WindowBg, 0.0, 0.0, 0.0, 0.3) -- Semi-transparent black
    ImGui.PushStyleColor(ImGuiCol.Border, 0.0, 0.0, 0.0, 0.0) -- No border
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 8.0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 10, 10)

    -- Set window flags for a floating timer
    local windowFlags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.NoResize,
        ImGuiWindowFlags.AlwaysAutoResize,
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoCollapse
    )

    -- Begin floating timer window
    local isOpen = config.timerMode
    config.timerMode = ImGui.Begin('Trap Timer', isOpen, windowFlags)

    if config.timerMode then
        local selectedZoneName = getSelectedZoneName()
        local lastTrapTime = getLastTrapTime(selectedZoneName)

        if lastTrapTime then
            local now = os.time()
            local elapsed = now - lastTrapTime
            local resetTime = 20 * 60 -- 20 minutes in seconds

            if elapsed < resetTime then
                -- Show countdown in red
                local remaining = resetTime - elapsed
                local minutes = math.floor(remaining / 60)
                local seconds = remaining % 60
                ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 0.3, 0.3, 1.0) -- Red
                ImGui.SetWindowFontScale(2.0) -- Larger font for visibility
                ImGui.Text(string.format('%d:%02d', minutes, seconds))
                ImGui.SetWindowFontScale(1.0)
                ImGui.PopStyleColor()
            else
                -- Show Ready in green
                ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 1.0, 0.3, 1.0) -- Green
                ImGui.SetWindowFontScale(2.0) -- Larger font for visibility
                ImGui.Text('READY')
                ImGui.SetWindowFontScale(1.0)
                ImGui.PopStyleColor()
            end
        else
            -- No trap data available
            ImGui.PushStyleColor(ImGuiCol.Text, 0.7, 0.7, 0.7, 1.0) -- Gray
            ImGui.SetWindowFontScale(1.5)
            ImGui.Text('No Data')
            ImGui.SetWindowFontScale(1.0)
            ImGui.PopStyleColor()
        end
    end

    ImGui.End()

    -- Pop style vars and colors
    ImGui.PopStyleVar(2)
    ImGui.PopStyleColor(2)
end

-- Bonus group options for Beasts' Domain
local bonusGroupOptions = {
    { id = "NoGroup", label = "No Group", desc = "Track kills without bonus group assignment" },
    { id = "Group1", label = "Group 1", desc = "Bound Essences of Qvic, Cazic Thule, Dragons Minor, Dragons Major" },
    { id = "Group2", label = "Group 2", desc = "Bound Essences of Gods Minor, Gods Major, Abyss, Anguish" },
    { id = "Group3", label = "Group 3", desc = "Bound Essences of Loping Plains, Temple Veeshan, Old Commons, Sunderock" },
    { id = "Group4", label = "Group 4", desc = "Bound Essences of Kael Drakkel, Blightfire Moors" },
}

local bonusGroupDescriptions = {
    NoGroup = "Track kills without bonus group assignment",
    Group1 = "Bound Essences of Qvic, Cazic Thule, Dragons Minor, Dragons Major",
    Group2 = "Bound Essences of Gods Minor, Gods Major, Abyss, Anguish",
    Group3 = "Bound Essences of Loping Plains, Temple Veeshan, Old Commons, Sunderock",
    Group4 = "Bound Essences of Kael Drakkel, Blightfire Moors",
}

-- Bonus group selection popup for Beasts' Domain
local function renderBonusGroupPopup()
    if not bonusGroupPopupOpen then return end

    ImGui.SetNextWindowPos(ImGui.GetIO().DisplaySize.x * 0.5, ImGui.GetIO().DisplaySize.y * 0.3, ImGuiCond.Always, 0.5, 0.0)
    ImGui.SetNextWindowSize(400, 0, ImGuiCond.Always)

    local windowFlags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.NoResize,
        ImGuiWindowFlags.NoCollapse,
        ImGuiWindowFlags.NoSavedSettings
    )

    bonusGroupPopupOpen = ImGui.Begin('Bonus Group Selection', bonusGroupPopupOpen, windowFlags)

    if bonusGroupPopupOpen then
        ImGui.Text('Beasts\' Domain Detected')
        ImGui.Separator()
        ImGui.Text('Which bonus group are you tracking?')
        ImGui.Spacing()

        ImGui.SetNextItemWidth(350)
        local comboLabel = "Select Group..."
        if selectedBonusGroupIndex > 0 and selectedBonusGroupIndex <= #bonusGroupOptions then
            comboLabel = bonusGroupOptions[selectedBonusGroupIndex].label
        end

        if ImGui.BeginCombo('##bonusgroupcombo', comboLabel) then
            for i, option in ipairs(bonusGroupOptions) do
                local isSelected = (selectedBonusGroupIndex == i)
                if ImGui.Selectable(option.label, isSelected) then
                    selectedBonusGroupIndex = i
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                    ImGui.SameLine()
                    ImGui.TextDisabled('  (%s)', option.desc)
                else
                    ImGui.SameLine()
                    ImGui.TextDisabled('  (%s)', option.desc)
                end
            end
            ImGui.EndCombo()
        end

        ImGui.Spacing()

        if ImGui.Button('Confirm') then
            if selectedBonusGroupIndex > 0 and selectedBonusGroupIndex <= #bonusGroupOptions then
                currentBonusGroup = bonusGroupOptions[selectedBonusGroupIndex].label
                bonusGroupPopupOpen = false
                printf('Bonus group tracking: %s', currentBonusGroup)
            end
        end
        ImGui.SameLine()
        if ImGui.Button('Skip') then
            currentBonusGroup = ''
            selectedBonusGroupIndex = 0
            bonusGroupPopupOpen = false
            printf('Bonus group tracking skipped for this session')
        end
    end

    ImGui.End()
end

local function checkZoneForBonusGroup()
    if isBeastsDomain() then
        if not bonusGroupPopupOpen and currentBonusGroup == '' then
            bonusGroupPopupOpen = true
        end
    else
        clearBonusGroupTracking()
    end
end

-- Command handlers
local function setupCommands()
    mq.bind('/killtracker', function(args)
        local command = args or ''
        if command == 'show' then
            config.showWindow = true
            printf('Kill Tracker window shown')
        elseif command == 'hide' then
            config.showWindow = false
            printf('Kill Tracker window hidden')
        elseif command == 'toggle' then
            config.showWindow = not config.showWindow
            printf('Kill Tracker window ' .. (config.showWindow and 'shown' or 'hidden'))
        elseif command == 'mini' then
            config.miniMode = not config.miniMode
            printf('Kill Tracker mini mode ' .. (config.miniMode and 'enabled' or 'disabled'))
        elseif command == 'timer' then
            config.timerMode = not config.timerMode
            printf('Kill Tracker timer mode ' .. (config.timerMode and 'enabled' or 'disabled'))
        elseif command == 'reset' then
            resetKillData()
            printf('Kill Tracker data reset')
        elseif command == 'exit' or command == 'quit' then
            shouldExit = true
            printf('Kill Tracker shutting down...')
        elseif command == 'help' then
            printf('/Kill Tracker commands:')
            printf('/killtracker show - Show window')
            printf('/killtracker hide - Hide window')
            printf('/killtracker toggle - Toggle window')
            printf('/killtracker mini - Toggle mini mode (summary only)')
            printf('/killtracker timer - Toggle floating timer mode')
            printf('/killtracker reset - Reset all data')
            printf('/killtracker exit - Shutdown script')
        else
            config.showWindow = not config.showWindow
        end
        saveConfig()
    end)
end

-- Initialize ImGui
local function initImGui()
    mq.imgui.init('KillTracker', renderKillTracker)
    mq.imgui.init('TrapTimer', renderFloatingTimer)
    mq.imgui.init('BonusGroupPopup', renderBonusGroupPopup)
end

-- Main initialization
local function init()
    loadConfig()
    initDatabase()
    loadKillData()
    loadTrapData()
    cleanupDanglingZoneSessions()
    setupEvents()
    setupCommands()
    -- Always start with the UI visible; user can hide it later via /killtracker hide
    config.showWindow = true
    initImGui()
    ensureZoneSessionTracking(false)

    printf('Kill Tracker initialized. Use /killtracker to toggle window.')
    printf('Commands: /killtracker [show|hide|toggle|mini|timer|reset|help]')
end

-- Cleanup function
local function cleanup()
    endZoneSession(os.time())
    if db then
        db:close()
        db = nil
    end
    mq.unbind('/killtracker')
    printf('Kill Tracker shutdown complete')
end

-- Main loop
local function main()
    init()

    while not shouldExit do
        mq.doevents()
        updateAggressiveMobCache()
        updateZoneSessionTracking()
        checkZoneForBonusGroup()
        mq.delay(50) -- 50ms delay for responsiveness
    end

    cleanup()
end

-- Start the script
main()
