local mq = require('mq')
local actors = require('actors')

local E3BC = {
    _version = '1.0',
    _name = 'E3BC',
    _author = 'MQ-ROF2',
    callbacks = {},
    mailbox_name = 'e3bc_command',
    actor_mailbox = nil,
    running = false,
    last_heartbeat = 0,
    heartbeat_interval = 30000,
}

E3BC.__index = E3BC

local function get_server()
    return mq.TLO.EverQuest.Server() or ''
end

local function get_char_name()
    return mq.TLO.Me.CleanName() or ''
end

local function get_full_name()
    return string.format('%s (%s)', get_char_name(), get_server())
end

local function get_zone_id()
    return mq.TLO.Zone.ID() or 0
end

local SCOPES = {
    ALL = 'all',
    ALL_ZONE = 'all_zone',
    GROUP = 'group',
    GROUP_ZONE = 'group_zone',
    GROUP_ALL = 'group_all',
    GROUP_ALL_ZONE = 'group_all_zone',
    RAID = 'raid',
    RAID_ZONE = 'raid_zone',
    PERSON = 'person',
    CHANNEL = 'channel',
}

local function parse_command_args(args)
    if not args or #args == 0 then
        return nil, nil
    end

    local message = table.concat(args, ' ')
    local is_command = message:find('^/') ~= nil
    return message, is_command
end

function E3BC.handle_message(message)
    local data = message()
    if not data or type(data) ~= 'table' then
        return
    end

    -- Ignore heartbeat messages
    if data.type == 'e3bc_heartbeat' then
        return
    end

    local sender = data.sender or 'Unknown'
    local sender_char = data.sender_char or ''
    local cmd = data.command
    local scope = data.scope
    local target = data.target
    local is_noparse = data.noparse or false
    local filters = data.filters or {}
    local my_name = get_char_name()
    local my_zone = get_zone_id()

    if not cmd then return end

    -- Ignore messages from self
    if sender_char == my_name then
        return
    end

    -- Check if this message is for us based on scope and target
    local should_execute = false

    if scope == SCOPES.PERSON then
        -- Targeted message - check if we're the target
        if target and target:lower() == my_name:lower() then
            should_execute = true
        end
    elseif scope == SCOPES.ALL or scope == SCOPES.GROUP_ALL then
        should_execute = true
    elseif scope == SCOPES.ALL_ZONE or scope == SCOPES.GROUP_ALL_ZONE then
        -- Zone-restricted - would need zone info from sender
        -- For now, execute if we receive it (actors handles routing)
        should_execute = true
    elseif scope == SCOPES.GROUP or scope == SCOPES.GROUP_ZONE then
        -- Group scope - check if sender is in our group
        local in_group = false
        for i = 1, mq.TLO.Group.Members() or 0 do
            local member = mq.TLO.Group.Member(i)
            if member and member.Name() and member.Name():lower() == sender_char:lower() then
                in_group = true
                break
            end
        end
        should_execute = in_group
    elseif scope == SCOPES.RAID or scope == SCOPES.RAID_ZONE then
        -- Raid scope - check if we're in a raid
        should_execute = (mq.TLO.Raid.Members() or 0) > 0
    elseif scope == SCOPES.CHANNEL then
        -- Channel scope - execute if we receive it
        should_execute = true
    end

    -- Execute the command if applicable
    if should_execute and cmd then
        printf('\ap[E3BC] \ay%s\aw => \ag%s', sender_char, cmd)
        mq.cmd(cmd)
    end

    -- Fire callbacks
    local callback_key = string.format('%s:%s', scope, cmd)
    if E3BC.callbacks[callback_key] then
        local success, result = pcall(E3BC.callbacks[callback_key], {
            sender = sender,
            command = cmd,
            scope = scope,
            target = target,
            noparse = is_noparse,
            filters = filters,
            raw = data,
        })
        if not success then
            printf('[E3BC] Callback error for %s: %s', callback_key, tostring(result))
        end
    end

    local generic_callback = E3BC.callbacks['*']
    if generic_callback then
        pcall(generic_callback, {
            sender = sender,
            command = cmd,
            scope = scope,
            target = target,
            noparse = is_noparse,
            filters = filters,
            raw = data,
        })
    end
end

function E3BC.register_callback(command, callback)
    if type(callback) ~= 'function' then return false end
    E3BC.callbacks[command] = callback
    return true
end

function E3BC.unregister_callback(command)
    E3BC.callbacks[command] = nil
    return true
end

function E3BC.send_to_peer(peer_name, cmd, scope, noparse, filters)
    local actor_msg = {
        type = 'e3bc_command',
        sender = get_full_name(),
        sender_char = get_char_name(),
        command = cmd,
        scope = scope,
        target = peer_name,
        noparse = noparse,
        filters = filters,
        timestamp = mq.gettime(),
    }

    local char, server = get_char_name(), get_server()
    actors.send({ server = server, character = char }, actor_msg)
