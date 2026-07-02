-- xreactor/optional/pocket_client.lua
--
-- Eigenstaendiges Client-Programm fuer einen Pocket Computer (oder
-- beliebigen anderen Computer mit Ender Modem, der nicht als regulaerer
-- XReactor-Node laufen soll). Sendet eine POCKET_QUERY-Anfrage auf dem
-- Status-Kanal, wartet auf die POCKET_STATUS-Antwort des Masters, zeigt
-- sie an und wiederholt das alle paar Sekunden.
--
-- Installation: diese Datei manuell auf einen Pocket Computer kopieren
-- (z.B. per Diskette oder wget, falls HTTP auf dem Pocket Computer erlaubt
-- ist) und als /startup.lua einrichten, oder einfach manuell starten.
-- Ist NICHT Teil des regulaeren Installer-Rollenflusses (LOG/MASTER/RT/...)
-- — ein Pocket Computer registriert sich absichtlich nicht als Node.
--
-- Kanaele: nutzt denselben STATUS-Kanal (6501) wie der normale Master<->
-- Node-Traffic, da POCKET_QUERY/POCKET_STATUS darueber laufen (siehe
-- xreactor/optional/pocket_query_handler.lua auf der Master-Seite).

local CHANNEL = 6501
local QUERY_INTERVAL_S = 5
local RESPONSE_TIMEOUT_S = 3
local MY_ID = "POCKET_" .. tostring(os.getComputerID and os.getComputerID() or "?")

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
        if ok_wireless and is_wireless then
          return name, modem
        end
      end
    end
  end
  return nil
end

local function draw(status_line, summary_text, err_text)
  term.clear()
  term.setCursorPos(1, 1)
  print("XReactor Pocket Status")
  print(string.rep("-", 24))
  print(status_line)
  print("")
  if summary_text then
    print(summary_text)
  end
  if err_text then
    print("")
    print(err_text)
  end
  print("")
  print("[Q] Beenden")
end

local function send_query(modem)
  local message = {
    type = "POCKET_QUERY",
    sender_id = MY_ID,
    src = MY_ID,
    ts = os.epoch and os.epoch("utc") or 0,
    payload = {}
  }
  pcall(modem.transmit, CHANNEL, CHANNEL, message)
end

local function wait_for_response(modem, timeout_s)
  local deadline = os.clock() + timeout_s
  while os.clock() < deadline do
    local timer_id = os.startTimer(math.max(0.1, deadline - os.clock()))
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      -- os.pullEvent("modem_message") liefert:
      -- (event, side, channel, replyChannel, message, distance)
      local side, channel, reply_channel, message = p1, p2, p3, p4
      if type(message) == "table" and message.type == "POCKET_STATUS" then
        os.cancelTimer(timer_id)
        return message
      end
    elseif event == "timer" and p1 == timer_id then
      return nil
    end
  end
  return nil
end

local function main()
  local modem_name, modem = find_modem()
  if not modem then
    draw("FEHLER", nil, "Kein Ender Modem gefunden. Bitte anschliessen und neu starten.")
    return
  end
  pcall(modem.open, CHANNEL)

  draw("Verbinde...", nil, nil)

  while true do
    send_query(modem)
    local response = wait_for_response(modem, RESPONSE_TIMEOUT_S)
    if response and response.payload and response.payload.summary then
      draw("OK - verbunden", response.payload.summary, nil)
    else
      draw("Keine Antwort vom Master", nil, "Master offline oder ausser Reichweite?")
    end

    -- Auf naechste Abfrage warten, dabei "Q" zum Beenden erlauben.
    local wait_deadline = os.clock() + QUERY_INTERVAL_S
    local should_quit = false
    while os.clock() < wait_deadline do
      local timer_id = os.startTimer(math.max(0.1, wait_deadline - os.clock()))
      local event, p1 = os.pullEvent()
      if event == "key" and p1 == keys.q then
        should_quit = true
        os.cancelTimer(timer_id)
        break
      elseif event == "timer" and p1 == timer_id then
        break
      end
    end
    if should_quit then break end
  end

  term.clear()
  term.setCursorPos(1, 1)
  print("Pocket Client beendet.")
end

main()
