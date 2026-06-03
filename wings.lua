-- wings.lua
-- Tracks the "Wings of the Angel" item timer and broadcasts readiness via Actors mailbox
-- Publishes to 'wings_status' mailbox for other characters to receive readiness updates

local mq = require('mq')
local actors = require('actors')
local ImGui = require('ImGui')

-- Configuration
local WINGS_ITEM_NAME = "Wings of the Arch Angel"
local MAILBOX_NAME = 'wings_status'
local COMMAND_MAILBOX_NAME = 'wings_command'
local PUBLISH_INTERVAL_S = 0.5  -- How often to publish status (in seconds)
local STALE_DATA_TIMEOUT_S = 10  -- How long before peer data is considered stale (in seconds)

-- State Variables
local function get_server_name()
    local server = mq.TLO.EverQuest.Server()
    return (server and tostring(server)) or "Unknown"
end

local state = {
    character_name = mq.TLO.Me.CleanName() or "Unknown",
    server_name = get_server_name(),
    wings_ready = false,
    timer_remaining = 0,
    last_update = 0,
    actor_mailbox = nil,
    command_mailbox = nil,
    peers = {},  -- Track status from other characters: [char/server] = {data, timestamp}
    window_open = { value = true },
    first_ready_character = nil,  -- Name of first character with wings ready
    should_exit = false,
}

-------------------------------------------
--- Utility Functions
-------------------------------------------

local function println(fmt, ...)
    if select('#', ...) > 0 then
        print(string.format("[Wings] " .. fmt, ...))
    else
        print("[Wings] " .. tostring(fmt))
    end
end

-------------------------------------------
--- Wings Status Functions
-------------------------------------------

-- Check if Wings of the Angel is ready to use
local function check_wings_status()
    local wings_item = mq.TLO.FindItem(WINGS_ITEM_NAME)
    
    if not wings_item then
        state.wings_ready = false
        state.timer_remaining = 0
        return
    end
    
    -- Get the timer ready value (0 = ready, > 0 = milliseconds remaining)
    local timer_ready = wings_item.TimerReady()
    
    state.timer_remaining = timer_ready or 0
    state.wings_ready = (timer_ready == 0)
end

