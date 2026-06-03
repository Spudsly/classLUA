local mq = require('mq')
require('ImGui')

-- Configuration
local MAX_SPAWNS = 5
local UPDATE_INTERVAL = 500 -- milliseconds

-- State
local recentSpawns = {}
local knownSpawnIDs = {}
local openGUI = true
local lockWindow = false

-- Commands
mq.bind('/recentspawns', function()
    openGUI = not openGUI
end)

mq.bind('/rs_lock', function()
    lockWindow = not lockWindow
end)

-- Get spawn details as a table
local function getSpawnDetails(spawn)
    if not spawn or not spawn() then return nil end
    return {
        id = spawn.ID(),
        name = spawn.DisplayName() or spawn.Name() or "Unknown",
        time = os.date("%H:%M:%S"),
    }
end

-- Check for new spawns
local function checkNewSpawns()
    local spawnCount = mq.TLO.SpawnCount("npc")()
    if not spawnCount or spawnCount == 0 then return end
    
    local currentIDs = {}
    
    for i = 1, spawnCount do
        local spawn = mq.TLO.NearestSpawn(i, "npc")
        if spawn and spawn() then
            local id = spawn.ID()
            if id and id > 0 then
                currentIDs[id] = true
                
                -- If this is a new spawn we haven't seen before
                if not knownSpawnIDs[id] then
                    local details = getSpawnDetails(spawn)
                    if details then
                        table.insert(recentSpawns, 1, details)
                        -- Keep only the last MAX_SPAWNS
                        while #recentSpawns > MAX_SPAWNS do
                            table.remove(recentSpawns)
                        end
                    end
                end
            end
        end
    end
    
    -- Update known spawns (keep only currently existing ones to prevent memory growth)
    knownSpawnIDs = currentIDs
end

-- Draw the ImGui window
local function drawGUI()
    if not openGUI then return end
    
    -- Window flags
    local windowFlags = ImGuiWindowFlags.None
    if lockWindow then
        windowFlags = bit32.bor(windowFlags, ImGuiWindowFlags.NoMove)
    end
    
    ImGui.SetNextWindowSize(250, 150, ImGuiCond.FirstUseEver)
    openGUI = ImGui.Begin("Recent Spawns##RecentSpawns", openGUI, windowFlags)
    
    -- Header with lock toggle
    ImGui.Text("Last %d NPC Spawns", MAX_SPAWNS)
    ImGui.SameLine()
    if ImGui.Button(lockWindow and "Unlock" or "Lock") then
        lockWindow = not lockWindow
    end
    
    ImGui.Separator()
    
    -- Display spawns
    if #recentSpawns == 0 then
        ImGui.TextColored(0.5, 0.5, 0.5, 1, "No recent spawns detected...")
    else
        for i, spawn in ipairs(recentSpawns) do
            ImGui.Text("%s", spawn.time)
            ImGui.SameLine(100)
            ImGui.TextColored(0, 1, 0, 1, "%s", spawn.name)
        end
    end
    
    ImGui.End()
end

-- Initialize ImGui
mq.imgui.init("RecentSpawnsGUI", drawGUI)

-- Main loop
local function main()
    while openGUI do
        mq.doevents()
        checkNewSpawns()
        mq.delay(UPDATE_INTERVAL)
    end
end

main()
