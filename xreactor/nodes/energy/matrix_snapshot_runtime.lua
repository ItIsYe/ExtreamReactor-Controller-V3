local utils = require("core.utils")

local runtime = {}

local METRIC_ORDER = { "stored", "capacity", "input", "output" }

local function now_ms()
  return os.epoch("utc")
end

function runtime.new(opts)
  opts = opts or {}
  return setmetatable({
    log_prefix = opts.log_prefix or "ENERGY",
    config = opts.config or {},
    get_groups = opts.get_groups,
    heartbeat_pump = opts.heartbeat_pump,
    record_error = opts.record_error,
    debug_enabled = opts.debug_enabled == true,
    dynamic_cache = {},
    static_cache = {},
    component_diag = {},
    component_cursor = 1,
    last_throttle_log_ts = 0,
    last_snapshot = {
      ts = 0,
      matrices = {},
      total = { stored = 0, capacity = 0, percent = 0, input = nil, output = nil },
      freshness_ms = nil,
      stale = true,
      diag = { metric_calls = {}, metric_totals = {}, throttled = nil }
    },
    last_poll_ts = 0,
    group_signature = ""
  }, { __index = runtime })
end

function runtime:invalidate()
  self.dynamic_cache = {}
  self.static_cache = {}
  self.component_diag = {}
  self.last_snapshot = {
    ts = 0,
    matrices = {},
    total = { stored = 0, capacity = 0, percent = 0, input = nil, output = nil },
    freshness_ms = nil,
    stale = true,
    diag = { metric_calls = {}, metric_totals = {}, throttled = nil }
  }
  self.last_throttle_log_ts = 0
end

local function normalize_reason(reason)
  if reason == nil then
    return nil
  end
  local text = tostring(reason)
  if text == "missing_method" or text == "missing method" then
    return "api_variant"
  end
  if text:find("^nil_value", 1) then
    return "temporary_not_ready"
  end
  if text:find("^call_failed:", 1) then
    return "temporary_read_error"
  end
  if text:find("^unsupported_value:", 1) then
    return "unsupported_value"
  end
  return "temporary_read_error"
end

function runtime:update_component_diag(group, adapter, metric, reason, detail)
  local key = tostring(group.key) .. ":" .. tostring(metric)
  local previous = self.component_diag[key]
  if reason == nil then
    if previous then
      self.component_diag[key] = nil
      if self.debug_enabled then
        utils.log(self.log_prefix, ("Matrix component %s recovered (%s)"):format(tostring(metric), tostring(group.key)), "INFO")
      end
    end
    return
  end
  local stamp = reason .. ":" .. tostring(detail)
  if previous == stamp then
    return
  end
  self.component_diag[key] = stamp
  if not self.debug_enabled then
    return
  end
  local method_map = adapter and adapter.getComponentMethods and adapter:getComponentMethods() or {}
  local method_name = method_map and method_map[metric]
  utils.log(self.log_prefix, ("Matrix component %s unavailable (%s reader=%s): reason=%s detail=%s method=%s"):format(
    tostring(metric),
    tostring(group.key),
    tostring(group.reader and group.reader.name or "n/a"),
    tostring(reason),
    tostring(detail),
    tostring(method_name or "n/a")
  ), "WARN")
end

function runtime:group_key_signature(groups)
  local parts = {}
  for _, group in ipairs(groups or {}) do
    local reader = group.representative
    parts[#parts + 1] = table.concat({
      tostring(group.key),
      tostring(reader and reader.name or "n/a"),
      tostring(#(group.ports or {}))
    }, "|")
  end
  return table.concat(parts, ";")
end

function runtime:sync_group_caches(groups)
  local active = {}
  for _, group in ipairs(groups or {}) do
    active[tostring(group.key)] = true
  end
  for key in pairs(self.dynamic_cache) do
    if not active[key] then
      self.dynamic_cache[key] = nil
    end
  end
  for key in pairs(self.static_cache) do
    if not active[key] then
      self.static_cache[key] = nil
    end
  end
  local signature = self:group_key_signature(groups)
  if signature ~= self.group_signature then
    self.group_signature = signature
    self.last_snapshot.ts = 0
  end
end

local function read_metric(group, label, fn, record_error)
  if not fn then
    return nil, "missing method"
  end
  local value, err = fn()
  if err and type(record_error) == "function" then
    local reader_name = group.reader and group.reader.name or group.key
    record_error(tostring(reader_name) .. "." .. tostring(label), err)
  end
  return tonumber(value), err
end

