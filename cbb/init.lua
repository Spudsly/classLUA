-- BigBagGUI_Actors.lua 

-- Use the actors/mailbox system in place of Redis
local mq     = require("mq")
local json   = require("dkjson")
local actors = require("actors")
local imgui  = require("ImGui") 
local Icons = require("mq.Icons")

local openGUI         = true
local showFullWindow  = false
local debug_mode      = false 

local ICON_WIDTH       = 40
local ICON_HEIGHT      = 40
local COUNT_X_OFFSET   = 39
local COUNT_Y_OFFSET   = 23
local EQ_ICON_OFFSET   = 500
local BAG_ITEM_SIZE    = 40
local INVENTORY_DELAY_SECONDS = 10 -- Time between inventory publish operations 

local animItems = mq.FindTextureAnimation("A_DragItem")
local animBox   = mq.FindTextureAnimation("A_RecessedBox") 

local show_item_background = true
local filter_text = "" 

-- Tab system
local current_tab = 1 -- 1 = Inventory, 2 = Bank
local TAB_INVENTORY = 1
local TAB_BANK = 2

local peer_inventories = {}     -- Store inventory data received from peers
local peer_bank_data = {}       -- Store bank data received from peers
local selected_peer   = mq.TLO.Me.Name() 
local headerFont = nil
local headerFontLoaded = false

local DIABLO_THEME = {
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
    tab = {0.18, 0.11, 0.05, 0.92},
    tabHovered = {0.30, 0.18, 0.08, 0.96},
    tabActive = {0.42, 0.25, 0.10, 0.98},
    tabUnfocused = {0.12, 0.08, 0.05, 0.90},
    tabUnfocusedActive = {0.22, 0.14, 0.07, 0.94},
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
    headerHeight = 34,
}

-- Debug helper
local function debug_print(...)
    if debug_mode then
        print("[BigBagGUI Debug]", ...)
    end
end 

-- Modifier helpers
local function is_alt_down()
    local ok, io = pcall(imgui.GetIO)
    if ok and io then
        if io.KeyAlt then return true end
    end
    if imgui.IsKeyDown then
        return imgui.IsKeyDown(ImGuiMod.Alt) or false
    end
    return false
end

local function tryLoadHeaderFont()
    if headerFontLoaded then return end
    headerFontLoaded = true

    local ok, io = pcall(imgui.GetIO)
    if not ok or not io or not io.Fonts or not io.Fonts.AddFontFromFileTTF then
        return
    end

    local candidates = {
        'C:/Windows/Fonts/ariblk.ttf',
        'C:/Windows/Fonts/impact.ttf',
        'C:/Windows/Fonts/arialbd.ttf',
    }

    for _, fontPath in ipairs(candidates) do
        local font = io.Fonts:AddFontFromFileTTF(fontPath, 16)
        if font then
            headerFont = font
            break
        end
    end
end

local function push_diablo_window_style()
    local pushedColors = 0
    local pushedVars = 0

    imgui.PushStyleColor(ImGuiCol.WindowBg, unpack(DIABLO_THEME.windowBg)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.Border, unpack(DIABLO_THEME.border)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TitleBg, unpack(DIABLO_THEME.titleBg)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TitleBgActive, unpack(DIABLO_THEME.titleBgActive)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.FrameBg, unpack(DIABLO_THEME.frameBg)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.FrameBgHovered, unpack(DIABLO_THEME.frameBgHovered)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.FrameBgActive, unpack(DIABLO_THEME.frameBgActive)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.Button, unpack(DIABLO_THEME.button)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, unpack(DIABLO_THEME.buttonHovered)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.ButtonActive, unpack(DIABLO_THEME.buttonActive)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.Tab, unpack(DIABLO_THEME.tab)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TabHovered, unpack(DIABLO_THEME.tabHovered)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TabActive, unpack(DIABLO_THEME.tabActive)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TabUnfocused, unpack(DIABLO_THEME.tabUnfocused)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.TabUnfocusedActive, unpack(DIABLO_THEME.tabUnfocusedActive)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.Header, unpack(DIABLO_THEME.header)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.HeaderHovered, unpack(DIABLO_THEME.headerHovered)); pushedColors = pushedColors + 1
    imgui.PushStyleColor(ImGuiCol.HeaderActive, unpack(DIABLO_THEME.headerActive)); pushedColors = pushedColors + 1

    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, DIABLO_THEME.windowRounding); pushedVars = pushedVars + 1
    imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, DIABLO_THEME.windowBorderSize); pushedVars = pushedVars + 1
    imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, DIABLO_THEME.frameRounding); pushedVars = pushedVars + 1
    imgui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, DIABLO_THEME.frameBorderSize); pushedVars = pushedVars + 1
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 10, 10); pushedVars = pushedVars + 1

    return pushedColors, pushedVars
