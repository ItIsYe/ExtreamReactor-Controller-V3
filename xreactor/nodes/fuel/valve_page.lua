-- nodes/fuel/valve_page.lua
--
-- FUEL-Seite VENTILE (82x40, feste SCADA-Geometrie wie scada_layout.lua).
--
-- Eine Zeile je Ventil aus der Routing-Konfiguration, Probleme zuerst:
--   ZUSTAND    farbig: UNBEKANNT / OFFLINE / NICHT AKTUELL / WARTET / ONLINE
--   NAME, ID   Name aus dem Heartbeat (auch nach einem Ausfall gemerkt), ID
--              wie sie in der Ventilkette steht
--   ZULETZT    wann FUEL den VALVE-Node zuletzt gehoert hat
--   VENTIL     letzte Rueckmeldung des Ventils: ZU / AUF / FEHLER
--   REAKTOREN  in welchen Ventilketten das Ventil steht -- dort muss man
--              ansetzen, wenn es nicht passt
--
-- Gedacht zum Fehlersuchen: welche Kennung meldet sich nie, welches Ventil
-- war da und ist weg, welches meldet einen Schreibfehler. Grundlage ist
-- redstone_router.lua's get_valve_status() -- dieselbe Live-Erreichbarkeit,
-- nach der FUEL auch schaltet.
--
-- Nur Darstellung. M.collect() ist rein (Eingabe: get_valve_status() und die
-- Uhr), M.new() zeichnet und blaettert. Kein Schalten, kein Speichern, kein
-- Funk.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local CONTENT_W = 79           -- Spalten 2..80
local LIST_FIRST_ROW = 11
local ROWS_PER_PAGE = 20       -- Zeilen 11..30
local ERROR_ROW = 32
local PAGER_ROW = 33           -- Knoepfe 33..34, Zeilen 36..37 frei, Footer 38..40

-- Spalten (x, Breite), zusammen 79 Zeichen ab x=2.
local COL = {
  state = { x = 2, w = 16 },
  name = { x = 18, w = 17 },
  id = { x = 35, w = 12 },
  heard = { x = 47, w = 11 },
  valve = { x = 58, w = 7 },
  reactors = { x = 65, w = 16 },
}

-- Zustand -> Reihenfolge (Probleme oben), Text, Farbe.
local LINK = {
  unknown = { rank = 1, text = "UNBEKANNT", key = "WARNING" },
  offline = { rank = 2, text = "OFFLINE", key = "EMERGENCY" },
  stale = { rank = 3, text = "NICHT AKTUELL", key = "LIMITED" },
  waiting = { rank = 5, text = "WARTET", key = "OFFLINE" },
  online = { rank = 6, text = "ONLINE", key = "OK" },
}
-- Online, aber das Ventil meldet einen Schreibfehler: vor die gesunden.
local RANK_ACK_ERROR = 4

local function pad(text, width)
  local s = mux.fit(tostring(text or ""), width)
  if #s < width then s = s .. string.rep(" ", width - #s) end
  return s
end

-- "zuletzt gehoert" in groben Stufen. Die Seite wird nur neu gezeichnet,
-- wenn sich ein angezeigter Text aendert -- ein Ventil, das alle 2 s
-- funkt, bleibt so ruhig auf "< 10 s" statt jede Sekunde neu zu zeichnen.
function M.format_heard(last_seen_ms, now_ms)
  if type(last_seen_ms) ~= "number" then return "nie" end
  local age_s = math.max(0, math.floor(((tonumber(now_ms) or last_seen_ms) - last_seen_ms) / 1000))
  if age_s < 10 then return "< 10 s" end
  if age_s < 60 then return string.format("vor %d s", math.floor(age_s / 10) * 10) end
  if age_s < 3600 then return string.format("vor %d min", math.floor(age_s / 60)) end
  return string.format("vor %d h", math.floor(age_s / 3600))
end

local function valve_text(entry)
  if entry.ack_applied == false then return "FEHLER", "EMERGENCY" end
  if entry.ack_applied == true then
    if entry.ack_high == true then return "ZU", "text" end
    if entry.ack_high == false then return "AUF", "LIMITED" end
  end
  if entry.ack_pending == true then
    local wanted = entry.requested_state == "OPEN" and "AUF?" or "ZU?"
    return wanted, "muted"
  end
  return "-", "muted"
end