function runtime:poll_due_metrics(now_ts, groups)
  local metric_poll_interval_ms = math.max(1, tonumber(self.config.matrix_metric_poll_interval) or 2.0) * 1000
  local metric_call_budget = math.max(1, math.floor(tonumber(self.config.matrix_metric_call_budget) or 3))
  local metric_time_budget_ms = math.max(100, math.floor(tonumber(self.config.matrix_metric_time_budget_ms) or 600))
  local slow_call_ms = math.max(50, tonumber(self.config.matrix_metric_slow_call_ms) or 150)
  local slow_poll_multiplier = math.max(1, tonumber(self.config.matrix_metric_slow_poll_multiplier) or 4.0)
  local per_matrix_budget = math.max(1, math.floor(tonumber(self.config.matrix_metric_per_matrix_budget) or 1))
  local throttle_log_interval_ms = math.max(1000, math.floor(tonumber(self.config.matrix_metric_throttle_log_interval_ms) or 5000))
  if #(groups or {}) <= 1 then
    -- In the single-matrix model we avoid artificial backlog by allowing one
    -- full metric sweep per poll window.
    per_matrix_budget = math.max(per_matrix_budget, #METRIC_ORDER)
  end

  local jobs = {}
  for _, group in ipairs(groups or {}) do
    local reader = group.representative
    local adapter = reader and reader.adapter
    group.reader = reader
    local cache_key = tostring(group.key)
    local cache = self.dynamic_cache[cache_key]
    if type(cache) ~= "table" then
      cache = {}
      self.dynamic_cache[cache_key] = cache
    end
    for _, metric in ipairs(METRIC_ORDER) do
      local getter = metric == "stored" and (adapter and adapter.getStored)
        or metric == "capacity" and (adapter and adapter.getCapacity)
        or metric == "input" and (adapter and adapter.getInput)
        or metric == "output" and (adapter and adapter.getOutput)
        or nil
      if getter then
        local last_ts = tonumber(cache[metric .. "_ts"]) or 0
        local last_duration = tonumber(cache[metric .. "_last_ms"]) or 0
        local cadence_multiplier = last_duration >= slow_call_ms and slow_poll_multiplier or 1
        local due = last_ts <= 0 or (now_ts - last_ts) >= math.floor(metric_poll_interval_ms * cadence_multiplier)
        if due then
          jobs[#jobs + 1] = {
            group = group,
            metric = metric,
            fn = getter,
            cache = cache,
            last_ms = last_duration
          }
        end
      end
    end
  end

  table.sort(jobs, function(a, b)
    if (a.last_ms or 0) ~= (b.last_ms or 0) then
      return (a.last_ms or 0) < (b.last_ms or 0)
    end
    return tostring(a.group.key) < tostring(b.group.key)
  end)

  local diag = { metric_calls = {}, metric_totals = {}, throttled = nil }
  local to_poll = math.min(metric_call_budget, #jobs)
  local polled = 0
  local poll_spent_ms = 0
  local per_matrix = {}

  local function append_metric_call(group, metric, duration_ms)
    if duration_ms < 80 then
      return
    end
    diag.metric_calls[#diag.metric_calls + 1] = {
      matrix = tostring(group.key),
      reader = tostring(group.reader and group.reader.name or "n/a"),
      metric = tostring(metric),
      ms = duration_ms
    }
    local metric_key = tostring(metric)
    diag.metric_totals[metric_key] = (diag.metric_totals[metric_key] or 0) + duration_ms
  end

  for _, job in ipairs(jobs) do
    if polled >= to_poll then break end
    if poll_spent_ms >= metric_time_budget_ms then break end
    local matrix_key = tostring(job.group.key)
    if (per_matrix[matrix_key] or 0) < per_matrix_budget then
      per_matrix[matrix_key] = (per_matrix[matrix_key] or 0) + 1
      polled = polled + 1
      if type(self.heartbeat_pump) == "function" then
        self.heartbeat_pump(now_ms())
      end
      local started_at = now_ms()
      local value, err = read_metric(job.group, job.metric, job.fn, self.record_error)
      local duration = now_ms() - started_at
      poll_spent_ms = poll_spent_ms + duration
      append_metric_call(job.group, job.metric, duration)
      if value ~= nil then
        job.cache[job.metric] = value
        job.cache["last_good_" .. job.metric] = value
        job.cache.last_good_ts = now_ts
      elseif job.cache["last_good_" .. job.metric] ~= nil then
        job.cache[job.metric] = job.cache["last_good_" .. job.metric]
      end
      job.cache[job.metric .. "_err"] = err
      job.cache[job.metric .. "_ts"] = now_ts
      job.cache[job.metric .. "_last_ms"] = duration
      if type(self.heartbeat_pump) == "function" then
        self.heartbeat_pump(now_ms())
      end
    end
  end

  if #jobs > polled then
    diag.throttled = {
      due = #jobs,
      polled = polled,
      deferred = #jobs - polled,
      per_matrix_budget = per_matrix_budget,
      time_budget_ms = metric_time_budget_ms,
      spent_ms = poll_spent_ms
    }
    if self.debug_enabled and (now_ts - (self.last_throttle_log_ts or 0) >= throttle_log_interval_ms) then
      utils.log(
        self.log_prefix,
        ("Matrix metric polling throttled: due=%d budget=%d deferred=%d per_matrix_budget=%d time_budget_ms=%d spent_ms=%d"):format(
          #jobs,
          polled,
          #jobs - polled,
          per_matrix_budget,
          metric_time_budget_ms,
          poll_spent_ms
        )
      )
      self.last_throttle_log_ts = now_ts
    end
  elseif self.debug_enabled and poll_spent_ms >= math.floor(metric_time_budget_ms * 0.85) and (now_ts - (self.last_throttle_log_ts or 0) >= throttle_log_interval_ms) then
    utils.log(self.log_prefix, ("Matrix metric polling near budget limit: due=%d polled=%d time_budget_ms=%d spent_ms=%d"):format(
      #jobs,
      polled,
      metric_time_budget_ms,
      poll_spent_ms
    ), "WARN")
    self.last_throttle_log_ts = now_ts
  end

  return diag
end

function runtime:poll_static_components(now_ts, groups)
  local component_poll_interval_ms = math.max(1, tonumber(self.config.matrix_component_poll_interval) or 30) * 1000
  local component_call_budget = math.max(1, math.floor(tonumber(self.config.matrix_component_call_budget) or 2))
  -- P3: Fallback auf 2000ms (konsistent mit main.lua Default und config.DEFAULT_MATRIX_COMPONENT_TIME_BUDGET_MS)
  local component_time_budget_ms = math.max(50, math.floor(tonumber(self.config.matrix_component_time_budget_ms) or 2000))
  local ordered = groups or {}
  if #ordered == 0 then
    return
  end
  local calls = 0
  local spent_ms = 0
  local start_index = math.max(1, math.min(self.component_cursor or 1, #ordered))
  local inspected = 0
  local idx = start_index
  while inspected < #ordered do
    local group = ordered[idx]
    inspected = inspected + 1
    idx = (idx % #ordered) + 1
    local reader = group.representative
    local adapter = reader and reader.adapter
    local key = tostring(group.key)
    local cache = self.static_cache[key]
    if type(cache) ~= "table" then
      cache = {}
      self.static_cache[key] = cache
    end
    local should_poll = (cache.ts or 0) <= 0 or (now_ts - cache.ts) >= component_poll_interval_ms
    if should_poll and calls < component_call_budget and spent_ms < component_time_budget_ms then
      if type(self.heartbeat_pump) == "function" then
        self.heartbeat_pump(now_ms())
      end
      local started_at = now_ms()
      local cells, cells_err = read_metric(group, "cells", adapter and adapter.features and adapter.features.cells and adapter.getCells or nil, self.record_error)
      local providers, providers_err = read_metric(group, "providers", adapter and adapter.features and adapter.features.providers and adapter.getProviders or nil, self.record_error)
      local ports, ports_err = read_metric(group, "ports", adapter and adapter.features and adapter.features.ports and adapter.getPorts or nil, self.record_error)
      cache.cells, cache.cells_err = cells, cells_err
      cache.providers, cache.providers_err = providers, providers_err
      cache.ports, cache.ports_err = ports, ports_err
      cache.ts = now_ts
      self:update_component_diag(group, adapter, "cells", normalize_reason(cells_err), cells_err)
      self:update_component_diag(group, adapter, "providers", normalize_reason(providers_err), providers_err)
      if adapter and adapter.features and adapter.features.ports then
        self:update_component_diag(group, adapter, "ports", normalize_reason(ports_err), ports_err)
      else
        self:update_component_diag(group, adapter, "ports", nil, nil)
      end
      calls = calls + 1
      spent_ms = spent_ms + (now_ms() - started_at)
      if type(self.heartbeat_pump) == "function" then
        self.heartbeat_pump(now_ms())
      end
    end
  end
  self.component_cursor = idx
end

function runtime:rebuild_snapshot(now_ts, groups, diag)
  local matrices = {}
  local total = { stored = 0, capacity = 0, input = 0, output = 0, has_flow = false }
  local stale_after_ms = math.max(1000, math.floor((tonumber(self.config.matrix_metric_poll_interval) or 2.0) * 4000))

  for _, group in ipairs(groups or {}) do
    local reader = group.representative
    local dynamic = self.dynamic_cache[tostring(group.key)] or {}
    local static = self.static_cache[tostring(group.key)] or {}
    local stored = tonumber(dynamic.stored or dynamic.last_good_stored) or 0
    local capacity = tonumber(dynamic.capacity or dynamic.last_good_capacity) or stored
    local input = dynamic.input
    local output = dynamic.output
    local stored_ts = tonumber(dynamic.stored_ts) or 0
    local capacity_ts = tonumber(dynamic.capacity_ts) or 0
    local metric_ts = math.min(stored_ts > 0 and stored_ts or now_ts, capacity_ts > 0 and capacity_ts or now_ts)
    local has_live_sample = stored_ts > 0 or capacity_ts > 0
    local has_last_good = (dynamic.last_good_stored ~= nil) and (dynamic.last_good_capacity ~= nil)
    local freshness_ms = has_live_sample and math.max(0, now_ts - metric_ts) or nil
    local missing = not has_live_sample and not has_last_good
    local stale = has_live_sample and freshness_ms ~= nil and freshness_ms > stale_after_ms
    local port_names = {}
    for _, port in ipairs(group.ports or {}) do
      port_names[#port_names + 1] = port.name
    end

    if input ~= nil or output ~= nil then
      total.has_flow = true
      total.input = total.input + (tonumber(input) or 0)
      total.output = total.output + (tonumber(output) or 0)
    end
    total.stored = total.stored + stored
    total.capacity = total.capacity + capacity

    local label = reader and (reader.alias or reader.name) or tostring(group.key)
    matrices[#matrices + 1] = {
      id = group.key,
      key = group.key,
      name = reader and reader.name or group.key,
      alias = label,
      label = label,
      reader = reader and reader.name or nil,
      ports = port_names,
      port_count = #port_names,
      stored = stored,
      capacity = capacity,
      percent = capacity > 0 and (stored / capacity) or 0,
      input = tonumber(input),
      output = tonumber(output),
      cells = tonumber(static.cells),
      providers = tonumber(static.providers),
      total_ports = tonumber(static.ports),
      -- Snapshot contract for telemetry/UI:
      -- missing => no successful sample yet, stale => last sample too old,
      -- valid => safe last-good state exists for stable rendering/reporting.
      valid = has_last_good or (dynamic.stored ~= nil and dynamic.capacity ~= nil),
      last_good_state = has_last_good and {
        stored = tonumber(dynamic.last_good_stored) or 0,
        capacity = tonumber(dynamic.last_good_capacity) or 0,
        input = tonumber(dynamic.last_good_input),
        output = tonumber(dynamic.last_good_output),
        ts = tonumber(dynamic.last_good_ts)
      } or nil,
      sample_ts = has_live_sample and metric_ts or nil,
      freshness_ms = freshness_ms,
      missing = missing,
      stale = stale,
      status = missing and "MISSING" or (stale and "STALE" or ((dynamic.stored_err or dynamic.capacity_err) and "DEGRADED" or "OK"))
    }
  end

  local total_percent = total.capacity > 0 and (total.stored / total.capacity) or 0
  self.last_snapshot = {
    ts = now_ts,
    matrices = matrices,
    total = {
      stored = total.stored,
      capacity = total.capacity,
      percent = total_percent,
      input = total.has_flow and total.input or nil,
      output = total.has_flow and total.output or nil
    },
    freshness_ms = now_ts - self.last_poll_ts,
    stale = false,
    diag = diag or { metric_calls = {}, metric_totals = {}, throttled = nil }
  }
end

-- Matrix sampling is intentionally detached from telemetry/UI paths.
-- Telemetry/UI consume this snapshot only; they never read matrix peripherals.
function runtime:tick(ts)
  local now_ts = ts or now_ms()
  local min_tick_spacing_ms = math.max(100, math.floor(tonumber(self.config.matrix_sample_min_tick_spacing_ms) or 400))
  if self.last_snapshot and (self.last_snapshot.ts or 0) > 0 and (now_ts - (self.last_poll_ts or 0)) < min_tick_spacing_ms then
    return
  end
  local groups = type(self.get_groups) == "function" and (self.get_groups() or {}) or {}
  self:sync_group_caches(groups)
  local diag = self:poll_due_metrics(now_ts, groups)
  self:poll_static_components(now_ts, groups)
  self.last_poll_ts = now_ts
  self:rebuild_snapshot(now_ts, groups, diag)
end

function runtime:get_snapshot(max_age_ms)
  local now_ts = now_ms()
  local snapshot = self.last_snapshot or {}
  local freshness = now_ts - (snapshot.ts or 0)
  local stale = (snapshot.ts or 0) <= 0
  if not stale and max_age_ms and tonumber(max_age_ms) and tonumber(max_age_ms) > 0 then
    stale = freshness > tonumber(max_age_ms)
  end
  local copy = utils.deep_copy(snapshot)
  copy.freshness_ms = freshness
  copy.stale = stale
  return copy
end

return runtime