end

local function pop_diablo_window_style(pushedColors, pushedVars)
    if pushedVars and pushedVars > 0 then imgui.PopStyleVar(pushedVars) end
    if pushedColors and pushedColors > 0 then imgui.PopStyleColor(pushedColors) end
end

local function draw_diablo_header(title)
    tryLoadHeaderFont()

    local avail = imgui.GetContentRegionAvail()
    local width = type(avail) == 'number' and avail or (avail.x or 0)
    local headerHeight = DIABLO_THEME.headerHeight
    local xsize = 28

    imgui.PushStyleColor(ImGuiCol.ChildBg, unpack(DIABLO_THEME.childBg))
    imgui.PushStyleColor(ImGuiCol.Border, unpack(DIABLO_THEME.headerBorder))
    imgui.BeginChild('##cbb_header', 0, headerHeight, true, bit32.bor(ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse))

    local startX, startY = imgui.GetCursorPos()
    local closeX = math.max(startX, width - xsize - 8)
    local pulse = 0.5 + (math.sin(os.clock() * 2.8) * 0.5)

    local fullTitle = title or 'CBB'

    local leftPad = startX + 10
    local rightPad = closeX - 12

    if headerFont then imgui.PushFont(headerFont) end
    local fullWidth = imgui.CalcTextSize(fullTitle)
    local textX = leftPad + math.max(0, (rightPad - leftPad - fullWidth) * 0.5)
    local textY = startY + math.max(0, math.floor((headerHeight - 18) * 0.5) - 1)

    imgui.SetCursorPos(textX, textY)
    imgui.TextColored(DIABLO_THEME.titleText[1], DIABLO_THEME.titleText[2], DIABLO_THEME.titleText[3], DIABLO_THEME.titleText[4], fullTitle)

    if title and title ~= '' then
        local glowA = (DIABLO_THEME.glowText[4] or 0.24) + pulse * 0.08
        local gr, gg, gb = DIABLO_THEME.glowText[1], DIABLO_THEME.glowText[2], DIABLO_THEME.glowText[3]
        imgui.SetCursorPos(textX - 1, textY)
        imgui.TextColored(gr, gg, gb, glowA, title)
        imgui.SetCursorPos(textX + 1, textY)
        imgui.TextColored(gr, gg, gb, glowA, title)
        imgui.SetCursorPos(textX, textY - 1)
        imgui.TextColored(gr, gg, gb, glowA * 0.85, title)
        imgui.SetCursorPos(textX, textY + 1)
        imgui.TextColored(gr, gg, gb, glowA * 0.85, title)
        imgui.SetCursorPos(textX, textY)
        imgui.TextColored(DIABLO_THEME.accentText[1], DIABLO_THEME.accentText[2], DIABLO_THEME.accentText[3], DIABLO_THEME.accentText[4], title)
    end
    if headerFont then imgui.PopFont() end

    imgui.SetCursorPos(closeX, startY + math.max(6, math.floor((headerHeight - 20) * 0.5)))
    local hoverPulse = 0.5 + (math.sin(os.clock() * 10.0) * 0.5)
    local pulseMix = hoverPulse * 0.08
    imgui.PushStyleColor(ImGuiCol.Button, DIABLO_THEME.closeButton[1], DIABLO_THEME.closeButton[2], DIABLO_THEME.closeButton[3], DIABLO_THEME.closeButton[4])
    imgui.PushStyleColor(
        ImGuiCol.ButtonHovered,
        math.min(1.0, DIABLO_THEME.closeHover[1] + pulseMix),
        math.min(1.0, DIABLO_THEME.closeHover[2] + pulseMix),
        math.min(1.0, DIABLO_THEME.closeHover[3] + pulseMix),
        DIABLO_THEME.closeHover[4]
    )
    imgui.PushStyleColor(ImGuiCol.ButtonActive, DIABLO_THEME.closeActive[1], DIABLO_THEME.closeActive[2], DIABLO_THEME.closeActive[3], DIABLO_THEME.closeActive[4])
    if imgui.SmallButton('X##cbb_close') then
        showFullWindow = false
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Close this window')
    end
    imgui.PopStyleColor(3)

    imgui.EndChild()
    imgui.PopStyleColor(2)
    imgui.Spacing()
end

local function format_number(n)
    local s = tostring(n)
    local sep = ","
    local formatted = s:reverse():gsub("(%d%d%d)", "%1"..sep):reverse()
    if formatted:sub(1,1) == sep then
        formatted = formatted:sub(2)
    end
    return formatted
end

-- Toggle full window display
local function toggleBigBagGUI()
    showFullWindow = not showFullWindow
