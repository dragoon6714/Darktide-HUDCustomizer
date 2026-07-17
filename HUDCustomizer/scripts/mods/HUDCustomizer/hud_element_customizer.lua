-- HudElementCustomizer — the in-game HUD editor.
--
-- A HudElementBase subclass injected into every UIHud (see HUDCustomizer.lua).
-- On its first update() it enumerates every top-level scenegraph node of every
-- HUD element (mission/hub elements via the parent UIHud's visibility groups,
-- plus the always-alive constant elements), builds a draggable proxy box per
-- node in its own scenegraph, and re-applies saved positions to the real
-- elements. While mod.is_customizing the "hud_customizer" visibility group
-- wins and only this element draws: proxy boxes, an optional element-list
-- panel, a snapping grid and a help bar.
--
-- Coordinate model: all stored positions are top-left-anchored 1920x1080
-- virtual UI units. Saved positions are written to real elements with
-- pcall(element.set_scenegraph_position, ..., "left", "top") so stored
-- absolute coordinates stay stable regardless of a node's original anchoring.
-- Constant elements do not render under Hud.hud_scale() while this element
-- does, so their coordinates are divided by hud_scale on the way in and
-- multiplied on the way out.

local mod = get_mod("HUDCustomizer")

local UIWorkspaceSettings = mod:original_require("scripts/settings/ui/ui_workspace_settings")
local UIWidget = mod:original_require("scripts/managers/ui/ui_widget")
local UIRenderer = mod:original_require("scripts/managers/ui/ui_renderer")
local ColorUtilities = mod:original_require("scripts/utilities/ui/colors")

-- ============================================================================
-- Exclusions
-- ============================================================================

-- Elements that break (or make no sense) when repositioned.
local EXCLUDED_ELEMENTS = {
    HudElementCustomizer = true,                            -- the editor itself
    HudElementCrosshair = true,                             -- center-locked
    HudElementDamageIndicator = true,                       -- radial, center-locked
    HudElementWorldMarkers = true,                          -- 3D-projected
    HudElementInteraction = true,                           -- 3D-projected
    HudElementSmartTagging = true,                          -- 3D-projected
    HudElementEmoteWheel = true,                            -- radial input widget
    HudElementPrologueTutorialSequenceTransitionEnd = true, -- scripted sequence
    HudElementPrologueTutorialInfoBox = true,               -- scripted sequence
    ConstantElementWatermark = true,                        -- pointless
    ConstantElementPopupHandler = true,                     -- modal popups
    ConstantElementSoftwareCursor = true,                   -- the cursor itself
}

