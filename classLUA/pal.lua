local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local stickEngaged = false

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

local function targetValid()
    if not targetID then return false end
    local spawn = mq.TLO.Spawn(targetID)
    if not spawn() then return false end
    return spawn.Type() == "NPC" and spawn.CurrentHPs() > 0
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

local function useDenyDeath()
    if (mq.TLO.Me.Buff("Ancient: Deny Death I").ID() or 0) ~= 0 then return false end
    if (mq.TLO.Me.Buff("Ancient: Deny Death II").ID() or 0) ~= 0 then return false end
    local ring = mq.TLO.FindItem("Legendary Ring of the Ages")
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

local function doSelfBuffs()
    useBackBuff()

    -- Earring of the Mystic Ages Rank 50 (left or right ear)
    if (mq.TLO.Me.Buff("Painfully Gorgeous").ID() or 0) == 0 then
        local ear = mq.TLO.FindItem("=Earring of the Mystic Ages Rank 50")
        if ear() and ear.TimerReady() == 0 then
            mq.cmd('/casting "Earring of the Mystic Ages Rank 50" item')
            mq.delay(50)
        end
    end

    -- Deranged Goblin Familiar
    if (mq.TLO.Me.Buff("Deranged Goblin Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Deranged Goblin Familiar" rightmouseup')
        mq.delay(50)
    end

    -- Fastest Travel (Reward Item)
    if (mq.TLO.Me.Buff("Fastest Travel Clickie").ID() or 0) == 0 then
        local travel = mq.TLO.FindItem("=Fastest Travel (Reward Item)")
        if travel() and travel.TimerReady() == 0 then
            mq.cmd('/casting "Fastest Travel (Reward Item)" item')
            mq.delay(50)
        end
    end

    useDenyDeath()

    -- Yaulp XII
    if (mq.TLO.Me.Song("Yaulp XII").ID() or 0) == 0 then
        mq.cmd('/casting "Yaulp XII"')
        mq.delay(50)
    end

    -- Holy Aura
    if (mq.TLO.Me.Aura("Holy Aura").ID() or 0) == 0 then
        mq.cmd('/casting "Holy Aura"')
        mq.delay(50)
    end

    -- Grace of the crusader
    if (mq.TLO.Me.Buff("Grace of the crusader").ID() or 0) == 0 then
        mq.cmd('/casting "Grace of the crusader"')
        mq.delay(50)
    end

    -- Gift of the Avenger II
    if (mq.TLO.Me.Buff("Gift of the Avenger II").ID() or 0) == 0 then
        mq.cmd('/casting "Gift of the Avenger II"')
        mq.delay(50)
    end

    useCharmClicky()

    -- Kaldar's Helping Hand II
    if (mq.TLO.Me.Buff("Kaldar's Helping Hand II").ID() or 0) == 0 then
        mq.cmd('/casting "Kaldar\'s Helping Hand II"')
        mq.delay(50)
    end
end

local function doAbilities()
    doSelfBuffs()

    -- Crabtwoshoes Will Heal You Three! (combat heal)
    if mq.TLO.Me.SpellReady("Crabtwoshoes Will Heal You Three!")() and inCombat() then
        mq.cmd('/casting 11934')
        mq.delay(50)
    end
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
    stickEngaged = true

    mq.cmdf('/tar id %d', targetID)
    mq.delay(50)
    mq.cmd('/stick 15 uw behind loose hold')
    mq.delay(50)
    mq.cmd('/attack on')

    print(string.format("Engaging target ID %d", targetID or 0))
end)

mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    stickEngaged = false
    print("Disengaged")
end)

print("Paladin combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        mq.cmdf('/tar id %d', targetID)
        if stickEngaged then
            if mq.TLO.Me.Moving() and (tonumber(mq.TLO.Target.Distance()) or 999) < 25 then
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