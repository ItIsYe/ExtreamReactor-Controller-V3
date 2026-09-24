-- Jede Turbine vermisst sich selbst: wieviel Drehzahl ein mB/t Dampf bei
-- gekuppelter Spule wert ist.
--
-- WARUM: rt2_turbine.lua regelt den Durchfluss bisher in festen Schritten
-- (TRIM_STEP) gegen eine Drehzahl, deren Zusammenhang mit dem Durchfluss
-- es nicht kennt. Das ist ein reiner Integrator ohne Streckenwissen, und
-- ein solcher Regler kann gar nicht anders als zu pendeln: er faehrt den
-- Durchfluss hoch, bis die Drehzahl ueber dem Ziel steht, dann wieder
-- runter, bis sie darunter steht. Dass alle Turbinen denselben Schritt
-- benutzen, macht es schlimmer -- eine grosse Turbine mit viel
-- Rotortraegheit braucht eine voellig andere Stellgroesse als eine kleine.
--
-- Diese Zahlen stehen nicht im Code, weil sie von der Anlage abhaengen,
-- die jemand gebaut hat. Sie lassen sich aber messen.
--
-- WIE: rein beobachtend, wie rt2_tuning.lua beim Reaktor -- kein
-- aufgezwungenes Stoersignal. Steht der Durchfluss eine Weile still
-- (dafuer sorgt rt2_turbine.MIN_ADJUST_INTERVAL_MS) und dreht der Rotor
-- dabei gleichmaessig, ist das ein Betriebspunkt: dieser Durchfluss
-- traegt diese Drehzahl. Eine Ausgleichsgerade durch diese Paare ergibt
--
--     Drehzahl = slope * Durchfluss + intercept
--
-- und damit beides, was dem Regler bisher fehlte:
--
--   * den Durchfluss, der eine gewuenschte Drehzahl traegt
--     (Vorsteuerung -- statt sich dorthin hochzutasten)
--   * die richtige SCHRITTWEITE fuer eine Abweichung: ein Fehler von
--     x RPM verlangt x/slope mB/t, nicht pauschal TRIM_STEP
--
-- Gemessen wird NUR mit gekuppelter Spule. Das ist der Zustand, in dem
-- die Anlage arbeitet, und der, in dem gependelt wurde; ohne Last gilt
-- eine ganz andere Gerade. Beim Hochfahren (Spule offen) bleibt es
-- deshalb bei der alten, monotonen Rampe.
--
-- Rein: observe() nimmt Zustand und Messwert und gibt einen neuen Zustand
-- zurueck, derive() macht daraus ein Profil. Keine Uhr, keine Peripherie,
-- keine Dateien.

local M = {}

-- Eine Gerade durch wenige, eng beieinander liegende Punkte ist beliebig.
M.MIN_SAMPLES = 8
M.MIN_FLOW_SPREAD = 40   -- mB/t zwischen kleinstem und groesstem Messpunkt

-- So lange muss der Durchfluss stillstehen, bevor die Drehzahl als zu ihm
-- gehoerig gilt. Der Rotor hat Traegheit; eine Messung unmittelbar nach
-- einer Verstellung beschreibt noch den vorherigen Betriebspunkt.
M.MIN_HOLD_MS = 1200
-- ...und nicht zu lange: ein Anker, der eine Beobachtungspause ueberlebt
-- hat (SAFE, fehlende Messung), wuerde sonst gegen einen Messwert aus
-- einem voellig anderen Betriebszustand verrechnet.
M.MAX_HOLD_MS = 20000

-- Der Rotor gilt als eingeschwungen, wenn er sich weniger als das bewegt.
M.STEADY_RPM_PER_S = 4

-- Unterhalb dieser Drehzahl ist der Zusammenhang nicht mehr linear (und
-- eine stehende, nur gebremste Turbine wuerde die Gerade in den Ursprung
-- ziehen).
M.MIN_SAMPLE_RPM = 100

