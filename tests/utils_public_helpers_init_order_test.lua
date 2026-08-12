package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local utils = require("core.utils")

assert(type(utils.number_or_nil) == "function",
  "number_or_nil must exist immediately after require(core.utils)")
assert(type(utils.payload_looks_rt) == "function",
  "payload_looks_rt must exist immediately after require(core.utils)")
assert(utils.number_or_nil("42") == 42)
assert(utils.number_or_nil("not-a-number") == nil)
assert(utils.payload_looks_rt({ turbines = {} }) == true)
assert(utils.payload_looks_rt({ mode = "MASTER", output = 1, capabilities = {} }) == true)
assert(utils.payload_looks_rt({ foo = "bar" }) == false)

print("utils_public_helpers_init_order_test: OK")
