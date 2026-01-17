-- Manifest for the XReactor installer (hashes and required files).
return {
  version = 1,
  source = {
    channel = "main"
  },
  hash_algo = "sumlen-v1",
  installer_min_version = "1.3",
  installer_path = "xreactor/installer/installer.lua",
  installer_hash = "5065399:61648",
  files = {
    ["xreactor/core/network.lua"] = "264972:3241",
    ["xreactor/core/trends.lua"] = "147554:1791",
    ["xreactor/core/utils.lua"] = "231893:2759",
    ["xreactor/core/logger.lua"] = "310370:3768",
    ["xreactor/core/ui.lua"] = "496501:6038",
    ["xreactor/core/protocol.lua"] = "431113:4905",
    ["xreactor/core/safety.lua"] = "69198:771",
    ["xreactor/core/state_machine.lua"] = "69430:842",
    ["xreactor/nodes/rt/config.lua"] = "70029:907",
    ["xreactor/nodes/rt/main.lua"] = "4982451:60013",
    ["xreactor/nodes/reprocessor/config.lua"] = "50046:651",
    ["xreactor/nodes/reprocessor/main.lua"] = "250741:2990",
    ["xreactor/nodes/water/config.lua"] = "57769:755",
    ["xreactor/nodes/water/main.lua"] = "204509:2414",
    ["xreactor/nodes/fuel/config.lua"] = "56514:740",
    ["xreactor/nodes/fuel/main.lua"] = "264323:3070",
    ["xreactor/nodes/energy/config.lua"] = "58644:759",
    ["xreactor/nodes/energy/main.lua"] = "256976:3032",
    ["xreactor/master/config.lua"] = "104833:1329",
    ["xreactor/master/startup_sequencer.lua"] = "269310:3239",
    ["xreactor/master/profiles.lua"] = "11210:164",
    ["xreactor/master/main.lua"] = "1782900:20973",
    ["xreactor/master/ui/alarms.lua"] = "100743:1245",
    ["xreactor/master/ui/resources.lua"] = "178632:2153",
    ["xreactor/master/ui/rt_dashboard.lua"] = "146115:1817",
    ["xreactor/master/ui/overview.lua"] = "341127:4222",
    ["xreactor/master/ui/energy.lua"] = "112049:1365",
    ["xreactor/shared/colors.lua"] = "27639:332",
    ["xreactor/shared/constants.lua"] = "89267:1318",
    ["xreactor/installer/release.lua"] = "11805:149"
  }
}
