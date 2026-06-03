local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local epicTimer = 0
local epicAttempt = 0

local function hasOneManBand()
    return (mq.TLO.Me.Buff("one man band").ID() or 0) ~= 0
end

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
    -- Wings of the Angel (ammo slot)
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

    useBackBuff()
    useRightwristClicky()

    -- Furious Sentinel Familiar
    if (mq.TLO.Me.Buff("Furious Sentinel Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Furious Sentinel Familiar" rightmouseup')
        mq.delay(50)
    end

    useCharmClicky()
end

local function doAbilities()
    doSelfBuffs()
    doCombat()
end

local function doCombat()
    -- Twist control: start in combat, stop out of combat
    if not mq.TLO.Twist.Twisting() and inCombat() then
        mq.cmd('/twist 1 2 3 4')
        mq.delay(50)
    end
    if mq.TLO.Twist.Twisting() and not inCombat() then
        mq.cmd('/twist stop')
        mq.delay(50)
    end

    -- Deftdance Discipline
    if mq.TLO.Me.CombatAbilityReady("Deftdance Discipline")() and inCombat() then
        mq.cmd('/disc Deftdance Discipline')
        mq.delay(50)
    end

    -- Fierce Eye
    if mq.TLO.Me.AltAbilityReady("Fierce Eye")() and inCombat() then
        mq.cmd('/alt act 3506')
        mq.delay(50)
    end

    -- Epic click (primary slot 13, aug click — no TimerReady)
    if inCombat() then
        local now = os.clock()
        -- If we attempted and 2s passed, verify the buff appeared
        if epicAttempt > epicTimer and now - epicAttempt >= 2 then
            if hasOneManBand() then
                epicTimer = epicAttempt
            else
                epicTimer = now - 70  -- retry immediately
                epicAttempt = 0
            end
        end
        -- Click if cooldown expired and no pending attempt
        if epicAttempt <= epicTimer and now - epicTimer >= 70 then
            mq.cmd('/itemnotify 13 rightmouseup')
            epicAttempt = os.clock()
            mq.delay(50)
        end
    end

    -- Ring of the Virtuoso, Rank II (slot 16)
    if inCombat() then
        local ring = mq.TLO.FindItem("=Ring of the Virtuoso, Rank II")
        if ring() and ring.TimerReady() == 0 then
            mq.cmd('/useitem 16')
            mq.delay(50)
        end
    end
end

mq.bind('/engage', function(id)
    id = tonumber(id)
    if not id then
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
    if mq.TLO.Twist.Twisting() then
        mq.cmd('/twist stop')
    end
    print("Disengaged")
end)

print("Bard combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

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
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        doAbilities()
    end

    mq.delay(50)
end