-- ClickyList by Algar
-- written in part using Sonnet/Opus 4.5
-- Version 1.0
-- A script to display extensive info about your current clicky items
-- /lua run clickylist

local mq = require('mq')
local ImGui = require('ImGui')

local openGUI = true
local showConsumables = false
local clickyItems = {}
local animItems = mq.FindTextureAnimation("A_DragItem")
local sortColumn = 0
local sortAscending = true

local targetColors = {
    { type = "find",  values = { "self", "pet", },                color = { 1.0, 0.9, 0.5, 1, }, },
    { type = "exact", values = { "single", "single in group", },  color = { 1.0, 0.5, 0.5, 1, }, },
    { type = "find",  values = { "tap", },                        color = { 0.8, 0.3, 0.3, 1, }, },
    { type = "exact", values = { "corpse", },                     color = { 0.5, 0.5, 0.5, 1, }, },
    { type = "find",  values = { "target of target", },           color = { 1.0, 0.6, 0.85, 1, }, },
    { type = "find",  values = { "group", "ae pc", "pb", },       color = { 0.8, 0.6, 1.0, 1, }, },
    { type = "exact", values = { "free target", "targeted ae", }, color = { 0.4, 1.0, 0.4, 1, }, },
}
local defaultTargetColor = { 1.0, 1.0, 1.0, 1, }

local function addClickies(item)
    if item() and item.Clicky() and (showConsumables or (item.Clicky.MaxCharges() or 0) < 0) and (item.Clicky.RecastType() or 0) >= 0 then
        table.insert(clickyItems, {
            name = item.Name(),
            item = item,
            spell = item.Clicky.Spell,
            spellName = (item.Clicky.Spell() and item.Clicky.Spell.Name()) or "Unknown",
            castTime = item.Clicky.CastTime() or 0,
            recastDelay = item.Clicky.TimerID() or 0,
            recastType = item.Clicky.RecastType() or 0,
            requiredLevel = item.Clicky.RequiredLevel() or 0,
            targetType = (item.Clicky.Spell() and item.Clicky.Spell.TargetType()) or "Unknown",
            beneficial = item.Clicky.Spell() and item.Clicky.Spell.Beneficial(),
            iconId = (item.Icon() or 500) - 500,
        })
    end
end

local function applySorting()
    if #clickyItems <= 1 then return end

    table.sort(clickyItems, function(a, b)
        local va, vb
        if sortColumn == 0 then
            va, vb = a.name:lower(), b.name:lower()
        elseif sortColumn == 1 then
            va, vb = a.spellName:lower(), b.spellName:lower()
        elseif sortColumn == 2 then
            va, vb = a.targetType:lower(), b.targetType:lower()
        elseif sortColumn == 3 then
            va, vb = a.castTime, b.castTime
        elseif sortColumn == 4 then
            va, vb = a.recastDelay, b.recastDelay
        elseif sortColumn == 5 then
            va, vb = a.recastType, b.recastType
        elseif sortColumn == 6 then
            va, vb = a.requiredLevel, b.requiredLevel
        else
            return false
        end
        if va == vb then
            return a.name:lower() < b.name:lower()
        end
        if sortAscending then
            return va < vb
        else
            return va > vb
        end
    end)
end

local function scanClickyItems()
    clickyItems = {}

    for slot = 0, 22 do
        addClickies(mq.TLO.InvSlot(slot).Item)
    end

    for bag = 23, 32 do
        local bagItem = mq.TLO.InvSlot(bag).Item
        if bagItem() then
            addClickies(bagItem)
            local bagSlots = bagItem.Container() or 0
            for slot = 1, bagSlots do
                addClickies(bagItem.Item(slot))
            end
        end
    end

    applySorting()
end

