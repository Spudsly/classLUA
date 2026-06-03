-- modules/redis_subscribe.lua
local socket = require('socket')
local json = require('dkjson')
local redis_commands = require('modules.redis_commands') -- so we can call redis.receiveCommand()

local redis_host = "127.0.0.1"
local redis_port = 6379
local redis_channel_prefix = "sentinel/cmd/" -- match whatever you used in commands.lua

local redis_subscriber = {}

local client
local connected = false
local myname = ""

local function connect()
    client = assert(socket.tcp())
    client:settimeout(0.5)
    local ok, err = client:connect(redis_host, redis_port)
    if not ok then
        print("\ar[Redis Subscribe Error connecting:]\ay " .. tostring(err))
        return false
    end
    -- Subscribe to our own channel
    myname = require('mq').TLO.Me.Name() or "unknown"
    local channel = redis_channel_prefix .. myname
    client:send(string.format("*2\r\n$9\r\nSUBSCRIBE\r\n$%d\r\n%s\r\n", #channel, channel))
    connected = true
    print("\ag[Redis Subscribe]\aw Subscribed to channel: \ay" .. channel)
    return true
end

local function parseRedisMessage(data)
    if not data then return nil end
    local parts = {}
    for line in data:gmatch("[^\r\n]+") do
        table.insert(parts, line)
    end
    if parts[1] == "message" then
        return parts[3] -- payload
    end
    return nil
end

function redis_subscriber.process()
    if not connected then
        connect()
        return
    end
    local readable, _, err = socket.select({client}, nil, 0)
    if #readable > 0 then
        local data, err = client:receive('*l')
        if data then
            local message = parseRedisMessage(data)
            if message then
                local decoded, pos, err = json.decode(message, 1, nil)
                if decoded and decoded.command then
                    redis_commands.receiveCommand(decoded.command)
                end
            end
        end
    end
end

return redis_subscriber
