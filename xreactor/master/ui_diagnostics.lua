local M = {}

local function count_real_rt_nodes(nodes)
  local count = 0
  for _, node in ipairs(nodes or {}) do
    if tostring(node and node.id or "") ~= "NO-RT" then
      count = count + 1
    end
  end
  return count
end

function M.snapshot_shape(models)
  local ov = (models and models.overview) or {}
  local rtm = (models and models.rt) or {}
  local en = (models and models.energy) or {}
  return {
    ov_nodes = #(ov.nodes or {}),
    ov_hints = #(ov.ops_hints or {}),
    ov_peer = tostring(ov.peer_summary or '-'),
    rt_nodes = count_real_rt_nodes(rtm.rt_nodes or {}),
    rt_assign = tostring(rtm.assignment_state or '-'),
    rt_queue = #(rtm.queue or {}),
    en_matrices = #(en.matrices or {}),
    en_support = #(en.support_nodes or {}),
    en_summary = tostring(en.energy_summary or '-')
  }
end

return M
