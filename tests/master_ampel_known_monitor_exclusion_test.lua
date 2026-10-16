-- MASTER's whole-installation ampel (optional/master_ampel.lua) used to
-- have no exclusion list at all: every ~60s scan flipped setTextScale to 1
-- on and printed a "kein Treffer" diagnostic for EVERY monitor on MASTER's
-- network, including its own overview/rt/energy displays and any AUX
-- monitor -- none of which can ever be the ampel. This verifies the fix:
-- monitors already bound as a MASTER session (from view_manager.sessions)
-- are skipped entirely (no scale probe, no print), and a genuine unknown
-- non-matching candidate only gets its diagnostic line printed once, not
-- on every repeated scan.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.colors = _G.colors or { green = 1, yellow = 2, orange = 3, red = 4, gray = 5 }

local clock_now = 0
_G.os = _G.os or {}
os.clock = function() return clock_now end

local scale_calls = {}
local printed = {}
local real_print = print
print = function(...)
  local parts = { ... }
  printed[#printed + 1] = table.concat((function()
    local out = {}
    for i, v in ipairs(parts) do out[i] = tostring(v) end
    return out
  end)(), " ")
end

local function make_mon(name, w, h)
  return {
    getTextScale = function() return 1 end,
    setTextScale = function(s) scale_calls[#scale_calls + 1] = { name = name, scale = s } end,
    getSize = function() return w, h end,
    setBackgroundColor = function() end,
    clear = function() end,
  }
end

-- "overview"/"rt"/"energy" are MASTER's own bound primary displays (large,
-- never ampel-shaped); "aux_1" is a bound AUX monitor; "candidate" is a
-- genuine unbound monitor that doesn't match the ampel shape either.
local mons = {
  overview = make_mon("overview", 80, 30),
  rt = make_mon("rt", 80, 30),
  energy = make_mon("energy", 80, 30),
  aux_1 = make_mon("aux_1", 60, 25),
  candidate = make_mon("candidate", 12, 12),
}

_G.peripheral = {
  getNames = function()
    return { "overview", "rt", "energy", "aux_1", "candidate" }
  end,
  getType = function(name) return "monitor" end,
  wrap = function(name) return mons[name] end,
}

package.loaded['optional.master_ampel'] = nil
local master_ampel = require('optional.master_ampel')

local bound_sessions = {
  { name = "overview" }, { name = "rt" }, { name = "energy" }, { name = "aux_1" },
}
local runtime = {
  state = { rt_global_off_hold = false, power_target = 100, active_profile = "BASELOAD", nodes = {} },
  refs = {
    alert_service = { get_counts = function() return {} end },
    view_manager = {
      sessions = { get_sessions = function() return bound_sessions end },
    },
  },
}
local constants = { roles = { RT_NODE = "RT-NODE" } }

master_ampel.update(runtime, constants)

for _, call in ipairs(scale_calls) do
  if call.name == "overview" or call.name == "rt" or call.name == "energy" or call.name == "aux_1" then
    error("known/bound monitor " .. call.name .. " must never have its TextScale probed")
  end
end
-- Two calls expected against the sole unbound candidate: the scale=1
-- probe itself, then restoring its original scale after the non-match.
if #scale_calls ~= 2 then
  error("expected exactly 2 scale calls (probe + restore), got " .. #scale_calls)
end
for _, call in ipairs(scale_calls) do
  if call.name ~= "candidate" then
    error("scale call touched a monitor other than the unbound candidate: " .. call.name)
  end
end

local candidate_prints = 0
for _, line in ipairs(printed) do
  if line:find("candidate", 1, true) then candidate_prints = candidate_prints + 1 end
  if line:find("overview", 1, true) or line:find("[ %[]rt[ %]]") or line:find("energy", 1, true) or line:find("aux_1", 1, true) then
    error("must never print a diagnostic for a known/bound monitor, got: " .. line)
  end
end
if candidate_prints ~= 1 then
  error("expected exactly one diagnostic line for the unbound candidate, got " .. candidate_prints)
end

-- Advance past the 60s probe interval and update() again: the candidate is
-- still not ampel-shaped, so it gets re-scanned, but must NOT print again.
clock_now = clock_now + 61
master_ampel.update(runtime, constants)
local candidate_prints_after = 0
for _, line in ipairs(printed) do
  if line:find("candidate", 1, true) then candidate_prints_after = candidate_prints_after + 1 end
end
if candidate_prints_after ~= 1 then
  error("diagnostic for an already-seen non-matching candidate must not repeat on a later scan, got " .. candidate_prints_after)
end

print = real_print
print('master_ampel_known_monitor_exclusion_test.lua: ok')
