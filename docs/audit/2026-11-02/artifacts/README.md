# Measurement provenance

These are archived inputs/results, not a new production benchmark runner. See
[measurements](../measurements.md) and [all samples](../distributions.md) first.

- `measurements.json`: individual samples, units, provenance, medians and ranges. Some metrics
  have only one multi-turn workload. No stable p95/p99 is inferred.
- `environment.json`: hardware, OS, compiler and pinned commit. Inherited environment **names**
  were recorded for diagnosis; the child environment itself was allowlisted without credentials.
- `release-compiler-inputs.json`: exact compiler commands/source membership used for the optimized
  modules. Production sources were unchanged; `-O`, whole-module optimization and `-enable-testing`
  were used, without DEBUG. This is not a shipping app build.
- `selection.json` and `Package.swift.txt`: reduced test target membership and manifest. The normal
  Release test build could not compile unrelated DEBUG-only counter references. Blank lines in
  the archived manifest are whitespace-normalized; the instrumentation patch's final hunk uses
  reduced context. These archival changes do not alter the compiled source or patch result.
- `benchmark-instrumentation.diff`: the only change in the measurement checkout: cap existing
  5/15 repeats at three and print raw samples. Apply only to a dedicated scratch checkout of
  `f80d01132` when reproducing. The report branch changes no production/test source.
- `ExtraDataPaths.swift.txt`: exact scratch fixture for tail refresh, state JSON and framing.
  It links optimized production modules; it deliberately excludes views/network/providers.
- `run.py.txt`: bounded allowlisted-process wrapper used for every recorded command.
- `runs/*/command.json` and `result.json`: exact commands, isolated environment, timeout, exit code
  and command duration. Build/command duration is not workload latency.

The `.txt` source archives are intentionally not auto-discovered build/test inputs. Reproduction
requires an isolated checkout, the pinned dependency artifacts and the recorded compiler setup;
these manifests are not a portable one-command harness. Paths in historical commands refer to
`/Users/bailycase/Developer/Shepherd-perf-bench-2026-11-02` and
`/tmp/shepherd-perf-2026-11-02`; relocate them consistently for another machine. Retain the existing
`ShepherdTestSupport` isolation. Never substitute the installed app, real support directory or
user credentials. The large copied production tree and dependency binaries are not archived here.

The original full logs, reduced harness tree, copied test/support sources and result files remain
at `/tmp/shepherd-perf-2026-11-02` on the audit machine. Log paths within JSON are relative to that
root; full logs are not included in this documentation bundle. Samples, manifests and exit records
are preserved here so the conclusions do not depend on the temporary logs surviving.

## Interpretation exclusions

- `relaunch.*` uses Python stub processes, not the actual engine or app. The connector-refusal
  counter is read before the detached connector completes; its raw zeros are **not** success-rate
  evidence. Keep the raw record, exclude that inference.
- `snapshot.fresh.roundTrip` requests an already-ready revision; it is not an uncached
  changed-history snapshot benchmark.
- `history.*.total` samples here are paired decode+projection sums; the original benchmark's
  printed total sums medians. These statistics are not generally identical.
- Debug offscreen view timings are separate from Release data paths. Neither establishes iPhone,
  iPad, energy, thermal, actual app startup, provider latency or competitor performance.
- No user conversation contents, auth secrets or production trace payloads are included.
