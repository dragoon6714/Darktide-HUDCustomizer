# HUD Customizer

A Warhammer 40,000: Darktide mod that lets you reposition, resize, and hide **any** HUD element with an in-game drag-and-drop editor. Press a keybind, and every UI element on your screen gets a draggable proxy box plus a scrollable list panel. Changes apply live and persist across missions, sessions, and game restarts.

## Requirements

1. [Darktide Mod Loader](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader) — run `toggle_darktide_mods.bat` once (and again after every game update).
2. [Darktide Mod Framework (DMF)](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework) — must be listed first in `mod_load_order.txt`.

## Installation

1. Copy the `HUDCustomizer` folder into `<game folder>/mods/`.
2. Add a line containing `HUDCustomizer` to `<game folder>/mods/mod_load_order.txt` (anywhere after `dmf`).
3. Launch the game, open **Options → Mods → HUD Customizer**, and bind **Open HUD Editor** to a key. No key is bound by default.

## Usage

Enter the hub or a mission (the Psykhanium is a good safe place to experiment), then press your editor keybind.

| Action | Input |
|---|---|
| Select an element | Left-click its box (or its row in the list panel) |
| Move | Drag with left mouse button |
| Nudge | Arrow keys (hold **Shift** for ×5) |
| Resize | **Alt** + arrow keys, or scroll wheel (uniform scale) |
| Hide / show | Right-click (box or panel row) |
| Reset one element | Double-click its box |
| Invert snapping temporarily | Hold **Ctrl** while dragging |
| Move the list panel | Drag its header |
| Scroll the list panel | Mouse wheel over the panel |
| Close the editor | Press the keybind again (opening any menu also closes it) |

Reset **everything** with the chat command `/hudcustomizer_reset`.

A separate **Toggle HUD Visibility** keybind hides the entire HUD (screenshot mode).

### Options

- **Grid Snapping** + **Grid Size** — snap dragged elements to a grid (drawn while dragging).
- **Snap To Other Elements** — magnetic edge/center alignment against other elements.
- **Show Element List Panel** — the scrollable list of every detected element.

## FAQ

**Some elements have no box.** A few elements are deliberately excluded because moving them breaks them: the crosshair, damage indicators, world markers/tagging, interaction prompts, the emote wheel, and popups.

**My positions reset after a game patch.** Expected when Fatshark renames internal HUD nodes — stale entries are pruned automatically so nothing crashes. Re-position the affected elements.

**Hiding one part of an element hid all of it.** Hiding works per-element, not per-node, in this version.

**A hidden element still shows for a moment.** A handful of elements draw outside the standard pipeline; report these on the mod page.

**Everything back to stock?** `/hudcustomizer_reset`, or disable the mod in Mod Options (your saved layout is kept and re-applies when re-enabled).

## Credits

- Built on the [Darktide Mod Framework](https://dmf-docs.darkti.de/#/).
- Editor architecture informed by [Custom HUD](https://github.com/fracticality/darktide-mods/tree/master/custom_hud) by Fracticality and [HUD Tweaker](https://github.com/danreeves/darktide-mods/tree/main/HUDTweaker) by danreeves.
