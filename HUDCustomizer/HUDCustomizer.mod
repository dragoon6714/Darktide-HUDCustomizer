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
