-- HUDCustomizer — bootstrap
--
-- Injects the editor HUD element (HudElementCustomizer) into every UIHud via a
-- UIHud.init hook, together with two custom visibility groups:
--   [1] "hud_customizer" — wins while mod.is_customizing; only the editor draws
--   [2] "hide_hud"       — wins while mod.is_hud_hidden; nothing draws
-- Visibility groups gate drawing only; the editor element's update() keeps
-- running while "closed", which is how saved positions get re-applied after
-- every HUD creation.

local mod = get_mod("HUDCustomizer")

mod.is_customizing = false
mod.is_hud_hidden = false

local CUSTOMIZER_CLASS_NAME = "HudElementCustomizer"
local customizer_path = "HUDCustomizer/scripts/mods/HUDCustomizer/hud_element_customizer"

mod:add_require_path(customizer_path)

-- ============================================================================
-- HUD injection
-- ============================================================================

mod:hook("UIHud", "init", function(func, self, elements, visibility_groups, params)
    -- Work on shallow clones so we never pollute the shared, module-level
    -- element/visibility tables the game passes in (they are require()d once
    -- and reused for every HUD creation).
    elements = table.clone(elements)
    visibility_groups = table.clone(visibility_groups)

    -- De-dupe (recreate_hud passes back a definition list that already
    -- contains our entries; so does a hot reload mid-session).
    local element_index = table.find_by_key(elements, "class_name", CUSTOMIZER_CLASS_NAME)
    if element_index then
        table.remove(elements, element_index)
    end

    table.insert(elements, {
        class_name = CUSTOMIZER_CLASS_NAME,
        filename = customizer_path,
        use_hud_scale = true,
        visibility_groups = {
            "hud_customizer",
        },
    })

    local group_index = table.find_by_key(visibility_groups, "name", "hud_customizer")
    if group_index then
        table.remove(visibility_groups, group_index)
    end

    table.insert(visibility_groups, 1, {
        name = "hud_customizer",
        validation_function = function(hud)
            return mod:is_enabled() and mod.is_customizing
        end,
    })

    group_index = table.find_by_key(visibility_groups, "name", "hide_hud")
    if group_index then
        table.remove(visibility_groups, group_index)
    end

    table.insert(visibility_groups, 2, {
        name = "hide_hud",
        validation_function = function(hud)
            return mod:is_enabled() and mod.is_hud_hidden
        end,
    })

    return func(self, elements, visibility_groups, params)
end)

-- ============================================================================
-- Hidden-element enforcement
-- ============================================================================

-- The editor marks elements with `_is_hidden`; these class-level hooks make
-- the flag stick without touching each element instance. Subclasses that
-- override draw() entirely bypass this — a known, harmless limitation.
local function element_draw_hook(func, self, ...)
    if self._is_hidden then
        return
    end

    return func(self, ...)
end

mod:hook("HudElementBase", "draw", element_draw_hook)
mod:hook("ConstantElementBase", "draw", element_draw_hook)

-- ============================================================================
-- HUD recreation
-- ============================================================================

local function recreate_hud()
    local ui_manager = Managers.ui
    if not ui_manager then
        return
    end

    local hud = ui_manager._hud
    if not hud then
        return
    end

    local player_manager = Managers.player
    local player = player_manager and player_manager:local_player(1)
    if not player then
        return
    end

    local peer_id = player:peer_id()
    local local_player_id = player:local_player_id()
    local elements = hud._element_definitions
    local visibility_groups = hud._visibility_groups

    ui_manager:destroy_player_hud()
    ui_manager:create_player_hud(peer_id, local_player_id, elements, visibility_groups)
end

local function get_live_customizer()
    local ui_manager = Managers.ui
    local hud = ui_manager and ui_manager:get_hud()
    return hud and hud:element(CUSTOMIZER_CLASS_NAME)
end

-- Restore every modified node's real element to its pristine box via the live
-- editor, without touching the saved settings. Constant elements survive HUD
-- recreation, so recreating alone can never un-move them.
local function restore_all_live(customizer)
    if not (customizer and customizer.restore_node_defaults) then
        return false
    end

    local saved = customizer._saved_node_settings or {}
    for node_name in pairs(saved) do
        pcall(customizer.restore_node_defaults, customizer, node_name)
    end

    return true
end

local function reset_all()
    mod.is_customizing = false

    local customizer = get_live_customizer()
    local saved = (customizer and customizer._saved_node_settings) or mod:get("saved_node_settings") or {}

    if next(saved) == nil then
        mod:notify(mod:localize("notify_hud_reset"))
        return
    end

    -- Without a live editor we cannot restore constant elements, and wiping
    -- would destroy the only data that can — refuse instead of half-resetting.
    if not restore_all_live(customizer) then
        mod:notify(mod:localize("notify_no_hud"))
        return
    end

    customizer._saved_node_settings = {}
    mod:set("saved_node_settings", {})
    recreate_hud()
    mod:notify(mod:localize("notify_hud_reset"))
end

mod:command("hudcustomizer_reset", mod:localize("cmd_reset_description"), function()
    reset_all()
end)

-- ============================================================================
-- Keybind handlers (wired via keybind_type = "function_call" in _data.lua)
-- ============================================================================

function mod.toggle_hud_editor()
    if not mod.is_customizing then
        local ui_manager = Managers.ui
        local hud = ui_manager and ui_manager:get_hud()

        if not hud or not hud:element(CUSTOMIZER_CLASS_NAME) then
            mod:notify(mod:localize("notify_no_hud"))
            return
        end

        -- Refuse to open while a view (esc menu, inventory, ...) owns input.
        local view_handler = ui_manager._view_handler
        if view_handler and view_handler:using_input() then
            return
        end
    end

    mod.is_customizing = not mod.is_customizing
end

function mod.toggle_hud_visibility()
    mod.is_hud_hidden = not mod.is_hud_hidden
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

-- Any view opening (esc menu, inventory, ...) force-closes the editor; the
-- editor element notices the flag flip and pops its cursor itself.
mod:hook_safe("UIViewHandler", "open_view", function(self, view_name)
    mod.is_customizing = false
end)

function mod.on_setting_changed(setting_id)
    if mod._refresh_editor_settings then
        mod._refresh_editor_settings()
    end
end

function mod.on_all_mods_loaded()
    -- Fires even when the mod is disabled — don't touch the HUD then.
    if not mod:is_enabled() then
        return
    end

    -- The HUD may already exist (mod reload mid-mission) — recreate it so the
    -- injection hook applies.
    recreate_hud()
end

function mod.on_enabled(initial_call)
    if not initial_call then
        recreate_hud()
    end
end

function mod.on_disabled(initial_call)
    mod.is_customizing = false
    mod.is_hud_hidden = false

    if not initial_call then
        -- Constant elements survive HUD recreation — put them back first.
        restore_all_live(get_live_customizer())

        -- Hooks are auto-disabled by DMF at this point and the editor element
        -- stays inert while disabled, so recreating the HUD restores a
        -- vanilla layout. Saved settings are kept for re-enabling.
        recreate_hud()
    end
end
