local function ensure_epoch()
  if not os.epoch then
    os.epoch = function()
      return os.time() * 1000
    end
  end
end

ensure_epoch()

package.path = table.concat({
  "./xreactor/?.lua",
  "./xreactor/?/init.lua",
  package.path
}, ";")

local protocol = require("core.protocol")
local constants = require("shared.constants")

local function assert_ok(name, ok, err)
  if not ok then
    error(string.format("%s failed: %s", name, tostring(err)))
  end
end

local valid = protocol.status("MASTER-1", constants.roles.MASTER, { ok = true })
local ok_valid, err_valid = protocol.validateMessage(valid)
assert_ok("valid message", ok_valid, err_valid)

local missing_role = protocol.status("MASTER-1", constants.roles.MASTER, { ok = true })
missing_role.role = nil
local ok_role, err_role = protocol.validateMessage(missing_role)
if ok_role or err_role ~= "missing role" then
  error("expected missing role validation error")
end

local missing_payload = protocol.status("MASTER-1", constants.roles.MASTER, { ok = true })
missing_payload.payload = nil
local ok_payload, err_payload = protocol.validateMessage(missing_payload)
if ok_payload or err_payload ~= "missing payload" then
  error("expected missing payload validation error")
end

local proto_mismatch = protocol.status("MASTER-1", constants.roles.MASTER, { ok = true })
proto_mismatch.proto_ver = { major = constants.proto_ver.major + 1, minor = 0 }
local ok_proto, err_proto = protocol.validateMessage(proto_mismatch)
if ok_proto or err_proto ~= "proto_ver mismatch" then
  error("expected proto_ver mismatch validation error")
end

print("protocol_test.lua: ok")