end
mq.bind("/cbbui", toggleBigBagGUI) 

-- Mailbox (actors) system: Inventory update handler 
local function inventory_update_handler(message)
    local data = message()
    if type(data) ~= "table" or not data.name then
        debug_print("Received invalid inventory update message.")
        return
    end
    peer_inventories[data.name] = data
    debug_print("Updated inventory for: " .. data.name)
end 

-- Mailbox (actors) system: Bank update handler 
local function bank_update_handler(message)
    local data = message()
    if type(data) ~= "table" or not data.name then
        debug_print("Received invalid bank update message.")
        return
    end
    peer_bank_data[data.name] = data
    debug_print("Updated bank data for: " .. data.name)
end 

-- Register mailboxes for inventory and bank updates
local inventory_mailbox = actors.register("inventory_update", inventory_update_handler)
local bank_mailbox = actors.register("bank_update", bank_update_handler)

if not inventory_mailbox then
    print("\ar[BigBagGUI] Failed to register inventory update mailbox.\ax")
else
    debug_print("Inventory update mailbox registered successfully.")
end 

if not bank_mailbox then
    print("\ar[BigBagGUI] Failed to register bank update mailbox.\ax")
else
    debug_print("Bank update mailbox registered successfully.")
end

-- Gathering Inventory Data for Publishing 
local function gatherInventoryForPublish()
    local bags = {}
    for bagSlot = 23, 34 do
        local slot = mq.TLO.Me.Inventory(bagSlot)
        local bag = { count = 1, items = {} } 
    if slot() and slot.Container() and slot.Container() > 0 then
        bag.count = slot.Container()
        for i = 1, slot.Container() do
            local item = slot.Item(i)
            if item() and item.ID() then
            bag.items[i] = {
            name  = tostring(item.Name() or "Unknown"),
            icon  = tonumber(item.Icon() or 0),
            stack = tonumber(item.Stack() or 1),
        }
            else
            bag.items[i] = nil  -- explicitly set nil (or a placeholder) at position i
            end
        end
    elseif slot() and slot.ID() then
        table.insert(bag.items, {
            name  = tostring(slot.Name() or "Unknown"),
            icon  = tonumber(slot.Icon() or 0),
            stack = tonumber(slot.Stack() or 1),
        })
    else
        table.insert(bag.items, nil)
    end
        bags[tostring(bagSlot)] = bag
    end 

    local currencies = {
    platinum = mq.TLO.Me.Platinum() or 0,
    gold     = mq.TLO.Me.Gold() or 0,
    silver   = mq.TLO.Me.Silver() or 0,
    copper   = mq.TLO.Me.Copper() or 0,
    }

    return {
        name      = tostring(mq.TLO.Me.Name()),
        timestamp = os.time(),
        bags      = bags,
        currencies = currencies,
    }
end 

-- Gathering Bank Data for Publishing
local function gatherBankForPublish()
    local bank_bags = {}
    
    -- Shared bank slots (2000-2023)
    for bankSlot = 1, 24 do
        local slot = mq.TLO.Me.Bank(bankSlot)
        local bag = { count = 1, items = {} }
        
        if slot() and slot.Container() and slot.Container() > 0 then
            bag.count = slot.Container()
            for i = 1, slot.Container() do
                local item = slot.Item(i)
                if item() and item.ID() then
                    bag.items[i] = {
                        name  = tostring(item.Name() or "Unknown"),
                        icon  = tonumber(item.Icon() or 0),
                        stack = tonumber(item.Stack() or 1),
                    }
                else
                    bag.items[i] = nil
                end
            end
        elseif slot() and slot.ID() then
            table.insert(bag.items, {
                name  = tostring(slot.Name() or "Unknown"),
                icon  = tonumber(slot.Icon() or 0),
                stack = tonumber(slot.Stack() or 1),
            })
        else
            table.insert(bag.items, nil)
        end
        bank_bags[tostring(bankSlot)] = bag
    end

    return {
        name      = tostring(mq.TLO.Me.Name()),
        timestamp = os.time(),
        bank_bags = bank_bags,
        bank_accessible = true,
    }
end

-- Gathering Bags for local drawing (UI only) 
local function gatherBags()
    local bags = {}
    for bagSlot = 23, 34 do
        local slot = mq.TLO.Me.Inventory(bagSlot)
        local bagEntry = {
            id    = string.format("bag_%d", bagSlot),
            items = {},
            count = 0,
            isBag = false,
        } 
    if slot() and slot.Container() and slot.Container() > 0 then
        bagEntry.isBag = true
        bagEntry.count = slot.Container()
        for inside = 1, slot.Container() do
            local item = slot.Item(inside)
            local cellID = string.format("bag_%d_slot_%d", bagSlot, inside)
            bagEntry.items[inside] = {
                item = (item.ID() and item) or nil,
                id   = cellID,
            }
        end
    else
        bagEntry.isBag = false
        bagEntry.count = 1
        local cellID = string.format("bag_%d_slot_1", bagSlot)
        bagEntry.items[1] = {
            item = (slot.ID() and slot) or nil,
            id   = cellID,
        }
    end
        bags[bagSlot] = bagEntry
    end
    return bags
