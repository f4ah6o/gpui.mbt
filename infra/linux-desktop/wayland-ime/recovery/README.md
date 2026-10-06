# Self-contained native IME reset recovery

This is a new recovery recipe and source closure. It preserves the historical
`../deployment.lock.json` and `../qualification.json` unchanged. It does not
recover lost historical helper bytes, relabel new Mozc/client bytes with old
hashes, or inherit earlier native qualification.

The replacement baseline utilities and strict Gio parser are included here as
complete source with adversarial tests. The public `case_runner.py` retains its
existing `PrivateX` implementation. No private helper directory is needed.

## Recover and bind

1. Run `../../gpui-desktop.py bootstrap` with the unchanged official package lock into a new private profile
   root, then `doctor --build-only --input-e2e`. The exact 106 Debian packages,
   MoonBit/core archives, and host prerequisites remain those in the original
   profile lock. Preserve the verified archive cache when available.
2. Run the unchanged `../../mozc-prefix/rebuild.py` with
   `PYTHONDONTWRITEBYTECODE=1` into a new empty build root.
   It verifies exact official source/build archives and protected IPC source;
   the new server-directory-bound client records fresh engine/component hashes
   with `native_conversion_tested: false`.
3. Build the actual app from its reviewed immutable source checkout into a
   fresh external build directory. Keep its genuine `field-build.json`; bound
   or stale-source manifests are rejected. Adding/changing recovery tooling
   requires an honest new combined-source manifest when app and recovery IaC
   share one reviewed checkout. If any captured source changes, rebuild it.
4. Review the new engine/component/build-result and candidate-manifest hashes.
   Supply those exact expected identities and explicit roots to the constructor:

```sh
/usr/bin/python3 prepare_deployment.py \
  --profile-root /private/recovered-profile \
  --mozc-build-root /private/new-mozc-build \
  --candidate-repo /source/immutable-app \
  --candidate-build-root /private/fresh-app-build \
  --candidate-manifest /private/fresh-app-build/field-build.json \
  --output-root /private/new-native-evidence \
  --output /private/new-native-evidence/recovery-deployment.json \
  --expected-engine-sha256 REVIEWED_ENGINE_SHA256 \
  --expected-component-sha256 REVIEWED_COMPONENT_SHA256 \
  --expected-mozc-build-result-sha256 REVIEWED_BUILD_RESULT_SHA256 \
  --expected-candidate-manifest-sha256 REVIEWED_CANDIDATE_MANIFEST_SHA256
```

Run the command from this directory, replacing every example path/hash with
the reviewed actual identity. Alternatively the candidate build manifest may
be directly beside the profile's `installed.json`, while its executable still
belongs to the explicitly declared external candidate build root. The output
root must be fresh or bear this constructor's exact private ownership marker;
existing deployment files are never overwritten.

The recovery entries enforce `PYTHONDONTWRITEBYTECODE=1` (and disable bytecode
in their Python process) for bootstrap/doctor/native children and read-only
evidence/runtime probes. A fresh archive-extracted prefix contains no generated
GI bytecode caches. Their absence is part of the complete pinned tree, not an
ignored-file policy. Earlier cache-bearing prefixes/builds remain diagnostic
artifacts; use a new cache-free recovery root and rebuild directory.

The constructor verifies the complete pinned prefix tree, package-derived
resources and config, bounded official Mozc build result/source/archive
identities, exact current app source/runtime/binary, trusted tool paths before
read-only version/font probes, and the complete current public recovery source
closure. Foreign source/runtime/config/tool paths, changed hashes, symlinks,
duplicate JSON fields, unsupported wrappers, output overlap, and stale builds
fail closed. It writes a new `prepared-native-unqualified` profile with
`native_qualified: false`. It never launches services, opens a display, or sends
input. Actual private roots are recorded in the generated deployment, not
embedded in this reusable source.

## Review and qualify separately

After independent source/runtime/pin review, use the existing GPUI overlay and
launcher helpers with this new recovery deployment as their explicit baseline.
Preparation and `--check` reverify the complete new closure through the narrow
recovery-kind preflight hook. Use the approved own-cloud native application
launch route only after that review and authorization. Exact-current held
shortcuts, genuine native protocol/Gio evidence, accepted presentations,
private pixels, and identity-bound cleanup must pass before reporting a new
qualification. No old result or static Green substitutes for that run.

```sh
/usr/bin/python3 prepare_deployment.py --check /private/new-native-evidence/recovery-deployment.json
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_baseline_utilities test_transport_diagnostics test_prepare_deployment -v
```

This remains a bounded Debian 13 amd64 recipe, not a hermetic OS image or a
production-wide IME claim. Host ABI, dynamically loaded libraries, and native
launch permissions are explicit prerequisites. Changed host/prefix/tool/helper
identities require a separately reviewed recipe update and fresh qualification;
the constructor never silently selects newer packages or rewrites old pins.

Strict process-ownership scan errors remain failures. The successor GPUI
finalizer records incomplete scan/error details in a terminal failed receipt
and retains its private runtime instead of treating an unknown scan as empty
or successful cleanup. Its owned no-clobber launcher log captures fd1/fd2
diagnostics only after exact source/runtime preflight; it is a bounded task
log, not a generic command interface. Earlier runs without a terminal receipt
remain cleanup-unverified and are never retroactively promoted to PASS.

Fresh recovery profiles declare `ownership_model: gpui-task-owner-birth-v1`.
The native entry captures its own stable UID/PID/starttime before output,
runtime or child creation and seals that snapshot into the terminal evidence.
Every private root, UI and IPC peer must belong to that fresh birth scope;
strictly older stable processes are excluded before environment access, while
same-tick/newer unreadable or ambiguous entries fail closed. Bounded cleanup
censuses record the owner, explicit caller exclusion and older/proven-terminal
exclusions. Receipt validation succeeds before private runtime deletion. The
result claims cleanup only for that fresh task's nonce/HOME/config descendants.
It neither adopts an existing service nor verifies/deletes an older runtime.
