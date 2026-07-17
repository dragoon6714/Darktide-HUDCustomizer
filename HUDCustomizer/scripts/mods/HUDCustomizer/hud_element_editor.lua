local mod = get_mod("HUDCustomizer")

local UIWorkspaceSettings = mod:original_require("scripts/settings/ui/ui_workspace_settings")
local UIWidget = mod:original_require("scripts/managers/ui/ui_widget")
local Hud = mod:original_require("scripts/utilities/ui/hud")

-- ############################################################################
-- Constants
-- ############################################################################

-- { alpha, r, g, b }
local COLOR_BORDER = { 180, 255, 255, 255 }
local COLOR_BORDER_HOVERED = { 255, 255, 255, 128 }
local COLOR_BORDER_SELECTED = { 255, 226, 199, 126 }
local COLOR_FILL = { 40, 255, 255, 255 }

local MIN_PROXY_SIZE = 8 -- editor-virtual units, keeps zero-size nodes clickable

-- Elements that break (or must not break) when moved. Seeded from Custom HUD,
-- proven in production; constant elements are out of MVP scope.
local EXCLUDED_ELEMENTS = {
    HudElementHudCustomizer = true,
    HudElementCrosshair = true,
    HudElementInteraction = true,
    HudElementWorldMarkers = true,
    HudElementEmoteWheel = true,
    HudElementSmartTagging = true,
    HudElementDamageIndicator = true,
    HudElementPrologueTutorialInfoBox = true,
    HudElementPrologueTutorialSequenceTransitionEnd = true,
}

local EXCLUDED_NODES = {
    HudElementPlayerWeaponHandler = {
        weapon_slot_1 = true,
        weapon_slot_2 = true,
        weapon_slot_3 = true,
        weapon_slot_4 = true,
    },
    HudElementTacticalOverlay = {
        background = true,
        canvas = true,
    },
}

-- ############################################################################
-- Class
-- ############################################################################

local HudElementHudCustomizer = class("HudElementHudCustomizer", "HudElementBase")

