local utils = require("core.utils")

local manager = {}

local function is_terminate_error(err)
  local message = tostring(err or ""):match("^%s*(.-)%s*$"):lower()
  return message == "terminate" or message == "terminated"
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
  state = { retries = 0, next_retry = 0, initialized = false }
  self.service_state[service] = state
  return state
end

local function clear_retry(state)
  state.retries = 0
  state.next_retry = 0
end

local function schedule_retry(self, service, index, state, stage, err)
  state.retries = (state.retries or 0) + 1
  local delay_ms = backoff_delay_ms(self, state.retries)
  state.next_retry = now_ms() + delay_ms
  utils.log(
    self.log_prefix,
    string.format(
      "Service %s failed (%s); retry in %.2fs: %s",
      tostring(stage),
      service_name(service, index),
      delay_ms / 1000,
      tostring(err)
    ),
    "ERROR"
  )
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

-- Fix (2026-07-14): CRITICAL. SHARED-P0 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). Ein Event-getriebener Aufruf (event ~= nil --
-- z.B. bei JEDEM einzelnen Modem-/Monitor-/Maus-/Tastendruck-Event aus
-- nodes/support/runtime.lua's run_event_loop() bzw. den analogen Event-
-- Loops in ENERGY/MASTER) fuehrte bisher IMMER den kompletten Service-
-- Manager aus: Discovery, Telemetry, Alert, Matrix-Sampling und jeder rein
-- periodische Ad-hoc-Service (z.B. "ampel_render", "valve_ack_retry",
-- "valve_failsafe") bekam dadurch bei einer Flut von Netzwerkpaketen ein
-- Vielfaches seiner eigentlich konfigurierten Tick-Rate zugemutet -- 1.000
-- Modemevents erzeugten 1.000 Discovery-/Telemetry-/Control-Zyklen statt
-- der beabsichtigten periodischen Rate. Jetzt bekommt ein Service seinen
-- tick() bei einem Event-Aufruf nur dann ueberhaupt aufgerufen, wenn er
-- sich explizit ueber service.wants_events = true dafuer angemeldet hat
-- (comms_service und ui_service melden sich standardmaessig selbst an,
-- siehe dort; einzelne rollenspezifische Ad-hoc-Services wie
-- "valve_channel" oder "valve_ack_listener" melden sich gezielt selbst
-- an, da sie echte Event-Reaktivitaet brauchen). Der reine periodische
-- Tick (event == nil, aus dem Timer-Zweig jeder Event-Loop) bleibt fuer
-- ALLE Services unveraendert -- kein Service verliert seine periodische
-- Arbeit, sie laeuft nur nicht mehr zusaetzlich bei jedem einzelnen Event.
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