end 

-- Gathering Bank bags for local drawing (UI only)
local function gatherBankBags()
    local bank_bags = {}
    
    for bankSlot = 1, 24 do
        local slot = mq.TLO.Me.Bank(bankSlot)
        local bagEntry = {
            id    = string.format("bank_%d", bankSlot),
            items = {},
            count = 0,
            isBag = false,
        }
        
        if slot() and slot.Container() and slot.Container() > 0 then
            bagEntry.isBag = true
            bagEntry.count = slot.Container()
            for inside = 1, slot.Container() do
                local item = slot.Item(inside)
                local cellID = string.format("bank_%d_slot_%d", bankSlot, inside)
                bagEntry.items[inside] = {
                    item = (item.ID() and item) or nil,
                    id   = cellID,
                }
            end
        else
            bagEntry.isBag = false
            bagEntry.count = 1
            local cellID = string.format("bank_%d_slot_1", bankSlot)
            bagEntry.items[1] = {
                item = (slot.ID() and slot) or nil,
                id   = cellID,
            }
        end
        bank_bags[bankSlot] = bagEntry
    end
    return bank_bags
end

-- Convert peer inventory data's bags into a structure consumable by the UI
local function gatherPeerBags(peer_data)
    local bags = {}
    for bagSlotStr, bagData in pairs(peer_data.bags or {}) do
        local bagSlot = tonumber(bagSlotStr)
        local items = {}
        local count = bagData.count or 0
        for i = 1, count do
            local itemData = type(bagData.items) == "table" and bagData.items[i] or nil
            items[i] = {
                item = itemData and {
                Name      = function() return itemData.name end,
                Icon      = function() return itemData.icon end,
                Stack     = function() return itemData.stack end,
                ItemSlot  = function() return bagSlot end,
                ItemSlot2 = function() return i end,
            } or nil,
                id = string.format("bag_%d_slot_%d", bagSlot, i),
            }
        end
    bags[bagSlot] = {
        id    = string.format("bag_%d", bagSlot),
        items = items,
        count = count,
        isBag = true,
    }   
    end
    return bags
end

-- Convert peer bank data into a structure consumable by the UI
local function gatherPeerBankBags(peer_data)
    local bank_bags = {}
    for bankSlotStr, bagData in pairs(peer_data.bank_bags or {}) do
        local bankSlot = tonumber(bankSlotStr)
        local items = {}
        local count = bagData.count or 0
        for i = 1, count do
            local itemData = type(bagData.items) == "table" and bagData.items[i] or nil
            items[i] = {
                item = itemData and {
                Name      = function() return itemData.name end,
                Icon      = function() return itemData.icon end,
                Stack     = function() return itemData.stack end,
                ItemSlot  = function() return bankSlot end,
                ItemSlot2 = function() return i - 1 end,
            } or nil,
                id = string.format("bank_%d_slot_%d", bankSlot, i),
            }
        end
        bank_bags[bankSlot] = {
            id    = string.format("bank_%d", bankSlot),
            items = items,
            count = count,
            isBag = true,
        }   
    end
    return bank_bags
end

