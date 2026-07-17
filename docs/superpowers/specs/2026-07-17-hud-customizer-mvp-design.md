# HUD Customizer — MVP Implementation Plan

Date: 2026-07-17 · Scope: `AGENT.md` §2 "In" list only (backlog explicitly excluded) · Status: approved by user instruction ("build the plan, review it, start working immediately")

## 0. What this plan is

`AGENT.md` is the verified product spec. This document is the implementation design derived
from it, with every API claim re-verified against local checkouts (`.reference/dmf`,
`.reference/game`, `.reference/fracticality/custom_hud`) on 2026-07-17. Where this plan
deliberately deviates from the reference mod (Custom HUD), the deviation and its reason are
stated.

**Out of scope (AGENT.md §2 backlog) — none of this is built:** resize/scale, hide/show,
grid & snapping, arrow-key nudge, element list panel, constant-elements, whole-HUD-hide
keybind, per-widget style editing.

Design rule (user requirement): scalable, simple, minimal. Every mechanism below was chosen
to have the fewest moving parts that satisfy `AGENT.md`; anything more complex was rejected.

## 1. Layout

Repo root is the project; the deployable mod folder is `HUDCustomizer/` (matches README
install instructions):

```
HUDCustomizer/
├── HUDCustomizer.mod                     -- new_mod() entry (template mirrors custom_hud.mod)
└── scripts/mods/HUDCustomizer/
    ├── HUDCustomizer.lua                 -- state, keybind fn, command, hooks, layout store, apply/restore
    ├── HUDCustomizer_data.lua            -- one group + one keybind widget (unbound default)
    ├── HUDCustomizer_localization.lua    -- en strings
    └── hud_element_editor.lua            -- class("HudElementHudCustomizer", "HudElementBase")
```

## 2. Responsibilities and data flow

Two runtime pieces, one shared registry:

**Mod file (`HUDCustomizer.lua`)** — owns durable state and all entry points:
- `mod._editor_active` (boolean) — the single source of truth for "editor open".
- `mod._layout` — cached saved layout: `{ version = 1, nodes = { ["Element|node"] = { dx = 0, dy = 0 } } }`.
  Loaded once at script load from `mod:get("layout")`; written through via `mod:set("layout", mod._layout)`
  on drag-release and editor close. Map-only tables (DMF rejects mixed tables at flush).
- `mod._nodes` — per-HUD-build registry (map), rebuilt by the editor element's `init`.
- Entry points: `toggle_editor` (keybind), `_close_editor` (used by open_view hook,
  `on_disabled`, `on_unload`), `_restore_defaults` (used by reset command and `on_disabled`),
  `/hudcustomizer_reset` chat command.
- Calls `mod:register_hud_element{...}` once, top-level.

**Editor element (`hud_element_editor.lua`)** — owns everything per-HUD-build and per-frame:
- `init`: discovery → rebuild `mod._nodes`; build proxy definitions; create own
  scenegraph + widgets; apply saved offsets (this is what makes offsets survive every
  player-HUD rebuild: load, hub↔mission, reload).
- `update`: react to `mod._editor_active` flips; while active — sync proxy rects, hover /
  selection, drag math, live apply. Gate everything on `self._active`.
- `set_visible(false)` / `destroy`: force-deactivate (cursor pop is guarded).

**Registry entry** — `mod._nodes["<ElementName>|<node_name>"]`:

```lua
{
  element_name   = "HudElementTeamPanelHandler",
  node_name      = "pivot",
  element        = <live element ref>,
  uses_hud_scale = true,                  -- from hud._elements_hud_scale_lookup
  def_x, def_y, def_z,                    -- default position (see §4)
  def_h_align, def_v_align,               -- default alignments (for reset fidelity)
  -- proxy bookkeeping (editor-virtual 1920x1080 units), refreshed per frame while active:
  px, py, pw, ph,
}
```

## 3. Verified API facts this design relies on

(All confirmed in `.reference` checkouts; `AGENT.md` §3 remains the parent spec.)

- `HudElementBase:set_scenegraph_position(id, x, y, z, h_align, v_align)` — nil x/y/z are
  skipped per-component; nil alignments keep current values; sets `_update_scenegraph = true`
  and the base `update` recomputes world positions + dirties widgets
  (`hud_element_base.lua:155-177,211-223`). So "apply" needs nothing else.
