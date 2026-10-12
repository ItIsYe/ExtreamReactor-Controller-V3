local utils = require("core.utils")

local manager = {}

local function is_terminate_error(err)
  local message = tostring(err or ""):lower()
  return message:find("terminate", 1, true) ~= nil
end

local function rethrow_terminate(err)
  if is_terminate_error(err) then
    error(err, 0)
  end
end

local function now_ms()
  if os and os.epoch then
    return os.epoch("utc")
  end
  return math.floor((os.clock() or 0) * 1000)
end

local function service_name(service, index)
  if type(service) ~= "table" then
    return string.format("service#%d", tonumber(index) or -1)
  end
  local candidates = {
    service.name,
    service.service_name,
    service.log_prefix,
    service.id,
    service.kind
  }
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "string" and candidate ~= "" then
      return candidate
    end
  end
  return string.format("service#%d", tonumber(index) or -1)
end

local function backoff_delay_ms(config, retries)
  local base = math.max(0, tonumber(config.backoff_base_s) or 0.5)
  local cap = math.max(base, tonumber(config.backoff_cap_s) or 5)
  local exponent = math.max(0, (retries or 1) - 1)
  local delay = base * math.pow(2, exponent)
  return math.floor(math.min(delay, cap) * 1000)
end

local function ensure_state(self, service)
  local state = self.service_state[service]
  if state then
    return state
  end
  state = { retries = 0, next_retry = 0, initialized = false, total_failures = 0, discards = 0 }
  self.service_state[service] = state
  return state
end

local function clear_retry(state)
  state.retries = 0
  state.next_retry = 0
end

-- Abgeleiteten Zustand verwerfen, wenn ein Dienst wiederholt scheitert.
--
-- Bis v814 wiederholte schedule_retry() einen scheiternden tick() nur, mit
-- Backoff -- verworfen wurde dabei nie etwas. Scheiterte ein Dienst an
-- einem Zustand, den er sich selbst abgeleitet hatte (ein Cache, ein
-- gemerktes Handle), scheiterte er daran bis zum Neustart, alle paar
-- Sekunden aufs Neue.
--
-- Der Manager selbst haelt keine Handles; er weiss nicht, was ein Dienst
-- sich merkt. Deshalb fragt er den Dienst: wer
--   service:discard_derived_state(stage, err, failures_in_row)
-- anbietet, bekommt nach jeweils `discard_after_failures` (Vorgabe 3)
-- Fehlschlaegen von tick() in Folge die Gelegenheit, ihn zu verwerfen. Der
-- naechste Versuch beginnt dann frisch. Dienste ohne die Methode verhalten
-- sich wie bisher. init() wird bewusst NICHT neu gestartet: comms_service
-- baut darin Netzwerk und Comms-Objekt neu, auf die andere Teile der Node
-- Verweise halten -- das waere kein Verwerfen, sondern ein Abriss.
local function maybe_discard_derived_state(self, service, index, state, stage, err)
  if stage ~= "tick" then return end
  if type(service) ~= "table" or type(service.discard_derived_state) ~= "function" then return end
  local every = tonumber(self.discard_after_failures) or 0
  if every <= 0 or (state.retries % every) ~= 0 then return end
  local ok, discard_err = pcall(service.discard_derived_state, service, stage, err, state.retries)
  if not ok then
    rethrow_terminate(discard_err)
    utils.log(
      self.log_prefix,
      string.format("Service %s: verwerfen des abgeleiteten Zustands fehlgeschlagen: %s",
        service_name(service, index), tostring(discard_err)),
      "WARN"
    )
    return
  end
  state.discards = (state.discards or 0) + 1
  utils.log(
    self.log_prefix,
    string.format("Service %s: %d Fehler in Folge -- abgeleiteten Zustand verworfen (%d. Mal)",
      service_name(service, index), state.retries, state.discards),
    "WARN"
  )
end

local function schedule_retry(self, service, index, state, stage, err)
  state.retries = (state.retries or 0) + 1
  state.total_failures = (state.total_failures or 0) + 1
  local delay_ms = backoff_delay_ms(self, state.retries)
  state.next_retry = now_ms() + delay_ms
  -- Reihenfolge der Argumente: bis v814 standen Stufe und Name vertauscht
  -- ("Service tick failed (DISCOVERY)").
  utils.log(
    self.log_prefix,
    string.format(
      "Service %s failed (%s); retry in %.2fs: %s",
      service_name(service, index),
      tostring(stage),
      delay_ms / 1000,
      tostring(err)
    ),
    "ERROR"
  )
  maybe_discard_derived_state(self, service, index, state, stage, err)
