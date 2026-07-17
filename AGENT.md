# AGENT.md — Darktide HUD Customizer Mod

Build specification for **HUDCustomizer**, a Warhammer 40,000: Darktide mod that lets the user press a customizable keybind to open an in-game editor which detects **all** HUD/UI elements active in the client's game process and reposition (drag/nudge), resize, and hide any of them, with settings persisted across sessions.

This document is the single source of truth for an agent building this mod. Every API, field name, and signature below was verified against the DMF source, the official docs, and the game source dump (July 2026). Do not guess APIs — if something is not in this document, check the references in §1 first.

---

## 1. Reference material

| Resource | URL | Use for |
|---|---|---|
| Darktide source code (Lua dump) | https://github.com/Aussiemon/Darktide-Source-Code | Ground truth for game classes. Fetch raw files: `https://raw.githubusercontent.com/Aussiemon/Darktide-Source-Code/master/<path>` |
| Darktide Mod Framework (DMF) | https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework | Framework source; modules under `dmf/scripts/mods/dmf/modules/` |
| DMF official docs | https://dmf-docs.darkti.de/#/ | docsify site; raw pages at `https://raw.githubusercontent.com/wiki/Darktide-Mod-Framework/Darktide-Mod-Framework/<page>.md` |
| Darktide Mod Loader | https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader | Install/patch chain, `mod_load_order.txt` |
| Darktide Mod Builder | https://github.com/Darktide-Mod-Framework/Darktide-Mod-Builder | Scaffolding templates (`.template-dmf/`) |
| Custom HUD by Fracticality | https://github.com/fracticality/darktide-mods/tree/master/custom_hud | **The reference implementation** — drag/snap HUD editor, ~2400 lines |
| HUD Tweaker by danreeves | https://github.com/danreeves/darktide-mods/tree/main/HUDTweaker | Minimal (203-line) enumerate-and-tweak pattern |
| CustomViewBoilerplate | https://github.com/ronvoluted/darktide-mods/tree/main/CustomViewBoilerplate | Custom view registration example (if a view is ever needed) |

Key game source files (paths relative to repo root):

- `scripts/ui/hud/elements/hud_element_base.lua` — `HudElementBase` (init, `set_scenegraph_position`, `_set_scenegraph_size`, `_widgets_by_name`, `_ui_scenegraph`)
- `scripts/managers/ui/ui_hud.lua` — `UIHud` (`init(elements, visibility_groups, params)`, `_elements`, `_elements_array`, `_element_definitions`, `_visibility_groups`, `element(name)`, `_setup_element`)
- `scripts/managers/ui/ui_manager.lua` — `Managers.ui` (`get_hud()`, `create_player_hud`, `destroy_player_hud`, `ui_constant_elements()`, `open_view`/`close_view`, `using_input()`, `allow_hud()`)
- `scripts/managers/ui/ui_scenegraph.lua` — `UIScenegraph` (`init_scenegraph`, `update_scenegraph`, `world_position`, `set_local_position`, `get_render_size`)
- `scripts/managers/ui/ui_widget.lua` — `UIWidget.create_definition(passes, scenegraph_id, ...)`, widget `offset`
- `scripts/ui/hud/hud_elements_player.lua` — the 29-element mission HUD definition list (also `_player_hub`, `_onboarding`, `hud_elements_spectator` variants)
- `scripts/ui/hud/hud_visibility_groups.lua` — ordered visibility groups (`disabled`, `in_view`, `dead`, `alive`, …; first match wins)
- `scripts/settings/ui/ui_hud_settings.lua` — `element_draw_layers` map
- `scripts/settings/ui/ui_workspace_settings.lua` — shared scenegraph roots (`screen` = `{ scale = "fit", size = {1920,1080}, position = {0,0,2} }`)
- `scripts/utilities/ui/hud.lua` — `Hud.hud_scale()`
- `scripts/managers/input/input_manager.lua` — `Managers.input:push_cursor/pop_cursor`

---

## 2. Core architecture decision (settled — do not relitigate)

The editor is **NOT a custom view**. It is a **HUD element** (`HudElementBase` subclass) injected by hooking `UIHud.init`, gated by a custom visibility group whose `validation_function` reads a mod flag. This is what both proven mods do, and for good reasons:

1. Opening a view sets `Managers.ui:allow_hud()` false → the entire HUD hides under the `in_view` visibility group — you'd be editing an invisible HUD. (A view *can* set `allow_hud = true`, but the element approach avoids the issue entirely.)
2. A HUD element receives `update(dt, t, ui_renderer, render_settings, input_service)` every frame — with cursor and click state — while gameplay keeps running.
3. Visibility groups gate **drawing only**, not `update()` — so the editor element can silently apply saved positions on the first frame after every HUD creation even while "closed".

The keybind uses DMF's `keybind_type = "function_call"` to toggle a `mod.is_customizing` flag; it does **not** use `view_toggle`.

---

## 3. Environment & mod structure

### 3.1 Loading chain

1. **Darktide Mod Loader** patches the game (`toggle_darktide_mods.bat`; re-run after every game update).
2. Mods live in `<game>/mods/<ModName>/` and load only if listed (one folder name per line) in `<game>/mods/mod_load_order.txt`. DMF (`dmf`) must be first.
3. In-game reload: Ctrl+Shift+R (requires "Developer Mode" in DMF Mod Options).
4. Settings persist to `%AppData%\Fatshark\Darktide\user_settings.config` (key `mods_settings`); logs to `%AppData%\Fatshark\Darktide\console_logs`.

### 3.2 File layout (naming convention is load-bearing — no extra subfolders between `.mod` and `scripts/`)

```
HUDCustomizer/
├── HUDCustomizer.mod
└── scripts/mods/HUDCustomizer/
    ├── HUDCustomizer.lua                 -- bootstrap: hooks, keybind handlers, recreate_hud
    ├── HUDCustomizer_data.lua            -- mod options: keybinds, grid/snap/opacity settings
    ├── HUDCustomizer_localization.lua    -- en strings (at minimum)
    └── hud_element_customizer.lua        -- the editor: HudElementBase subclass (the bulk of the mod)
```

### 3.3 `HUDCustomizer.mod` (exact format)

```lua
return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`HUDCustomizer` encountered an error loading the Darktide Mod Framework.")

		new_mod("HUDCustomizer", {
			mod_script       = "HUDCustomizer/scripts/mods/HUDCustomizer/HUDCustomizer",
			mod_data         = "HUDCustomizer/scripts/mods/HUDCustomizer/HUDCustomizer_data",
			mod_localization = "HUDCustomizer/scripts/mods/HUDCustomizer/HUDCustomizer_localization",
		})
	end,
	packages = {},
}
```

Paths are relative to the `mods` folder, no `.lua` extension. Load order inside `new_mod`: localization → data → script (so `mod:localize` works inside `_data.lua`).

---

## 4. DMF API reference (the subset this mod needs)

### 4.1 Hooks

```lua
mod:hook(obj, method, handler)        -- handler(func, ...) — func is next-in-chain; call it (or don't)
mod:hook_safe(obj, method, handler)   -- handler(...) — runs AFTER original; errors caught, not propagated
mod:hook_origin(obj, method, handler) -- replaces original; ONE origin hook per function across ALL mods — avoid
mod:hook_require(path, callback)      -- callback(instance) for every past/future require() of a game file
mod:hook_enable(obj, method) / mod:hook_disable(obj, method)
mod:add_require_path(path)            -- lets game code require() a file inside the mod folder
mod:original_require(path, ...)       -- require a game file bypassing DMF's require hook
```

- `obj` may be a class table (`CLASS.UIHud`) or a string (`"UIHud"`) — string targets are auto-deferred until the class exists. Use strings for game classes.
- One hook per (mod, function). Regular `mod:hook` errors **crash the game** — keep handlers defensive.
- Hooks of a togglable mod are auto-disabled when the user disables the mod.

### 4.2 Settings

```lua
mod:get(setting_id)                 -- CLONES tables on every call — cache reads!
mod:set(setting_id, value, notify)  -- notify=true fires mod.on_setting_changed(setting_id)
```