-- Rein: aus get_valve_status() die fertigen Anzeigezeilen. Nur Text und
-- Farbschluessel -- das Ergebnis ist zugleich der Vergleichsstand fuer das
-- Neuzeichnen (siehe nodes/fuel/monitor_ui.lua).
function M.collect(valve_status, now_ms)
  local rows = {}
  local counts = { total = 0, online = 0, stale = 0, offline = 0, unknown = 0, waiting = 0, ack_error = 0 }
  local first_error = nil
  for _, entry in ipairs(type(valve_status) == "table" and valve_status or {}) do
    if type(entry) == "table" and entry.id ~= nil then
      local id = tostring(entry.id)
      local link = LINK[entry.link] and entry.link or (entry.online and "online" or "offline")
      local info = LINK[link]
      counts.total = counts.total + 1
      counts[link] = counts[link] + 1
      local rank = info.rank
      if entry.ack_applied == false then
        counts.ack_error = counts.ack_error + 1
        if not first_error then
          first_error = { id = id, text = tostring(entry.ack_error or "Ventil meldet: nicht geschaltet") }
        end
        if link == "online" then rank = RANK_ACK_ERROR end
      end
      local name = tostring(entry.label or id)
      if name == id then name = "-" end
      local reactors = "-"
      if type(entry.affected_routes) == "table" and #entry.affected_routes > 0 then
        local labels = {}
        for i, label in ipairs(entry.affected_routes) do labels[i] = tostring(label) end
        reactors = table.concat(labels, ", ")
      end
      local valve, valve_key = valve_text(entry)
      rows[#rows + 1] = {
        rank = rank, id = id, name = name,
        state = info.text, state_key = info.key,
        heard = M.format_heard(entry.last_seen_ms, now_ms),
        valve = valve, valve_key = valve_key,
        reactors = reactors,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.id < b.id
  end)

  local worst = "OK"
  if counts.unknown > 0 or counts.offline > 0 or counts.ack_error > 0 then
    worst = "WARNING"
  elseif counts.stale > 0 or counts.waiting > 0 then
    worst = "LIMITED"
  end
  if counts.total == 0 then worst = "LIMITED" end
  return { rows = rows, counts = counts, worst = worst, first_error = first_error }
end

local function write_line(mon, y, text, key)
  mux.text(mon, 2, y, pad(text, CONTENT_W), colorset.get(key or "text"), colorset.get("background"))
end

local function blank(mon, y)
  write_line(mon, y, "", "text")
end

local function cell(mon, col, y, text, key)
  mux.text(mon, col.x, y, pad(text, col.w), colorset.get(key or "text"), colorset.get("background"))
end

local function draw_row(mon, y, row)
  -- Zustand als farbiger Block, eine Leerspalte dahinter.
  mux.text(mon, COL.state.x, y, pad(" " .. row.state, COL.state.w - 1),
    colorset.get("background"), colorset.get(row.state_key))
  mux.text(mon, COL.state.x + COL.state.w - 1, y, " ", colorset.get("text"), colorset.get("background"))
  cell(mon, COL.name, y, row.name, "text")
  cell(mon, COL.id, y, row.id, "muted")
  cell(mon, COL.heard, y, row.heard, row.heard == "nie" and "WARNING" or "text")
  cell(mon, COL.valve, y, row.valve, row.valve_key)
  cell(mon, COL.reactors, y, row.reactors, "muted")
end

local LEGEND = {
  { "UNBEKANNT", "WARNING", "ID meldet sich nie -> ROUTER > Ventilkette neu einlernen" },
  { "OFFLINE", "EMERGENCY", "war da, ist weg -> VALVE-Node und Funk pruefen" },
  { "NICHT AKTUELL", "LIMITED", "Meldung ueberfaellig -> Chunk geladen? Funk pruefen" },
}

local function draw_legend(mon, y)
  for i, item in ipairs(LEGEND) do
    local row = y + i - 1
    blank(mon, row)
    mux.text(mon, 2, row, pad(item[1], 15), colorset.get(item[2]), colorset.get("background"))
    mux.text(mon, 17, row, mux.fit(item[3], CONTENT_W - 15), colorset.get("muted"), colorset.get("background"))
  end
end

local function hit(button, x, y)
  return button ~= nil and y >= button.y and y <= (button.y2 or button.y)
    and x >= button.x1 and x <= button.x2
end

