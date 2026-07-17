local mod = get_mod("HUDCustomizer")

return {
    name = mod:localize("hud_customizer"),
    description = mod:localize("hud_customizer_description"),
    is_togglable = true,
    allow_rehooking = true,
    options = {
        widgets = {
            {
                setting_id = "hud_customizer_settings",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "toggle_editor_key",
                        type = "keybind",
                        default_value = {},
                        keybind_trigger = "pressed",
                        keybind_type = "function_call",
                        function_name = "toggle_editor",
                    },
                },
            },
        },
    },
}