Values must be SJSON-serializable: nil/number/string/boolean, and tables that are **either** array-like **or** string-keyed maps — never mixed at the same level (mixed tables throw "number expected, got string" at save time). Not flushed immediately — flushed on game-state change, mod reload, or closing the options menu.

### 4.3 Lifecycle callbacks (fields on the mod object; run even when mod disabled — check `mod:is_enabled()`)

```lua
mod.update = function(dt) end
mod.on_all_mods_loaded = function() end
mod.on_setting_changed = function(setting_id) end
mod.on_enabled  = function(initial_call) end
mod.on_disabled = function(initial_call) end
mod.on_game_state_changed = function(status, state_name) end  -- status "enter"/"exit"; "StateGameplay" etc.
mod.on_unload = function(exit_game) end
```

### 4.4 Logging / misc

```lua
mod:notify(msg, ...)   mod:echo(msg, ...)   mod:error(msg, ...)   mod:info(msg, ...)
mod:localize(text_id, ...)
mod:persistent_table(name, default)   -- survives Ctrl+Shift+R reload (not across sessions)
mod:dump(obj, name, max_depth)        -- debug: dump a table to the log
mod:io_dofile(path)                   -- execute a bundled file (pcall-wrapped), return its result
mod:command(name, description, fn)    -- chat command /name
```

### 4.5 Keybind widget (in `_data.lua` → `options.widgets`)

```lua
{
	setting_id      = "toggle_editor_keybind",
	type            = "keybind",
	default_value   = {},               -- SHIP UNBOUND; user assigns in Mod Options. Stored as {"f3"} or {"g","left ctrl"}
	keybind_trigger = "pressed",        -- "pressed" | "held" ("held" calls fn(true) on press, fn(false) on release)
	keybind_type    = "function_call",
	function_name   = "toggle_hud_editor",  -- DMF calls mod.toggle_hud_editor()
},
```

Other widget types available: `checkbox` (`default_value` boolean, may have `sub_widgets`), `group` (`sub_widgets` only), `dropdown` (`options = {{text=loc_id, value=v}, ...}`, ≥2 options, unique values), `numeric` (`range = {min,max}` required, optional `decimals_number`, `unit_text`). Each widget's `setting_id` doubles as its title localization key; tooltip key is `setting_id .. "_description"`. Note: conditional show/hide of sub_widgets is **not implemented** in DMF — only grouping/collapsing works.

---

## 5. Game HUD architecture (what the editor manipulates)

### 5.1 Object graph at runtime

```
Managers.ui                              (UIManager)
├── :get_hud()  →  UIHud instance        (mission/hub HUD; nil outside gameplay)
│   ├── _element_definitions             array of def tables {class_name, filename, visibility_groups, use_hud_scale, use_retained_mode, package?, validation_function?}
│   ├── _elements                        map class_name → element instance
│   ├── _elements_array                  array of element instances
│   ├── _elements_hud_scale_lookup       map class_name → bool (uses HUD-scale option)
│   ├── _visibility_groups               array {name, validation_function(hud), visible_elements = {class_name=true}}
│   ├── :element(class_name)             public getter
│   └── :_setup_element(definition)      instantiation entry point (used by DMF injection)
└── :ui_constant_elements()              always-alive elements (chat, notifications, crosshair-adjacent, subtitles)
    └── same _visibility_groups shape; instance lookup via :element(name)
```

Every element instance (`HudElementBase` subclass):

- `element.__class_name` — exact class name string (e.g. `"HudElementPlayerBuffs"`)
- `element._ui_scenegraph` — **per-element** live scenegraph (strict table — probing unknown keys errors; use `rawget` or iterate `hierarchical_scenegraph`)
- `element._ui_scenegraph.hierarchical_scenegraph` — array of root nodes; each root has `children` array; each node: `name`, `position {x,y,z}` (aliased as `local_position`), `world_position`, `size {w,h}`, `horizontal_alignment`, `vertical_alignment`, `parent`
- `element._definitions.scenegraph_definition` — the original (plain, non-strict) definition table → source of node names AND pristine default values for reset snapshots
- `element._widgets_by_name` — map widget name → widget (`widget.style`, `widget.content`, `widget.offset {x,y,z}`, `widget.dirty`)
- `element._draw_layer`, `element._parent` (the UIHud)