function M.new(_opts)
  local state = { page = 1, prev = nil, next = nil, pages = 1 }
  local self = {}

  -- data: Ergebnis von M.collect(), oder nil (noch nicht geladen / kein
  -- Router). page_label: "4/5".
  function self.render(mon, model, should_clear, data, page_label)
    if not mon or type(mon.getSize) ~= "function" then return false end
    local ok_size, w, h = pcall(mon.getSize)
    if not ok_size or w ~= TARGET_W or h ~= TARGET_H then return false end
    if should_clear == true then mux.clear(mon) end

    local view = data or { rows = {}, counts = { total = 0 }, worst = "LIMITED" }
    local counts = view.counts or {}
    mux.header(mon, {
      title = "FUEL NODE - VENTILE", node_id = model and model.node_id or "FUEL-?",
      page = page_label or "", status = view.worst or "LIMITED", icon = "fuel",
    })

    local summary
    if data == nil then
      summary = "VENTILE WERDEN GELADEN ..."
    elseif (counts.total or 0) == 0 then
      summary = "KEINE VENTILE KONFIGURIERT -- ROUTER > REAKTOR > VENTILKETTE"
    else
      summary = string.format("%d VENTILE  ONLINE %d  NICHT AKTUELL %d  OFFLINE %d  UNBEKANNT %d  WARTET %d",
        counts.total or 0, counts.online or 0, counts.stale or 0, counts.offline or 0,
        counts.unknown or 0, counts.waiting or 0)
    end
    mux.banner(mon, 2, 4, CONTENT_W, mux.fit(summary, CONTENT_W - 2), view.worst or "LIMITED",
      view.worst == "OK" and "ok" or "warning")

    blank(mon, 5)
    draw_legend(mon, 6)
    mux.table_header(mon, 2, 9, CONTENT_W, {
      { label = "ZUSTAND", width = COL.state.w }, { label = "NAME", width = COL.name.w },
      { label = "ID", width = COL.id.w }, { label = "ZULETZT", width = COL.heard.w },
      { label = "VENTIL", width = COL.valve.w }, { label = "REAKTOREN", width = COL.reactors.w },
    })

    local rows = view.rows or {}
    state.pages = math.max(1, math.ceil(#rows / ROWS_PER_PAGE))
    if state.page > state.pages then state.page = state.pages end
    if state.page < 1 then state.page = 1 end
    local first = (state.page - 1) * ROWS_PER_PAGE
    for slot = 1, ROWS_PER_PAGE do
      local y = LIST_FIRST_ROW + slot - 1
      local row = rows[first + slot]
      if row then draw_row(mon, y, row) else blank(mon, y) end
    end

    blank(mon, ERROR_ROW - 1)
    if view.first_error then
      local more = (counts.ack_error or 0) > 1
        and string.format(" (+%d weitere)", counts.ack_error - 1) or ""
      write_line(mon, ERROR_ROW, "VENTIL-FEHLER " .. view.first_error.id .. ": "
        .. view.first_error.text .. more, "EMERGENCY")
    else
      blank(mon, ERROR_ROW)
    end

    blank(mon, PAGER_ROW); blank(mon, PAGER_ROW + 1); blank(mon, PAGER_ROW + 2)
    state.prev, state.next = nil, nil
    if state.pages > 1 then
      if state.page > 1 then
        state.prev = mux.button(mon, 4, PAGER_ROW, 12, "<< SEITE", "LIMITED", 2)
      end
      if state.page < state.pages then
        state.next = mux.button(mon, 67, PAGER_ROW, 12, "SEITE >>", "LIMITED", 2)
      end
      local page_text = string.format("VENTILE %d-%d VON %d", first + 1,
        math.min(first + ROWS_PER_PAGE, #rows), #rows)
      mux.text(mon, math.floor((TARGET_W - #page_text) / 2) + 1, PAGER_ROW + 1, page_text,
        colorset.get("muted"), colorset.get("background"))
    end
    return true
  end

  function self.handle_touch(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    if hit(state.prev, x, y) then
      state.page = math.max(1, state.page - 1)
      return true
    end
    if hit(state.next, x, y) then
      state.page = math.min(state.pages, state.page + 1)
      return true
    end
    return false
  end

  function self.get_state()
    return { page = state.page, pages = state.pages, prev = state.prev, next = state.next }
  end

  return self
end

M.ROWS_PER_PAGE = ROWS_PER_PAGE

return M