-- UI Helper functions for drawing inventory slots 
local function draw_empty_slot(cell_id)
    local cursor_x, cursor_y = imgui.GetCursorPos()
    if show_item_background then
        imgui.DrawTextureAnimation(animBox, ICON_WIDTH, ICON_HEIGHT)
    end
    imgui.SetCursorPos(cursor_x, cursor_y)
    imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.3, 0, 0.2)
    imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    imgui.Button("##empty_" .. cell_id, ICON_WIDTH, ICON_HEIGHT)
    imgui.PopStyleColor(3)

    if imgui.IsItemHovered() and imgui.IsMouseClicked(ImGuiMouseButton.Left) then
        local altPrefix = is_alt_down() and "/nomodkey /altkey " or ""
        local bagSlot, slotIndex = cell_id:match("bag_(%d+)_slot_(%d+)")
        local bankSlot, bankIndex = cell_id:match("bank_(%d+)_slot_(%d+)")

        -- Allow either dropping cursor item or forwarding Alt+Left to the spot
        if mq.TLO.Cursor.ID() or is_alt_down() then
            if bagSlot and slotIndex then
                mq.cmd((altPrefix.."/itemnotify in pack%d %d leftmouseup"):format(tonumber(bagSlot) - 22, tonumber(slotIndex)))
            elseif bagSlot then
                mq.cmd((altPrefix.."/itemnotify %d leftmouseup"):format(tonumber(bagSlot)))
            elseif bankSlot and bankIndex then
                bankSlot = tonumber(bankSlot)
                bankIndex = tonumber(bankIndex)

                if bankSlot >= 25 then
                    local shared = bankSlot - 24
                    mq.cmd((altPrefix.."/itemnotify in sharedbank%d %d leftmouseup"):format(shared, bankIndex - 1))
                else
                    mq.cmd((altPrefix.."/itemnotify in bank%d %d leftmouseup"):format(bankSlot, bankIndex))
                end
            elseif bankSlot then
                bankSlot = tonumber(bankSlot)
                if bankSlot >= 25 then
                    local shared = bankSlot - 24
                    mq.cmd((altPrefix.."/itemnotify sharedbank%d leftmouseup"):format(shared))
                else
                    mq.cmd((altPrefix.."/itemnotify bank%d leftmouseup"):format(bankSlot + 1))
                end
            end
        end
    end
end

local function draw_item_icon(item, cell_id)
    local cursor_x, cursor_y = imgui.GetCursorPos()
    if show_item_background then
        imgui.DrawTextureAnimation(animBox, ICON_WIDTH, ICON_HEIGHT)
    end
    imgui.SetCursorPos(cursor_x, cursor_y)

    local iconId = item.Icon() or EQ_ICON_OFFSET
    animItems:SetTextureCell(math.max(0, iconId - EQ_ICON_OFFSET))
    imgui.DrawTextureAnimation(animItems, ICON_WIDTH, ICON_HEIGHT)

    if item.Stack() > 1 then
        imgui.SetWindowFontScale(0.68)
        local stackStr = tostring(item.Stack())
        local textSize = imgui.CalcTextSize(stackStr)
        local textX = cursor_x + COUNT_X_OFFSET - textSize
        local textY = cursor_y + COUNT_Y_OFFSET
        local textH = imgui.GetTextLineHeight()
        local padX, padY = 2, 1

        -- Draw a dark backdrop so stack text stays readable on bright icons.
        local drawList = imgui.GetWindowDrawList()
        if drawList then
            local winX, winY = imgui.GetWindowPos()
            drawList:AddRectFilled(
                ImVec2(winX + textX - padX, winY + textY - padY),
                ImVec2(winX + textX + textSize + padX, winY + textY + textH - padY),
                0xC0000000,
                2.0
            )
        end

        imgui.SetCursorPos(textX, textY)
        imgui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 1.0, 1.0)
        imgui.TextUnformatted(stackStr)
        imgui.PopStyleColor()
        imgui.SetWindowFontScale(1.0)
    end

    imgui.SetCursorPos(cursor_x, cursor_y)
    imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0, 0.3, 0, 0.2)
    imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0.3, 0, 0.3)
    imgui.Button("##item_" .. cell_id, ICON_WIDTH, ICON_HEIGHT)
    imgui.PopStyleColor(3)

    if imgui.IsItemHovered() then
        local tooltip_text = item.Name()
        if item.Stack() > 1 then
            tooltip_text = tooltip_text .. " (x" .. item.Stack() .. ")"
        end
        imgui.SetTooltip(tooltip_text)
    end

    local function click_item(withAlt)
        local slot = item.ItemSlot()
        local subslot = item.ItemSlot2()
        local altPrefix = withAlt and "/nomodkey /altkey " or ""

        if string.match(cell_id, "bank_") then
            if slot >= 25 then
                local shared = slot - 24
                if subslot == -1 then
                    mq.cmd((altPrefix.."/itemnotify sharedbank%d leftmouseup"):format(shared))
                else
                    mq.cmd((altPrefix.."/itemnotify in sharedbank%d %d leftmouseup"):format(shared, subslot))
                end
            else
                if subslot == -1 then
                    mq.cmd((altPrefix.."/itemnotify bank%d leftmouseup"):format(slot))
                else
                    mq.cmd((altPrefix.."/itemnotify in bank%d %d leftmouseup"):format(slot + 1, subslot + 1))
                end
            end
        else
            if subslot == -1 then
                mq.cmd((altPrefix.."/itemnotify %d leftmouseup"):format(slot))
            else
                mq.cmd((altPrefix.."/itemnotify in pack%d %d leftmouseup"):format(slot - 22, subslot + 1))
            end
        end
    end

    if imgui.IsItemClicked(ImGuiMouseButton.Left) then
        -- If Alt is held and we are not carrying an item, open ItemDisplay directly via clickable link when possible.
        if is_alt_down() and not mq.TLO.Cursor.ID() then
            local link = nil
            if item.ItemLink then
                -- Prefer the exact clickable link from the TLO when available
                link = item.ItemLink("CLICKABLE")()
            end
            if link and link ~= "" and mq.ExtractLinks and mq.ExecuteTextLink then
                local links = mq.ExtractLinks(link)
                if links and #links > 0 then
                    mq.ExecuteTextLink(links[1])
                else
                    -- Fallback to slot click with Alt modifier if link extraction fails
                    click_item(true)
                end
            else
                -- Fallback if we cannot build a link (e.g., peer data): try slot click with Alt modifier
                click_item(true)
            end
        else
            click_item(is_alt_down())
        end
    elseif imgui.IsItemClicked(ImGuiMouseButton.Right) then
        mq.cmdf('/useitem "%s"', item.Name())
    elseif imgui.IsItemHovered() and imgui.IsMouseClicked(ImGuiMouseButton.Left) and mq.TLO.Cursor.ID() then
        click_item(is_alt_down())
    end