function HudElementHudCustomizer:init(parent, draw_layer, start_scale)
    self._active = false
    self._cursor_pushed = false -- track OUR push state, never input_manager state
    self._hovered_key = nil
    self._selected_key = nil
    self._drag = nil -- { key, press_x, press_y, start_dx, start_dy }

    -- Discovery: rebuilds mod._nodes and fills the proxy definitions.
    local definitions = self:_build_definitions(parent)

    HudElementHudCustomizer.super.init(self, parent, draw_layer, start_scale, definitions)

    -- Widgets start visible; the editor starts inactive.
    self:_set_proxies_visible(false)

    mod:info("Discovered %d movable HUD nodes.", #self._widgets)

    -- Re-apply saved offsets on every HUD build (load, hub<->mission, spectate, reload).
    mod._apply_all_offsets()
end

-- ############################################################################
-- Discovery (once per HUD build)
-- ############################################################################

function HudElementHudCustomizer:_build_definitions(hud)
    local nodes = {}
    mod._nodes = nodes

    local definitions = {
        scenegraph_definition = {
            screen = UIWorkspaceSettings.screen,
        },
        widget_definitions = {},
    }

    local hud_scale_lookup = hud._elements_hud_scale_lookup
    local elements_array = hud._elements_array

    for i = 1, #elements_array do
        local element = elements_array[i]
        local element_name = element.__class_name

        if not EXCLUDED_ELEMENTS[element_name] then
            local ui_scenegraph = element._ui_scenegraph
            local hierarchical_scenegraph = ui_scenegraph and ui_scenegraph.hierarchical_scenegraph

            if hierarchical_scenegraph then
                local element_definitions = element._definitions
                local scenegraph_definition = element_definitions and element_definitions.scenegraph_definition
                local excluded_nodes = EXCLUDED_NODES[element_name]

                -- One movable node per top-level child of each root node
                -- (Custom HUD's proven discovery path).
                for j = 1, #hierarchical_scenegraph do
                    local children = hierarchical_scenegraph[j].children

                    for k = 1, children and #children or 0 do
                        local child = children[k]
                        local child_name = child.name

                        if child_name and not (excluded_nodes and excluded_nodes[child_name]) then
                            local key = element_name .. "|" .. child_name

                            if not nodes[key] then
                                nodes[key] = self:_make_registry_entry(element, element_name, child,
                                    scenegraph_definition and scenegraph_definition[child_name],
                                    hud_scale_lookup[element_name] == true,
                                    mod._layout.nodes[key])
                                self:_make_proxy(definitions, key)
                            end
                        end
                    end
                end
            end
        end
    end

    return definitions
end

-- Snapshots the node's default position/alignments (authored definition first,
-- live node as fallback) for delta math and reset.
function HudElementHudCustomizer:_make_registry_entry(element, element_name, child, definition_node, uses_hud_scale, saved_offset)
    local default_position = definition_node and definition_node.position
    local offset_x, offset_y = 0, 0

    if not default_position then
        -- Live fallback: after a mid-game mod reload the live position can
        -- already include our saved offset; subtract it so the delta is not
        -- applied twice (the next HUD rebuild re-snapshots cleanly anyway).
        default_position = child.local_position or child.position
        if saved_offset then
            offset_x = saved_offset.dx or 0
            offset_y = saved_offset.dy or 0
        end
    end

    local size = child.size

    return {
        element = element,
        element_name = element_name,
        node_name = child.name,
        uses_hud_scale = uses_hud_scale,
        def_x = ((default_position and default_position[1]) or 0) - offset_x,
        def_y = ((default_position and default_position[2]) or 0) - offset_y,
        def_z = (default_position and default_position[3]) or 0,
        def_h_align = (definition_node and definition_node.horizontal_alignment) or child.horizontal_alignment,
        def_v_align = (definition_node and definition_node.vertical_alignment) or child.vertical_alignment,
        -- Proxy rect in editor-virtual (1920x1080) units; synced while active.
        px = 0,
        py = 0,
        pw = math.max((size and size[1]) or 0, MIN_PROXY_SIZE),
        ph = math.max((size and size[2]) or 0, MIN_PROXY_SIZE),
    }
end

-- One scenegraph node (parented to "screen": position == virtual world position)
-- plus one widget per movable node. Two rect passes fake a bordered box: a
-- full-size border rect with an inset fill rect on top.
function HudElementHudCustomizer:_make_proxy(definitions, key)
    definitions.scenegraph_definition[key] = {
        parent = "screen",
        position = { 0, 0, 0 },
        size = { MIN_PROXY_SIZE, MIN_PROXY_SIZE },
        -- left/top alignment by omission (only "center"/"right" and
        -- "center"/"bottom" are honored by the scenegraph updater)
    }

    definitions.widget_definitions[key] = UIWidget.create_definition({
        {
            pass_type = "rect",
            style_id = "border",
            style = {
                color = COLOR_BORDER,
                offset = { 0, 0, 1 },
            },
        },
        {
            pass_type = "rect",
            style_id = "fill",
            style = {
                color = COLOR_FILL,
                offset = { 2, 2, 2 },
                size = { MIN_PROXY_SIZE - 4, MIN_PROXY_SIZE - 4 },
            },
        },
    }, key)
end

-- ############################################################################
-- Activation
-- ############################################################################

function HudElementHudCustomizer:_set_active(active)
    if self._active == active then
        return
    end

    self._active = active

    if active then
        if not self._cursor_pushed then
            Managers.input:push_cursor(self.__class_name)
            self._cursor_pushed = true
        end
        self:_set_proxies_visible(true)
    else
        self._drag = nil
        self._selected_key = nil
        self._hovered_key = nil
        self:_set_proxies_visible(false)
        if self._cursor_pushed then
            Managers.input:pop_cursor(self.__class_name)
            self._cursor_pushed = false
        end
        -- Re-assert offsets on close (apply moments: HUD build, live drag, close).
        mod._apply_all_offsets()
        mod._save_layout()
    end
end

function HudElementHudCustomizer:_set_proxies_visible(visible)
    for _, widget in pairs(self._widgets_by_name) do
        widget.visible = visible
    end
end

-- Returning true here alone blocks gameplay input while the editor is open
-- (UIHud:using_input -> Managers.ui:using_input -> HumanGameplay._input_active).
function HudElementHudCustomizer:using_input()
    return self._active
end

-- ############################################################################
-- Update (runs only while the "alive" visibility group is active)
-- ############################################################################

function HudElementHudCustomizer:update(dt, t, ui_renderer, render_settings, input_service)
    if mod._editor_active ~= self._active then
        self:_set_active(mod._editor_active)
    end

    if not self._active then
        HudElementHudCustomizer.super.update(self, dt, t, ui_renderer, render_settings, input_service)
        return
    end

    local inverse_scale = render_settings.inverse_scale or RESOLUTION_LOOKUP.inverse_scale

    -- Sync BEFORE super.update so the base recomputes our scenegraph (and
    -- dirties the proxy widgets) in the same frame: no one-frame lag.
    self:_sync_proxies()

    HudElementHudCustomizer.super.update(self, dt, t, ui_renderer, render_settings, input_service)

    local cursor = input_service:get("cursor")
    local cursor_x, cursor_y
    if cursor then
        local cursor_array = Vector3.to_array(cursor)
        cursor_x = cursor_array[1] * inverse_scale
        cursor_y = cursor_array[2] * inverse_scale
    end

    self._hovered_key = cursor_x and self:_hit_test(cursor_x, cursor_y) or nil

    -- Selection + drag start (click empty space deselects).
    if cursor_x and input_service:get("left_pressed") then
        local key = self._hovered_key
        self._selected_key = key

        if key then
            local saved = mod._layout.nodes[key]
            self._drag = {
                key = key,
                press_x = cursor_x,
                press_y = cursor_y,
                start_dx = (saved and saved.dx) or 0,
                start_dy = (saved and saved.dy) or 0,
            }
        else
            self._drag = nil
        end
    end

    -- Dragging: recompute the offset from the latched press position and the
    -- committed start offset, apply live, save on release.
    local drag = self._drag
    if drag then
        if cursor_x and input_service:get("left_hold") then
            local reg = mod._nodes[drag.key]

            if reg then
                -- Deltas are measured in editor-virtual units; the target node
                -- lives in its element's scale space (Hud.hud_scale() for
                -- use_hud_scale elements, RESOLUTION_LOOKUP.scale otherwise).
                local element_scale = reg.uses_hud_scale and Hud.hud_scale() or RESOLUTION_LOOKUP.scale
                local factor = RESOLUTION_LOOKUP.scale / element_scale
                local dx = drag.start_dx + (cursor_x - drag.press_x) * factor
                local dy = drag.start_dy + (cursor_y - drag.press_y) * factor

                mod._layout.nodes[drag.key] = { dx = dx, dy = dy }
                mod._apply_offset(drag.key)
            else
                self._drag = nil
            end
        end

        if input_service:get("left_released") then
            self._drag = nil
            mod._save_layout()
        end
    end

    self:_update_proxy_colors()
