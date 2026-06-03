local mq = require("mq")

local secondsUntilNextTick = 6
local flashUntil = 0
local lastFlashTime = 0
local FLASH_DURATION_MS = 750

local INFINITE_DURATION = 4294967295

local selectedSource = "None"
local selectedBuffName = "None"
local selectedBuffDur = 0
local selectedBuffMod = 0

-- Returns shortest buff or song duration % 6 under 6000s
local function getTickCountdown()
    local bestDur = nil
    local bestMod = nil
    local bestName = nil
    local bestType = nil

    -- Check Buffs
    for i = 1, 40 do
        local buff = mq.TLO.Me.Buff(i)
        if not buff or not buff.ID() then break end

        local durMs = buff.Duration() or 0
        if durMs > 0 and durMs < INFINITE_DURATION then
            local dur = durMs / 1000
            if dur < 6000 then
                local mod = dur % 6
                if not bestDur or dur < bestDur then
                    bestDur = dur
                    bestMod = mod
                    bestName = buff.Name() or "Unknown"
                    bestType = "Buff"
                end
            end
        end
    end

    -- Check Songs (up to 20 slots, skip SongCount)
    for i = 1, 20 do
        local song = mq.TLO.Me.Song(i)
        if not song() or not song.ID() then break end
        local durMs = song.Duration() or 0
        if durMs > 0 and durMs < INFINITE_DURATION then
            local dur = durMs / 1000
            if dur < 6000 then
                local mod = dur % 6
                if not bestDur or dur < bestDur then
                    bestDur = dur
                    bestMod = mod
                    bestName = song.Name() or "Unknown"
                    bestType = "Song"
                end
            end
        end
    end

    selectedBuffName = bestName or "None"
    selectedBuffDur = bestDur or 0
    selectedBuffMod = bestMod or 0
    selectedSource = bestType or "None"

    return bestMod
end

-- UI
local function drawTickMetronome()
    local now = mq.gettime()
    local mod = getTickCountdown()

    if mod then
        secondsUntilNextTick = mod
        if mod < 0.1 and now - lastFlashTime > 5000 then
            if mq.TLO.Me.CombatState() == "COMBAT" then
                mq.cmdf('/squelch /beep beep.wav')
            end
            flashUntil = now + FLASH_DURATION_MS
            lastFlashTime = now
        end
    else
        secondsUntilNextTick = 6
    end

    ImGui.Begin("Tick Metronome", true, ImGuiWindowFlags.AlwaysAutoResize)

                
                
    if now < flashUntil then
        ImGui.PushStyleColor(ImGuiCol.WindowBg, 1.0, 0.0, 0.0, 1.0)
        ImGui.PushStyleColor(ImGuiCol.Text, 1.0, 1.0, 1.0, 1.0)
        ImGui.Text("!!! TICK !!!")
        ImGui.PopStyleColor(2)
    else
        local tickText = string.format("Next Tick In: %.1f seconds", secondsUntilNextTick)
        ImGui.Text(tickText)
    end

    ImGui.ProgressBar((6 - secondsUntilNextTick) / 6.0, ImVec2(200, 20), "")
    ImGui.End()
end

mq.imgui.init("tick_metronome", drawTickMetronome)

while true do
    mq.delay(10)
end
