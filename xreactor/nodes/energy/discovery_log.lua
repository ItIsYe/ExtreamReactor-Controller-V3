local discovery_log = {}

local function sort_copy(list)
  local out = {}
  for _, value in ipairs(list or {}) do
    out[#out + 1] = tostring(value)
  end
  table.sort(out)
  return out
end

local function method_signature(methods)
  return table.concat(sort_copy(methods or {}), ",")
end

function discovery_log.build_signature(snapshot)
  snapshot = snapshot or {}
  local entries = {}
  local function push(value)
    entries[#entries + 1] = tostring(value)
  end

  push("monitor:" .. tostring(snapshot.monitor_name or "none"))

  local names = sort_copy(snapshot.names or {})
  for _, name in ipairs(names) do
    push("peripheral:" .. name .. ":" .. tostring((snapshot.peripheral_types or {})[name] or "unknown"))
  end

  local candidates = snapshot.candidates or {}
  local candidate_rows = {}
  for _, candidate in ipairs(candidates) do
    candidate_rows[#candidate_rows + 1] = table.concat({
      tostring(candidate.name or "unknown"),
      tostring(candidate.kind or "unknown"),
      method_signature(candidate.methods)
    }, ":")
  end
  table.sort(candidate_rows)
  for _, row in ipairs(candidate_rows) do
    push("candidate:" .. row)
  end

  local matrices = snapshot.matrices or {}
  local matrix_rows = {}
  for _, matrix in ipairs(matrices) do
    matrix_rows[#matrix_rows + 1] = table.concat({
      tostring(matrix.name or "unknown"),
      method_signature(matrix.methods)
    }, ":")
  end
  table.sort(matrix_rows)
  for _, row in ipairs(matrix_rows) do
    push("matrix:" .. row)
  end

  local registry = snapshot.registry_summary or {}
  push(("registry:%s/%s/%s"):format(
    tostring(registry.total or 0),
    tostring(registry.bound or 0),
    tostring(registry.missing or 0)
  ))

  return table.concat(entries, "|")
end

function discovery_log.should_log_details(previous_signature, next_signature, force)
  if force then
    return true
  end
  if not previous_signature then
    return true
  end
  return previous_signature ~= next_signature
end

return discovery_log