- `UIHud:element(name)` exists; `hud._elements`, `hud._elements_array`,
  `hud._elements_hud_scale_lookup`, `hud._currently_visible_elements` are live tables
  (`ui_hud.lua`). Element `update(dt, t, ui_renderer, render_settings, input_service)` only
  runs while the element is in the active visibility group; `using_input()` is polled on
  every element every frame (`element.using_input and element:using_input()`).
- Visibility groups: first valid group wins; on group change every element gets
  `set_visible(status, ui_renderer, use_retained_mode)` (`ui_hud.lua:278-315`). `"alive"`
  exists in player, hub, and spectator element lists — no fallback group hook needed.
- `UIWidget.create_definition(passes, scenegraph_id, content, size, style, overrides)`;
  rect passes draw the scenegraph node rect (style `size`/`offset` optional overrides);
  `UIWidget.draw` checks `widget.visible` first, then `content.visible == false` per pass
  (`ui_widget.lua`). Widgets start `visible = true` → editor sets proxy widgets invisible at
  creation and toggles visibility on activate/deactivate.
- Scenegraph: nodes have `position` (local, {x,y,z}), `size`, `horizontal_alignment` /
  `vertical_alignment` ("center"/"right", "center"/"bottom"; anything else = left/top);
  `hierarchical_scenegraph` is a **dense array** of root nodes, each with `.children` dense
  array (`ui_scenegraph.lua`). Child node world position = parent world + local + alignment.
- Scale: `RESOLUTION_LOOKUP.scale` / `.inverse_scale` (1920×1080 fragment space);
  `Hud.hud_scale()` = `RESOLUTION_LOOKUP.scale * hud_scale_setting/100`
  (`scripts/utilities/ui/hud.lua`). HUD-scale elements update/draw wrapped in
  `_apply_hud_scale`/`_abort_hud_scale`, so their scenegraph space differs by exactly the
  factor `Hud.hud_scale()/RESOLUTION_LOOKUP.scale`.
- Cursor: `Managers.input:push_cursor(ref)` / `pop_cursor(ref)`; pop decrements depth
  unconditionally → single `_cursor_pushed` guard is mandatory (Custom HUD's documented fix).
- Input service in HUD update provides `"cursor"` (Vector3, physical pixels),
  `"left_pressed"`, `"left_hold"`, `"left_released"` (same actions the hotspot pass reads).
- DMF: `register_hud_element` injects after `UIHud._setup_elements` (or immediately if a HUD
  exists), removes on HUD destroy and on mod disable, and calls `add_require_path(filename)`
  itself. Keybind `function_call` dispatches `mod[function_name](is_pressed)` **without
  self** → define as `function mod.toggle_editor(is_pressed)`. Lifecycle events
  (`on_disabled`, `on_unload`, ...) also pass no self. `mod:set`/`mod:get` shallow-clone
  tables both directions; flush to disk happens on game-state change and on exit/unload.
  Widget localization keys: `<setting_id>` (title) and `<setting_id>_description` (tooltip).
- Requires inside mod files: `mod:original_require("scripts/...")` (Custom HUD pattern).

## 4. Key design decisions (with rejected alternatives)

1. **Deltas from defaults, alignment preserved** (AGENT.md §5.3 improvement).
   Store `{dx, dy}` relative to the snapshotted default; apply as
   `pcall(element.set_scenegraph_position, element, node_name, def_x+dx, def_y+dy, def_z, nil, nil)`.
   *Rejected:* Custom HUD's absolute positions + forced `"left"/"top"` (breaks right/bottom
   anchored elements across aspect ratios).
2. **Defaults snapshot**: from `element._definitions.scenegraph_definition[node_name]`
   (authored source of truth, stable across HUD rebuilds); fall back to the live child
   node's `position`/`size`/alignments when the definition entry is missing. Definition
   `position` may be nil → treat as `{0,0,0}`.