-- Harte Grenzen. Ein schlechter Fit darf nie einen gefaehrlichen Regler
-- erzeugen, also wird die Steigung in einen Bereich geklemmt, der auch
-- dann sicher ist, wenn die Messung Unsinn war. 0.05 RPM je mB/t hiesse
-- 18000 mB/t fuer 900 RPM (jenseits jeder Turbine), 20 hiesse 45 mB/t.
M.MIN_SLOPE, M.MAX_SLOPE = 0.05, 20

-- Abgeleitetes Stellintervall: so lange wartet der Regler zwischen zwei
-- Verstellungen. Gemessen wird, wie lange der Rotor tatsaechlich zum
-- Einschwingen brauchte.
M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS = 400, 4000

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

function M.new_state()
  return {
    n = 0, sum_x = 0, sum_y = 0, sum_xy = 0, sum_xx = 0,
    flow_min = nil, flow_max = nil,
    sum_settle_ms = 0,
    -- Der Durchfluss, zu dem zuletzt ein Messpunkt aufgenommen wurde.
    -- Solange er sich nicht aendert, bringt ein weiterer Punkt am selben
    -- Ort keine Information, wuerde die Gerade aber dorthin ziehen, wo
    -- die Anlage zufaellig am laengsten stand.
    last_sampled_flow = nil,
    anchor_flow = nil, anchor_rpm = nil, anchor_ms = nil,
  }
end

-- reading: { now_ms, flow, rpm, coil_engaged }
function M.observe(state, reading)
  state = type(state) == "table" and state or M.new_state()
  reading = type(reading) == "table" and reading or {}

  local now_ms = tonumber(reading.now_ms)
  local flow = tonumber(reading.flow)
  local rpm = tonumber(reading.rpm)

  local next_state = copy(state)
  local function drop()
    next_state.anchor_flow, next_state.anchor_rpm, next_state.anchor_ms = nil, nil, nil
    return next_state
  end
  local function reanchor()
    next_state.anchor_flow, next_state.anchor_rpm, next_state.anchor_ms = flow, rpm, now_ms
    return next_state
  end

  -- Ohne Last gilt eine andere Gerade, und ohne vollstaendige Messung gar
  -- keine. Beides beendet die laufende Beobachtung, statt sie zu
  -- verfaelschen.
  if reading.coil_engaged ~= true then return drop() end
  if not (now_ms and flow and rpm) then return drop() end
  if rpm < M.MIN_SAMPLE_RPM then return drop() end

  if state.anchor_flow == nil or state.anchor_flow ~= flow then return reanchor() end

  local elapsed_ms = now_ms - (state.anchor_ms or now_ms)
  if elapsed_ms <= 0 then return reanchor() end
  -- Noch nicht lange genug: Anker HALTEN und weiter Zeit sammeln.
  if elapsed_ms < M.MIN_HOLD_MS then return next_state end
  -- Zu lange: der Anker hat eine Pause ueberlebt, also neu ansetzen.
  if elapsed_ms > M.MAX_HOLD_MS then return reanchor() end

  -- Dreht der Rotor noch hoch oder runter, gehoert diese Drehzahl noch
  -- nicht zu diesem Durchfluss. Anker halten und weiter warten.
  local drift = math.abs(rpm - (state.anchor_rpm or rpm)) / (elapsed_ms / 1000)
  if drift > M.STEADY_RPM_PER_S then return next_state end

  if state.last_sampled_flow == flow then return next_state end

  next_state.n = state.n + 1
  next_state.sum_x = state.sum_x + flow
  next_state.sum_y = state.sum_y + rpm
  next_state.sum_xy = state.sum_xy + flow * rpm
  next_state.sum_xx = state.sum_xx + flow * flow
  next_state.flow_min = math.min(state.flow_min or flow, flow)
  next_state.flow_max = math.max(state.flow_max or flow, flow)
  next_state.sum_settle_ms = state.sum_settle_ms + elapsed_ms
  next_state.last_sampled_flow = flow
  return reanchor()
end

function M.spread(state)
  if not (state and state.flow_min and state.flow_max) then return 0 end
  return state.flow_max - state.flow_min
end

