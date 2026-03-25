local discovery_log = {}

local function stable_join(values)
  table.sort(values)
  return table.concat(values, "|")
end

function discovery_log.build_signature(summary, decisions)
  local parts = {
    "vr=" .. tostring(summary.visible_reactors or 0),
    "vt=" .. tostring(summary.visible_turbines or 0),
    "br=" .. tostring(summary.bound_reactors or 0),
    "bt=" .. tostring(summary.bound_turbines or 0)
  }
  for _, decision in ipairs(decisions or {}) do
    parts[#parts + 1] = table.concat({
      tostring(decision.kind or "unknown"),
      tostring(decision.name or "n/a"),
      tostring(decision.type_name or "n/a"),
      decision.bound and "bound" or "rejected",
      tostring(decision.reason or "n/a"),
      tostring(decision.error and true or false)
    }, ":")
  end
  return stable_join(parts)
end

function discovery_log.should_log_details(previous_signature, next_signature, has_errors)
  if has_errors then
    return true
  end
  if not previous_signature then
    return true
  end
  return previous_signature ~= next_signature
end

return discovery_log