local function renderGUI()
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    ImGui.SetNextWindowSize(ImVec2(950, 500), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSizeConstraints(ImVec2(390, 200), ImVec2(2000, 2000))
    local shouldDraw
    openGUI, shouldDraw = ImGui.Begin('Clicky List###clickylist', openGUI)

    if shouldDraw then
        if ImGui.Button("Rescan") then
            scanClickyItems()
        end
        ImGui.SameLine()
        ImGui.Text(string.format("Found %d clicky items", #clickyItems))
        ImGui.SameLine(ImGui.GetWindowWidth() - 160)
        local newShowConsumables = ImGui.Checkbox("Show Consumables", showConsumables)
        if newShowConsumables ~= showConsumables then
            showConsumables = newShowConsumables
            scanClickyItems()
        end

        ImGui.Separator()

        local tableFlags = bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY, ImGuiTableFlags.Sortable,
            ImGuiTableFlags.Hideable, ImGuiTableFlags.Reorderable)
        if ImGui.BeginTable("ClickyTable", 7, tableFlags) then
            ImGui.TableSetupColumn('Item', bit32.bor(ImGuiTableColumnFlags.WidthStretch, ImGuiTableColumnFlags.DefaultSort), 300.0)
            ImGui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch, 225.0)
            ImGui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed, 115.0)
            ImGui.TableSetupColumn('Cast', ImGuiTableColumnFlags.WidthFixed, 55.0)
            ImGui.TableSetupColumn('Recast', ImGuiTableColumnFlags.WidthFixed, 75.0)
            ImGui.TableSetupColumn('Timer', ImGuiTableColumnFlags.WidthFixed, 45.0)
            ImGui.TableSetupColumn('Min Lvl', ImGuiTableColumnFlags.WidthFixed, 60.0)
            ImGui.TableSetupScrollFreeze(0, 1)
            ImGui.TableHeadersRow()

            local sortSpecs = ImGui.TableGetSortSpecs()
            if sortSpecs and sortSpecs.SpecsDirty then
                local spec = sortSpecs:Specs(1)
                sortColumn = spec.ColumnIndex
                sortAscending = spec.SortDirection == ImGuiSortDirection.Ascending
                applySorting()
                sortSpecs.SpecsDirty = false
            end

            for idx, clicky in ipairs(clickyItems) do
                ImGui.TableNextRow()

                ImGui.TableNextColumn()
                local headerScreenPos = ImGui.GetCursorScreenPosVec()
                animItems:SetTextureCell(clicky.iconId)
                local drawList = ImGui.GetWindowDrawList()
                drawList:AddTextureAnimation(animItems, ImVec2(headerScreenPos.x, headerScreenPos.y), ImVec2(16, 16))
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + 20)
                if clicky.beneficial == true then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.4, 1.0, 0.4, 1))
                elseif clicky.beneficial == false then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(1.0, 0.4, 0.4, 1))
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.6, 0.9, 1, 1))
                end
                ImGui.PushStyleColor(ImGuiCol.HeaderHovered, ImGui.GetColorU32(0.12, 0.12, 0.12, 1))
                ImGui.PushID("item_" .. idx)
                local _, itemClicked = ImGui.Selectable(clicky.name)
                ImGui.PopStyleColor(2)
                if ImGui.IsItemHovered() then
                    ImGui.BeginTooltip()
                    ImGui.Text(string.format("Item ID: %s (click to inspect)", clicky.item.ID()))
                    ImGui.EndTooltip()
                end
                if itemClicked and clicky.item then
                    clicky.item.Inspect()
                end
                ImGui.PopID()

                ImGui.TableNextColumn()
                if clicky.spell and clicky.spell() then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(1, 0.65, 0, 1))
                    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, ImGui.GetColorU32(0.12, 0.12, 0.12, 1))
                    ImGui.PushID("spell_" .. idx)
                    local _, clicked = ImGui.Selectable(clicky.spellName)
                    ImGui.PopStyleColor(2)
                    if ImGui.IsItemHovered() then
                        ImGui.BeginTooltip()
                        ImGui.Text(string.format("Spell ID: %s (click to inspect)", clicky.spell.ID()))
                        ImGui.EndTooltip()
                    end
                    if clicked then
                        clicky.spell.Inspect()
                    end
                    ImGui.PopID()
                else
                    ImGui.TextDisabled(clicky.spellName)
                end

                ImGui.TableNextColumn()
                local targetLower = clicky.targetType:lower()
                local color = defaultTargetColor
                for _, entry in ipairs(targetColors) do
                    for _, value in ipairs(entry.values) do
                        if entry.type == "exact" and targetLower == value then
                            color = entry.color
                            break
                        elseif entry.type == "find" and targetLower:find(value) then
                            color = entry.color
                            break
                        end
                    end
                    if color ~= defaultTargetColor then
                        break
                    end
                end
                ---@diagnostic disable-next-line: deprecated
                ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(unpack(color)))
                ImGui.Text(clicky.targetType)
                ImGui.PopStyleColor()

                ImGui.TableNextColumn()
                if clicky.castTime <= 0 then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.4, 0.4, 0.4, 1))
                    ImGui.Text("-")
                    ImGui.PopStyleColor()
                else
                    local seconds = clicky.castTime / 1000
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.85, 0.9, 1.0, 1))
                    if seconds >= 60 then
                        local mins = math.floor(seconds / 60)
                        local secs = math.floor(seconds) % 60
                        ImGui.Text(tostring(mins))
                        ImGui.SameLine(0, 0)
                        if secs == 0 then
                            ImGui.Text("m")
                        else
                            ImGui.Text("m ")
                            ImGui.SameLine(0, 0)
                            ImGui.Text(tostring(secs))
                            ImGui.SameLine(0, 0)
                            ImGui.Text("s")
                        end
                    else
                        ImGui.Text(string.format("%.1f", seconds))
                        ImGui.SameLine(0, 0)
                        ImGui.Text("s")
                    end
                    ImGui.PopStyleColor()
                end

                ImGui.TableNextColumn()
                if clicky.recastDelay <= 0 then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.4, 0.4, 0.4, 1))
                    ImGui.Text("-")
                    ImGui.PopStyleColor()
                else
                    local seconds = clicky.recastDelay
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(1.0, 0.9, 0.7, 1))
                    if seconds >= 60 then
                        local mins = math.floor(seconds / 60)
                        local secs = math.floor(seconds) % 60
                        ImGui.Text(tostring(mins))
                        ImGui.SameLine(0, 0)
                        if secs == 0 then
                            ImGui.Text("m")
                        else
                            ImGui.Text("m ")
                            ImGui.SameLine(0, 0)
                            ImGui.Text(tostring(secs))
                            ImGui.SameLine(0, 0)
                            ImGui.Text("s")
                        end
                    else
                        ImGui.Text(tostring(seconds))
                        ImGui.SameLine(0, 0)
                        ImGui.Text("s")
                    end
                    ImGui.PopStyleColor()
                end

                ImGui.TableNextColumn()
                ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.7, 1.0, 0.8, 1))
                ImGui.Text(tostring(clicky.recastType))
                ImGui.PopStyleColor()

                ImGui.TableNextColumn()
                if clicky.requiredLevel <= 0 then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.4, 0.4, 0.4, 1))
                    ImGui.Text("-")
                elseif mq.TLO.Me.Level() >= clicky.requiredLevel then
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(0.4, 1.0, 0.4, 1))
                    ImGui.Text(tostring(clicky.requiredLevel))
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, ImGui.GetColorU32(1.0, 0.4, 0.4, 1))
                    ImGui.Text(tostring(clicky.requiredLevel))
                end
                ImGui.PopStyleColor()
            end

            ImGui.EndTable()
        end
    end

    ImGui.End()
end

scanClickyItems()
mq.imgui.init('ClickyList', renderGUI)

while openGUI do
    mq.delay(100)
end
