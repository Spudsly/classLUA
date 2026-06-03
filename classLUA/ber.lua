local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local epicTimer = 0
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

local function useSkill(name)
    if mq.TLO.Me.AbilityReady(name)() then
        mq.cmdf('/doability "%s"', name)
        mq.delay(50)
        return true
    end
    return false
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

local function useCombatClicky(itemName)
    if not inCombat() then return false end
    local item = mq.TLO.FindItem("=" .. itemName)
    if not item() then return false end
    if item.TimerReady() ~= 0 then return false end
    local slot = tonumber(item.InvSlot())
    if slot == nil or slot < 0 or slot > 22 then return false end
    mq.cmdf('/itemnotify "%s" rightmouseup', itemName)
    mq.delay(50)
    return true
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

local function useAngryface()
    if (mq.TLO.Me.Buff("Angryface Blessing").ID() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify "Angryface Familiar (Halloween Reward)" rightmouseup')
    mq.delay(50)
    return true
end

local function useZerkerHaste()
    if (mq.TLO.Me.Buff("Over Raided Zerker Haste").ID() or 0) ~= 0 then return false end
    local ammo = mq.TLO.Me.Inventory("Ammo")
    if not ammo() then return false end
    if not (ammo.Name() or ""):find("Over Raided Zerker Haste", 1, true) then return false end
    if (ammo.TimerReady() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify ammo rightmouseup')
    mq.delay(50)
    return true
end

local function doSelfBuffs()
    useBackBuff()
    useDenyDeath()
    useRightwristClicky()
    useAngryface()
    useZerkerHaste()

    -- Aura of Rage
    if (mq.TLO.Me.Song("Aura of Rage").ID() or 0) == 0 then
        mq.cmd("/disc Aura of rage")
        mq.delay(50)
    end

    -- Cry Havoc
    if (mq.TLO.Me.Song("Cry Havoc").ID() or 0) == 0 then
        mq.cmd("/disc Cry Havoc")
        mq.delay(50)
    end
end

local function doAbilities()
    doSelfBuffs()
    useChestClicky()
    useCombatClicky("Pendant of Mayong Mistmoore")

    useSkill("Frenzy")

    -- Epic weapon (slot 13, ~6s cooldown)
    if os.clock() - epicTimer >= 6 then
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

print("Berserker combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        if stickEngaged then
            if mq.TLO.Me.Moving() and tonumber(mq.TLO.Target.Distance()) < 25 then
                stickEngaged = false
            else
                mq.cmd('/stick 15 uw behind loose hold')
            end
        end
        doAbilities()
    end

    mq.delay(50)
end
