import SwiftUI
import AppKit
import simd
import ShepherdCore

/// Opaque cover over a just-created agent's pane while its pi process boots
/// (`ShepherdViewModel.beginAgentLaunch` owns when it lifts).
///
/// The Shepherd crook rendered as monochrome ASCII art: the stroke is shaded
/// as a rounded tube for depth, a light pulse travels along the staff toward
/// the hook, and glyphs churn between same-density variants like terminal
/// noise. Primary ink on the terminal background — no color, no chrome; the
/// loading screen is itself a terminal drawing. Static under Reduce Motion.
struct AgentLaunchOverlay: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.terminalBg)
            .overlay {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    scene(t: 0)
                } else {
                    // ~12fps: ASCII churn reads right at terminal cadence,
                    // and the canvas stays cheap.
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                        scene(t: context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .clipped()
    }

    private func scene(t: Double) -> some View {
        VStack(spacing: 18) {
            AsciiCrook(t: t)
                .frame(width: AsciiCrook.displaySize.width, height: AsciiCrook.displaySize.height)
            Text("starting pi…")
                .font(Fonts.mono(11))
                .foregroundStyle(Tokens.textDim)
        }
    }
}

/// One ASCII frame of the crook at absolute time `t`. Pure function of time:
/// incommensurate frequencies, no loop seam, and a resumed timeline never
/// jumps.
private struct AsciiCrook: View {
    let t: Double

    static let field = CrookField.make(cols: 46, rows: 44)
    /// Display cell: mono glyphs are ~0.6 as wide as tall. The grid box was
    /// chosen so this aspect shows the crook undistorted.
    static let displaySize = CGSize(width: 46 * 8.6 * 0.6, height: 44 * 8.6)

    /// Glyph ramp, dim → bright. Variants within a level have similar visual
    /// density; the churn swaps between them without changing the shading.
    private static let ramp: [[String]] = [
        ["·", ",", "'", "`"],
        [":", ";", "i", "!"],
        ["r", "s", "x", "v"],
        ["h", "X", "A", "5"],
        ["M", "#", "@", "W"],
    ]
    private static let levelOpacity: [Double] = [0.30, 0.45, 0.62, 0.80, 1.0]

