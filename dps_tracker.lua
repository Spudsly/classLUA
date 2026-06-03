-- dps_tracker.lua
-- Combined DPS publisher + HUD so every character runs one script.

local mq = require('mq')
local ImGui = require('ImGui')
local actors = require('actors')
-- local redis_publisher = require('redis_publisher')  -- DISABLED: Redis not available

local args = {...}

local config = {
    mailbox = args[1] or 'dps_status',
    stale_timeout_ms = tonumber(args[2]) or 20000,
    publish_interval_ms = tonumber(args[3]) or 1000,
    combat_timeout_ms = tonumber(args[4]) or 5000,
    healing_timeout_ms = tonumber(args[5]) or 15000,
    loop_delay_ms = 50,
}

local PET_CHECK_INTERVAL_MS = 1000

local function new_metric_tracker(kind)
    return {
        kind = kind,
        sequence = 0,
        fight_active = false,
        total = 0,
        hits = 0,
        start_time = 0,
        last_event = 0,
        last_publish = 0,
        last_target = nil,
        last_source = nil,
    }
end

local function get_class_short_name()
    local ok, class_short = pcall(function()
        local short = mq.TLO.Me.Class.ShortName()
        if short and short ~= '' then
            return tostring(short)
        end
    end)
    if ok and class_short then
        return class_short
    end
    return 'UNK'
end

local state = {
    character_name = nil,
    server_name = nil,
    class_short = nil,
    window_open = { value = false },
    show_class_short = false,
    actor_mailbox = nil,
    last_prune = 0,
    peers = {},
    damage = new_metric_tracker('damage'),
    healing = new_metric_tracker('healing'),
    pet_name = nil,
    last_pet_check = 0,
    should_exit = false,
}

--[[ DISABLED: Redis not available
local DPS_REDIS_FIELDS = {
    'character',
    'server',
    'class',
    'status',
    'active',
    'sequence',
    'duration_ms',
    'total_damage',
    'dps',
    'hits',
    'target',
    'source',
    'reason',
    'healing_status',
    'healing_active',
    'healing_sequence',
    'healing_duration_ms',
    'total_healing',
    'hps',
    'healing_hits',
    'healing_target',
    'healing_source',
    'healing_reason',
    'timestamp',
}
--]]

local TABLE_FLAGS = bit32.bor(
    ImGuiTableFlags.Resizable,
    ImGuiTableFlags.Borders,
    ImGuiTableFlags.RowBg,
    ImGuiTableFlags.ScrollY,
    ImGuiTableFlags.SizingStretchProp
)

local function println(fmt, ...)
    if select('#', ...) > 0 then
        print(string.format('[DPSTracker] ' .. fmt, ...))
    else
        print('[DPSTracker] ' .. tostring(fmt))
    end
end

local function wait_for_identity()
    local attempts = 0
    while attempts < 200 do
        local me = mq.TLO.Me
        if me() then
            local clean_name = me.CleanName()
            if clean_name and clean_name ~= '' then
                state.character_name = clean_name
                state.class_short = get_class_short_name()
                break
            end
        end
        mq.delay(50)
        attempts = attempts + 1
    end
    local ok, server = pcall(function()
        local s = mq.TLO.EverQuest.Server()
        return s and tostring(s)
    end)
    if ok and server and server ~= '' then
        state.server_name = server
    end
    if not state.character_name then state.character_name = 'Unknown' end
    if not state.server_name then state.server_name = 'Unknown' end
    if not state.class_short then state.class_short = 'UNK' end
end

local suffix_thresholds = {
    {1e12, 't'},
    {1e9, 'b'},
    {1e6, 'm'},
}

local function format_with_commas(number)
    local formatted = string.format('%d', math.floor(number + 0.5))
    local k = 0
    repeat
        formatted, k = formatted:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
    until k == 0
    return formatted
end

local function trim_decimal_suffix(output)
    return output:gsub('%.0([a-zA-Z])', '%1')
end