end

-- UI functions to display bag contents and options 
local function display_bag_content()
    local bags
    if selected_peer == mq.TLO.Me.Name() then
        bags = gatherBags()
    else
        local pdata = peer_inventories[selected_peer]
        if pdata and pdata.bags then
        bags = gatherPeerBags(pdata)
        else
        bags = {}
        end
    end 

    local region_width = imgui.GetWindowContentRegionWidth()
    local cols = math.max(1, math.floor(region_width / BAG_ITEM_SIZE)) 

    imgui.SetWindowFontScale(1.25)
    local total_used, total_slots = 0, 0
    for _, bag in pairs(bags) do
        for _, cell in ipairs(bag.items) do
        total_slots = total_slots + 1
        if cell.item then total_used = total_used + 1 end
        end
    end
    local total_free = total_slots - total_used
    if selected_peer == mq.TLO.Me.Name() then
        total_free = mq.TLO.Me.FreeInventory() or 0
    end
    imgui.TextUnformatted(string.format("Used/Free Slots (%d/%d)", total_used, total_free))
    imgui.SameLine()
    imgui.SetWindowFontScale(1.0)
    do
        local hasCursorItem = mq.TLO.Cursor.ID() ~= nil
        if not hasCursorItem then imgui.BeginDisabled(true) end
        -- Make the destroy button red
        imgui.PushStyleColor(ImGuiCol.Button,        0.85, 0.15, 0.15, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.95, 0.35, 0.35, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive,  0.75, 0.10, 0.10, 1.0)
        if imgui.SmallButton("Destroy Cursor") then
            if mq.TLO.Cursor.ID() then
                mq.cmd('/destroy')
            else
                print('[CBB] No item on cursor to destroy.')
            end
        end
        imgui.PopStyleColor(3)
        if not hasCursorItem then
            if imgui.IsItemHovered() then imgui.SetTooltip('Put an item on your cursor to destroy it.') end
            imgui.EndDisabled()
        end
    end
    imgui.SetWindowFontScale(1.0)
    imgui.Separator()
    imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(0, 0)) 

    for bagSlot = 23, 32 do
        local bag = bags[bagSlot]
        if bag then
        if bag.isBag then
            local pack_number = bagSlot - 22
            imgui.Dummy(0, 5)
            imgui.TextUnformatted(string.format("Pack %d", pack_number))
            imgui.Dummy(0, 5)
        end
        imgui.BeginGroup()
        local current_col = 1
        for index, cell in ipairs(bag.items) do
            local item = cell.item
            local cell_id = cell.id
            local should_show = true
            if filter_text ~= "" and item then
            should_show = string.match(string.lower(item.Name()), string.lower(filter_text)) ~= nil
            end
            if should_show then
            if item then
                draw_item_icon(item, cell_id)
            else
                draw_empty_slot(cell_id)
            end
            end
            if current_col < cols then
            current_col = current_col + 1
            imgui.SameLine()
            else
            current_col = 1
            end
        end
        imgui.EndGroup()
        end
    end 

    imgui.PopStyleVar()
end 

