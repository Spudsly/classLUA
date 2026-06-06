local mq = require('mq')

local spells = {
    "Rangewind's Glacial Lance",
    "Freezing Direwind Shards",
    "Natedog's Meteor of Annihilation",
}

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local stickEngaged = false

-- Disengage if we zone while in combat
local function checkZoneChange()
    local currentZone = mq.TLO.Zone.ID()
    if currentZone ~= lastZone then
        lastZone = currentZone
        if engaged then
            print("Zoned while engaged, disengaging")
            engaged = false
            targetID = nil
        end
    end
end

-- Check if target is valid and alive
local function targetValid()
    if not targetID then return false end
    local spawn = mq.TLO.Spawn(targetID)
    if not spawn() then return false end
    return spawn.Type() == "NPC" and spawn.CurrentHPs() > 0
end

local function inCombat()
    return mq.TLO.Me.CombatState() == "COMBAT"
end

-- Find spell gem by name
local function getGemByName(name)
    for i = 1, 12 do
        local gem = mq.TLO.Me.Gem(i)
        if gem() and gem.Name() == name then
            return i
        end
    end
    return nil
end

local function useBackBuff()
    local back = mq.TLO.Me.Inventory("Back")
    if not back() then return false end
    local timer = back.TimerReady()
    if timer ~= nil and timer == 0 then
        local dur = (mq.TLO.Me.Buff("Ancient Stonewall XII").Duration() or 0)
        if dur == 0 then
            dur = (mq.TLO.Me.Buff("Ancient Stonewall XIII").Duration() or 0)
        end
        if dur >= 300000 then return false end
        mq.cmd('/nomodkey /itemnotify back rightmouseup')
        mq.delay(50)
        return true
    end
    return false
end

-- Try casting spells in order
local function trySpells()
    for _, spellName in ipairs(spells) do
        local gem = getGemByName(spellName)
        if gem and mq.TLO.Me.SpellReady(gem)() then
            mq.cmdf('/cast %d', gem)
            mq.delay(350)
            return true
        end
    end
    return false
end

local function useRightwristClicky()
    local rightwrist = mq.TLO.Me.Inventory("Rightwrist")
    if not rightwrist() then return false end
    if rightwrist.TimerReady() ~= 0 then return false end
    if (mq.TLO.Me.Buff("Cloak of").Duration() or 0) >= 300000 then return false end
    mq.cmd('/nomodkey /itemnotify rightwrist rightmouseup')
    mq.delay(50)
    return true
end

local function useCharmClicky()
    local charm = mq.TLO.Me.Inventory("Charm")
    if not charm() then return false end
    if (mq.TLO.Me.Buff("ultimate rune").ID() or 0) ~= 0 then return false end
    if (charm.TimerReady() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify charm rightmouseup')
    mq.delay(50)
    return true
end

local function useChestClicky()
    if not inCombat() then return false end
    local chest = mq.TLO.Me.Inventory("Chest")
    if not chest() then return false end
    if (chest.TimerReady() or 0) == 0 then
        mq.cmd('/itemnotify chest rightmouseup')
        mq.delay(50)
        return true
    end
    return false
end

local function doSelfBuffs()
    useBackBuff()
    useRightwristClicky()
    useCharmClicky()

    -- Thule's Nightmare Familiar
    if (mq.TLO.Me.Buff("Thule's Nightmare Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Thule\'s Nightmare Familiar" rightmouseup')
        mq.delay(50)
    end

    -- Thick Ether Skin (epic augment slot 13, no cooldown)
    if (mq.TLO.Me.Buff("Thick Ether Skin").ID() or 0) == 0 then
        mq.cmd('/itemnotify 13 rightmouseup')
        mq.delay(50)
    end

    -- Painfully Gorgeous (earring)
    if (mq.TLO.Me.Buff("Painfully Gorgeous").ID() or 0) == 0 then
        local rightEar = mq.TLO.Me.Inventory("Rightear")
        if rightEar() and (rightEar.Name() or ""):find("Earring of the Mystic Ages", 1, true) then
            mq.cmd('/itemnotify rightear rightmouseup')
            mq.delay(50)
        end
    end

    -- Cryomancy (self buff spell)
    if (mq.TLO.Me.Buff("Cryomancy").ID() or 0) == 0 then
        local gem = getGemByName("Cryomancy")
        if gem and mq.TLO.Me.SpellReady(gem)() then
            mq.cmdf('/cast %d', gem)
            mq.delay(50)
        end
    end

    -- Curious Creation (pet summon)
    if (mq.TLO.Pet.ID() or 0) == 0 then
        local gem = getGemByName("Curious Creation")
        if gem and mq.TLO.Me.SpellReady(gem)() then
            mq.cmdf('/cast %d', gem)
            mq.delay(50)
        end
    end
end

local function doAbilities()
    useChestClicky()

    -- Don't interrupt casting
    if not mq.TLO.Me.Casting() then
        -- 1. Try equipped ranged item first (slot-based)
        local ranged = mq.TLO.InvSlot("ranged").Item
        local usedWand = false
        if ranged() then
            local timer = ranged.TimerReady()
            if timer ~= nil and timer == 0 then
                mq.cmd('/itemnotify 11 rightmouseup')
                mq.delay(350)
                usedWand = true
            end
        end
        if not usedWand then
            -- 2. Try spells if wand was not used
            trySpells()
        end
    end

    -- Powersource slot click (Brain of Cazic Thule / The Necronomicon / any, in-combat only)
    if inCombat() then
        local ps = mq.TLO.Me.Inventory("Powersource")
        if ps() then
            local timer = ps.TimerReady()
            if timer ~= nil and timer == 0 then
                mq.cmd('/itemnotify powersource rightmouseup')
                mq.delay(50)
            end
        end
    end
end

-- Bind the /engage command
mq.bind('/engage', function(id)
    id = tonumber(id)
    if id == 0 then
        print("Running self-buffs...")
        for i = 1, 10 do
            doSelfBuffs()
            mq.delay(200)
        end
        print("Self-buffs complete")
        return
    end

    targetID = id
    engaged = true
    stickEngaged = true

    mq.cmdf('/tar id %d', targetID)
    mq.delay(50)
    mq.cmd('/stick 15 uw behind loose hold')
    mq.delay(50)
    mq.cmd('/attack on')

    print(string.format("Engaging target ID %d", targetID))
end)

-- Bind /disengage to stop
mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    stickEngaged = false
    print("Disengaged")
end)

print("Wizard nuke script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        doSelfBuffs()
        if stickEngaged then
            if (tonumber(mq.TLO.Target.ID()) or 0) ~= targetID then
                stickEngaged = false
            elseif mq.TLO.Me.Moving() then
                stickEngaged = false
            else
                mq.cmd('/stick 15 uw behind loose hold')
            end
        end
        if (tonumber(mq.TLO.Target.Distance()) or 999) <= 25 then
            doAbilities()
        end
    end

    mq.delay(50)
end