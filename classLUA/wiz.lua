local mq = require('mq')

local spells = {
    "Rangewind's Glacial Lance",
    "Freezing Direwind Shards",
    "Natedog's Meteor of Annihilation",
}

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()

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

local function inCombat()
    return mq.TLO.Me.CombatState() == "COMBAT"
end

-- Check if target is valid and alive
local function targetValid()
    if not targetID then return false end
    local spawn = mq.TLO.Spawn(targetID)
    if not spawn() then return false end
    return spawn.Type() == "NPC" and spawn.CurrentHPs() > 0
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

local function doSelfBuffs()
    useBackBuff()
end

local function doAbilities()
    doSelfBuffs()

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
        doSelfBuffs()
        print("Self-buffs complete")
        return
    end

    targetID = id
    engaged = true

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
        mq.cmd('/stick 15 uw behind loose hold')
        doAbilities()
    end

    mq.delay(100)
end