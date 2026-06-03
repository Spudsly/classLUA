local mq = require('mq')
local sqlite3 = require('lsqlite3')
local ImGui = require('ImGui')

-- Script info
local script_name = 'Tradeskill Automation'
local version = '1.0.0'

-- State variables
local show_window = true
local db = nil
local recipes = {}
local selected_recipe = nil
local combine_status = ''
local is_combining = false
local container_name = ''
local selected_container = nil
local batch_count = 1
local batch_current = 0
local combine_queue = nil -- Recipe ID to combine
local start_batch = false -- Flag to start batch combine

-- UI settings
local window_flags = 0

-- Recipe form variables
local new_recipe = {
    name = '',
    skill = 'Baking',
    trivial = 0,
    container = '',
    yield = 1,
    notes = '',
    ingredients = {}
}
local new_ingredient_name = ''
local new_ingredient_qty = 1
local edit_mode = false
local edit_recipe_id = nil
local tradeskills = {
    'Baking', 'Brewing', 'Fletching', 'Jewelry Making',
    'Poison Making', 'Pottery', 'Research', 'Smithing',
    'Tailoring', 'Tinkering', 'Other'
}

-- Settings
local settings = {
    auto_inventory = true,
    clear_on_fail = true,
    pause_on_skill_up = false,
    combine_delay = 2000,
    pickup_delay = 250,     -- delay after picking an item to cursor (ms)
    place_delay = 250,      -- delay after placing an item into container (ms)
    between_items_delay = 150, -- delay between handling consecutive items (ms)
    container_open_settle_delay = 300 -- delay after opening container before interacting (ms)
}

-- Database functions
local function init_database()
    local db_path = mq.configDir .. '/tradeskill_recipes.db'
    print('Initializing database at: ' .. db_path)
    db = sqlite3.open(db_path)

    if not db then
        print('Failed to open database!')
        return false
    end

    -- Create recipes table
    local create_table = [[
        CREATE TABLE IF NOT EXISTS recipes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            skill TEXT NOT NULL,
            trivial INTEGER,
            container TEXT NOT NULL,
            yield INTEGER DEFAULT 1,
            notes TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    ]]
    db:exec(create_table)

    -- Create ingredients table
    local create_ingredients = [[
        CREATE TABLE IF NOT EXISTS ingredients (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recipe_id INTEGER NOT NULL,
            item_name TEXT NOT NULL,
            quantity INTEGER NOT NULL,
            FOREIGN KEY(recipe_id) REFERENCES recipes(id) ON DELETE CASCADE
        );
    ]]
    db:exec(create_ingredients)

    -- Create combines history table
    local create_history = [[
        CREATE TABLE IF NOT EXISTS combine_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            recipe_id INTEGER NOT NULL,
            success BOOLEAN NOT NULL,
            skill_gain BOOLEAN DEFAULT 0,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(recipe_id) REFERENCES recipes(id)
        );
    ]]
    db:exec(create_history)

    print('Database initialized successfully')
    return true
end

-- Load recipes from database
local function load_recipes()
    recipes = {}

    if not db then
        print('Database not initialized')
        return
    end

    local stmt = db:prepare("SELECT * FROM recipes ORDER BY skill, name")

    if stmt then
        local count = 0
        for row in stmt:nrows() do
            table.insert(recipes, row)
            count = count + 1
        end
        stmt:finalize()
        print('Loaded ' .. count .. ' recipes from database')
    else
        print('Failed to prepare recipe query')
    end
end

-- Get ingredients for a recipe
local function get_ingredients(recipe_id)
    local ingredients = {}
    local stmt = db:prepare("SELECT * FROM ingredients WHERE recipe_id = ?")

    if stmt then
        stmt:bind_values(recipe_id)
        for row in stmt:nrows() do
            table.insert(ingredients, row)
        end
        stmt:finalize()
    end

    return ingredients
end

-- Load recipe for editing
local function load_recipe_for_edit(recipe_id)
    -- Find the recipe
    local recipe = nil
    for _, r in ipairs(recipes) do
        if r.id == recipe_id then
            recipe = r
            break
        end
    end

    if not recipe then
        return false
    end

    -- Set edit mode
    edit_mode = true
    edit_recipe_id = recipe_id

    -- Load recipe data
    new_recipe.name = recipe.name
    new_recipe.skill = recipe.skill
    new_recipe.trivial = recipe.trivial
    new_recipe.container = recipe.container
    new_recipe.yield = recipe.yield
    new_recipe.notes = recipe.notes or ''

    -- Load ingredients
    local ingredients = get_ingredients(recipe_id)
    new_recipe.ingredients = {}
    for _, ing in ipairs(ingredients) do
        table.insert(new_recipe.ingredients, {
            name = ing.item_name,
            qty = ing.quantity
        })
    end

    return true
end

