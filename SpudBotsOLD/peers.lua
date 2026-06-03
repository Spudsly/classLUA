-- peers.lua
-- Handles peer status, DPS tracking, and switching logic

local mq = require('mq')
local imgui = require('ImGui')
local utils = require('utils') -- Assuming utils.lua is available
local json = require('dkjson')
local config = {}
local config_path = string.format('%s/peer_ui_config.json', mq.configDir)
local MyName -- Initialized in M.init()
local MyServer -- Initialized in M.init()

local M = {} -- Module table

-- Configuration
local REFRESH_INTERVAL_MS = 200 -- How often to run the update loop (in ms)
local STALE_DATA_TIMEOUT_S= 30  -- How long before peer data is considered stale (in seconds)
local BATTLE_DURATION_S   = 5  -- How long after combat ends before DPS resets (in seconds)
-- FG_REFRESH_MS and BG_REFRESH_MS are not used in the provided snippet, can be removed or implemented
local lastRefreshTime = 0   -- track in mq’s high‐res clock
local elapsed = os.clock  -- or mq.clock, whichever you use

-- State Variables
M.peers       = {}      -- Stores data received from other peers [id] = {data}
M.peer_list   = {}      -- Filtered and processed list of peers for display
M.options = {         -- Options controlled by the main UI menu
    sort_mode   = "Custom", -- or "HP", "Distance", "DPS", "Alphabetical", "Class"
    custom_order = {}, -- User-defined order, one entry (name or filler) per line
    show_name     = true,
    show_hp       = true,
    show_mana     = true,
    show_distance = true,
    show_dps      = true,
    show_target   = true,
    show_combat   = true,
    show_casting  = true,
    borderless    = false,
    show_player_stats = true,
    use_class     = false,
    font_scale = 1.0,
    filler_char = "~ ~ ~ ~ ~",
}
M.show_aa_window = { value = false } -- Control the visibility of the AA window
M.show_sort_editor = { value = false }

local lastPeerCount     = 0
local cachedPeerHeight = 300 -- Default height
local lastUpdateTime   = {} -- [id] = timestamp of last message received
local lastPublishTime  = 0  -- Timestamp of last published message
local lastDPSVisibility = M.options.show_dps


-- DPS Tracking Variables (largely unchanged)
local dmgTotalBattle    = 0
local dmgBattCounter    = 0
local critTotalBattle   = 0
local critHealsTotal    = 0 -- Note: Crit heals aren't DPS but were tracked
local dmgTotalDS        = 0
local dsCounter         = 0
local dmgTotalNonMelee  = 0
local nonMeleeCounter   = 0
local battleStartTime   = 0 -- Timestamp combat started
local enteredCombat     = false
local leftCombatTime    = 0 -- Timestamp combat ended

-- Helper: Get health bar color (unchanged)
local function getHealthColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(1, 0, 0, 1) -- Red
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1) -- Yellow
    else
        return ImVec4(0, 1, 0, 1) -- Green
    end
end

-- Helper: Get mana bar color (unchanged)
local function getManaColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(0.5, 0.5, 0, 1) -- Dark Yellow/Reddish for low mana
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1) -- Yellow
    else
        return ImVec4(0.678, 0.847, 0.902, 1) -- Light Blue
    end
end

-- Helper: Calculate current DPS (unchanged)
local function calculateCurrentDPS()
    if not enteredCombat or battleStartTime <= 0 then return 0 end
    local currentTime = os.time()
    local duration = currentTime - battleStartTime
    if duration <= 0 then return 0 end
    local totalDmg = dmgTotalBattle + dmgTotalDS + dmgTotalNonMelee
    -- local formattedDPS = math.floor(totalDmg / duration) -- Not used directly for return

    if currentTime ~= lastPublishedTime then -- Assuming lastPublishedTime is for /netnote
        lastPublishedTime = currentTime
        mq.cmdf('/netnote %d', math.floor(totalDmg / duration))
    end
    return totalDmg / duration
end

-- DPS Event Callbacks (unchanged)
local function handleDamageEvent(dmgAmount)
    if not enteredCombat then
        enteredCombat   = true
        battleStartTime = os.time()
        leftCombatTime  = 0
        dmgTotalBattle    = 0; dmgBattCounter    = 0
        critTotalBattle   = 0; critHealsTotal    = 0
        dmgTotalDS        = 0; dsCounter         = 0
        dmgTotalNonMelee  = 0; nonMeleeCounter   = 0
    end
    leftCombatTime = 0
    return tonumber(dmgAmount) or 0
