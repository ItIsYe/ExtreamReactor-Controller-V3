package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den gemeldeten Bug "ZURUECK-Button funktioniert
-- nicht" auf der FUEL/REPROCESSOR-Router-Seite (Fix 2026-07-26).
--
-- core/ui_router.lua nutzt den Rueckgabewert von page.render() als Quelle
-- fuer die sichtbaren ZURUECK/WEITER-Touch-Zonen. Deshalb muss jede Router-
-- Page einen Footer mit left/right-Koordinaten zurueckgeben.
--
-- FUEL hat seit beta-v613 absichtlich einen eigenen, groesseren Footer:
-- router_ui:render() zeichnet zuerst den Router-Inhalt, danach zeichnet
-- large_footer() die tatsaechlich sichtbaren grossen FUEL-Navigationsbuttons.
-- Folglich muessen fuer FUEL die Koordinaten von large_footer() an den
-- ui_router zurueckgereicht werden. REPROCESSING verwendet weiterhin direkt
-- den Footer von router_ui:render().

local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local content = f:read('*a')
  f:close()
  return content
end

local function extract(content, start_marker, end_marker)
  local s = content:find(start_marker, 1, true)
  assert(s, 'start marker not found: ' .. start_marker)
  local e = content:find(end_marker, s, true)
  assert(e, 'end marker not found: ' .. end_marker)
  return content:sub(s, e + #end_marker - 1)
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. nodes/fuel/monitor_ui.lua's "Router"-Eintrag: sichtbar ist der neue
-- grosse FUEL-Footer, also muss genau dessen Touch-Geometrie zurueckkommen.
do
  local source = read_file('xreactor/nodes/fuel/monitor_ui.lua')
  local entry_src = extract(source,
    '{ name = "Router", render = function(target, page_model, should_clear)',
    'ctx.get_router_ui():handle_touch(x, y) end }')

  local old_router_footer = { left = { x1 = 2, x2 = 10, y = 20 }, right = { x1 = 50, x2 = 60, y = 20 } }
  local large_fuel_footer = { left = { x1 = 3, x2 = 17, y = 20 }, right = { x1 = 46, x2 = 60, y = 20 } }
  local render_calls = 0
  local mock_router_ui = {
    render = function(_self, _target, _ui, _colors, _should_clear)
      render_calls = render_calls + 1
      return old_router_footer
    end,
    handle_touch = function(_self, _x, _y) return true end,
  }

  local chunk = [[
local ctx = {
  get_router_ui = function() return ROUTER_UI_MOCK end,
  ui = nil,
  colors = nil,
}
local large_footer = function(_target, center)
  assert(center == "ROUTER")
  return LARGE_FOOTER_MOCK
end
return ]] .. entry_src

  local env = {
    ROUTER_UI_MOCK = mock_router_ui,
    LARGE_FOOTER_MOCK = large_fuel_footer,
    assert = assert,
  }
  env._G = env
  local fn = assert(load(chunk, 'fuel_router_page_entry_chunk', 't', env))
  local entry = fn()

  assert_true(type(entry.render) == 'function', 'the FUEL Router page entry must have a render field')
  local result = entry.render('MON', 'MODEL', true)
  assert_true(render_calls == 1, 'FUEL Router page must still render router_ui exactly once')
  assert_true(result == large_fuel_footer,
    'nodes/fuel/monitor_ui.lua: Router page must return the visible large_footer() touch geometry')
  assert_true(result.left and result.right,
    'nodes/fuel/monitor_ui.lua: returned FUEL footer must expose left/right touch zones')
end

-- 2. nodes/reprocessor/main.lua's "Router"-Eintrag verwendet weiterhin
-- direkt den Footer von router_ui:render().
do
  local source = read_file('xreactor/nodes/reprocessor/main.lua')
  local entry_src = extract(source,
    '{ name = "Router", render = function(target, m, should_clear)',
    'get_router_ui():handle_touch(x, y) end }')

  local mock_footer = { left = { x1 = 2, x2 = 10, y = 20 }, right = { x1 = 50, x2 = 60, y = 20 } }
  local mock_router_ui = {
    render = function(_self, _target, _ui, _colors, _should_clear) return mock_footer end,
    handle_touch = function(_self, _x, _y) return true end,
  }

  local chunk = [[
local get_router_ui = function() return ROUTER_UI_MOCK end
local ui, colors = nil, nil
return ]] .. entry_src

  local env = { ROUTER_UI_MOCK = mock_router_ui }
  env._G = env
  local fn = assert(load(chunk, 'reprocessor_router_page_entry_chunk', 't', env))
  local entry = fn()

  assert_true(type(entry.render) == 'function', 'the REPROCESSOR Router page entry must have a render field')
  local result = entry.render('MON', 'MODEL', true)
  assert_true(result == mock_footer,
    'nodes/reprocessor/main.lua: Router page render() must return router_ui:render() footer geometry')
end

print("router_page_footer_nav_return_test.lua: ok")