end

function manager.new(opts)
  opts = opts or {}
  local self = {
    services = {},
    log_prefix = opts.log_prefix or "SERVICES",
    running = false,
    backoff_base_s = opts.backoff_base_s or 0.5,
    backoff_cap_s = opts.backoff_cap_s or 5,
    service_state = {},
    service_tick_warn_ms = opts.service_tick_warn_ms or 1200,
    manager_tick_warn_ms = opts.manager_tick_warn_ms or 1800,
    -- Siehe maybe_discard_derived_state(); 0 schaltet es ab.
    discard_after_failures = opts.discard_after_failures or 3,
    inter_service_hook = opts.inter_service_hook
  }
  return setmetatable(self, { __index = manager })
end

local function run_inter_service_hook(self, dt, event, phase, service, index)
  if type(self.inter_service_hook) ~= "function" then
    return
  end
  local ok, err = pcall(self.inter_service_hook, dt, event, phase, service, index)
  if not ok then
    rethrow_terminate(err)
    utils.log(self.log_prefix, "Inter-service hook failed: " .. tostring(err), "WARN")
  end
end

function manager:add(service)
  if type(service) == "table" and (service.name == nil or service.name == "") then
    service.name = service_name(service, #self.services + 1)
  end
  table.insert(self.services, service)
end

function manager:init()
  for index, service in ipairs(self.services) do
    local state = ensure_state(self, service)
    if service.init and not state.initialized then
      local ok, err = pcall(service.init, service)
      if not ok then
        rethrow_terminate(err)
        schedule_retry(self, service, index, state, "init", err)
      else
        state.initialized = true
        clear_retry(state)
      end
    end
  end
  self.running = true
end

-- Ein Service bekommt seinen tick() bei einem Event-Aufruf (event ~= nil)
-- nur dann aufgerufen, wenn er sich explizit ueber
-- service.wants_events = true angemeldet hat (comms_service/ui_service
-- standardmaessig; einzelne rollenspezifische Ad-hoc-Services gezielt
-- selbst) -- sonst wuerde jedes einzelne Modem-/Touch-/Tastendruck-Event
-- den kompletten Service-Manager (Discovery, Telemetry, Alert, ...) ein
-- Vielfaches seiner konfigurierten Tick-Rate ausfuehren lassen. Der reine
-- periodische Tick (event == nil) bleibt fuer alle Services unveraendert.
function manager:tick(dt, event)
  local tick_started = now_ms()
  run_inter_service_hook(self, dt, event, "tick_start")
  for index, service in ipairs(self.services) do
    run_inter_service_hook(self, dt, event, "before_service", service, index)
    local relevant = event == nil or (type(service) == "table" and service.wants_events == true)
    if relevant then
      local state = ensure_state(self, service)
      if state.next_retry > now_ms() then
        goto after_service
      end
      if service.init and not state.initialized then
        local ok, err = pcall(service.init, service)
        if not ok then
          rethrow_terminate(err)
          schedule_retry(self, service, index, state, "init", err)
          goto after_service
        end
        state.initialized = true
        clear_retry(state)
      end
      if service.tick then
        local service_tick_started = now_ms()
        local ok, err = pcall(service.tick, service, dt, event)
        local service_tick_duration = now_ms() - service_tick_started
        if service_tick_duration > self.service_tick_warn_ms then
          utils.log(
            self.log_prefix,
            string.format(
              "Service tick slow: %s took %dms (threshold=%dms)",
              service_name(service, index),
              service_tick_duration,
              self.service_tick_warn_ms
            ),
            "WARN"
          )
        end
        if not ok then
          rethrow_terminate(err)
          schedule_retry(self, service, index, state, "tick", err)
        else
          clear_retry(state)
        end
      end
    end
    ::after_service::
    run_inter_service_hook(self, dt, event, "after_service", service, index)
  end
  run_inter_service_hook(self, dt, event, "tick_end")
  local tick_duration = now_ms() - tick_started
  if tick_duration > self.manager_tick_warn_ms then
    utils.log(
      self.log_prefix,
      string.format("Service manager tick slow: %dms (threshold=%dms)", tick_duration, self.manager_tick_warn_ms),
      "WARN"
    )
  end
end

function manager:stop()
  for _, service in ipairs(self.services) do
    if service.stop then
      local ok, err = pcall(service.stop, service)
      if not ok then
        rethrow_terminate(err)
        utils.log(self.log_prefix, "Service stop failed: " .. tostring(err), "ERROR")
      end
    end
  end
  self.running = false
end

return manager
