-- Convention (2026-07-27): every fix/feature commit that changes anything
-- under xreactor/ bumps release_id/manifest_id/manifest_version here by
-- exactly +1 (in lockstep with the same manifest_version/manifest_id
-- fields in xreactor/manifest.lua -- tests/manifest_integrity_consistency_
-- test.lua and tools/offline_validate.lua both fail otherwise). Since this
-- file's own size/hash is tracked in manifest.lua ("release.lua" entry),
-- editing the version numbers here ALSO requires recomputing that one
-- entry afterwards (lua5.2 installer.manifest.crc32 one-liner, see other
-- manifest entries' update history) -- easy to forget since it's self-
-- referential.
return {
  release_id = "beta-v473",
  commit_sha = "beta",
  source_ref = "beta",
  manifest_id = "manifest-v473",
  manifest_version = 473,
  manifest_file_count = 166,
  hash_algo = "crc32",
  manifest_path = "xreactor/manifest.lua",
  installer_core_version = "3.2",
}
