-- notify_10pm_popup.lua
-- Pops "10 PM!" in the middle of the screen for 30 seconds at Norrath 10:00 PM.

local mq = require('mq')

local TARGET_HOUR = 22        -- 10 PM in 24h
local TARGET_MIN  = 0
local POP_SECONDS = 30

local lastNotifiedKey = nil

local function dayKey(gt)
  -- Build a simple key that changes each Norrath day (year-month-day)
  return string.format('%d-%02d-%02d', gt.Year(), gt.Month(), gt.Day())
end

while true do
  local gt = mq.TLO.GameTime
  if gt() then
    local hour = gt.Hour()
    local min  = gt.Minute()
    local key  = dayKey(gt)

    -- Use a small trigger window to avoid missing it if the loop lags:
    -- fires any time during 22:00 (minute 0) but only once per day.
    if hour == TARGET_HOUR and min == TARGET_MIN and key ~= lastNotifiedKey then
      lastNotifiedKey = key

      mq.cmd('/beep')
      -- /popupecho [#color] [#seconds] <message>
      mq.cmd(string.format('/popupecho %d %d %s', 13, POP_SECONDS, '10 PM!'))
      -- also log it
      mq.cmd('/echo [Time Alert] Norrath time is now 10:00 PM!')
    end
  end

  mq.delay(250) -- check 4x/sec
end