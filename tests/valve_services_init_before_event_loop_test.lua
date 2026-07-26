package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den gemeldeten Node-Absturz "attempt to index field
-- 'comms' (a nil value)" (Fix 2026-07-27). Root cause: nodes/valve/main.lua
-- rief -- anders als RT/FUEL/REPROCESSOR/WATER, die denselben Event-Loop
-- (nodes/support/runtime.lua's run_event_loop()) nutzen -- niemals
-- services:init() auf, bevor die Event-Loop betreten wurde. comms_service:
-- init() (siehe services/comms_service.lua) setzt self.comms; ohne diesen
-- Aufruf blieb self.comms bis zum ERSTEN services:tick()-Aufruf nil, waehrend
-- run_event_loop() bei einem modem_message-Event comms:handle_event(event)
-- bereits VOR dem allerersten services:tick()-Aufruf ausfuehrt -- war das
-- allererste Event nach dem Boot ein modem_message (auf einem Server mit
-- beliebigem Funkverkehr sehr wahrscheinlich), stuerzte die Node sofort ab.
--
-- Dieser Test prueft strukturell per String-Suche, dass main.lua eine
-- tatsaechliche "services:init()"-Codezeile (nicht nur eine Erwaehnung in
-- einem Kommentar) GENAU EINMAL enthaelt, und zwar NACH allen
-- "services:add(...)"-Aufrufen und VOR dem Aufruf von support_runtime.
-- run_event_loop(...) -- exakt dieselbe Reihenfolge, die RT/FUEL/
-- REPROCESSOR/WATER bereits einhalten. Kommentarzeilen (beginnend mit
-- "--") werden dabei ausdruecklich uebersprungen, damit ein erklaerender
-- Kommentar wie dieser hier selbst keinen falschen Treffer erzeugt.

local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local content = f:read('*a')
  f:close()
  return content
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- Liefert { {line_no=, text=}, ... } fuer jede NICHT-Kommentarzeile, die
-- exakt "services:init()" ist (nach Trimmen von Leerraum).
local function find_code_lines(source, exact_text)
  local matches = {}
  local line_no = 0
  for line in (source .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == exact_text then
      matches[#matches + 1] = line_no
    end
  end
  return matches
end

local function last_index(haystack, needle)
  local last, start = nil, 1
  while true do
    local s = haystack:find(needle, start, true)
    if not s then break end
    last = s
    start = s + #needle
  end
  return last
end

local function line_start_index(source, line_no)
  local idx, current_line = 1, 1
  for line in (source .. "\n"):gmatch("(.-\n)") do
    if current_line == line_no then return idx end
    idx = idx + #line
    current_line = current_line + 1
  end
  return nil
end

for _, node in ipairs({
  { path = 'xreactor/nodes/valve/main.lua', label = 'VALVE' },
}) do
  local source = read_file(node.path)

  local init_lines = find_code_lines(source, 'services:init()')
  assert_true(#init_lines == 1,
    node.label .. ': expected exactly one actual services:init() code line (not counting comments), found ' .. #init_lines)
  local init_idx = line_start_index(source, init_lines[1])

  local last_add_idx = last_index(source, 'services:add(')
  assert_true(last_add_idx ~= nil, node.label .. ': expected at least one services:add(...) call')
  assert_true(init_idx > last_add_idx,
    node.label .. ': services:init() must come after every services:add(...) registration')

  local loop_idx = source:find('support_runtime.run_event_loop(', 1, true)
  assert_true(loop_idx ~= nil, node.label .. ': expected a support_runtime.run_event_loop(...) call')
  assert_true(init_idx < loop_idx,
    node.label .. ': services:init() must be called BEFORE run_event_loop() -- otherwise self.comms stays nil ' ..
    'until the first tick, and an early modem_message event crashes the node (see services/comms_service.lua)')
end

print("valve_services_init_before_event_loop_test.lua: ok")