-- Per-element scenegraph nodes to skip (handler sub-slots, full-screen canvases).
local EXCLUDED_SCENEGRAPHS = {
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

-- ============================================================================
-- Cached mod settings (mod:get clones tables on every call — cache reads)
-- ============================================================================

local _grid_snap_enabled = true
local _grid_size = 20
local _snap_to_elements = true
local _show_info_panel = true

local function _refresh_settings()
    _grid_snap_enabled = mod:get("grid_snap_enabled") ~= false
    _grid_size = math.max(tonumber(mod:get("grid_size")) or 20, 2)
    _snap_to_elements = mod:get("snap_to_elements") ~= false
    _show_info_panel = mod:get("show_info_panel") ~= false
end

mod._refresh_editor_settings = _refresh_settings
_refresh_settings()

-- ============================================================================
-- Constants
-- ============================================================================

local DRAG_THRESHOLD = 3           -- px of cursor travel before a press becomes a drag
local NUDGE_STEP = 1               -- UI units per frame (arrow keys)
local NUDGE_STEP_FAST = 5          -- with shift held
local SCALE_STEP = 0.05            -- per scroll notch
local SCALE_MIN, SCALE_MAX = 0.1, 10
local ELEMENT_SNAP_THRESHOLD = 8   -- UI units
local MAX_GRID_LINES = 240         -- don't draw (still snap) absurdly dense grids
local PERSIST_QUIET_TIME = 0.4     -- seconds of inactivity before flushing mod:set

local FONT_TYPE = "proxima_nova_bold"

local COLOR_FILL_DEFAULT = { 110, 150, 150, 150 }
local COLOR_FILL_HOVER = { 160, 210, 210, 210 }
local COLOR_FILL_HIDDEN = { 140, 160, 40, 40 }
local COLOR_FILL_HIDDEN_HOVER = { 200, 220, 60, 60 }
local COLOR_BORDER_DEFAULT = { 255, 0, 0, 0 }
local COLOR_BORDER_SELECTED = { 255, 255, 220, 0 }
local COLOR_BORDER_LIST_HOVER = { 255, 90, 200, 255 }
local COLOR_GRID_LINE = { 100, 255, 255, 255 }
local COLOR_GRID_CENTER = { 160, 255, 200, 0 }
local COLOR_HELP_BG = { 190, 10, 10, 10 }
local COLOR_HELP_TEXT = { 255, 210, 210, 210 }

local PANEL_WIDTH = 400
local PANEL_LINE_HEIGHT = 20
local PANEL_HEADER_HEIGHT = 28
local PANEL_FOOTER_HEIGHT = 48
local PANEL_LIST_ROWS = 18
local PANEL_FONT_SIZE = 16
local PANEL_FONT_SIZE_SMALL = 14
local PANEL_SCROLL_SPEED = 3
local PANEL_BG_COLOR = { 210, 15, 15, 15 }
local PANEL_HEADER_COLOR = { 230, 30, 30, 38 }
local PANEL_LINE_HOVER_COLOR = { 110, 70, 70, 90 }
local PANEL_LINE_SELECTED_COLOR = { 160, 90, 130, 90 }
local PANEL_TEXT_COLOR = { 255, 205, 205, 205 }
local PANEL_TEXT_HIDDEN_COLOR = { 190, 220, 150, 60 }

-- ============================================================================
-- Keyboard helpers (raw Keyboard global; input_service has no modifier keys)
-- ============================================================================

local _kb_index_cache = {}

local function _keyboard()
    return rawget(_G, "Keyboard")
end

local function _button_index(kb, key_name)
    local cached = _kb_index_cache[key_name]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    if kb.button_index then
        local ok, result = pcall(kb.button_index, key_name)
        if ok and result then
            _kb_index_cache[key_name] = result
            return result
        end
    end

    if kb.button_id then
        local ok, result = pcall(kb.button_id, key_name)
        if ok and result then
            _kb_index_cache[key_name] = result
            return result
        end
    end

    _kb_index_cache[key_name] = false
    return nil
end

local function _key_held(key_name)
    local kb = _keyboard()
    if not kb then
        return false
    end

    local idx = _button_index(kb, key_name)
    return (idx and kb.button(idx) > 0.5) or false
end

local function is_shift_held()
    return _key_held("left shift")
end

local function is_ctrl_held()
    return _key_held("left ctrl")
end

local function is_alt_held()
    return _key_held("left alt")
end

-- ============================================================================
-- Utilities
-- ============================================================================

local function split_node_name(node_name)
    local splits = string.split(node_name, "|")
    return splits[1], splits[2]
end

local function short_node_name(node_name)
    local element_name, scenegraph_id = split_node_name(node_name)
    local short = element_name:gsub("^HudElement", ""):gsub("^ConstantElement", "C:")
    if scenegraph_id and scenegraph_id ~= "" then
        return short .. " | " .. scenegraph_id
    end
    return short
end

local function _is_constant_element(element_name)
    return string.starts_with(element_name, "ConstantElement")
end

local function _get_hud_scale()
    local ok, save_data = pcall(function()
        return Managers.save:account_data()
    end)
    local interface_settings = ok and save_data and save_data.interface_settings
    local hud_scale = ((interface_settings and interface_settings.hud_scale) or 100) / 100

    if hud_scale <= 0 then
        hud_scale = 1
    end

    return hud_scale
end

local function _clone_pristine(pristine)
    return {
        position = { pristine.position[1], pristine.position[2], pristine.position[3] },
        size = { pristine.size[1], pristine.size[2] },
        horizontal_alignment = pristine.horizontal_alignment,
        vertical_alignment = pristine.vertical_alignment,
    }
end

-- UIRenderer.draw_text's signature has shifted across patches; probe once.
local _draw_text_variant

local function _safe_draw_text(ui_renderer, text, font_size, position, size, color, horizontal_alignment, vertical_alignment)
    if text == nil or text == "" then
        return
    end

    local options = {
        horizontal_alignment = horizontal_alignment or "left",
        vertical_alignment = vertical_alignment or "center",
        drop_shadow = true,
        word_wrap = false,
    }

    local probes = {
        function() UIRenderer.draw_text(ui_renderer, text, FONT_TYPE, font_size, position, size, color, options) end,
        function() UIRenderer.draw_text(ui_renderer, text, FONT_TYPE, font_size, position, size, color) end,
        function() UIRenderer.draw_text(ui_renderer, text, font_size, FONT_TYPE, position, size, color, options) end,
        function() UIRenderer.draw_text(ui_renderer, text, font_size, FONT_TYPE, position, size, color) end,
    }

    if _draw_text_variant then
        pcall(probes[_draw_text_variant])
        return
    end

    for i = 1, #probes do
        if pcall(probes[i]) then
            _draw_text_variant = i
            return
        end
    end
end

-- Best snap position along one axis against another box (min/mid/max edges).
local function _best_snap_axis(pos, size, other_pos, other_size, threshold)
    local best_diff = threshold
    local best_snap = nil

    local mid = pos + size * 0.5
    local max = pos + size
    local other_mid = other_pos + other_size * 0.5
    local other_max = other_pos + other_size

    local candidates = {
        { math.abs(pos - other_pos), other_pos },
        { math.abs(mid - other_mid), other_mid - size * 0.5 },
        { math.abs(max - other_max), other_max - size },
        { math.abs(pos - other_max), other_max },
        { math.abs(max - other_pos), other_pos - size },
    }

    for i = 1, #candidates do
        local diff, snap = candidates[i][1], candidates[i][2]
        if diff < best_diff then
            best_diff = diff
            best_snap = snap
        end
    end

    return best_snap, best_diff
end

-- ============================================================================
-- Class
-- ============================================================================

local HudElementCustomizer = class("HudElementCustomizer", "HudElementBase")

function HudElementCustomizer:init(parent, draw_layer, start_scale)
    self._setup_complete = false
    self._always_full_alpha = true
    self._start_scale = start_scale

    self._saved_node_settings = mod:get("saved_node_settings") or {}
    self._pristine = {}
    self._all_node_names = {}

    self._selected_node = nil
    self._drag = nil
    self._widget_press_stack = {}
    self._last_cursor = { 0, 0 }
    self._settings_dirty = false
    self._last_change_t = 0

    self._cursor_pushed = false
    self._using_cursor = false

    self._panel_position = mod:get("panel_position")
    self._panel_scroll_offset = 0
    self._panel_hovered_index = nil
    self._panel_dragging = false
    self._panel_drag_offset = nil

    _refresh_settings()

    local definitions = {
        scenegraph_definition = {
            screen = UIWorkspaceSettings.screen,
        },
        widget_definitions = {},
    }

    HudElementCustomizer.super.init(self, parent, draw_layer, start_scale, definitions)
end

-- ============================================================================
-- Element lookup
-- ============================================================================

function HudElementCustomizer:_get_element(element_name)
    local element = self._parent:element(element_name)

    if not element then
        local ok, constant_elements = pcall(function()
            return Managers.ui:ui_constant_elements()
        end)
        if ok and constant_elements then
            element = constant_elements:element(element_name)
        end
    end

    return element
end

-- Union of every visibility group's elements ("detect ALL UI"), plus the
-- constant elements' default group.
function HudElementCustomizer:_collect_target_element_names()
    local names = {}

    local groups = self._parent._visibility_groups or {}
    for _, group in ipairs(groups) do
        local visible_elements = group.visible_elements
        if visible_elements then
            for element_name in pairs(visible_elements) do
                names[element_name] = true
            end
        end
    end

    local ok, constant_elements = pcall(function()
        return Managers.ui:ui_constant_elements()
    end)
    if ok and constant_elements then
        for _, group in ipairs(constant_elements._visibility_groups or {}) do
            if group.name == "default" and group.visible_elements then
                for element_name in pairs(group.visible_elements) do
                    names[element_name] = true
                end
            end
        end
    end

    return names
end

-- ============================================================================
-- Setup: enumerate nodes, build proxy widgets, apply saved settings
-- ============================================================================

function HudElementCustomizer:_setup_elements(render_settings)
    local inverse_scale = render_settings.inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    self._inverse_scale = inverse_scale
    local saved_node_settings = self._saved_node_settings
    local hud_scale = _get_hud_scale()

    -- Fresh tables every setup so nothing stale survives HUD recreation.
    local definitions = {
        scenegraph_definition = {
            screen = UIWorkspaceSettings.screen,
        },
        widget_definitions = {},
    }
    local all_node_names = {}
    local pristine_by_node = {}

    local target_names = self:_collect_target_element_names()

    for element_name in pairs(target_names) do
        repeat
            if EXCLUDED_ELEMENTS[element_name] then
                break
            end

            local element = self:_get_element(element_name)
            if not element or type(element._ui_scenegraph) ~= "table" then
                break
            end

            -- element._ui_scenegraph is a strict table: never probe unknown
            -- keys directly, only rawget / iterate hierarchical_scenegraph.
            local hierarchical_scenegraph = rawget(element._ui_scenegraph, "hierarchical_scenegraph") or {}
            local excluded_scenegraphs = EXCLUDED_SCENEGRAPHS[element_name]
            local is_constant = _is_constant_element(element_name)

            for _, root in ipairs(hierarchical_scenegraph) do
                for _, child in ipairs(root.children or {}) do
                    repeat
                        local child_name = child.name
                        if not child_name or (excluded_scenegraphs and excluded_scenegraphs[child_name]) then
                            break
                        end

                        local node_name = string.format("%s|%s", element_name, child_name)
                        if definitions.widget_definitions[node_name] then
                            break
                        end

                        -- Reset target ("pristine" box, top-left space).
                        -- Prefer the persisted snapshot: constant elements
                        -- survive HUD recreations, so their live position may
                        -- already carry a previous modification — only a node
                        -- with no saved entry is guaranteed unmodified.
                        local node_settings = saved_node_settings[node_name]
                        local saved_defaults = node_settings and node_settings.default_settings
                        local pristine

                        if saved_defaults and saved_defaults.position and saved_defaults.size then
                            pristine = {
                                position = {
                                    tonumber(saved_defaults.position[1]) or 0,
                                    tonumber(saved_defaults.position[2]) or 0,
                                    tonumber(saved_defaults.position[3]) or 0,
                                },
                                size = {
                                    tonumber(saved_defaults.size[1]) or 25,
                                    tonumber(saved_defaults.size[2]) or 25,
                                },
                                horizontal_alignment = saved_defaults.horizontal_alignment,
                                vertical_alignment = saved_defaults.vertical_alignment,
                            }
                        else
                            local live_position = child.world_position or child.position or { 0, 0, 0 }
                            local live_size = child.size or { 25, 25 }
                            pristine = {
                                position = { live_position[1] or 0, live_position[2] or 0, live_position[3] or 0 },
                                size = { live_size[1] or 25, live_size[2] or 25 },
                                horizontal_alignment = child.horizontal_alignment,
                                vertical_alignment = child.vertical_alignment,
                            }

                            if is_constant then
                                -- Constant elements don't render under
                                -- hud_scale; convert into the editor's
                                -- hud-scaled space.
                                pristine.position[1] = pristine.position[1] / hud_scale
                                pristine.position[2] = pristine.position[2] / hud_scale
                                pristine.size[1] = pristine.size[1] / hud_scale
                                pristine.size[2] = pristine.size[2] / hud_scale
                            end

                            if node_settings then
                                node_settings.default_settings = _clone_pristine(pristine)

                                if is_constant then
                                    -- A modified constant element survives HUD
                                    -- recreation, so a live snapshot taken now
                                    -- may already carry the saved offset.
                                    mod:info("Reset target for [%s] captured from a possibly-modified live position", node_name)
                                end
                            end
                        end

                        if pristine.size[1] == 0 then pristine.size[1] = 25 end
                        if pristine.size[2] == 0 then pristine.size[2] = 25 end

                        pristine_by_node[node_name] = pristine

                        local saved_position = node_settings and (node_settings.position or {
                            node_settings.x, node_settings.y, node_settings.z,
                        })
                        local position = {
                            (saved_position and saved_position[1]) or pristine.position[1],
                            (saved_position and saved_position[2]) or pristine.position[2],
                            (saved_position and saved_position[3]) or pristine.position[3],
                        }
                        local saved_size = node_settings and node_settings.size
                        local size = {
                            (saved_size and saved_size[1] ~= 0 and saved_size[1]) or pristine.size[1],
                            (saved_size and saved_size[2] ~= 0 and saved_size[2]) or pristine.size[2],
                        }

                        definitions.scenegraph_definition[node_name] = {
                            parent = "screen",
                            size = { size[1], size[2] },
                            position = { position[1], position[2], position[3] },
                            horizontal_alignment = "left",
                            vertical_alignment = "top",
                        }

                        definitions.widget_definitions[node_name] = self:_create_proxy_definition(node_name, {
                            is_hidden = (node_settings and node_settings.is_hidden) or false,
                            is_list_hover = false,
                            suppress_hover_labels = false,
                            size = { size[1], size[2] },
                            scale = (node_settings and node_settings.scale) or 1,
                            node_x = position[1],
                            node_y = position[2],
                            node_z = position[3],
                        })

                        all_node_names[#all_node_names + 1] = node_name
                    until true
                end
            end
        until true
    end

    table.sort(all_node_names)

    self._pristine = pristine_by_node
    self._all_node_names = all_node_names
    self._definitions = definitions

    local scale = (inverse_scale ~= 0 and 1 / inverse_scale) or self._start_scale
    self._ui_scenegraph = self:_create_scenegraph(definitions, scale)
    self._widgets = {}
    self._widgets_by_name = {}
    self:_create_widgets(definitions, self._widgets, self._widgets_by_name)

    self:_apply_saved_node_settings()

    self._setup_complete = true
end

function HudElementCustomizer:_create_proxy_definition(node_name, content_overrides)
    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale

    return UIWidget.create_definition({
        {
            pass_type = "hotspot",
            content_id = "hotspot",
            content = {
                pressed_callback = callback(self, "_on_widget_pressed", node_name),
                right_pressed_callback = callback(self, "_on_widget_right_pressed", node_name),
                double_click_callback = callback(self, "_on_widget_double_clicked", node_name),
            },
        },
        {
            pass_type = "rect",
            style_id = "border",
            style = {
                color = { 255, 0, 0, 0 },
                offset = { 0, 0, 1 },
            },
            change_function = function(content, style)
                local color
                if content.hotspot.is_selected then
                    color = COLOR_BORDER_SELECTED
                elseif content.is_list_hover then
                    color = COLOR_BORDER_LIST_HOVER
                else
                    color = COLOR_BORDER_DEFAULT
                end
                style.color[1] = color[1]
                style.color[2] = color[2]
                style.color[3] = color[3]
                style.color[4] = color[4]
            end,
        },
        {
            pass_type = "rect",
            style_id = "fill",
            style = {
                color = { 168, 168, 168, 168 },
                size = { 0, 0 },
                offset = { 2, 2, 2 },
            },
            change_function = function(content, style)
                local hotspot = content.hotspot
                local progress = hotspot.anim_hover_progress or 0
                if content.is_list_hover then
                    progress = 1
                end
                local is_hidden = content.is_hidden
                local from = is_hidden and COLOR_FILL_HIDDEN or COLOR_FILL_DEFAULT
                local to = is_hidden and COLOR_FILL_HIDDEN_HOVER or COLOR_FILL_HOVER

                local size = content.size
                style.size[1] = math.max((size[1] or 0) - 4, 0)
                style.size[2] = math.max((size[2] or 0) - 4, 0)

                ColorUtilities.color_lerp(from, to, progress, style.color, false)
            end,
        },
        {
            pass_type = "text",
            value_id = "label",
            value = short_node_name(node_name),
            style_id = "label",
            style = {
                size = { 1000, 20 },
                font_size = 16 * inverse_scale,
                font_type = FONT_TYPE,
                text_horizontal_alignment = "left",
                text_vertical_alignment = "top",
                text_color = { 255, 255, 255, 255 },
                drop_shadow = true,
                offset = { 0, -18 * inverse_scale, 4 },
            },
            visibility_function = function(content, style)
                return (content.hotspot.is_hover or content.is_list_hover)
                    and not content.suppress_hover_labels
            end,
        },
        {
            pass_type = "text",
            value_id = "readout",
            value = "",
            style_id = "readout",
            style = {
                size = { 400, 20 },
                font_size = 14 * inverse_scale,
                font_type = FONT_TYPE,
                text_horizontal_alignment = "left",
                text_vertical_alignment = "top",
                text_color = { 255, 255, 230, 130 },
                drop_shadow = true,
                offset = { 0, -34 * inverse_scale, 4 },
            },
            visibility_function = function(content, style)
                return content.hotspot.is_selected
            end,
            change_function = function(content, style)
                local size = content.size
                content.readout = string.format("x:%.0f  y:%.0f  %.0fx%.0f  x%.2f%s",
                    content.node_x or 0, content.node_y or 0,
                    (size and size[1]) or 0, (size and size[2]) or 0,
                    content.scale or 1,
                    content.is_hidden and "  [hidden]" or "")
            end,
        },
    }, node_name, content_overrides)
end

-- ============================================================================
-- Saved settings: create / persist / apply / prune
-- ============================================================================

function HudElementCustomizer:_get_node_settings(node_name)
    local settings = self._saved_node_settings[node_name]

    if not settings then
        local pristine = self._pristine[node_name]
        if not pristine then
            return nil
        end

        settings = {
            x = pristine.position[1],
            y = pristine.position[2],
            z = pristine.position[3],
            position = { pristine.position[1], pristine.position[2], pristine.position[3] },
            size = { pristine.size[1], pristine.size[2] },
            scale = 1,
            default_settings = _clone_pristine(pristine),
        }
        self._saved_node_settings[node_name] = settings
    end

    return settings
end

-- Entries loaded from disk may lack a size array (hand-edited files).
function HudElementCustomizer:_ensure_settings_size(node_name, settings)
    if not settings.size then
        local pristine = self._pristine[node_name]
        settings.size = {
            (pristine and pristine.size[1]) or 25,
            (pristine and pristine.size[2]) or 25,
        }
    end
    return settings.size
end

function HudElementCustomizer:_mark_dirty(t)
    self._settings_dirty = true
    self._last_change_t = t or self._last_change_t
end

function HudElementCustomizer:_flush_dirty_settings(t)
    if not self._settings_dirty then
        return
    end

    if t and (t - self._last_change_t) < PERSIST_QUIET_TIME then
        return
    end

    self:_persist_saved_settings()
end

-- Normalize every entry to SJSON-safe shape (string-keyed maps whose values
-- are scalars or pure arrays — never mixed tables) and store it.
function HudElementCustomizer:_persist_saved_settings()
    local saved = self._saved_node_settings or {}

    for _, settings in pairs(saved) do
        settings.x = tonumber(settings.x) or 0
        settings.y = tonumber(settings.y) or 0
        settings.z = tonumber(settings.z) or 0
        settings.position = { settings.x, settings.y, settings.z }

        if settings.size then
            settings.size = {
                tonumber(settings.size[1]) or 0,
                tonumber(settings.size[2]) or 0,
            }
        end

        if settings.is_hidden ~= true then
            settings.is_hidden = nil
        end

        local defaults = settings.default_settings
        if defaults then
            local position = defaults.position or {}
            local size = defaults.size or {}
            defaults.position = {
                tonumber(position[1]) or 0,
                tonumber(position[2]) or 0,
                tonumber(position[3]) or 0,
            }
            defaults.size = {
                tonumber(size[1]) or 0,
                tonumber(size[2]) or 0,
            }
        end
    end

    mod:set("saved_node_settings", saved)
    self._settings_dirty = false
end

-- Push one node's saved settings onto the real element.
function HudElementCustomizer:_write_through(node_name, settings)
    local element_name, scenegraph_id = split_node_name(node_name)
    if not scenegraph_id then
        return false
    end

    local element = self:_get_element(element_name)
    if not element or type(element._ui_scenegraph) ~= "table" then
        return false
    end

    if rawget(element._ui_scenegraph, scenegraph_id) == nil then
        return false
    end

    local x = settings.x or 0
    local y = settings.y or 0
    local z = settings.z or 0
    local is_constant = _is_constant_element(element_name)
    local hud_scale = is_constant and _get_hud_scale() or 1

    if is_constant then
        x = x * hud_scale
        y = y * hud_scale
    end

    -- pcall: some handler elements override set_scenegraph_position and
    -- forward into nested sub-elements; patches change internals.
    local ok = pcall(element.set_scenegraph_position, element, scenegraph_id, x, y, z, "left", "top")

    if ok then
        -- Only touch size if the user actually resized this node. A missing
        -- default snapshot (hand-edited file) counts as resized.
        local size = settings.size
        local default_size = settings.default_settings and settings.default_settings.size
        if size and (not default_size
            or math.abs(size[1] - default_size[1]) > 0.5 or math.abs(size[2] - default_size[2]) > 0.5) then
            local w = size[1] * hud_scale
            local h = size[2] * hud_scale
            pcall(element._set_scenegraph_size, element, scenegraph_id, w, h)
        end
    end

    return ok
end

-- Applied on first update after every HUD creation and whenever the editor
-- closes. Prunes entries whose scenegraph node no longer exists (game patch
-- renamed it) — but only when the element itself resolved, so entries for
-- elements absent from the current HUD variant (hub vs mission) survive.
function HudElementCustomizer:_apply_saved_node_settings()
    local saved = self._saved_node_settings
    if not saved then
        return
    end

    local hidden_by_element = {}
    local pruned = false

    for node_name, settings in pairs(saved) do
        local element_name, scenegraph_id = split_node_name(node_name)
        local element = scenegraph_id and self:_get_element(element_name)

        if element and type(element._ui_scenegraph) == "table" then
            if rawget(element._ui_scenegraph, scenegraph_id) ~= nil then
                self:_write_through(node_name, settings)

                if hidden_by_element[element_name] == nil then
                    hidden_by_element[element_name] = false
                end
                hidden_by_element[element_name] = hidden_by_element[element_name] or (settings.is_hidden == true)
            else
                saved[node_name] = nil
                pruned = true
                mod:info("Pruned stale saved entry [%s] (scenegraph node no longer exists)", node_name)
            end
        elseif not scenegraph_id then
            saved[node_name] = nil
            pruned = true
        end
    end

    for element_name, is_hidden in pairs(hidden_by_element) do
        local element = self:_get_element(element_name)
        if element then
            element._is_hidden = is_hidden or nil
        end
    end

    if pruned then
        self:_persist_saved_settings()
    end
end

-- ============================================================================
-- Reset
-- ============================================================================

-- Recompute the element-wide hidden flag from all of its saved nodes (hiding
-- any node hides the whole element in v1).
function HudElementCustomizer:_update_element_hidden_flag(element_name)
    local element = self:_get_element(element_name)
    if not element then
        return
    end

    local any_hidden = false
    for other_name, other_settings in pairs(self._saved_node_settings) do
        local other_element_name = split_node_name(other_name)
        if other_element_name == element_name and other_settings.is_hidden then
            any_hidden = true
            break
        end
    end

    element._is_hidden = any_hidden or nil
end

-- Put the real element's node back to its pristine box. Does NOT touch the
-- saved settings or the proxy (used standalone by the bootstrap when the mod
-- is disabled, and by reset_node).
function HudElementCustomizer:restore_node_defaults(node_name)
    local pristine = self._pristine[node_name]
    if not pristine then
        return false
    end

    local element_name, scenegraph_id = split_node_name(node_name)
    local element = self:_get_element(element_name)

    if element and scenegraph_id and type(element._ui_scenegraph) == "table"
        and rawget(element._ui_scenegraph, scenegraph_id) ~= nil then
        local is_constant = _is_constant_element(element_name)
        local hud_scale = is_constant and _get_hud_scale() or 1
        local x = pristine.position[1] * hud_scale
        local y = pristine.position[2] * hud_scale

        pcall(element.set_scenegraph_position, element, scenegraph_id, x, y, pristine.position[3], "left", "top")
        pcall(element._set_scenegraph_size, element, scenegraph_id,
            pristine.size[1] * hud_scale, pristine.size[2] * hud_scale)
    end

    return true
end

function HudElementCustomizer:reset_node(node_name)
    local pristine = self._pristine[node_name]
    if not pristine then
        return
    end

    self:restore_node_defaults(node_name)

    -- Restore the proxy.
    self:set_scenegraph_position(node_name, pristine.position[1], pristine.position[2], pristine.position[3])
    self:_set_scenegraph_size(node_name, pristine.size[1], pristine.size[2])

    local widget = self._widgets_by_name[node_name]
    if widget then
        widget.content.is_hidden = false
        widget.content.scale = 1
        widget.content.size[1] = pristine.size[1]
        widget.content.size[2] = pristine.size[2]
        widget.content.node_x = pristine.position[1]
        widget.content.node_y = pristine.position[2]
        widget.content.node_z = pristine.position[3]
    end

    self._saved_node_settings[node_name] = nil

    -- Another node of the same element may still be hidden.
    local element_name = split_node_name(node_name)
    self:_update_element_hidden_flag(element_name)

    self:_persist_saved_settings()
end

-- ============================================================================
-- Selection & widget presses
-- ============================================================================

function HudElementCustomizer:_set_selected(node_name)
    local previous = self._selected_node
    if previous and previous ~= node_name then
        local widget = self._widgets_by_name[previous]
        if widget then
            widget.content.hotspot.is_selected = false
        end
    end

    self._selected_node = node_name

    if node_name then
        local widget = self._widgets_by_name[node_name]
        if widget then
            widget.content.hotspot.is_selected = true
        end
    end
end

function HudElementCustomizer:_on_widget_pressed(node_name)
    self._widget_press_stack[#self._widget_press_stack + 1] = { node_name = node_name, press_type = "left" }
end

function HudElementCustomizer:_on_widget_right_pressed(node_name)
    self._widget_press_stack[#self._widget_press_stack + 1] = { node_name = node_name, press_type = "right" }
end

function HudElementCustomizer:_on_widget_double_clicked(node_name)
    table.clear(self._widget_press_stack)
    self._drag = nil
    self:reset_node(node_name)
end

-- Overlapping proxies all fire their callbacks in the same frame; act once on
-- the highest-z winner, never inside the callback itself.
function HudElementCustomizer:_handle_widget_presses()
    local stack = self._widget_press_stack
    local stack_size = #stack
    if stack_size == 0 then
        return
    end

    local press_data = stack[1]
    if stack_size > 1 then
        local highest_z = -math.huge
        for i = 1, stack_size do
            local entry = stack[i]
            local ok, position = pcall(self.scenegraph_position, self, entry.node_name)
            local z = (ok and position and position[3]) or 0
            if z > highest_z then
                highest_z = z
                press_data = entry
            end
        end
    end

    table.clear(stack)

    if press_data.press_type == "left" then
        self:_process_press_left(press_data.node_name)
    else
        self:_process_press_right(press_data.node_name)
    end
end

function HudElementCustomizer:_process_press_left(node_name)
    local was_selected = self._selected_node == node_name
    if not was_selected then
        self:_set_selected(node_name)
    end

    local ok, position = pcall(self.scenegraph_position, self, node_name)
    if not ok or not position then
        return
    end

    self._drag = {
        node_name = node_name,
        was_selected = was_selected,
        start_cursor = { self._last_cursor[1], self._last_cursor[2] },
        start_x = position[1],
        start_y = position[2],
        current_x = position[1],
        current_y = position[2],
        moved = false,
    }
end

function HudElementCustomizer:_process_press_right(node_name)
    local element_name = split_node_name(node_name)
    local widget = self._widgets_by_name[node_name]
    if not widget then
        return
    end

    local should_hide = not widget.content.is_hidden
    widget.content.is_hidden = should_hide

    local settings = self:_get_node_settings(node_name)
    if settings then
        settings.is_hidden = should_hide or nil
    end

    self:_update_element_hidden_flag(element_name)
    self:_persist_saved_settings()
end

-- ============================================================================
-- Snapping
-- ============================================================================

function HudElementCustomizer:_grid_snap_active()
    local active = _grid_snap_enabled
    if is_ctrl_held() then
        active = not active
    end
    return active
end

function HudElementCustomizer:_element_snap_active()
    local active = _snap_to_elements
    if is_ctrl_held() then
        active = not active
    end
    return active
end

function HudElementCustomizer:_apply_snapping(node_name, dest_x, dest_y)
    local ok, size = pcall(self.scenegraph_size, self, node_name)
    if not ok or not size then
        return dest_x, dest_y
    end

    if self:_grid_snap_active() and _grid_size > 0 then
        dest_x = math.floor(dest_x / _grid_size + 0.5) * _grid_size
        dest_y = math.floor(dest_y / _grid_size + 0.5) * _grid_size
    end

    if self:_element_snap_active() then
        local w = size[1] or 0
        local h = size[2] or 0
        local best_x_diff = ELEMENT_SNAP_THRESHOLD
        local best_y_diff = ELEMENT_SNAP_THRESHOLD
        local snapped_x, snapped_y = dest_x, dest_y

        local all_node_names = self._all_node_names
        for i = 1, #all_node_names do
            local other_name = all_node_names[i]
            if other_name ~= node_name then
                local other_settings = self._saved_node_settings[other_name]
                if not (other_settings and other_settings.is_hidden) then
                    local ok_p, other_pos = pcall(self.scenegraph_position, self, other_name)
                    local ok_s, other_size = pcall(self.scenegraph_size, self, other_name)
                    if ok_p and ok_s and other_pos and other_size then
                        local snap_x, diff_x = _best_snap_axis(dest_x, w, other_pos[1], other_size[1] or 0, ELEMENT_SNAP_THRESHOLD)
                        if snap_x and diff_x < best_x_diff then
                            best_x_diff = diff_x
                            snapped_x = snap_x
                        end

                        local snap_y, diff_y = _best_snap_axis(dest_y, h, other_pos[2], other_size[2] or 0, ELEMENT_SNAP_THRESHOLD)
                        if snap_y and diff_y < best_y_diff then
                            best_y_diff = diff_y
                            snapped_y = snap_y
                        end
                    end
                end
            end
        end

        dest_x, dest_y = snapped_x, snapped_y
    end

    return dest_x, dest_y
end

-- ============================================================================
-- Input handling
-- ============================================================================

function HudElementCustomizer:_update_widget_readout(node_name)
    local widget = self._widgets_by_name[node_name]
    if not widget then
        return
    end

    local ok_p, position = pcall(self.scenegraph_position, self, node_name)
    if ok_p and position then
        widget.content.node_x = position[1]
        widget.content.node_y = position[2]
        widget.content.node_z = position[3]
    end
end

function HudElementCustomizer:_handle_input(input_service, t)
    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale

    -- Active drag
    local drag = self._drag
    if drag then
        if input_service:get("left_hold") then
            local cursor = self._last_cursor
            local dx = (cursor[1] - drag.start_cursor[1]) * inverse_scale
            local dy = (cursor[2] - drag.start_cursor[2]) * inverse_scale

            if not drag.moved and (math.abs(dx) > DRAG_THRESHOLD or math.abs(dy) > DRAG_THRESHOLD) then
                drag.moved = true
            end

            if drag.moved then
                local dest_x, dest_y = self:_apply_snapping(drag.node_name, drag.start_x + dx, drag.start_y + dy)
                drag.current_x = dest_x
                drag.current_y = dest_y
                self:set_scenegraph_position(drag.node_name, dest_x, dest_y)
                self:_update_widget_readout(drag.node_name)
            end
        else
            -- Release: commit a real drag, or treat as a plain click.
            if drag.moved then
                local settings = self:_get_node_settings(drag.node_name)
                if settings then
                    settings.x = drag.current_x
                    settings.y = drag.current_y
                    self:_write_through(drag.node_name, settings)
                    self:_persist_saved_settings()
                end
            elseif drag.was_selected then
                self:_set_selected(nil)
            end

            self._drag = nil
        end

        return
    end

    -- Keyboard/scroll actions on the selected node
    local node_name = self._selected_node
    if not node_name then
        return
    end

    local settings

    -- Scroll wheel: uniform scale
    local scroll_axis = input_service:get("scroll_axis")
    if scroll_axis and scroll_axis[2] and scroll_axis[2] ~= 0 then
        settings = self:_get_node_settings(node_name)
        if settings then
            self:_ensure_settings_size(node_name, settings)
            local old_scale = settings.scale or 1
            local new_scale = math.clamp(old_scale + (scroll_axis[2] > 0 and SCALE_STEP or -SCALE_STEP), SCALE_MIN, SCALE_MAX)

            if new_scale ~= old_scale then
                local base_w = (settings.size[1] or 0) / old_scale
                local base_h = (settings.size[2] or 0) / old_scale
                settings.scale = new_scale
                settings.size = { base_w * new_scale, base_h * new_scale }

                self:_set_scenegraph_size(node_name, settings.size[1], settings.size[2])

                local widget = self._widgets_by_name[node_name]
                if widget then
                    widget.content.size[1] = settings.size[1]
                    widget.content.size[2] = settings.size[2]
                    widget.content.scale = new_scale
                end

                self:_write_through(node_name, settings)
                self:_mark_dirty(t)
            end
        end
    end

    -- Arrow keys: nudge (Shift = fast, Alt = resize)
    local axis = input_service:get("navigation_keys_virtual_axis")
    if axis and (axis[1] ~= 0 or axis[2] ~= 0) then
        settings = settings or self:_get_node_settings(node_name)
        if settings then
            if is_alt_held() then
                self:_ensure_settings_size(node_name, settings)
                local dw = axis[1]
                local dh = -axis[2]
                local new_w = math.max((settings.size[1] or 25) + dw, 5)
                local new_h = math.max((settings.size[2] or 25) + dh, 5)
                settings.size = { new_w, new_h }

                self:_set_scenegraph_size(node_name, new_w, new_h)

                local widget = self._widgets_by_name[node_name]
                if widget then
                    widget.content.size[1] = new_w
                    widget.content.size[2] = new_h
                end
            else
                local step = is_shift_held() and NUDGE_STEP_FAST or NUDGE_STEP
                settings.x = (settings.x or 0) + axis[1] * step
                settings.y = (settings.y or 0) - axis[2] * step
                self:set_scenegraph_position(node_name, settings.x, settings.y)
                self:_update_widget_readout(node_name)
            end

            self:_write_through(node_name, settings)
            self:_mark_dirty(t)
        end
    end
end

-- ============================================================================
-- Cursor management (track our own push state; imbalanced pops break the
-- cursor stack game-wide)
-- ============================================================================

function HudElementCustomizer:using_input()
    return self._using_cursor
end

function HudElementCustomizer:_activate_mouse_cursor()
    if not self._cursor_pushed then
        Managers.input:push_cursor(self.__class_name)
        self._cursor_pushed = true
    end
    self._using_cursor = true
end

function HudElementCustomizer:_deactivate_mouse_cursor()
    if self._cursor_pushed then
        Managers.input:pop_cursor(self.__class_name)
        self._cursor_pushed = false
    end
    self._using_cursor = false
end

function HudElementCustomizer:_close_editor_interactions()
    -- An uncommitted drag is discarded: put the proxy back where the saved
    -- settings say it is, so reopening the editor shows the truth.
    local drag = self._drag
    if drag and drag.moved then
        pcall(self.set_scenegraph_position, self, drag.node_name, drag.start_x, drag.start_y)
        self:_update_widget_readout(drag.node_name)
    end

    self._drag = nil
    self._panel_dragging = false
    self._panel_drag_offset = nil
    table.clear(self._widget_press_stack)

    if self._using_cursor then
        self:_deactivate_mouse_cursor()
    end

    if self._settings_dirty then
        self:_persist_saved_settings()
    end
end

-- Called by UIHud when our visibility group flips.
function HudElementCustomizer:set_visible(visible, ui_renderer, use_retained_mode)
    if visible == false then
        self:_close_editor_interactions()

        if self._setup_complete then
            self:_apply_saved_node_settings()
        end
    end
end

function HudElementCustomizer:destroy(ui_renderer)
    self:_close_editor_interactions()
    HudElementCustomizer.super.destroy(self, ui_renderer)
end

-- ============================================================================
-- Update
-- ============================================================================

function HudElementCustomizer:update(dt, t, ui_renderer, render_settings, input_service)
    if not self._setup_complete then
        -- While the mod is disabled the element can still get instantiated
        -- (stale definitions survive in recreated HUDs after the injection
        -- hook is auto-disabled) — stay fully inert so saved positions are
        -- never applied to a "vanilla" HUD.
        if not mod:is_enabled() then
            return
        end

        -- First tick after every HUD creation: enumerate everything and
        -- re-apply saved settings (visibility groups gate drawing only, so
        -- this runs even while the editor is "closed").
        self:_setup_elements(render_settings)
        HudElementCustomizer.super.update(self, dt, t, ui_renderer, render_settings, input_service)
        return
    end

    self._inverse_scale = render_settings.inverse_scale

    local is_customizing = mod:is_enabled() and mod.is_customizing

    if is_customizing then
        self:_activate_mouse_cursor()

        local cursor = input_service:get("cursor")
        if cursor then
            local cursor_array = Vector3.to_array(cursor)
            self._last_cursor[1] = cursor_array[1]
            self._last_cursor[2] = cursor_array[2]
        end

        -- Panel first so clicks on it never leak through to proxies below;
        -- but never while a proxy drag is in flight.
        local panel_consumed = not self._drag and self:_handle_panel_input(input_service) or false

        if panel_consumed then
            table.clear(self._widget_press_stack)
        else
            self:_handle_widget_presses()
            self:_handle_input(input_service, t)
        end

        self:_flush_dirty_settings(t)
        self:_sync_list_hover()
    elseif self._using_cursor then
        self:_close_editor_interactions()
    end

    HudElementCustomizer.super.update(self, dt, t, ui_renderer, render_settings, input_service)
end

-- Highlight the proxy for the panel row under the cursor; suppress proxy
-- hover labels while the mouse is over the panel.
function HudElementCustomizer:_sync_list_hover()
    local preview_node = self._panel_mouse_over and self._panel_hovered_index
        and self._all_node_names[self._panel_hovered_index] or nil

    for node_name, widget in pairs(self._widgets_by_name) do
        local content = widget.content
        if content.hotspot then
            content.is_list_hover = node_name == preview_node
            content.suppress_hover_labels = self._panel_mouse_over or false
        end
    end
end

-- ============================================================================
-- Panel: input
-- ============================================================================

function HudElementCustomizer:_panel_metrics()
    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local total = #self._all_node_names
    local rows = math.min(total, PANEL_LIST_ROWS)
    local width = PANEL_WIDTH * inverse_scale
    local line_h = PANEL_LINE_HEIGHT * inverse_scale
    local header_h = PANEL_HEADER_HEIGHT * inverse_scale
    local footer_h = self._selected_node and PANEL_FOOTER_HEIGHT * inverse_scale or 0
    local height = header_h + rows * line_h + footer_h

    return width, height, header_h, line_h, rows, footer_h
end

function HudElementCustomizer:_panel_xy()
    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local width = self:_panel_metrics()

    if not self._panel_position then
        local screen_w = RESOLUTION_LOOKUP.width * inverse_scale
        self._panel_position = { screen_w - width - 10 * inverse_scale, 10 * inverse_scale }
    end

    return self._panel_position[1], self._panel_position[2]
end

function HudElementCustomizer:_handle_panel_input(input_service)
    self._panel_mouse_over = false
    self._panel_hovered_index = nil

    if not _show_info_panel then
        return false
    end

    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local cx = self._last_cursor[1] * inverse_scale
    local cy = self._last_cursor[2] * inverse_scale
    local panel_w, panel_h, header_h, line_h, rows = self:_panel_metrics()
    local px, py = self:_panel_xy()
    local total = #self._all_node_names

    -- Ongoing panel drag
    if self._panel_dragging then
        if input_service:get("left_hold") then
            local screen_w = RESOLUTION_LOOKUP.width * inverse_scale
            local screen_h = RESOLUTION_LOOKUP.height * inverse_scale
            local offset = self._panel_drag_offset or { 0, 0 }
            self._panel_position = {
                math.clamp(cx - offset[1], 0, math.max(screen_w - panel_w, 0)),
                math.clamp(cy - offset[2], 0, math.max(screen_h - panel_h, 0)),
            }
        else
            self._panel_dragging = false
            self._panel_drag_offset = nil
            mod:set("panel_position", { self._panel_position[1], self._panel_position[2] })
        end
        return true
    end

    local in_panel = cx >= px and cx <= px + panel_w and cy >= py and cy <= py + panel_h
    if not in_panel then
        return false
    end

    self._panel_mouse_over = true

    local in_header = cy <= py + header_h
    if in_header and input_service:get("left_pressed") then
        self._panel_dragging = true
        self._panel_drag_offset = { cx - px, cy - py }
        return true
    end

    -- Row hover
    local list_top = py + header_h
    if cy >= list_top and cy < list_top + rows * line_h then
        local row = math.floor((cy - list_top) / line_h) + 1 + self._panel_scroll_offset
        if row >= 1 and row <= total then
            self._panel_hovered_index = row
        end
    end

    if input_service:get("left_pressed") and self._panel_hovered_index then
        local node_name = self._all_node_names[self._panel_hovered_index]
        if node_name and self._widgets_by_name[node_name] then
            if self._selected_node == node_name then
                self:_set_selected(nil)
            else
                self:_set_selected(node_name)
                self:_update_widget_readout(node_name)
            end
        end
        return true
    end

    if input_service:get("right_pressed") and self._panel_hovered_index then
        local node_name = self._all_node_names[self._panel_hovered_index]
        if node_name and self._widgets_by_name[node_name] then
            self:_process_press_right(node_name)
        end
        return true
    end

    local scroll_axis = input_service:get("scroll_axis")
    if scroll_axis and scroll_axis[2] and scroll_axis[2] ~= 0 then
        local max_scroll = math.max(total - rows, 0)
        local direction = scroll_axis[2] > 0 and -PANEL_SCROLL_SPEED or PANEL_SCROLL_SPEED
        self._panel_scroll_offset = math.clamp(self._panel_scroll_offset + direction, 0, max_scroll)
        return true
    end

    -- Swallow any other mouse interaction that started over the panel
    -- (right_hold included: the proxy underneath fires its callback during
    -- the draw pass and would otherwise be processed a frame later, when
    -- right_pressed is already false).
    return input_service:get("left_pressed") or input_service:get("left_hold")
        or input_service:get("right_pressed") or input_service:get("right_hold") or false
end

-- ============================================================================
-- Drawing
-- ============================================================================

function HudElementCustomizer:_draw_widgets(dt, t, input_service, ui_renderer, render_settings)
    HudElementCustomizer.super._draw_widgets(self, dt, t, input_service, ui_renderer, render_settings)

    self:_draw_grid(ui_renderer)
    self:_draw_help_bar(ui_renderer)
    self:_draw_panel(ui_renderer)
end

function HudElementCustomizer:_draw_grid(ui_renderer)
    -- Only while actually dragging with grid snap in effect.
    if not (self._drag and self._drag.moved and self:_grid_snap_active()) then
        return
    end

    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local screen_w = RESOLUTION_LOOKUP.width * inverse_scale
    local screen_h = RESOLUTION_LOOKUP.height * inverse_scale
    local columns = math.floor(screen_w / _grid_size)
    local grid_rows = math.floor(screen_h / _grid_size)

    if columns + grid_rows > MAX_GRID_LINES then
        return
    end

    local layer = 900

    for i = 0, columns do
        local x = i * _grid_size
        local color = (x == math.floor(screen_w / 2 / _grid_size) * _grid_size) and COLOR_GRID_CENTER or COLOR_GRID_LINE
        UIRenderer.draw_rect(ui_renderer, Vector3(x, 0, layer), Vector2(1, screen_h), color)
    end

    for i = 0, grid_rows do
        local y = i * _grid_size
        local color = (y == math.floor(screen_h / 2 / _grid_size) * _grid_size) and COLOR_GRID_CENTER or COLOR_GRID_LINE
        UIRenderer.draw_rect(ui_renderer, Vector3(0, y, layer), Vector2(screen_w, 1), color)
    end
end

function HudElementCustomizer:_draw_help_bar(ui_renderer)
    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local screen_w = RESOLUTION_LOOKUP.width * inverse_scale
    local screen_h = RESOLUTION_LOOKUP.height * inverse_scale
    local bar_h = 26 * inverse_scale
    local y = screen_h - bar_h
    local layer = 950

    UIRenderer.draw_rect(ui_renderer, Vector3(0, y, layer), Vector2(screen_w, bar_h), COLOR_HELP_BG)
    _safe_draw_text(ui_renderer,
        "HUD CUSTOMIZER    Drag: move    Arrows: nudge (Shift = x5)    Alt+Arrows / Scroll: resize    RMB: hide    Double-click: reset    Ctrl: invert snap    Keybind/Esc: close",
        13 * inverse_scale,
        Vector3(0, y, layer + 1),
        Vector2(screen_w, bar_h),
        COLOR_HELP_TEXT,
        "center", "center")
end

function HudElementCustomizer:_draw_panel(ui_renderer)
    if not _show_info_panel then
        return
    end

    local inverse_scale = self._inverse_scale or RESOLUTION_LOOKUP.inverse_scale
    local panel_w, panel_h, header_h, line_h, rows, footer_h = self:_panel_metrics()
    local px, py = self:_panel_xy()
    local all_node_names = self._all_node_names
    local total = #all_node_names
    local layer = 960
    local pad = 8 * inverse_scale

    UIRenderer.draw_rect(ui_renderer, Vector3(px, py, layer), Vector2(panel_w, panel_h), PANEL_BG_COLOR)
    UIRenderer.draw_rect(ui_renderer, Vector3(px, py, layer + 1), Vector2(panel_w, header_h), PANEL_HEADER_COLOR)

    _safe_draw_text(ui_renderer,
        string.format("HUD Elements (%d)   [drag here]", total),
        PANEL_FONT_SIZE * inverse_scale,
        Vector3(px + pad, py, layer + 2),
        Vector2(panel_w - pad * 2, header_h),
        PANEL_TEXT_COLOR,
        "left", "center")

    local scroll = self._panel_scroll_offset
    local max_scroll = math.max(total - rows, 0)
    if scroll > max_scroll then
        scroll = max_scroll
        self._panel_scroll_offset = max_scroll
    end

    for i = 1, rows do
        local index = i + scroll
        if index > total then
            break
        end

        local node_name = all_node_names[index]
        local row_y = py + header_h + (i - 1) * line_h
        local settings = self._saved_node_settings[node_name]
        local is_hidden = settings and settings.is_hidden
        local is_selected = self._selected_node == node_name
        local is_hovered = self._panel_hovered_index == index

        if is_selected or is_hovered then
            UIRenderer.draw_rect(ui_renderer,
                Vector3(px + 2 * inverse_scale, row_y, layer + 1),
                Vector2(panel_w - 4 * inverse_scale, line_h - inverse_scale),
                is_selected and PANEL_LINE_SELECTED_COLOR or PANEL_LINE_HOVER_COLOR)
        end

        _safe_draw_text(ui_renderer,
            short_node_name(node_name) .. (is_hidden and "  [hidden]" or ""),
            PANEL_FONT_SIZE_SMALL * inverse_scale,
            Vector3(px + pad, row_y, layer + 2),
            Vector2(panel_w - pad * 2, line_h),
            is_hidden and PANEL_TEXT_HIDDEN_COLOR or PANEL_TEXT_COLOR,
            "left", "center")
    end

    -- Footer: selected node details
    local selected = self._selected_node
    if selected and footer_h > 0 then
        local footer_y = py + header_h + rows * line_h
        local settings = self._saved_node_settings[selected]
        local ok_p, position = pcall(self.scenegraph_position, self, selected)
        local ok_s, size = pcall(self.scenegraph_size, self, selected)

        _safe_draw_text(ui_renderer,
            short_node_name(selected),
            PANEL_FONT_SIZE_SMALL * inverse_scale,
            Vector3(px + pad, footer_y, layer + 2),
            Vector2(panel_w - pad * 2, footer_h / 2),
            PANEL_TEXT_COLOR,
            "left", "center")

        _safe_draw_text(ui_renderer,
            string.format("x: %.0f   y: %.0f   size: %.0f x %.0f   scale: %.2f   hidden: %s",
                (ok_p and position and position[1]) or 0,
                (ok_p and position and position[2]) or 0,
                (ok_s and size and size[1]) or 0,
                (ok_s and size and size[2]) or 0,
                (settings and settings.scale) or 1,
                (settings and settings.is_hidden) and "yes" or "no"),
            PANEL_FONT_SIZE_SMALL * inverse_scale,
            Vector3(px + pad, footer_y + footer_h / 2, layer + 2),
            Vector2(panel_w - pad * 2, footer_h / 2),
            PANEL_TEXT_COLOR,
            "left", "center")
    end
end

return HudElementCustomizer
