# Failed Kotoeri A/B evidence, 2026-10-07

**NOT Product Green.** [RESULT.md](RESULT.md) separates observations, exploratory
runs, diagnostics, test results, and limitations. PR45's archive is untouched.

- `experiment-a/`: immediate-preview collector, initial screenshot only.
- `normal/`: same binary/dylib, normal capture handshake, initial/composition PNGs.
- `B-final.log`: new minimal NSTextView control, same app-local CGEvent producer.
- `provenance.json`: exact source/tree and build-fix separation, binary hashes.
- `files-sha256.json`: archive inventory (excludes itself and validation.log).
- `validate.py`: failure-contract/hash/partial-pixel/cleanup validator; rejects
  Product Green. Run from any directory with `python3 /path/to/validate.py`.

`run.py` is the final local launch-activation driver, with its historical paths.
It targets the exact spawned app PID/executable and propagates the collector exit
code. `activate_owned_app.m` is copied from PR45; compile it at the driver path
before replay. See `../../KOTOERI_DIAGNOSTICS.md` for reusable commands/options.
Earlier raw/alternative control runs are secondary exploratory records. Their
transient native timing setup varied; no bit-identical replay claim is made for
those variants. Compiled binaries/toolchains are not included in the archive.

The stored summaries describe clean source commit `8a7cf7c`, before this archive
was added. They are historical source snapshots, not claims that the source
currently including the archive is byte-identical. Product Green validation
rejects both failed summaries before comparing current source state.
