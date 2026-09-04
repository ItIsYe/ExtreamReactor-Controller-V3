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

  local CAPACITY_INTERVAL_MS = math.max(1000, math.floor((tonumber(runtime.config.capacity_interval_s) or 5) * 1000))
  local BACKOFF_FAIL_THRESHOLD = 4
  local BACKOFF_SKIP_CYCLES = 4
  local per_storage = {}

  local function storage_state(key)
    local s = per_storage[key]
    if not s then
      s = {
        last_capacity_ts = 0,
        cached_capacity = 0,
        fail_count = 0,
        skip_remaining = 0,
        last_good = { stored = 0, input = 0, output = 0 }
      }
      per_storage[key] = s
    end
    return s
  end

  local function sample_storage_stats(ts)
    local now = ts or runtime.now_ms()
    local total, capacity, input, output = 0, 0, 0, 0
    local stores = {}
    local any_stale = false
    for _, storage in ipairs(runtime.devices.storages or {}) do
      local adapter = storage.adapter
      local key = storage.id or storage.name
      local st = storage_state(key)
      local had_error = false
      local stored, cap, in_rate, out_rate

      if st.skip_remaining > 0 then
        st.skip_remaining = st.skip_remaining - 1
        stored, in_rate, out_rate = st.last_good.stored, st.last_good.input, st.last_good.output
        cap = st.cached_capacity
        had_error = (st.fail_count or 0) > 0
      else
        local function read_metric(label, fn)
          if not fn then return 0, false end
          local value, err = fn()
          if err then
            if type(runtime.record_error) == "function" then
              runtime.record_error(storage.name .. "." .. tostring(label), err)
            end
            return nil, true
          end
          return tonumber(value) or 0, false
        end

        local stored_v, err1 = read_metric("stored", adapter and adapter.getStored)
        local in_v, err2 = read_metric("input", adapter and adapter.getInput)
        local out_v, err3 = read_metric("output", adapter and adapter.getOutput)
        had_error = err1 or err2 or err3

        stored = err1 and st.last_good.stored or (stored_v or 0)
        in_rate = err2 and st.last_good.input or (in_v or 0)
        out_rate = err3 and st.last_good.output or (out_v or 0)

        -- Capacity is part of the same truth contract as stored/input/output.
        -- A failed capacity read must mark the whole storage sample stale and
        -- participate in failure backoff; otherwise a frozen cached capacity
        -- can be presented as fresh forever.
        if (now - st.last_capacity_ts) >= CAPACITY_INTERVAL_MS or st.last_capacity_ts == 0 then
          local cap_v, err_cap = read_metric("capacity", adapter and adapter.getCapacity)
          had_error = had_error or err_cap
          if not err_cap then
            if type(cap_v) == "number" and cap_v > 0 then
              st.cached_capacity = cap_v
            elseif type(stored) == "number" then
              st.cached_capacity = stored
            end
            st.last_capacity_ts = now
          end
        end
        cap = st.cached_capacity

        if not had_error then
          st.last_good.stored, st.last_good.input, st.last_good.output = stored, in_rate, out_rate
          st.fail_count = 0
        else
          st.fail_count = st.fail_count + 1
          if st.fail_count >= BACKOFF_FAIL_THRESHOLD then st.skip_remaining = BACKOFF_SKIP_CYCLES end
        end
      end

      stored = tonumber(stored) or 0
      cap = tonumber(cap) or stored
      in_rate = tonumber(in_rate) or 0
      out_rate = tonumber(out_rate) or 0
      if had_error then any_stale = true end
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
      stale = any_stale,
      stores = stores,
      total = { stored = total, capacity = capacity, input = input, output = output }
    }
    return runtime.snapshot
  end

  local function read_storage_stats(read_opts)
    read_opts = read_opts or {}
    local max_age_ms = tonumber(read_opts.max_age_ms)
      or math.max(3000, math.floor((tonumber(runtime.config.status_interval) or 5) * 1000))
    local now = runtime.now_ms()
    local snapshot = runtime.snapshot or {
      ts = 0,
      stores = {},
      total = { stored = 0, capacity = 0, input = 0, output = 0 }
    }
    local age = now - (snapshot.ts or 0)
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
      stale = snapshot.stale == true or (snapshot.ts or 0) <= 0
        or (max_age_ms > 0 and age > max_age_ms)
    }
  end

  return {
    sample_storage_stats = sample_storage_stats,
    read_storage_stats = read_storage_stats
  }
end

return M
