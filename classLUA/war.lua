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
        if dur >= 600000 then return false end
        mq.cmd('/nomodkey /itemnotify back rightmouseup')
        mq.delay(50)
        return true
    end
    return false
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

    -- Deranged Goblin Familiar (always up, or out of combat without pet)
    if (mq.TLO.Me.Buff("Deranged Goblin Blessing").ID() or 0) == 0 or (not inCombat() and (mq.TLO.Pet.ID() or 0) == 0) then
        local goblin = mq.TLO.FindItem("=Deranged Goblin Familiar")
        if goblin() and goblin.TimerReady() == 0 then
            mq.cmd('/itemnotify "Deranged Goblin Familiar" rightmouseup')
            mq.delay(50)
        end
    end

    -- Divine Intervention (Reward Item)
    if (mq.TLO.Me.Buff("Self Only Divine Intervention Clickie").ID() or 0) == 0 then
        local di = mq.TLO.FindItem("=Divine Intervention (Reward Item)")
        if di() and di.TimerReady() == 0 then
            mq.cmd('/itemnotify "Divine Intervention (Reward Item)" rightmouseup')
            mq.delay(50)
        end
    end

    useCharmClicky()

    -- Epic mainhand augment (slot 13, ~5s cooldown, Warrior's Defense VIII buff)
    if (mq.TLO.Me.Buff("Warrior's Defense VIII").ID() or 0) == 0 and os.clock() - epicTimer >= 5 then
        mq.cmd('/itemnotify 13 rightmouseup')
        epicTimer = os.clock()
        mq.delay(50)
    end
end

local function doAbilities()
    doSelfBuffs()

    -- Bashful Crustaceans' Angerbomb
    local bomb = mq.TLO.FindItem("=Bashful Crustaceans' Angerbomb")
    if bomb() and bomb.TimerReady() == 0 then
        mq.cmd('/itemnotify "Bashful Crustaceans\' Angerbomb" rightmouseup')
        mq.delay(50)
    end

    -- Essence of Hate (powersource slot)
    local ps = mq.TLO.Me.Inventory("Powersource")
    if ps() and (ps.Name() or ""):find("Essence of Hate", 1, true) then
        local timer = ps.TimerReady()
        if timer ~= nil and timer == 0 then
            mq.cmd('/itemnotify powersource rightmouseup')
            mq.delay(50)
        end
    end
    if mq.TLO.Me.AbilityReady("Taunt")() then
        mq.cmd('/doability Taunt')
        mq.delay(50)
    end

    -- Cover discipline
    if mq.TLO.Me.CombatAbilityReady("Cover")() and inCombat() then
        mq.cmd('/discipline Cover')
        mq.delay(50)
    end
end

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

    mq.cmdf('/tar id %d', targetID)
    mq.delay(50)
    mq.cmd('/stick 15 uw loose hold')
    mq.delay(50)
    mq.cmd('/attack on')

    print(string.format("Engaging target ID %d", targetID or 0))
end)

mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    print("Disengaged")
end)

print("Warrior combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        mq.cmd('/stick 15 uw loose hold')
        doAbilities()
    end

    mq.delay(50)
end