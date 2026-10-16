-- Regressionstest: MASTERs Notfall-Schwelle darf nicht unter der
-- Betriebstemperatur liegen.
--
-- master/startup_sequencer.lua's handle_timeout() entscheidet ueber
-- should_emergency(), ob ein Startup-Timeout als EMERGENCY oder als
-- LIMITED gilt. Das ist kein Kosmetikunterschied: bei EMERGENCY verwirft
-- der Sequencer die GANZE Warteschlange, schickt MODE=EMERGENCY an die
-- Node und meldet einen CRITICAL-Alarm.
--
-- Zwei Fehler lagen dort uebereinander:
--
--   1. Die Schwelle war 950 °C. Ein Extreme-Reactors-Reaktor laeuft unter
--      Last darueber, und die RT-Node selbst loest erst bei 2000 aus
--      (nodes/rt/config.lua: safety.max_temperature). MASTER erklaerte
--      also einen voellig gesunden Reaktor fuer kritisch -- bei JEDEM
--      Timeout.
--   2. master/config.lua trug zwar DEFAULT_SEQUENCER_SCRAM_TEMPERATURE,
--      legte den Wert aber nie auf den Schluessel, den der Sequencer
--      liest (config.scram_temperature). Die Konstante war toter Code;
--      es griff immer der eingebaute Ersatzwert.

local REPO = os.getenv("REPO_ROOT") or "."
if type(package) == "table" and type(package.path) == "string" then
  package.path = REPO .. "/xreactor/?.lua;" .. REPO .. "/xreactor/?/init.lua;" .. package.path
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local constants = require("shared.constants")
local sequencer_lib = require("master.startup_sequencer")
local master_config = require("master.config")
local rt_config = require("nodes.rt.config")

------------------------------------------------------------------------------
-- 1. Die Schwelle muss die RT-Node ueberhaupt erreichen koennen.
------------------------------------------------------------------------------

local rt_trip = rt_config.DEFAULTS and rt_config.DEFAULTS.safety
  and rt_config.DEFAULTS.safety.max_temperature
if rt_trip == nil then
  -- Der Schluessel liegt je nach Fassung flach oder unter DEFAULTS.
  rt_trip = rt_config.safety and rt_config.safety.max_temperature
end
check(type(rt_trip) == "number",
  "Vorbedingung: die RT-Node muss eine Ausloeseschwelle haben (gefunden: " .. tostring(rt_trip) .. ")")

-- master/config.lua gibt die Vorgabetabelle selbst zurueck; der Sequencer
-- liest daraus config.scram_temperature. Fehlt der Schluessel, faellt er
-- still auf seinen eingebauten Ersatzwert zurueck -- genau das war Fehler 2.
local master_trip = master_config.scram_temperature
check(type(master_trip) == "number",
  "die Vorgabetabelle muss scram_temperature fuehren -- sonst ist"
    .. " DEFAULT_SEQUENCER_SCRAM_TEMPERATURE toter Code und der Sequencer nimmt seinen"
    .. " Ersatzwert (ist: " .. tostring(master_trip) .. ")")

check(type(master_trip) == "number" and rt_trip and master_trip >= rt_trip,
  "MASTERs Notfall-Schwelle (" .. tostring(master_trip) .. ") darf nicht unter der"
    .. " Ausloeseschwelle der RT-Node (" .. tostring(rt_trip) .. ") liegen -- sonst erklaert"
    .. " MASTER einen Reaktor fuer kritisch, den die Node zu Recht weiterfaehrt")

master_trip = tonumber(master_trip) or 0

------------------------------------------------------------------------------
-- 3. Verhalten: ein Timeout bei BETRIEBStemperatur ist LIMITED, kein Notfall.
------------------------------------------------------------------------------

local function run_timeout(max_temp, config)
  local sent, alerts = {}, {}
  local comms = {
    send_command = function(_, node_id, payload, opts)
      table.insert(sent, { node_id = node_id, payload = payload, opts = opts })
    end,
  }
  local seq = sequencer_lib.new(comms, "NORMAL", {
    timeout_s = 0,
    config = config,
    alert_service = { alerts = { raise = function(entry) table.insert(alerts, entry) end } },
  })
  seq:enqueue("RT-1", "DISCOVERY")
  local nodes = {
    ["RT-1"] = {
      id = "RT-1", mode = "MASTER", status = "OK",
      snapshot = { max_temp = max_temp },
      modules = { ["turbine:X"] = { state = "OFF" } },
    },
  }
  seq:tick(nodes)   -- sendet STARTUP_STAGE, geht auf WAITING_ACK
  seq:tick(nodes)   -- timeout_s = 0 -> laeuft sofort ab
  return sent, alerts
end

local defaults = master_config

do
  -- 1200 °C: ueber der alten 950er-Schwelle, klar unter der Ausloesung der
  -- Node. Genau der Bereich, in dem ein Reaktor unter Last steht.
  local sent = run_timeout(1200, defaults)
  check(#sent == 2, "nach dem Timeout muss ein MODE-Kommando folgen (got " .. #sent .. ")")
  if #sent == 2 then
    check(sent[2].payload.value == constants.node_states.LIMITED,
      "ein Timeout bei Betriebstemperatur (1200 °C) muss LIMITED melden, nicht EMERGENCY (got "
        .. tostring(sent[2].payload.value) .. ")")
  end
end

do
  -- Und die Gegenprobe: oberhalb der Schwelle bleibt es ein Notfall.
  local sent = run_timeout(master_trip + 100, defaults)
  if #sent == 2 then
    check(sent[2].payload.value == constants.node_states.EMERGENCY,
      "oberhalb der Schwelle muss EMERGENCY erhalten bleiben (got "
        .. tostring(sent[2].payload.value) .. ")")
  end
end

do
  -- Ohne Konfiguration greift der eingebaute Ersatzwert. Auch der darf
  -- nicht unter der Betriebstemperatur liegen -- er war die Stelle, an der
  -- die 950 ueberhaupt wirksam wurden.
  local sent = run_timeout(1200, nil)
  if #sent == 2 then
    check(sent[2].payload.value == constants.node_states.LIMITED,
      "auch ohne Konfiguration darf 1200 °C kein Notfall sein (got "
        .. tostring(sent[2].payload.value) .. ")")
  end
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
