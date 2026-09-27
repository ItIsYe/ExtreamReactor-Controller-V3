-- Lokale Aufzeichnung dessen, was der Regler WIRKLICH tut.
--
-- Warum es das gibt: die Anlage zeigte wiederholt ein Bild, das der Code
-- nicht hergibt -- Durchfluss 0 auf der ganzen Flotte, waehrend Drehzahlen
-- gelesen wurden und die Kopfzeile LEARNING sagte. Log-Zeilen und
-- Bildschirm zeigen nur das Ergebnis. Was fehlt, ist die Kette: welcher
-- Messwert kam an, was hat der Regler daraus entschieden, ist das Schreiben
-- ueberhaupt losgegangen, und was hat die Hardware gemeldet.
--
-- Genau diese vier Dinge stehen hier. Besonders zwei, die bisher nirgends
-- auftauchten:
--
--   * `unchanged` -- der Regler schreibt NICHT, wenn der zurueckgelesene
--     Wert schon der gewuenschte ist. Luegt der Rueckmesswert, bleibt die
--     Turbine fuer immer falsch stehen, ohne eine einzige Fehlermeldung.
--   * die Rueckgabe von rt2_adapter.apply_turbine() -- sie sagt, ob der
--     Schreibaufruf geklappt hat. rt2_engine hat sie bisher verworfen.
--
-- Bauform: die Zeilen baut eine REINE Funktion (format_rows), die
-- Datei-Arbeit liegt daneben. So ist das Format testbar, ohne Dateisystem.
--
-- Datenmenge: bei 50 Turbinen und 10 Hz waeren es 500 Zeilen je Sekunde --
-- das laeuft jeder Platte ueber. Deshalb:
--   * eine Sammelzeile je Intervall (Default 1 s),
--   * Turbinenzeilen NUR bei Aenderung (Grund, unchanged, Schreibfehler,
--     Durchfluss 0 trotz Ziel) -- eine eingeschwungene Flotte schreibt
--     also fast nichts, eine zappelnde genau ihre Zappler,
--   * zusaetzlich ein voller Durchgang aller Turbinen im laengeren Takt
--     (Default 30 s), damit es auch einen Grundwahrheits-Abdruck gibt,
--   * eine Obergrenze je Takt, damit ein Sturm die Datei nicht sprengt;
--     unterdrueckte Zeilen werden gezaehlt und in der Sammelzeile gemeldet.

local M = {}

M.VERSION = 1

-- Spaltenkoepfe, damit die Datei ohne diese Quelle lesbar ist.
M.HEADER = table.concat({
  "# xreactor rt trace v" .. M.VERSION,
  "# T=Takt  R=Reaktor  U=Turbine",
  "# T,ms,tick,state,master_pct,max_active,cap_ready,cap_max,cap_sust,cap_at_target,"
    .. "n_turb,n_flow0,n_unchanged,n_model,n_dropped,n_suppressed",
  "# R,ms,name,fill,rods_is,rods_cmd,reason,temp,coolant,tripped,write_ok,write_err",
  "# U,ms,name,rpm,flow_is,target_rpm,flow_cmd,reason,unchanged,coil_is,coil_cmd,"
    .. "model,write_ok,write_err,coil_ok,coil_err",
  "# leeres Feld = kein Messwert (nil), NICHT 0",
}, "\n")

local function n(value)
  if type(value) ~= "number" then return "" end
  if value ~= value then return "nan" end
  if value == math.floor(value) then return string.format("%d", value) end
  return string.format("%.3f", value)
end

local function b(value)
  if value == true then return "1" end
  if value == false then return "0" end
  return ""
end

local function s(value)
  if value == nil then return "" end
  -- Kommas und Zeilenumbrueche wuerden die Spalten zerreissen.
  return (tostring(value):gsub("[,\r\n]", " "))
end

-- Der Fingerabdruck einer Turbinenentscheidung. Aendert er sich, ist die
-- Zeile interessant; bleibt er gleich, ist sie Wiederholung.
function M.turbine_signature(row)
  return table.concat({
    s(row.reason), b(row.unchanged), n(row.flow_cmd), n(row.target_rpm),
    b(row.coil_cmd), b(row.model), b(row.write_ok), s(row.write_err),
  }, "|")
