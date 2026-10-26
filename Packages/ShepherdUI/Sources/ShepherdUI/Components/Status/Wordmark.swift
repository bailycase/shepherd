import SwiftUI

/// The shepherd's crook: the product mark. Always lantern amber, on any background.
public struct SHCrook: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width, geo.size.height) / 24
            SHCrookShape()
                .stroke(Color.sh.lantern, style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The crook on the board's 24×24 grid: a stem, the hook over the top, and its curl.
struct SHCrookShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 22))
        path.addLine(to: CGPoint(x: 9, y: 9.5))
        path.addArc(center: CGPoint(x: 14, y: 9.5), radius: 5, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: 19, y: 10))
        path.addArc(center: CGPoint(x: 16.5, y: 10), radius: 2.5, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        let side = min(rect.width, rect.height)
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: side / 24, y: side / 24))
    }
}

/// The wordmark: the crook and "shepherd", lowercase Geist 600, tracked −3% large and −2% small.
public struct SHWordmark: View {
    public enum Size: Sendable { case small, large }
    let size: Size

    public init(size: Size = .small) { self.size = size }

    public var body: some View {
        let (mark, text): (CGFloat, CGFloat) = size == .large ? (30, 26) : (16, 14)
        HStack(spacing: size == .large ? 10 : SH.Space.s) {
            SHCrook().frame(width: mark, height: mark)
            Text("shepherd")
                .font(.shSans(text, .semibold))
                .tracking((size == .large ? -0.03 : -0.02) * text)
                .foregroundStyle(.sh.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shepherd")
    }
}