-- Returns a profile table, or nil plus a reason string.
function M.derive(state)
  state = type(state) == "table" and state or M.new_state()

  if state.n < M.MIN_SAMPLES then
    return nil, string.format("zu wenige Betriebspunkte: %d von %d", state.n, M.MIN_SAMPLES)
  end
  local spread = M.spread(state)
  if spread < M.MIN_FLOW_SPREAD then
    return nil, string.format("Durchfluesse zu eng beieinander: %.0f statt %d mB/t",
      spread, M.MIN_FLOW_SPREAD)
  end

  local n = state.n
  local denominator = n * state.sum_xx - state.sum_x * state.sum_x
  if denominator == 0 then return nil, "Steigung nicht bestimmbar" end
  local slope = (n * state.sum_xy - state.sum_x * state.sum_y) / denominator
  if slope < M.MIN_SLOPE or slope > M.MAX_SLOPE then
    return nil, string.format("unplausible Steigung: %.3f RPM je mB/t", slope)
  end
  local intercept = (state.sum_y - slope * state.sum_x) / n

  local settle_ms = state.sum_settle_ms / n
  return {
    slope = slope,                 -- RPM je mB/t
    intercept = intercept,         -- RPM bei Durchfluss 0 (rechnerisch)
    min_adjust_interval_ms = math.floor(clamp(settle_ms, M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS) + 0.5),
    samples = n,
    flow_spread = spread,
  }
end

-- Der Durchfluss, der laut Profil diese Drehzahl traegt. nil, wenn kein
-- brauchbares Profil vorliegt.
function M.flow_for(profile, target_rpm)
  if type(profile) ~= "table" then return nil end
  local slope = tonumber(profile.slope)
  local target = tonumber(target_rpm)
  if not slope or slope <= 0 or not target then return nil end
  local flow = (target - (tonumber(profile.intercept) or 0)) / slope
  if flow ~= flow then return nil end -- NaN
  return flow
end

-- ── Persistenz (duenne Huelle, gleiche Form wie rt2_tuning) ──────────────

local function sane(entry)
  if type(entry) ~= "table" then return nil end
  local slope = tonumber(entry.slope)
  local interval = tonumber(entry.min_adjust_interval_ms)
  if not slope or not interval then return nil end
  -- Beim Laden neu klemmen: eine von Hand editierte oder veraltete Datei
  -- darf den Regler nicht ueber das aufweiten, was die Ableitung darf.
  if slope < M.MIN_SLOPE or slope > M.MAX_SLOPE then return nil end
  return {
    slope = slope,
    intercept = tonumber(entry.intercept) or 0,
    min_adjust_interval_ms = clamp(interval, M.INTERVAL_MIN_MS, M.INTERVAL_MAX_MS),
    samples = tonumber(entry.samples) or 0,
    flow_spread = tonumber(entry.flow_spread) or 0,
  }
end

function M.load_units(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return {} end
  if type(opts.read_config) ~= "function" then return {} end
  local data = opts.read_config(opts.path)
  if type(data) ~= "table" or type(data.units) ~= "table" then return {} end
  local out = {}
  for key, entry in pairs(data.units) do
    if type(entry) == "table" and entry.modelled == true then
      local profile = sane(entry)
      if profile then out[key] = profile end
    end
  end
  return out
end

function M.save_units(profiles, opts)
  opts = opts or {}
  if type(profiles) ~= "table" then return false, "no profiles" end
  if type(opts.path) ~= "string" or opts.path == "" then return false, "no path" end
  if type(opts.write_config) ~= "function" then return false, "no writer" end
  local out = {}
  for key, profile in pairs(profiles) do
    if type(profile) == "table" and tonumber(profile.slope) then
      out[key] = {
        modelled = true,
        slope = profile.slope,
        intercept = tonumber(profile.intercept) or 0,
        min_adjust_interval_ms = tonumber(profile.min_adjust_interval_ms) or 0,
        samples = tonumber(profile.samples) or 0,
        flow_spread = tonumber(profile.flow_spread) or 0,
      }
    end
  end
  if next(out) == nil then return false, "nothing to save" end
  return opts.write_config(opts.path, { units = out })
end

return M
