local M = {}

function M.new(opts)
  opts = opts or {}
  local runtime = {
    now_ms = assert(opts.now_ms, "now_ms required"),
    config = assert(opts.config, "config required"),
    devices = assert(opts.devices, "devices required"),
    utils = assert(opts.utils, "utils required"),
    record_error = opts.record_error
  }

  local function sample_storage_stats(ts)
    local total, capacity, input, output = 0, 0, 0, 0
    local stores = {}
    for _, storage in ipairs(runtime.devices.storages or {}) do
      local adapter = storage.adapter
      local had_error = false
      local function read_metric(label, fn)
        if not fn then
          return 0
        end
        local value, err = fn()
        if err then
          if type(runtime.record_error) == "function" then
            runtime.record_error(storage.name .. "." .. tostring(label), err)
          end
          had_error = true
        end
        return tonumber(value) or 0
      end
      local stored = read_metric("stored", adapter and adapter.getStored)
      local cap = read_metric("capacity", adapter and adapter.getCapacity)
      local in_rate = read_metric("input", adapter and adapter.getInput)
      local out_rate = read_metric("output", adapter and adapter.getOutput)
      stored = tonumber(stored) or 0
      cap = tonumber(cap) or stored
      in_rate = tonumber(in_rate) or 0
      out_rate = tonumber(out_rate) or 0
      total = total + stored
      capacity = capacity + cap
      input = input + in_rate
      output = output + out_rate
      stores[#stores + 1] = {
        id = storage.id or storage.name,
        alias = storage.alias,
        name = storage.name,
        stored = stored,
        capacity = cap,
        input = in_rate,
        output = out_rate,
        is_matrix = storage.is_matrix or false,
        ok = not had_error
      }
    end
    runtime.snapshot = {
      ts = ts or runtime.now_ms(),
      stale = false,
      stores = stores,
      total = { stored = total, capacity = capacity, input = input, output = output }
    }
    return runtime.snapshot
  end

  local function read_storage_stats(read_opts)
    read_opts = read_opts or {}
    local max_age_ms = tonumber(read_opts.max_age_ms) or math.max(3000, math.floor((tonumber(runtime.config.status_interval) or 5) * 1000))
    local now = runtime.now_ms()
    local snapshot = runtime.snapshot or {
      ts = 0,
      stores = {},
      total = { stored = 0, capacity = 0, input = 0, output = 0 }
    }
    local age = now - (snapshot.ts or 0)
    -- Fix #1: Storage wird jetzt immer neu gelesen wenn age > max_age_ms,
    -- nicht nur beim ersten Sample. Sonst zeigt die Node nach dem ersten
    -- erfolgreichen Read permanent veraltete Werte.
    if max_age_ms > 0 and age > max_age_ms then
      snapshot = sample_storage_stats(now)
      age = now - (snapshot.ts or 0)
    end
    return {
      stored = tonumber(snapshot.total and snapshot.total.stored) or 0,
      capacity = tonumber(snapshot.total and snapshot.total.capacity) or 0,
      input = tonumber(snapshot.total and snapshot.total.input) or 0,
      output = tonumber(snapshot.total and snapshot.total.output) or 0,
      stores = runtime.utils.deep_copy(snapshot.stores or {}),
      freshness_ms = age,
      stale = (snapshot.ts or 0) <= 0 or (max_age_ms > 0 and age > max_age_ms)
    }
  end

  return {
    sample_storage_stats = sample_storage_stats,
    read_storage_stats = read_storage_stats
  }
end

return M
