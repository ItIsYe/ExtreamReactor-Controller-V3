local function read(path)
  local handle = io.open(path, "r")
  if not handle then
    error("unable to read " .. tostring(path))
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local source = read("xreactor/nodes/energy/main.lua")

local master_peer_decl_pos = source:find("local master_peer_state", 1, true)
if not master_peer_decl_pos then
  error("missing forward declaration for master_peer_state")
end

local declaration_pos = source:find("local is_master_connected", 1, true)
if not declaration_pos then
  error("missing forward declaration for is_master_connected")
end

local build_status_pos = source:find("local function build_status_payload%(", 1)
if not build_status_pos then
  error("build_status_payload missing")
end

if declaration_pos > build_status_pos then
  error("is_master_connected forward declaration must appear before build_status_payload")
end

local build_ui_pos = source:find("local function build_ui_model%(", 1)
if not build_ui_pos then
  error("build_ui_model missing")
end

if master_peer_decl_pos > build_ui_pos then
  error("master_peer_state forward declaration must appear before build_ui_model")
end

local assignment_pos = source:find("is_master_connected%s*=%s*function%(", 1)
if not assignment_pos then
  error("is_master_connected local assignment missing")
end

if assignment_pos < build_status_pos then
  error("is_master_connected assignment should remain after helper definitions near message handlers")
end

local call_pos = source:find("is_master_connected%(", build_status_pos)
if not call_pos then
  error("build_status_payload must call is_master_connected")
end

local master_peer_assignment_pos = source:find("master_peer_state%s*=%s*function%(", 1)
if not master_peer_assignment_pos then
  error("master_peer_state local assignment missing")
end

if master_peer_assignment_pos < build_ui_pos then
  error("master_peer_state assignment should remain in the comms-helper section")
end

local master_peer_call_pos = source:find("master_peer_state%(", build_ui_pos)
if not master_peer_call_pos then
  error("build_ui_model must call master_peer_state")
end

print("energy_master_connection_scope_regression_test.lua: ok")
