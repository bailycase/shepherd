# Post-fix optimized measurements

Measured implementation: `f7a3f49e0b1210494aefb57d34b0fbaad2c35a26`, before the subsequent
iOS-only table-map compile adapter. Same archived synthetic fixture, compiled with `-O` against
the normal Release modules. Three repetitions run serially without competing performance-lane
builds. See [comparison.json](comparison.json) for every sample, baseline, source and caveat;
commands and exit statuses accompany each raw run. Original logs are stored byte-for-byte as
`full.log.gz` (decompress with `gzip -dc`), preserving trailing whitespace without lint exemptions.
No images, credentials or user histories.

| Workload | Baseline ms | After ms |
| --- | ---: | ---: |
| Tail refresh, 100 messages / 50 turns | 0.326 | 0.076 |
| Tail refresh, 1,000 messages / 500 turns | 2.316 | 0.404 |
| Tail refresh, 5,000 messages / 2,500 turns | 10.811 | 1.863 |
| History decode, 1.1 MiB | 7.596 | 6.709 |
| History decode, 4.3 MiB | 28.627 | 26.236 |
| History decode, 12.8 MiB | 85.120 | 78.184 |
| Thinking reduction, 4,000 chunks | 30.378 | 27.320 |
| Queue reload worst, 4 MiB | 2.643 | 0.323 |
| Queue reload worst, 12 MiB | 1.200 | 0.805 |
| Stub relaunch all-ready, 8 agents | 147.633 | 95.482 |
| Stub relaunch all-ready, 30 agents | 273.333 | 235.172 |
| Status reports, 100 agents (ms/report) | 0.081 | 0.095 |
| Workspace decode, 300 agents | 1.793 | 1.876 |

**Interpretation:** tail refresh is the strongest result, about 5.8× faster at 5,000 messages.
It still scales with loaded history, so this is not an O(1) claim. Small regressions are retained,
not omitted. Three run-summary medians are not pooled raw workload samples; baseline repetition
structure differs. Treat small differences and maxima as descriptive, not statistically established.

These are M4 Max synthetic data-path measurements, not presented frames, UI latency, physical
iPhone/iPad, provider time-to-first-token or competitive app benchmarks. Stub startup is not app
startup. History totals differ in instrumentation and are not compared. Connector zero-duration
observations prove no connection success rate. Snapshot “fresh” measurements hit the cache.

For reproduction use the archived `benchmark-final.py.txt` with paths relocated to a clean
checkout/scratch directory after `swift test --build-system native -c release -j 2 list`.
The `.swift.txt` fixture is copied to scratch as `.swift`, never edited. That extension correction
was the sole missing-fixture failure; no failed timing run was silently converted to success.
