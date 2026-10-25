# Headless checks for the top bar widgets

No game needed. Requires Python 3 and `pip install lupa` (bundles a real Lua 5.1).

    python3 -I tools/luacheck51.py gui_top_bar_buildpower.lua      # compile with Lua 5.1 (catches syntax errors and the 200-local / 60-upvalue limits)
    python3 -I tools/run_widget.py gui_top_bar_buildpower.lua      # run the widget lifecycle against mocked Spring/gl/WG APIs

`mock_env.lua` is the mocked engine: a few fake UnitDefs (commander, builder, nano, factory, wind,
tank, solar), resources, rules params, and no-op gl. `run_widget.py` drives Initialize, ViewResize,
400 game frames with units finishing, dying and being given away, hover, a spectator switch and
Shutdown, and prints PASS/FAIL per step. The stock widget in `stock_reference/` passes it.
