local mod = get_mod("HUDCustomizer")

local EDITOR_CLASS_NAME = "HudElementHudCustomizer"
local EDITOR_FILE_PATH = "HUDCustomizer/scripts/mods/HUDCustomizer/hud_element_editor"
local LAYOUT_SETTING_ID = "layout"

-- ############################################################################
-- State
-- ############################################################################

-- Single source of truth for "editor is open". The editor element watches this
-- flag in its update and activates/deactivates itself accordingly.
mod._editor_active = false

-- Per-HUD-build registry of movable nodes, keyed "ElementName|node_name".
-- Rebuilt by the editor element's init on every HUD build. Entries:
--   element, element_name, node_name, uses_hud_scale,
--   def_x, def_y, def_z, def_h_align, def_v_align,
--   px, py, pw, ph (proxy rect in editor-virtual units, synced while active)
mod._nodes = {}

-- Saved layout, cached at load (mod:get clones tables, so keep one reference
-- and write through on change). Map-only tables: DMF rejects mixed tables.
local layout = mod:get(LAYOUT_SETTING_ID)
if type(layout) ~= "table" then
    layout = { version = 1, nodes = {} }
end
if type(layout.nodes) ~= "table" then
    layout.nodes = {}
end
mod._layout = layout

function mod._save_layout()
    mod:set(LAYOUT_SETTING_ID, mod._layout)
end

-- ############################################################################
-- Helpers
-- ############################################################################

local function get_hud()
    local ui_manager = Managers.ui
    return ui_manager and ui_manager._hud
end

local function split_key(key)
    -- Element names never contain "|"; node names are split off after the first one.
    local element_name, node_name = string.match(key, "^(.-)|(.*)$")
    return element_name, node_name
end

-- ############################################################################
-- Applying offsets (every call into a foreign element is pcall'd: game patches
-- can change signatures, and a moved node must never crash the mod)
-- ############################################################################

-- Applies the saved offset for one registry key to its live element.
function mod._apply_offset(key)
    local reg = mod._nodes[key]
    if not reg then
        return
    end

    local saved = mod._layout.nodes[key]
    local dx = (saved and saved.dx) or 0
    local dy = (saved and saved.dy) or 0

    -- nil alignments: set_scenegraph_position keeps the node's authored alignment.
    pcall(reg.element.set_scenegraph_position, reg.element, reg.node_name,
        reg.def_x + dx, reg.def_y + dy, reg.def_z, nil, nil)
end

-- Applies every saved offset. Runs on every HUD build (editor element init),
-- so positions survive load, hub<->mission transitions, spectate and reloads.
function mod._apply_all_offsets()
    local hud = get_hud()
    local nodes = mod._layout.nodes
    local pruned = false

    for key, _ in pairs(nodes) do
        if mod._nodes[key] then
            mod._apply_offset(key)
        elseif hud then
            -- Not in this HUD's registry: the node is excluded, belongs to a
            -- different context (hub vs mission vs spectator), or is stale.
            -- Prune only when the element exists here but the node is gone for
            -- good; entries for other contexts are kept.
            local element_name, node_name = split_key(key)
            local element = element_name and hud:element(element_name)
            if element and type(element._ui_scenegraph) == "table"
                and rawget(element._ui_scenegraph, node_name) == nil then
                nodes[key] = nil
                pruned = true
                mod:info("Pruned stale layout entry '%s' (node no longer exists).", key)
            end
        end
    end

    if pruned then
        mod._save_layout()
    end
end

-- Restores authored defaults (position and alignments) on all live nodes.
function mod._restore_defaults()
    for _, reg in pairs(mod._nodes) do
        pcall(reg.element.set_scenegraph_position, reg.element, reg.node_name,
            reg.def_x, reg.def_y, reg.def_z, reg.def_h_align, reg.def_v_align)
    end
end

-- ############################################################################
-- Editor toggle
-- ############################################################################

-- Closes the editor. Also deactivates the live element directly so the cursor
-- is released even when the element's update will not run again (menus, reload).
function mod._close_editor()
    mod._editor_active = false

    local hud = get_hud()
    local editor = hud and hud:element(EDITOR_CLASS_NAME)
    if editor then
        editor:_set_active(false)
    end
end

-- Keybind entry point (DMF calls mod[function_name](is_pressed), no self).
function mod.toggle_editor()
    if mod._editor_active then
        mod._close_editor()
        mod:echo("HUD editor: closed")
        return
    end

    local ui_manager = Managers.ui
    local hud = ui_manager and ui_manager._hud
    if not hud then
        return
    end

    -- A view (inventory, options, ...) is already using the cursor.
    local view_handler = ui_manager._view_handler
    if view_handler and view_handler:using_input() then
        return
    end

    -- Editor element not injected, or not in the active visibility group
    -- (dead, cutscene, ...): nothing would happen, so refuse to open.
    if not hud:element(EDITOR_CLASS_NAME) then
        return
    end
    local visible_elements = hud._currently_visible_elements
    if visible_elements and not visible_elements[EDITOR_CLASS_NAME] then
        return
    end

    mod._editor_active = true
    mod:echo("HUD editor: open")
end

-- ############################################################################
-- Hooks, command, lifecycle
-- ############################################################################

-- Opening any menu force-closes the editor (and releases the cursor).
mod:hook_safe("UIViewHandler", "open_view", function(self, view_name)
    if mod._editor_active then
        mod._close_editor()
    end
end)

mod:command("hudcustomizer_reset", "Reset all HUD element positions to their defaults.", function()
    mod._layout.nodes = {}
    mod._save_layout()
    mod._restore_defaults()
    mod:echo("HUD Customizer: layout reset to defaults.")
end)

-- DMF lifecycle events fire without self.
function mod.on_disabled()
    mod._close_editor()
    -- Restore stock positions on the live HUD; the saved layout is kept and
    -- re-applies when the mod is re-enabled.
    mod._restore_defaults()
end

function mod.on_unload()
    mod._close_editor()
end

-- ############################################################################
-- Editor element injection (DMF injects after UIHud._setup_elements and removes
-- the element cleanly on HUD destroy and on mod disable)
-- ############################################################################

mod:register_hud_element({
    class_name = EDITOR_CLASS_NAME,
    filename = EDITOR_FILE_PATH,
    use_hud_scale = false,
    visibility_groups = { "alive" },
})