local function format_human(number)
    if not number or number <= 0 then return '0' end
    for _, entry in ipairs(suffix_thresholds) do
        local threshold, suffix = entry[1], entry[2]
        if number >= threshold then
            local scaled = number / threshold
            local text = scaled >= 100 and string.format('%.0f%s', scaled, suffix)
                or string.format('%.1f%s', scaled, suffix)
            return trim_decimal_suffix(text)
        end
    end
    if number >= 1000 then
        return format_with_commas(number)
    end
    return string.format('%d', math.floor(number + 0.5))
end

local function format_duration(seconds)
    if not seconds or seconds <= 0 then return '0.0s' end
    if seconds >= 60 then
        local mins = math.floor(seconds / 60)
        local secs = seconds - mins * 60
        return string.format('%dm %02ds', mins, math.floor(secs))
    end
    return string.format('%.1fs', seconds)
end

local function parse_amount(raw)
    if not raw then return nil end
    local clean = raw:gsub(',', '')
    return tonumber(clean)
end

local function reset_tracker(tracker)
    tracker.total = 0
    tracker.hits = 0
    tracker.fight_active = false
    tracker.start_time = 0
    tracker.last_event = 0
    tracker.last_publish = 0
    tracker.last_target = nil
    tracker.last_source = nil
end

local function begin_tracker(tracker, now)
    tracker.sequence = tracker.sequence + 1
    tracker.fight_active = true
    tracker.start_time = now
    tracker.last_event = now
    tracker.last_publish = 0
    tracker.total = 0
    tracker.hits = 0
    tracker.last_target = nil
    tracker.last_source = nil
end

local function tracker_has_data(tracker)
    return tracker.total > 0 and tracker.start_time > 0
end

local function get_tracker_timeout(tracker)
    if tracker.kind == 'healing' then
        return config.healing_timeout_ms or config.combat_timeout_ms
    end
    return config.combat_timeout_ms
end

local function compute_duration_ms(tracker)
    if not tracker_has_data(tracker) then return 0 end
    local last = tracker.last_event > 0 and tracker.last_event or mq.gettime()
    return math.max(last - tracker.start_time, 0)
end

local function update_peer_entry(payload, is_local)
    if not payload or type(payload) ~= 'table' or not payload.character then return end
    local entry = state.peers[payload.character] or {}
    entry.character = payload.character
    entry.server = payload.server or entry.server
    entry.class_short = payload.class_short or entry.class_short
    entry.status = payload.status or entry.status
    entry.active = payload.active
    entry.sequence = payload.sequence or entry.sequence
    entry.total_damage = payload.total_damage or entry.total_damage or 0
    entry.total_display = payload.total_display or format_human(entry.total_damage)
    entry.dps = payload.dps or entry.dps or 0
    entry.dps_display = payload.dps_display or format_human(entry.dps)
    entry.hits = payload.hits or entry.hits or 0
    entry.duration_s = payload.duration_s or (payload.duration_ms and payload.duration_ms / 1000) or entry.duration_s
    entry.target = payload.target or entry.target
    entry.source = payload.source or entry.source
    entry.reason = payload.reason or entry.reason
    entry.healing_status = payload.healing_status or entry.healing_status
    entry.healing_active = payload.healing_active
    entry.healing_sequence = payload.healing_sequence or entry.healing_sequence
    entry.total_healing = payload.total_healing or entry.total_healing or 0
    entry.healing_display = payload.healing_display or format_human(entry.total_healing)
    entry.hps = payload.hps or entry.hps or 0
    entry.hps_display = payload.hps_display or format_human(entry.hps)
    entry.healing_hits = payload.healing_hits or entry.healing_hits or 0
    entry.healing_duration_s = payload.healing_duration_s or (payload.healing_duration_ms and payload.healing_duration_ms / 1000) or entry.healing_duration_s
    entry.healing_target = payload.healing_target or entry.healing_target
    entry.healing_source = payload.healing_source or entry.healing_source
    entry.healing_reason = payload.healing_reason or entry.healing_reason
    entry.timestamp = payload.timestamp or os.time()
    entry.last_update = mq.gettime()
    entry.local_player = is_local or entry.local_player
    state.peers[payload.character] = entry