-- Helper function to extract base name for grouping
local function get_base_name(name)
    -- Remove common suffixes for grouping
    local base = name

    -- Remove RK patterns
    base = base:gsub("%s*RK%s+[IVX]+%s*", " ")

    -- Remove LV patterns
    base = base:gsub("%s*LV%s*%d+%s*", " ")

    -- Remove Level patterns
    base = base:gsub("%s*Level%s+%d+%s*", " ")

    -- Remove version patterns
    base = base:gsub("%s*v%d+%s*", " ")

    -- Remove Mk patterns
    base = base:gsub("%s*Mk%s+[IVX]+%s*", " ")

    -- Remove standalone Roman numerals at the end (I, II, III, IV, V, etc.)
    base = base:gsub("%s+[IVX]+%s*$", "")

    -- Remove standalone Arabic numerals at the end (1, 2, 3, etc.)
    base = base:gsub("%s+%d+%s*$", "")

    -- Remove parenthetical numbers/versions at the end like (1), (2), (V2), etc.
    base = base:gsub("%s*%([IVX%d]+%)%s*$", "")

    -- Remove bracketed numbers/versions at the end like [1], [2], [V2], etc.
    base = base:gsub("%s*%[[IVX%d]+%]%s*$", "")

    -- Clean up extra spaces
    base = base:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    return base
end

-- Helper function to extract sort key for ordering within groups
local function get_sort_key(name)
    -- Roman numeral conversion table
    local roman_to_num = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10, XI = 11, XII = 12, XIII = 13, XIV = 14, XV = 15, XVI = 16, XVII = 17, XVIII = 18, XIX = 19, XX = 20 }

    -- Extract numeric values for sorting
    local rk_match = name:match("RK%s+([IVX]+)")
    if rk_match then
        return roman_to_num[rk_match] or 0
    end

    local lv_match = name:match("LV%s*(%d+)")
    if lv_match then
        return tonumber(lv_match) or 0
    end

    local level_match = name:match("Level%s+(%d+)")
    if level_match then
        return tonumber(level_match) or 0
    end

    local v_match = name:match("v(%d+)")
    if v_match then
        return tonumber(v_match) or 0
    end

    local mk_match = name:match("Mk%s+([IVX]+)")
    if mk_match then
        return roman_to_num[mk_match] or 0
    end

    -- Check for standalone Roman numerals at the end
    local standalone_roman = name:match("%s+([IVX]+)%s*$")
    if standalone_roman then
        return roman_to_num[standalone_roman] or 0
    end

    -- Check for standalone Arabic numerals at the end
    local standalone_num = name:match("%s+(%d+)%s*$")
    if standalone_num then
        return tonumber(standalone_num) or 0
    end

    -- Check for parenthetical numbers/versions at the end like (1), (2), (V2), etc.
    local paren_roman = name:match("%s*%(([IVX]+)%)%s*$")
    if paren_roman then
        return roman_to_num[paren_roman] or 0
    end

    local paren_num = name:match("%s*%((%d+)%)%s*$")
    if paren_num then
        return tonumber(paren_num) or 0
    end

    -- Check for bracketed numbers/versions at the end like [1], [2], [V2], etc.
    local bracket_roman = name:match("%s*%[([IVX]+)%]%s*$")
    if bracket_roman then
        return roman_to_num[bracket_roman] or 0
    end

    local bracket_num = name:match("%s*%[(%d+)%]%s*$")
    if bracket_num then
        return tonumber(bracket_num) or 0
    end

    return 0
end

-- Group recipes by base name
local function group_recipes()
    local groups = {}
    local group_order = {}

    for _, recipe in ipairs(recipes) do
        local base_name = get_base_name(recipe.name)
        local sort_key = get_sort_key(recipe.name)

        if not groups[base_name] then
            groups[base_name] = {}
            table.insert(group_order, base_name)
        end

        table.insert(groups[base_name], {
            recipe = recipe,
            sort_key = sort_key
        })
    end

    -- Sort recipes within each group
    for _, group in pairs(groups) do
        table.sort(group, function(a, b)
            if a.sort_key == b.sort_key then
                return a.recipe.name < b.recipe.name
            end
            return a.sort_key < b.sort_key
        end)
    end

    -- Sort groups by name
    table.sort(group_order)

    return groups, group_order
end

-- State for group expansion
local expanded_groups = {}

-- Helper function to increment rank/level in item names
local function increment_item_name(name)
    -- Handle RK (Rank) patterns: RK I, RK II, RK III, etc.
    local rk_match = name:match("(.+)RK%s+([IVX]+)(.*)$")
    if rk_match then
        local prefix, roman, suffix = rk_match, name:match("RK%s+([IVX]+)"), name:match("RK%s+[IVX]+(.*)$")
        local roman_to_num = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10, XI = 11, XII = 12 }
        local num_to_roman = {
            [1] = "I",
            [2] = "II",
            [3] = "III",
            [4] = "IV",
            [5] = "V",
            [6] = "VI",
            [7] = "VII",
            [8] =
            "VIII",
            [9] = "IX",
            [10] = "X",
            [11] = "XI",
            [12] = "XII"
        }

        local current_num = roman_to_num[roman]
        if current_num and current_num < 12 then
            return prefix .. "RK " .. num_to_roman[current_num + 1] .. suffix
        end
    end

    -- Handle LV (Level) patterns: LV20, LV 20, etc.
    local lv_match = name:match("(.+)LV%s*(%d+)(.*)$")
    if lv_match then
        local prefix, level_str, suffix = lv_match, name:match("LV%s*(%d+)"), name:match("LV%s*%d+(.*)$")
        local level_num = tonumber(level_str)
        if level_num then
            return prefix .. "LV" .. (level_num + 1) .. suffix
        end
    end

    -- Handle Level patterns: Level 20, etc.
    local level_match = name:match("(.+)Level%s+(%d+)(.*)$")
    if level_match then
        local prefix, level_str, suffix = level_match, name:match("Level%s+(%d+)"), name:match("Level%s+%d+(.*)$")
        local level_num = tonumber(level_str)
        if level_num then
            return prefix .. "Level " .. (level_num + 1) .. suffix
        end
    end

    -- Handle Mk patterns: Mk I, Mk II, etc.
    local mk_match = name:match("(.+)Mk%s+([IVX]+)(.*)$")
    if mk_match then
        local prefix, roman, suffix = mk_match, name:match("Mk%s+([IVX]+)"), name:match("Mk%s+[IVX]+(.*)$")
        local roman_to_num = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10, XI = 11, XII = 12 }
        local num_to_roman = {
            [1] = "I",
            [2] = "II",
            [3] = "III",
            [4] = "IV",
            [5] = "V",
            [6] = "VI",
            [7] = "VII",
            [8] =
            "VIII",
            [9] = "IX",
            [10] = "X",
            [11] = "XI",
            [12] = "XII"
        }

        local current_num = roman_to_num[roman]
        if current_num and current_num < 12 then
            return prefix .. "Mk " .. num_to_roman[current_num + 1] .. suffix
        end
    end

    -- If no pattern matches, return original name
    return name