-- Publish current wings status to mailbox
local function publish_status()
    local current_time = os.time()
    
    -- Rate limit publishing (only publish if more than PUBLISH_INTERVAL_S has passed)
    if state.last_update > 0 and (current_time - state.last_update) < PUBLISH_INTERVAL_S then
        return
    end
    
    check_wings_status()
    
    -- Get server dynamically (don't use cached value)
    local server = mq.TLO.EverQuest.Server()
    local server_name = server and tostring(server) or ""
    
    local status = {
        character = state.character_name,
        server = server_name,
        wings_ready = state.wings_ready,
        timer_remaining = state.timer_remaining,
        timestamp = current_time,
    }
    
    -- Send via actors.send() for broader compatibility
    actors.send({ mailbox = MAILBOX_NAME }, status)
    
    state.last_update = current_time
end

-------------------------------------------
--- Mailbox Message Handler
-------------------------------------------

-- Find the first character with wings ready (including self)
local function find_first_ready_character()
    local current_time = os.time()
    local first_ready = nil

    -- Check if our own wings are ready first
    if state.wings_ready then
        first_ready = state.character_name
    end

    -- Then check peers
    if not first_ready then
        for key, peer_data in pairs(state.peers) do
            -- Check if data is stale
            if current_time - peer_data.timestamp <= STALE_DATA_TIMEOUT_S then
                if peer_data.wings_ready then
                    first_ready = peer_data.character
                    break  -- Return first available
                end
            end
        end
    end

    state.first_ready_character = first_ready
end

-- Count total characters with wings ready (including self)
local function count_available_wings()
    local current_time = os.time()
    local count = 0

    -- Count our own wings if ready
    if state.wings_ready then
        count = count + 1
    end

    -- Count peers with ready wings
    for key, peer_data in pairs(state.peers) do
        -- Check if data is stale
        if current_time - peer_data.timestamp <= STALE_DATA_TIMEOUT_S then
            if peer_data.wings_ready then
                count = count + 1
            end
        end
    end

    return count
end

-- Handler for incoming wings status messages from other characters
-- Handler for incoming wings status messages from other characters
local function handle_wings_message(message)
    -- Try both patterns
    local content = message.content or message()
    
    if not content or type(content) ~= 'table' then
        return
    end
    
    if not content.character then
        return
    end
    
    -- Server can be missing, use character name as fallback
    local peer_server = content.server or content.character
    
    -- Don't process our own messages
    if content.character == state.character_name then
        return
    end
    
    local peer_key = string.format("%s/%s", content.character, peer_server)
    state.peers[peer_key] = {
        character = content.character,
        server = peer_server,
        wings_ready = content.wings_ready,
        timer_remaining = content.timer_remaining,
        timestamp = content.timestamp or os.time(),
    }
    
    find_first_ready_character()
end

-------------------------------------------
--- Command Functions
-------------------------------------------

-- Handler for incoming command messages
local function handle_command_message(message)
    local content = message.content or message()
    
    if not content or type(content) ~= 'table' then
        return
    end
    
    -- Check if command is for this character
    if content.target and content.target ~= state.character_name then
        return
    end
    
    -- Execute the command
    if content.command == 'useitem' and content.item then
        println('Received command to use item: %s', content.item)
        mq.cmdf('/useitem "%s"', content.item)
    end
end

-- Send useitem command to a specific character via mailbox
local function send_use_item_command(target_character)
    if not target_character then
        println('No target character specified')
        return
    end
    
    println('Sending useitem command to %s', target_character)
    
    -- Send command via actors mailbox
    actors.send(
        { mailbox = COMMAND_MAILBOX_NAME },
        {
            command = 'useitem',
            item = WINGS_ITEM_NAME,
            target = target_character,
        }
    )
end

-------------------------------------------
--- UI Functions
-------------------------------------------

local function draw_ui()
    if not state.window_open.value then return end
    
    -- Skip rendering if not in valid game state (prevents crashes when minimized)
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    ImGui.SetNextWindowSize(300, 250, ImGuiCond.FirstUseEver)

    if ImGui.Begin("Wings Tracker##wingsUI", state.window_open.value) then
        local available_count = count_available_wings()

        ImGui.Text("Wings of the Angel Status")
        ImGui.SameLine()
        ImGui.TextColored(0xFF00FFFF, string.format("(%d)", available_count))  -- Cyan
        ImGui.Separator()
        ImGui.Text("First Ready Character:")
        ImGui.SameLine()
        if state.first_ready_character then
            ImGui.TextColored(0xFF00FF00, state.first_ready_character)  -- Green

            -- Button to use item on first available character
            if ImGui.Button("Use Wings##useWingsBtn", ImVec2(100, 20)) then
                send_use_item_command(state.first_ready_character)
            end
        else
            ImGui.TextColored(0xFFFF8800, "None available")  -- Orange
            ImGui.BeginDisabled(true)
            ImGui.Button("No one ready##disabledBtn", ImVec2(100, 20))
            ImGui.EndDisabled()
        end

        ImGui.End()
    end
end

-------------------------------------------
--- Main Update Loop
-------------------------------------------

local function update_loop()
    check_wings_status()
    publish_status()
    find_first_ready_character()
end

local function cleanup()
    println('Wings Tracker shutdown complete')
end

local function main_loop()
    while not state.should_exit do
        update_loop()
        mq.delay(50)  -- Check every 50ms
    end

    cleanup()
end

-------------------------------------------
--- Initialization
-------------------------------------------

local function init()
    println('Initializing Wings tracker...')
    
    state.character_name = mq.TLO.Me.CleanName() or "Unknown"
    state.server_name = get_server_name()
    
    -- Register the mailbox to receive status messages from other characters
    state.actor_mailbox = actors.register(MAILBOX_NAME, handle_wings_message)
    
    if not state.actor_mailbox then
        println('Failed to register actor mailbox "%s"', MAILBOX_NAME)
        return false
    end
    
    -- Register the command mailbox to receive commands from other characters
    state.command_mailbox = actors.register(COMMAND_MAILBOX_NAME, handle_command_message)
    
    if not state.command_mailbox then
        println('Failed to register command mailbox "%s"', COMMAND_MAILBOX_NAME)
        return false
    end
    
    println('Actor mailboxes registered successfully')
    println('Character: %s / Server: %s', state.character_name, state.server_name)
    println('Tracking: %s', WINGS_ITEM_NAME)
    
    return true
end

-------------------------------------------
--- Module Exports
-------------------------------------------

-- If this is being required as a module
if ... and ... ~= "wings" then
    return {
        init = init,
        get_status = function()
            check_wings_status()
            return {
                character = state.character_name,
                wings_ready = state.wings_ready,
                timer_remaining = state.timer_remaining,
            }
        end,
        get_first_ready = function()
            return state.first_ready_character
        end,
        publish = publish_status,
        show_ui = function()
            state.window_open.value = true
        end,
        hide_ui = function()
            state.window_open.value = false
        end,
        exit = function()
            state.should_exit = true
        end,
    }
else
    -- If running directly as a script
    if not init() then
        println('Initialization failed')
        return
    end

    -- Add exit command
    mq.bind('/wings_exit', function()
        state.should_exit = true
        println('Wings Tracker shutting down...')
    end)

    println('Wings tracker started. Use /wings_exit to shutdown.')

    -- Register the ImGui render callback
    mq.imgui.init('WingsTracker', draw_ui)

    -- Main loop for status updates
    main_loop()

    -- Cleanup command binding
    mq.unbind('/wings_exit')
end