end

local function build_metric_snapshot(tracker, override)
    local has_data = tracker_has_data(tracker)
    local duration_ms = has_data and compute_duration_ms(tracker) or 0
    local duration_s = has_data and math.max(duration_ms / 1000, 0.01) or 0
    local rate = has_data and (tracker.total / duration_s) or 0
    local status
    if override and override.status then
        status = override.status
    elseif has_data and tracker.fight_active then
        status = 'update'
    elseif has_data then
        status = 'completed'
    else
        status = 'idle'
    end
    return {
        has_data = has_data,
        status = status,
        reason = override and override.reason or nil,
        active = has_data and status == 'update' or false,
        duration_ms = duration_ms,
        duration_s = has_data and duration_s or 0,
        total = has_data and tracker.total or 0,
        rate = rate,
        hits = has_data and tracker.hits or 0,
        target = tracker.last_target,
        source = tracker.last_source,
        sequence = tracker.sequence,
    }
end

local function publish_state(overrides)
    overrides = overrides or {}
    local damage_snapshot = build_metric_snapshot(state.damage, overrides.damage)
    local healing_snapshot = build_metric_snapshot(state.healing, overrides.healing)
    if not damage_snapshot.has_data and not healing_snapshot.has_data then
        if damage_snapshot.status == 'idle' and healing_snapshot.status == 'idle' then
            return
        end
    end

    local payload = {
        character = state.character_name,
        server = state.server_name,
        class_short = state.class_short,
        timestamp = os.time(),
        status = damage_snapshot.status,
        active = damage_snapshot.active,
        sequence = damage_snapshot.sequence,
        duration_ms = damage_snapshot.duration_ms,
        duration_s = damage_snapshot.duration_s,
        total_damage = damage_snapshot.total,
        total_display = format_human(damage_snapshot.total),
        dps = damage_snapshot.rate,
        dps_display = format_human(damage_snapshot.rate),
        hits = damage_snapshot.hits,
        target = damage_snapshot.target,
        source = damage_snapshot.source,
        reason = damage_snapshot.reason,
        healing_status = healing_snapshot.status,
        healing_active = healing_snapshot.active,
        healing_sequence = healing_snapshot.sequence,
        healing_duration_ms = healing_snapshot.duration_ms,
        healing_duration_s = healing_snapshot.duration_s,
        total_healing = healing_snapshot.total,
        healing_display = format_human(healing_snapshot.total),
        hps = healing_snapshot.rate,
        hps_display = format_human(healing_snapshot.rate),
        healing_hits = healing_snapshot.hits,
        healing_target = healing_snapshot.target,
        healing_source = healing_snapshot.source,
        healing_reason = healing_snapshot.reason,
    }

    actors.send({mailbox = config.mailbox}, payload)
    update_peer_entry(payload, true)
    -- DISABLED: Redis publishing - uncomment if you have a Redis server
    --[[
    redis_publisher.publish('dps', DPS_REDIS_FIELDS, {
        character = payload.character,
        server = payload.server,
        class = payload.class_short,
        status = payload.status,
        active = payload.active and 1 or 0,
        sequence = payload.sequence,
        duration_ms = payload.duration_ms,
        total_damage = payload.total_damage,
        dps = payload.dps,
        hits = payload.hits,
        target = payload.target,
        source = payload.source,
        reason = payload.reason,
        healing_status = payload.healing_status,
        healing_active = payload.healing_active and 1 or 0,
        healing_sequence = payload.healing_sequence,
        healing_duration_ms = payload.healing_duration_ms,
        total_healing = payload.total_healing,
        hps = payload.hps,
        healing_hits = payload.healing_hits,
        healing_target = payload.healing_target,
        healing_source = payload.healing_source,
        healing_reason = payload.healing_reason,
        timestamp = payload.timestamp,
    })
    --]]
    local now = mq.gettime()
    state.damage.last_publish = now
    state.healing.last_publish = now
