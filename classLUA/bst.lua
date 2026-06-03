local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()

local spells = {
    "Vicious Ice VII",
    "Vicious Ice VI",
    "Vicious Ice V",
    "Vicious Ice IV",
    "Vicious Ice III",
    "Glacial Spear",
    "Trushar's Frost",
    "Ancient: Frozen Chaos",
    "Frost Spear",
    "Blizzard blast",
}

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

local function getGemByName(name)
    for i = 1, 12 do
        local gem = mq.TLO.Me.Gem(i)
        if gem() and gem.Name() == name then
            return i
        end
    end
    return nil
end

local function targetValid()
    if not targetID then return false end
    local spawn = mq.TLO.Spawn(targetID)
    if not spawn() then return false end
    return spawn.CurrentHPs() > 0
end

local function inCombat()
    return mq.TLO.Me.CombatState() == "COMBAT"
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

-- Deny Death (any rank X through XV)
local function useDenyDeath()
    if (mq.TLO.Me.Buff("Ancient: Deny Death I").ID() or 0) ~= 0 then return false end
    if (mq.TLO.Me.Buff("Ancient: Deny Death II").ID() or 0) ~= 0 then return false end
    local ring = mq.TLO.FindItem("=Legendary Ring of the Ages X")
    if not ring() then return false end
    if ring.Timer() ~= 0 then return false end
    mq.cmdf('/casting "%s" item', ring.Name())
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

    -- Painfully Gorgeous (right ear)
    if (mq.TLO.Me.Buff("Painfully Gorgeous").ID() or 0) == 0 then
        local rightEar = mq.TLO.Me.Inventory("Rightear")
        if rightEar() and (rightEar.Name() or ""):find("Earring of the Mystic Ages", 1, true) then
            mq.cmd('/itemnotify rightear rightmouseup')
            mq.delay(50)
        end
    end

    -- Wings of the Angel (ammo)
    if (mq.TLO.Me.Buff("Timeless: Haste").ID() or 0) == 0 then
        local ammo = mq.TLO.Me.Inventory("Ammo")
        if ammo() and (ammo.Name() or ""):find("Wings of the Angel", 1, true) then
            local wings = mq.TLO.FindItem("Wings of the Angel")
            if wings() and wings.Timer() == 0 then
                mq.cmd('/itemnotify ammo rightmouseup')
                mq.delay(50)
            end
        end
    end

    -- Fastest Travel
    if (mq.TLO.Me.Buff("Fastest Travel Clickie").ID() or 0) == 0 then
        local travel = mq.TLO.FindItem("=Fastest Travel (Reward Item)")
        if travel() and travel.Timer() == 0 then
            mq.cmd('/itemnotify "Fastest Travel (Reward Item)" rightmouseup')
            mq.delay(50)
        end
    end

    -- Right wrist (Cloak of Anarchy)
    if (mq.TLO.Me.Buff("Cloak of Anarchy").Duration() or 0) < 300000 then
        local rightwrist = mq.TLO.Me.Inventory("Rightwrist")
        if rightwrist() and (rightwrist.TimerReady() or 0) == 0 then
            mq.cmd('/nomodkey /itemnotify rightwrist rightmouseup')
            mq.delay(50)
        end
    end

    -- Thule's Nightmare Familiar
    if (mq.TLO.Me.Buff("Thule's Nightmare Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Thule\'s Nightmare Familiar" rightmouseup')
        mq.delay(50)
    end

    useDenyDeath()

    -- Call of the Alpha I
    if (mq.TLO.Me.Buff("Call of the Alpha I").ID() or 0) == 0 then
        mq.cmd('/cast "Call of the Alpha I"')
        mq.delay(50)
    end
end

local function doAbilities()
    doSelfBuffs()

    -- Chest clicky
    if inCombat() then
        local chest = mq.TLO.Me.Inventory("Chest")
        if chest() and (chest.TimerReady() or 0) == 0 then
            mq.cmd('/itemnotify chest rightmouseup')
            mq.delay(50)
        end
    end

    -- Combat rotation: disc then spells (both fire independently like the macro)
    if engaged and targetValid() and not mq.TLO.Me.Casting() then
        if inCombat() and mq.TLO.Me.CombatAbilityReady("Bestial Fury Discipline")() then
            mq.cmd('/disc Bestial Fury Discipline')
            mq.delay(50)
        end
        if not mq.TLO.Me.Casting() then
            trySpells()
        end
    end

    useCharmClicky()
end

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
    mq.cmd('/pet attack')
    mq.cmd('/stick 15 uw behind loose hold')
    mq.delay(50)
    mq.cmd('/attack on')

    print(string.format("Engaging target ID %d", targetID))
end)

mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    print("Disengaged")
end)

print("Beastlord combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        doAbilities()
    end

    mq.delay(50)
end
