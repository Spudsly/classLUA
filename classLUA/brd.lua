local mq = require('mq')

local engaged = false
local targetID = nil
local lastZone = mq.TLO.Zone.ID()
local epicTimer = 0
local stickEngaged = false
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
    stickEngaged = false
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
        if stickEngaged then
            if mq.TLO.Me.Moving() and tonumber(mq.TLO.Target.Distance()) < 25 then
                stickEngaged = false
            else
                mq.cmd('/stick 15 uw behind loose hold')
            end
        end
        if tonumber(mq.TLO.Target.Distance()) <= 25 then
            doAbilities()
        end
    end

    mq.delay(50)
end