### 5.2 The repositioning API (this is the entire trick)

```lua
-- scripts/ui/hud/elements/hud_element_base.lua — verbatim from game source:
HudElementBase.set_scenegraph_position = function (self, id, x, y, z, horizontal_alignment, vertical_alignment)
	local scenegraph = self._ui_scenegraph[id]
	scenegraph.horizontal_alignment = horizontal_alignment or scenegraph.horizontal_alignment
	scenegraph.vertical_alignment = vertical_alignment or scenegraph.vertical_alignment
	local position = scenegraph.position
	if x then position[1] = x end
	if y then position[2] = y end
	if z then position[3] = z end
	self._update_scenegraph = true    -- UIScenegraph.update_scenegraph runs next element update
end
```

Also available: `element:_set_scenegraph_size(id, w, h)`, `element:scenegraph_position(id)`, `element:scenegraph_size(id, scale)`, `element:scenegraph_world_position(id, scale)`, `element:set_visible(visible, ui_renderer, use_retained_mode)`, `element:set_dirty()`.

**Rules:**
- Always call through `pcall` — some handler elements override `set_scenegraph_position` and forward to nested sub-elements (e.g. `HudElementPlayerWeaponHandler`), and patches change internals.
- Always pass `"left", "top"` as the alignments when applying saved positions, so stored absolute coordinates are stable regardless of the node's original center/right anchoring. Convert the node's current world position to left/top-space before first save.
- All coordinates are in **1920×1080 virtual UI units**. Convert mouse deltas from screen pixels: multiply by `render_settings.inverse_scale` (fallback `RESOLUTION_LOOKUP.inverse_scale`).
- Elements with `use_hud_scale = true` render under `Hud.hud_scale()` (= `RESOLUTION_LOOKUP.scale * interface_settings.hud_scale/100` from `Managers.save:account_data().interface_settings`); constant elements do not. When editing constant elements from a hud-scaled editor element, divide/multiply by `hud_scale/100` (see Custom HUD's `_get_inverse_hud_scale()`).
- Retained-mode elements (TeamPanelHandler, PlayerAbilityHandler, PlayerWeaponHandler, Overcharge, PlayerBuffs) cache draws — moving them is fine because `_update_scenegraph` triggers `set_dirty()`, but if you mutate widgets directly, set `widget.dirty = true`.

### 5.3 Visibility groups (why the HUD "disappears" and how the editor stays visible)

`scripts/ui/hud/hud_visibility_groups.lua` is an **ordered** list; each frame the first group whose `validation_function(hud)` returns true wins, and only elements listing that group in their `visibility_groups` are drawn. Order includes: `disabled`, `popup`, `cutscene`, `in_view` (any open view without `allow_hud`), `communication_wheel`, `tactical_overlay`, `dead`, `alive` (the default), `onboarding`.

The mod inserts its own groups at the front (see §6.2) so that while editing, ONLY the editor draws its overlay on top and the normal HUD stays visible underneath (the editor group's `validation_function` returns false → next matching group, normally `alive`, still governs the real HUD — the editor element simply lists BOTH `custom_hud` and `alive`… **no**: follow Custom HUD exactly — editor element lists only `"hud_customizer"` group; group inserted at index 1 with `validation_function = function() return mod.is_customizing end`. When that group wins, elements not listing it hide. To keep the real HUD visible while editing, ALSO add every other element's class_name into the group's `visible_elements` — `UIHud._verify_elements` fills `visible_elements` from each element's `visibility_groups` list, so the simplest correct approach, proven by Custom HUD, is: the editor draws **proxy rectangles** for each node and the real HUD hides while the editor is open. Positions apply live to proxies; the real HUD reflects them when the editor closes. Alternatively append `"hud_customizer"` to each definition's `visibility_groups` inside the `UIHud.init` hook to keep the real HUD rendered during editing — both work; pick one and document it in code.)

### 5.4 HUD lifecycle

- Created per mission/hub by `HumanGameplay._create_player_hud` → `Managers.ui:create_player_hud(peer_id, local_player_id, elements, visibility_groups)`; element list file varies by mission template (`hud_elements_player`, `_player_hub`, `_onboarding`).
- Destroyed/recreated on mission transitions. **Saved positions must be re-applied after every creation** — do it in the editor element's first `update()` tick, not just once.
- `Managers.event:trigger("event_player_hud_created")` / `"event_on_hud_created"` fire on creation (usable via `Managers.event:register`).
- Force-applying settings mid-session = recreate the HUD (verbatim proven pattern):

```lua
local function recreate_hud()
	local ui_manager = Managers.ui
	local hud = ui_manager._hud
	if hud then
		local player = Managers.player:local_player(1)
		local elements = hud._element_definitions
		local visibility_groups = hud._visibility_groups
		ui_manager:destroy_player_hud()
		ui_manager:create_player_hud(player:peer_id(), player:local_player_id(), elements, visibility_groups)
	end
end
```

---

## 6. Implementation plan

### Phase 1 — Bootstrap (`HUDCustomizer.lua`)

```lua
local mod = get_mod("HUDCustomizer")

mod.is_customizing = false
mod.is_hud_hidden = false

local customizer_path = "HUDCustomizer/scripts/mods/HUDCustomizer/hud_element_customizer"
mod:add_require_path(customizer_path)

mod:hook("UIHud", "init", function(func, self, elements, visibility_groups, params)
	if not table.find_by_key(elements, "class_name", "HudElementCustomizer") then
		table.insert(elements, {
			class_name = "HudElementCustomizer",
			filename = customizer_path,
			use_hud_scale = true,
			visibility_groups = { "hud_customizer" },
		})
	end
	table.insert(visibility_groups, 1, {
		name = "hud_customizer",
		validation_function = function(hud) return mod.is_customizing end,
	})
	return func(self, elements, visibility_groups, params)
end)

function mod.toggle_hud_editor()
	-- refuse while a menu/view is consuming input
	if Managers.ui and Managers.ui:using_input() and not mod.is_customizing then
		return
	end
	mod.is_customizing = not mod.is_customizing
end

function mod.on_all_mods_loaded()
	-- HUD may already exist (mod reload mid-mission) — recreate so injection applies
	recreate_hud()
end

-- Exit edit mode if any view opens (esc menu, inventory, …)
mod:hook_safe("UIViewHandler", "open_view", function()
	if mod.is_customizing then mod.is_customizing = false end
end)
```

Notes:
- Hooking `UIHud.init` (rather than `mod:register_hud_element`) is deliberate: it is the only way to also inject the custom **visibility group**.
- `mod:hook` with string `"UIHud"` defers automatically until the class exists.
- Guard against double-insertion (hot-reload) as shown.

### Phase 2 — Enumeration (`hud_element_customizer.lua`, in `_setup_elements`)

Collect **all** movable nodes from both HUD systems:

```lua
-- 1) Mission/hub HUD elements: via parent UIHud
local target_names = {}
for _, group in ipairs(self._parent._visibility_groups) do
	for class_name in pairs(group.visible_elements or {}) do
		target_names[class_name] = true
	end
end
-- 2) Constant elements (chat, notifications, subtitles — alive in menus too)
local constant_elements = Managers.ui:ui_constant_elements()
for _, group in ipairs(constant_elements._visibility_groups) do
	if group.name == "default" then
		for class_name in pairs(group.visible_elements or {}) do
			target_names[class_name] = true
		end
	end
end

-- Resolve instances and walk each element's scenegraph roots' children:
local element = self._parent:element(class_name) or constant_elements:element(class_name)
local hsg = element._ui_scenegraph and element._ui_scenegraph.hierarchical_scenegraph or {}
for _, root in ipairs(hsg) do
	for _, child in ipairs(root.children or {}) do
		local node_key = string.format("%s|%s", class_name, child.name)   -- addressable unit
		local world_pos = child.world_position or child.position or {0,0,0}
		local size = child.size or {25, 25}
		-- register node_key → {element, scenegraph_id = child.name, pos, size, defaults…}
	end
end
```

- The addressable/movable unit is a **top-level scenegraph child node**, keyed `"ClassName|scenegraph_id"`. This is what "detects ALL UI present on the client" means in practice: every drawn HUD widget hangs off one of these nodes.
- Maintain an **exclusion list** (start from Custom HUD's): `HudElementCustomizer` itself, `HudElementWorldMarkers`, `HudElementDamageIndicator`, `HudElementCrosshair` (world/center-locked or 3D-projected elements that break when moved), `ConstantElementPopupHandler`, and per-element scenegraph exclusions for `HudElementPlayerWeaponHandler` slot nodes. Make the exclusion list a table at the top of the file with a comment explaining each entry.
- Handler elements (`*Handler`) contain nested sub-elements with their own scenegraphs; v1 treats the handler's own nodes as the unit. Recursing into sub-elements is a v2 feature.

### Phase 3 — Editor element skeleton

```lua
local UIWorkspaceSettings = require("scripts/settings/ui/ui_workspace_settings")
local UIWidget = require("scripts/managers/ui/ui_widget")
local UIRenderer = require("scripts/managers/ui/ui_renderer")

local Definitions = {
	scenegraph_definition = {
		screen = UIWorkspaceSettings.screen,
	},
	widget_definitions = {},
}

HudElementCustomizer = class("HudElementCustomizer", "HudElementBase")

function HudElementCustomizer:init(parent, draw_layer, start_scale)
	HudElementCustomizer.super.init(self, parent, draw_layer, start_scale, Definitions)
	self._setup_complete = false
end

function HudElementCustomizer:update(dt, t, ui_renderer, render_settings, input_service)
	HudElementCustomizer.super.update(self, dt, t, ui_renderer, render_settings, input_service)
	if not self._setup_complete then
		self:_setup_elements()               -- enumerate + apply saved settings (Phase 5)
		self._setup_complete = true
	end
	local mod = get_mod("HUDCustomizer")
	if mod.is_customizing then
		self:_activate_mouse_cursor()
		self:_handle_input(input_service, render_settings, dt, t)
	elseif self._using_cursor then
		self:_deactivate_mouse_cursor()
	end
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

function HudElementCustomizer:destroy(ui_renderer)
	self:_deactivate_mouse_cursor()
	HudElementCustomizer.super.destroy(self, ui_renderer)
end

return HudElementCustomizer
```

Critical: track cursor push state yourself (`_cursor_pushed`) — imbalanced `pop_cursor` calls break the cursor stack game-wide (this is an explicit bug-fix pattern in Custom HUD). Pop in `destroy` and on editor close.

For each enumerated node, build a **proxy widget** in the editor's own scenegraph:

- Add `self._definitions.scenegraph_definition[node_key] = { parent = "screen", size = size, position = world_pos, horizontal_alignment = "left", vertical_alignment = "top" }`, then rebuild: `self._ui_scenegraph = self:_create_scenegraph(self._definitions, scale)` and `self:_create_widgets(self._definitions, self._widgets, self._widgets_by_name)`.
- Proxy widget passes (`UIWidget.create_definition({...}, node_key)`):
  - `hotspot` pass — `content.hotspot` gains `is_hover`, `on_pressed`, `is_held`; wire `pressed_callback = callback(self, "_on_widget_pressed", node_key)`
  - `rect` pass — translucent fill + border, color driven by a `change_function` reading `content.hotspot.is_hover` / selection state
  - `text` pass — node label, plus an `x,y  w×h` readout with `visibility_function = function(content) return content.hotspot.is_selected end`
- Overlapping widgets: callbacks only push `node_key` onto `self._widget_press_stack`; a per-frame `_handle_widget_presses()` picks the winner by highest z. Do not act inside the callback itself.

### Phase 4 — Input handling (inside `_handle_input`)

Read everything from the `input_service` parameter (the HUD's input service) and the raw `Keyboard` global for modifiers:

| Action | Input |
|---|---|
| Cursor position | `input_service:get("cursor")` → Vector3; convert via `Vector3.to_array`, multiply deltas by `render_settings.inverse_scale` |
| Drag | `input_service:get("left_hold")` — record `_cursor_start_position` on first frame, compute delta each frame |
| Select | hotspot `pressed_callback` (via press stack, §Phase 3) |
| Scale (v2) | `input_service:get("scroll_axis")` — ±0.05 per notch, resize node = original_size × scale |
| Keyboard nudge | `input_service:get("navigation_keys_virtual_axis")` (arrow keys) |
| Reset node | double-click hotspot (`double_click_callback`) |
| Modifiers | `Keyboard.button(Keyboard.button_index("left shift")) > 0.5` — pcall-probe `button_index` once, cache result |

Drag application: update the **proxy** node live via `self:set_scenegraph_position(node_key, x, y)`; write through to the **real** element via `pcall(element.set_scenegraph_position, element, scenegraph_id, x, y, nil, "left", "top")` either live each frame (feels better) or on release (safer) — start with on-release, promote to live once stable.

Optional (v2): grid snapping (precompute grid line positions; snap when within threshold px; Ctrl inverts snap), element-edge snapping (compare dragged edges vs all other nodes within 10px), Alt+drag edge = resize.

### Phase 5 — Persistence

Single setting, map-of-maps (SJSON-safe — string keys at top level, arrays inside):

```lua
mod:set("saved_node_settings", {
	["HudElementPlayerBuffs|buff_info_box"] = {
		x = 10.33, y = 566.67, z = 2,
		position = { 10.33, 566.67, 2 },
		size = { 833.33, 416.67 },
		is_hidden = false,
		default_settings = {              -- snapshot for reset, taken on FIRST modification
			horizontal_alignment = "left", vertical_alignment = "bottom",
			position = { 50, -490, 0 }, size = { 500, 250 },
		},
	},
})
```

- Snapshot `default_settings` from `element._definitions.scenegraph_definition[scenegraph_id]` (falling back to the live child node) **before** the first modification — that's the reset target.
- Persist (`mod:set`) after every completed interaction (drag release, hide toggle, reset). Cache the read (`mod:get` clones tables every call) in a local; refresh in `mod.on_setting_changed`.
- Apply in `_setup_elements` after enumeration: loop saved table → resolve element → `pcall(set_scenegraph_position …, "left", "top")` → apply `is_hidden` via `element:set_visible(false, ui_renderer, use_retained_mode)` + an `_is_hidden` flag enforced by a per-element `draw` hook:

```lua
mod:hook(element, "draw", function(func, elem, ...)
	if elem._is_hidden then return end
	return func(elem, ...)
end)
```

- **Prune stale entries**: if a saved `ClassName|scenegraph_id` no longer resolves (game patch renamed nodes), delete it from the saved table and `mod:info` about it. This is the patch-resilience mechanism.

### Phase 6 — Mod options (`HUDCustomizer_data.lua`)

```lua
local mod = get_mod("HUDCustomizer")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "toggle_editor_keybind",
				type = "keybind",
				default_value = {},
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_hud_editor",
			},
			{
				setting_id = "hide_hud_keybind",
				type = "keybind",
				default_value = {},
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "toggle_hud_visibility",
			},
			{
				setting_id = "grid_snap_enabled",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{ setting_id = "grid_size", type = "numeric", default_value = 20, range = {5, 100} },
				},
			},
		},
	},
}
```

Every `setting_id` needs an entry in `HUDCustomizer_localization.lua`:

```lua
return {
	mod_name = { en = "HUD Customizer" },
	mod_description = { en = "Reposition, resize, and hide any HUD element. Bind a key in Mod Options, press it in-game, drag things around." },
	toggle_editor_keybind = { en = "Open HUD Editor" },
	hide_hud_keybind = { en = "Toggle HUD Visibility" },
	grid_snap_enabled = { en = "Grid Snapping" },
	grid_snap_enabled_description = { en = "Snap dragged elements to a grid." },
	grid_size = { en = "Grid Size" },
	-- …
}
```

### Phase 7 — Reset & polish

- "Reset node" (double-click) restores from `default_settings` and removes the saved entry.
- Chat command `/hudcustomizer_reset` → wipe `saved_node_settings`, `recreate_hud()`, notify.
- `recreate_hud()` after DMF options view closes (`mod:hook_safe("UIViewHandler", "close_view", …)` checking for `dmf_options_view`) so option changes apply.
- On `mod.on_disabled`: restore all elements (recreate_hud is sufficient since hooks are auto-disabled).
- Editor on-screen help text (immediate-mode `UIRenderer.draw_text` in the element's `draw`) listing controls.

---

## 7. Pitfalls & gotchas (each of these has bitten a real mod)

1. **`mod:get` clones tables on every call.** Cache in locals; refresh via `on_setting_changed`.
2. **Mixed tables crash the settings save.** Never mix array and string keys in one table level.
3. **Strict scenegraph tables.** `element._ui_scenegraph` errors on unknown-key reads — use `rawget` or iterate `hierarchical_scenegraph`. `element._definitions.scenegraph_definition` is a plain table — probe that instead.
4. **Cursor stack.** Track your own push state; always pop in `destroy` and on close. Never pop unpushed.
5. **Regular `mod:hook` errors crash the game.** All manipulation of foreign elements goes through `pcall`.
6. **Unloaded texture packages render as white rectangles.** The editor should use only `rect`/`text`/`hotspot` passes (no game textures) to avoid package loading entirely. If a texture is ever needed: `Managers.package:load("packages/ui/...", mod.name, nil, true)`.
7. **HUD is recreated on every mission/hub transition.** Re-apply saved settings in the element's first `update()`, every time. `mod:persistent_table` survives Ctrl+Shift+R but NOT sessions — persistence must go through `mod:set`.
8. **Coordinate spaces.** Screen pixels ≠ UI units (×`inverse_scale`); HUD-scaled elements ≠ constant elements (÷`hud_scale/100`). Get this wrong and drags "drift".
9. **`mod:is_enabled()` returns true during mod load** even for disabled mods; lifecycle callbacks fire even when disabled.
10. **Don't ship default keybinds** (`default_value = {}`) — collisions with other mods are unchecked; all mods bound to the same key fire.
11. **UIHud may not exist** (main menu, loading): `Managers.ui:get_hud()` is nil — guard everything.
12. **Views steal input**: refuse to open the editor while `Managers.ui:using_input()`; force-close the editor when any view opens.
13. **One `hook_origin` per function game-wide** — never use it here; everything is `hook`/`hook_safe`.
14. **After a game update** the loader must be re-patched (`toggle_darktide_mods.bat`) and node names may change — the pruning logic in Phase 5 handles renames gracefully.
15. **Debug tool**: `UIRenderer.debug_render_scenegraph(self, ui_scenegraph)` inside a `hook_safe` on `UIRenderer.begin_pass` overlays all scenegraph node names/positions — invaluable during development. `mod:dump(element._definitions, name, 3)` dumps definitions to the log.

---

## 8. Testing checklist

Manual (no automated test harness exists for Darktide mods):

1. Install: symlink/copy `HUDCustomizer/` into `<game>/mods/`, add `HUDCustomizer` to `mod_load_order.txt` after `dmf`.
2. Mod loads with no log errors (`console_logs`); appears in Mod Options; keybind assignable.
3. In the **Psykhanium** (Meat Grinder — safest test env): press keybind → overlay appears, cursor visible, gameplay input suppressed for camera but game keeps running.
4. Every expected element shows a proxy box (compare against the 29-element list + constant elements). Elements on the exclusion list do not.
5. Drag a node → real element moves; release; reload UI (Ctrl+Shift+R) → position persists; restart game → position persists; start a mission → position persists.
6. Reset (double-click) restores original position; `/hudcustomizer_reset` restores everything.
7. Open ESC menu / inventory while editing → editor force-closes, cursor restored, no stuck cursor.
8. Disable mod in Mod Options → HUD returns to fully vanilla layout.
9. Test at a non-1080p resolution and with HUD Scale ≠ 100% → drags track the cursor 1:1, saved positions land identically after restart.
10. Hub AND mission HUDs both work (different element lists).
11. Die in-game while editor open; spectate; use tactical overlay — no crashes, visibility groups behave.

---

## 9. Deliverables & publishing

- The mod folder as laid out in §3.2, committed to this repo.
- README.md for users: installation (DML + DMF prerequisite, `mod_load_order.txt`), controls table, FAQ (white boxes = report it; positions reset after patch = expected for renamed nodes).
- Optional: package as a zip with the folder at the correct relative root for Nexus Mods upload.
