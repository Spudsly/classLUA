--[[
    EZQuests
]]

local mq = require('mq')
local ImGui = require('ImGui')
local actors = require('actors')

-- Detect how this script was actually loaded (preserves case)
local loaded_script_name = 'ezquests'
local source = debug.getinfo(1, 'S').source or ''
if source:find('EZQuests') then
    loaded_script_name = 'EZQuests'
elseif source:find('ezquests') then
    loaded_script_name = 'ezquests'
end

local SCRIPT_NAME = loaded_script_name
local WINDOW_NAME = 'EZQuests'
local DETAIL_WINDOW_NAME = 'EZQuests Peer Status'
local FIRST_WINDOW_WIDTH = 620
local FIRST_WINDOW_HEIGHT = 680
local TIMER_DISPLAY_THRESHOLD_SECONDS = 604800
local FRAME_ROUNDING = 8
local POPUP_ROUNDING = 8
local WINDOW_ROUNDING = 10

local COLOR_COMPLETED = { 0.25, 0.85, 0.40, 1.00 }
local COLOR_ACTIVE = { 0.95, 0.85, 0.35, 1.00 }
local COLOR_MISSING = { 0.95, 0.35, 0.35, 1.00 }
local COLOR_MUTED = { 0.65, 0.65, 0.65, 1.00 }
local COLOR_HEADER = { 0.90, 0.90, 0.50, 1.00 }
local COLOR_PEER = { 0.65, 0.85, 1.00, 1.00 }
local COLOR_SELECTED = { 0.30, 0.90, 0.30, 1.00 }

local window_flags = 0
local tree_flags = bit32.bor(ImGuiTreeNodeFlags.Framed, ImGuiTreeNodeFlags.SpanAvailWidth)
local objective_table_flags = bit32.bor(
    ImGuiTableFlags.RowBg,
    ImGuiTableFlags.BordersInner,
    ImGuiTableFlags.BordersOuter,
    ImGuiTableFlags.Resizable
)

local taskheader = '\ay[\agEZQuests\ay]'
local my_name = mq.TLO.Me.CleanName()
local dannet = mq.TLO.Plugin('mq2dannet').IsLoaded()

-- Use global state to persist across script reloads and prevent double-init
_G.ezquests_state = _G.ezquests_state or {
    actor_handle = nil,
    local_tasks = {},
    peer_tasks = {},
    peer_order = {},
    detail_task_key = nil,
    detail_window_open = false,
    viewing_peer = nil,
    advanced_view = false,
    adv_selected_peer_filter = 'All Peers',
    adv_selected_task_key = nil,
    adv_selected_objective_source = nil,
    adv_all_tasks = {},
}
local state = _G.ezquests_state

_G.ezquests_triggers = _G.ezquests_triggers or {
    do_refresh = false,
    need_task_update = false,
    startup_refresh_at = 0,
}
local triggers = _G.ezquests_triggers

-- Initialize global running state (if nil, set to true; otherwise preserve existing value)
if _G.ezquests_running == nil then
    _G.ezquests_running = true
end
local running = _G.ezquests_running

-- GUI visibility is local per-instance
local drawGUI = false
local debug_mode = false

local args = { ... }
local module_name = 'ezquests'
local exchange_mailbox = module_name .. '_exchange'

local function trim(s)
    return tostring(s or ''):match('^%s*(.-)%s*$')
end

local function extract_character_name(name)
    local cleaned = trim(name)
    if cleaned == '' then return '' end
    cleaned = cleaned:gsub('%b()', '')
    cleaned = trim(cleaned)
    return cleaned:match('^([^%.%s]+)') or cleaned
end

local function log_debug(fmt, ...)
    if debug_mode then
        local timestamp = os.date('%H:%M:%S')
        printf(taskheader .. ' [' .. timestamp .. '] ' .. fmt, ...)
    end
end

local function colored_text(color, text)
    ImGui.TextColored(color[1], color[2], color[3], color[4], text)
end

local function push_soft_theme()
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, FRAME_ROUNDING)
    ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding, POPUP_ROUNDING)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, WINDOW_ROUNDING)
end

local function pop_soft_theme()
    ImGui.PopStyleVar(3)
end

local function build_task_key(title, task_type)
    local normalized_title = (title and title ~= '' and title or '(Untitled Task)'):gsub('^%s+', ''):gsub('%s+$', '')
    local normalized_type = (task_type or ''):gsub('^%s+', ''):gsub('%s+$', '')
    return string.format('%s|%s', normalized_title, normalized_type)
end

local function sort_peer_order()
    state.peer_order = {}
    for name in pairs(state.peer_tasks) do
        table.insert(state.peer_order, name)
    end
    table.sort(state.peer_order, function(a, b)
        return a:lower() < b:lower()
    end)
end

local function summarize_task(task)
    task.total_objectives = #task.objectives
    task.completed_objectives = 0
    task.active_step = ''
    task.is_complete = task.total_objectives > 0

    for _, objective in ipairs(task.objectives) do
        if objective.is_complete then
            task.completed_objectives = task.completed_objectives + 1
        elseif task.active_step == '' then
            task.active_step = objective.instruction
        end
    end

    if task.total_objectives == 0 then
        task.is_complete = false
    else
        task.is_complete = task.completed_objectives == task.total_objectives
    end

    task.key = build_task_key(task.title, task.task_type)
end

local function clone_task(task)
    local copy = {
        slot = task.slot,
        title = task.title,
        task_type = task.task_type,
        timer_display = task.timer_display,
        timer_seconds = task.timer_seconds,
        member_count = task.member_count,
        leader = task.leader,
        objectives = {},
    }

    for index, objective in ipairs(task.objectives or {}) do
        copy.objectives[index] = {
            index = objective.index,
            instruction = objective.instruction,
            status = objective.status,
            is_complete = objective.is_complete,
            optional = objective.optional,
            zone = objective.zone,
        }
    end

    summarize_task(copy)
    return copy
