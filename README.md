# HUD Customizer

A Warhammer 40,000: Darktide mod that lets you reposition HUD elements with an in-game drag-and-drop editor. Press a keybind, click any highlighted element box, and drag it where you want it. Changes apply live and persist across missions, sessions, and game restarts.

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
| Select an element | Left-click its box |
| Move | Drag with left mouse button |
| Deselect | Left-click empty space |
| Close the editor | Press the keybind again (opening any menu also closes it) |

Reset **everything** to the stock layout with the chat command `/hudcustomizer_reset`.

Positions are stored locally in Darktide's own `user_settings.config` (via DMF), so they work offline and survive game restarts.

## FAQ

**Some elements have no box.** A few elements are deliberately excluded because moving them breaks them: the crosshair, damage indicators, world markers/tagging, interaction prompts, the emote wheel, and prologue tutorial popups.

**My positions reset after a game patch.** Expected when Fatshark renames internal HUD nodes — stale entries are pruned automatically (with a log line) so nothing crashes. Re-position the affected elements.

**Everything back to stock?** `/hudcustomizer_reset`, or disable the mod in Mod Options (your saved layout is kept and re-applies when re-enabled).

**Does it work in missions and the hub?** Yes — offsets re-apply on every HUD build: game load, hub ↔ mission transitions, and mod reloads. (Spectating uses a separate HUD that DMF cannot inject mod elements into; it shows stock positions while you spectate.)

## Credits

- Built on the [Darktide Mod Framework](https://dmf-docs.darkti.de/#/).
- Editor architecture informed by [Custom HUD](https://github.com/fracticality/darktide-mods/tree/master/custom_hud) by Fracticality and [HUD Tweaker](https://github.com/danreeves/darktide-mods/tree/main/HUDTweaker) by danreeves.
