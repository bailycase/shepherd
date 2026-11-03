# Full measurement distributions

Release data paths. n=3 unless explicitly n=1; no stable tail quantiles inferred.

| Metric | Samples | Median | Range | Unit | n |
|---|---|---:|---|---|---:|
| history.1.1MiB.decode | 8.15075, 7.59571, 7.38363 | 7.59571 | 7.38363–8.15075 | ms | 3 |
| history.1.1MiB.project | 0.961, 0.698709, 0.674416 | 0.698709 | 0.674416–0.961 | ms | 3 |
| history.1.1MiB.release | 0.035291, 0.02825, 0.026959 | 0.02825 | 0.026959–0.035291 | ms | 3 |
| history.1.1MiB.total | 9.11175, 8.29442, 8.05804 | 8.29442 | 8.05804–9.11175 | ms | 3 |
| history.4.3MiB.decode | 28.9005, 28.4162, 28.6268 | 28.6268 | 28.4162–28.9005 | ms | 3 |
| history.4.3MiB.project | 3.01358, 2.90338, 2.76025 | 2.90338 | 2.76025–3.01358 | ms | 3 |
| history.4.3MiB.release | 0.139834, 0.120792, 0.119292 | 0.120792 | 0.119292–0.139834 | ms | 3 |
| history.4.3MiB.total | 31.914, 31.3195, 31.387 | 31.387 | 31.3195–31.914 | ms | 3 |
| history.12.8MiB.decode | 84.37, 85.1201, 85.5441 | 85.1201 | 84.37–85.5441 | ms | 3 |
| history.12.8MiB.project | 9.10504, 8.68546, 8.69708 | 8.69708 | 8.68546–9.10504 | ms | 3 |
| history.12.8MiB.release | 0.421583, 0.506334, 0.425875 | 0.425875 | 0.421583–0.506334 | ms | 3 |
| history.12.8MiB.total | 93.475, 93.8055, 94.2412 | 93.8055 | 93.475–94.2412 | ms | 3 |
| project.output16384bytes | 0.25542, 0.2225, 0.22292 | 0.22292 | 0.2225–0.25542 | us/row | 3 |
| project.output1048576bytes | 0.70375, 0.67083, 0.58209 | 0.67083 | 0.58209–0.70375 | us/row | 3 |
| project.output12582912bytes | 0.85, 0.56, 0.56875 | 0.56875 | 0.56–0.85 | us/row | 3 |
| thinking.1000 | 5.53367, 5.5255, 5.54904 | 5.53367 | 5.5255–5.54904 | ms | 3 |
| thinking.2000 | 13.327, 13.0203, 14.0615 | 13.327 | 13.0203–14.0615 | ms | 3 |
| thinking.4000 | 31.5529, 30.3777, 28.9812 | 30.3777 | 28.9812–31.5529 | ms | 3 |
| stream.decodeDelta | 3.44014, 3.29514, 3.32653 | 3.32653 | 3.29514–3.44014 | us/event | 3 |
| stream.handleDelta.tools0 | 2.44188, 2.40242, 2.44529 | 2.44188 | 2.40242–2.44529 | us/event | 3 |
| stream.handleDelta.tools10 | 5.24567, 5.09969, 4.95085 | 5.09969 | 4.95085–5.24567 | us/event | 3 |
| stream.handleDelta.tools50 | 15.2004, 15.6353, 15.463 | 15.463 | 15.2004–15.6353 | us/event | 3 |
| snapshot.fresh.roundTrip | 0.095375, 0.064583, 0.060625 | 0.064583 | 0.060625–0.095375 | ms | 3 |
| snapshot.unchanged.roundTrip | 0.031042, 0.019708, 0.039458 | 0.031042 | 0.019708–0.039458 | ms | 3 |
| status.30agents.cpu | 0.027, 0.027, 0.026 | 0.027 | 0.026–0.027 | ms/report | 3 |
| status.100agents.cpu | 0.082, 0.081, 0.081 | 0.081 | 0.081–0.082 | ms/report | 3 |
| status.300agents.cpu | 0.514, 0.511, 0.507 | 0.511 | 0.507–0.514 | ms/report | 3 |
| queue.reload4MiB.worst | 2.643 | 2.643 | 2.643–2.643 | ms | 1 |
| queue.reload12MiB.worst | 1.2 | 1.2 | 1.2–1.2 | ms | 1 |
| relaunch.8x4MiB.firstReady | 101.903, 141.913, 144.384 | 141.913 | 101.903–144.384 | ms | 3 |
| relaunch.8x4MiB.allReady | 108.901, 147.633, 150.376 | 147.633 | 108.901–150.376 | ms | 3 |
| relaunch.8x4MiB.queueWorst | 0.985, 0.568, 0.862 | 0.862 | 0.568–0.985 | ms | 3 |
| relaunch.8x4MiB.stateReadWorst | 0.028, 0.012, 0.006 | 0.012 | 0.006–0.028 | ms | 3 |
| relaunch.8x4MiB.connectsRefused | 0, 0, 0 | 0 | 0–0 | connects | 3 |
| relaunch.30x4MiB.firstReady | 174.11, 215.215, 167.676 | 174.11 | 167.676–215.215 | ms | 3 |
| relaunch.30x4MiB.allReady | 276.676, 265.294, 273.333 | 273.333 | 265.294–276.676 | ms | 3 |
| relaunch.30x4MiB.queueWorst | 5.656, 5.155, 3.955 | 5.155 | 3.955–5.656 | ms | 3 |
| relaunch.30x4MiB.stateReadWorst | 0.003, 0.213, 0.083 | 0.083 | 0.003–0.213 | ms | 3 |
| relaunch.30x4MiB.connectsRefused | 0, 0, 0 | 0 | 0–0 | connects | 3 |
| store.tailRefresh.50turns | 0.325625, 0.342792, 0.222708 | 0.325625 | 0.222708–0.342792 | ms | 3 |
| store.tailRefresh.500turns | 2.45267, 2.31617, 2.16533 | 2.31617 | 2.16533–2.45267 | ms | 3 |
| store.tailRefresh.2500turns | 10.8106, 10.9526, 9.84971 | 10.8106 | 9.84971–10.9526 | ms | 3 |
| state.encode.30agents | 0.229625, 0.213875, 0.228667 | 0.228667 | 0.213875–0.229625 | ms | 3 |
| state.decode.30agents | 0.220584, 0.233833, 0.224166 | 0.224166 | 0.220584–0.233833 | ms | 3 |
| state.encode.300agents | 1.96621, 1.98, 1.97004 | 1.97004 | 1.96621–1.98 | ms | 3 |
| state.decode.300agents | 1.79329, 1.79833, 1.78442 | 1.79329 | 1.78442–1.79833 | ms | 3 |
| state.encode.3000agents | 20.458, 19.0721, 19.0572 | 19.0721 | 19.0572–20.458 | ms | 3 |
| state.decode.3000agents | 18.1958, 18.1399, 17.8845 | 18.1399 | 17.8845–18.1958 | ms | 3 |
| framing.65536bytes.1024chunk | 1.24729, 1.20738, 1.19842 | 1.20738 | 1.19842–1.24729 | ms | 3 |
| framing.65536bytes.65536chunk | 1.30833, 1.27825, 1.29987 | 1.29987 | 1.27825–1.30833 | ms | 3 |
| framing.1048576bytes.1024chunk | 12.8899, 12.6413, 13.075 | 12.8899 | 12.6413–13.075 | ms | 3 |
| framing.1048576bytes.65536chunk | 11.8853, 11.1749, 11.7664 | 11.7664 | 11.1749–11.8853 | ms | 3 |