3. **Discovery scope**: iterate `hud._elements_array` (live elements), walk each
   `_ui_scenegraph.hierarchical_scenegraph[*].children` — one movable node per top-level
   child, exactly Custom HUD's proven path. Exclusion lists seeded verbatim from Custom HUD
   (minus its `ConstantElement*` entries — constants are out of MVP scope; plus our own
   `HudElementHudCustomizer`).
4. **Proxies: own scenegraph + own widgets, no hotspot passes.** Each discovered node gets a
   scenegraph node parented to `"screen"` (root, left/top → position == virtual world
   position) and one widget with two rect passes: full-size border rect (z=1) + inset-by-2
   fill rect (z=2) — Custom HUD's border illusion. Visibility via `widget.visible`.
   *Rejected:* hotspot passes + `_widget_press_stack` (engine callback ordering, more moving
   parts). Manual hit-test in `update` against the synced `px,py,pw,ph` rects, iterating
   proxies in reverse creation order = topmost-wins. Same result, ~40 fewer lines, zero
   engine interplay.
5. **Per-element scale factor in all math.** For a node on a `use_hud_scale` element:
   `scale = Hud.hud_scale()` else `RESOLUTION_LOOKUP.scale` (recomputed each drag frame —
   handles live setting/resolution changes).
   - Drag: `dx = drag.start_dx + (cursor_x - drag.press_x) / scale` (same for dy). Latched
     press position + committed start offset (Custom HUD's formula, generalized).
   - Proxy placement: `px = world_x * scale / RESOLUTION_LOOKUP.scale` (and size likewise);
     synced every frame while active via own `set_scenegraph_position` +
     `_set_scenegraph_size` + inner-fill `style.size` write.
   *Rejected:* Custom HUD's ignore-hud-scale approach (mis-drags hud-scaled elements —
   most of the HUD — whenever the user's HUD scale ≠ 100%; violates M3 acceptance).
6. **Activation via flag-watch in `update`** (Custom HUD pattern): keybind flips
   `mod._editor_active`; element reacts next update → `_set_active(true/false)`.
   Activate: `push_cursor` (guarded by `_cursor_pushed`), proxies visible. Deactivate:
   proxies invisible, selection/drag cleared, `pop_cursor` (guarded), save layout.
   `using_input()` returns `self._active` — this alone blocks gameplay input
   (`HumanGameplay._input_active` chain, AGENT.md §3).
7. **Force-close paths call the live element directly**, not just the flag:
   `mod._close_editor()` sets the flag AND calls `hud:element("HudElementHudCustomizer")
   :_set_active(false)` if reachable — so the cursor pops even when the element's `update`
   won't run (menu open, reload edge cases). Guards make double-pop impossible.
   Force-close triggers: `hook_safe("UIViewHandler", "open_view")`, `set_visible(false)`
   (death/cutscene/popup group switches), `destroy` (also clears `mod._editor_active` so a
   new HUD build doesn't reopen the editor), `on_disabled`, `on_unload`.
8. **Toggle guards** before opening (Custom HUD's, plus one): HUD exists
   (`Managers.ui._hud`), no view using input (`ui_manager._view_handler:using_input()`),
   and the editor element exists and is currently visible
   (`hud._currently_visible_elements`) — refuses to "open" while dead/in cutscene where the
   element never updates. Closing is always allowed.
9. **Apply moments** (AGENT.md §5.3): editor `init` (every HUD build), live during drag,
   and on close. Save moments: drag-release and close (disk flush rides DMF's points).
10. **Prune rule (safer than Custom HUD)**: at apply-all, a saved key is dropped only when
    its element **exists in this HUD** but `rawget(element._ui_scenegraph, node_name) == nil`
    (genuinely stale after a game patch) → drop + `mod:info` + re-save. If the element is
    absent (different context: hub vs mission vs spectator) the entry is **kept** — pruning
    it would destroy the player's layout for the other context. Inert entries cost nothing.
11. **No `recreate_hud`** (Custom HUD destroys/rebuilds the player HUD on reload). After
    Ctrl+Shift+R the element re-injects on the next HUD build; acceptable for MVP and far
    less invasive. Documented in Testing.
12. **Reset**: `/hudcustomizer_reset` → `layout.nodes = {}` + save + `_restore_defaults()`
    (iterate registry, `pcall(set_scenegraph_position, element, node, def_x, def_y, def_z,
    def_h_align, def_v_align)` — full authored restore including alignments).
    `on_disabled`: close editor + restore defaults on the live HUD, keep the saved table.

## 5. Editor element — update flow (single pass, all gated)

```text
update(dt, t, ui_renderer, render_settings, input_service):
    super.update(...)                                  -- scenegraph recompute + dirty
    if mod._editor_active ~= self._active: _set_active(mod._editor_active)
    if not self._active: return
    inverse_scale = render_settings.inverse_scale       -- 1/RESOLUTION_LOOKUP.scale (we are use_hud_scale=false)
    cursor = input_service:get("cursor")
    _sync_proxies()                                     -- per registry entry: world pos/size -> px,py,pw,ph (+ scenegraph writes)
    hovered = hit_test(cursor, reverse proxy order)
    update border colors (normal / hovered / selected)
    if input_service:get("left_pressed"):
        if hovered: select(hovered); begin drag (latch press cursor + committed dx,dy)
        else: clear selection
    if self._drag and input_service:get("left_hold"):
        dx,dy = latched + delta/scale; write mod._layout.nodes[key]; apply live (pcall)
    if self._drag and input_service:get("left_released"):
        self._drag = nil; mod._save_layout()
```

Drag only affects the single selected node (MVP). Click-away deselects (M2 acceptance —
deliberately better than Custom HUD, which lacks it).

## 6. Options / localization

- `HUDCustomizer_data.lua`: `{ name, description, is_togglable = true, allow_rehooking = true, options = { widgets = { group{ sub_widgets = { keybind{ setting_id = "toggle_editor_key", default_value = {}, keybind_trigger = "pressed", keybind_type = "function_call", function_name = "toggle_editor" } } } } } }`.
  `default_value = {}` = unbound by default (DMF accepts; binds nothing until the player sets it).
- Localization keys: `hud_customizer`, `hud_customizer_description`, `toggle_editor_key`,
  `toggle_editor_key_description` (+ `en` only, per AGENT.md).

## 7. Risks carried from AGENT.md §8 — status in this design

- Game-API drift → pcall on every cross-element `set_scenegraph_position`; prune-and-log.
- Cursor imbalance → single `_cursor_pushed` flag; pop sites: `_set_active(false)`,
  `destroy`. `pop_cursor` itself is unguarded engine-side, so all pops go through the flag.
- Reload mid-game (Ctrl+Shift+R) → `on_unload` closes via the live element (flag-independent);
  re-injection on next HUD build; `allow_rehooking = true`.
- Context-specific elements → keep-don't-prune rule (§4.10).
- Elements re-writing their own scenegraph positions per frame → not observed for positions;
  if one appears, special-case per-frame re-apply for that element only (AGENT.md §8).
- Spectator HUD → DMF injects a registered element only once per mod-load (status gate in
  `custom_hud_elements.lua`), and spectating uses a *separate* `UIHud` instance, so the
  spectator HUD never gets the editor element: stock positions while spectating, no editor
  there. Saved offsets target player-HUD elements (which the spectator list mostly lacks),
  and the player HUD keeps its offsets throughout — impact ≈ nil. Documented limitation;
  lifting it requires the `UIHud.init`-hook fallback from AGENT.md §4.

## 8. Milestones (AGENT.md §6, unchanged) and verification stance

M0 skeleton → M1 injection/discovery/toggle → M2 proxies/selection → M3 drag →
M4 persistence/reset/prune → M5 hardening review. Code is written milestone-ordered but
landed as one coherent drop; in-game acceptance per AGENT.md §6/§7 must run on a Windows
install — **this machine cannot run Darktide**, so verification here is: (a) every game/DMF
API call mirrored from the verified checkouts, (b) Lua syntax checking of all files,
(c) a full self-review pass against the M0–M5 acceptance criteria and the regression traps
(§7) before handoff. That residual in-game test gap is stated plainly, not papered over.

## 9. Definition of done

AGENT.md §9, plus: no state where gameplay input stays blocked (cursor pop guaranteed by
flag + destroy + set_visible + lifecycle paths), `/hudcustomizer_reset` restores stock,
README trimmed to what the MVP actually does.
