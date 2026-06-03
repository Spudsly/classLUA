local mq = require('mq')

local engaged = false
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

local function getGemByName(name)
    for i = 1, 12 do
        local gem = mq.TLO.Me.Gem(i)
        if gem() and gem.Name() == name then
            return i
        end
    end
    return nil
end

local function doSelfBuffs()
    useBackBuff()
    useRightwristClicky()

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

    -- Strength of Direwind (pet buff, pet level > 78)
    local pet = mq.TLO.Me.Pet
    if pet() and (pet.Level() or 0) > 78 and mq.TLO.Me.SpellReady("Strength of Direwind")() then
        local petBuff = mq.TLO.Pet.Buff("Strength of Direwind")
        if not petBuff() then
            mq.cmd('/casting 33358')
            mq.delay(50)
        end
    end

    -- Thule's Nightmare Familiar
    if (mq.TLO.Me.Buff("Thule's Nightmare Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Thule\'s Nightmare Familiar" rightmouseup')
        mq.delay(50)
    end

    useDenyDeath()

    -- Painfully Gorgeous (right ear)
    if (mq.TLO.Me.Buff("Painfully Gorgeous").ID() or 0) == 0 then
        local rightEar = mq.TLO.Me.Inventory("Rightear")
        if rightEar() and (rightEar.Name() or ""):find("Earring of the Mystic Ages", 1, true) then
            mq.cmd('/itemnotify rightear rightmouseup')
            mq.delay(50)
        end
    end
end

local function doAbilities()
    doSelfBuffs()

    -- Ring of the Mindbender (must be equipped)
    if inCombat() then
        local ring = mq.TLO.FindItem("=Ring of the Mindbender, Rank II")
        if ring() and ring.TimerReady() == 0 then
            local slot = tonumber(ring.InvSlot())
            if slot and slot >= 0 and slot <= 22 then
                mq.cmd('/itemnotify "Ring of the Mindbender, Rank II" rightmouseup')
                mq.delay(50)
            end
        end
    end

    -- Combat rotation: wand first, then spells (slot-based)
    if not mq.TLO.Me.Casting() then
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
            local spellPriority = { "Arcane Rupture", "Draconic Mindlash", "Insanity VIII" }
            for _, spellName in ipairs(spellPriority) do
                local gem = getGemByName(spellName)
                if gem and mq.TLO.Me.SpellReady(gem)() then
                    mq.cmdf('/cast %d', gem)
                    mq.delay(350)
                    break
                end
            end
        end
    end

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

    useChestClicky()
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

    print(string.format("Engaging target ID %d", targetID or 0))
end)

mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    print("Disengaged")
end)

print("Enchanter combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

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