end

-- Copy recipe for creating a new one
local function copy_recipe(recipe_id)
    -- Find the recipe
    local recipe = nil
    for _, r in ipairs(recipes) do
        if r.id == recipe_id then
            recipe = r
            break
        end
    end

    if not recipe then
        return false
    end

    -- Clear edit mode (we're creating a new recipe)
    edit_mode = false
    edit_recipe_id = nil

    -- Smart increment recipe name
    local new_name = increment_item_name(recipe.name)
    if new_name == recipe.name then
        -- If no increment pattern found, use "Copy of" prefix
        new_name = "Copy of " .. recipe.name
    end

    -- Load recipe data
    new_recipe.name = new_name
    new_recipe.skill = recipe.skill
    new_recipe.trivial = recipe.trivial
    new_recipe.container = recipe.container
    new_recipe.yield = recipe.yield
    new_recipe.notes = recipe.notes or ''

    -- Load ingredients with smart increment
    local ingredients = get_ingredients(recipe_id)
    new_recipe.ingredients = {}
    for _, ing in ipairs(ingredients) do
        local incremented_name = increment_item_name(ing.item_name)
        table.insert(new_recipe.ingredients, {
            name = incremented_name,
            qty = ing.quantity
        })
    end

    return true
end

-- Add new recipe
local function add_recipe(name, skill, trivial, container, yield, notes)
    local stmt = db:prepare([[
        INSERT INTO recipes (name, skill, trivial, container, yield, notes)
        VALUES (?, ?, ?, ?, ?, ?)
    ]])

    if stmt then
        stmt:bind_values(name, skill, trivial, container, yield, notes)
        stmt:step()
        local recipe_id = db:last_insert_rowid()
        stmt:finalize()
        return recipe_id
    end

    return nil
end

-- Add ingredient to recipe
local function add_ingredient(recipe_id, item_name, quantity)
    local stmt = db:prepare([[
        INSERT INTO ingredients (recipe_id, item_name, quantity)
        VALUES (?, ?, ?)
    ]])

    if stmt then
        stmt:bind_values(recipe_id, item_name, quantity)
        stmt:step()
        stmt:finalize()
        return true
    end

    return false
end

-- Update recipe
local function update_recipe(recipe_id, name, skill, trivial, container, yield, notes)
    local stmt = db:prepare([[
        UPDATE recipes
        SET name = ?, skill = ?, trivial = ?, container = ?, yield = ?, notes = ?
        WHERE id = ?
    ]])

    if stmt then
        stmt:bind_values(name, skill, trivial, container, yield, notes, recipe_id)
        stmt:step()
        stmt:finalize()
        return true
    end

    return false
end

-- Delete ingredients for a recipe
local function delete_recipe_ingredients(recipe_id)
    local stmt = db:prepare("DELETE FROM ingredients WHERE recipe_id = ?")

    if stmt then
        stmt:bind_values(recipe_id)
        stmt:step()
        stmt:finalize()
        return true
    end

    return false
end

-- Delete recipe
local function delete_recipe(recipe_id)
    local stmt = db:prepare("DELETE FROM recipes WHERE id = ?")

    if stmt then
        stmt:bind_values(recipe_id)
        stmt:step()
        stmt:finalize()
        load_recipes() -- Reload recipes
        return true
    end

    return false
end

-- Record combine result
local function record_combine(recipe_id, success, skill_gain)
    local stmt = db:prepare([[
        INSERT INTO combine_history (recipe_id, success, skill_gain)
        VALUES (?, ?, ?)
    ]])

    if stmt then
        stmt:bind_values(recipe_id, success and 1 or 0, skill_gain and 1 or 0)
        stmt:step()
        stmt:finalize()
    end
end

-- Get combine statistics
local function get_combine_stats(recipe_id)
    local stats = {
        total = 0,
        success = 0,
        failures = 0,
        skill_gains = 0
    }

    local stmt = db:prepare([[
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as success,
            SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) as failures,
            SUM(CASE WHEN skill_gain = 1 THEN 1 ELSE 0 END) as skill_gains
        FROM combine_history
        WHERE recipe_id = ?
    ]])

    if stmt then
        stmt:bind_values(recipe_id)
        for row in stmt:nrows() do
            stats.total = row.total or 0
            stats.success = row.success or 0
            stats.failures = row.failures or 0
            stats.skill_gains = row.skill_gains or 0
        end
        stmt:finalize()
    end

    return stats
