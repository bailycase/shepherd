# Paced Changes scrolling

The `ChangesScrollFrameReport` opt-in test drives real NSScrollView clip offsets at a requested
120Hz cadence through synthetic highlighted 3,000-line and long-line files. Each step performs
native layout/display and full-window bitmap capture. It exercises unified and split layouts,
100pt and 300pt steps, and verifies that at least 20,000pt was traversed. It never posts user
input or touches a private checkout.

```
SHEPHERD_PERF_REPORT=1 swift test --no-parallel --filter ChangesScrollFrameReport
SHEPHERD_PERF_REPORT=1 swift test -c release -Xswiftc -DDEBUG --no-parallel --filter ChangesScrollFrameReport
```

The optimized build retains DEBUG instrumentation because some existing test targets require
its counters; it is not an exact shipping binary. Default Release test compilation otherwise
fails on a debug-only ChangesGit counter. Generated test bundles also needed a local Sparkle
framework lookup link. Neither workaround changed tracked build configuration.

## Results before further optimization

| Optimized, capture included | Median interval | p95 | Worst |
| --- | ---: | ---: | ---: |
| Unified, 100pt step | 10.70ms | 11.97ms | 13.60ms |
| Split, 100pt step | 11.04ms | 12.26ms | 14.39ms |
| Unified, 300pt step | 18.82ms | 20.92ms | 30.96ms |
| Split, 300pt step | 20.47ms | 22.01ms | 46.65ms |

Debug 300pt steps measured about 20–21ms median and 22–24ms p95. Optimizing Swift alone does
not remove the bottleneck. Layout/display remains about 15ms at fast steps, with another
3.7–4.9ms for bitmap capture. A test pass establishes exercised behavior, not a frame-rate budget.

These intervals are a paced CPU rendering proxy, **not displayed FPS**. Capture adds work which
the normal compositor may perform differently. The test does not drive a physical trackpad,
exercise repeated real-pointer hover, or measure display presentation/GPU deadlines. It cannot
certify 60Hz or 120Hz smoothness. No such claim is made.

## Experiments rejected

- Fixed row height, tooltip removal and removing an empty note stack: no material improvement.
  Tooltips and existing structure retained.
- Native drawing per row: modest total interval improvement, but capture cost increased; not
  enough to justify a second row renderer and more native views.
- Eight-line drawing blocks: roughly 20–25% lower fast-scroll cost in a trial, but changed the
  pinned-header fold behavior and failed its existing regression. Reverted rather than relaxing
  the test or shipping broken folding/comment/navigation semantics.

No production vertical-scrolling optimization from these experiments was retained. The next
substantial candidate is viewport-level native/tiled rendering which avoids materializing a
SwiftUI view tree for each incoming line while retaining accessible per-line actions, folding,
inline comments, syntax/word colors, navigation IDs and independent horizontal columns.
