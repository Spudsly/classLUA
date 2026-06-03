local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local epicTimer = 0

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

local function useDerangedGoblin()
    if (mq.TLO.Me.Buff("Deranged Goblin Blessing").ID() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify "Deranged Goblin Familiar" rightmouseup')
    mq.delay(50)
    return true
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

local function useDeathKnightArmor()
    if (mq.TLO.Me.Buff("Death Knight's Armor").ID() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify rightfinger rightmouseup')
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
    useDerangedGoblin()
    useDenyDeath()

    -- Death Knight's Armor
    useDeathKnightArmor()

    -- Call of the Void V
    if (mq.TLO.Me.Buff("Call of the Void V").ID() or 0) == 0 then
        mq.cmd('/cast "Call of the Void V"')
        mq.delay(50)
    end

    useCharmClicky()
end

local function doAbilities()
    doSelfBuffs()

    -- Shadowbane Scourge III
    local scourge3Dur = mq.TLO.Target.MyBuffDuration("Shadowbane Scourge III")()
    if not scourge3Dur or scourge3Dur < 6000 then
        mq.cmd('/casting "Shadowbane Scourge III"')
        mq.delay(50)
    end

    -- Vaelthyr's Agony
    local agonyDur = mq.TLO.Target.MyBuffDuration("Vaelthyr's Agony")()
    if (not agonyDur or agonyDur < 6000) and mq.TLO.Me.SpellReady("Vaelthyr's Agony")() then
        mq.cmd('/casting "Vaelthyr\'s Agony"')
        mq.delay(50)
    end

    -- Shadowbane Scourge II
    local scourge2Dur = mq.TLO.Target.MyBuffDuration("Shadowbane Scourge II")()
    if not scourge2Dur or scourge2Dur < 6000 then
        mq.cmd('/casting "Shadowbane Scourge II"')
        mq.delay(50)
    end

    -- Vile Tightness IV
    local vileDur = mq.TLO.Target.MyBuffDuration("Vile Tightness IV")()
    if not vileDur or vileDur < 6000 then
        mq.cmd('/casting "Vile Tightness IV"')
        mq.delay(50)
    end

    -- Epic weapon (slot 13, ~365s cooldown)
    if os.clock() - epicTimer >= 365 then
        mq.cmd('/itemnotify 13 rightmouseup')
        epicTimer = os.clock()
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
    print("Disengaged")
end)

print("Shadow Knight combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

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