end

-- Check if we have all ingredients
local function check_ingredients(recipe_id)
    local ingredients = get_ingredients(recipe_id)
    local missing = {}

    for _, ingredient in ipairs(ingredients) do
        local count = mq.TLO.FindItemCount(ingredient.item_name)()
        if count < ingredient.quantity then
            table.insert(missing, {
                name = ingredient.item_name,
                need = ingredient.quantity,
                have = count
            })
        end
    end

    return missing
end

-- Track our specific container window
local our_container_slot = nil
local our_container_name = nil

local function tradeskill_container_window_open()
    local pack_window = mq.TLO.Window('pack10')
    if pack_window() and pack_window.Open then
        return pack_window.Open() or false
    end

    local container_window = mq.TLO.Window('ContainerWindow')
    if container_window() and container_window.Open then
        return container_window.Open() or false
    end

    return false
end

-- Open container
local function open_container(container)

    -- Check bag slot 10 (inventory slot 32) for the container
    local bag_slot_10 = mq.TLO.Me.Inventory(32)
    if not bag_slot_10() or not bag_slot_10.ID() then
        print('No item in bag slot 10')
        return false
    end

    -- Verify it's the correct container
    if bag_slot_10.Name() ~= container and not string.find(bag_slot_10.Name(), container) then
        print(string.format('Wrong container in bag slot 10. Expected: %s, Found: %s', container, bag_slot_10.Name()))
        return false
    end

    -- Verify it's actually a container
    if not bag_slot_10.Container() or bag_slot_10.Container() == 0 then
        print(string.format('Item in bag slot 10 (%s) is not a container', bag_slot_10.Name()))
        return false
    end

    print(string.format('Opening container "%s" from bag slot 10', bag_slot_10.Name()))

    -- Store our container info for verification
    our_container_slot = 32 -- bag slot 10 = inventory slot 32
    our_container_name = bag_slot_10.Name()

    local opened = tradeskill_container_window_open()

    -- Only open the container once per combine round. Use inventory slot 32 directly
    -- so the tradeskill container is actually opened before we clear/place items.
    if not opened then
        mq.cmd('/itemnotify 32 rightmouseup')
        opened = mq.delay(3000, function()
            return tradeskill_container_window_open()
        end)

        if not opened then
            opened = tradeskill_container_window_open()
        end
    end

    -- Allow UI to settle before any /itemnotify in packXX (placing/clearing)
    if opened then
        mq.delay(settings.container_open_settle_delay)
    end

    return opened
end

-- Clear container
local function clear_container()
    -- Check if container window is open
    if not tradeskill_container_window_open() then
        return false
    end

    -- Pick up items from each slot
    for i = 1, 10 do
        -- Check if there's an item in this container slot
        local item = mq.TLO.InvSlot('trade' .. i).Item
        if item() and item.ID() then
            -- Pick up the item from container (pack10 slot_number)
            mq.cmdf('/ctrl /itemnotify in pack10 %d leftmouseup', i)
            mq.delay(200)

            -- Auto-inventory it
            if mq.TLO.Cursor() then
                mq.cmd('/autoinv')
                mq.delay(200)
            end
        end
    end

    return true
end

-- Add items to container
local function add_items_to_container(recipe_id)
    local ingredients = get_ingredients(recipe_id)
    local container_slot = 1

    for _, ingredient in ipairs(ingredients) do
        for i = 1, ingredient.quantity do
            if container_slot > 10 then
                return false, "Too many items for container"
            end

            -- Find the item
            local item = mq.TLO.FindItem(ingredient.item_name)
            if not item.ID() then
                return false, "Could not find " .. ingredient.item_name
            end

            -- Pick up the item using its name.
            -- Only use shift to split if the item is stacked; otherwise use a normal pickup.
            local invItem = mq.TLO.FindItem(ingredient.item_name)
            local stackCount = invItem() and invItem.Stack() or 1
            if stackCount and stackCount > 1 then
                mq.cmd('/nomodkey /ctrl /itemnotify "' .. ingredient.item_name .. '" leftmouseup')
            else
                mq.cmd('/ctrl /itemnotify "' .. ingredient.item_name .. '" leftmouseup')
            end

            -- Wait for item to be on cursor
            mq.delay(1500, function()
                return (mq.TLO.Cursor() and mq.TLO.Cursor.ID()) and true or false
            end)

            -- Small stabilization delay after item pickup
            mq.delay(settings.pickup_delay)

            if not mq.TLO.Cursor() or not mq.TLO.Cursor.ID() then
                return false, "Failed to pick up " .. ingredient.item_name
            end

            -- Place in container slot (pack10 slot_number)
            mq.cmdf('/itemnotify in pack10 %d leftmouseup', container_slot)

            -- Wait for item to be placed (cursor should be empty)
            mq.delay(1000, function()
                return (not mq.TLO.Cursor() or not mq.TLO.Cursor.ID()) and true or false
            end)

            -- Stabilization delay after placing
            mq.delay(settings.place_delay)

            if mq.TLO.Cursor() and mq.TLO.Cursor.ID() then
                return false, "Failed to place " .. ingredient.item_name .. " in container"
            end

            -- Delay between items to prevent rapid-fire moves
            mq.delay(settings.between_items_delay)

            container_slot = container_slot + 1
        end
    end

    return true, "Items added"
