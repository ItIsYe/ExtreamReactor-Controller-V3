-- xreactor/manifest.lua -- manifest-v287
return {
  manifest_version = 489,
  manifest_id = "manifest-v489",
  source_ref = "beta",
  hash_algo = "crc32",

  base_files = {
  { path = "services/heartbeat_service.lua", size_bytes = 3938, hash = "6b908df2" },
  { path = "services/auto_update_service.lua", size_bytes = 1688, hash = "1d9fcbc6" },
  { path = "installer/http.lua", size_bytes = 3948, hash = "96b3ae8a", always=true },
  { path = "installer/manifest.lua", size_bytes = 5794, hash = "faaa98fa", always=true },
  { path = "installer/stage.lua", size_bytes = 9164, hash = "b067f20b", always=true },
  { path = "installer/ui.lua", size_bytes = 2074, hash = "7bdd0eb9", always=true },
  { path = "installer/auto_update.lua", size_bytes = 17674, hash = "8c7a115a", always=true },
  { path = "installer/init.lua", size_bytes = 28141, hash = "0defdf4f", always=true },
  { path = "installer/journal.lua", size_bytes = 11987, hash = "ae694c83", always=true },
  { path = "installer/plan_validator.lua", size_bytes = 5768, hash = "0189a978", always=true },
  { path = "release.lua", size_bytes = 345, hash = "44af47e0", always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true, always=true },
  { path = "start.lua", size_bytes = 13840, hash = "11e88196", always=true },
  { path = "shared/build_info.lua", size_bytes = 1312, hash = "328286a9", always=true },
  { path = "shared/constants.lua", size_bytes = 4181, hash = "08d98202", always=true },
    { path = "core/mockup_ui.lua", size_bytes = 11146, hash = "3b1f768a", always=true },
  { path = "adapters/monitor.lua", size_bytes = 7979, hash = "9948fe5c" },
  { path = "core/bootstrap.lua", size_bytes = 11202, hash = "e54f2a38", always=true },
  { path = "core/update_handshake.lua", size_bytes = 3464, hash = "015539af", always=true },
  { path = "core/comms.lua", size_bytes = 25765, hash = "ea0be60e" },
  { path = "core/health.lua", size_bytes = 1918, hash = "48d5bd7f" },
  { path = "core/logger.lua", size_bytes = 32590, hash = "088f5e4b" },
  { path = "core/monitor_manager.lua", size_bytes = 10306, hash = "db7fc423" },
  { path = "core/network.lua", size_bytes = 15309, hash = "7504d3dd" },
  { path = "core/non_rt_config.lua", size_bytes = 4183, hash = "6f5bf45f" },
  { path = "core/non_rt_payload.lua", size_bytes = 558, hash = "b9c0175d" },
  { path = "core/protocol.lua", size_bytes = 6423, hash = "6c324af5" },
  { path = "core/registry.lua", size_bytes = 12481, hash = "f36ffed9" },
  { path = "core/remote_log.lua", size_bytes = 4698, hash = "7e6f3647" },
  { path = "core/safety.lua", size_bytes = 7851, hash = "3d0160cc" },
  { path = "core/state_machine.lua", size_bytes = 842, hash = "4ae6c19c" },
    { path = "core/startup_report.lua", size_bytes = 4090, hash = "d3ecd622", always=true },
  { path = "core/time.lua", size_bytes = 454, hash = "52e5eb5d" },
  { path = "core/trends.lua", size_bytes = 1791, hash = "d01a6948" },
  { path = "core/ui.lua", size_bytes = 12977, hash = "b0274c0e" },
  { path = "core/ui_router.lua", size_bytes = 20847, hash = "d9c9c7a8" },
  { path = "core/utils.lua", size_bytes = 24602, hash = "96cdaaaf" },
  { path = "core/auto_update.lua", size_bytes = 5174, hash = "332b3250" },
  { path = "core/remote_update.lua", size_bytes = 13576, hash = "ac163240" },
  { path = "core/alerts.lua", size_bytes = 11048, hash = "7c28803c" },
  -- Fix (2026-07-17): INSTALL/MANIFEST-P1 aus docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md (Abschnitt 7, transitive require()-Abdeckung,
  -- siehe tests/manifest_transitive_require_coverage_test.lua). Ohne
  -- required_for wurde diese Datei bisher an JEDE nicht-LOG-Rolle
  -- mitgeschickt (unnoetiger Ballast -- nur master/runtime_loop.lua
  -- require()t sie tatsaechlich), UND ihre eigene, unbedingte Abhaengigkeit
  -- core/alert_rules.lua ist bereits korrekt auf required_for={"MASTER"}
  -- beschraenkt -- eine faktisch tote, aber strukturell inkonsistente
  -- Kombination.
  { path = "services/alert_service.lua", size_bytes = 14551, hash = "be4bfdf2", required_for={"MASTER"} },
  { path = "services/comms_service.lua", size_bytes = 9910, hash = "7ab0adba" },
  { path = "services/control_service.lua", size_bytes = 610, hash = "e09ee7b4" },
  { path = "services/discovery_service.lua", size_bytes = 3157, hash = "600b94de" },
  { path = "services/service_manager.lua", size_bytes = 7459, hash = "6cb63793" },
  { path = "services/telemetry_service.lua", size_bytes = 5651, hash = "1bdb3693" },
  { path = "services/ui_service.lua", size_bytes = 5595, hash = "fcc90306" },
  -- Fix (2026-07-17): INSTALL/MANIFEST-P1 (Abschnitt 7). core/mockup_ui.lua
  -- hat always=true (wird u.a. an LOG_COLLECTOR mitgeschickt) und
  -- require()t shared.colors unbedingt beim Laden -- ohne always=true hier
  -- fehlte shared/colors.lua bei LOG_COLLECTOR (is_log-Filter in
  -- files_for_role() liess ausschliesslich always=true Basisdateien durch).
  { path = "shared/colors.lua", size_bytes = 593, hash = "89e36ece", always=true },
  { path = "shared/health_codes.lua", size_bytes = 336, hash = "e1d7e466" },
  { path = "shared/telemetry_schema.lua", size_bytes = 938, hash = "9567b224" },
  },

  roles = {
    master = {
    { path = "master/config_edits.lua", size_bytes = 8683, hash = "a685c2a6", required_for={"MASTER"} },
    { path = "master/context.lua", size_bytes = 5370, hash = "7e42349c", required_for={"MASTER"} },
    { path = "master/loop.lua", size_bytes = 4003, hash = "294a734c", required_for={"MASTER"} },
    { path = "core/alert_rules.lua", size_bytes = 17159, hash = "f436f415", required_for={"MASTER"} },
    { path = "master/config.lua", size_bytes = 7111, hash = "2cb175fc", required_for={"MASTER"} },
    { path = "master/housekeeping.lua", size_bytes = 3850, hash = "b3d24c21", required_for={"MASTER"} },
    { path = "master/fuel_relay.lua", size_bytes = 4291, hash = "ff7ae504", required_for={"MASTER"} },
    { path = "master/init_runtime.lua", size_bytes = 8295, hash = "50e5b461", required_for={"MASTER"} },
    { path = "master/main.lua", size_bytes = 244, hash = "227a851a", required_for={"MASTER"} },
    { path = "master/message_handlers.lua", size_bytes = 28938, hash = "31bb36af", required_for={"MASTER"} },
    { path = "master/monitor_sessions.lua", size_bytes = 10746, hash = "8918bb8f", required_for={"MASTER"} },
    { path = "master/profiles.lua", size_bytes = 283, hash = "16f8e038", required_for={"MASTER"} },
    { path = "master/rt_sync.lua", size_bytes = 19025, hash = "bfaff89a", required_for={"MASTER"} },
    { path = "master/rt_sync_coalescer.lua", size_bytes = 7676, hash = "9519c601", required_for={"MASTER"} },
    { path = "master/runtime_context.lua", size_bytes = 5758, hash = "0c0c5c9c", required_for={"MASTER"} },
    { path = "master/runtime_loop.lua", size_bytes = 18185, hash = "1d9a0442", required_for={"MASTER"} },
    { path = "master/runtime_ops_monitor.lua", size_bytes = 2634, hash = "8454a2a2", required_for={"MASTER"} },
    { path = "master/runtime_ops_profile.lua", size_bytes = 15968, hash = "85af1ef9", required_for={"MASTER"} },
    { path = "master/runtime_ops_rt.lua", size_bytes = 16692, hash = "45ba275f", required_for={"MASTER"} },
    { path = "master/startup_sequencer.lua", size_bytes = 12914, hash = "40c9d982", required_for={"MASTER"} },
    { path = "master/support_status.lua", size_bytes = 1385, hash = "7e4a2f0e", required_for={"MASTER"} },
    { path = "master/ui/alarms.lua", size_bytes = 7996, hash = "93b8a349", required_for={"MASTER"} },
    { path = "master/ui/alerts.lua", size_bytes = 28137, hash = "4bf57a50", required_for={"MASTER"} },
    { path = "master/ui/energy.lua", size_bytes = 9254, hash = "38fb057f", required_for={"MASTER"} },
    { path = "master/ui/multiview.lua", size_bytes = 20300, hash = "cd241353", required_for={"MASTER"} },
    { path = "master/ui/overview.lua", size_bytes = 13792, hash = "33054a4f", required_for={"MASTER"} },
    { path = "master/ui/resources.lua", size_bytes = 6215, hash = "2137ffd1", required_for={"MASTER"} },
    { path = "master/ui/rt_dashboard.lua", size_bytes = 12331, hash = "dfe0ff10", required_for={"MASTER"} },
    { path = "master/ui/widgets.lua", size_bytes = 7637, hash = "24de9664", required_for={"MASTER"} },
    { path = "master/ui/layout.lua", size_bytes = 6263, hash = "a29fdd47", required_for={"MASTER"} },
    { path = "master/ui/maintenance.lua", size_bytes = 4360, hash = "17833cc1", required_for={"MASTER"} },
    { path = "master/ui/updates.lua", size_bytes = 4914, hash = "577f9890", required_for={"MASTER"} },
    { path = "master/ui/system_map.lua", size_bytes = 6136, hash = "c62cf990", required_for={"MASTER"} },
    { path = "master/ui/config_editor.lua", size_bytes = 6749, hash = "682b50a4", required_for={"MASTER"} },
    -- Fix (2026-07-20): VALVE NICHT (mehr) in required_for -- die VALVE-Node
    -- hat einen eigenen, fest eingebauten (nicht optionalen, nicht ueber
    -- dieses Feature gesteuerten) 1x1-Statusmonitor direkt in nodes/valve/
    -- main.lua (render_status_monitor()), unabhaengig vom hier verwalteten
    -- 1x3-Turm-Ampel-Modul mit Shape-Check. Siehe dortiger Kommentar.
    { path = "optional/ampel.lua", size_bytes = 7328, hash = "58b9f1d8", optional=true, feature="ampel", required_for={"RT","ENERGY","WATER","FUEL","REPROCESSING","LOG"} },
    -- Fix (2026-07-16): CRITICAL. MANIFEST-P1 aus
    -- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 17).
    -- Fehlte bisher ganz -- files_for_role() fuegt einen roles.*-Eintrag
    -- nur hinzu, wenn "always=true" ODER "required_for" die gewaehlte
    -- Rolle enthaelt (siehe installer/manifest.lua). Ohne required_for
    -- wurde diese Datei fuer KEINE Rolle jemals installiert, selbst wenn
    -- der Nutzer das Feature interaktiv ausgewaehlt hatte (der Prompt
    -- erschien sogar faelschlich fuer JEDE Rolle, da matches_role() in
    -- installer/init.lua ein fehlendes required_for als "passt immer"
    -- interpretiert). Rollen entsprechen den tatsaechlichen
    -- require("optional.speaker_alarm")-Aufrufstellen: nodes/rt/main.lua,
    -- nodes/rt/monitor_ui.lua, nodes/energy/main.lua, nodes/water/main.lua,
    -- nodes/fuel/main.lua, nodes/reprocessor/main.lua,
    -- nodes/log_collector/main.lua, sowie services/alert_service.lua
    -- (dort per Default AKTIV, "opt-out via enable_speaker_alarm=false"),
    -- das ueber master/init_runtime.lua auch von MASTER instanziiert wird
    -- -- anders als "ampel", das fuer MASTER ein eigenes getrenntes
    -- "master_ampel"-Feature hat, gibt es fuer speaker_alarm keine
    -- MASTER-spezifische Variante. nodes/valve/main.lua nutzt weder
    -- speaker_alarm noch alert_service -- VALVE bewusst nicht enthalten.
    { path = "optional/speaker_alarm.lua", size_bytes = 5545, hash = "44a8e65d", optional=true, feature="speaker_alarm", required_for={"RT","ENERGY","WATER","FUEL","REPROCESSING","LOG","MASTER"} },
    { path = "optional/pocket_query_handler.lua", size_bytes = 5939, hash = "abe22b63", optional=true, feature="pocket_query", required_for={"MASTER"} },
    -- Feature (2026-07-09): eigenstaendiges Pocket-Computer-Client-Skript.
    -- Bewusst OHNE Auto-Installation -- Pocket Computer ist kein waehlbarer
    -- Rollen-Typ im Installer, laeuft daher nie automatisch bei irgendeiner
    -- Rollen-Installation mit ("manual install only", siehe Commit-Historie
    -- der Datei). optional=true + leeres required_for={} sorgt dafuer,
    -- dass es weder automatisch installiert noch als Auswahl-Prompt bei
    -- IRGENDEINER Rolle auftaucht (siehe collect_optional_feature_names()
    -- in installer/init.lua: required_for={} matched keine Rolle). Trotzdem
    -- im Manifest gefuehrt, damit Groesse/Hash verifizierbar sind, falls
    -- die Datei gezielt manuell heruntergeladen wird.
    { path = "optional/pocket_client.lua", size_bytes = 10846, hash = "10601ed6", optional=true, feature="pocket_client", required_for={} },
    { path = "optional/master_ampel.lua", size_bytes = 6373, hash = "f3d68ef7", optional=true, feature="master_ampel", required_for={"MASTER"} },
    { path = "master/ui_controller.lua", size_bytes = 52976, hash = "bd210ff0", required_for={"MASTER"} },
    { path = "master/ui_diagnostics.lua", size_bytes = 830, hash = "d2a9d0fb", required_for={"MASTER"} },
    },
    rt = {
    { path = "adapters/reactor.lua", size_bytes = 19150, hash = "27d9025b", required_for={"RT"} },
    { path = "adapters/turbine.lua", size_bytes = 3871, hash = "a9e924f3", required_for={"RT"} },
    { path = "core/control_rails.lua", size_bytes = 8017, hash = "01c1a770", required_for={"RT"} },
    { path = "core/fluid.lua", size_bytes = 5017, hash = "9a5c0bea", required_for={"RT"} },
    { path = "core/turbine_ctrl.lua", size_bytes = 2663, hash = "d1b27731", required_for={"RT"} },
    { path = "core/turbine_regulator.lua", size_bytes = 17134, hash = "50ce7402", required_for={"RT"} },
    { path = "nodes/rt/binding.lua", size_bytes = 3507, hash = "87255444", required_for={"RT"} },
    { path = "nodes/rt/command_handler.lua", size_bytes = 12089, hash = "d2d2f705", required_for={"RT"} },
    { path = "nodes/rt/reactor_control.lua", size_bytes = 36127, hash = "377016c4", required_for={"RT"} },
    { path = "nodes/rt/turbine_control.lua", size_bytes = 48274, hash = "a19b4b96", required_for={"RT"} },
    { path = "nodes/rt/capacity_learning.lua", size_bytes = 3983, hash = "0dee3a0d", required_for={"RT"} },
    { path = "nodes/rt/capacity_cache.lua", size_bytes = 2657, hash = "c51d7bd1", required_for={"RT"} },
    { path = "nodes/rt/config.lua", size_bytes = 5675, hash = "b4adbfb4", required_for={"RT"} },
    { path = "nodes/rt/config_normalizer.lua", size_bytes = 27009, hash = "be5c4de6", required_for={"RT"} },
    { path = "nodes/rt/discovery_log.lua", size_bytes = 1080, hash = "7d9ceb62", required_for={"RT"} },
    { path = "nodes/rt/discovery_runtime.lua", size_bytes = 13926, hash = "98be547a", required_for={"RT"} },
    { path = "nodes/rt/flow_apply_helpers.lua", size_bytes = 6878, hash = "b1b73ffe", required_for={"RT"} },
    { path = "nodes/rt/health_payload.lua", size_bytes = 2723, hash = "7a3f83b2", required_for={"RT"} },
    { path = "nodes/rt/main.lua", size_bytes = 60817, hash = "b86ab270", required_for={"RT"} },
    { path = "nodes/rt/module_lifecycle.lua", size_bytes = 27809, hash = "1b235e40", required_for={"RT"} },
    { path = "nodes/rt/monitor_ui.lua", size_bytes = 16319, hash = "92da8da4", required_for={"RT"} },
    { path = "nodes/rt/mockup_pages.lua", size_bytes = 17793, hash = "f0390938", required_for={"RT"} },
    { path = "nodes/rt/reactor_steam_guard.lua", size_bytes = 2613, hash = "2f2fa78c", required_for={"RT"} },
    { path = "nodes/rt/startup_diagnostics.lua", size_bytes = 2613, hash = "e5d63978", required_for={"RT"} },
    { path = "nodes/rt/state_handlers.lua", size_bytes = 9257, hash = "bb391437", required_for={"RT"} },
    { path = "nodes/rt/status_snapshot.lua", size_bytes = 6460, hash = "a5787f60", required_for={"RT"} },
    },
    energy = {
    { path = "nodes/energy/heartbeat.lua", size_bytes = 6671, hash = "9b84841c", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix.lua", size_bytes = 1964, hash = "be7074b3", required_for={"ENERGY"} },
    { path = "adapters/energy_storage.lua", size_bytes = 3648, hash = "fd2dc2e5", required_for={"ENERGY"} },
    { path = "adapters/induction_matrix.lua", size_bytes = 15124, hash = "c3006e4d", required_for={"ENERGY"} },
    { path = "services/matrix_sampling_service.lua", size_bytes = 867, hash = "fff32232", required_for={"ENERGY"} },
    { path = "nodes/energy/command_handler.lua", size_bytes = 1329, hash = "e6b074ac", required_for={"ENERGY"} },
    { path = "nodes/energy/config.lua", size_bytes = 6428, hash = "64c500f6", required_for={"ENERGY"} },
    { path = "nodes/energy/config_normalizer.lua", size_bytes = 6260, hash = "0f3e5f0e", required_for={"ENERGY"} },
    { path = "nodes/energy/discovery_log.lua", size_bytes = 2433, hash = "4f723e27", required_for={"ENERGY"} },
    { path = "nodes/energy/discovery_runtime.lua", size_bytes = 17168, hash = "4d225311", required_for={"ENERGY"} },
    { path = "nodes/energy/main.lua", size_bytes = 25770, hash = "2c0e27fb", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix_snapshot_runtime.lua", size_bytes = 17943, hash = "9b8b5405", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix_topology_cache.lua", size_bytes = 2052, hash = "54dc9081", required_for={"ENERGY"} },
    { path = "nodes/energy/runtime_context.lua", size_bytes = 2098, hash = "c352f2d4", required_for={"ENERGY"} },
    { path = "nodes/energy/status_payload.lua", size_bytes = 9140, hash = "767f2ce2", required_for={"ENERGY"} },
    { path = "nodes/energy/storage_snapshot_runtime.lua", size_bytes = 7082, hash = "f6c8c3f0", required_for={"ENERGY"} },
    { path = "nodes/energy/ui_model.lua", size_bytes = 6005, hash = "faa185db", required_for={"ENERGY"} },
    { path = "nodes/energy/ui_pages.lua", size_bytes = 18429, hash = "c0aa3582", required_for={"ENERGY"} },
    },
    water = {
    { path = "nodes/water/config.lua", size_bytes = 4789, hash = "961b224e", required_for={"WATER"} },
    { path = "nodes/water/config_normalizer.lua", size_bytes = 989, hash = "09141fba", required_for={"WATER"} },
    { path = "nodes/water/main.lua", size_bytes = 28497, hash = "46b73a0f", required_for={"WATER"} },
    { path = "nodes/water/ui_pages.lua", size_bytes = 10862, hash = "cfbbd586", required_for={"WATER"} },
    { path = "nodes/water/role_descriptor.lua", size_bytes = 152, hash = "c76ee5e7", required_for={"WATER"} },
    },
    fuel = {
    { path = "nodes/fuel/config.lua", size_bytes = 10035, hash = "8f10ce36", required_for={"FUEL"} },
    { path = "nodes/fuel/config_normalizer.lua", size_bytes = 5319, hash = "26224676", required_for={"FUEL"}},
    { path = "nodes/fuel/main.lua", size_bytes = 24985, hash = "027f0d6c", required_for={"FUEL"}},
    { path = "nodes/fuel/status_snapshot.lua", size_bytes = 5027, hash = "2a145d2b", required_for={"FUEL"} },
    { path = "nodes/fuel/command_handler.lua", size_bytes = 2096, hash = "369baea1", required_for={"FUEL"} },
    { path = "nodes/fuel/fuel_status_network.lua", size_bytes = 4052, hash = "d18e34ba", required_for={"FUEL"} },
    { path = "nodes/fuel/monitor_ui.lua", size_bytes = 12594, hash = "20557fdf", required_for={"FUEL"} },
    { path = "nodes/fuel/storage.lua", size_bytes = 2275, hash = "370bf2fa", required_for={"FUEL"} },
    { path = "nodes/fuel/ui_pages.lua", size_bytes = 19964, hash = "ef15d921", required_for={"FUEL"}},
    { path = "nodes/fuel/role_descriptor.lua", size_bytes = 147, hash = "1b38a051", required_for={"FUEL"} },
    { path = "nodes/fuel/logistics_router.lua", size_bytes = 29802, hash = "9d423ec4", required_for={"FUEL","REPROCESSING"} },
    { path = "nodes/fuel/redstone_router.lua", size_bytes = 48894, hash = "c72567e2", required_for={"FUEL","REPROCESSING","WATER"} },
    { path = "nodes/fuel/router_ui.lua", size_bytes = 36257, hash = "1b90edb0", required_for={"FUEL","REPROCESSING"}},
    },
    reprocessing = {
    { path = "nodes/reprocessor/config.lua", size_bytes = 5028, hash = "3b53b47d", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/config_normalizer.lua", size_bytes = 2097, hash = "7b4dd612", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/feed_router.lua", size_bytes = 10658, hash = "fdad2b01", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/main.lua", size_bytes = 32985, hash = "f3d2ac84", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/ui_pages.lua", size_bytes = 11071, hash = "25d5ebdf", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/role_descriptor.lua", size_bytes = 177, hash = "3a1d8dc9", required_for={"REPROCESSING"} },
    { path = "nodes/valve/role_descriptor.lua", size_bytes = 152, hash = "aca06242", required_for={"VALVE"} },
    { path = "nodes/valve/config.lua", size_bytes = 2332, hash = "a571ceaf", required_for={"VALVE"} },
    { path = "nodes/valve/main.lua", size_bytes = 29057, hash = "bc4f5040", required_for={"VALVE"} },
    },
    log = {
    { path = "nodes/log_collector/main.lua", size_bytes = 60851, hash = "d401680c", required_for={"LOG"} },
    { path = "nodes/log_collector/mockup_main.lua", size_bytes = 1820, hash = "93f3bf36", required_for={"LOG"} },
    { path = "nodes/log_collector/mockup_ui.lua", size_bytes = 6190, hash = "75b0732e", required_for={"LOG"} },
    { path = "nodes/log_collector/default_ui.lua", size_bytes = 4481, hash = "adeb5fa4", required_for={"LOG"} },
    },
    shared_support = {
    { path = "nodes/support/command_handler.lua", size_bytes = 5643, hash = "7b6b4fac", required_for={"WATER", "FUEL", "REPROCESSING"} },
    { path = "nodes/support/discovery.lua", size_bytes = 1343, hash = "e8aa30c3", required_for={"WATER", "FUEL", "REPROCESSING"} },
    { path = "nodes/support/role_logic.lua", size_bytes = 571, hash = "a3d15a39", required_for={"ENERGY", "WATER", "FUEL", "REPROCESSING", "RT"} },
    { path = "nodes/support/runtime.lua", size_bytes = 9247, hash = "556b690a", required_for={"WATER", "FUEL", "REPROCESSING", "RT", "ENERGY", "MASTER", "VALVE"} },
    { path = "nodes/support/ui_pages.lua", size_bytes = 7695, hash = "10a158cd", required_for={"WATER", "FUEL", "REPROCESSING", "ENERGY", "RT"} },
    },
  },

  dev_files = {},
}