## Workload notes and source logs

- **history.1.1MiB.decode**: messages=240; `reduced-release-data/full.log`
- **history.1.1MiB.project**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.1.1MiB.release**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.1.1MiB.total**: ; paired decode+projection sums (original BENCH total is sum of medians); `reduced-release-data/full.log`
- **history.4.3MiB.decode**: messages=944; `reduced-release-data/full.log`
- **history.4.3MiB.project**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.4.3MiB.release**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.4.3MiB.total**: ; paired decode+projection sums (original BENCH total is sum of medians); `reduced-release-data/full.log`
- **history.12.8MiB.decode**: messages=2816; `reduced-release-data/full.log`
- **history.12.8MiB.project**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.12.8MiB.release**: existing benchmark fixture; `reduced-release-data/full.log`
- **history.12.8MiB.total**: ; paired decode+projection sums (original BENCH total is sum of medians); `reduced-release-data/full.log`
- **project.output16384bytes**: existing benchmark fixture; `reduced-release-data/full.log`
- **project.output1048576bytes**: existing benchmark fixture; `reduced-release-data/full.log`
- **project.output12582912bytes**: existing benchmark fixture; `reduced-release-data/full.log`
- **thinking.1000**: 77000 streamed bytes; `reduced-release-data/full.log`
- **thinking.2000**: 154000 streamed bytes; `reduced-release-data/full.log`
- **thinking.4000**: 308000 streamed bytes; `reduced-release-data/full.log`
- **stream.decodeDelta**: existing benchmark fixture; `release-server-1/full.log`
- **stream.handleDelta.tools0**: existing benchmark fixture; `release-server-1/full.log`
- **stream.handleDelta.tools10**: existing benchmark fixture; `release-server-1/full.log`
- **stream.handleDelta.tools50**: existing benchmark fixture; `release-server-1/full.log`
- **snapshot.fresh.roundTrip**: bytes=182504 messages=50; `release-server-1/full.log`
- **snapshot.unchanged.roundTrip**: existing benchmark fixture; `release-server-1/full.log`
- **status.30agents.cpu**: state.json rewritten: false; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **status.100agents.cpu**: state.json rewritten: false; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **status.300agents.cpu**: state.json rewritten: false; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **queue.reload4MiB.worst**: over16ms=0 of 122 probes, p99=0.9ms; `release-server-1/full.log`
- **queue.reload12MiB.worst**: over16ms=0 of 242 probes, p99=0.9ms; `release-server-1/full.log`
- **relaunch.8x4MiB.firstReady**: existing benchmark fixture; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.8x4MiB.allReady**: existing benchmark fixture; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.8x4MiB.queueWorst**: over16ms=0 of 59; over16ms=0 of 80; over16ms=0 of 81; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.8x4MiB.stateReadWorst**: total blocked 0ms over 45 reads; total blocked 0ms over 61 reads; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.8x4MiB.connectsRefused**: of 40; INVALID success-rate inference: sampled before detached connector finishes; raw values retained only.; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.30x4MiB.firstReady**: existing benchmark fixture; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.30x4MiB.allReady**: existing benchmark fixture; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.30x4MiB.queueWorst**: over16ms=0 of 116; over16ms=0 of 112; over16ms=0 of 126; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.30x4MiB.stateReadWorst**: total blocked 0ms over 96 reads; total blocked 0ms over 94 reads; total blocked 0ms over 102 reads; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **relaunch.30x4MiB.connectsRefused**: of 150; INVALID success-rate inference: sampled before detached connector finishes; raw values retained only.; `release-server-1/full.log, release-server-2/full.log, release-server-3/full.log`
- **store.tailRefresh.50turns**: historyRows=100 displayedRows=100 warmup=1 noView=true; `extra-release-data/full.log`
- **store.tailRefresh.500turns**: historyRows=1000 displayedRows=1000 warmup=1 noView=true; `extra-release-data/full.log`
- **store.tailRefresh.2500turns**: historyRows=5000 displayedRows=5000 warmup=1 noView=true; `extra-release-data/full.log`
- **state.encode.30agents**: bytes=14546 warmup=1; `extra-release-data/full.log`
- **state.decode.30agents**: bytes=14546 warmup=1; `extra-release-data/full.log`
- **state.encode.300agents**: bytes=144006 warmup=1; `extra-release-data/full.log`
- **state.decode.300agents**: bytes=144006 warmup=1; `extra-release-data/full.log`
- **state.encode.3000agents**: bytes=1444006 warmup=1; `extra-release-data/full.log`
- **state.decode.3000agents**: bytes=1444006 warmup=1; `extra-release-data/full.log`
- **framing.65536bytes.1024chunk**: framesPerSample=100 warmup=1 framingOnly=true; `extra-release-data/full.log`
- **framing.65536bytes.65536chunk**: framesPerSample=100 warmup=1 framingOnly=true; `extra-release-data/full.log`
- **framing.1048576bytes.1024chunk**: framesPerSample=100 warmup=1 framingOnly=true; `extra-release-data/full.log`
- **framing.1048576bytes.65536chunk**: framesPerSample=100 warmup=1 framingOnly=true; `extra-release-data/full.log`