end

-- Event handlers
local last_combine_result = nil
local last_skill_up = false

mq.event('combine_success', 'You have fashioned the items together to create #*#: #*#', function(line, item)
    last_combine_result = true
end)

mq.event('combine_success2', 'You have fashioned the items together to create something new: #*#', function(line, item)
    last_combine_result = true
end)

mq.event('combine_fail', 'You lacked the skills to fashion the items together.', function()
    last_combine_result = false
end)

mq.event('combine_fail2', 'You have failed to combine these items.', function()
    last_combine_result = false
end)

mq.event('skill_up', 'You have become better at #*#! (#*#)', function(line, skill, level)
    last_skill_up = true
end)

-- Perform combine
local function do_combine()
    if not tradeskill_container_window_open() then
        return false, false
    end

    -- Double-check we're working with the right container
    if our_container_name and our_container_slot then
        local current_container = mq.TLO.Me.Inventory(our_container_slot)
        if not current_container() or current_container.Name() ~= our_container_name then
            print('Warning: Container mismatch detected during combine!')
            return false, false
        end
    end

    last_combine_result = nil
    last_skill_up = false

    -- Explicitly use /combine pack 10 to trigger the combine in our working container
    mq.cmd('/combine pack 10')
    mq.delay(settings.combine_delay, function() return last_combine_result ~= nil end)

    -- Check events
    mq.doevents('combine_success')
    mq.doevents('combine_success2')
    mq.doevents('combine_fail')
    mq.doevents('combine_fail2')
    mq.doevents('skill_up')

    return last_combine_result == true, last_skill_up
end

local function stop_batch(status)
    is_combining = false
    start_batch = false
    combine_queue = nil
    if status then
        combine_status = status
    end
end

-- Main combine function
local function combine_recipe(recipe_id)
    if is_combining then
        return false
    end

    is_combining = true
    combine_status = "Starting combine..."

    -- Get recipe details
    local recipe = nil
    for _, r in ipairs(recipes) do
        if r.id == recipe_id then
            recipe = r
            break
        end
    end

    if not recipe then
        combine_status = "Recipe not found"
        is_combining = false
        return false
    end

    -- Check ingredients
    local missing = check_ingredients(recipe_id)
    if #missing > 0 then
        combine_status = "Missing ingredients:"
        for _, m in ipairs(missing) do
            combine_status = combine_status .. string.format("\n%s: need %d, have %d",
                m.name, m.need, m.have)
        end
        is_combining = false
        return false
    end

    -- Open container
    combine_status = "Opening container: " .. recipe.container
    local container_opened = open_container(recipe.container)
    if not container_opened then
        combine_status = "Failed to open container: " .. recipe.container
        is_combining = false
        return false
    end
    combine_status = "Container opened successfully"

    -- Clear container
    combine_status = "Clearing container..."
    clear_container()

    -- Add items
    combine_status = "Adding items..."
    local success, msg = add_items_to_container(recipe_id)
    if not success then
        combine_status = "Failed to add items: " .. msg
        is_combining = false
        return false
    end

    -- Do combine
    combine_status = "Combining..."
    local combine_success, skill_gain = do_combine()

    -- Record result
    record_combine(recipe_id, combine_success, skill_gain)

    local paused_for_skill_up = settings.pause_on_skill_up and skill_gain

    if combine_success then
        combine_status = "Combine successful!"
        if skill_gain then
            combine_status = combine_status .. " (Skill up!)"
        end

        -- Auto inventory if enabled
        if settings.auto_inventory then
            mq.cmd('/autoinv')
        end
    else
        combine_status = "Combine failed!"

        -- Clear container if enabled
        if settings.clear_on_fail then
            clear_container()
        end
    end

    is_combining = false
    if paused_for_skill_up then
        combine_status = "Skill up! Pausing..."
    end

    return true, paused_for_skill_up
end

