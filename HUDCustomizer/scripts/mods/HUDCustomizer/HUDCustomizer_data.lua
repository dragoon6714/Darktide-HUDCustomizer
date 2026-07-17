local mod = get_mod("HUDCustomizer")

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "open_editor_keybind",
                type = "keybind",
                -- Ship unbound: default keybind collisions between mods are
                -- unchecked, all mods bound to the same key would fire.
                default_value = {},
                keybind_trigger = "pressed",
                keybind_type = "function_call",
                function_name = "toggle_hud_editor",
            },
            {
                setting_id = "toggle_hud_keybind",
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
                    {
                        setting_id = "grid_size",
                        type = "numeric",
                        default_value = 20,
                        range = { 5, 100 },
                        decimals_number = 0,
                    },
                },
            },
            {
                setting_id = "snap_to_elements",
                type = "checkbox",
                default_value = true,
            },
            {
                setting_id = "show_info_panel",
                type = "checkbox",
                default_value = true,
            },
        },
    },
}
