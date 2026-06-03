local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local epicTimer = 0
local stickEngaged = false

local function getGemByName(name)
    for i = 1, 12 do
        local gem = mq.TLO.Me.Gem(i)
        if gem() and gem.Name() == name then
            return i
        end
    end
    return nil
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

local function doSelfBuffs()
    useBackBuff()
    useRightwristClicky()
    -- Thule's Nightmare Familiar
    if (mq.TLO.Me.Buff("Thule's Nightmare Blessing").ID() or 0) == 0 then
        mq.cmd('/itemnotify "Thule\'s Nightmare Familiar" rightmouseup')
        mq.delay(50)
    end
    useDenyDeath()

    -- Secrets' Secret Ranger Secrets II (find by gem name)
    local secretsGem = getGemByName("Secrets' Secret Ranger Secrets II")
    if secretsGem and mq.TLO.Me.SpellReady(secretsGem)() and (mq.TLO.Me.Buff("Secrets' Secret Ranger Secrets II").ID() or 0) == 0 then
        mq.cmdf('/cast %d', secretsGem)
        mq.delay(50)
    end

    -- Relentless Hunt (find by gem name, can appear in buff or song window)
    local huntGem = getGemByName("Relentless Hunt")
    if huntGem and mq.TLO.Me.SpellReady(huntGem)() and (mq.TLO.Me.Buff("Relentless Hunt").ID() or 0) == 0 and (mq.TLO.Me.Song("Relentless Hunt").ID() or 0) == 0 then
        mq.cmdf('/cast %d', huntGem)
        mq.delay(50)
    end

    -- Howl of the Huntmaster III (find by gem name)
    local howlGem = getGemByName("Howl of the Huntmaster III")
    if howlGem and mq.TLO.Me.SpellReady(howlGem)() and (mq.TLO.Me.Buff("Howl of the Huntmaster III").ID() or 0) == 0 then
        mq.cmdf('/cast %d', howlGem)
        mq.delay(50)
    end
end

local function doAbilities()
    doSelfBuffs()
    useChestClicky()

    -- Sarthin's Secret Power Ranger III (4min recast, in-combat only)
    if inCombat() then
        local gem = getGemByName("Sarthin's Secret Power Ranger III")
        if gem and mq.TLO.Me.SpellReady(gem)() then
            mq.cmdf('/cast %d', gem)
            mq.delay(50)
        end
    end

    -- Sarthin's Secret Power Ranger II
    if inCombat() then
        local gem = getGemByName("Sarthin's Secret Power Ranger II")
        if gem and mq.TLO.Me.SpellReady(gem)() then
            mq.cmdf('/cast %d', gem)
            mq.delay(50)
        end
    end

    -- Ring of the Huntmaster (slot 16)
    if inCombat() then
        local ring = mq.TLO.FindItem("=Ring of the Huntmaster, Rank I")
        if ring() and ring.TimerReady() == 0 then
            mq.cmd('/useitem 16')
            mq.delay(50)
        end
    end

    -- Trickshot Crushing Defeat (ranged slot)
    local trickshotDuration = mq.TLO.Target.MyBuffDuration("Trickshot Crushing Defeat")()
    if not trickshotDuration or trickshotDuration < 300 then
        mq.cmd('/itemnotify ranged rightmouseup')
        mq.delay(50)
    end

    -- Epic weapon (slot 13, ~81s cooldown)
    if os.clock() - epicTimer >= 81 then
        mq.cmd('/itemnotify 13 rightmouseup')
        epicTimer = os.clock()
        mq.delay(50)
    end

    -- Caster nukes (lowest priority)
    if inCombat() then
        local tinderGem = getGemByName("Burning Tinder III")
        if tinderGem and mq.TLO.Me.SpellReady(tinderGem)() then
            mq.cmdf('/cast %d', tinderGem)
            mq.delay(50)
        end
    end
    if inCombat() then
        local burstGem = getGemByName("Burst of Fire")
        if burstGem and mq.TLO.Me.SpellReady(burstGem)() then
            mq.cmdf('/cast %d', burstGem)
            mq.delay(50)
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

print("Ranger combat script loaded. Use /engage ### to start, /engage with no arg for self-buffs, /disengage to stop")

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