    var body: some View {
        // Resolved on the main actor; the canvas renderer closure is not.
        let ink = Tokens.textPrimary
        return Canvas { ctx, size in
            let field = Self.field
            let cw = size.width / CGFloat(field.cols)
            let ch = size.height / CGFloat(field.rows)
            let font = Fonts.mono(ch * 0.95)
            // Resolve each (glyph, level) once per frame, not per cell.
            var cache: [Int: GraphicsContext.ResolvedText] = [:]
            func glyph(level: Int, variant: Int, dim: Bool) -> GraphicsContext.ResolvedText {
                let key = (level * 4 + variant) * 2 + (dim ? 1 : 0)
                if let hit = cache[key] { return hit }
                let opacity = dim ? 0.16 : Self.levelOpacity[level]
                let resolved = ctx.resolve(
                    Text(Self.ramp[level][variant])
                        .font(font)
                        .foregroundStyle(ink.opacity(opacity))
                )
                cache[key] = resolved
                return resolved
            }

            let churnTick = Int(t * 2.5)     // glyph swaps ~2.5×/s
            let strayTick = Int(t * 0.8)     // the sparse halo drifts slowly
            for j in 0..<field.rows {
                for i in 0..<field.cols {
                    let cell = field.cells[j * field.cols + i]
                    let at = CGPoint(x: (CGFloat(i) + 0.5) * cw, y: (CGFloat(j) + 0.5) * ch)
                    if cell.d < 1 {
                        // Inside the stroke: rounded-tube shading gives the
                        // 3D read; a pulse flows along the path; per-cell
                        // flicker keeps the fill alive.
                        let tube = (1 - Double(cell.d) * Double(cell.d)).squareRoot()
                        let pulse = 0.74 + 0.26 * sin(Double(cell.s) * 9.4 - t * 1.7)
                        let flick = 0.86 + 0.14 * sin(t * 3.1 + Double(Self.hash(i, j, 0)) * 6.28)
                        let b = max(0, min(0.999, tube * pulse * flick))
                        let level = Int(b * 5)
                        let variant = Int(Self.hash(i, j, churnTick) * 4)
                        ctx.draw(glyph(level: level, variant: variant, dim: false), at: at)
                    } else if cell.d < 2.2, Self.hash(i, j, strayTick) < 0.05 {
                        // Sparse stray glyphs just off the silhouette, like
                        // scatter around the reference render.
                        let variant = Int(Self.hash(j, i, strayTick) * 4)
                        ctx.draw(glyph(level: 0, variant: variant, dim: true), at: at)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Deterministic per-cell pseudo-random in [0, 1).
    private static func hash(_ a: Int, _ b: Int, _ c: Int) -> Float {
        let n = sinf(Float(a) * 127.1 + Float(b) * 311.7 + Float(c) * 74.7) * 43758.547
        return n - floorf(n)
    }
}

/// Precomputed per-cell geometry for the ASCII render: distance to the
/// crook's stroked path (normalized to the stroke radius) and the arc-length
/// parameter of the nearest point (0 at the staff's foot, 1 at the hook tip)
/// for the traveling pulse. Built once; frames only shade it.
struct CrookField {
    struct Cell {
        /// Distance to the path centerline / stroke radius (<1 = inside).
        let d: Float
        /// Normalized arc length of the nearest path point.
        let s: Float
    }

    let cols: Int
    let rows: Int
    let cells: [Cell]

    static func make(cols: Int, rows: Int) -> CrookField {
        // The crook — same path data as App/AppIcon.icon/Assets/crook.svg
        // (1024 grid): staff line up, then three cubics around the hook.
        func cubic(_ p0: SIMD2<Float>, _ c1: SIMD2<Float>, _ c2: SIMD2<Float>,
                   _ p1: SIMD2<Float>, into pts: inout [SIMD2<Float>], steps: Int) {
            for k in 1...steps {
                let u = Float(k) / Float(steps)
                let v = 1 - u
                let p = v * v * v * p0 + 3 * v * v * u * c1 + 3 * v * u * u * c2 + u * u * u * p1
                pts.append(p)
            }
        }
        var pts: [SIMD2<Float>] = [[547.2, 835.2]]
        for k in 1...16 { pts.append([547.2, 835.2 - 480.0 * Float(k) / 16]) } // V355.2
        cubic([547.2, 355.2], [547.2, 233.6], [476.8, 163.2], [384, 163.2], into: &pts, steps: 20)
        cubic([384, 163.2], [291.2, 163.2], [230.4, 233.6], [246.4, 323.2], into: &pts, steps: 20)
        cubic([246.4, 323.2], [256, 371.2], [281.6, 409.6], [320, 438.4], into: &pts, steps: 12)

        // Cumulative arc length for the pulse parameter.
        var arc: [Float] = [0]
        for k in 1..<pts.count {
            arc.append(arc[k - 1] + simd_distance(pts[k], pts[k - 1]))
        }
        let total = arc.last ?? 1

        // Field box in the 1024 grid, with margin for the stray halo. Its
        // aspect (540/860) matches the display grid (cols·0.6/rows) so cells
        // are isotropic and the crook is undistorted.
        let box = SIMD4<Float>(150, 80, 540, 860) // x, y, w, h
        let radius: Float = 36 // slightly chunkier than the icon's 28.8

        var cells: [Cell] = []
        cells.reserveCapacity(cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                let p = SIMD2<Float>(
                    box.x + (Float(i) + 0.5) / Float(cols) * box.z,
                    box.y + (Float(j) + 0.5) / Float(rows) * box.w
                )
                var best = Float.greatestFiniteMagnitude
                var bestS: Float = 0
                for k in 0..<(pts.count - 1) {
                    let a = pts[k], b = pts[k + 1]
                    let ab = b - a
                    let len2 = simd_length_squared(ab)
                    let u = len2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / len2)) : 0
                    let dist = simd_distance(p, a + ab * u)
                    if dist < best {
                        best = dist
                        bestS = (arc[k] + u * simd_distance(a, b)) / total
                    }
                }
                cells.append(Cell(d: best / radius, s: bestS))
            }
        }
        return CrookField(cols: cols, rows: rows, cells: cells)
    }
}
