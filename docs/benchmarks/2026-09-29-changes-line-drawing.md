# Changes line drawing

A local Debug benchmark compared the existing diff rows with a single SwiftUI Canvas per
unified line or split side. Both used the existing synthetic 40-file review, including a
3,000-line file, long lines, syntax colors and comments. No private checkout data was used.

Command: `SHEPHERD_PERF_REPORT=1 swift test --filter 'ListPerformanceReport/reviewRealistic|ListPerformanceReport/reviewPaneRendering'`.

| Measurement | Before | After |
| --- | ---: | ---: |
| 200pt scroll steps down, mean main-thread CPU | 14.14ms | 11.82ms |
| 200pt scroll steps up, mean main-thread CPU | 14.14ms | 11.78ms |
| Draw docked window after 22pt step, mean CPU | 7.92ms | 3.77ms |
| Draw floating window after 22pt step, mean CPU | 6.87ms | 2.84ms |
| Incoming diff lines per 100 downward 200pt steps | 920 | 920 |

This reduces drawing work rather than hiding lines or weakening row-count budgets. A sample
of the baseline process showed SwiftUI attributed-text measurement/conversion and color
resolution in row layout. Resolving colors per row and changing only text layout produced no
useful gain and were discarded. Drawing the line's gutter, numbers, sign and attributed code
together avoids several independently measured text views. Native row interactions and
accessibility remain outside the Canvas.

The drawing test uses explicit sRGB colors to verify glyph colors, word backgrounds and clipping
for unified/split rows. System semantic `.blue` is not pure RGB blue, so the initial test's
pure-blue pixel threshold was invalid; production drawing required no manual background layer.

A follow-up adds horizontal scrolling with equal split-column widths, measured once per diff
revision/text scale using CoreText. Repeating the same report with it enabled measured
10.56/10.15ms downward/upward fast-scroll CPU and 3.67/2.74ms docked/floating draw CPU. It did
not reverse the rendering improvement. These are single-machine comparative measurements, not guaranteed frame rates. Offscreen clip
scrolling does not exercise a real pointer repeatedly hovering lines, and window capture is a
CPU drawing proxy, not a GPU/render-server trace. Existing hover/comment, row-count and motion
checks remain in place. Real-use scrolling may still have costs outside this renderer change.
