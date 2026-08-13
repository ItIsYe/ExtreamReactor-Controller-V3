-- xreactor/manifest.lua
return {
  manifest_version = 566,
  manifest_id = "manifest-v566",
  source_ref = "beta",
  hash_algo = "crc32",

  base_files = {
  { path = "installer/http.lua", size_bytes = 4835, hash = "eb7b4d47", always = true },
  { path = "installer/manifest.lua", size_bytes = 7223, hash = "272115ad", always = true },
  { path = "installer/stage.lua", size_bytes = 12124, hash = "837c3ab6", always = true },
  { path = "installer/ui.lua", size_bytes = 2074, hash = "7bdd0eb9", always = true },
  { path = "installer/auto_update.lua", size_bytes = 15660, hash = "685150ed", always = true },
  { path = "installer/init.lua", size_bytes = 22827, hash = "20dd5066", always = true },
  { path = "installer/reactor_naming.lua", size_bytes = 13072, hash = "dc01bce2", always = true },
  { path = "installer/journal.lua", size_bytes = 10079, hash = "5d1a2617", always = true },
  { path = "installer/plan_validator.lua", size_bytes = 6106, hash = "7ea9244c", always = true },
  { path = "release.lua", size_bytes = 345, hash = "8cdca309", always = true },
  { path = "start.lua", size_bytes = 15787, hash = "b2746ca4", always = true },
  { path = "shared/build_info.lua", size_bytes = 1312, hash = "328286a9", always = true },
  { path = "shared/constants.lua", size_bytes = 4181, hash = "08d98202", always = true },
  { path = "core/mockup_ui.lua", size_bytes = 11023, hash = "a712e4bc", always = true },
  { path = "adapters/monitor.lua", size_bytes = 9122, hash = "e1f359a2" },
  { path = "core/bootstrap.lua", size_bytes = 11202, hash = "e54f2a38", always = true },
  { path = "core/update_handshake.lua", size_bytes = 4701, hash = "94353b43", always = true },
  { path = "core/comms.lua", size_bytes = 26608, hash = "99069d17" },
  { path = "core/health.lua", size_bytes = 1918, hash = "48d5bd7f" },
  { path = "core/logger.lua", size_bytes = 31844, hash = "ac66b6f6" },
  { path = "core/monitor_manager.lua", size_bytes = 10463, hash = "9a28afa3" },
  { path = "core/network.lua", size_bytes = 15457, hash = "732d98cc" },
  { path = "core/non_rt_config.lua", size_bytes = 4183, hash = "6f5bf45f" },
  { path = "core/non_rt_payload.lua", size_bytes = 558, hash = "b9c0175d" },
  { path = "core/protocol.lua", size_bytes = 7370, hash = "4564c676" },
  { path = "core/reactor_identity.lua", size_bytes = 1610, hash = "059a6785", required_for={"MASTER","RT","FUEL"} },
  { path = "core/registry.lua", size_bytes = 12798, hash = "dfee2f71" },
  { path = "core/safety.lua", size_bytes = 7851, hash = "3d0160cc" },
  { path = "core/state_machine.lua", size_bytes = 842, hash = "4ae6c19c" },
  { path = "core/startup_report.lua", size_bytes = 4090, hash = "d3ecd622", always = true },
  { path = "core/time.lua", size_bytes = 454, hash = "52e5eb5d" },
  { path = "core/trends.lua", size_bytes = 1791, hash = "d01a6948" },
  { path = "core/ui.lua", size_bytes = 12977, hash = "b0274c0e" },
  { path = "core/ui_router.lua", size_bytes = 18766, hash = "6fa70df3" },
  { path = "core/window_buffer.lua", size_bytes = 3681, hash = "1743677d" },
  { path = "core/utils.lua", size_bytes = 24296, hash = "f9cf839e" },
  { path = "core/remote_update.lua", size_bytes = 4347, hash = "13acf7b4" },
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
  { path = "services/comms_service.lua", size_bytes = 12668, hash = "f35c5a04" },
  { path = "services/control_service.lua", size_bytes = 610, hash = "e09ee7b4" },
  { path = "services/discovery_service.lua", size_bytes = 3157, hash = "600b94de" },
  { path = "services/service_manager.lua", size_bytes = 7459, hash = "6cb63793" },
  { path = "services/telemetry_service.lua", size_bytes = 5651, hash = "1bdb3693" },
  { path = "services/ui_service.lua", size_bytes = 5764, hash = "91e1a922" },
  -- Fix (2026-07-17): INSTALL/MANIFEST-P1 (Abschnitt 7). core/mockup_ui.lua
  -- hat always = true (wird u.a. an LOG_COLLECTOR mitgeschickt) und
  -- require()t shared.colors unbedingt beim Laden -- ohne always = true hier
  -- fehlte shared/colors.lua bei LOG_COLLECTOR (is_log-Filter in
  -- files_for_role() liess ausschliesslich always = true Basisdateien durch).
  { path = "shared/colors.lua", size_bytes = 593, hash = "89e36ece", always = true },
  { path = "shared/health_codes.lua", size_bytes = 336, hash = "e1d7e466" },
  { path = "shared/telemetry_schema.lua", size_bytes = 938, hash = "9567b224" },
  },

  roles = {
    master = {
    { path = "master/config_edits.lua", size_bytes = 9283, hash = "39e380b2", required_for={"MASTER"} },
    { path = "master/context.lua", size_bytes = 5370, hash = "7e42349c", required_for={"MASTER"} },
    { path = "master/loop.lua", size_bytes = 4500, hash = "ea364de6", required_for={"MASTER"} },
    { path = "core/alert_rules.lua", size_bytes = 17159, hash = "f436f415", required_for={"MASTER"} },
    { path = "master/config.lua", size_bytes = 7111, hash = "2cb175fc", required_for={"MASTER"} },
    { path = "master/housekeeping.lua", size_bytes = 4106, hash = "c43799c5", required_for={"MASTER"} },
    { path = "master/fuel_relay.lua", size_bytes = 3413, hash = "0b9f8c37", required_for={"MASTER"} },
    { path = "master/init_runtime.lua", size_bytes = 8295, hash = "50e5b461", required_for={"MASTER"} },
    { path = "master/main.lua", size_bytes = 244, hash = "227a851a", required_for={"MASTER"} },
    { path = "master/message_handlers.lua", size_bytes = 28930, hash = "2fc1c9b2", required_for={"MASTER"} },
    { path = "master/monitor_sessions.lua", size_bytes = 10746, hash = "8918bb8f", required_for={"MASTER"} },
    { path = "master/profiles.lua", size_bytes = 275, hash = "59bdc157", required_for={"MASTER"} },
    { path = "master/rt_sync.lua", size_bytes = 18867, hash = "0aecf044", required_for={"MASTER"} },
    { path = "master/rt_sync_coalescer.lua", size_bytes = 7676, hash = "9519c601", required_for={"MASTER"} },
    { path = "master/runtime_loop.lua", size_bytes = 18185, hash = "1d9a0442", required_for={"MASTER"} },
    { path = "master/runtime_ops_monitor.lua", size_bytes = 2634, hash = "8454a2a2", required_for={"MASTER"} },
    { path = "master/runtime_ops_profile.lua", size_bytes = 8994, hash = "1017c3d3", required_for={"MASTER"} },
    { path = "master/runtime_ops_rt.lua", size_bytes = 16692, hash = "45ba275f", required_for={"MASTER"} },
    { path = "master/startup_sequencer.lua", size_bytes = 12914, hash = "40c9d982", required_for={"MASTER"} },
    { path = "master/support_status.lua", size_bytes = 1385, hash = "7e4a2f0e", required_for={"MASTER"} },
    { path = "master/ui/alarms.lua", size_bytes = 7996, hash = "93b8a349", required_for={"MASTER"} },
    { path = "master/ui/alerts.lua", size_bytes = 28137, hash = "4bf57a50", required_for={"MASTER"} },
    { path = "master/ui/energy.lua", size_bytes = 9254, hash = "38fb057f", required_for={"MASTER"} },
    { path = "master/ui/multiview.lua", size_bytes = 20300, hash = "cd241353", required_for={"MASTER"} },
    { path = "master/ui/overview.lua", size_bytes = 13792, hash = "33054a4f", required_for={"MASTER"} },
    { path = "master/ui/resources.lua", size_bytes = 6215, hash = "2137ffd1", required_for={"MASTER"} },
    { path = "master/ui/rt_dashboard.lua", size_bytes = 13157, hash = "391c3c5e", required_for={"MASTER"} },
    { path = "master/ui/widgets.lua", size_bytes = 7637, hash = "24de9664", required_for={"MASTER"} },
    { path = "master/ui/layout.lua", size_bytes = 5981, hash = "bbec1760", required_for={"MASTER"} },
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
    -- nur hinzu, wenn "always = true" ODER "required_for" die gewaehlte
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
    { path = "master/ui_controller.lua", size_bytes = 48151, hash = "0dd366c3", required_for={"MASTER"} },
    { path = "master/ui_diagnostics.lua", size_bytes = 830, hash = "d2a9d0fb", required_for={"MASTER"} },
    },
    rt = {
    { path = "adapters/reactor.lua", size_bytes = 18944, hash = "17252797", required_for={"RT"} },
    { path = "adapters/turbine.lua", size_bytes = 3871, hash = "a9e924f3", required_for={"RT"} },
    { path = "core/control_rails.lua", size_bytes = 8017, hash = "01c1a770", required_for={"RT"} },
    { path = "core/fluid.lua", size_bytes = 5017, hash = "9a5c0bea", required_for={"RT"} },
    { path = "core/turbine_regulator.lua", size_bytes = 14688, hash = "cc80eb87", required_for={"RT"} },
    { path = "nodes/rt/binding.lua", size_bytes = 3507, hash = "87255444", required_for={"RT"} },
    { path = "nodes/rt/command_handler.lua", size_bytes = 10816, hash = "7a13db6f", required_for={"RT"} },
    { path = "nodes/rt/reactor_control.lua", size_bytes = 35938, hash = "f2b4a3af", required_for={"RT"} },
    { path = "nodes/rt/turbine_control.lua", size_bytes = 43953, hash = "f31a53e8", required_for={"RT"} },
    { path = "nodes/rt/capacity_learning.lua", size_bytes = 3907, hash = "4f56566d", required_for={"RT"} },
    { path = "nodes/rt/capacity_cache.lua", size_bytes = 1556, hash = "86f9a268", required_for={"RT"} },
    { path = "nodes/rt/config.lua", size_bytes = 5675, hash = "b4adbfb4", required_for={"RT"} },
    { path = "nodes/rt/config_normalizer.lua", size_bytes = 27009, hash = "be5c4de6", required_for={"RT"} },
    { path = "nodes/rt/discovery_log.lua", size_bytes = 1080, hash = "7d9ceb62", required_for={"RT"} },
    { path = "nodes/rt/discovery_runtime.lua", size_bytes = 13926, hash = "98be547a", required_for={"RT"} },
    { path = "nodes/rt/flow_apply_helpers.lua", size_bytes = 3782, hash = "acc26603", required_for={"RT"} },
    { path = "nodes/rt/health_payload.lua", size_bytes = 2723, hash = "7a3f83b2", required_for={"RT"} },
    { path = "nodes/rt/main.lua", size_bytes = 47730, hash = "d5f46b04", required_for={"RT"} },
    { path = "nodes/rt/module_lifecycle.lua", size_bytes = 27809, hash = "1b235e40", required_for={"RT"} },
    { path = "nodes/rt/monitor_ui.lua", size_bytes = 15609, hash = "1762eae7", required_for={"RT"} },
    { path = "nodes/rt/mockup_pages.lua", size_bytes = 17753, hash = "de97e0d1", required_for={"RT"} },
    { path = "nodes/rt/reactor_steam_guard.lua", size_bytes = 2613, hash = "2f2fa78c", required_for={"RT"} },
    { path = "nodes/rt/startup_diagnostics.lua", size_bytes = 2613, hash = "e5d63978", required_for={"RT"} },
    { path = "nodes/rt/state_handlers.lua", size_bytes = 9257, hash = "bb391437", required_for={"RT"} },
    { path = "nodes/rt/status_snapshot.lua", size_bytes = 6662, hash = "e05cae0b", required_for={"RT"} },
    },
    energy = {
    { path = "nodes/energy/heartbeat.lua", size_bytes = 6671, hash = "9b84841c", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix.lua", size_bytes = 1964, hash = "be7074b3", required_for={"ENERGY"} },
    { path = "adapters/energy_storage.lua", size_bytes = 3648, hash = "fd2dc2e5", required_for={"ENERGY"} },
    { path = "adapters/induction_matrix.lua", size_bytes = 15124, hash = "c3006e4d", required_for={"ENERGY"} },
    { path = "services/matrix_sampling_service.lua", size_bytes = 867, hash = "fff32232", required_for={"ENERGY"} },
    { path = "nodes/energy/command_handler.lua", size_bytes = 1329, hash = "e6b074ac", required_for={"ENERGY"} },
    { path = "nodes/energy/config.lua", size_bytes = 6023, hash = "d84742e5", required_for={"ENERGY"} },
    { path = "nodes/energy/config_normalizer.lua", size_bytes = 6260, hash = "0f3e5f0e", required_for={"ENERGY"} },
    { path = "nodes/energy/discovery_log.lua", size_bytes = 2433, hash = "4f723e27", required_for={"ENERGY"} },
    { path = "nodes/energy/discovery_runtime.lua", size_bytes = 17168, hash = "4d225311", required_for={"ENERGY"} },
    { path = "nodes/energy/main.lua", size_bytes = 25165, hash = "8c3eaa30", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix_snapshot_runtime.lua", size_bytes = 17084, hash = "e1dc1663", required_for={"ENERGY"} },
    { path = "nodes/energy/matrix_topology_cache.lua", size_bytes = 2052, hash = "54dc9081", required_for={"ENERGY"} },
    { path = "nodes/energy/runtime_context.lua", size_bytes = 2098, hash = "c352f2d4", required_for={"ENERGY"} },
    { path = "nodes/energy/status_payload.lua", size_bytes = 9457, hash = "bbfc682a", required_for={"ENERGY"} },
    { path = "nodes/energy/storage_snapshot_runtime.lua", size_bytes = 5751, hash = "aecf0ea6", required_for={"ENERGY"} },
    { path = "nodes/energy/ui_model.lua", size_bytes = 6005, hash = "faa185db", required_for={"ENERGY"} },
    { path = "nodes/energy/ui_pages.lua", size_bytes = 18429, hash = "c0aa3582", required_for={"ENERGY"} },
    },
    water = {
    { path = "nodes/water/config.lua", size_bytes = 3884, hash = "1804d0e7", required_for={"WATER"} },
    { path = "nodes/water/config_normalizer.lua", size_bytes = 989, hash = "09141fba", required_for={"WATER"} },
    { path = "nodes/water/main.lua", size_bytes = 28363, hash = "ca529bd1", required_for={"WATER"} },
    { path = "nodes/water/ui_pages.lua", size_bytes = 10862, hash = "cfbbd586", required_for={"WATER"} },
    { path = "nodes/water/role_descriptor.lua", size_bytes = 152, hash = "c76ee5e7", required_for={"WATER"} },
    },
    fuel = {
    { path = "nodes/fuel/config.lua", size_bytes = 9082, hash = "c298ddd0", required_for={"FUEL"} },
    { path = "nodes/fuel/config_normalizer.lua", size_bytes = 6065, hash = "8eaa6398", required_for={"FUEL"} },
    { path = "nodes/fuel/main.lua", size_bytes = 23711, hash = "7440f389", required_for={"FUEL"} },
    { path = "nodes/fuel/status_snapshot.lua", size_bytes = 5779, hash = "7e6f2625", required_for={"FUEL"} },
    { path = "nodes/fuel/operational_summary.lua", size_bytes = 7915, hash = "0e2fd9d7", required_for={"FUEL"} },
    { path = "nodes/fuel/command_handler.lua", size_bytes = 2305, hash = "24c8f3c7", required_for={"FUEL"} },
    { path = "nodes/fuel/fuel_status_network.lua", size_bytes = 7887, hash = "dc4f4529", required_for={"FUEL"} },
    { path = "nodes/fuel/reactor_targets.lua", size_bytes = 1815, hash = "17439bad", required_for={"FUEL"} },
    { path = "nodes/fuel/monitor_ui.lua", size_bytes = 8274, hash = "ec09cf59", required_for={"FUEL"} },
    { path = "nodes/fuel/ui_completion.lua", size_bytes = 17973, hash = "fba02cac", required_for={"FUEL"} },
    { path = "nodes/fuel/storage.lua", size_bytes = 2379, hash = "31ad81f2", required_for={"FUEL"} },
    { path = "nodes/fuel/ui_pages.lua", size_bytes = 24145, hash = "48c4a07a", required_for={"FUEL"} },
    { path = "nodes/fuel/role_descriptor.lua", size_bytes = 147, hash = "1b38a051", required_for={"FUEL"} },
    { path = "nodes/fuel/logistics_router.lua", size_bytes = 29184, hash = "7d70bcc1", required_for={"FUEL","REPROCESSING"} },
    { path = "nodes/fuel/redstone_router.lua", size_bytes = 48683, hash = "12bdbf84", required_for={"FUEL","REPROCESSING"} },
    { path = "nodes/fuel/router_ui.lua", size_bytes = 40507, hash = "56f89f0a", required_for={"FUEL","REPROCESSING"} },
    },
    reprocessing = {
    { path = "nodes/reprocessor/config.lua", size_bytes = 4079, hash = "1c3b0c7b", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/config_normalizer.lua", size_bytes = 2097, hash = "7b4dd612", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/feed_router.lua", size_bytes = 10882, hash = "acf72d76", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/main.lua", size_bytes = 33113, hash = "8eb66840", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/ui_pages.lua", size_bytes = 11071, hash = "25d5ebdf", required_for={"REPROCESSING"} },
    { path = "nodes/reprocessor/role_descriptor.lua", size_bytes = 177, hash = "3a1d8dc9", required_for={"REPROCESSING"} },
    { path = "nodes/valve/role_descriptor.lua", size_bytes = 152, hash = "aca06242", required_for={"VALVE"} },
    { path = "nodes/valve/config.lua", size_bytes = 2332, hash = "a571ceaf", required_for={"VALVE"} },
    { path = "nodes/valve/controller.lua", size_bytes = 12021, hash = "992adf05", required_for={"VALVE"} },
    { path = "nodes/valve/main.lua", size_bytes = 9036, hash = "5da83e2f", required_for={"VALVE"} },
    },
    log = {
    { path = "nodes/log_collector/main.lua", size_bytes = 51017, hash = "45e0552e", required_for={"LOG"} },
    { path = "nodes/log_collector/mockup_main.lua", size_bytes = 1820, hash = "93f3bf36", required_for={"LOG"} },
    { path = "nodes/log_collector/mockup_ui.lua", size_bytes = 6190, hash = "75b0732e", required_for={"LOG"} },
    { path = "nodes/log_collector/default_ui.lua", size_bytes = 4481, hash = "adeb5fa4", required_for={"LOG"} },
    },
    shared_support = {
    { path = "nodes/support/command_handler.lua", size_bytes = 4496, hash = "50077b45", required_for={"WATER", "FUEL", "REPROCESSING"} },
    { path = "nodes/support/discovery.lua", size_bytes = 1343, hash = "e8aa30c3", required_for={"WATER", "FUEL", "REPROCESSING"} },
    { path = "nodes/support/role_logic.lua", size_bytes = 571, hash = "a3d15a39", required_for={"ENERGY", "WATER", "FUEL", "REPROCESSING", "RT"} },
    { path = "nodes/support/runtime.lua", size_bytes = 9568, hash = "2abf3216", required_for={"WATER", "FUEL", "REPROCESSING", "RT", "ENERGY", "MASTER", "VALVE"} },
    { path = "nodes/support/ui_pages.lua", size_bytes = 6585, hash = "2b86c102", required_for={"WATER", "FUEL", "REPROCESSING", "ENERGY", "RT"} },
    },
  },

  dev_files = {},
}