end

-- Keeps every proxy box on top of its real node's rect. Positions come from
-- the node's world position (element scale space) converted to editor-virtual
-- units; only writes to the scenegraph when something actually changed.
function HudElementHudCustomizer:_sync_proxies()
    local res_scale = RESOLUTION_LOOKUP.scale
    local hud_scale = nil -- lazy, only when a hud-scale element is met

    for key, reg in pairs(mod._nodes) do
        -- rawget: the scenegraph is a strict table, and a node that vanished
        -- mid-session must be skipped, not error.
        local scenegraph_node = rawget(reg.element._ui_scenegraph, reg.node_name)
        local world_position = scenegraph_node and scenegraph_node.world_position
        local size = scenegraph_node and scenegraph_node.size

        if world_position and size then
            local element_scale = res_scale
            if reg.uses_hud_scale then
                hud_scale = hud_scale or Hud.hud_scale()
                element_scale = hud_scale
            end

            local factor = element_scale / res_scale
            local px = world_position[1] * factor
            local py = world_position[2] * factor
            local pw = math.max(size[1] * factor, MIN_PROXY_SIZE)
            local ph = math.max(size[2] * factor, MIN_PROXY_SIZE)

            if px ~= reg.px or py ~= reg.py or pw ~= reg.pw or ph ~= reg.ph then
                reg.px = px
                reg.py = py
                reg.pw = pw
                reg.ph = ph

                self:set_scenegraph_position(key, px, py, 0)
                self:_set_scenegraph_size(key, pw, ph)

                local fill_style = self._widgets_by_name[key].style.fill
                fill_style.size[1] = pw - 4
                fill_style.size[2] = ph - 4
            end
        end
    end
end

-- Topmost wins: self._widgets is the real draw order (later widgets draw on top).
function HudElementHudCustomizer:_hit_test(cursor_x, cursor_y)
    local widgets = self._widgets
    local nodes = mod._nodes

    for i = #widgets, 1, -1 do
        local key = widgets[i].name
        local reg = nodes[key]

        if reg and cursor_x >= reg.px and cursor_x <= reg.px + reg.pw
            and cursor_y >= reg.py and cursor_y <= reg.py + reg.ph then
            return key
        end
    end

    return nil
end

function HudElementHudCustomizer:_update_proxy_colors()
    for key, widget in pairs(self._widgets_by_name) do
        local style = widget.style.border

        if key == self._selected_key then
            style.color = COLOR_BORDER_SELECTED
        elseif key == self._hovered_key then
            style.color = COLOR_BORDER_HOVERED
        else
            style.color = COLOR_BORDER
        end
    end
end

-- ############################################################################
-- Lifecycle
-- ############################################################################

-- Called by UIHud when the active visibility group changes. Losing visibility
-- (death, cutscene, popup, emote wheel, ...) force-closes the editor.
function HudElementHudCustomizer:set_visible(visible)
    if not visible and self._active then
        mod._close_editor()
    end
end

function HudElementHudCustomizer:destroy(ui_renderer)
    if self._active then
        -- A new HUD build must not reopen the editor.
        mod._editor_active = false
        self:_set_active(false)
    end

    HudElementHudCustomizer.super.destroy(self, ui_renderer)
end

return HudElementHudCustomizer
