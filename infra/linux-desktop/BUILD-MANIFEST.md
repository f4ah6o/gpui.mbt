# Build identity and reusable candidates

Semantic cases declare input actions, expected text/selection and reviewed
output oracles. They do not select one historical executable. The original
golden's source/binary/font hashes remain historical review provenance.

The normal workflow is:

1. Build the current source with the locked profile. The build samples Git
   HEAD/tree, tracked patch and regular untracked files before and after the
   compiler run. Runtime snapshots after protocol preparation bracket that run
   too. A changed source or runtime snapshot invalidates the build claim.
   Git textconv is disabled and assume-unchanged/skip-worktree paths are rejected.
2. Prepare a fresh candidate bundle outside the checkout from that build
   manifest. Copy the executable and provenance snapshots; preserve every
   captured hash. An explicitly supplied executable is labelled `bound`, not
   described as compiled by this workflow.
3. Run one/all semantic cases with that candidate. Verify executable, source,
   toolchain, runtime and font identities before native process launch. Compare
   outputs against predeclared state and reviewed golden bytes; never create or
   promote a golden from the new output.

`build_manifest.py` is an import-safe capture/verification module. The build
command writes `field-build.json` and `field-binary.txt` outside the repository.
`candidate_bundle.py` owns candidate preparation and verification; the case
runner consumes its verified context.

Build manifest version 1 has `kind: gpui-field-build`, `mode: built|bound`,
`source`, `source_consistent`, `binary`, `runtime`, and `command`. Source records
the current local repository identity and tracked patch bytes/hash; it does not
require an already-published commit. Binary records path, SHA-256 and size.
Runtime records the profile/prefix/fontconfig paths, exact file/tree identities,
tool versions, actual compiler/pkg-config commands and generated protocol hashes. Paths in private generated
manifests are allowed; no personal paths or generated manifests are committed.

API:

- `capture_source(repo) -> dict`
- `capture_runtime(profile_root, fontconfig, env, repo) -> dict`
- `write_build_manifest(path, source_before, source_after, binary, runtime, command) -> dict`
- `make_bound_manifest(repo, binary, runtime) -> dict`
- `verify_build_manifest(path) -> dict`
- `verify_runtime(runtime) -> None`

Live source/runtime identities must still match at preparation and execution.
If an iteration changes them, rebuild/prepare a new bundle. This needs no edits
to committed case SHAs. Source links/special untracked entries are rejected
instead of silently omitting possible build inputs. The fonts snapshot retains
the original configuration location for execution, so relative Fontconfig
directories keep their original base.

Fontconfig XML must be self-contained: external includes fail closed until a
complete configuration closure can be captured. The generated profile config
contains only pinned prefix font directories and its owned cache. Font inventory
changes, including added fallback fonts, invalidate existing bundles.