## Debug off-screen UI — not app/device performance

Values below are one workload result per process (three process runs). Ten streamed updates and twenty highlight moves are operations within each workload, not independent sample counts.
Existing scroll p95/p99 outputs are within-workload descriptive statistics, not three-run tail estimates. One scroll line was interleaved with a SwiftPM warning; retained verbatim and excluded from numeric inference.

- **palette (1000 results) | open**: 30.4 ms; 38.9 ms; 40.1 ms; median 38.900ms (n=3)
- **palette (1000 results) | open: rows**: palette.row 14, paletteOverlay 1; palette.row 14, paletteOverlay 1; palette.row 14, paletteOverlay 1
- **palette (1000 results) | move the highlight ×20: mean**: 1.8 ms; 1.7 ms; 1.5 ms; median 1.700ms (n=3)
- **palette (1000 results) | move the highlight ×20: rows**: palette.row 40; palette.row 40; palette.row 40
- **palette (1000 results) ↓ | scroll: steps · mean · p95 · worst**: 224 · 4.56 ms · 5.25 ms · 5.64 ms (26572 pt); 224 · 4.63 ms · 5.69 ms · 6.96 ms (26572 pt); 224 · 4.49 ms · 5.49 ms · 6.28 ms (26572 pt)
- **palette (1000 results) ↓ | scroll: main-thread CPU mean · p50 · p95**: 4.55 ms · 4.59 ms · 5.23 ms; 4.62 ms · 4.55 ms · 5.69 ms; 4.48 ms · 4.42 ms · 5.47 ms
- **palette (1000 results) ↓ | scroll: instructions mean · p95**: 44.7 M · 50.0 M; 44.7 M · 50.0 M; 44.7 M · 49.9 M
- **palette (1000 results) | scroll: rows**: palette.row 949; palette.row 949; palette.row 949
- **palette (40 results) | open**: 25.3 ms; 21.6 ms; 15.3 ms; median 21.600ms (n=3)
- **palette (40 results) | open: rows**: palette.row 10, paletteOverlay 1; palette.row 10, paletteOverlay 1; palette.row 10, paletteOverlay 1
- **palette (40 results) | move the highlight ×20: mean**: 0.6 ms; 0.6 ms; 0.6 ms; median 0.600ms (n=3)
- **palette (40 results) | move the highlight ×20: rows**: palette.row 19; palette.row 19; palette.row 19
- **palette (40 results) ↓ | scroll: steps · mean · p95 · worst**: 1 · 0.03 ms · 0.03 ms · 0.03 ms (0 pt); 1 · 0.04 ms · 0.04 ms · 0.04 ms (0 pt); 1 · 0.04 ms · 0.04 ms · 0.04 ms (0 pt)
- **palette (40 results) ↓ | scroll: main-thread CPU mean · p50 · p95**: 0.03 ms · 0.03 ms · 0.03 ms; 0.04 ms · 0.04 ms · 0.04 ms; 0.04 ms · 0.04 ms · 0.04 ms
- **palette (40 results) ↓ | scroll: instructions mean · p95**: 0.1 M · 0.1 M; 0.2 M · 0.2 M; 0.1 M · 0.1 M
- **palette (40 results) | scroll: rows**: none; none; none
- **thread (50 turns) | open (load + first layout)**: 113.1 ms; 103.2 ms; 125.1 ms; median 113.100ms (n=3)
- **thread (50 turns) | open: rows**: composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 17, layout.composerControlsMinimum 9, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2; composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 17, layout.composerControlsMinimum 9, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2; composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 17, layout.composerControlsMinimum 9, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2
- **thread (50 turns) ↑ | scroll: steps · mean · p95 · worst**: 34 · 6.56 ms · 11.27 ms · 11.60 ms (10382 pt); 34 · 6.56 ms · 11.41 ms · 12.55 ms (10382 pt); 34 · 6.52 ms · 11.40 ms · 11.85 ms (10382 pt)
- **thread (50 turns) ↑ | scroll: main-thread CPU mean · p50 · p95**: 6.54 ms · 8.15 ms · 11.25 ms; 6.54 ms · 8.02 ms · 11.39 ms; 6.50 ms · 8.20 ms · 11.29 ms
- **thread (50 turns) ↑ | scroll: instructions mean · p95**: 60.6 M · 111.2 M; 58.9 M · 104.6 M; 58.6 M · 104.7 M
- **thread (50 turns) ↓ | scroll: steps · mean · p95 · worst**: 23 · 7.01 ms · 11.04 ms · 15.18 ms (9825 pt); 23 warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.; 23 warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.
- **thread (50 turns) ↓ | scroll: main-thread CPU mean · p50 · p95**: 6.97 ms · 7.44 ms · 11.03 ms; 7.21 ms · 7.81 ms · 12.83 ms; 7.61 ms · 6.89 ms · 13.88 ms
- **thread (50 turns) ↓ | scroll: instructions mean · p95**: 68.0 M · 107.2 M; 67.9 M · 107.8 M; 67.3 M · 108.6 M
- **thread (50 turns) | scroll up and back: rows**: layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 54, thread.rowBuilder 212, thread.userTurn 55; layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 54, thread.rowBuilder 212, thread.userTurn 55; layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 54, thread.rowBuilder 212, thread.userTurn 55
- **thread (50 turns) | stream a chunk ×10: store refresh mean**: 1.2 ms; 1.3 ms; 1.3 ms; median 1.300ms (n=3)
- **thread (50 turns) | stream a chunk ×10: view update mean**: 13.9 ms; 14.4 ms; 14.6 ms; median 14.400ms (n=3)
- **thread (50 turns) | stream a chunk ×10: rows**: arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 458, thread.view 10; arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 458, thread.view 10; arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 458, thread.view 10
- **thread (500 turns) | open (load + first layout)**: 118.1 ms; 128.5 ms; 131.2 ms; median 128.500ms (n=3)
- **thread (500 turns) | open: rows**: composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 12, layout.composerControlsMinimum 6, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2; composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 12, layout.composerControlsMinimum 6, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2; composer.body 2, composer.chips 6, composer.contextMeter 1, layout.composerControlsMeasured 12, layout.composerControlsMinimum 6, thread.agentTurn 20, thread.rowBuilder 80, thread.userTurn 19, thread.view 2
- **thread (500 turns) ↑ | scroll: steps · mean · p95 · worst**: 60 · 7.08 ms · 12.30 ms · 13.31 ms (20295 pt); 60 · 6.68 ms · 11.47 ms · 12.07 ms (20295 pt); 60 · 6.99 ms · 11.91 ms · 12.98 ms (20295 pt)
- **thread (500 turns) ↑ | scroll: main-thread CPU mean · p50 · p95**: 7.07 ms · 8.95 ms · 12.28 ms; 6.67 ms · 8.20 ms · 11.47 ms; 6.98 ms · 8.78 ms · 11.89 ms
- **thread (500 turns) ↑ | scroll: instructions mean · p95**: 63.3 M · 113.2 M; 63.3 M · 113.5 M; 63.7 M · 113.2 M
- **thread (500 turns) ↓ | scroll: steps · mean · p95 · worst**: 52 · 6.75 ms · 11.33 ms · 12.warning: '--build-system native' has been deprecated and will be removed in a future release; please report an issue at https://github.com/swiftlang/swift-package-manager/issues if you are unable to adopt the default build system.; 52 · 6.56 ms · 11.96 ms · 12.21 ms (15300 pt); 52 · 6.72 ms · 11.84 ms · 12.60 ms (15300 pt)
- **thread (500 turns) ↓ | scroll: main-thread CPU mean · p50 · p95**: 6.75 ms · 8.26 ms · 11.32 ms; 6.55 ms · 7.81 ms · 11.92 ms; 6.72 ms · 8.75 ms · 11.83 ms
- **thread (500 turns) ↓ | scroll: instructions mean · p95**: 63.0 M · 110.1 M; 63.2 M · 110.6 M; 62.9 M · 110.1 M
- **thread (500 turns) | scroll up and back: rows**: layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 105, thread.rowBuilder 442, thread.userTurn 105; layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 105, thread.rowBuilder 442, thread.userTurn 105; layout.composerControlsMeasured 5, layout.composerControlsMinimum 3, thread.agentTurn 105, thread.rowBuilder 442, thread.userTurn 105
- **thread (500 turns) | stream a chunk ×10: store refresh mean**: 10.6 ms; 10.8 ms; 11.0 ms; median 10.800ms (n=3)
- **thread (500 turns) | stream a chunk ×10: view update mean**: 33.2 ms; 32.7 ms; 35.2 ms; median 33.200ms (n=3)
- **thread (500 turns) | stream a chunk ×10: rows**: arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 417, thread.userTurn 1, thread.view 10; arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 414, thread.userTurn 1, thread.view 10; arrival.animates 1, layout.composerControlsMeasured 50, layout.composerControlsMinimum 30, thread.agentTurn 10, thread.rowBuilder 417, thread.userTurn 1, thread.view 10