end

local function finalize_tracker(tracker, reason)
    if not tracker.fight_active then return end
    if not tracker_has_data(tracker) then
        reset_tracker(tracker)
        return
    end
    local overrides = {}
    overrides[tracker.kind] = { status = 'completed', reason = reason }
    publish_state(overrides)
    reset_tracker(tracker)
    if tracker.kind == 'damage' and state.healing.fight_active then
        finalize_tracker(state.healing, reason)
    end
end

local function record_tracker(tracker, amount, target, source)
    if not amount or amount <= 0 then return end
    local now = mq.gettime()
    local timeout_ms = get_tracker_timeout(tracker)
    if not tracker.fight_active or tracker.start_time == 0 then
        begin_tracker(tracker, now)
    elseif now - tracker.last_event > timeout_ms then
        finalize_tracker(tracker, 'timeout')
        begin_tracker(tracker, now)
    end

    tracker.total = tracker.total + amount
    tracker.hits = tracker.hits + 1
    tracker.last_event = now
    if target and target ~= '' then tracker.last_target = target end
    if source and source ~= '' then tracker.last_source = source end

    if tracker.last_publish == 0 or (now - tracker.last_publish) >= config.publish_interval_ms then
        publish_state()
    end
end

local function record_damage(amount, target, source)
    record_tracker(state.damage, amount, target, source)
end

local PET_EVENT_MELEE = 'DPSTrk_PetMelee'
local PET_EVENT_NON_MELEE = 'DPSTrk_PetNonMelee'

local function escape_event_token(text)
    if not text or text == '' then return text end
    return text:gsub('%%', '%%%%')
end

local function unregister_pet_events()
    if not mq.unevent then return end
    mq.unevent(PET_EVENT_MELEE)
    mq.unevent(PET_EVENT_NON_MELEE)
end

local function register_pet_damage_events(pet_name)
    unregister_pet_events()
    if not pet_name or pet_name == '' then return end
    local safe_name = escape_event_token(pet_name)
    local melee_pattern = string.format('%s #1# #2# for #3# points of damage.#*#', safe_name)
    mq.event(PET_EVENT_MELEE, melee_pattern, function(_, ability, target, amount)
        local numeric = parse_amount(amount)
        if not numeric then return end
        local source = pet_name
        if ability and ability ~= '' then
            source = string.format('%s %s', pet_name, ability)
        end
        record_damage(numeric, target, source)
    end)

    local non_melee_pattern = string.format('%s hit #1# for #2# points of non-melee damage.#*#', safe_name)
    mq.event(PET_EVENT_NON_MELEE, non_melee_pattern, function(_, target, amount)
        local numeric = parse_amount(amount)
        if not numeric then return end
        record_damage(numeric, target, string.format('%s non-melee', pet_name))
    end)
end

local function query_pet_name()
    local ok, name = pcall(function()
        local pet = mq.TLO.Me.Pet
        if pet() then
            local clean = pet.CleanName()
            if clean and clean ~= '' then
                return tostring(clean)
            end
        end
    end)
    if ok then
        return name
    end
end

local function refresh_pet_tracking(force)
    local now = mq.gettime()
    if not force and now - state.last_pet_check < PET_CHECK_INTERVAL_MS then return end
    state.last_pet_check = now
    local pet_name = query_pet_name()
    if pet_name ~= state.pet_name then
        state.pet_name = pet_name
        register_pet_damage_events(pet_name)
    end
end

local function record_healing(amount, target)
    record_tracker(state.healing, amount, target)
end

local function check_tracker_timeout(tracker)
    if not tracker.fight_active or tracker.last_event <= 0 then return end
    if tracker.kind == 'healing' and state.damage.fight_active then return end
    local timeout_ms = get_tracker_timeout(tracker)
    if mq.gettime() - tracker.last_event >= timeout_ms then
        finalize_tracker(tracker, 'timeout')
    end
end

local function check_timeouts()
    check_tracker_timeout(state.damage)
    check_tracker_timeout(state.healing)
end