end

function E3BC.broadcast(cmd, scope, noparse, filters)
    scope = scope or SCOPES.ALL

    local actor_msg = {
        type = 'e3bc_command',
        sender = get_full_name(),
        sender_char = get_char_name(),
        command = cmd,
        scope = scope,
        target = nil,
        noparse = noparse,
        filters = filters,
        timestamp = mq.gettime(),
    }

    actors.send({ mailbox = E3BC.mailbox_name }, actor_msg)

    local scope_str = scope:gsub('_', ' '):upper()
    printf('\ap[E3BC] \ay%s\aw: \ag%s', scope_str, cmd)
end

function E3BC.register_commands()
    mq.bind('/e3bc', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.ALL, true, {})
    end)

    mq.bind('/e3bca', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.ALL, true, {})
        mq.cmd(cmd)
    end)

    mq.bind('/e3bcz', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.ALL_ZONE, true, {})
    end)

    mq.bind('/e3bcg', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.GROUP, true, {})
    end)

    mq.bind('/e3bcgz', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.GROUP_ZONE, true, {})
    end)

    mq.bind('/e3bcga', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.GROUP_ALL, true, {})
    end)

    mq.bind('/e3bcgza', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.GROUP_ALL_ZONE, true, {})
    end)

    mq.bind('/e3bcaa', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.ALL, true, {})
        mq.cmd(cmd)
    end)

    mq.bind('/e3bcza', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.ALL_ZONE, true, {})
        mq.cmd(cmd)
    end)

    mq.bind('/e3bcr', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.RAID, true, {})
    end)

    mq.bind('/e3bcrz', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.RAID_ZONE, true, {})
    end)

    mq.bind('/e3bcra', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.RAID, true, {})
        mq.cmd(cmd)
    end)

    mq.bind('/e3bcraz', function(...)
        local args = {...}
        local cmd, _ = parse_command_args(args)
        if not cmd then return end
        E3BC.broadcast(cmd, SCOPES.RAID_ZONE, true, {})
        mq.cmd(cmd)
    end)

    mq.bind('/e3bct', function(...)
        local args = {...}
        if #args < 2 then
            print('[E3BC] Usage: /e3bct <target> <command>')
            return
        end
        local target = args[1]
        local cmd = table.concat(args, ' ', 2)
        E3BC.send_to_peer(target, cmd, SCOPES.PERSON, true, {})
    end)

    mq.bind('/e3bcchannel', function(...)
        local args = {...}
        if #args < 2 then
            print('[E3BC] Usage: /e3bcchannel <channel> <command>')
            return
        end
        local channel = args[1]
        local cmd = table.concat(args, ' ', 2)
        local actor_msg = {
            type = 'e3bc_command',
            sender = get_full_name(),
            sender_char = get_char_name(),
            command = cmd,
            scope = SCOPES.CHANNEL,
            target = channel,
            noparse = true,
            filters = {},
            timestamp = mq.gettime(),
        }
        actors.send({ mailbox = E3BC.mailbox_name }, actor_msg)
        printf('\ap[E3BC] \ayCHANNEL (%s)\aw: \ag%s', channel, cmd)
    end)
end

local function e3bc_keepalive()
    local now = mq.gettime()
    if now - E3BC.last_heartbeat >= E3BC.heartbeat_interval then
        E3BC.last_heartbeat = now
        local actor_msg = {
            type = 'e3bc_heartbeat',
            sender = get_full_name(),
            sender_char = get_char_name(),
            scope = 'heartbeat',
            timestamp = now,
        }
        actors.send({ mailbox = E3BC.mailbox_name }, actor_msg)
    end
end

function E3BC.init()
    if E3BC.actor_mailbox then return E3BC end

    E3BC.running = true
    E3BC.last_heartbeat = mq.gettime()
    E3BC.actor_mailbox = actors.register(E3BC.mailbox_name, E3BC.handle_message)
    E3BC.register_commands()

    mq.event('E3BC_Tick', '#*#', function()
        if not E3BC.running then return end
        e3bc_keepalive()
    end)

    mq.cmdf('/timed 5000 /doevents E3BC_Tick')

    printf('[E3BC] Initialized - Registered %d broadcast commands', 14)

    return E3BC
end

function E3BC.shutdown()
    E3BC.running = false
    E3BC.actor_mailbox = nil
    E3BC.callbacks = {}
    printf('[E3BC] Shutdown complete')
end

function E3BC.main_loop()
    while E3BC.running do
        e3bc_keepalive()
        mq.delay(100)
    end
end

E3BC.SCOPES = SCOPES

-- Auto-initialize and run main loop when executed as a script
E3BC.init()
E3BC.main_loop()
