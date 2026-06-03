local mq = require('mq')

local engaged = false
local buffMode = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()

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

local function useFuriousSentinel()
    if (mq.TLO.Me.Buff("Furious Sentinel Blessing").ID() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify "Furious Sentinel Familiar" rightmouseup')
    mq.delay(50)
    return true
end

local function doSelfBuffs()
    useRightwristClicky()

    -- Ancestral Harmony (right ear)
    if (mq.TLO.Me.Buff("Ancestral Harmony").ID() or 0) == 0 then
        local rightEar = mq.TLO.Me.Inventory("Rightear")
        if rightEar() and (rightEar.Name() or ""):find("Ascended Earring of the Wild Ages Rank I", 1, true) then
            mq.cmd('/itemnotify rightear rightmouseup')
            mq.delay(50)
        end
    end

    useBackBuff()
    useFuriousSentinel()
    useDenyDeath()

    -- Croton's Empowering Scepter (click from inventory)
    if (mq.TLO.Me.Buff("Wisest Healer II").ID() or 0) == 0 then
        local scepter = mq.TLO.FindItem("=Croton's Empowering Scepter")
        if scepter() and mq.TLO.Cast.Ready("Croton's Empowering Scepter")() then
            mq.cmd('/itemnotify "Croton\'s Empowering Scepter" rightmouseup')
            mq.delay(50)
        end
    end

    useCharmClicky()
end

local function doAbilities()
    -- Wand in ranged slot (slot-based)
    if not mq.TLO.Me.Casting() then
        local ranged = mq.TLO.InvSlot("ranged").Item
        if ranged() then
            local timer = ranged.TimerReady()
            if timer ~= nil and timer == 0 then
                mq.cmd('/itemnotify 11 rightmouseup')
                mq.delay(350)
            end
        end
    end

    -- Ancestral Grudge
    if (mq.TLO.Me.Song("Ancestral Grudge").ID() or 0) == 0 and inCombat() and mq.TLO.Me.SpellReady("Ancestral Grudge")() then
        mq.cmd('/itemnotify 18 rightmouseup')
        mq.delay(50)
        mq.cmd('/casting "10604"')
        mq.delay(50)
        if targetID then
            mq.cmdf('/tar id %d', targetID)
            mq.delay(50)
        end
    end

    doSelfBuffs()
    useChestClicky()

    -- Champion on Rubette, then retarget
    if (mq.TLO.Me.Buff("Champion").ID() or 0) == 0 and inCombat() then
        local rubette = mq.TLO.Spawn("=Rubette pc")
        if rubette() then
            mq.cmdf('/casting "5417" -targetid|%d', rubette.ID())
            mq.delay(50)
            if targetID then
                mq.cmdf('/tar id %d', targetID)
                mq.delay(50)
            end
        end
    end

    -- Ring of the Spiritwalker
    if inCombat() then
        local ring = mq.TLO.FindItem("=Ring of the Spiritwalker, Rank II")
        if ring() and ring.TimerReady() == 0 then
            mq.cmd('/useitem 16')
            mq.delay(50)
        end
    end

    -- Plague of the North II
    local plagueDur = mq.TLO.Target.MyBuffDuration("Plague of the North II")()
    if not plagueDur or plagueDur < 6000 then
        mq.cmd('/casting "Plague of the North II"')
        mq.delay(50)
    end

    -- Powersource slot (Brain of Cazic Thule / any clicky)
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

mq.bind('/engage', function(id)
    id = tonumber(id)
    if not id then
        buffMode = true
        engaged = false
        targetID = nil
        print("Self-buff mode activated. Use /disengage to stop")
        return
    end

    targetID = id
    engaged = true
    buffMode = false

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
    buffMode = false
    print("Disengaged")
end)

print("Shaman combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if buffMode then
        doSelfBuffs()
    elseif engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    elseif engaged and targetValid() then
        mq.cmd('/attack on')
        doAbilities()
    end

    mq.delay(50)
end