end

local function task_sorter(a, b)
    if a.is_complete ~= b.is_complete then
        return not a.is_complete
    end

    local a_type = (a.task_type or ''):lower()
    local b_type = (b.task_type or ''):lower()
    if a_type ~= b_type then
        return a_type < b_type
    end

    return (a.title or ''):lower() < (b.title or ''):lower()
end

local function normalize_tasks(tasks)
    local normalized = {}
    for _, task in ipairs(tasks or {}) do
        local copy = clone_task(task)
        table.insert(normalized, copy)
    end
    table.sort(normalized, task_sorter)
    return normalized
end

local function get_tasks()
    local tasks = {}
    local taskWnd = mq.TLO.Window('TaskWnd')
    taskWnd.DoOpen()

    local start_time = mq.gettime()
    while not taskWnd.Open() do
        if mq.gettime() - start_time > 5000 then
            printf('%s Failed to open TaskWnd', taskheader)
            return tasks
        end
        mq.delay(100)
    end

    local taskList = mq.TLO.Window('TaskWnd/TASK_TaskList')
    local taskElementList = mq.TLO.Window('TaskWnd/TASK_TaskElementList')

    if not taskList or not taskElementList then
        printf('%s Failed to find task list windows', taskheader)
        taskWnd.DoClose()
        return tasks
    end

    for i = 1, taskList.Items() do
        taskList.Select(i)

        local select_start = mq.gettime()
        while taskList.GetCurSel() ~= i do
            if mq.gettime() - select_start > 1000 then
                break
            end
            mq.delay(50)
        end

        local task_type = taskList.List(i, 1)() or ''
        local task_name = taskList.List(i, 2)()
        local timer_display = taskList.List(i, 3)() or ''

        if task_name and task_name ~= '' then
            local task = {
                slot = i,
                title = task_name,
                task_type = task_type,
                timer_display = timer_display == '?' and '' or timer_display,
                timer_seconds = 0,
                member_count = 0,
                leader = '',
                objectives = {},
            }

            for j = 1, taskElementList.Items() do
                local objective_text = taskElementList.List(j, 1)()
                local status_text = taskElementList.List(j, 2)()
                if objective_text and objective_text ~= '? ? ?' and status_text then
                    table.insert(task.objectives, {
                        index = #task.objectives + 1,
                        instruction = objective_text,
                        status = status_text,
                        is_complete = status_text == 'Done',
                        optional = false,
                        zone = '',
                    })
                end
            end

            summarize_task(task)
            table.insert(tasks, task)
        end
    end

    taskWnd.DoClose()
    table.sort(tasks, task_sorter)
    return tasks
end

local function find_local_task(task_key)
    for _, task in ipairs(state.local_tasks) do
        if task.key == task_key then
            return task
        end
    end
    return nil
end

local function find_peer_task(peer, task_key)
    if not peer or not peer.tasks then
        return nil
    end

    for _, task in ipairs(peer.tasks) do
        if task.key == task_key then
            return task
        end
    end

    return nil
end

local function peer_has_task(peer, task_key)
    return find_peer_task(peer, task_key) ~= nil
end

local function evaluate_peer_task_presence(task)
    local peer_count = #state.peer_order
    if peer_count == 0 then
        return 'unknown', 0, 0
    end

    local peers_with_task = 0
    local has_missing_peer = false

    for _, peer_name in ipairs(state.peer_order) do
        local peer = state.peer_tasks[peer_name]
        if peer_has_task(peer, task.key) then
            peers_with_task = peers_with_task + 1
        else
            has_missing_peer = true
        end
    end

    if has_missing_peer then
        return 'missing', peers_with_task, peer_count
    end

    return 'complete', peers_with_task, peer_count
end

local function refresh_advanced_task_list()
    state.adv_all_tasks = {}
    local seen = {}

    for _, task in ipairs(state.local_tasks) do
        if not seen[task.key] then
            seen[task.key] = true
            table.insert(state.adv_all_tasks, {
                key = task.key,
                title = task.title,
                task_type = task.task_type,
                local_task = task,
            })
        end
    end

    for _, peer_name in ipairs(state.peer_order) do
        local peer = state.peer_tasks[peer_name]
        for _, task in ipairs(peer.tasks or {}) do
            if not seen[task.key] then
                seen[task.key] = true
                table.insert(state.adv_all_tasks, {
                    key = task.key,
                    title = task.title,
                    task_type = task.task_type,
                    local_task = nil,
                })
            end
        end
    end

    table.sort(state.adv_all_tasks, function(a, b)
        return (a.title or ''):lower() < (b.title or ''):lower()
    end)

    local selected_entry = nil
    if state.adv_selected_task_key then
        for _, entry in ipairs(state.adv_all_tasks) do
            if entry.key == state.adv_selected_task_key then
                selected_entry = entry
                break
            end
        end
    end

    if not selected_entry then
        state.adv_selected_task_key = #state.adv_all_tasks > 0 and state.adv_all_tasks[1].key or nil
        state.adv_selected_objective_source = nil
    end

    if state.adv_selected_peer_filter ~= 'All Peers'
        and state.adv_selected_peer_filter ~= 'Self'
        and not state.peer_tasks[state.adv_selected_peer_filter] then
        state.adv_selected_peer_filter = 'All Peers'
    end

    if state.adv_selected_objective_source and state.adv_selected_objective_source ~= 'self' then
        if not selected_entry or not find_peer_task(state.peer_tasks[state.adv_selected_objective_source], selected_entry.key) then
            state.adv_selected_objective_source = nil
        end
    elseif state.adv_selected_objective_source == 'self' and (not selected_entry or not selected_entry.local_task) then
        state.adv_selected_objective_source = nil
    end
