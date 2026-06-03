-- modules/redis_commands.lua
local mq = require('mq')
local socket = require('socket') -- using luasocket
local json = require('dkjson')

local redis_host = "127.0.0.1"
local redis_port = 6379
local redis_channel_prefix = "sentinel/cmd/" -- can be anything you want

local redis_command_queue = {}

local redis = {}

-- Helper: Basic Redis PUBLISH
local function publish(channel, message)
    local client = assert(socket.tcp())
    client:settimeout(0.5)
    local ok, err = client:connect(redis_host, redis_port)
    if not ok then
        print("\ar[Redis Error connecting:]\ay " .. tostring(err))
        return
    end
    client:send(string.format("*3\r\n$7\r\nPUBLISH\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n",
        #channel, channel,
        #message, message))
    client:close()
end

-- API: Send to a specific peer
function redis.sendToPeer(peer, command)
    local payload = {
        target = peer,
        command = command
    }
    local message = json.encode(payload)
    publish(redis_channel_prefix .. peer, message)
end

-- API: Send to partial matching peers (EXCLUDES self)
function redis.sendToPartial(partial, command)
    local peers = mq.TLO.DanNet.Peers() or ""
    local myname = mq.TLO.Me.Name() or ""
    if peers == "" then return end
    for peer in peers:gmatch("([^|]+)") do
        if peer:lower():find(partial:lower(), 1, true) and peer:lower() ~= myname:lower() then
            redis.sendToPeer(peer, command)
        end
    end
end

-- API: Send to all peers (EXCLUDES self)
function redis.sendToAllExceptSelf(command)
    local peers = mq.TLO.DanNet.Peers() or ""
    local myname = mq.TLO.Me.Name() or ""
    if peers == "" then return end
    for peer in peers:gmatch("([^|]+)") do
        if peer:lower() ~= myname:lower() then
            redis.sendToPeer(peer, command)
        end
    end
end

-- API: Send to all peers (INCLUDING self)
function redis.sendToAllIncludingSelf(command)
    local peers = mq.TLO.DanNet.Peers() or ""
    local myname = mq.TLO.Me.Name() or ""
    if peers ~= "" then
        for peer in peers:gmatch("([^|]+)") do
            redis.sendToPeer(peer, command)
        end
    end
    -- Also execute on myself
    redis.receiveCommand(command)
end

-- This would be your command processor that handles incoming Redis messages.
function redis.processQueuedCommands()
    while #redis_command_queue > 0 do
        local cmd = table.remove(redis_command_queue, 1)
        if cmd then
            mq.cmdf("%s", cmd)
        end
    end
end

-- Assume you have a Redis subscriber that pushes received commands into this queue
function redis.receiveCommand(command)
    table.insert(redis_command_queue, command)
end

-- Bind MQ commands
mq.bind("/redist", function(line)
    local args = {}
    for word in line:gmatch("%S+") do table.insert(args, word) end
    if #args < 2 then
        print("\arUsage: /redist <peer> <command>")
        return
    end
    local peer = args[1]
    table.remove(args, 1)
    local command = table.concat(args, " ")
    redis.sendToPeer(peer, command)
end)

mq.bind("/redisa", function(line)
    if not line or line == "" then
        print("\arUsage: /redisa <command>")
        return
    end
    redis.sendToAllExceptSelf(line)
end)

mq.bind("/redisaa", function(line)
    if not line or line == "" then
        print("\arUsage: /redisaa <command>")
        return
    end
    redis.sendToAllIncludingSelf(line)
end)

return redis
