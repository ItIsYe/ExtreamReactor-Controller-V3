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

  -- Feature (2026-07-13): ENERGY-P1 (siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md). Vorher wurden stored/capacity/input/
  -- output fuer JEDES Storage bei JEDEM 0.5s-Sample-Zyklus gelesen --
  -- capacity ist ueblicherweise statisch (aendert sich nur bei einem
  -- Upgrade/Umbau der Speicherbank) und muss nicht mit 2Hz abgefragt
  -- werden. Pro-Storage-Zustand: wann zuletzt capacity gelesen wurde,
  -- der zuletzt bekannte GUTE Wert jeder Metrik (last-good, ueberlebt
  -- einen einzelnen fehlgeschlagenen Read statt auf 0 zurueckzufallen),
  -- und ein einfacher Fehlerzaehler fuer ein zaehlerbasiertes Backoff bei
  -- durchgehend fehlschlagenden Geraeten.
  local CAPACITY_INTERVAL_MS = math.max(1000, math.floor((tonumber(runtime.config.capacity_interval_s) or 5) * 1000))
  local BACKOFF_FAIL_THRESHOLD = 4  -- ab so vielen Fehlschlagen in Folge: seltener versuchen
  local BACKOFF_SKIP_CYCLES = 4     -- so viele Sample-Zyklen ueberspringen, bevor erneut versucht wird
  local per_storage = {}  -- [storage_key] = { last_capacity_ts, cached_capacity, fail_count, skip_remaining, last_good }

  local function storage_state(key)
    local s = per_storage[key]
    if not s then
      s = { last_capacity_ts = 0, cached_capacity = 0, fail_count = 0, skip_remaining = 0, last_good = { stored = 0, input = 0, output = 0 } }
      per_storage[key] = s
    end
    return s
  end

  local function sample_storage_stats(ts)
    local now = ts or runtime.now_ms()
    local total, capacity, input, output = 0, 0, 0, 0
    local stores = {}
    for _, storage in ipairs(runtime.devices.storages or {}) do
      local adapter = storage.adapter
      local key = storage.id or storage.name
      local st = storage_state(key)
      local had_error = false
      local stored, cap, in_rate, out_rate

      -- Backoff: ein durchgehend fehlschlagendes Geraet wird nicht bei
      -- JEDEM 0.5s-Zyklus erneut angefragt, sondern seltener -- vermeidet
      -- unnoetige wiederholte Peripherie-Calls gegen ein bereits als
      -- kaputt/nicht erreichbar bekanntes Geraet, ohne es dauerhaft
      -- komplett aufzugeben (nach BACKOFF_SKIP_CYCLES wird wieder normal
      -- versucht).
      if st.skip_remaining > 0 then
        st.skip_remaining = st.skip_remaining - 1
        stored, in_rate, out_rate = st.last_good.stored, st.last_good.input, st.last_good.output
        cap = st.cached_capacity
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

        -- Fix (2026-07-13): ENERGY-P1. Bei einem fehlgeschlagenen Read
        -- wird jetzt der zuletzt bekannte GUTE Wert weiterverwendet, statt
        -- stillschweigend auf 0 zu fallen (0 wuerde in der UI/Telemetrie
        -- wie "Speicher leer" aussehen, obwohl es sich tatsaechlich nur um
        -- einen kurzzeitigen Lesefehler handelt).
        stored = err1 and st.last_good.stored or (stored_v or 0)
        in_rate = err2 and st.last_good.input or (in_v or 0)
        out_rate = err3 and st.last_good.output or (out_v or 0)

        if not had_error then
          st.last_good.stored, st.last_good.input, st.last_good.output = stored, in_rate, out_rate
          st.fail_count = 0
        else
          st.fail_count = st.fail_count + 1
          if st.fail_count >= BACKOFF_FAIL_THRESHOLD then
            st.skip_remaining = BACKOFF_SKIP_CYCLES
          end
        end

        -- capacity: nur alle CAPACITY_INTERVAL_MS (Standard 5s) tatsaechlich
        -- neu lesen, sonst den zwischengespeicherten Wert weiterverwenden.
        if (now - st.last_capacity_ts) >= CAPACITY_INTERVAL_MS or st.last_capacity_ts == 0 then
          local cap_v, err_cap = read_metric("capacity", adapter and adapter.getCapacity)
          if not err_cap then
            st.cached_capacity = cap_v or stored
            st.last_capacity_ts = now
          end
        end
        cap = st.cached_capacity
      end

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