end

local function send_message(payload)
    payload = payload or {}
    payload.sender = my_name
    payload.script = SCRIPT_NAME

    if not state.actor_handle then
        log_debug('Cannot send %s; actor mailbox not initialized yet.', tostring(payload.id))
        return false
    end

    log_debug('Sending %s via %s', tostring(payload.id), tostring(exchange_mailbox))
    state.actor_handle:send({ mailbox = exchange_mailbox }, payload)
    return true
end

local function send_message_to_peer(peer_name, payload)
    if not state.actor_handle or not peer_name or peer_name == '' then
        return false
    end

    payload = payload or {}
    payload.sender = my_name
    payload.script = SCRIPT_NAME
    payload.target_peer = peer_name
    
    log_debug('Sending %s to %s via %s', tostring(payload.id), tostring(peer_name), tostring(exchange_mailbox))
    state.actor_handle:send({ character = peer_name, mailbox = exchange_mailbox }, payload)
    return true
end

local function get_connected_peers()
    local peers = {}
    local seen = {}
    local self_name = extract_character_name(mq.TLO.Me.CleanName())

    local function add_peer(raw_name)
        local peer_name = extract_character_name(raw_name)
        if peer_name ~= '' and peer_name ~= self_name and not seen[peer_name:lower()] then
            seen[peer_name:lower()] = true
            table.insert(peers, peer_name)
        end
    end

    if mq.TLO.Plugin('MQ2Mono') and mq.TLO.Plugin('MQ2Mono').IsLoaded() then
        local peers_str = mq.TLO.MQ2Mono.Query('e3,E3Bots.ConnectedClients')()
        if peers_str and type(peers_str) == 'string' and peers_str:lower() ~= 'null' and peers_str ~= '' then
            for peer in string.gmatch(peers_str, '([^,]+)') do
                add_peer(peer)
            end
        end
    elseif mq.TLO.Plugin('MQ2DanNet') and mq.TLO.Plugin('MQ2DanNet').IsLoaded() then
        local peers_str = mq.TLO.DanNet.Peers() or ''
        for peer in string.gmatch(peers_str, '([^|]+)') do
            add_peer(peer)
        end
    elseif mq.TLO.Plugin('MQ2EQBC') and mq.TLO.Plugin('MQ2EQBC').IsLoaded() and mq.TLO.EQBC.Connected() then
        local names = mq.TLO.EQBC.Names() or ''
        for peer in string.gmatch(names, '([^%s]+)') do
            add_peer(peer)
        end
    end

    return peers
end

-- Flag for deferred work from actor callbacks
local needs_capture_and_publish = false

local function capture_and_publish_task_data(target_peer)
    state.local_tasks = normalize_tasks(get_tasks())
    mq.delay(250, function() return not mq.TLO.Window('TaskWnd').Open() end)

    local payload = {
        id = 'TASK_DATA',
        tasks = state.local_tasks,
    }
    if target_peer and target_peer ~= '' then
        send_message_to_peer(target_peer, payload)
    else
        send_message(payload)
    end

    if state.advanced_view then
        refresh_advanced_task_list()
    end
end

