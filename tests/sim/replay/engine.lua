-- tests/sim/replay/engine.lua  Phase 8.2
-- Spielt Peripheral-Calls als Antworten in den Simulator ein.
-- Vergleicht aufgezeichnete Entscheidungen mit aktuell getroffenen.

local M = {}

-- Replay-Source: gibt für jeden Peripheral-Call die aufgezeichnete Antwort zurück
function M.make_peripheral_replay(trace_entries)
  -- Index: device_name → method → Queue von Antworten
  local queues = {}
  for _, e in ipairs(trace_entries) do
    if e.kind == "peripheral_call" then
      local k = e.data.name .. ":" .. e.data.method
      if not queues[k] then queues[k] = {} end
      queues[k][#queues[k]+1] = e.data.result or {}
    end
  end
  local positions = {}

  return {
    -- Nächste aufgezeichnete Antwort abrufen
    next = function(device_name, method)
      local k = device_name .. ":" .. method
      local q = queues[k]
      if not q then return nil end
      positions[k] = (positions[k] or 0) + 1
      return q[positions[k]]
    end,
    -- Verbleibende Antworten (für Vollständigkeitsprüfung)
    remaining = function(device_name, method)
      local k = device_name .. ":" .. method
      local q = queues[k] or {}
      local pos = positions[k] or 0
      return #q - pos
    end,
  }
end

-- Entscheidungsvergleich: aufgezeichnet vs. aktuell
-- tolerance: absolute Abweichung für numerische Werte
function M.compare_decisions(recorded, actual, tolerance)
  tolerance = tolerance or 0
  local mismatches = {}
  local n = math.min(#recorded, #actual)

  for i = 1, n do
    local rec = recorded[i]
    local act = actual[i]
    if rec.data.kind ~= act.kind then
      mismatches[#mismatches+1] = {
        index = i,
        tick  = rec.t,
        issue = "kind mismatch: rec=" .. tostring(rec.data.kind) ..
                " act=" .. tostring(act.kind),
      }
    elseif type(rec.data.value) == "number" and type(act.value) == "number" then
      if math.abs(rec.data.value - act.value) > tolerance then
        mismatches[#mismatches+1] = {
          index = i,
          tick  = rec.t,
          issue = string.format("value delta %.4f > tolerance %.4f (rec=%.4f act=%.4f)",
            math.abs(rec.data.value - act.value), tolerance,
            rec.data.value, act.value),
        }
      end
    elseif rec.data.value ~= act.value then
      mismatches[#mismatches+1] = {
        index = i,
        tick  = rec.t,
        issue = "value mismatch: rec=" .. tostring(rec.data.value) ..
                " act=" .. tostring(act.value),
      }
    end
  end

  if #recorded ~= #actual then
    mismatches[#mismatches+1] = {
      index = n + 1,
      issue = string.format("count mismatch: recorded=%d actual=%d", #recorded, #actual),
    }
  end

  return { ok = #mismatches == 0, mismatches = mismatches }
end

-- Replay laufen lassen: Trace → Simulator → Vergleich
function M.run(trace, sim_fn, opts)
  opts = opts or {}
  local loader = dofile("tests/sim/replay/loader.lua")
  loader.validate(trace)

  local recorded_decisions = loader.decisions(trace)
  local peripheral_src     = M.make_peripheral_replay(trace.entries)

  -- sim_fn(peripheral_src, opts) → { decisions=[] }
  local sim_result = sim_fn(peripheral_src, opts)

  local cmp = M.compare_decisions(
    recorded_decisions,
    sim_result.decisions or {},
    opts.tolerance or 0
  )

  return {
    ok             = cmp.ok,
    mismatches     = cmp.mismatches,
    recorded_count = #recorded_decisions,
    actual_count   = #(sim_result.decisions or {}),
  }
end

return M