-- New function to display bank contents
local function display_bank_content()
    local bank_bags
    if selected_peer == mq.TLO.Me.Name() then
        bank_bags = gatherBankBags()
    else
        local pdata = peer_bank_data[selected_peer]
        if pdata and pdata.bank_bags then
            bank_bags = gatherPeerBankBags(pdata)
        else
            bank_bags = {}
            imgui.SetWindowFontScale(1.25)
            imgui.PushStyleColor(ImGuiCol.Text, 1.0, 0.8, 0.2, 1.0) -- Orange warning text
            imgui.TextUnformatted("No bank data available for " .. selected_peer)
            imgui.PopStyleColor()
            imgui.SetWindowFontScale(1.0)
            imgui.TextUnformatted("Bank data is only available when the player is at a banker.")
            imgui.Separator()
            return
        end
    end 

    local region_width = imgui.GetWindowContentRegionWidth()
    local cols = math.max(1, math.floor(region_width / BAG_ITEM_SIZE)) 

    imgui.SetWindowFontScale(1.25)
    local total_used, total_slots = 0, 0
    for _, bag in pairs(bank_bags) do
        for _, cell in ipairs(bag.items) do
            total_slots = total_slots + 1
            if cell.item then total_used = total_used + 1 end
        end
    end
    local total_free = total_slots - total_used
    imgui.TextUnformatted(string.format("Bank Used/Free Slots (%d/%d)", total_used, total_free))
    imgui.SameLine()
    imgui.SetWindowFontScale(1.0)
    do
        local hasCursorItem = mq.TLO.Cursor.ID() ~= nil
        if not hasCursorItem then imgui.BeginDisabled(true) end
        -- Make the destroy button red
        imgui.PushStyleColor(ImGuiCol.Button,        0.85, 0.15, 0.15, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.95, 0.35, 0.35, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive,  0.75, 0.10, 0.10, 1.0)
        if imgui.SmallButton("Destroy Cursor") then
            if mq.TLO.Cursor.ID() then
                mq.cmd('/destroy')
            else
                print('[CBB] No item on cursor to destroy.')
            end
        end
        imgui.PopStyleColor(3)
        if not hasCursorItem then
            if imgui.IsItemHovered() then imgui.SetTooltip('Put an item on your cursor to destroy it.') end
            imgui.EndDisabled()
        end
    end
    imgui.SetWindowFontScale(1.0)
    imgui.Separator()
    imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(0, 0)) 

    for bankSlot = 1, 24 do
        local bag = bank_bags[bankSlot]
        if bag then
            if bag.isBag then
                imgui.Dummy(0, 5)
                imgui.TextUnformatted(string.format("Bank Bag %d", bankSlot))
                imgui.Dummy(0, 5)
            end
            imgui.BeginGroup()
            local current_col = 1
            for index, cell in ipairs(bag.items) do
                local item = cell.item
                local cell_id = cell.id
                local should_show = true
                if filter_text ~= "" and item then
                    should_show = string.match(string.lower(item.Name()), string.lower(filter_text)) ~= nil
                end
                if should_show then
                    if item then
                        draw_item_icon(item, cell_id)
                    else
                        draw_empty_slot(cell_id)
                    end
                end
                if current_col < cols then
                    current_col = current_col + 1
                    imgui.SameLine()
                else
                    current_col = 1
                end
            end
            imgui.EndGroup()
        end
    end 

    imgui.PopStyleVar()
end

local function display_bag_utilities()
    imgui.PushItemWidth(200)
    local text, selected = imgui.InputText("##FilterInput", filter_text)
    imgui.PopItemWidth()
    if selected then
        filter_text = string.gsub(text, "[^a-zA-Z0-9%s'`_.-]", "") or ""
    end
    imgui.SameLine()
    if imgui.SmallButton("Clear##FilterClear") then
        filter_text = ""
    end
    imgui.SameLine()
    imgui.Checkbox("Show Background", show_item_background)
end 

local function display_bag_options()
    imgui.Text("Viewing Inventory of:")
    imgui.SameLine()
    if imgui.BeginCombo("##PeerSelect", selected_peer) then
        if imgui.Selectable(mq.TLO.Me.Name(), selected_peer == mq.TLO.Me.Name()) then
        selected_peer = mq.TLO.Me.Name()
        end
        for name, _ in pairs(peer_inventories) do
        if name ~= mq.TLO.Me.Name() then
            if imgui.Selectable(name, selected_peer == name) then
            selected_peer = name
            end
        end
        end
        imgui.EndCombo()
    end
    local peer_count = 0
    for _ in pairs(peer_inventories) do
        peer_count = peer_count + 1
    end
    imgui.SameLine(imgui.GetWindowWidth() - 150)
    imgui.Text("Peers: " .. peer_count)
    local pdata = selected_peer == mq.TLO.Me.Name() and gatherInventoryForPublish() or peer_inventories[selected_peer]
    if pdata and pdata.currencies then
        imgui.Text("Plat: ")
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Text, 1.0, 0.85, 0.1, 1.0) -- gold
        imgui.Text(format_number(pdata.currencies.platinum))
        imgui.PopStyleColor()

        imgui.SameLine()
        imgui.Text(" | G: ")
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Text, 0.95, 0.65, 0.15, 1.0) -- goldenrod
        imgui.Text(format_number(pdata.currencies.gold))
        imgui.PopStyleColor()

        imgui.SameLine()
        imgui.Text(" | S: ")
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Text, 0.75, 0.75, 0.75, 1.0) -- silver
        imgui.Text(format_number(pdata.currencies.silver))
        imgui.PopStyleColor()

        imgui.SameLine()
        imgui.Text(" | C: ")
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Text, 0.9, 0.45, 0.2, 1.0) -- copper
        imgui.Text(format_number(pdata.currencies.copper))
        imgui.PopStyleColor()
    end