local function request_task_data_from_peers()
    -- Don't clear peer data - just request updates to avoid UI flickering
    log_debug('Requesting task data from %d existing peers.', #state.peer_order)
    local peers = get_connected_peers()
    log_debug('Found %d connected peers via DanNet/EQBC.', #peers)
    
    -- Send a single broadcast REQUEST_ALL - all peers will respond
    log_debug('Broadcasting REQUEST_ALL to all peers')
    send_message({
        id = 'REQUEST_ALL',
        requester = my_name,
    })
    
    -- Publish our own data in response
    capture_and_publish_task_data()
end

local function close_script()
    _G.ezquests_running = false
    running = false
end

local function render_objectives_table(task, suffix, all_peer_objectives)
    if #task.objectives == 0 then
        colored_text(COLOR_MUTED, 'No objectives found for this task yet.')
        return
    end

    local flags = objective_table_flags
    local desired_height = 0
    if #task.objectives > 6 then
        flags = bit32.bor(flags, ImGuiTableFlags.ScrollY)
        desired_height = math.min(math.max(#task.objectives * 26, 150), math.max(220, ImGui.GetContentRegionAvailVec().y * 0.6))
    end

    if ImGui.BeginTable('TaskObjectives##' .. suffix, 3, flags, 0, desired_height) then
        ImGui.TableSetupColumn('Objective', ImGuiTableColumnFlags.WidthStretch, 300)
        ImGui.TableSetupColumn('Progress', ImGuiTableColumnFlags.WidthFixed, 110)
        ImGui.TableSetupColumn('Zone', ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableHeadersRow()

        for _, objective in ipairs(task.objectives) do
            ImGui.TableNextRow()

            ImGui.TableNextColumn()
            local label = string.format('%d. %s', objective.index, objective.instruction)
            if objective.optional then
                label = label .. ' (Optional)'
            end
            ImGui.TextWrapped(label)

            ImGui.TableNextColumn()
            local status_color = objective.is_complete and COLOR_COMPLETED or COLOR_ACTIVE
            local status_text = objective.status ~= '' and objective.status or (objective.is_complete and 'Done' or 'In Progress')
            colored_text(status_color, status_text)
            if all_peer_objectives and ImGui.IsItemHovered() then
                local tooltip = ''
                for _, peer_info in ipairs(all_peer_objectives) do
                    if peer_info.objectives[objective.index] then
                        local peer_obj = peer_info.objectives[objective.index]
                        local peer_status = peer_obj.status ~= '' and peer_obj.status or (peer_obj.is_complete and 'Done' or 'In Progress')
                        tooltip = tooltip .. string.format('%s: %s\n', peer_info.name, peer_status)
                    end
                end
                if tooltip ~= '' then
                    ImGui.SetTooltip(tooltip)
                end
            end

            ImGui.TableNextColumn()
            ImGui.Text(objective.zone ~= '' and objective.zone or 'Any')
        end

        ImGui.EndTable()
    end
end

local function render_peer_name_button(peer_name, task_key)
    if ImGui.SmallButton(peer_name .. '##peer_' .. peer_name .. '_' .. (task_key or '')) then
        state.viewing_peer = peer_name
    end
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(string.format("View %s's tasks", peer_name))
    end
end

local function render_task_summary(task)
    local status_color = task.is_complete and COLOR_COMPLETED or COLOR_ACTIVE
    colored_text(status_color, string.format('Status: %s', task.is_complete and 'Complete' or 'In Progress'))

    if task.active_step and task.active_step ~= '' then
        colored_text({ 0.75, 0.90, 1.00, 1.00 }, 'Current Step:')
        ImGui.TextWrapped(task.active_step)
    end

    if task.timer_seconds > 0 and task.timer_seconds < TIMER_DISPLAY_THRESHOLD_SECONDS and task.timer_display ~= '' then
        colored_text({ 0.90, 0.70, 0.35, 1.00 }, 'Time Remaining: ' .. task.timer_display)
    elseif task.timer_display ~= '' then
        colored_text({ 0.90, 0.70, 0.35, 1.00 }, 'Time Remaining: ' .. task.timer_display)
    end

    if (task.member_count or 0) > 1 or (task.leader or '') ~= '' then
        local summary = ''
        if (task.member_count or 0) > 1 then
            summary = string.format('Members: %d', task.member_count)
        end
        if (task.leader or '') ~= '' then
            summary = summary ~= '' and (summary .. ' | Leader: ' .. task.leader) or ('Leader: ' .. task.leader)
        end
        if summary ~= '' then
            ImGui.Text(summary)
        end
    end
end

local function render_task_peer_coverage_indicator(task)
    local presence, peers_with_task, peer_count = evaluate_peer_task_presence(task)
    if presence == 'unknown' then
        return
    end

    if presence == 'complete' then
        colored_text(COLOR_COMPLETED, '[OK]')
    else
        colored_text(COLOR_MISSING, '[X]')
    end

    if ImGui.IsItemHovered() then
        if ImGui.IsMouseClicked(ImGuiMouseButton.Left) then
            state.detail_task_key = task.key
            state.detail_window_open = true
        end

        if presence == 'complete' then
            ImGui.SetTooltip(string.format('All %d peers share this task.\nClick for details.', peer_count))
        else
            ImGui.SetTooltip(string.format('%d of %d peers have this task.\nClick for details.', peers_with_task, peer_count))
        end
    end

    ImGui.SameLine(0, 6)
end

local function render_task(task)
    local header = task.task_type ~= '' and string.format('%s [%s]', task.title, task.task_type) or task.title
    if task.is_complete then
        header = header .. ' (Complete)'
    end

    render_task_peer_coverage_indicator(task)

    local open = ImGui.TreeNodeEx(header .. '##task_' .. tostring(task.slot), tree_flags)
    if open then
        render_task_summary(task)
        ImGui.Separator()
        render_objectives_table(task, task.key)
        ImGui.TreePop()
    end

    ImGui.Separator()
end

local function render_tasks()
    if #state.local_tasks == 0 then
        colored_text({ 0.75, 0.75, 0.75, 1.00 }, 'No active tasks detected. Accept a task to populate this view.')
        return
    end

    for _, task in ipairs(state.local_tasks) do
        render_task(task)
    end
end

local function render_task_header()
    local reporting_count = #state.peer_order + 1

    ImGui.Text('Active tasks: %d', #state.local_tasks)
    ImGui.SameLine()

    if ImGui.Button('Refresh') then
        triggers.do_refresh = true
    end

    ImGui.SameLine()
    if ImGui.Button('Advanced View') then
        state.advanced_view = true
        refresh_advanced_task_list()
    end

    ImGui.SameLine()
    colored_text(COLOR_COMPLETED, '[OK]')
    ImGui.SameLine(0, 4)
    ImGui.Text('= All bots have task')
    ImGui.SameLine(0, 12)
    colored_text(COLOR_MISSING, '[X]')
    ImGui.SameLine(0, 4)
    ImGui.Text('= At least 1 bot missing task')
    ImGui.SameLine(0, 12)
    ImGui.Text('Number of Peers reporting: %d', reporting_count)
end

local function render_peer_objectives_table(task, suffix)
    render_objectives_table(task, 'peer_' .. suffix)
end

local function render_peer_task_detail(task, auto_expand)
    local header = task.task_type ~= '' and string.format('%s [%s]', task.title, task.task_type) or task.title
    if task.is_complete then
        header = header .. ' (Complete)'
    end

    local flags = tree_flags
    if auto_expand then
        flags = bit32.bor(flags, ImGuiTreeNodeFlags.DefaultOpen)
    end

    local open = ImGui.TreeNodeEx(header .. '##peertask_' .. task.key, flags)
    if open then
        render_task_summary(task)
        if task.total_objectives > 0 then
            ImGui.Text('Progress: %d/%d', task.completed_objectives, task.total_objectives)
        end
        if #task.objectives > 0 then
            ImGui.Separator()
            render_peer_objectives_table(task, task.key)
        end
        ImGui.TreePop()
    end

    ImGui.Separator()
end

local function render_peer_task_view()
    local peer = state.peer_tasks[state.viewing_peer]
    if not peer then
        state.viewing_peer = nil
        return
    end

    if ImGui.Button('<< Back') then
        state.viewing_peer = nil
        return
    end

    ImGui.SameLine()
    colored_text(COLOR_PEER, string.format("%s's Tasks", peer.name))
    ImGui.SameLine()
    colored_text(COLOR_MUTED, string.format('(%d tasks)', #(peer.tasks or {})))
    ImGui.SameLine()
    if ImGui.Button('Refresh##PeerView') then
        triggers.do_refresh = true
    end

    ImGui.Separator()

    if not peer.tasks or #peer.tasks == 0 then
        colored_text({ 0.75, 0.75, 0.75, 1.00 }, 'No tasks reported by this peer.')
        return
    end

    for _, task in ipairs(peer.tasks) do
        local auto_expand = state.detail_task_key and state.detail_task_key == task.key
        render_peer_task_detail(task, auto_expand)
    end
end

local function render_detail_window()
    if not state.detail_window_open or not state.detail_task_key then
        return
    end

    push_soft_theme()
    local open, show = ImGui.Begin(DETAIL_WINDOW_NAME .. '##' .. my_name, true)
    state.detail_window_open = open
    if not open then
        state.detail_task_key = nil
    end

    if show and state.detail_task_key then
        local task = find_local_task(state.detail_task_key)
        if not task then
            ImGui.Text('Task no longer available.')
        else
            local header = task.task_type ~= '' and string.format('%s [%s]', task.title, task.task_type) or task.title
            colored_text(COLOR_HEADER, header)
            ImGui.Separator()

            local obj_open = ImGui.TreeNodeEx('Objectives##detail', ImGuiTreeNodeFlags.DefaultOpen)
            if obj_open then
                if #task.objectives == 0 then
                    colored_text(COLOR_MUTED, 'No objectives available.')
                else
                    for _, obj in ipairs(task.objectives) do
                        local obj_color = obj.is_complete and COLOR_COMPLETED or COLOR_ACTIVE
                        colored_text(obj_color, obj.is_complete and '[OK]' or '[X]')
                        ImGui.SameLine(0, 6)
                        local label = obj.instruction
                        if obj.optional then
                            label = label .. ' (Optional)'
                        end
                        ImGui.Text(label)
                        if obj.status ~= '' and not obj.is_complete then
                            ImGui.SameLine(0, 8)
                            colored_text({ 0.7, 0.7, 0.7, 1.0 }, '[' .. obj.status .. ']')
                        end
                    end
                end
                ImGui.TreePop()
            end

            ImGui.Separator()

            local peer_open = ImGui.TreeNodeEx(string.format('Peer Status (%d peers)##detail', #state.peer_order), ImGuiTreeNodeFlags.DefaultOpen)
            if peer_open then
                if #state.peer_order == 0 then
                    colored_text(COLOR_MUTED, 'No peers reporting.')
                else
                    for _, peer_name in ipairs(state.peer_order) do
                        local peer_task = find_peer_task(state.peer_tasks[peer_name], task.key)
                        if peer_task then
                            colored_text(COLOR_COMPLETED, '[OK]')
                            ImGui.SameLine(0, 6)
                            render_peer_name_button(peer_name, task.key)
                            ImGui.SameLine(0, 8)
                            local progress = string.format('(%d/%d)', peer_task.completed_objectives, peer_task.total_objectives)
                            colored_text(peer_task.is_complete and COLOR_COMPLETED or COLOR_ACTIVE, peer_task.is_complete and '(Complete)' or progress)
                        else
                            colored_text(COLOR_MISSING, '[X]')
                            ImGui.SameLine(0, 6)
                            render_peer_name_button(peer_name, task.key)
                            ImGui.SameLine(0, 8)
                            colored_text(COLOR_MUTED, '(Missing task)')
                        end
                    end
                end
                ImGui.TreePop()
            end
        end
    end

    ImGui.End()
    pop_soft_theme()
end

local function render_advanced_peer_summary_table(entry)
    -- Collect all peer task data first for tooltips
    local all_tasks = {}
    if entry.local_task then
        table.insert(all_tasks, { name = my_name, task = entry.local_task })
    end
    for _, peer_name in ipairs(state.peer_order) do
        local peer_task = find_peer_task(state.peer_tasks[peer_name], entry.key)
        if peer_task then
            table.insert(all_tasks, { name = peer_name, task = peer_task })
        end
    end

    if ImGui.BeginTable('PeerSummary##' .. entry.key, 3, bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner, ImGuiTableFlags.BordersOuter)) then
        ImGui.TableSetupColumn('Peer', ImGuiTableColumnFlags.WidthFixed, 150)
        ImGui.TableSetupColumn('Status', ImGuiTableColumnFlags.WidthFixed, 100)
        ImGui.TableSetupColumn('Progress', ImGuiTableColumnFlags.WidthFixed, 100)
        ImGui.TableHeadersRow()

        if entry.local_task then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            local label = string.format('%s##peer_self_%s', my_name, entry.key)
            if ImGui.Selectable(label, state.adv_selected_objective_source == 'self') then
                state.adv_selected_objective_source = 'self'
            end
            ImGui.TableNextColumn()
            ImGui.Text(entry.local_task.is_complete and 'Complete' or 'In Progress')
            ImGui.TableNextColumn()
            local prog_text = string.format('%d/%d', entry.local_task.completed_objectives, entry.local_task.total_objectives)
            ImGui.Selectable(prog_text .. '##prog_self_' .. entry.key, false, ImGuiSelectableFlags.None)
            if ImGui.IsItemHovered() then
                local tooltip = ''
                for _, info in ipairs(all_tasks) do
                    for _, obj in ipairs(info.task.objectives) do
                        local status = obj.is_complete and 'Done' or 'In Progress'
                        tooltip = tooltip .. string.format('%s[%d]: %s - %s\n', info.name, obj.index, status, obj.instruction)
                    end
                end
                ImGui.SetTooltip(tooltip)
            end
        end

        for idx, peer_name in ipairs(state.peer_order) do
            local peer_task = find_peer_task(state.peer_tasks[peer_name], entry.key)
            if peer_task then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                local label = string.format('%s##peer_row_%d_%s', peer_name, idx, entry.key)
                if ImGui.Selectable(label, state.adv_selected_objective_source == peer_name) then
                    state.adv_selected_objective_source = peer_name
                end
                ImGui.TableNextColumn()
                ImGui.Text(peer_task.is_complete and 'Complete' or 'In Progress')
                ImGui.TableNextColumn()
                local prog_text = string.format('%d/%d', peer_task.completed_objectives, peer_task.total_objectives)
                ImGui.Selectable(prog_text .. '##prog_' .. idx .. '_' .. entry.key, false, ImGuiSelectableFlags.None)
                if ImGui.IsItemHovered() then
                    local tooltip = ''
                    for _, info in ipairs(all_tasks) do
                        for _, obj in ipairs(info.task.objectives) do
                            local status = obj.is_complete and 'Done' or 'In Progress'
                            tooltip = tooltip .. string.format('%s[%d]: %s - %s\n', info.name, obj.index, status, obj.instruction)
                        end
                    end
                    ImGui.SetTooltip(tooltip)
                end
            end
        end

        ImGui.EndTable()
    end
end

local function render_advanced_view_right_pane()
    local entry = nil
    for _, task_entry in ipairs(state.adv_all_tasks) do
        if task_entry.key == state.adv_selected_task_key then
            entry = task_entry
            break
        end
    end

    if not entry then
        colored_text(COLOR_MUTED, 'Select a task to view details.')
        return
    end

    colored_text(COLOR_HEADER, entry.title)
    colored_text(COLOR_MUTED, 'Type: ' .. (entry.task_type ~= '' and entry.task_type or 'Unknown'))
    ImGui.Separator()

    ImGui.Text('View objectives from:')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)
    local preview = 'Auto (Self if available)'
    if state.adv_selected_objective_source == 'self' then
        preview = 'Self (' .. my_name .. ')'
    elseif state.adv_selected_objective_source then
        preview = state.adv_selected_objective_source or 'Auto (Self if available)'
    end

    if ImGui.BeginCombo('##ObjectiveSource', preview) then
        if ImGui.Selectable('Auto (Self if available)', state.adv_selected_objective_source == nil) then
            state.adv_selected_objective_source = nil
        end
        if entry.local_task and ImGui.Selectable('Self (' .. my_name .. ')', state.adv_selected_objective_source == 'self') then
            state.adv_selected_objective_source = 'self'
        end
        for _, peer_name in ipairs(state.peer_order) do
            if find_peer_task(state.peer_tasks[peer_name], entry.key) then
                if ImGui.Selectable(peer_name .. '##objective_source_' .. peer_name, state.adv_selected_objective_source == peer_name) then
                    state.adv_selected_objective_source = peer_name
                end
            end
        end
        ImGui.EndCombo()
    end

    ImGui.Separator()

    local task_to_show = nil
    if state.adv_selected_objective_source == nil then
        task_to_show = entry.local_task
        if not task_to_show then
            for _, peer_name in ipairs(state.peer_order) do
                task_to_show = find_peer_task(state.peer_tasks[peer_name], entry.key)
                if task_to_show then
                    break
                end
            end
        end
    elseif state.adv_selected_objective_source == 'self' then
        task_to_show = entry.local_task
    else
        task_to_show = find_peer_task(state.peer_tasks[state.adv_selected_objective_source], entry.key)
    end

    if not task_to_show then
        colored_text(COLOR_MUTED, 'No objective data available from selected source.')
        return
    end

    colored_text(task_to_show.is_complete and COLOR_COMPLETED or COLOR_ACTIVE, string.format('Status: %s', task_to_show.is_complete and 'Complete' or 'In Progress'))
    if task_to_show.active_step ~= '' then
        colored_text({ 0.75, 0.90, 1.00, 1.00 }, 'Current Step:')
        ImGui.TextWrapped(task_to_show.active_step)
    end

    ImGui.Separator()
    if ImGui.CollapsingHeader('Who has this task:', ImGuiTreeNodeFlags.DefaultOpen) then
        render_advanced_peer_summary_table(entry)
    end

    if #task_to_show.objectives > 0 then
        -- Build peer objectives data for tooltips
        local all_peer_objectives = {}
        if entry.local_task then
            table.insert(all_peer_objectives, { name = my_name, objectives = entry.local_task.objectives })
        end
        for _, peer_name in ipairs(state.peer_order) do
            local peer_task = find_peer_task(state.peer_tasks[peer_name], entry.key)
            if peer_task then
                table.insert(all_peer_objectives, { name = peer_name, objectives = peer_task.objectives })
            end
        end

        ImGui.Separator()
        render_objectives_table(task_to_show, 'advanced_' .. entry.key, all_peer_objectives)
    end
end

local function render_advanced_view_task_list()
    colored_text(COLOR_HEADER, 'Tasks')
    ImGui.Separator()

    if #state.adv_all_tasks == 0 then
        colored_text(COLOR_MUTED, 'No tasks found.')
        return
    end

    for _, entry in ipairs(state.adv_all_tasks) do
        local include = true
        if state.adv_selected_peer_filter == 'Self' then
            include = entry.local_task ~= nil
        elseif state.adv_selected_peer_filter ~= 'All Peers' then
            include = find_peer_task(state.peer_tasks[state.adv_selected_peer_filter], entry.key) ~= nil
        end

        if include then
            local peer_count_with_task = entry.local_task and 1 or 0
            for _, peer_name in ipairs(state.peer_order) do
                if find_peer_task(state.peer_tasks[peer_name], entry.key) then
                    peer_count_with_task = peer_count_with_task + 1
                end
            end

            local label = string.format('[%s] (%d) %s', entry.task_type ~= '' and entry.task_type or '???', peer_count_with_task, entry.title)
            if ImGui.Selectable(label .. '##adv_task_' .. entry.key, state.adv_selected_task_key == entry.key) then
                if state.adv_selected_task_key ~= entry.key then
                    state.adv_selected_task_key = entry.key
                    state.adv_selected_objective_source = nil
                end
            end
        end
    end
end

local function render_advanced_view()
    if ImGui.Button('<< Simple View') then
        state.advanced_view = false
        return
    end

    ImGui.SameLine()
    if ImGui.Button('Refresh##Advanced') then
        triggers.do_refresh = true
        refresh_advanced_task_list()
    end

    ImGui.SameLine()
    ImGui.Text('Filter:')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)
    if ImGui.BeginCombo('##PeerFilter', state.adv_selected_peer_filter) then
        if ImGui.Selectable('All Peers', state.adv_selected_peer_filter == 'All Peers') then
            state.adv_selected_peer_filter = 'All Peers'
        end
        if ImGui.Selectable('Self', state.adv_selected_peer_filter == 'Self') then
            state.adv_selected_peer_filter = 'Self'
        end
        if #state.peer_order > 0 then
            ImGui.Separator()
            for _, peer_name in ipairs(state.peer_order) do
                if ImGui.Selectable(peer_name .. '##peer_filter_' .. peer_name, state.adv_selected_peer_filter == peer_name) then
                    state.adv_selected_peer_filter = peer_name
                end
            end
        end
        ImGui.EndCombo()
    end

    ImGui.SameLine()
    colored_text(COLOR_MUTED, '[Type] (# who have it) Task Name')

    ImGui.Separator()

    local avail = ImGui.GetContentRegionAvailVec()
    local left_width = math.max(200, math.min(300, avail.x * 0.30))

    if ImGui.BeginChild('AdvView_TaskList', ImVec2(left_width, avail.y - 10), bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.ResizeX)) then
        render_advanced_view_task_list()
    end
    ImGui.EndChild()

    ImGui.SameLine()

    if ImGui.BeginChild('AdvView_Details', ImVec2(0, avail.y - 10), ImGuiChildFlags.Border) then
        render_advanced_view_right_pane()
    end
    ImGui.EndChild()
end

local function displayGUI()
    if not drawGUI then
        return
    end

    push_soft_theme()
    ImGui.SetNextWindowSize(ImVec2(FIRST_WINDOW_WIDTH, FIRST_WINDOW_HEIGHT), ImGuiCond.FirstUseEver)
    local open, show = ImGui.Begin(WINDOW_NAME .. '##' .. my_name, true, window_flags)
    if not open then
        drawGUI = false
    end

    if show then
        if state.viewing_peer then
            render_peer_task_view()
        elseif state.advanced_view then
            render_advanced_view()
        else
            render_task_header()
            ImGui.Separator()
            render_tasks()
        end
    end

    ImGui.End()
    pop_soft_theme()
    render_detail_window()
end

local function handle_message(message)
    log_debug('handle_message called')
    local content = message.content
    if not content or not content.id then
        log_debug('Message has no content or id')
        return
    end
    log_debug('Received message id=%s script=%s sender=%s', tostring(content.id), tostring(content.script), tostring(content.sender))
    -- Case-insensitive comparison since peers might be running different case
    local incoming_script = (content.script or ''):lower()
    local my_script = SCRIPT_NAME:lower()
    if incoming_script ~= my_script then
        log_debug('Ignoring message for script %s (expected %s)', tostring(content.script), SCRIPT_NAME)
        return
    end

    if content.sender == my_name and content.id == 'TASK_DATA' then
        log_debug('Ignoring local TASK_DATA echo from %s', tostring(content.sender))
        return
    end

    if content.id == 'REQUEST_ALL' then
        -- Queue response for main thread (can't delay in actor callback)
        log_debug('Received REQUEST_ALL from %s, queuing TASK_DATA response', tostring(content.requester or content.sender))
        needs_capture_and_publish = true
    elseif content.id == 'REQUEST_TASKS' then
        if content.requester == my_name then
            log_debug('Ignoring REQUEST_TASKS from self')
            return
        end
        -- Check if this message is targeted at us (or broadcast to all)
        if content.target_peer and content.target_peer ~= my_name then
            log_debug('Ignoring REQUEST_TASKS targeted at %s', tostring(content.target_peer))
            return
        end
        log_debug('Received REQUEST_TASKS from %s, queuing response', tostring(content.requester or content.sender))
        needs_capture_and_publish = true
    elseif content.id == 'TASK_DATA' then
        local sender_name = (message.sender and message.sender.character) or content.sender
        log_debug('Received TASK_DATA from sender_name=%s, my_name=%s, content.sender=%s', 
            tostring(sender_name), tostring(my_name), tostring(content.sender))
        if sender_name and sender_name ~= my_name then
            state.peer_tasks[sender_name] = {
                name = sender_name,
                tasks = normalize_tasks(content.tasks or {}),
                last_update = mq.gettime(),
            }
            sort_peer_order()
            if state.advanced_view then
                refresh_advanced_task_list()
            end
            log_debug('Received %d tasks from %s (total peers: %d)', 
                #(state.peer_tasks[sender_name].tasks or {}), sender_name, #state.peer_order)
        else
            log_debug('Ignoring TASK_DATA from self or invalid sender')
        end
    elseif content.id == 'TASKS_UPDATED' then
        if drawGUI then
            triggers.do_refresh = true
        end
    elseif content.id == 'END_SCRIPT' then
        close_script()
    end
end

local function cmd_ezq(cmd)
    if not cmd or cmd == 'help' then
        printf('%s \ar/ezq exit \ao--- Exit script (also \ar/ezq stop \aoand \ar/ezq quit)', taskheader)
        printf('%s \ar/ezq show \ao--- Show UI', taskheader)
        printf('%s \ar/ezq hide \ao--- Hide UI', taskheader)
        printf('%s \ar/ezq debug \ao--- Toggle debug mode', taskheader)
        printf('%s \ar/ezq refresh \ao--- Request a fresh task snapshot from peers', taskheader)
        return
    end

    if cmd == 'exit' or cmd == 'quit' or cmd == 'stop' then
        _G.ezquests_running = false
        _G.ezquests_initialized = false
        _G.ezquests_imgui_initialized = false
        running = false
    elseif cmd == 'show' then
        printf('%s \aoShowing UI.', taskheader)
        drawGUI = true
        triggers.do_refresh = true
    elseif cmd == 'hide' then
        printf('%s \aoHiding UI.', taskheader)
        drawGUI = false
    elseif cmd == 'debug' then
        debug_mode = not debug_mode
        printf('%s \aoToggling debug mode %s.', taskheader, debug_mode and 'on' or 'off')
    elseif cmd == 'refresh' then
        triggers.do_refresh = true
    end
end

local function update_event()
    send_message({ id = 'TASKS_UPDATED' })
end

local function create_events()
    mq.event('ezquests_update_event', '#*#Your task #*# has been updated#*#', update_event)
    mq.event('ezquests_new_task_event', '#*#You have been assigned the task#*#', update_event)
    mq.event('ezquests_shared_task_event', '#*#Your shared task#*# has ended.#*#', update_event)
end

local is_primary_launch = false

local function check_args()
    -- If already initialized, this is a secondary instance (different case or manual re-run)
    -- We still need to init the actor for THIS instance to receive messages
    if _G.ezquests_initialized then
        log_debug('Script already running in another instance, joining existing session.')
        drawGUI = true
        triggers.do_refresh = true
        -- Don't broadcast to peers - they're already running
        is_primary_launch = false
        return
    end

    is_primary_launch = true
    if #args == 0 then
        log_debug('Primary launch detected; broadcasting /lua run %s nohud to peers.', SCRIPT_NAME)
        mq.cmdf('/dge /lua run %s nohud', SCRIPT_NAME)
        drawGUI = true
        -- Only set startup_refresh_at, not do_refresh (avoid double request)
        triggers.startup_refresh_at = mq.gettime() + 2000
        return
    end

    for _, arg in ipairs(args) do
        if arg == 'nohud' then
            drawGUI = false
            log_debug('Running in nohud mode.')
        elseif arg == 'debug' then
            debug_mode = true
            log_debug('Debug launch detected; broadcasting /lua run %s nohud to peers.', SCRIPT_NAME)
            mq.cmdf('/dge /lua run %s nohud', SCRIPT_NAME)
            drawGUI = true
            -- Only set startup_refresh_at, not do_refresh (avoid double request)
            triggers.startup_refresh_at = mq.gettime() + 2000
        end
    end
end

local function init()
    -- ALWAYS set up event handlers for this script instance
    create_events()
    module_name = module_name:lower()
    exchange_mailbox = module_name .. '_exchange'

    -- ALWAYS register the actor so THIS instance can receive messages
    -- (MacroQuest routes messages per-script-instance, not per-mailbox)
    local ok, mailbox = pcall(function()
        return actors.register(exchange_mailbox, handle_message)
    end)

    if not ok or not mailbox then
        print(string.format('[EZQuests] Failed to register %s: %s', exchange_mailbox, tostring(mailbox)))
        return
    end

    -- Store actor handle locally for this instance
    state.actor_handle = mailbox
    log_debug('Registered actor mailbox %s for this instance', tostring(exchange_mailbox))
    
    -- Only init imgui once (global)
    if not _G.ezquests_imgui_initialized then
        mq.imgui.init('ezquests_gui', displayGUI)
        _G.ezquests_imgui_initialized = true
    end
    
    -- Bind command for this instance
    mq.bind('/ezq', cmd_ezq)
    
    -- First-time initialization only
    if not _G.ezquests_initialized then
        _G.ezquests_initialized = true
        triggers.need_task_update = true
        printf('%s \agstarting. use \ar/ezq help \agfor a list of commands.', taskheader)
    else
        log_debug('Joined existing EZQuests session.')
    end
end

local function main()
    mq.delay(500)
    while running do
        -- Sync with global state (in case another instance changed it)
        running = _G.ezquests_running
        
        mq.doevents()
        mq.delay(100)

        -- Process any deferred work from actor callbacks
        if needs_capture_and_publish then
            needs_capture_and_publish = false
            capture_and_publish_task_data()
        end

        if triggers.do_refresh then
            triggers.do_refresh = false
            request_task_data_from_peers()
        end

        if triggers.startup_refresh_at > 0 and mq.gettime() >= triggers.startup_refresh_at then
            triggers.startup_refresh_at = 0
            request_task_data_from_peers()
        end

        if triggers.need_task_update then
            triggers.need_task_update = false
            capture_and_publish_task_data()
        end
    end

    mq.exit()
end

check_args()
init()
main()
