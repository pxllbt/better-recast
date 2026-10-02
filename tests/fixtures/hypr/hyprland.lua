-- Fixture for scripts/read-binds.lua (see tests/smoke.sh).
hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("ghostty"), { description = "Terminal" })
hl.bind("CTRL + ALT + Print", hl.dsp.exec_cmd("omarchy-shell px-recast cancel"), { description = "Discard recording" })
hl.bind("SUPER + SHIFT + ALT + P", hl.dsp.exec_cmd("omarchy-shell px-recast pause"))
hl.bind("SUPER + Q", hl.dsp.window.close(), { description = "Close window" })
hl.monitor({ output = "", mode = "preferred" })
