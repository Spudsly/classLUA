local mq = require('mq')

local itemName = "Wand of Terris Thule"

local spells = {
    "Rangewind's Glacial Lance",
    "Freezing Direwind Shards",
    "Natedog's Meteor of Annihilation",
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

-- Find spell gem by name
local function getGemByName(name)
    for i = 1, 12 do
        local gem = mq.TLO.Me.Gem(i)
        if gem() and gem.Name() == name then
            return i
        end
    end
    return nil
end

-- Check if target is valid and alive
local function targetValid()
    if not targetID then return false end
    local spawn = mq.TLO.Spawn(targetID)
    if not spawn() then return false end
    return spawn.Type() == "NPC" and spawn.CurrentHPs() > 0
end

-- Bind the /engage command
mq.bind('/engage', function(id)
    id = tonumber(id)
    if not id then
        print("Usage: /engage ### (where ### is target ID)")
        return
    end

    targetID = id
    engaged = true

    mq.cmdf('/tar id %d', targetID)
    mq.delay(50)
    mq.cmd('/stick 15 behind')
    mq.delay(50)
    mq.cmd('/attack on')

    print(string.format("Engaging target ID %d", targetID))
end)

-- Bind /disengage to stop
mq.bind('/disengage', function()
    engaged = false
    targetID = nil
    print("Disengaged")
end)

print("Wizard nuke script loaded. Use /engage ### to start, /disengage to stop")

while true do
    checkZoneChange()

    -- Check if we should disengage (target dead or gone)
    if engaged and not targetValid() then
        print("Target dead or invalid, disengaging")
        engaged = false
        targetID = nil
    end

    -- Only cast when engaged and valid target
    if engaged and targetValid() and not mq.TLO.Me.Casting() then

        -- 1. Try item first
        local item = mq.TLO.FindItem(itemName)
        if item() and item.TimerReady() == 0 then
            mq.cmdf('/useitem "%s"', itemName)
            mq.delay(350)
        else
            -- 2. Try spells in order
            for _, spellName in ipairs(spells) do
                local gem = getGemByName(spellName)
                if gem and mq.TLO.Me.SpellReady(gem)() then
                    mq.cmdf('/cast %d', gem)
                    mq.delay(350)
                    break
                end
            end
        end
    end

    mq.delay(100)
end