local function handle_message(message)
    local payload = message.content or message()
    if not payload or type(payload) ~= 'table' then return end
    if payload.character == state.character_name then return end
    update_peer_entry(payload, false)
end

local function prune_stale()
    local now = mq.gettime()
    if now - state.last_prune < config.stale_timeout_ms then return end
    state.last_prune = now
    for name, entry in pairs(state.peers) do
        if entry.last_update and now - entry.last_update > config.stale_timeout_ms then
            state.peers[name] = nil
        end
    end
end

local function collect_entries()
    local items = {}
    for _, entry in pairs(state.peers) do
        table.insert(items, entry)
    end
    table.sort(items, function(a, b)
        local name_a = (a.character or ''):lower()
        local name_b = (b.character or ''):lower()
        return name_a < name_b
    end)
    return items
end

local function filter_entries_by_metric(entries, metric)
    local filtered = {}
    for _, entry in ipairs(entries) do
        local value = metric == 'healing' and entry.total_healing or entry.total_damage
        if value and value > 0 then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

local function draw_metric_table(entries, metric)
    local filtered = filter_entries_by_metric(entries, metric)
    if #filtered == 0 then
        if metric == 'healing' then
            ImGui.TextColored(0xFF808080, 'No healing data yet. Patch someone up!')
        else
            ImGui.TextColored(0xFF808080, 'No DPS data yet. Start swinging!')
        end
        return
    end

    local table_id = metric == 'healing' and 'HealTable' or 'DPSTable'
    if not ImGui.BeginTable(table_id, 4, TABLE_FLAGS) then return end

    local rate_label = metric == 'healing' and 'HPS' or 'DPS'
    local total_label = metric == 'healing' and 'Total Heal' or 'Total'
    local name_column_label = state.show_class_short and 'Class' or 'Character'
    ImGui.TableSetupColumn(name_column_label, ImGuiTableColumnFlags.None, 1.2)
    ImGui.TableSetupColumn(rate_label, ImGuiTableColumnFlags.None, 0.8)
    ImGui.TableSetupColumn(total_label, ImGuiTableColumnFlags.None, 0.9)
    ImGui.TableSetupColumn('Duration', ImGuiTableColumnFlags.None, 0.6)
    ImGui.TableHeadersRow()

    for _, entry in ipairs(filtered) do
        ImGui.TableNextRow()
        local active = metric == 'healing' and entry.healing_active or entry.active
        if active then
            ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0x2000B000)
        else
            ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0x20101010)
        end
        if entry.character == state.character_name then
            ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg1, 0x208080FF)
        end

        local rate_display = metric == 'healing'
            and (entry.hps_display or format_human(entry.hps or 0))
            or (entry.dps_display or format_human(entry.dps or 0))
        local total_display = metric == 'healing'
            and (entry.healing_display or format_human(entry.total_healing or 0))
            or (entry.total_display or format_human(entry.total_damage or 0))
        local duration = metric == 'healing'
            and format_duration(entry.healing_duration_s)
            or format_duration(entry.duration_s)

        ImGui.TableSetColumnIndex(0)
        local identity_label
        if state.show_class_short then
            identity_label = entry.class_short or entry.character or '?'
        else
            identity_label = entry.character or entry.class_short or '?'
        end
        ImGui.Text(identity_label)

        ImGui.TableSetColumnIndex(1)
        ImGui.Text(rate_display)

        ImGui.TableSetColumnIndex(2)
        ImGui.Text(total_display)

        ImGui.TableSetColumnIndex(3)
        ImGui.Text(duration)
    end

    ImGui.EndTable()
end