end

local function meleeCallBack(line, dType, target, dmgStr)
    if string.find(line, "have been healed") then return end
    if string.find(line, "but miss") or string.find(line, "but misses") then return end
    local dmg = handleDamageEvent(dmgStr)
    dmgTotalBattle = dmgTotalBattle + dmg
    dmgBattCounter = dmgBattCounter + 1
end

local function critCallBack(line, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    critTotalBattle = critTotalBattle + dmg
end

local function critHealCallBack(line, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    critHealsTotal = critHealsTotal + dmg
end

local function nonMeleeCallBack(line, targetOrYou, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    if string.find(line, "was hit by non-melee for") then
        dmgTotalDS = dmgTotalDS + dmg
        dsCounter = dsCounter + 1
    elseif string.find(line, "You were hit by non-melee for") then
        -- Damage taken, not dealt by player for DPS calc
    else
        dmgTotalNonMelee = dmgTotalNonMelee + dmg
        nonMeleeCounter = nonMeleeCounter + 1
    end
end

-- checkCombatState (unchanged)
local function checkCombatState()
    local currentCombatState = utils.safeTLO(mq.TLO.Me.CombatState, "UNKNOWN")
    if currentCombatState ~= 'COMBAT' and enteredCombat then
        if leftCombatTime == 0 then
            leftCombatTime = os.time()
            -- print("[SpudBots] Combat ended (timer started).")
        end
        if os.difftime(os.time(), leftCombatTime) > BATTLE_DURATION_S then
            -- print("[SpudBots] Combat DPS reset.")
            enteredCombat   = false; battleStartTime = 0; leftCombatTime  = 0
            dmgTotalBattle    = 0; dmgBattCounter    = 0; critTotalBattle   = 0
            critHealsTotal    = 0; dmgTotalDS        = 0; dsCounter         = 0
            dmgTotalNonMelee  = 0; nonMeleeCounter   = 0
            mq.cmdf('/netnote 0')
        end
    elseif (currentCombatState == 'COMBAT' or currentCombatState == 'TRUE') and not enteredCombat then
        enteredCombat = true; battleStartTime = os.time(); leftCombatTime = 0
        dmgTotalBattle    = 0; dmgBattCounter    = 0; critTotalBattle   = 0
        critHealsTotal    = 0; dmgTotalDS        = 0; dsCounter         = 0
        dmgTotalNonMelee  = 0; nonMeleeCounter   = 0
        -- print("[Peers] Entered combat state.")
    elseif (currentCombatState == 'COMBAT' or currentCombatState == 'TRUE') and enteredCombat then
        if leftCombatTime ~= 0 then
            -- print("[Peers] Re-entered combat.")
            leftCombatTime = 0
        end
    end
end


local function refreshPeers()
    local currentTime = os.time()
    local myID = mq.TLO.Me.ID() or 0
    -- Ensure MyName and MyServer are valid (usually set in M.init)
    if not MyName or MyName == "Unknown" then
        MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown") -- Fallback
    end
    if not MyServer or MyServer == "Unknown" then
        MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown") -- Fallback
    end

    local myCurrentZoneID = mq.TLO.Me.Instance() or 0 -- Use Instance ID for zone comparison
    local my_entry_key = MyName -- Key for self in M.peers

    -- Update self in M.peers table
    M.peers[my_entry_key] = {
        id = my_entry_key, -- Unique ID for ImGui
        name = MyName,
        server = MyServer,
        hp = mq.TLO.Me.PctHPs() or 0,
        mana = mq.TLO.Me.PctMana() or 0,
        uses_mana = (mq.TLO.Me.MaxMana() or 0) > 0,
        zone_id = myCurrentZoneID, -- Store zone ID
        zone = mq.TLO.Zone.ShortName() or "unknown", -- For display
        dps = calculateCurrentDPS(),
        aa = mq.TLO.Me.AAPoints() or 0,
        target = mq.TLO.Target.CleanName() or "None",
        combat_state = mq.TLO.Me.Combat() or false,
        casting = mq.TLO.Me.Casting() or "NULL",
        last_update = currentTime,
        distance = 0,
        inSameZone = true, -- Self is always in the same zone as self
        class = mq.TLO.Me.Class.ShortName() or "Unknown"
    }
    lastUpdateTime[my_entry_key] = currentTime

    -- Use NetBots.Client to get list of netbots
    local netbotClients = mq.TLO.NetBots.Client() or ""
    local current_netbot_names = {}
    for name_str in string.gmatch(netbotClients, '(%S+)') do
        current_netbot_names[name_str] = true -- Keep track of current netbots
        if name_str ~= MyName then
            local netBot = mq.TLO.NetBots(name_str)
            if netBot and netBot() then
                local success, peerData = pcall(function()
                    local zoneID = netBot.Instance() or 0
                    local inSameZone = (zoneID == myCurrentZoneID)
                    local distance = 9999
                    if inSameZone then
                        local spawn = mq.TLO.Spawn(string.format('pc "%s"', name_str))
                        if spawn() and spawn.ID() ~= myID then
                            distance = spawn.Distance3D() or 9999
                        end
                    end
                    local targetID = netBot.TargetID() or 0
                    local targetName = "None"
                    if targetID > 0 then
                        local targetSpawn = mq.TLO.Spawn(targetID)
                        if targetSpawn() then targetName = targetSpawn.CleanName() or "Unknown" end
                    end
                    local dpsNote = netBot.Note() or "0"
                    local peerDPS = tonumber(dpsNote) or 0

                    return {
                        id = name_str, -- Unique ID for ImGui
                        name = name_str,
                        server = MyServer, -- Assuming same server for netbots
                        hp = netBot.PctHPs() or 0,
                        mana = netBot.PctMana() or 0,
                        uses_mana = (netBot.MaxMana() or 0) > 0,
                        zone_id = zoneID,
                        zone = netBot.Zone() or "unknown", -- Get actual zone name if possible
                        dps = peerDPS,
                        aa = netBot.TotalAA() or 0,
                        target = targetName,
                        combat_state = netBot.Attacking() or false,
                        casting = netBot.Casting() or "NULL",
                        last_update = currentTime,
                        distance = distance,
                        inSameZone = inSameZone,
                        class = netBot.Class() and netBot.Class.ShortName() or "Unknown"
                    }
                end)
                if success and peerData then
                    M.peers[name_str] = peerData
                    lastUpdateTime[name_str] = currentTime
                else
                    -- print(string.format("\ar[Peers] Error processing NetBot %s: %s\ax", name_str, tostring(peerData)))
                end
            end
        end
    end

    -- Remove stale peers that are no longer in NetBots.Client or timed out
    for id_key, _ in pairs(M.peers) do
        if id_key ~= my_entry_key and not current_netbot_names[id_key] then -- Not self and not in current netbots
            if currentTime - (lastUpdateTime[id_key] or 0) > STALE_DATA_TIMEOUT_S then
                M.peers[id_key] = nil
                lastUpdateTime[id_key] = nil
            else
                if not M.peers[id_key].marked_stale then M.peers[id_key].marked_stale_time = currentTime end
                M.peers[id_key].inSameZone = false -- Mark as out of zone or unknown
            end
        end
        if currentTime - (lastUpdateTime[id_key] or 0) > STALE_DATA_TIMEOUT_S then
            M.peers[id_key] = nil
            lastUpdateTime[id_key] = nil
        end
    end

        if self_data then
            table.insert(new_peer_list, self_data) -- Self is usually first
        end

        local other_peers_temp = {}
        for name_key, peer_item in pairs(M.peers) do
            if name_key ~= my_entry_key then -- Only add other peers
                table.insert(other_peers_temp, peer_item)
            end
        end

    -- Build custom ordered peer_list (includes filler support)
    local new_peer_list = {}

    -- Build id->peer map for fast lookup
    local id_to_peer = {}
    for k, p in pairs(M.peers) do id_to_peer[p.id or k] = p end

    if M.options.sort_mode == "Custom" then
        for _, entry in ipairs(M.options.custom_order or {}) do
            if entry.type == "filler" then
                table.insert(new_peer_list, { type = "filler", filler_text = entry.filler_text or M.options.filler_char })
            elseif entry.id and id_to_peer[entry.id] then
                table.insert(new_peer_list, id_to_peer[entry.id])
            end
        end
    else
        -- Default ordering: Self first, then others, sorted by selected mode
        local self_peer = id_to_peer[MyName]
        if self_peer then table.insert(new_peer_list, self_peer) end

        local others = {}
        for k, p in pairs(M.peers) do
            if k ~= MyName then table.insert(others, p) end
        end

        if M.options.sort_mode == "Alphabetical" then
            table.sort(others, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
        elseif M.options.sort_mode == "HP" then
            table.sort(others, function(a, b) return (a.hp or 0) < (b.hp or 0) end)
        elseif M.options.sort_mode == "Distance" then
            table.sort(others, function(a, b) return (a.distance or 9999) < (b.distance or 9999) end)
        elseif M.options.sort_mode == "DPS" then
            table.sort(others, function(a, b) return (a.dps or 0) > (b.dps or 0) end)
        elseif M.options.sort_mode == "Class" then
            table.sort(others, function(a, b)
                local class_a = a.class or "Unknown"
                local class_b = b.class or "Unknown"
                if class_a:lower() == class_b:lower() then
                    return (a.name or ""):lower() < (b.name or ""):lower()
                end
                return class_a:lower() < class_b:lower()
            end)
        end

        for _, p in ipairs(others) do table.insert(new_peer_list, p) end
    end

    M.peer_list = new_peer_list

    -- === Height Calculation (Adjusted for fillers) ===
    local num_peer_rows = #M.peer_list
    local num_class_title_rows = 0

    if M.options.sort_mode == "Class" and num_peer_rows > 0 then
        local distinct_classes = {}
        for _, peer_entry in ipairs(M.peer_list) do
            distinct_classes[peer_entry.class or "Unknown"] = true
        end
        for _ in pairs(distinct_classes) do
            num_class_title_rows = num_class_title_rows + 1
        end
    end

    local font_scale = M.options.font_scale or 1.0
    local single_data_row_height = (imgui.GetTextLineHeight() + (imgui.GetStyle().CellPadding.y * 2)) * font_scale
    local table_header_actual_row_height = single_data_row_height + 2 * font_scale
    local new_calculated_height = 0
    if num_peer_rows > 0 or num_class_title_rows > 0 then 
        new_calculated_height = new_calculated_height + table_header_actual_row_height 
    end

    new_calculated_height = new_calculated_height + (num_peer_rows * single_data_row_height)
    new_calculated_height = new_calculated_height + (num_class_title_rows * single_data_row_height) 

    if new_calculated_height > 0 then 
        new_calculated_height = new_calculated_height + (imgui.GetStyle().FramePadding.y) * font_scale
    end

    local min_renderable_height = table_header_actual_row_height
    if num_peer_rows == 0 and num_class_title_rows == 0 then
        min_renderable_height = 20 * font_scale
    end

    cachedPeerHeight = math.max(min_renderable_height, new_calculated_height)

    if num_peer_rows ~= lastPeerCount then
        lastPeerCount = num_peer_rows
    end
end

-- Switcher Actions
local function switchTo(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Switching to: %s", name))
        mq.cmdf('/bct %s //foreground', name)
    end
end

local function targetCharacter(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Targeting: %s", name))
        mq.cmdf('/target pc "%s"', name) -- Quote name for safety
    end
end

-- Drawing Functions
function M.draw_peer_list()
    imgui.SetWindowFontScale(M.options.font_scale or 1.0)
    if M.options.show_dps ~= lastDPSVisibility then
        lastDPSVisibility = M.options.show_dps
        if M.options.show_dps then
            mq.cmdf('/bca //lua run spudbots')
        else
            mq.cmdf('/bca //lua stop spudbots')
        end
    end

    local column_count = 0
    local first_column_is_name_or_class = false
    if M.options.show_name or M.options.use_class then column_count = column_count + 1; first_column_is_name_or_class = true end
    if M.options.show_hp       then column_count = column_count + 1 end
    if M.options.show_mana     then column_count = column_count + 1 end
    if M.options.show_distance then column_count = column_count + 1 end
    if M.options.show_dps      then column_count = column_count + 1 end
    if M.options.show_target   then column_count = column_count + 1 end
    if M.options.show_combat   then column_count = column_count + 1 end
    if M.options.show_casting  then column_count = column_count + 1 end

    if column_count == 0 then
        imgui.Text("No columns selected for Peer Switcher.")
        return
    end

    local tableFlags = bit32.bor(
        ImGuiTableFlags.Reorderable, ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders,
        ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.NoHostExtendX
    )

    if not imgui.BeginTable("##PeerTableUnified", column_count, tableFlags) then
        -- imgui.EndTable() -- Not needed if BeginTable returns false
        return
    end

    -- Setup columns
    if first_column_is_name_or_class then
        local header_text = (M.options.sort_mode ~= "Class" and M.options.use_class) and "Class" or "Name"
        imgui.TableSetupColumn(header_text, ImGuiTableColumnFlags.None, 0.0, 0) -- Default flags, let width be auto or set by user drag
    end
    if M.options.show_hp       then imgui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_mana     then imgui.TableSetupColumn("Mana", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_distance then imgui.TableSetupColumn("Dist", ImGuiTableColumnFlags.None, 0.0, 0) end
    if M.options.show_dps      then imgui.TableSetupColumn("DPS", ImGuiTableColumnFlags.None, 0.0, 0) end
    if M.options.show_target   then imgui.TableSetupColumn("Target", ImGuiTableColumnFlags.None, 0.0, 0) end
    if M.options.show_combat   then imgui.TableSetupColumn("Combat", ImGuiTableColumnFlags.WidthFixed, 60) end
    if M.options.show_casting  then imgui.TableSetupColumn("Casting", ImGuiTableColumnFlags.None, 0.0, 0) end
    imgui.TableHeadersRow()

    local current_drawn_class = nil
    for _, item in ipairs(M.peer_list) do
        if item.type == "filler" then
            imgui.TableNextRow()
            imgui.TableNextColumn() -- First column for the filler text
            imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.6, 0.6, 0.6, 1)) -- Dim color for filler
            -- Use a disabled selectable to make it span and look like a row item
            local filler_label = string.format("%s##filler_row_%d", item.filler_text, _)
            imgui.Selectable(filler_label, false, bit32.bor(ImGuiSelectableFlags.SpanAllColumns, ImGuiSelectableFlags.Disabled))
            imgui.PopStyleColor()
            -- No need to manually fill other columns if SpanAllColumns is used on the selectable.
        else
            local peer = item -- It's a peer data object
            -- Class Header Row (only if sorting by class AND it's a peer)
            if M.options.sort_mode == "Class" and (peer.class or "Unknown") ~= current_drawn_class then
                current_drawn_class = peer.class or "Unknown"
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.PushStyleColor(ImGuiCol.Text, ImVec4(1.0, 0.75, 0.3, 1.0))
                imgui.Text(current_drawn_class)
                imgui.PopStyleColor()
                for i = 2, column_count do imgui.TableNextColumn(); imgui.Text("") end
            end

            imgui.TableNextRow()
            -- Name/Class Column Content
            if first_column_is_name_or_class then
                imgui.TableNextColumn()
                local isSelf = (peer.name == MyName and peer.server == MyServer)
                local zoneColor = peer.inSameZone and ImVec4(0.8,1,0.8,1) or ImVec4(1,0.2,0.2,1)
                if isSelf then zoneColor = ImVec4(1,1,0.7,1) end
                imgui.PushStyleColor(ImGuiCol.Text, zoneColor)

                local displayValue = peer.name
                if M.options.sort_mode ~= "Class" and M.options.use_class then
                    displayValue = peer.class or "Unknown"
                end
                local uniqueLabel = string.format("%s##%s_peer_selectable", displayValue, peer.id or peer.name)

                if imgui.Selectable(uniqueLabel, false, ImGuiSelectableFlags.SpanAllColumns) then
                    if not isSelf then switchTo(peer.name) end
                end
                imgui.PopStyleColor()

                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text("Name : %s",  peer.name)
                    imgui.Text("Class: %s",  peer.class or "Unknown")
                    imgui.Text("Zone: %s (%s)", peer.zone or "Unknown", peer.inSameZone and "Here" or "Elsewhere")
                    if not isSelf then
                        imgui.Separator()
                        imgui.Text("Left-click : Switch to %s", peer.name)
                        imgui.Text("Right-click: Target %s",   peer.name)
                    end
                    imgui.EndTooltip()
                end
                if not isSelf and imgui.IsItemClicked(ImGuiMouseButton.Right) then
                    targetCharacter(peer.name)
                end
            end

            -- HP Column
            if M.options.show_hp then
                imgui.TableNextColumn(); imgui.PushStyleColor(ImGuiCol.Text, getHealthColor(peer.hp))
                imgui.Text("%.0f%%", peer.hp or 0); imgui.PopStyleColor()
            end
            -- Mana Column
            if M.options.show_mana then
                imgui.TableNextColumn();
                if peer.uses_mana then
                    imgui.PushStyleColor(ImGuiCol.Text, getManaColor(peer.mana))
                    imgui.Text("%.0f%%", peer.mana or 0); imgui.PopStyleColor()
                else imgui.Text("N/A") end
            end
            -- Distance Column
            if M.options.show_distance then
                imgui.TableNextColumn()
                local distText = "N/A"; local distColor = ImVec4(0.7,0.7,0.7,1)
                if not peer.inSameZone then distText = "Zone!"; distColor = ImVec4(1,0.5,0.5,1)
                elseif peer.distance == 0 and peer.name == MyName then distText = "Self"; distColor = ImVec4(1,1,0.7,1)
                elseif peer.distance >= 9999 then distText = "??"; distColor = ImVec4(1,1,0.6,1)
                else
                    distText = string.format("%.0f", peer.distance)
                    if peer.distance < 20 then distColor = ImVec4(0.6,1,0.6,1)
                    elseif peer.distance < 100 then distColor = ImVec4(0.8,1,0.8,1)
                    elseif peer.distance < 175 then distColor = ImVec4(1,0.8,0.6,1)
                    else distColor = ImVec4(1,0.6,0.6,1) end
                end
                imgui.PushStyleColor(ImGuiCol.Text, distColor); imgui.Text(distText); imgui.PopStyleColor()
            end
            -- DPS Column
            if M.options.show_dps then
                imgui.TableNextColumn(); imgui.Text(utils.cleanNumber(tonumber(peer.dps) or 0, 1, true))
            end
            -- Target Column
            if M.options.show_target then
                imgui.TableNextColumn()
                local targetColor = (peer.target == "None") and ImVec4(0.7,0.7,0.7,1) or ImVec4(1,1,1,1)
                if not M.options.show_combat and peer.combat_state then targetColor = ImVec4(1,0.6,0.6,1) end -- Red if fighting and combat col hidden
                imgui.PushStyleColor(ImGuiCol.Text, targetColor); imgui.Text(peer.target or "None"); imgui.PopStyleColor()
            end
            -- Combat State Column
            if M.options.show_combat then
                imgui.TableNextColumn()
                local combatText, combatColor
                if peer.combat_state then combatText = "Fighting"; combatColor = ImVec4(1,0.7,0.7,1)
                else combatText = "Idle"; combatColor = ImVec4(0.7,1,0.7,1) end
                imgui.PushStyleColor(ImGuiCol.Text, combatColor); imgui.Text(combatText); imgui.PopStyleColor()
            end
            -- Casting Column
            if M.options.show_casting then
                imgui.TableNextColumn()
                local castText = peer.casting or "NULL"
                local castingColor = (castText == "NULL" or castText == "") and ImVec4(0.7,0.7,0.7,1) or ImVec4(0.8,0.8,1,1)
                imgui.PushStyleColor(ImGuiCol.Text, castingColor)
                if castText ~= "NULL" and castText ~= "" then imgui.Text(castText) else imgui.Text("") end
                imgui.PopStyleColor()
            end
        end
    end
    imgui.EndTable()
end


function M.draw_aa_window()
    if not M.show_aa_window.value then return end
    local window_open_ref = M.show_aa_window -- Pass the table itself for Begin's p_open
    imgui.SetNextWindowSize(ImVec2(250, 300), ImGuiCond.FirstUseEver)

    if imgui.Begin("Peer AA Counts", window_open_ref, ImGuiWindowFlags.NoCollapse) then
        if imgui.Button("Close##AAWinClose") then M.show_aa_window.value = false end
        imgui.Separator()

        local aa_list = {} -- Create a list of actual peers for AA display
        for _, p_item in ipairs(M.peer_list) do
            if not p_item.is_filler then table.insert(aa_list, p_item) end
        end
        table.sort(aa_list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)

        if imgui.BeginTable("PeerAATable", 2, bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY)) then
            imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn("AA Points", ImGuiTableColumnFlags.WidthFixed, 80)
            imgui.TableHeadersRow()
            for _, peer in ipairs(aa_list) do
                imgui.TableNextRow(); imgui.TableNextColumn(); imgui.Text(peer.name or "Unknown")
                imgui.TableNextColumn(); imgui.Text(tostring(peer.aa or 0))
            end
            imgui.EndTable()
        end
    end
    imgui.End()
    -- If Begin returns false (window closed by 'X'), window_open_ref.value is already set to false by ImGui
end

function M.draw_sort_editor()
    if not M.show_sort_editor or not M.show_sort_editor.value then return end
    M.options.custom_order = M.options.custom_order or {}
    local window_open = M.show_sort_editor.value
    imgui.SetNextWindowSize(ImVec2(300, 400), ImGuiCond.FirstUseEver)

    if imgui.Begin("Edit Peer Sort Order", window_open, ImGuiWindowFlags.NoCollapse) then
        imgui.Text("Custom Sort Order:")
        imgui.Separator()

        imgui.Columns(2, nil, false) -- 2 columns: Label + Buttons
        imgui.SetColumnWidth(0, 180)

        for i, entry in ipairs(M.options.custom_order) do
            imgui.PushID(i)
            if entry.type == "filler" then
                entry.filler_text = entry.filler_text or M.options.filler_char
                local new_text, changed = imgui.InputText("##fillertext_"..i, entry.filler_text)
                if changed then
                    entry.filler_text = new_text
                end
            else
                imgui.Text(M.peers[entry.id] and M.peers[entry.id].name or entry.id)
            end
            imgui.NextColumn()
            local buttonSize = ImVec2(36, 0)

            -- Second column: buttons
            imgui.PushStyleVar(ImGuiStyleVar.FramePadding, ImVec2(3, 2)) -- More readable padding

            if imgui.SmallButton("^", buttonSize) and i > 1 then
                M.options.custom_order[i], M.options.custom_order[i-1] = M.options.custom_order[i-1], M.options.custom_order[i]
            end
            imgui.SameLine()
            if imgui.SmallButton("v", buttonSize) and i < #M.options.custom_order then
                M.options.custom_order[i], M.options.custom_order[i+1] = M.options.custom_order[i+1], M.options.custom_order[i]
            end
            imgui.SameLine()
            if imgui.SmallButton("X", buttonSize) then
                table.remove(M.options.custom_order, i)
                imgui.PopStyleVar()
                imgui.PopID()
                imgui.NextColumn()
                goto continue
            end

            imgui.PopStyleVar()
            imgui.NextColumn()
            imgui.PopID()
            ::continue::
        end

        imgui.Columns(1) -- back to single-column layout

        local new_filler, changed = imgui.InputText("Filler Characters", M.options.filler_char)
        if changed then
            M.options.filler_char = new_filler
        end

        imgui.Separator()
        imgui.Text("Add Peer/Filler Row:")

        for id, peer in pairs(M.peers) do
            local in_order = false
            for _, entry in ipairs(M.options.custom_order) do
                if entry.id == id then
                    in_order = true
                    break
                end
            end
            if not in_order then
                imgui.PushID(id)
                if imgui.SmallButton(peer.name) then
                    table.insert(M.options.custom_order, {id = id})
                end
                imgui.PopID()
                imgui.SameLine()
            end
        end

        if imgui.SmallButton("+ Add Filler Row") then
            table.insert(M.options.custom_order, {
                type = "filler",
                filler_text = M.options.filler_char
            })
        end

        imgui.Separator()
        if imgui.Button("Save") then
            M.save_config()
            M.show_sort_editor.value = false
            M.options.sort_mode = "Custom"
        end
        imgui.SameLine()
        if imgui.Button("Cancel") then
            M.show_sort_editor.value = false
        end

        imgui.End()
    end
end

-- peers.lua
function M.load_config()
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local success, parsed_json = pcall(json.decode, content)
        if success and parsed_json and parsed_json[MyName] then
            local char_config = parsed_json[MyName]
            if char_config["custom_order_text"] and type(char_config["custom_order_text"]) == "string" then
                M.options.custom_order = {}
                local text_to_migrate = char_config["custom_order_text"]
                for line in text_to_migrate:gmatch("[^\r\n]+") do
                    table.insert(M.options.custom_order, line:match("^%s*(.-)%s*$"))
                end
                print(string.format("[Peers] Config: Migrated 'custom_order_text' to 'custom_order' for %s.", MyName))
                char_config["custom_order_text"] = nil
            end

            for k, v in pairs(char_config) do
                if M.options[k] ~= nil then
                    if k == "custom_order" then
                        if type(v) == "table" then
                            M.options.custom_order = v
                        else
                            print(string.format("\ar[Peers] Config Warning: 'custom_order' for %s was not a table, resetting.\ax", MyName))
                            M.options.custom_order = {}
                        end
                    elseif k ~= "custom_order_text" then -- Don't try to load the old key if we processed it
                        M.options[k] = v
                    end
                end
            end
        elseif not success then
            print(string.format("\ar[Peers] Error decoding config JSON: %s\ax", tostring(parsed_json)))
        end
    end
    if type(M.options.custom_order) ~= "table" then
        M.options.custom_order = {}
    end
end

function M.save_config()
    local all_config = {}
    local file_read = io.open(config_path, "r")
    if file_read then
        local content = file_read:read("*a")
        file_read:close()
        local success_decode, decoded_data = pcall(json.decode, content)
        if success_decode then
            all_config = decoded_data or {}
        else
            print(string.format("\ay[Peers] Could not decode existing config, starting fresh: %s\ax", tostring(decoded_data)))
        end
    end

    all_config[MyName] = M.options -- Save current character's options

    local file_write = io.open(config_path, "w")
    if file_write then
        local success_encode, encoded_data = pcall(json.encode, all_config, { indent = true })
        if success_encode then
            file_write:write(encoded_data)
        else
            print(string.format("\ar[Peers] Failed to encode config data: %s\ax", tostring(encoded_data)))
        end
        file_write:close()
        if success_encode then
            print(string.format("\ay[Peers] Saved UI config to %s\ax", config_path))
        end
    else
        print(string.format("\ar[Peers] Failed to write UI config to %s\ax", config_path))
    end
end

-- Main update function for the peer module
function M.update()
    refreshPeers()
    checkCombatState()
end

-- Initialization function
function M.init()
    print("[Peers] Initializing...")
    MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
    MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")
    if MyName == "Unknown" or MyServer == "Unknown" then
        print('\ar[Peers] Failed to get character name or server. Retrying on first update.\ax')
    end

    M.load_config()
    if M.options.show_dps then
        mq.cmdf('/bca //lua run spudbots')
    end

    -- Register DPS events
    mq.event("melee_crit", "#*#You score a critical hit!#*#(#1#)#*#", critCallBack)
    mq.event("melee_crit2", "#*#You deliver a critical blast!#*#(#1#)#*#", critCallBack)
    -- The following MyName based events might need to be re-registered if MyName changes (unlikely in one session)
    mq.event("melee_crit3", string.format("#*#%s scores a critical hit!#*#(#1#)#*#", MyName), critCallBack)
    mq.event("melee_deadly_strike", string.format("#*#%s scores a Deadly Strike!#*#(#1#)#*#", MyName), critCallBack)
    mq.event("melee_do_damage", "#*#You #1# #2# for #3# points of damage#*#", meleeCallBack)
    -- melee_miss is not strictly needed if only damage is tracked.
    mq.event("melee_non_melee", string.format("#*#%s hit #1# for #2# points of non-melee damage#*#", MyName), nonMeleeCallBack)
    mq.event("melee_damage_shield", "#*#was hit by non-melee for #2# points of damage#*#", nonMeleeCallBack)
    mq.event("melee_you_hit_non-melee", "#*#You were hit by non-melee for #2# damage#*#", nonMeleeCallBack)
    mq.event("melee_crit_heal", "#*#You perform an exceptional heal!#*#(#1#)#*#", critHealCallBack)
    print("[Peers] DPS events registered.")

    refreshPeers() -- Initial population
    print("[Peers] Initialization complete.")
end

-- Getters for main UI
function M.get_peer_data()
    return {
        list = M.peer_list,
        count = #M.peer_list, -- This now includes fillers
        my_aa = utils.safeTLO(mq.TLO.Me.AAPoints, 0),
        cached_height = cachedPeerHeight
    }
end

function M.get_refresh_interval()
    -- Determine refresh rate based on foreground status for performance
    if mq.TLO.EverQuest.Foreground() then
        return 1 -- FG_REFRESH_MS (very fast, ensure this is okay for CPU)
    else
        return 200 -- BG_REFRESH_MS (slower for background)
    end
    -- return REFRESH_INTERVAL_MS -- Original fixed interval
end

-- Bind for saving (consider if this is still needed or if UI save is enough)
mq.bind("/savepeerui", function()
    M.save_config()
end)

-- Utility for draw_custom_sort_ui to get a unique hex string for IDs.
if not utils.stringToHex then
    function utils.stringToHex(str)
        if not str then return "" end
        return (str:gsub('.', function (c)
            return string.format('%02x', string.byte(c))
        end))
    end
end


return M