end

-- Ein Takt -> Zeilen. Rein: kein Dateisystem, keine Uhr, kein Zustand
-- ausser dem, was der Aufrufer in `memory` mitgibt (und was diese
-- Funktion darin fortschreibt).
--
-- sample = {
--   ms, tick, state, master_pct, max_active, capacity = {...},
--   reactors = { { name, fill, rods_is, rods_cmd, reason, temp, coolant,
--                  tripped, write_ok, write_err }, ... },
--   turbines = { { name, rpm, flow_is, target_rpm, flow_cmd, reason,
--                  unchanged, coil_is, coil_cmd, model, write_ok,
--                  write_err, coil_ok, coil_err }, ... },
--   dropped = { name, ... },
-- }
-- opts = { full_sweep = bool, max_turbine_rows = number }
-- memory = { signatures = { [name] = string } }  -- wird fortgeschrieben
function M.format_rows(sample, opts, memory)
  opts = opts or {}
  memory = memory or {}
  memory.signatures = memory.signatures or {}
  local max_rows = tonumber(opts.max_turbine_rows) or 12
  local full_sweep = opts.full_sweep == true

  local rows = {}
  local ms = sample.ms

  local turbines = sample.turbines or {}
  local flow0, unchanged_count, model_count = 0, 0, 0
  local interesting = {}
  for _, t in ipairs(turbines) do
    if (tonumber(t.flow_cmd) or 0) == 0 then flow0 = flow0 + 1 end
    if t.unchanged == true then unchanged_count = unchanged_count + 1 end
    if t.model == true then model_count = model_count + 1 end

    local signature = M.turbine_signature(t)
    local changed = memory.signatures[t.name] ~= signature
    -- Ein fehlgeschlagenes Schreiben und ein stiller Nullfluss sind immer
    -- interessant, auch unveraendert: gerade das Verharren ist der Befund.
    local broken = t.write_ok == false or t.coil_ok == false
    local silent = (tonumber(t.target_rpm) or 0) > 0 and (tonumber(t.flow_cmd) or 0) == 0
    if full_sweep or changed or broken or silent then
      interesting[#interesting + 1] = t
    end
    memory.signatures[t.name] = signature
  end

  -- Die Sturmbremse gilt nur fuer aenderungsgetriebene Zeilen. Ein voller
  -- Durchgang ist eine bewusste, seltene Bestandsaufnahme -- ihn zu kappen
  -- hiesse, ihn nicht zu machen: genau die abgeschnittenen Turbinen waeren
  -- die, ueber die man nichts weiss.
  local limit = full_sweep and #interesting or max_rows
  local suppressed = 0
  if #interesting > limit then
    suppressed = #interesting - limit
  end

  local cap = sample.capacity or {}
  rows[#rows + 1] = table.concat({
    "T", n(ms), n(sample.tick), s(sample.state), n(sample.master_pct),
    n(sample.max_active), b(cap.ready), n(cap.max_output),
    n(cap.sustainable_turbines), n(cap.at_target),
    n(#turbines), n(flow0), n(unchanged_count), n(model_count),
    n(sample.dropped and #sample.dropped or 0), n(suppressed),
  }, ",")

  for _, r in ipairs(sample.reactors or {}) do
    rows[#rows + 1] = table.concat({
      "R", n(ms), s(r.name), n(r.fill), n(r.rods_is), n(r.rods_cmd),
      s(r.reason), n(r.temp), n(r.coolant), b(r.tripped),
      b(r.write_ok), s(r.write_err),
    }, ",")
  end

  for index, t in ipairs(interesting) do
    if index > limit then break end
    rows[#rows + 1] = table.concat({
      "U", n(ms), s(t.name), n(t.rpm), n(t.flow_is), n(t.target_rpm),
      n(t.flow_cmd), s(t.reason), b(t.unchanged), b(t.coil_is), b(t.coil_cmd),
      b(t.model), b(t.write_ok), s(t.write_err), b(t.coil_ok), s(t.coil_err),
    }, ",")
  end

  for _, name in ipairs(sample.dropped or {}) do
    rows[#rows + 1] = table.concat({ "D", n(ms), s(name) }, ",")
  end

  return rows
end

return M
