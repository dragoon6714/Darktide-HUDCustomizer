# HUD Customizer — MVP Plan

Agent-facing working plan for a Warhammer 40,000: Darktide HUD-repositioning mod. Every API
name in this document was verified (2026-07-17) directly against:

- **DMF source** — [Darktide-Mod-Framework](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework) (branch `master`) + [docs](https://dmf-docs.darkti.de/#/)
- **Game source** — [Aussiemon/Darktide-Source-Code](https://github.com/Aussiemon/Darktide-Source-Code) (decompiled live game, branch `master`)
- **Reference mods** — [Custom HUD](https://github.com/fracticality/darktide-mods/tree/master/custom_hud) (Fracticality), [HUD Tweaker](https://github.com/danreeves/darktide-mods/tree/main/HUDTweaker) (danreeves), plus `crosshair_hud`, `NumericUI`, and DMF's own `custom_hud_elements.lua`

File paths cited as `game:` refer to the game source repo; `dmf:` to the DMF repo.

## 1. Goal

1. Player binds a key in Mod Options that toggles an in-game **HUD editor**.
2. In the editor, the player **selects** a client-side HUD element by clicking it.
3. The selected element can be **dragged freely**; the move applies live.
4. Positions **persist to disk** and survive game restarts; persistence is purely local
   (Darktide's own `user_settings.config`), so it works offline by construction.

## 2. MVP scope

**In** — keybind toggle (unbound by default); draggable proxy box per movable HUD node;
click-select + drag; live position updates; persistence + re-application on every HUD build;
`/hudcustomizer_reset` chat command; exclusion list for elements that break when moved.

**Out (backlog)** — resize/scale, hide/show, grid & magnetic snapping, arrow-key nudge,
element list panel, constant-elements support (chat, notifications), whole-HUD-hide keybind,
per-widget style editing (HUD Tweaker's approach).

## 3. Verified technical foundation

Facts the design rests on — do not re-derive these, they are confirmed from source:

- **HUD structure**: `UIHud` (`game: scripts/managers/ui/ui_hud.lua`) holds `_elements`
  (by class name), `_elements_array`, `_element_definitions`, `_visibility_groups`. Elements
  are `class("HudElementX", "HudElementBase")` instances created via
  `class:new(self, draw_layer, hud_scale, optional_context)` from entries
  `{ class_name, filename, visibility_groups, use_hud_scale, ... }`. Public accessor:
  `hud:element(class_name)`.
- **Element geometry**: each element owns `_ui_scenegraph`
  (`UIScenegraph.init_scenegraph(definitions.scenegraph_definition, start_scale)`), virtual
  1920×1080 coordinate space, nodes with `position`, `size`,
  `horizontal_alignment` (`"center"`/`"right"`, default left) and `vertical_alignment`
  (`"center"`/`"bottom"`, default top). Walk `element._ui_scenegraph.hierarchical_scenegraph`
  → `.children` for `name` / `world_position` / `size` (Custom HUD's proven discovery path).
- **The move API**: `HudElementBase:set_scenegraph_position(id, x, y, z, h_align, v_align)`
  (`game: scripts/ui/hud/elements/hud_element_base.lua`) — writes the node position and sets
  `_update_scenegraph = true`, so the element's next `update()` re-runs
  `UIScenegraph.update_scenegraph` and dirties widgets. Read side:
  `element:scenegraph_position(id)`, `element:scenegraph_world_position(id, scale)`,
  `element:scenegraph_size(id, scale)`.
- **Scale**: `RESOLUTION_LOOKUP.scale` globally; `Hud.hud_scale()`
  (`game: scripts/utilities/ui/hud.lua`) for elements with `use_hud_scale = true`. Cursor axis
  is physical pixels — multiply by `inverse_scale` to get virtual coords.
- **Input during gameplay**: DMF has **no** cursor utilities (verified: zero hits for
  cursor/imgui in repo). The working pattern: the editor itself is a HUD element, so it
  receives a live `input_service` in
  `update(dt, t, ui_renderer, render_settings, input_service)`. Actions:
  `input_service:get("cursor")` (Vector3), `"left_pressed"`, `"left_hold"`, `"left_released"`.
  Cursor visibility: `Managers.input:push_cursor(ref)` / `pop_cursor(ref)`
  (`game: scripts/managers/input/input_manager.lua`). Gameplay input suppression is automatic:
  `HumanGameplay._input_active()` nulls gameplay input when `Managers.ui:using_input()` is
  true, which chains down to `hud:using_input()` → any element whose `using_input()` returns
  true. So the editor element returns `true` from `using_input()` while active — no hooks
  needed for input blocking.
- **Element injection**: DMF provides `mod:register_hud_element({ class_name, filename,
  visibility_groups, use_hud_scale, use_retained_mode, validation_function })`
  (`dmf: .../modules/gui/custom_hud_elements.lua`) — injects after `UIHud._setup_elements`
  via hook, removes cleanly on `UIHud.destroy` and on mod disable. Use this, not a manual
  `UIHud.init` hook.
- **Persistence**: `mod:set(id, value, notify)` / `mod:get(id)` store non-mixed Lua tables,
  namespaced per mod under `Application.user_setting("mods_settings")`, on disk at
  `%AppData%\Fatshark\Darktide\user_settings.config`. **Flush is deferred**: written to disk
  on game-state change, mod unload/reload, and Mod Options close — not on every `mod:set`.
  That covers quit-to-desktop (unload fires) and mission transitions; acceptable for MVP.
- **Keybind**: options widget `{ setting_id, type = "keybind", default_value = {},
  keybind_trigger = "pressed", keybind_type = "function_call", function_name = "..." }`
  (`dmf: .../modules/core/options.lua`, values `pressed|held`,
  `function_call|view_toggle|mod_toggle`). DMF calls `mod[function_name](is_pressed)`.
- **HUD lifecycle**: HUD is destroyed/recreated per state transition (hub ↔ mission,
  spectate) by `HumanGameplay._create_player_hud` → `UIManager:create_player_hud`. Element
  lists differ per context (`game: scripts/ui/hud/hud_elements_player.lua`, `_player_hub`,
  `_spectator`). Consequence: **all offset application must run per HUD build**, never
  one-shot at mod load.
- **Dev loop**: enable Developer Mode in DMF options → **Ctrl+Shift+R** reloads mods
  in-game. Set `allow_rehooking = true` in mod_data during development.

## 4. Mod layout

```
HUDCustomizer/
├── HUDCustomizer.mod                     -- new_mod() entry (DMF template format)
└── scripts/mods/HUDCustomizer/
    ├── HUDCustomizer.lua                 -- get_mod, keybind fn, command, hooks, lifecycle
    ├── HUDCustomizer_data.lua            -- options: keybind widget; is_togglable = true
    ├── HUDCustomizer_localization.lua    -- en strings
    └── hud_element_editor.lua            -- class("HudElementHudCustomizer", "HudElementBase")
                                          --   discovery, proxies, drag, apply, persistence
```

`.mod` file follows the Darktide-Mod-Builder template exactly (`new_mod("HUDCustomizer",
{ mod_script = ..., mod_data = ..., mod_localization = ... })`). The editor element file is
exposed with `mod:add_require_path("HUDCustomizer/scripts/mods/HUDCustomizer/hud_element_editor")`
and registered with `mod:register_hud_element{ class_name = "HudElementHudCustomizer",
filename = <that path>, use_hud_scale = false, visibility_groups = { "alive" } }`.
(If `"alive"` proves absent in some context's visibility-group file, fall back to Custom HUD's
pattern: hook `UIHud.init`, insert an own group gated on `mod._editor_active`.)

## 5. Core systems

### 5.1 Toggle (in `HUDCustomizer.lua`)
- Keybind widget → `function mod.toggle_editor() ... end` flips `mod._editor_active`.
- Guards: no HUD (`Managers.ui and Managers.ui._hud`), a view already using input
  (`Managers.ui._view_handler:using_input()` — Custom HUD's guard) → refuse to open.
- Force-close on menu open: `mod:hook_safe("UIViewHandler", "open_view", ...)`.
- `mod.on_disabled` / `mod.on_unload` → force-close (cursor release, save).

### 5.2 Editor element (`hud_element_editor.lua`)
- **Discovery** (in `init`, i.e. once per HUD build): iterate the parent hud's elements;
  for each element not excluded, walk `_ui_scenegraph.hierarchical_scenegraph` children;
  register one movable node per top-level child, keyed `"<ElementName>|<node_name>"`
  (Custom HUD's stable key format). Snapshot each node's default `position` + alignments
  (for delta math and reset).
- **Proxies**: for each node, add a scenegraph node + one widget
  (`UIWidget.create_definition` with a `hotspot` pass for click callbacks, `rect` passes for
  fill/border) to the editor's own definitions, then rebuild via `self:_create_scenegraph` /
  `self:_create_widgets`. Hotspot passes give engine-side hit-testing for free; resolve
  overlapping presses by highest layer (Custom HUD's `_widget_press_stack` pattern).
- **Activation**: `set_active(true)` → `Managers.input:push_cursor(self.__class_name)` with an
  own `_cursor_pushed` flag; `using_input()` returns active state (this alone blocks gameplay
  input, §3). `set_active(false)` and `destroy()` both pop the cursor **only if
  `_cursor_pushed`** — imbalanced pops are a known footgun Custom HUD explicitly fixed.
- **Drag loop** (in `update`, only while active): `input_service:get("cursor")` ×
  `render_settings.inverse_scale` → virtual coords; on `left_pressed` over a proxy → select;
  while `left_hold` → accumulate delta into the node's offset and apply live; on
  `left_released` → commit + save. Draw nothing / skip all logic when inactive.

### 5.3 Applying offsets
- Store **deltas** `{dx, dy}` from the snapshotted default position, preserving the node's
  authored alignment (keeps right/bottom-anchored elements sane across aspect ratios —
  deliberate improvement over Custom HUD's convert-to-absolute-left/top approach).
- Apply = `pcall(element.set_scenegraph_position, element, node_name, def_x + dx, def_y + dy,
  def_z, nil, nil)` — pcall'd because game patches change signatures (Custom HUD pcalls this
  exact call for the same reason).
- Applied at three moments: editor element `init` (covers every HUD build: load, hub↔mission,
  spectate, reload), live during drag, and on editor close.

### 5.4 Persistence
- One settings key: `mod:set("layout", { version = 1, nodes = { ["Element|node"] = { dx, dy } } })`.
  Arrays-or-maps only — DMF rejects mixed tables. Clone-on-get is slow → cache the table in
  the mod, write through on change.
- Save on drag-release and editor close. Disk flush rides DMF's flush points (§3).
- **Prune**: at apply time, if `rawget(element._ui_scenegraph, node_name) == nil` or the
  element no longer exists, drop the entry, log via `mod:info`, re-save. Never crash on a
  game patch.
- `mod:command("hudcustomizer_reset", <desc>, fn)` → wipe `layout.nodes`, restore snapshotted
  defaults on the live HUD.
- Mod disable (`mod.on_disabled`): restore defaults on live elements, keep the saved table.

### 5.5 Exclusion list
Seed verbatim from Custom HUD (proven in production): `HudElementCrosshair`,
`HudElementInteraction`, `HudElementWorldMarkers`, `HudElementEmoteWheel`,
`HudElementSmartTagging`, `HudElementDamageIndicator`, `HudElementPrologueTutorialInfoBox`,
`HudElementPrologueTutorialSequenceTransitionEnd`, the editor element itself; excluded
sub-nodes: `HudElementPlayerWeaponHandler` `weapon_slot_1..4`, `HudElementTacticalOverlay`
`background`/`canvas`.

## 6. Milestones

| # | Milestone | Acceptance criteria |
|---|---|---|
| M0 | Skeleton | Mod loads (Options → Mods entry, no log errors); keybind binds and `mod:echo`s; `/hudcustomizer_reset` echoes. Ctrl+Shift+R reload loop working. |
| M1 | Injection + discovery | Editor element injects via `register_hud_element` in both Psykhanium and hub; on toggle, logs the discovered node list; cursor appears/disappears; gameplay input blocked while open, fully restored on close (incl. after Ctrl+Shift+R while open). |
| M2 | Proxies + selection | Proxy boxes drawn over discovered nodes, tracking real rects; click selects (highlight), click-away deselects; overlap resolved topmost-wins; menus force-close the editor. |
| M3 | Drag | Selected node drags live at all resolutions/UI-scale settings (delta math correct under `inverse_scale` and hud_scale); release keeps position for the session. |
| M4 | Persistence | Positions survive editor close → hub↔mission → full quit-to-desktop → relaunch (verify once with Steam offline). Reset restores stock. Fabricated stale key prunes with a log line, no crash. |
| M5 | Hardening | Disable→enable cycle per §5.4; spectate/death/respec/cutscene transitions don't crash or strand the cursor; exclusion list validated element-by-element in a real mission. |

Each milestone is testable in-game before the next begins.

## 7. Testing

- Install: copy/symlink into `<game>/mods/`, add `HUDCustomizer` to `mod_load_order.txt`
  after `dmf`. Iterate in the **Psykhanium**; test hub separately (different element list).
- Regression traps to exercise explicitly: loadout swap (ability HUD rebuild), spectating a
  teammate (spectator HUD), dying while editor open, opening Mod Options while editor open,
  cutscene start, 21:9 + non-100% HUD-scale setting.
- Log at `%AppData%\Fatshark\Darktide\console_logs\` — grep for `[HUDCustomizer]` and Lua
  errors after every session.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Game patch changes `set_scenegraph_position` / renders / node names | pcall every game-API call touching elements (Custom HUD probes 6 `draw_text` signatures for this reason); prune-and-log stale keys; delta storage composes with moved defaults. |
| Cursor push/pop imbalance strands the player | Single `_cursor_pushed` flag; pop in `set_active(false)`, `destroy`, `on_disabled`, `on_unload`. |
| `"alive"` visibility group missing in some context | Fallback documented in §4 (own group via `UIHud.init` hook, Custom HUD pattern). |
| Multi-node elements feel awkward to move node-by-node | Accepted for MVP (matches Custom HUD UX); element-level grouping is backlog. |
| `mod:set` not flushed if game crashes | Accepted; normal exit and state changes flush. |
| Element positions written by game code each frame override us | Not observed for scenegraph positions (only widget styles, which is why HUD Tweaker re-applies per frame); if a specific element does, special-case it with a per-frame re-apply for that element only. |

## 9. Definition of done

A player installs the mod, binds a key, presses it in the Psykhanium, drags any non-excluded
HUD node somewhere new, closes the editor, quits to desktop, relaunches offline, and the node
is exactly where they left it — with `/hudcustomizer_reset` available to undo everything, and
no possible state where gameplay input stays blocked.

(IMPORTANT NOTE: THIS MOD SHOULD ALSO APPLY TO IN GAME MATCHES AND THE LOBBY)