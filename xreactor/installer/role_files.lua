local roles = {}

roles.base = {
    "xreactor/shared/",
    "xreactor/core/",
    "xreactor/services/"
}

roles.master = {
    "xreactor/master/"
}

roles.rt = {
    "xreactor/nodes/rt/",
    "xreactor/adapters/reactor.lua",
    "xreactor/adapters/turbine.lua"
}

roles.energy = {
    "xreactor/nodes/energy/",
    "xreactor/adapters/induction_matrix.lua",
    "xreactor/adapters/energy_storage.lua"
}

roles.water = {
    "xreactor/nodes/water/"
}

roles.fuel = {
    "xreactor/nodes/fuel/"
}

roles.reprocessing = {
    "xreactor/nodes/reprocessor/"
}

return roles