end 

local function BigBagToggle()
    ImGui.SetNextWindowSize(160, 70, ImGuiCond.Always)
    ImGui.Begin("BagToggle", nil, bit32.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoBackground))

    local time = mq.gettime() / 1000
    local pulse = (math.sin(time * 3) + 1) * 0.5 -- Pulses between 0 and 1
    local base_color = showFullWindow and {0.2, 0.8, 0.2, 1.0} or {0.7, 0.2, 0.2, 1.0}
    local hover_color = {
        math.min(1, base_color[1] + 0.2 * pulse),
        math.min(1, base_color[2] + 0.2 * pulse),
        math.min(1, base_color[3] + 0.2 * pulse),
        1.0
    }

    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 25)
    ImGui.PushStyleColor(ImGuiCol.Button,       ImVec4(base_color[1], base_color[2], base_color[3], 0.8))
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,ImVec4(hover_color[1], hover_color[2], hover_color[3], 1.0))
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(base_color[1]*0.8, base_color[2]*0.8, base_color[3]*0.8, 1.0))

    local icon = Icons.MD_SHOPPING_BASKET or ""
    local button_label = string.format("%s %s", icon, showFullWindow and "Hide Bags" or "Show Bags")

    if ImGui.Button(button_label, 150, 50) then
        showFullWindow = not showFullWindow
    end

    ImGui.PopStyleColor(3)
    ImGui.PopStyleVar()
    ImGui.End()
end

-- Main GUI function with tabs
local function BigBagGUI()
    if showFullWindow then
        local pushedColors, pushedVars = push_diablo_window_style()
        imgui.SetNextWindowSize(600, 400, ImGuiCond.FirstUseEver)
        local open = imgui.Begin("EZ Bags##Diablo", true, bit32.bor(ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoTitleBar))

        if open then
            draw_diablo_header('EZ Bags')

            if imgui.BeginTabBar("BagTabs") then
                if imgui.BeginTabItem("Inventory") then
                    current_tab = TAB_INVENTORY
                    display_bag_utilities()
                    display_bag_options()
                    imgui.Separator()
                    display_bag_content()
                    imgui.EndTabItem()
                end

                if imgui.BeginTabItem("Bank") then
                    current_tab = TAB_BANK
                    display_bag_utilities()
                    display_bag_options()
                    imgui.Separator()
                    display_bank_content()
                    imgui.EndTabItem()
                end

                imgui.EndTabBar()
            end
        end

        imgui.End()
        pop_diablo_window_style(pushedColors, pushedVars)
    end
end 

-- Publishing our own inventory update via mailbox 
local lastPublishTime = os.time() 
local lastBankPublishTime = os.time()

local function publishInventory()
    local now = os.time()
    if now - lastPublishTime < INVENTORY_DELAY_SECONDS then return end
    local inventoryData = gatherInventoryForPublish()
    -- Update our local peer cache:
    peer_inventories[inventoryData.name] = inventoryData
    -- Publish the update via our mailbox:
    if inventory_mailbox then
        inventory_mailbox:send({ mailbox = "inventory_update" }, inventoryData)
        debug_print("Published inventory update for " .. inventoryData.name)
    end
    lastPublishTime = now
end 

local function publishBankData()
    local now = os.time()
    if now - lastBankPublishTime < INVENTORY_DELAY_SECONDS then return end
    local bankData = gatherBankForPublish()
    -- Update our local peer cache:
    peer_bank_data[bankData.name] = bankData
    -- Publish the update via our mailbox:
    if bank_mailbox then
        bank_mailbox:send({ mailbox = "bank_update" }, bankData)
        debug_print("Published bank update for " .. bankData.name)
    end
    lastBankPublishTime = now
end 

-- Main loop 
mq.imgui.init("BigBagGUI", function()
    BigBagToggle()
    if showFullWindow then
        BigBagGUI()
    end
end)

while openGUI do
    publishInventory()  -- periodically publish our inventory update
    publishBankData()   -- periodically publish our bank data
    -- Process any incoming mailbox messages (actors system)
    mq.delay(50) -- small delay to limit CPU usage
end
