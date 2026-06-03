local mq = require('mq')
require('ImGui')

local OpenEditor, OpenSpawnViewer = false, true
local npc_list = {}  -- Persistent watchlist of spawn queries per zone
local tracked_spawns = {}
local input_npc_name = ""
local file_path = mq.luaDir .. "/npc_watchlist_by_zone.json"
local lockWindow = false

-- MacroQuest command to reopen the editor
mq.bind('/sm_edit', function()
    OpenEditor = true
end)

mq.bind('/sm_lock', function()
    lockWindow = not lockWindow
end)

-- MacroQuest command to reopen the spawn viewer
mq.bind('/showspawns', function()
    OpenSpawnViewer = true
end)

-- 🔹 Manual JSON Stringifier
local function table_to_json(tbl)
    local json = "{\n"
    for zone, queries in pairs(tbl) do
        json = json .. string.format('    "%s": [', zone)
        for i, v in ipairs(queries) do
            json = json .. string.format('"%s"%s', v, i < #queries and ", " or "")
        end
        json = json .. "],\n"
    end
    json = json .. "}"
    return json
end

-- 🔹 Manual JSON Parser
local function json_to_table(json)
    local tbl = {}
    for zone, query_list_str in json:gmatch('"([^"]+)": %[(.-)%]') do
        local queries = {}
        for query in query_list_str:gmatch('"([^"]+)"') do
            table.insert(queries, query)
        end
        tbl[zone] = queries
    end
    return tbl
end

-- 🔹 Save the watchlist to a JSON file
local function save_npc_list()
    local file = io.open(file_path, "w")
    if file then
        file:write(table_to_json(npc_list))
        file:close()
    end
end

-- 🔹 Load the watchlist from a JSON file
local function load_npc_list()
    local file = io.open(file_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        npc_list = json_to_table(content) or {}
    end
end

-- 🔹 Update the list of currently spawned entities (Only in the current zone)
local function update_tracked_spawns()
    tracked_spawns = {}
    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"

    if npc_list[current_zone] then
        tracked_spawns[current_zone] = {}
        for _, query in ipairs(npc_list[current_zone]) do
            local spawn_count = mq.TLO.SpawnCount(query)()
            if spawn_count and spawn_count > 0 then
                for i = 1, spawn_count do
                    local spawn_name = mq.TLO.NearestSpawn(i, query).Name()
                    local spawn_loc = string.format("(%d, %d, %d)", 
                        mq.TLO.NearestSpawn(i, query).X() or 0,
                        mq.TLO.NearestSpawn(i, query).Y() or 0,
                        mq.TLO.NearestSpawn(i, query).Z() or 0)
                    table.insert(tracked_spawns[current_zone], {name = spawn_name, location = spawn_loc})
                    table.sort(tracked_spawns[current_zone], function(a, b)
                        return a.name < b.name
                    end)
                end
            end
        end
    end
end

-- 🔹 Draw the Spawn Query Watchlist Editor with improved layout
local function draw_editor()
    if not OpenEditor then return end
    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.6)
    OpenEditor = ImGui.Begin("Spawn Query Watchlist Editor", OpenEditor)

    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
    -- Display a descriptive label on its own
    ImGui.Text("Add spawn query in " .. current_zone)
    -- Set a fixed width for the input field so it doesn't stretch the window
    ImGui.SetNextItemWidth(250)
    input_npc_name = ImGui.InputText("##spawnQuery", input_npc_name, 64)
    ImGui.SameLine()
    if ImGui.Button("Add") and input_npc_name ~= "" then
        if not npc_list[current_zone] then npc_list[current_zone] = {} end
        table.insert(npc_list[current_zone], input_npc_name)
        save_npc_list()  -- Save when adding
        input_npc_name = ""
    end

    -- Display a table of spawn queries being watched
    for zone, queries in pairs(npc_list) do
        if ImGui.CollapsingHeader(zone) then
            if ImGui.BeginTable("WatchlistTable_" .. zone, 2, ImGuiTableFlags.Borders) then
                ImGui.TableSetupColumn("Spawn Query", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Remove", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()
                
                for i, query in ipairs(queries) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(query)

                    ImGui.TableSetColumnIndex(1)
                    if ImGui.Button("Remove##" .. zone .. i) then
                        table.remove(npc_list[zone], i)
                        if #npc_list[zone] == 0 then
                            npc_list[zone] = nil
                        end
                        save_npc_list()  -- Save when removing
                    end
                end
                ImGui.EndTable()
            end
        end
    end

    ImGui.End()
end

-- 🔹 Draw the Active Spawn Viewer (Only for the current zone)
local function draw_spawn_viewer()
    if not OpenSpawnViewer then return end

    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.0) -- Fully transparent window

    -- Apply NoMove flag if lockWindow is true
    local window_flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.AlwaysAutoResize
    if lockWindow then
        window_flags = window_flags + ImGuiWindowFlags.NoMove
    end

    OpenSpawnViewer = ImGui.Begin("Active Spawn Viewer", OpenSpawnViewer, window_flags)

    if ImGui.Button("Open Spawn Query Editor") then
        OpenEditor = true
    end

    ImGui.SameLine()
    if ImGui.Button(lockWindow and "Unlock Window" or "Lock Window") then
        lockWindow = not lockWindow
    end

    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
    
    if tracked_spawns[current_zone] and #tracked_spawns[current_zone] > 0 then
        for _, spawn in ipairs(tracked_spawns[current_zone]) do
            ImGui.TextColored(0, 1, 0, 1, spawn.name .. " " .. spawn.location)
        end
    else
        ImGui.TextColored(1, 0, 0, 1, "Nothing's Up.")
    end

    ImGui.End()
end

-- 🔹 Hook into ImGui rendering
mq.imgui.init("SpawnQueryEditor", draw_editor)
mq.imgui.init("SpawnViewer", draw_spawn_viewer)

-- 🔹 Main loop
local function main()
    load_npc_list()  -- Load the watchlist when the script starts
    while true do
        mq.doevents()
        update_tracked_spawns()
        mq.delay(5000)
    end
end

-- Run the script (keeping it alive)
main()