-- Draw add recipe form
local function draw_add_recipe_form()
    -- Recipe name
    new_recipe.name = ImGui.InputText('Recipe Name', new_recipe.name)

    -- Tradeskill dropdown
    if ImGui.BeginCombo('Tradeskill', new_recipe.skill) then
        for _, skill in ipairs(tradeskills) do
            if ImGui.Selectable(skill, skill == new_recipe.skill) then
                new_recipe.skill = skill
            end
        end
        ImGui.EndCombo()
    end

    -- Trivial
    new_recipe.trivial = ImGui.InputInt('Trivial', new_recipe.trivial)

    -- Container
    new_recipe.container = ImGui.InputText('Container', new_recipe.container)
    ImGui.SameLine()
    if ImGui.Button('Cursor') then
        -- Get cursor item as container
        local cursor = mq.TLO.Cursor
        if cursor() and cursor.ID() then
            new_recipe.container = cursor.Name()
        end
    end

    -- Yield
    new_recipe.yield = ImGui.InputInt('Yield', new_recipe.yield)
    if new_recipe.yield < 1 then new_recipe.yield = 1 end

    -- Notes
    new_recipe.notes = ImGui.InputTextMultiline('Notes', new_recipe.notes, 400, 100)

    ImGui.Separator()
    ImGui.Text('Ingredients:')

    -- Ingredient list
    if ImGui.BeginChild('IngredientList', 0, 150, true) then
        local to_remove = nil
        for i, ing in ipairs(new_recipe.ingredients) do
            ImGui.Text(string.format('%dx %s', ing.qty, ing.name))
            ImGui.SameLine()
            if ImGui.Button('Remove##' .. i) then
                to_remove = i
            end
        end

        if to_remove then
            table.remove(new_recipe.ingredients, to_remove)
        end

        ImGui.EndChild()
    end

    -- Add ingredient
    ImGui.Separator()
    new_ingredient_name = ImGui.InputText('Item Name', new_ingredient_name)
    ImGui.SameLine()
    if ImGui.Button('Cursor') then
        local cursor = mq.TLO.Cursor
        if cursor() and cursor.ID() then
            new_ingredient_name = cursor.Name()
        end
    end

    new_ingredient_qty = ImGui.InputInt('Quantity', new_ingredient_qty)
    if new_ingredient_qty < 1 then new_ingredient_qty = 1 end

    if ImGui.Button('Add Ingredient') then
        if new_ingredient_name ~= '' then
            table.insert(new_recipe.ingredients, {
                name = new_ingredient_name,
                qty = new_ingredient_qty
            })
            new_ingredient_name = ''
            new_ingredient_qty = 1
        end
    end

    ImGui.Separator()

    -- Save/Update button
    local button_text = edit_mode and 'Update Recipe' or 'Save Recipe'
    if ImGui.Button(button_text) then
        if new_recipe.name ~= '' and new_recipe.container ~= '' and #new_recipe.ingredients > 0 then
            local success = false

            if edit_mode then
                -- Update existing recipe
                success = update_recipe(
                    edit_recipe_id,
                    new_recipe.name,
                    new_recipe.skill,
                    new_recipe.trivial,
                    new_recipe.container,
                    new_recipe.yield,
                    new_recipe.notes
                )

                if success then
                    -- Delete old ingredients and add new ones
                    delete_recipe_ingredients(edit_recipe_id)
                    for _, ing in ipairs(new_recipe.ingredients) do
                        add_ingredient(edit_recipe_id, ing.name, ing.qty)
                    end
                end
            else
                -- Add new recipe
                local recipe_id = add_recipe(
                    new_recipe.name,
                    new_recipe.skill,
                    new_recipe.trivial,
                    new_recipe.container,
                    new_recipe.yield,
                    new_recipe.notes
                )

                if recipe_id then
                    -- Save ingredients
                    for _, ing in ipairs(new_recipe.ingredients) do
                        add_ingredient(recipe_id, ing.name, ing.qty)
                    end
                    success = true
                end
            end

            if success then
                -- Reset form
                new_recipe = {
                    name = '',
                    skill = 'Baking',
                    trivial = 0,
                    container = '',
                    yield = 1,
                    notes = '',
                    ingredients = {}
                }
                edit_mode = false
                edit_recipe_id = nil

                -- Reload recipes
                load_recipes()

                combine_status = edit_mode and 'Recipe updated successfully!' or 'Recipe saved successfully!'
            else
                combine_status = 'Failed to save recipe'
            end
        else
            combine_status = 'Please fill in all required fields'
        end
    end

    -- Cancel button (only show in edit mode)
    if edit_mode then
        ImGui.SameLine()
        if ImGui.Button('Cancel') then
            -- Reset form
            new_recipe = {
                name = '',
                skill = 'Baking',
                trivial = 0,
                container = '',
                yield = 1,
                notes = '',
                ingredients = {}
            }
            edit_mode = false
            edit_recipe_id = nil
            combine_status = 'Edit cancelled'
        end
    end

    ImGui.TextColored(1, 1, 0, 1, combine_status)
end

-- Draw settings
local function draw_settings()
    ImGui.Text('Automation Settings')
    ImGui.Separator()

    settings.auto_inventory = ImGui.Checkbox('Auto Inventory Items', settings.auto_inventory)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Automatically inventory items after successful combines')
    end

    settings.clear_on_fail = ImGui.Checkbox('Clear Container on Fail', settings.clear_on_fail)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Automatically clear the container after failed combines')
    end

    settings.pause_on_skill_up = ImGui.Checkbox('Pause on Skill Up', settings.pause_on_skill_up)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Stop combining when you gain a skill point')
    end

    ImGui.Separator()

    settings.combine_delay = ImGui.SliderInt('Combine Delay (ms)', settings.combine_delay, 500, 5000)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Delay to wait for combine results')
    end

    ImGui.Separator()
    ImGui.Text('Database Statistics')
    ImGui.Separator()

    -- Get database stats
    local recipe_count = 0
    local total_combines = 0
    local total_successes = 0

    local stmt = db:prepare("SELECT COUNT(*) as count FROM recipes")
    if stmt then
        for row in stmt:nrows() do
            recipe_count = row.count
        end
        stmt:finalize()
    end

    stmt = db:prepare([[
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END) as successes
        FROM combine_history
    ]])
    if stmt then
        for row in stmt:nrows() do
            total_combines = row.total
            total_successes = row.successes
        end
        stmt:finalize()
    end

    ImGui.Text(string.format('Total Recipes: %d', recipe_count))
    ImGui.Text(string.format('Total Combines: %d', total_combines))
    if total_combines > 0 then
        ImGui.Text(string.format('Success Rate: %.1f%%', (total_successes / total_combines) * 100))
    end

    ImGui.Separator()

    if ImGui.Button('Export Recipes') then
        -- TODO: Implement recipe export
        combine_status = 'Export not yet implemented'
    end

    ImGui.SameLine()

    if ImGui.Button('Import Recipes') then
        -- TODO: Implement recipe import
        combine_status = 'Import not yet implemented'
    end
