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

local function doSelfBuffs()
    useBackBuff()
    useDenyDeath()
    useRightwristClicky()

    -- Holy Blessing of Intervention (out of combat only)
    if not inCombat() and mq.TLO.Me.SpellReady("Holy Blessing of Intervention")() then
        mq.cmd('/casting "Holy Blessing of Intervention"')
        mq.delay(50)
    end

    -- Aura of the Zealot
    if (mq.TLO.Me.Aura("Aura of the Zealot").ID() or 0) == 0 then
        mq.cmd('/casting "Aura of the Zealot"')
        mq.delay(50)
    end

    -- Deranged Goblin Familiar
    local goblinBuff = (mq.TLO.Me.Buff("Deranged Goblin Blessing").ID() or 0) ~= 0
    local hasPet = (mq.TLO.Pet.ID() or 0) ~= 0
    if not goblinBuff or (not inCombat() and not hasPet) then
        mq.cmd('/itemnotify "Deranged Goblin Familiar" rightmouseup')
        mq.delay(50)
    end

    -- Amplify Healing II
    if (mq.TLO.Me.Buff("Amplify Healing II").ID() or 0) == 0 then
        mq.cmd('/casting "Amplify Healing II"')
        mq.delay(50)
    end

    useCharmClicky()

    -- Yaulp X
    if (mq.TLO.Me.Song("Yaulp X").ID() or 0) == 0 then
        mq.cmd('/casting "Yaulp X"')
        mq.delay(50)
    end

end

local function doAbilities()
    doSelfBuffs()

    -- Celestial Regeneration (epic weapon augment, 30s os.clock timer)
    if inCombat() then
        local now = os.clock()
        if now - epicTimer >= 30 then
            local pubiseTarget = mq.TLO.Spawn("=Pubise pc")
            if pubiseTarget() then
                mq.cmdf('/tar id %d', pubiseTarget.ID())
                mq.delay(50)
                mq.cmd('/itemnotify 13 rightmouseup')
                epicTimer = os.clock()
                mq.delay(50)
                if targetID then
                    mq.cmdf('/tar id %d', targetID)
                    mq.delay(50)
                end
            end
        end
    end

    -- Ring of the High Priest
    if inCombat() then
        local ring = mq.TLO.FindItem("=Ring of the High Priest")
        if ring() and ring.TimerReady() == 0 then
            mq.cmd('/itemnotify rightfinger rightmouseup')
            mq.delay(50)
        end
    end

    -- Holy Cataclysm, fallback to 33383 on Pubise pc
    if mq.TLO.Me.SpellReady("Holy Cataclysm")() then
        mq.cmd('/cast "Holy Cataclysm"')
        mq.delay(50)
    else
        local pubiseTarget = mq.TLO.Spawn("=Pubise pc")
        if pubiseTarget() then
            mq.cmdf('/casting 33383 -targetid|%d', pubiseTarget.ID())
            mq.delay(50)
            -- Retarget original mob after healing Pubise
            if targetID then
                mq.cmdf('/tar id %d', targetID)
                mq.delay(50)
            end
        end
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

print("Cleric combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        if tonumber(mq.TLO.Target.Distance()) > 20 then
            mq.cmd('/stick 15 uw behind loose hold')
        end
        doAbilities()
    end

    mq.delay(50)
end
