-- modules/redis_pubsub.lua
local mq = require('mq')
local socket = require("socket")
local dkjson = require("dkjson")

local M = {}
M.subscriptions = {}
M.connected = false
M.host = "127.0.0.1"
M.port = 6379

-- Pub/Sub internals
local buffer = {}
local subscriber = nil

-- Command handling
local command_queue = {}
local channel_prefix = "cmd/"
local myname = mq.TLO.Me.Name() or "unknown"

local function connect()
    local client = socket.tcp()
    client:settimeout(0)
    local success, err = client:connect(M.host, M.port)
    if not success and err ~= "timeout" then
        print("\ar[Redis] Connection failed: " .. err)
        return nil
    end
    return client
end

local function read_line(sock)
    local data, err = sock:receive("*l")
    if not data and err ~= "timeout" then
        return nil, err
    end
    return data
end

function M.publish(channel, message)
    local client = connect()
    if not client then return end
    local cmd = string.format("*3\r\n$7\r\nPUBLISH\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n",
        #channel, channel, #message, message)
    client:send(cmd)
    client:close()
end

function M.subscribe(name, callback)
    if M.subscriptions[name] then return end
    M.subscriptions[name] = callback
end

function M.poll()
    if not subscriber then
        subscriber = connect()
        if not subscriber then return end

        local subs = {}
        for ch in pairs(M.subscriptions) do
            table.insert(subs, string.format("$%d\r\n%s", #ch, ch))
        end

        local sub_cmd = string.format("*%d\r\n$9\r\nSUBSCRIBE\r\n%s\r\n", #subs + 1, table.concat(subs, "\r\n"))
        subscriber:send(sub_cmd)
    end

    while true do
        local line, err = read_line(subscriber)
        if not line then break end
        table.insert(buffer, line)

        if #buffer >= 7 and buffer[1] == "*3" and buffer[3] == "message" then
            local channel = buffer[5]
            local payload = buffer[7]
            local callback = M.subscriptions[channel]
            if callback then callback(payload) end
            buffer = {}
        elseif #buffer > 7 then
            buffer = {}
        elseif line == "*3" and #buffer > 1 then
            buffer = {line}
        end
    end
end

-- ============================================
-- COMMAND SYSTEM (new)
-- ============================================

-- Queue a command for execution
local function queueCommand(cmd)
    table.insert(command_queue, cmd)
end

-- Process queued commands
function M.processQueuedCommands()
    while #command_queue > 0 do
        local cmd = table.remove(command_queue, 1)
        if cmd then
            mq.cmdf("%s", cmd)
        end
    end
end

-- Handle incoming Redis command messages
local function handleIncoming(payload)
    local decoded, pos, err = dkjson.decode(payload, 1, nil)
    if decoded and decoded.command then
        queueCommand(decoded.command)
    end
end

-- Send command to a single peer
function M.sendToPeer(peer, command)
    local payload = { target = peer, command = command }
    local message = dkjson.encode(payload)
    M.publish(channel_prefix .. peer, message)
end

-- Send command to partial match peers
function M.sendToPartial(partial, command)
    local peers = mq.TLO.DanNet.Peers() or ""
    if peers == "" then return end
    for peer in peers:gmatch("([^|]+)") do
        if peer:lower():find(partial:lower(), 1, true) and peer:lower() ~= myname:lower() then
            M.sendToPeer(peer, command)
        end
    end
end

-- Send command to all peers EXCEPT self
function M.sendToAllExceptSelf(command)
    local peers = mq.TLO.DanNet.Peers() or ""
    if peers == "" then return end
    for peer in peers:gmatch("([^|]+)") do
        if peer:lower() ~= myname:lower() then
            M.sendToPeer(peer, command)
        end
    end
end

-- Send command to all peers INCLUDING self
function M.sendToAllIncludingSelf(command)
    local peers = mq.TLO.DanNet.Peers() or ""
    if peers ~= "" then
        for peer in peers:gmatch("([^|]+)") do
            M.sendToPeer(peer, command)
        end
    end
    queueCommand(command) -- locally queue for self
end

-- ============================================
-- BIND MQ COMMANDS
-- ============================================

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
    M.sendToPeer(peer, command)
end)

mq.bind("/redisa", function(line)
    if not line or line == "" then
        print("\arUsage: /redisa <command>")
        return
    end
    M.sendToAllExceptSelf(line)
end)

mq.bind("/redisaa", function(line)
    if not line or line == "" then
        print("\arUsage: /redisaa <command>")
        return
    end
    M.sendToAllIncludingSelf(line)
end)

-- ============================================
-- INITIALIZE
-- ============================================

-- Subscribe to our own channel
M.subscribe(channel_prefix .. myname, handleIncoming)

return M