end

-- ImGui window
local function draw_gui()
    if not show_window then return end

    ImGui.SetNextWindowSize(800, 600, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowPos(100, 100, ImGuiCond.FirstUseEver)

    show_window, draw = ImGui.Begin(script_name .. ' v' .. version, show_window, window_flags)

    if not draw then
        ImGui.End()
        return
    end

    local pos_x, pos_y = ImGui.GetWindowPos()
    local size_x, size_y = ImGui.GetWindowSize()
    local display_w, display_h = ImGui.GetIO().DisplaySize.x, ImGui.GetIO().DisplaySize.y

    if pos_x < 0 then pos_x = 0 end
    if pos_y < 0 then pos_y = 0 end
    if pos_x + size_x > display_w then pos_x = display_w - size_x end
    if pos_y + size_y > display_h then pos_y = display_h - size_y end
    ImGui.SetWindowPos(pos_x, pos_y)

    -- Main content
    if ImGui.BeginTabBar('MainTabs') then
        -- Recipes tab
        if ImGui.BeginTabItem('Recipes') then
            -- Recipe list
            if ImGui.BeginChild('RecipeList', 300, 0) then
                ImGui.Text('Recipes (' .. #recipes .. '):')
                ImGui.Separator()

                if #recipes == 0 then
                    ImGui.Text('No recipes found.')
                    ImGui.Text('Use the "Add Recipe" tab to create recipes.')
                else
                    local groups, group_order = group_recipes()

                    for _, group_name in ipairs(group_order) do
                        local group = groups[group_name]
                        local group_count = #group

                        -- Create a unique key for this group
                        local group_key = group_name .. "_" .. group[1].recipe.skill

                        -- Initialize expansion state if not set
                        if expanded_groups[group_key] == nil then
                            expanded_groups[group_key] = group_count == 1 -- Auto-expand single-item groups
                        end

                        if group_count == 1 then
                            -- Single recipe, display directly
                            local recipe = group[1].recipe
                            if ImGui.Selectable(recipe.name .. ' (' .. recipe.skill .. ')',
                                    selected_recipe and selected_recipe.id == recipe.id) then
                                selected_recipe = recipe
                            end
                        else
                            -- Multiple recipes, show as collapsible group
                            local header_text = string.format("%s (%d) [%s]", group_name, group_count,
                                group[1].recipe.skill)

                            if ImGui.CollapsingHeader(header_text, expanded_groups[group_key] and ImGuiTreeNodeFlags.DefaultOpen or 0) then
                                expanded_groups[group_key] = true

                                -- Indent the group items
                                ImGui.Indent()

                                for _, item in ipairs(group) do
                                    local recipe = item.recipe
                                    local display_name = recipe.name

                                    -- Show abbreviated name if it's very similar to group name
                                    if recipe.name:find(group_name, 1, true) then
                                        display_name = recipe.name:gsub(group_name, ""):gsub("^%s+", ""):gsub("%s+$", "")
                                        if display_name == "" then
                                            display_name = recipe.name
                                        else
                                            display_name = "--> " .. display_name
                                        end
                                    end

                                    if ImGui.Selectable(display_name,
                                            selected_recipe and selected_recipe.id == recipe.id) then
                                        selected_recipe = recipe
                                    end
                                end

                                ImGui.Unindent()
                            else
                                expanded_groups[group_key] = false
                            end
                        end
                    end
                end

                ImGui.EndChild()
            end

            ImGui.SameLine()

            -- Recipe details
            if ImGui.BeginChild('RecipeDetails', 0, 0, true) then
                if selected_recipe then
                    ImGui.Text('Recipe: ' .. selected_recipe.name)
                    ImGui.Text('Skill: ' .. selected_recipe.skill)
                    ImGui.Text('Trivial: ' .. tostring(selected_recipe.trivial or 'Unknown'))
                    ImGui.Text('Container: ' .. selected_recipe.container)
                    ImGui.Text('Yield: ' .. tostring(selected_recipe.yield))

                    ImGui.Separator()
                    ImGui.Text('Ingredients:')

                    local ingredients = get_ingredients(selected_recipe.id)
                    for _, ing in ipairs(ingredients) do
                        local have = mq.TLO.FindItemCount(ing.item_name)()
                        local color = have >= ing.quantity and { 0, 1, 0, 1 } or { 1, 0, 0, 1 }
                        ImGui.TextColored(color[1], color[2], color[3], color[4],
                            string.format("%dx %s (have: %d)", ing.quantity, ing.item_name, have))
                    end

                    ImGui.Separator()

                    -- Statistics
                    local stats = get_combine_stats(selected_recipe.id)
                    ImGui.Text('Statistics:')
                    ImGui.Text(string.format('Total: %d, Success: %d (%.1f%%)',
                        stats.total, stats.success,
                        stats.total > 0 and (stats.success / stats.total * 100) or 0))
                    ImGui.Text(string.format('Failures: %d, Skill Gains: %d',
                        stats.failures, stats.skill_gains))

                    ImGui.Separator()

                    -- Batch combine controls
                    batch_count = ImGui.InputInt('Batch Count', batch_count)
                    if batch_count < 1 then batch_count = 1 end
                    if batch_count > 100 then batch_count = 100 end

                    local batch_active = start_batch and combine_queue ~= nil

                    -- Combine button
                    if not is_combining and not batch_active then
                        if ImGui.Button('Combine Recipe') then
                            batch_current = 0
                            combine_queue = selected_recipe.id
                            start_batch = false
                        end

                        ImGui.SameLine()
                        if ImGui.Button('AutoInventory') then
                            mq.cmd('/autoinv')
                            combine_status = 'Auto-inventory requested'
                        end

                        if batch_count > 1 then
                            ImGui.SameLine()
                            if ImGui.Button('Combine x' .. batch_count) then
                                batch_current = 0
                                combine_queue = selected_recipe.id
                                start_batch = true
                                combine_status = 'Starting batch combine...'
                            end
                        end
                    else
                        ImGui.Text(string.format('Combining... %d/%d', batch_current, batch_count))
                        ImGui.SameLine()
                        if ImGui.Button('Stop') then
                            stop_batch(string.format('Batch combine stopped at %d/%d', batch_current, batch_count))
                        end
                    end

                    ImGui.TextWrapped(combine_status)

                    ImGui.Separator()

                    -- Edit, Copy and Delete buttons
                    if ImGui.Button('Edit Recipe') then
                        load_recipe_for_edit(selected_recipe.id)
                    end

                    ImGui.SameLine()

                    if ImGui.Button('Copy Recipe') then
                        copy_recipe(selected_recipe.id)
                        combine_status = 'Recipe copied! Edit the name and save as new recipe.'
                    end

                    ImGui.SameLine()

                    if ImGui.Button('Delete Recipe') then
                        delete_recipe(selected_recipe.id)
                        selected_recipe = nil
                    end
                end

                ImGui.EndChild()
            end

            ImGui.EndTabItem()
        end

        -- Add/Edit Recipe tab
        local tab_title = edit_mode and 'Edit Recipe' or 'Add Recipe'
        if ImGui.BeginTabItem(tab_title) then
            draw_add_recipe_form()
            ImGui.EndTabItem()
        end

        -- Settings tab
        if ImGui.BeginTabItem('Settings') then
            draw_settings()
            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end

    ImGui.End()
end

-- Toggle window command
local function cmd_toggle()
    show_window = not show_window
end

-- Reset window position command
local function cmd_reset_window()
    show_window = true
    print('Window position will be reset on next display')
end

-- Main loop
local function main()
    -- Initialize database
    if not init_database() then
        print('Failed to initialize database - exiting')
        return
    end
    load_recipes()

    -- Bind commands
    mq.bind('/tradeskill', cmd_toggle)
    mq.bind('/tradeskillreset', cmd_reset_window)

    -- Initialize ImGui with error handling
    local success, error_msg = pcall(function()
        ImGui.Register('TradeskillAutomation', draw_gui)
    end)

    if not success then
        print('Failed to register ImGui: ' .. tostring(error_msg))
        print('You may need to delete ImGui settings and restart')
        return
    end

    print('Tradeskill Automation loaded! Use /tradeskill to toggle window')

    -- Main loop
    while true do
        -- Handle combine queue
        if combine_queue and not is_combining then
            if start_batch then
                if batch_current < batch_count then
                -- Check if we still have ingredients
                    local missing = check_ingredients(combine_queue)
                    if #missing == 0 then
                        batch_current = batch_current + 1
                        combine_status = string.format('Batch combine %d/%d...', batch_current, batch_count)

                        local combine_started, paused_for_skill_up = combine_recipe(combine_queue)
                        if not combine_started then
                            stop_batch(string.format('Batch stopped at %d/%d - Could not start combine', batch_current,
                                batch_count))
                        elseif paused_for_skill_up then
                            stop_batch(string.format('Batch paused after skill up at %d/%d', batch_current, batch_count))
                        elseif batch_current >= batch_count then
                            stop_batch(string.format('Batch complete! Processed %d combines', batch_count))
                        end
                    else
                        stop_batch(string.format('Batch stopped at %d/%d - Missing ingredients', batch_current,
                            batch_count))
                    end
                else
                    stop_batch(string.format('Batch complete! Processed %d combines', batch_count))
                end
            else
                -- Single combine
                combine_recipe(combine_queue)
                combine_queue = nil
            end
        end

        mq.doevents()
        mq.delay(50)
    end
end

-- Start script
main()
