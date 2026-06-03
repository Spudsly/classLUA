-- modules/redis.lua
local socket = require("socket")
local mq = require("mq")

local redis = {}

-- Configuration
local HOST = "127.0.0.1"
local PORT = 6379
local CONNECT_TIMEOUT = 1 -- shorter timeout to prevent freezing
local RECEIVE_TIMEOUT = 0.01 -- very short timeout for non-blocking receives

-- Connection state
local command_conn
local sub_conn
local sub_listeners = {}
local pattern_listeners = {}
local last_connect_attempt = 0
local reconnect_delay = 5 -- seconds between reconnection attempts
local subscription_active = false

-- Debug helper
local function debug(msg, ...)
    print("[Redis] " .. msg:format(...))
end

local function encodeCommand(...)
    local args = {...}
    local out = {"*" .. #args}
    for _, v in ipairs(args) do
        v = tostring(v)
        table.insert(out, "$" .. #v)
        table.insert(out, v)
    end
    return table.concat(out, "\r\n") .. "\r\n"
end

local function parseResponse(conn)
    -- Non-blocking receive with very short timeout
    conn:settimeout(RECEIVE_TIMEOUT)
    
    local line, err = conn:receive("*l")
    if not line then 
        if err ~= "timeout" then
            debug("Receive error: %s", tostring(err))
        end
        return nil, err 
    end
    
    local prefix, payload = line:sub(1,1), line:sub(2)

    if prefix == "+" or prefix == ":" then
        return payload
    elseif prefix == "-" then
        debug("Error response: %s", payload)
        return nil, payload
    elseif prefix == "$" then
        local size = tonumber(payload)
        if size == -1 then return nil end
        
        -- For bulk strings, we need to read exactly 'size' bytes plus the CRLF
        conn:settimeout(RECEIVE_TIMEOUT * 10) -- slightly longer timeout for data
        local data, err = conn:receive(size)
        if not data then
            return nil, "Failed to read bulk string data: " .. tostring(err)
        end
        
        -- Read the trailing CRLF
        local crlf, err = conn:receive(2)
        if not crlf then
            -- This is not critical, we already have the data
            debug("Warning: Failed to read trailing CRLF: %s", tostring(err))
        end
        
        return data
    elseif prefix == "*" then
        local count = tonumber(payload)
        if count == -1 then return nil end
        local values = {}
        for i = 1, count do
            local val, err = parseResponse(conn)
            if not val and err and err ~= "timeout" then
                return nil, err
            elseif not val and err == "timeout" then
                -- If we time out in the middle of an array, we need to consider this a partial read
                return nil, "partial read"
            end
            values[i] = val
        end
        return values
    end
    return nil, "Unknown prefix: " .. prefix
end

local function ensureCommandConn()
    -- Check if enough time has passed since last connection attempt
    local now = os.time()
    if not command_conn and (now - last_connect_attempt) < reconnect_delay then
        return nil
    end
    
    if not command_conn then
        last_connect_attempt = now
        command_conn = socket.tcp()
        command_conn:settimeout(CONNECT_TIMEOUT)
        
        debug("Attempting to connect to %s:%s", HOST, PORT)
        local ok, err = command_conn:connect(HOST, PORT)
        
        if not ok then
            debug("Command connect failed: %s", tostring(err))
            command_conn = nil
            return nil
        end
        
        -- Test connection with PING but don't block too long
        command_conn:settimeout(CONNECT_TIMEOUT)
        command_conn:send(encodeCommand("PING"))
        local resp, err = parseResponse(command_conn)
        
        if not resp then
            if err ~= "timeout" then
                debug("Connection test failed: %s", tostring(err))
                command_conn:close()
                command_conn = nil
                return nil
            end
            -- If it's just a timeout, we'll assume connection is ok for now
        end
        
        command_conn:settimeout(RECEIVE_TIMEOUT)
        debug("Command connection established")
    end
    
    return command_conn
end

-- Simple non-blocking commands
function redis.get(key)
    local conn = ensureCommandConn()
    if not conn then return nil, "Not connected" end
    
    conn:send(encodeCommand("GET", key))
    return parseResponse(conn)
end

function redis.set(key, value)
    local conn = ensureCommandConn()
    if not conn then return nil, "Not connected" end
    
    conn:send(encodeCommand("SET", key, value))
    return parseResponse(conn)
end

function redis.publish(channel, message)
    local conn = ensureCommandConn()
    if not conn then return nil, "Not connected" end
    
    conn:send(encodeCommand("PUBLISH", channel, message))
    return parseResponse(conn)
end

function redis.subscribe(channel, callback)
    if not callback or type(callback) ~= "function" then
        debug("Cannot subscribe to %s without a valid callback", channel)
        return false
    end
    
    sub_listeners[channel] = callback
    subscription_active = false -- Force resubscription
    
    return true
end

function redis.subscribe_pattern(pattern, callback)
    if not callback or type(callback) ~= "function" then
        debug("Cannot subscribe to pattern %s without a valid callback", pattern)
        return false
    end
    
    pattern_listeners[pattern] = callback
    subscription_active = false -- Force resubscription
    
    return true
end

function redis.run_subscription_loop()
    -- Check if we have any subscriptions
    local has_subscriptions = false
    for _ in pairs(sub_listeners) do has_subscriptions = true; break end
    if not has_subscriptions then
        for _ in pairs(pattern_listeners) do has_subscriptions = true; break end
    end
    
    if not has_subscriptions then
        -- No need to maintain a subscription connection
        if sub_conn then
            debug("No active subscriptions, closing subscription connection")
            sub_conn:close()
            sub_conn = nil
            subscription_active = false
        end
        return
    end
    
    -- Ensure command connection first (to check if Redis is available)
    if not ensureCommandConn() then
        if sub_conn then
            debug("Command connection lost, closing subscription connection")
            sub_conn:close()
            sub_conn = nil
            subscription_active = false
        end
        return
    end

    -- Initialize subscription connection if needed
    if not sub_conn or not subscription_active then
        if (os.time() - last_connect_attempt) < reconnect_delay then
            return
        end
        last_connect_attempt = os.time()

        if sub_conn then
            sub_conn:close()
        end
        
        sub_conn = socket.tcp()
        sub_conn:settimeout(CONNECT_TIMEOUT)
        
        debug("Opening subscription connection")
        local ok, err = sub_conn:connect(HOST, PORT)
        
        if not ok then
            debug("Subscription connection failed: %s", tostring(err))
            sub_conn = nil
            subscription_active = false
            return
        end

        debug("Subscription connection established")
        sub_conn:settimeout(RECEIVE_TIMEOUT) -- Short timeout for non-blocking
        
        -- Start with pattern subscriptions
        for pat, _ in pairs(pattern_listeners) do
            debug("Subscribing to pattern: %s", pat)
            sub_conn:send(encodeCommand("PSUBSCRIBE", pat))
        end
        
        -- Then regular subscriptions
        for chan, _ in pairs(sub_listeners) do
            debug("Subscribing to channel: %s", chan)
            sub_conn:send(encodeCommand("SUBSCRIBE", chan))
        end
        
        -- Mark as active - we don't wait for confirmation as it would block
        subscription_active = true
    end

    -- Try to receive a message but don't block
    local msg, err = parseResponse(sub_conn)
    if msg then
        if type(msg) == "table" then
            if msg[1] == "message" then
                local _, chan, payload = unpack(msg)
                if sub_listeners[chan] then
                    -- Use pcall to avoid crashing on callback errors
                    local success, callbackErr = pcall(sub_listeners[chan], chan, payload)
                    if not success then
                        debug("Callback error for channel %s: %s", chan, tostring(callbackErr))
                    end
                end
            elseif msg[1] == "pmessage" then
                local _, pattern, chan, payload = unpack(msg)
                if pattern_listeners[pattern] then
                    -- Use pcall to avoid crashing on callback errors
                    local success, callbackErr = pcall(pattern_listeners[pattern], chan, payload)
                    if not success then
                        debug("Callback error for pattern %s: %s", pattern, tostring(callbackErr))
                    end
                end
            elseif msg[1] == "subscribe" or msg[1] == "psubscribe" then
                -- Subscription confirmation
                debug("Successfully subscribed to: %s", tostring(msg[2]))
            else
                debug("Unexpected message type: %s", tostring(msg[1]))
            end
        else
            debug("Unexpected message format: %s", tostring(msg))
        end
    elseif err and err ~= "timeout" and err ~= "partial read" then
        debug("Subscription connection error: %s, resetting...", tostring(err))
        if sub_conn then 
            sub_conn:close()
            sub_conn = nil
        end
        subscription_active = false
    end
    
    -- Always return quickly to avoid freezing
    return
end

function redis.cleanup()
    if sub_socket then
        sub_socket:close()
        sub_socket = nil
    end
    if command_socket then
        command_socket:close()
        command_socket = nil
    end
end

function redis.is_connected()
    return command_conn ~= nil
end

function redis.stop()
    if command_conn then
        command_conn:close()
        command_conn = nil
    end
    if sub_conn then
        sub_conn:close()
        sub_conn = nil
    end
    subscription_active = false
end

-- Add debugging helpers
function redis.debug_info()
    local info = {
        command_conn = command_conn ~= nil,
        sub_conn = sub_conn ~= nil,
        subscription_active = subscription_active,
        channels = {},
        patterns = {}
    }
    
    for chan, _ in pairs(sub_listeners) do
        table.insert(info.channels, chan)
    end
    
    for pat, _ in pairs(pattern_listeners) do
        table.insert(info.patterns, pat)
    end
    
    return info
end

-- Add mock mode for testing when Redis isn't available
local mock_mode = false
local mock_data = {}

function redis.enable_mock_mode()
    mock_mode = true
    mock_data = {}
    debug("MOCK MODE ENABLED - No actual Redis connections will be made")
    return true
end

function redis.disable_mock_mode()
    mock_mode = false
    debug("MOCK MODE DISABLED - Will attempt real Redis connections")
    return true
end

function redis.is_mock_mode()
    return mock_mode
end

return redis