local function draw_ui()
    if not state.window_open.value then return end

    ImGui.SetNextWindowSize(520, 360, ImGuiCond.FirstUseEver)
    local open
    local window_flags = bit32.bor(ImGuiWindowFlags.NoCollapse)
    open, state.window_open.value = ImGui.Begin('DPS Tracker##dpscombo', state.window_open.value, window_flags)
    if not open then
        ImGui.End()
        return
    end

    local count = 0
    for _ in pairs(state.peers) do count = count + 1 end
    ImGui.Text(string.format('Mailbox: %s  |  Peers: %d  |  Publish %.1fs  |  Stale %.1fs',
        config.mailbox, count, config.publish_interval_ms / 1000, config.stale_timeout_ms / 1000))
    state.show_class_short = ImGui.Checkbox('Show class short names##dps_class_toggle', state.show_class_short)

    local entries = collect_entries()
    if #entries == 0 then
        ImGui.TextColored(0xFF808080, 'No DPS data yet. Start swinging!')
    else
        if ImGui.BeginTabBar('DPSTrackerTabs') then
            if ImGui.BeginTabItem('Damage') then
                draw_metric_table(entries, 'damage')
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Healing') then
                draw_metric_table(entries, 'healing')
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end
    end

    ImGui.End()
end

local function register_combat_events()
    mq.event('DPSTrk_Melee', 'You #1# #2# for #3# points of damage.#*#', function(_, ability, target, amount)
        record_damage(parse_amount(amount), target, ability)
    end)

    mq.event('DPSTrk_YouNonMelee', 'You #1# #2# for #3# points of non-melee damage.#*#', function(_, ability, target, amount)
        record_damage(parse_amount(amount), target, ability)
    end)

    local non_melee_pattern = string.format('%s hit #1# for #2# points of non-melee damage.#*#', state.character_name)
    mq.event('DPSTrk_NameNonMelee', non_melee_pattern, function(_, target, amount)
        record_damage(parse_amount(amount), target, 'non-melee')
    end)

    mq.event('DPSTrk_Dot', '#1# has taken #2# damage from your #3#.#*#', function(_, target, amount, spell)
        record_damage(parse_amount(amount), target, spell)
    end)

    mq.event('DPSTrk_Heal', 'You have healed #1# for #2# points.#*#', function(_, target, amount)
        record_healing(parse_amount(amount), target)
    end)

    refresh_pet_tracking(true)
end

local function register_commands()
    mq.bind('/dps_show', function()
        state.window_open.value = true
        println('DPS Tracker window shown')
    end)

    mq.bind('/dps_hide', function()
        state.window_open.value = false
        println('DPS Tracker window hidden')
    end)

    mq.bind('/dps_toggle', function()
        state.window_open.value = not state.window_open.value
        println('DPS Tracker window %s', state.window_open.value and 'shown' or 'hidden')
    end)

    mq.bind('/dps_exit', function()
        state.should_exit = true
        println('DPS Tracker shutting down...')
    end)
end

local function init()
    wait_for_identity()
    println('Starting DPS tracker for %s (%s) using mailbox %s', state.character_name, state.server_name, config.mailbox)
    state.actor_mailbox = actors.register(config.mailbox, handle_message)
    if not state.actor_mailbox then
        println('Failed to register mailbox %s', config.mailbox)
        return false
    end
    register_combat_events()
    register_commands()
    mq.imgui.init('DPSTrackerUI', draw_ui)
    return true
end

local function cleanup()
    mq.unbind('/dps_show')
    mq.unbind('/dps_hide')
    mq.unbind('/dps_toggle')
    mq.unbind('/dps_exit')
    unregister_pet_events()
    println('DPS Tracker shutdown complete')
end

local function should_continue()
    if state.should_exit then return false end
    local ok, game_state = pcall(function()
        return mq.TLO.MacroQuest.GameState()
    end)
    if not ok or not game_state then return false end
    return game_state ~= 'SHUTDOWN' and game_state ~= 'CHARSELECT'
end

local function main_loop()
    println('Combined DPS tracker running. Use /dps_exit to shutdown.')
    while should_continue() do
        mq.doevents()
        check_timeouts()
        prune_stale()
        refresh_pet_tracking()
        mq.delay(config.loop_delay_ms)
    end

    cleanup()
end

if ... and ... ~= 'dps_tracker' then
    return {
        init = init,
        draw = draw_ui,
    }
else
    if init() then
        main_loop()
    end
end
