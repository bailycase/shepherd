import SwiftUI

/// A slash command the user sent, leading their bubble (SentCommandsA): "Used skill
/// swiftui-specialist" or "Sent prompt review" in place of the text pi expanded it to, with the
/// user's own words under it in the bubble. The line opens that text in a capped mono box that
/// scrolls, with Open (when there is a file) and Copy under it.
public struct SHSentCommand: View {
    public enum Kind: Sendable { case skill, prompt }

    let kind: Kind
    let name: String
    /// Shown while open: "SKILL.md · 6.1k chars".
    let meta: String
    let text: String
    let openTitle: String
    let open: (() -> Void)?
    @State private var expanded: Bool
    @State private var copied = false
    /// The text runs on below the box: the fade says so, and leaves at the end.
    @State private var moreBelow = false

    /// `open` shows "`openTitle`" under the opened text; nil hides it.
    public init(kind: Kind, name: String, meta: String, text: String, openTitle: String = "Open SKILL.md",
                expanded: Bool = false, open: (() -> Void)? = nil) {
        self.kind = kind
        self.name = name
        self.meta = meta
        self.text = text
        self.openTitle = openTitle
        self.open = open
        _expanded = State(initialValue: expanded)
    }

    private var verb: String { kind == .skill ? "Used skill" : "Sent prompt" }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Button { expanded.toggle() } label: { header }
                .buttonStyle(.shRow())
                .padding(.leading, -SH.Space.s)
                .accessibilityLabel("\(verb) \(name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(kind == .skill ? "Shows the skill's text" : "Shows the prompt's text")
            if expanded {
                expandedText
                HStack(spacing: SH.Space.l) {
                    if let open { link(openTitle, action: open) }
                    link(copied ? "Copied" : "Copy") {
                        SHPasteboard.copy(text)
                        copied = true
                    }
                }
            }
        }
        .shAnimation(.content, value: expanded)
    }

    private var header: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            Image(systemName: kind == .skill ? SHGlyph.skill.symbolName : SHGlyph.document.symbolName)
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(sh.textTertiary)
                .frame(width: SHThreadMetrics.activityIcon, height: SHThreadMetrics.activityIcon)
            (Text(verb + " ").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
             + Text(name).font(.sh(.code, weight: .medium)).foregroundStyle(sh.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            if expanded, !meta.isEmpty {
                Text(meta).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1).monospacedDigit()
            }
            SHThreadChevron(isExpanded: expanded).foregroundStyle(sh.textTertiary)
        }
        .padding(.leading, SH.Space.xs)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: SHThreadMetrics.activityHeight)
    }

    private var expandedText: some View {
        let sh = Color.sh
        return ScrollView {
            Text(text)
                .font(.sh(.code))
                .foregroundStyle(sh.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SH.Space.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 1
        } action: { _, more in
            moreBelow = more
        }
        .frame(maxHeight: SHThreadMetrics.sentCommandTextHeight)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) {
            if moreBelow {
                LinearGradient(colors: [sh.bgSunken.opacity(0), sh.bgSunken], startPoint: .top, endPoint: .bottom)
                    .frame(height: SHThreadMetrics.sentCommandFade)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: SH.Radius.m).fill(sh.bgSunken))
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
    }
}

/// A goal the user set, drawn as their sent message (the SentCommandsA pattern): a "Set goal" line
/// leading the bubble, the condition as its words. Right-aligned at the bubble's measure, so a long
/// goal wraps instead of spreading across the column.
public struct SHSentGoal: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        let sh = Color.sh
        SHUserBubble(text) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "target")
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(sh.textTertiary)
                    .frame(width: SHThreadMetrics.activityIcon, height: SHThreadMetrics.activityIcon)
                Text("Set goal").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
            }
        }
    }
}
