local mq = require('mq')

local combatActions = {
    { type = "skill", name = "Backstab" },
}

local chestClickies = {
}

local combatBuffClickies = {
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

-- Per MQ2CharacterType.cpp, these readiness members return bool by name.
local function useDisc(name)
    if mq.TLO.Me.CombatAbilityReady(name)() then
        mq.cmdf('/disc "%s"', name)
        mq.delay(50)
        return true
    end
    return false
end

local function useSkill(name)
    if mq.TLO.Me.AbilityReady(name)() then
        mq.cmdf('/doability "%s"', name)
        mq.delay(50)
        return true
    end
    return false
end

local function useAltAbility(name)
    if mq.TLO.Me.AltAbilityReady(name)() then
        local aa = mq.TLO.Me.AltAbility(name)
        local aaID = aa.ID()
        if not aaID or aaID <= 0 then return false end

        mq.cmdf('/alt act %d', aaID)
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

local function useCombatBuffClicky(clicky)
    if not inCombat() then return false end

    local buff = mq.TLO.Me.Buff(clicky.buff)
    if buff() then return false end

    local item = mq.TLO.FindItem("=" .. clicky.name)
    if not item() then return false end

    if item.TimerReady() == 0 then
        mq.cmdf('/useitem "%s"', clicky.name)
        mq.delay(50)
        return true
    end

    return false
end

local function doCombatBuffClickies()
    for _, clicky in ipairs(combatBuffClickies) do
        if useCombatBuffClicky(clicky) then return true end
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

local function useEarringMysticAges()
    if (mq.TLO.Me.Buff("Painfully Gorgeous").ID() or 0) ~= 0 then return false end
    local leftEar = mq.TLO.Me.Inventory("Leftear")
    local rightEar = mq.TLO.Me.Inventory("Rightear")
    local name = "Earring of the Mystic Ages Rank 50"
    if (leftEar() and (leftEar.Name() or ""):find(name, 1, true)) or
       (rightEar() and (rightEar.Name() or ""):find(name, 1, true)) then
        mq.cmdf('/casting "%s" item', name)
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

local function useFuriousSentinel()
    if (mq.TLO.Me.Buff("Furious Sentinel Blessing").ID() or 0) ~= 0 then return false end
    mq.cmd('/itemnotify "Furious Sentinel Familiar" rightmouseup')
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

local function useRoguesFury()
    if not inCombat() then return false end
    return useAltAbility("Rogue's Fury")
end

local function useCharmClicky()
    local charm = mq.TLO.Me.Inventory("Charm")
    if not charm() then return false end
    if (mq.TLO.Me.Buff("ultimate rune").ID() or 0) ~= 0 then return false end
    if charm.TimerReady() ~= 0 then return false end
    mq.cmd('/itemnotify charm rightmouseup')
    mq.delay(50)
    return true
end

local function doSelfBuffs()
    useBackBuff()
    useEarringMysticAges()
    useRightwristClicky()
    useFuriousSentinel()
    useDenyDeath()

    -- Thief's Eyes
    if (mq.TLO.Me.Song("Thief's eyes").ID() or 0) == 0 then
        mq.cmd("/disc Thief's eyes")
        mq.delay(50)
    end

    useCharmClicky()
end

local function doAbilities()
    doSelfBuffs()

    useSkill("Backstab")

    local combatClickies = {
        "Nightshade, Blade of Entropy",
        "Fatestealer",
    }
    for _, name in ipairs(combatClickies) do
        useCombatClicky(name)
    end

    useRoguesFury()
    doCombatBuffClickies()
    useChestClicky()

    -- Powersource slot click (Brain of Cazic Thule / The Necronomicon / any)
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

    -- Pendant of Mayong Mistmoore
    useCombatClicky("Pendant of Mayong Mistmoore")
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

    print(string.format("Engaging target ID %d", targetID or 0))
end)

-- Bind /disengage to stop
mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    print("Disengaged")
end)

print("Rogue combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

while true do
    checkZoneChange()

    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    if engaged and targetValid() then
        mq.cmd('/attack on')
        if not mq.TLO.Me.Moving() then
            mq.cmd('/stick 15 uw behind loose hold')
        end
        doAbilities()
    end

    mq.delay(50)
end
