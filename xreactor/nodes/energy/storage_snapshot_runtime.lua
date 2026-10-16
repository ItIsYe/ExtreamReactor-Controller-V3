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
    -- Der wahre Energieinhalt ueber ALLE Speicher, auch die ohne bekannte
    -- Kapazitaet. total/capacity bleiben dagegen ein zusammengehoeriges
    -- Zaehler/Nenner-Paar -- siehe read_capacity() unten.
    local stored_all = 0
    local capacity_unknown = 0
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

        -- Wie read_metric, aber ohne die 0-Erfindung: eine fehlende
        -- Methode und ein nil-Rueckgabewert ergeben beide "unbekannt"
        -- (nil) statt einer Null, die sich spaeter nicht mehr von einem
        -- echten Messwert unterscheiden laesst.
        local function read_capacity(fn)
          if not fn then return nil, false end
          local value, err = fn()
          if err then
            if type(runtime.record_error) == "function" then
              runtime.record_error(storage.name .. ".capacity", err)
            end
            return nil, true
          end
          return tonumber(value), false
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
        --
        -- UNBEKANNT wird nicht mehr erfunden. Vorher fiel die Kapazitaet bei
        -- fehlendem Messwert auf `stored` zurueck -- und read_metric() macht
        -- aus einer FEHLENDEN Methode wie aus einem nil-Rueckgabewert beides
        -- "0, kein Fehler". Ergebnis: stored=1000, capacity=1000, also
        -- scheinbar frische 100 % Fuellstand, ohne jede Stale-Markierung.
        -- Das ist kein Randfall: adapters/energy_storage.lua gibt fuer den
        -- passiven ER2-Reaktorport ausdruecklich capacity = nil zurueck,
        -- weil dieses Geraet die Kapazitaet nur in getEnergyStats() fuehrt.
        -- Der MASTER rechnet aus stored/capacity seinen Lastabwurf
        -- (master/runtime_ops_profile.lua) -- ein erfundener Nenner ist dort
        -- teurer als ein fehlender.
        if (now - st.last_capacity_ts) >= CAPACITY_INTERVAL_MS or st.last_capacity_ts == 0 then
          local cap_v, err_cap = read_capacity(adapter and adapter.getCapacity)
          had_error = had_error or err_cap
          if not err_cap then
            if cap_v and cap_v > 0 then
              st.cached_capacity = cap_v
              st.capacity_known = true
            else
              st.cached_capacity = 0
              st.capacity_known = false
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
      cap = tonumber(cap) or 0
      in_rate = tonumber(in_rate) or 0
      out_rate = tonumber(out_rate) or 0
      local capacity_known = st.capacity_known == true and cap > 0
      if had_error then any_stale = true end
      stored_all = stored_all + stored
      -- Zaehler und Nenner nur gemeinsam: ein Speicher ohne bekannte
      -- Kapazitaet darf seinen Inhalt nicht in einen Quotienten einbringen,
      -- zu dem er keinen Nenner beitraegt -- sonst waere der Fuellstand
      -- genau so verfaelscht wie mit der erfundenen Kapazitaet, nur in die
      -- andere Richtung.
      if capacity_known then
        total = total + stored
        capacity = capacity + cap
      else
        capacity_unknown = capacity_unknown + 1
      end
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
        capacity_known = capacity_known,
        ok = not had_error
      }
    end
    runtime.snapshot = {
      ts = ts or runtime.now_ms(),
      stale = any_stale,
      stores = stores,
      capacity_unknown = capacity_unknown,
      capacity_complete = capacity_unknown == 0,
      total = {
        stored = total, capacity = capacity, input = input, output = output,
        -- Der wahre Gesamtinhalt, unabhaengig von der Kapazitaetsabdeckung.
        stored_all = stored_all,
      }
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
      capacity_unknown = 0,
      capacity_complete = true,
      total = { stored = 0, capacity = 0, input = 0, output = 0, stored_all = 0 }
    }
    local age = now - (snapshot.ts or 0)
    -- Absichtlich KEIN synchrones sample_storage_stats() hier, wenn der
    -- Snapshot zu alt ist: read_storage_stats() wird ausschliesslich aus dem
    -- Heartbeat-Thread aufgerufen (TELEMETRY/UI via build_status_payload),
    -- der laut Architektur (siehe main.lua) niemals blockierend auf
    -- Peripherie zugreifen darf -- das erledigt exklusiv der STORAGE_SAMPLE-
    -- Service im separaten Matrix-Thread. Ein zu alter Snapshot wird
    -- stattdessen einfach als `stale=true` durchgereicht.
    return {
      stored = tonumber(snapshot.total and snapshot.total.stored) or 0,
      capacity = tonumber(snapshot.total and snapshot.total.capacity) or 0,
      input = tonumber(snapshot.total and snapshot.total.input) or 0,
      output = tonumber(snapshot.total and snapshot.total.output) or 0,
      stored_all = tonumber(snapshot.total and snapshot.total.stored_all)
        or tonumber(snapshot.total and snapshot.total.stored) or 0,
      capacity_unknown = tonumber(snapshot.capacity_unknown) or 0,
      capacity_complete = snapshot.capacity_complete ~= false,
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
