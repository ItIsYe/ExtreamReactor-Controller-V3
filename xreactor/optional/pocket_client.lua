if type(package) == "table" and type(package.path) == "string"
    and not package.path:find("/xreactor/%?%.lua") then
  package.path = package.path .. ";/xreactor/?.lua;/xreactor/?/init.lua"
end

local CHANNEL = 6501
local QUERY_INTERVAL_S = 5
local RESPONSE_TIMEOUT_S = 3
local MY_ID = "POCKET_" .. tostring(os.getComputerID and os.getComputerID() or "?")
local POCKET_ROLE = "POCKET"
local protocol = require("core.protocol")
local AUTH_SECRET = protocol.resolve_auth_secret({})

local CC = colors or {
  white = 1, orange = 2, yellow = 16, lime = 32, gray = 128,
  lightGray = 256, cyan = 512, blue = 2048, red = 16384, black = 32768,
}

local function fit(text, width)
  local s = tostring(text or ""):gsub("[\r\n]", " ")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "~"
end

local function set_bg(c) if term.setBackgroundColor then term.setBackgroundColor(c) end end
local function set_fg(c) if term.setTextColor then term.setTextColor(c) end end
local function write_at(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  if bg then set_bg(bg) end
  if fg then set_fg(fg) end
  term.write(tostring(text or ""))
end

local function clear()
  set_bg(CC.black)
  set_fg(CC.white)
  term.clear()
end

local function header(title, page, status_color)
  local w = ({ term.getSize() })[1]
  status_color = status_color or CC.lime
  write_at(1, 1, string.rep(" ", w), CC.black, status_color)
  write_at(2, 2, "[X] " .. fit(title, math.max(1, w - 12)), CC.white, CC.black)
  if page then
    local p = tostring(page)
    write_at(math.max(2, w - #p), 2, p, CC.lightGray, CC.black)
  end
end

local function status_dot(x, y, label, ok)
  write_at(x, y, (ok and "* " or "! ") .. tostring(label), ok and CC.lime or CC.yellow, CC.black)
end

local function card(x, y, w, h, title, color)
  color = color or CC.cyan
  if w < 4 or h < 3 then return end
  write_at(x, y, "+" .. string.rep("-", w - 2) .. "+", color, CC.black)
  for row = y + 1, y + h - 2 do
    write_at(x, row, "|", color, CC.black)
    write_at(x + w - 1, row, "|", color, CC.black)
  end
  write_at(x, y + h - 1, "+" .. string.rep("-", w - 2) .. "+", color, CC.black)
  if title then write_at(x + 2, y, fit("[" .. title .. "]", w - 4), color, CC.black) end
end

local function banner(y, text, color)
  local w = ({ term.getSize() })[1]
  color = color or CC.lime
  local content = fit("> " .. tostring(text or ""), math.max(1, w - 4))
  write_at(2, y, string.rep(" ", math.max(1, w - 2)), CC.black, color)
  local x = math.max(2, math.floor((w - #content) / 2))
  write_at(x, y, content, CC.black, color)
end

local function data_row(y, label, value, color)
  local w = ({ term.getSize() })[1]
  local right = tostring(value or "")
  local left_w = math.max(1, w - #right - 4)
  write_at(2, y, fit(label, left_w), color or CC.white, CC.black)
  if right ~= "" then write_at(math.max(2, w - #right), y, right, color or CC.white, CC.black) end
end

local function footer()
  local w, h = term.getSize()
  write_at(1, h, string.rep(" ", w), CC.white, CC.gray)
  write_at(2, h, "[Q] ENDE", CC.white, CC.gray)
  local right = "[C] BEFEHL"
  write_at(math.max(2, w - #right), h, right, CC.white, CC.gray)
end

local function find_modem()
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return nil end
  for _, name in ipairs(names) do
    local ok_t, ptype = pcall(peripheral.getType, name)
    if ok_t and tostring(ptype):find("modem", 1, true) then
      local ok_w, modem = pcall(peripheral.wrap, name)
      if ok_w and modem then
        local ok_wireless, is_wireless = pcall(modem.isWireless)
        if ok_wireless and is_wireless then return name, modem end
      end
    end
  end
  return nil
end

local function draw(status_line, summary_text, err_text)
  clear()
  local w, h = term.getSize()
  local connected = tostring(status_line or ""):find("OK", 1, true) ~= nil
  local status_color = connected and CC.lime or err_text and CC.red or CC.yellow
  header("XREACTOR POCKET", "STATUS", status_color)
  status_dot(2, 3, connected and "MASTER LINK OK" or "MASTER LINK", connected)
  if w >= 22 then status_dot(math.floor(w * 0.56), 3, "CH " .. tostring(CHANNEL), true) end

  banner(5, status_line or "Warte auf Status", status_color)

  if h >= 11 then
    card(2, 7, math.max(10, w - 2), math.max(4, h - 10), "SYSTEM SUMMARY", connected and CC.lime or CC.cyan)
    if summary_text then
      local y = 9
      for line in tostring(summary_text):gmatch("[^\r\n]+") do
        if y >= h - 2 then break end
        data_row(y, line, "", CC.white)
        y = y + 1
      end
    elseif err_text then
      data_row(9, "[!] " .. err_text, "", CC.red)
      if h >= 12 then data_row(10, "Master offline oder ausser Reichweite?", "", CC.yellow) end
    else
      data_row(9, "Warte auf Telemetrie ...", "", CC.lightGray)
    end
  end
  footer()
end

local function build_signed_message(message_type, payload)
  if not AUTH_SECRET then return nil, "Netzwerk-Secret fehlt" end
  local message = protocol.status(MY_ID, POCKET_ROLE, payload or {})
  message.type = message_type
  message.dst = nil
  local ok, err = protocol.sign_message(message, AUTH_SECRET)
  if not ok then return nil, err end
  return message
end

local function send_query(modem)
  local message = build_signed_message("POCKET_QUERY", {})
  if message then pcall(modem.transmit, CHANNEL, CHANNEL, message) end
end

local function wait_for_response(modem, timeout_s, expected_type)
  local deadline = os.clock() + timeout_s
  while os.clock() < deadline do
    local timer_id = os.startTimer(math.max(0.1, deadline - os.clock()))
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local message = protocol.sanitize_message(p4)
      local valid = p3 == CHANNEL and message and select(1, protocol.validate(message))
      local auth_ok = valid and AUTH_SECRET
        and select(1, protocol.verify_message_auth(message, AUTH_SECRET))
      local timestamp = message and (message.ts or message.timestamp)
      local fresh = type(timestamp) == "number"
        and math.abs((os.epoch and os.epoch("utc") or 0) - timestamp) <= 30 * 1000
      local for_me = message and message.dst == MY_ID
      local from_master = message and message.role == "MASTER"
      if auth_ok and fresh and for_me and from_master and message.type == expected_type then
        os.cancelTimer(timer_id)
        return message
      end
    elseif event == "timer" and p1 == timer_id then
      return nil
    end
  end
  return nil
end

local function prompt_command_menu(modem)
  clear()
  local w, h = term.getSize()
  header("POCKET COMMAND", "CONTROL", CC.yellow)
  status_dot(2, 3, "TOKEN REQUIRED", false)
  card(2, 5, math.max(10, w - 2), math.max(8, h - 7), "BEFEHL WAEHLEN", CC.yellow)
  data_row(7, "1  RT-HOLD UMSCHALTEN", "", CC.white)
  data_row(8, "2  PROFIL SETZEN", "", CC.white)
  data_row(9, "3  WARTUNGSMODUS NODE", "", CC.white)
  data_row(10, "0  ABBRECHEN", "", CC.lightGray)
  term.setCursorPos(3, math.min(h - 2, 12))
  set_fg(CC.yellow); set_bg(CC.black)
  term.write("> ")
  local choice = read and read() or ""

  local action, params = nil, {}
  if choice == "1" then
    action = "rt_hold_toggle"
  elseif choice == "2" then
    term.write("Profil (BASELOAD/PEAK/IDLE): ")
    params.profile = read and read() or ""
    action = "profile_set"
  elseif choice == "3" then
    term.write("Node-ID: ")
    params.node_id = read and read() or ""
    action = "maintenance_toggle"
  else
    return
  end

  term.write("Token: ")
  local token = read and read() or ""
  if tostring(token) == "" then
    draw("BEFEHL ABGEBROCHEN", nil, "Kein Token eingegeben")
    os.sleep(1.5)
    return
  end

  local message, sign_err = build_signed_message("POCKET_COMMAND",
    { action = action, params = params, token = token })
  if not message then
    draw("BEFEHL ABGELEHNT", nil, tostring(sign_err))
    os.sleep(1.5)
    return
  end
  pcall(modem.transmit, CHANNEL, CHANNEL, message)

  draw("WARTE AUF BESTAETIGUNG", nil, nil)
  local response = wait_for_response(modem, RESPONSE_TIMEOUT_S, "POCKET_COMMAND_RESULT")
  if response and response.payload then
    if response.payload.ok then
      draw("OK - BEFEHL AUSGEFUEHRT", tostring(response.payload.reason or "Befehl ausgefuehrt"), nil)
    else
      draw("BEFEHL ABGELEHNT", nil, tostring(response.payload.reason or "Unbekannter Fehler"))
    end
  else
    draw("KEINE ANTWORT", nil, "Master antwortet nicht")
  end
  os.pullEvent("key")
  -- Hinweis: os.pullEventRaw waere hier riskant (fehlerhafter Filter
  -- koennte Events verschlucken); "key" allein reicht als Bestaetigung
  -- nach der Ergebnisanzeige — anders als der Hauptloop oben, wo Touch
  -- die einzig realistische Eingabemethode fuer Pocket Computer ist,
  -- dient dies hier nur als kurze "weiter"-Bestaetigung, jeder Tastendruck
  -- (auch ueber die eingebaute Bildschirmtastatur) erfuellt das bereits.
end

local function main()
  if not AUTH_SECRET then
    draw("FEHLER", nil, "Netzwerk-Secret fehlt in network_auth.lua")
    return
  end
  -- Fix (2026-07-06): bekannter CC:Tweaked-Bug — frisch gecraftete Pocket
  -- Computer mit eingebautem Wireless-Modem registrieren das Peripheral
  -- manchmal nicht sofort (siehe cc-tweaked/CC-Tweaked#1888). Ein kurzer
  -- Retry mit Wartezeit behebt das in den meisten Faellen von selbst,
  -- ohne dass der Nutzer den Computer manuell aus- und wieder einschalten
  -- muss (der dokumentierte Workaround waere: Computer kurz ins Inventar/
  -- eine Kiste legen, 5s warten, wieder herausnehmen).
  local modem_name, modem
  for attempt = 1, 5 do
    modem_name, modem = find_modem()
    if modem then break end
    os.sleep(0.5)
  end
  if not modem then
    draw("FEHLER", nil, "Kein Wireless-Modem gefunden. Falls der Pocket Computer gerade erst gecraftet wurde: kurz ins Inventar legen, 5s warten, wieder herausnehmen (bekannter CC:Tweaked-Registrierungsbug), dann neu starten.")
    return
  end
  pcall(modem.open, CHANNEL)
  draw("VERBINDE ...", nil, nil)

  while true do
    send_query(modem)
    local response = wait_for_response(modem, RESPONSE_TIMEOUT_S, "POCKET_STATUS")
    if response and response.payload and response.payload.summary then
      draw("OK - VERBUNDEN", response.payload.summary, nil)
    else
      draw("KEINE ANTWORT VOM MASTER", nil, "Master offline oder ausser Reichweite?")
    end

    local wait_deadline = os.clock() + QUERY_INTERVAL_S
    local should_quit = false
    while os.clock() < wait_deadline do
      local timer_id = os.startTimer(math.max(0.1, wait_deadline - os.clock()))
      local event, p1, p2, p3 = os.pullEvent()
      if event == "key" and p1 == keys.q then
        should_quit = true
        os.cancelTimer(timer_id)
        break
      elseif event == "key" and p1 == keys.c then
        os.cancelTimer(timer_id)
        prompt_command_menu(modem)
        break
      elseif event == "mouse_click" or event == "monitor_touch" then
        -- Fix (2026-07-06): Pocket Computer haben keine physische
        -- Tastatur — nur "key"-Events zu unterstuetzen waere fuer das
        -- eingebaute Touch-Display unpraktisch. Footer zeigt bereits
        -- "[Q] ENDE" links / "[C] BEFEHL" rechts; Touch auf die jeweilige
        -- Bildschirmhaelfte in der Footer-Zeile loest dieselbe Aktion aus.
        local touch_x = event == "monitor_touch" and p2 or p1
        local touch_y = event == "monitor_touch" and p3 or p2
        local w, h = term.getSize()
        if touch_y == h then
          os.cancelTimer(timer_id)
          if touch_x <= math.floor(w / 2) then
            should_quit = true
          else
            prompt_command_menu(modem)
          end
          break
        end
      elseif event == "timer" and p1 == timer_id then
        break
      end
    end
    if should_quit then break end
  end

  clear()
  header("XREACTOR POCKET", "OFFLINE", CC.gray)
  data_row(5, "Pocket Client beendet.", "", CC.lightGray)
end

main()
