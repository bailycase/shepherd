import SwiftUI

// A thread named in agent prose (ThreadLinkA): a standard Markdown link whose URL names the agent,
// `[words](shepherd-thread://<agentID>)`. The app hands this file the threads that resolve now (`SHThreadLinks`, through the
// environment). A resolving link is an inline chip: a status dot, the thread's CURRENT title (owner data, never the words the model
// wrote) and, for a thread on another Mac, that Mac's name as a tag. Pressing it opens the thread; resting the pointer on it opens
// a peek (`SHThreadPeek`) with Open thread and Copy link. A link that resolves to no known thread (stale, malformed, or half written
// while a reply streams) is its plain words, never a link, and the scheme never reaches the system's opener (`SHProseLinkRouter`).

/// One thread a link can name, as its chip, its peek and the composer's @ picker draw it.
public struct SHThreadLink: Equatable, Sendable, Identifiable {
    /// The agent's id, as the link spells it.
    public var id: String
    public var title: String
    public var state: AgentState
    /// The Mac it runs on when that is not this device's own host (the chip's tag, "mini"); nil on this Mac.
    public var host: String?
    /// Where it runs, as the peek says it: "This Mac", or the host's name.
    public var location: String
    /// The project (space) it works in, and its checkout's branch.
    public var project: String?
    public var branch: String?
    /// The latest line the host keeps about it: what it asks you, or why it failed. Nil when there is none.
    public var progress: String?
    /// When it entered its status: a working or asking thread's elapsed time.
    public var since: Date?
    /// When it was last active (ms since 1970): the @ picker lists the most recent first.
    public var activeAt: Double?
    /// The @ picker offers it (an ordinary thread, not a design's chat or a Project's coordinator).
    public var pickable: Bool

    public init(id: String, title: String, state: AgentState, host: String? = nil, location: String, project: String? = nil,
                branch: String? = nil, progress: String? = nil, since: Date? = nil, activeAt: Double? = nil, pickable: Bool = true) {
        self.id = id
        self.title = title
        self.state = state
        self.host = host
        self.location = location
        self.project = project
        self.branch = branch
        self.progress = progress
        self.since = since
        self.activeAt = activeAt
        self.pickable = pickable
    }

    /// The link that names this thread, with its current title: what Copy link copies and the @ picker inserts.
    public var markdown: String { SHThreadLinks.markdown(title: title, id: id) }

    /// "orders-db · agent/pg17-orders".
    public var place: String? {
        let parts = [project, branch].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The status word: "Working", "Needs you", "Done".
    public var word: String {
        switch state {
        case .running: "Working"
        default: state.label
        }
    }

    /// "Working · 18m": the word, and for a thread that works or asks, how long it has.
    public func statusLine(now: Date = Date()) -> String {
        guard state == .running || state == .attention, let since else { return word }
        return word + " · " + Self.elapsed(now.timeIntervalSince(since))
    }

    /// "1m", "18m", "2h", "1h 4m", "3d".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}

/// The threads a conversation's links resolve against, keyed by agent id, and what opening one does. One object per window (the app
/// updates it as threads change), so the environment that carries it never changes; a paragraph that draws a chip reads `links` and
/// is drawn again when they change, and nothing else is.
@MainActor @Observable
public final class SHThreadLinks {
    public nonisolated static let scheme = "shepherd-thread"

    /// By lowercased id.
    public private(set) var links: [String: SHThreadLink] = [:]
    /// Opens a thread by its id. Set by the app.
    @ObservationIgnored public var open: (String) -> Void

    public init(_ links: [SHThreadLink] = [], open: @escaping (String) -> Void = { _ in }) {
        self.open = open
        update(links)
    }

    /// Replaces the table, writing only when it changed.
    public func update(_ links: [SHThreadLink]) {
        let next = Dictionary(links.map { ($0.id.lowercased(), $0) }) { first, _ in first }
        if next != self.links { self.links = next }
    }

    /// The thread `url` names, when it is a well-formed thread link to a known thread.
    public func link(_ url: URL) -> SHThreadLink? {
        Self.id(in: url).flatMap { links[$0.lowercased()] }
    }

    /// The thread a pressed link names opens; anything else with the scheme is dropped. Whether `url` had the scheme (it is then
    /// never handed on, to the system or anyone).
    @discardableResult
    public func route(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.scheme else { return false }
        if let link = link(url) { open(link.id) }
        return true
    }

    /// `shepherd-thread://<id>`.
    public nonisolated static func url(id: String) -> String { "\(scheme)://\(id)" }

    /// `[Title](shepherd-thread://<id>)`, the title's brackets and backslashes escaped.
    public nonisolated static func markdown(title: String, id: String) -> String {
        var escaped = ""
        for character in title.replacingOccurrences(of: "\n", with: " ") {
            if character == "[" || character == "]" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "[\(escaped)](\(url(id: id)))"
    }

    /// The id a thread link names: its host, when the URL is `shepherd-thread://<id>` and nothing else (no path, query, user or
    /// port), and the id is letters, digits, `-`, `_` and `.` only. Nil for anything else.
    public nonisolated static func id(in url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil, components.user == nil, components.port == nil,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        else { return nil }
        return host
    }

    /// The thread links in `text`, a message the person sent, read as links and nothing else: every other character, Markdown
    /// included, stays as typed (a bubble is not Markdown). Nil when it holds none. `[words](shepherd-thread://<id>)` with the
    /// words' `\[`, `\]` and `\\` escapes (what `markdown(title:id:)` writes).
    public nonisolated static func linkingThreads(in text: String) -> AttributedString? {
        guard text.range(of: "](\(scheme)://", options: .caseInsensitive) != nil else { return nil }
        let whole = text as NSString
        var result = AttributedString()
        var cursor = 0
        var found = false
        for match in sentLink.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            guard let url = URL(string: url(id: whole.substring(with: match.range(at: 2)))) else { continue }
            found = true
            result += AttributedString(whole.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            var words = AttributedString(unescaped(whole.substring(with: match.range(at: 1))))
            words.link = url
            result += words
            cursor = match.range.location + match.range.length
        }
        guard found else { return nil }
        result += AttributedString(whole.substring(from: cursor))
        return result
    }

    /// `[words](shepherd-thread://<id>)` in a sent message: the words (escapes allowed, one line) and the id.
    nonisolated(unsafe) private static let sentLink = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\]\\\n])*)\]\((?i:shepherd-thread)://([A-Za-z0-9._-]+)\)"#)

    /// A link's words with their backslash escapes taken out.
    nonisolated private static func unescaped(_ words: String) -> String {
        var out = ""
        var escaping = false
        for character in words {
            if escaping || character != "\\" { out.append(character); escaping = false } else { escaping = true }
        }
        return out
    }

    /// Whether `text` holds a thread link: a cheap test before any run is walked.
    nonisolated static func hasReference(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.link?.scheme?.lowercased() == scheme }
    }

    /// `text` with every thread link reduced to its plain words.
    nonisolated static func inert(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link?.scheme?.lowercased() == scheme {
            text[run.range].link = nil
            text[run.range].foregroundColor = nil
            text[run.range].underlineStyle = nil
        }
        return text
    }
}

extension EnvironmentValues {
    /// The threads this conversation's links resolve against; nil draws every thread link as its words.
    @Entry public var shThreadLinks: SHThreadLinks? = nil
    /// Previews: the chip of this thread (by id) opens its peek as it appears.
    @Entry public var shThreadLinkPeekOpen: String? = nil
}

/// The chip's own measures (ThreadLinkA's `.chip`, `.tag`, `.pop` and `.btn`).
public enum SHThreadLinkMetrics {
    public static let chipHeight: CGFloat = 22
    public static let chipPad: CGFloat = SH.Space.s
    public static let chipGap: CGFloat = SH.Space.s
    public static let chipMargin: CGFloat = SH.Space.xxs
    public static let border: CGFloat = 1
    public static let dot: CGFloat = 6
    public static let tagHeight: CGFloat = 16
    public static let tagPad: CGFloat = SH.Space.xs
    /// A paragraph with a chip sets its lines at the board's 1.75 rather than prose's 1.6, so chips on lines one above the
    /// other don't touch: the difference at the body size.
    public static let lineExtra: CGFloat = 2
    /// The press target is at least this tall; the chip stays the board's 22.
    public static let pressHeight: CGFloat = 24
    public static let peekWidth: CGFloat = 360
    public static let peekGap: CGFloat = SH.Space.xs
    public static let buttonHeight: CGFloat = 26
    /// The progress box's line height (the board's 1.5).
    public static let progressLineHeight: CGFloat = 1.5
}

// MARK: - The chip in prose

/// Marks the runs of a chip so `SHThreadChipRenderer` draws behind them.
struct SHThreadChipAttribute: TextAttribute {
    enum Part: Hashable { case room, title, tag }
    /// Which mention of the paragraph it is (0, 1, …): the identity of the chip.
    let mention: Int
    let state: AgentState
    let part: Part
}

enum SHThreadChipText {
    /// The paragraph as one `Text`, each resolving thread link a chip (a run that holds the room of the padding, dot and gap, the
    /// title in ui 500, and the tag), an unresolved one its plain words; and the threads its chips name, in order.
    @MainActor static func text(_ source: AttributedString, links: SHThreadLinks, size: SHProseSize) -> (text: Text, mentions: [SHThreadLink]) {
        let M = SHThreadLinkMetrics.self
        var result = Text(verbatim: "")
        var mentions: [SHThreadLink] = []
        for (url, range) in source.runs[\.link] {
            let piece = AttributedString(source[range])
            guard let url, url.scheme?.lowercased() == SHThreadLinks.scheme else {
                result = Text("\(result)\(Text(piece))")
                continue
            }
            guard let link = links.link(url) else {
                result = Text("\(result)\(Text(SHThreadLinks.inert(piece)))")
                continue
            }
            let mention = mentions.count
            mentions.append(link)
            func mark(_ part: SHThreadChipAttribute.Part) -> SHThreadChipAttribute {
                SHThreadChipAttribute(mention: mention, state: link.state, part: part)
            }
            let font = Font.sh(.ui, weight: .medium, size: size)
            // A hair space (a real glyph: a zero-width one is dropped from the layout) kerned to the margin, border, padding, dot and
            // gap; a word joiner after it, so the dot never ends a line without its title.
            var room = AttributedString("\u{200A}\u{2060}")
            room.font = font
            room.kern = M.chipMargin + M.border + M.chipPad + M.dot + M.chipGap
            // Non-breaking, so a chip stays one box on one line unless it is wider than the column.
            var title = AttributedString(link.title.replacingOccurrences(of: " ", with: "\u{00A0}"))
            title.font = font
            title.foregroundColor = Color.sh.textPrimary
            let titleEnd = link.host == nil ? M.chipPad + M.border + M.chipMargin : M.chipGap + M.border + M.tagPad
            if let last = title.characters.indices.last { title[last..<title.endIndex].kern = titleEnd }
            result = Text("\(result)\(Text(room).customAttribute(mark(.room)))\(Text(title).customAttribute(mark(.title)))")
            if let host = link.host {
                var tag = AttributedString("\u{2060}" + host.replacingOccurrences(of: " ", with: "\u{00A0}"))
                tag.font = Font.sh(.micro, size: size)
                tag.foregroundColor = Color.sh.textSecondary
                if let last = tag.characters.indices.last {
                    tag[last..<tag.endIndex].kern = M.tagPad + M.border + M.chipPad + M.border + M.chipMargin
                }
                result = Text("\(result)\(Text(tag).customAttribute(mark(.tag)))")
            }
        }
        return (result, mentions)
    }
}

/// One chip's box on one line of the laid-out paragraph, in the text's own coordinates.
struct SHThreadChipBox: Identifiable, Equatable {
    let mention: Int
    let state: AgentState
    /// The chip: the board's 22pt box.
    let rect: CGRect
    /// The host's tag inside it, on the line that holds it.
    let tag: CGRect?
    /// 0 for a chip's first line; a title wider than the column wraps and has more.
    let fragment: Int
    /// Whether the chip ends on this line (its right edge has its padding).
    let ends: Bool
    var id: String { "\(mention)#\(fragment)" }

    static func boxes(in layout: Text.Layout) -> [SHThreadChipBox] {
        let M = SHThreadLinkMetrics.self
        var found: [SHThreadChipBox] = []
        var fragments: [Int: Int] = [:]
        // The chips that have a host's tag: their title doesn't end them.
        var tagged: Set<Int> = []
        for line in layout {
            for run in line {
                if let chip = run[SHThreadChipAttribute.self], chip.part == .tag { tagged.insert(chip.mention) }
            }
        }
        for line in layout {
            struct Open {
                var chip: SHThreadChipAttribute
                var bounds: CGRect
                var text: CGRect?
                var tag: CGRect?
                var starts: Bool
                var ends = false
            }
            var open: Open?
            func finish() {
                guard let current = open else { return }
                open = nil
                let fragment = fragments[current.chip.mention, default: -1] + 1
                fragments[current.chip.mention] = fragment
                let mid = (current.text ?? current.bounds).midY
                let left = current.bounds.minX + (current.starts ? M.chipMargin : 0)
                let right = current.bounds.maxX - (current.ends ? M.chipMargin : 0)
                let rect = CGRect(x: left, y: mid - M.chipHeight / 2, width: max(0, right - left), height: M.chipHeight)
                let tag = current.tag.map { bounds in
                    let tagLeft = bounds.minX - M.tagPad - M.border
                    let tagRight = bounds.maxX - (M.chipPad + M.border + M.chipMargin)
                    return CGRect(x: tagLeft, y: mid - M.tagHeight / 2, width: max(0, tagRight - tagLeft), height: M.tagHeight)
                }
                found.append(SHThreadChipBox(mention: current.chip.mention, state: current.chip.state, rect: rect, tag: tag,
                                             fragment: fragment, ends: current.ends))
            }
            for run in line {
                guard let chip = run[SHThreadChipAttribute.self] else {
                    finish()
                    continue
                }
                let bounds = run.typographicBounds.rect
                var current: Open
                if chip.part == .room || open?.chip.mention != chip.mention {
                    finish()
                    current = Open(chip: chip, bounds: bounds, starts: chip.part == .room)
                } else {
                    current = open!
                    current.bounds = current.bounds.union(bounds)
                }
                switch chip.part {
                case .room, .title: current.text = current.text.map { $0.union(bounds) } ?? bounds
                case .tag: current.tag = current.tag.map { $0.union(bounds) } ?? bounds
                }
                // The title ends the chip unless a tag follows it; the tag always ends it.
                current.ends = chip.part == .tag || (chip.part == .title && !tagged.contains(chip.mention))
                open = current
            }
            finish()
        }
        return found
    }
}

/// Draws each chip behind its runs (ThreadLinkA's `.chip`: `bgRaised`, a 1px `lineStrong` border, radius 6, a 6pt dot in the
/// thread's status color; `bgHover` with a `textTertiary` border while it is hovered, pressed or peeked), the host's tag box, then
/// every run over them.
struct SHThreadChipRenderer: TextRenderer {
    /// The mention drawn hovered.
    let highlighted: Int?
    let fill: Color
    let hoverFill: Color
    let line: Color
    let hoverLine: Color
    let dots: [AgentState: Color]

    @MainActor init(highlighted: Int?) {
        self.highlighted = highlighted
        fill = Color.sh.bgRaised
        hoverFill = Color.sh.bgHover
        line = Color.sh.lineStrong
        hoverLine = Color.sh.textTertiary
        dots = Dictionary(uniqueKeysWithValues: AgentState.allCases.map { ($0, $0.color) })
    }

    var displayPadding: EdgeInsets {
        let half = SHThreadLinkMetrics.chipHeight / 2
        return EdgeInsets(top: half, leading: SHThreadLinkMetrics.chipMargin, bottom: half, trailing: SHThreadLinkMetrics.chipMargin)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let M = SHThreadLinkMetrics.self
        for box in SHThreadChipBox.boxes(in: layout) {
            let on = box.mention == highlighted
            let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
            context.fill(shape.path(in: box.rect), with: .color(on ? hoverFill : fill))
            context.stroke(shape.path(in: box.rect.insetBy(dx: M.border / 2, dy: M.border / 2)), with: .color(on ? hoverLine : line),
                           lineWidth: M.border)
            if box.fragment == 0 {
                let dot = CGRect(x: box.rect.minX + M.border + M.chipPad, y: box.rect.midY - M.dot / 2, width: M.dot, height: M.dot)
                context.fill(Circle().path(in: dot), with: .color(dots[box.state] ?? line))
            }
            if let tag = box.tag {
                context.stroke(RoundedRectangle(cornerRadius: SH.Radius.xs).path(in: tag.insetBy(dx: M.border / 2, dy: M.border / 2)),
                               with: .color(line), lineWidth: M.border)
            }
        }
        for line in layout { context.draw(line) }
    }
}

/// A paragraph that names threads (a reply's, or a message the person sent): its chips, their press targets and their peeks.
struct SHThreadChipParagraph: View {
    let text: AttributedString
    let links: SHThreadLinks
    let size: SHProseSize
    /// The words' weight (a sent answer's title is semibold).
    var weight: Font.Weight? = nil
    /// The words' own line spacing (a bubble's is its metrics'); chips add `lineExtra` to it.
    var lineSpacing: CGFloat? = nil
    @State private var highlighted: Int?

    var body: some View {
        let built = SHThreadChipText.text(text, links: links, size: size)
        built.text
            .font(.sh(.body, weight: weight, size: size))
            .lineSpacing((lineSpacing ?? SHTextStyle.body.lineSpacing(size)) + SHThreadLinkMetrics.lineExtra)
            .textRenderer(SHThreadChipRenderer(highlighted: highlighted))
            .overlayPreferenceValue(Text.LayoutKey.self) { anchored in
                GeometryReader { proxy in
                    ForEach(Array(anchored.enumerated()), id: \.offset) { _, item in
                        let origin = proxy[item.origin]
                        ForEach(SHThreadChipBox.boxes(in: item.layout)) { box in
                            if box.mention < built.mentions.count {
                                SHThreadChipTarget(box: box, link: built.mentions[box.mention], links: links, highlighted: $highlighted)
                                    .position(x: origin.x + box.rect.midX, y: origin.y + box.rect.midY)
                            }
                        }
                    }
                }
            }
    }
}

/// One chip's press target: an invisible button over its box, at least 24pt tall, that opens the thread; resting the pointer on it
/// opens its peek under the chip, as a design reference's chip opens its preview.
private struct SHThreadChipTarget: View {
    let box: SHThreadChipBox
    let link: SHThreadLink
    let links: SHThreadLinks
    @Binding var highlighted: Int?
    @State private var hover = SHChipHover()
    @State private var inside = false
    @State private var pressed = false
    @Environment(\.shThreadLinkPeekOpen) private var startsOpen

    var body: some View {
        let lit = inside || pressed || hover.shown
        Button(action: open) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(SHChipPressStyle(pressed: $pressed))
            .frame(width: box.rect.width, height: max(box.rect.height, SHThreadLinkMetrics.pressHeight))
            .onHover { entered in
                inside = entered
                hover.pointer(entered)
            }
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .topLeading) {
                    if hover.shown, box.fragment == 0 {
                        SHThreadPeek(link, open: open)
                            .onHover { hover.pointer($0) }
                            .shTransition(.overlay, anchor: .topLeading)
                    }
                }
                .fixedSize()
                .alignmentGuide(.bottom) { _ in -SHThreadLinkMetrics.peekGap }
            }
            .shAnimation(.overlay, value: hover.shown)
            .preference(key: SHPreviewOpenKey.self, value: hover.shown)
            .onChange(of: lit, initial: true) { _, lit in
                if lit { highlighted = box.mention } else if highlighted == box.mention { highlighted = nil }
            }
            .onAppear { if startsOpen?.lowercased() == link.id.lowercased(), box.fragment == 0 { hover.show() } }
            #if os(iOS)
            // No pointer rests on a chip on a touch screen: Copy link is in its menu.
            .contextMenu {
                Button("Open Thread", action: open)
                Button("Copy Link") { SHPasteboard.copy(link.markdown) }
            }
            #endif
            .accessibilityLabel("\(link.title), \(link.word.lowercased())\(link.host.map { ", on \($0)" } ?? ""). Open thread")
            .accessibilityAction(named: "Copy link") { SHPasteboard.copy(link.markdown) }
            .accessibilityHidden(box.fragment > 0)
    }

    private func open() {
        hover.close()
        links.open(link.id)
    }
}

/// Reports a plain button's pressed state, drawing nothing of its own.
private struct SHChipPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in pressed = isPressed }
            .shFocusRing(radius: SH.Radius.s)
    }
}

// MARK: - The peek

/// A thread chip's peek (ThreadLinkA's `.pop`): the status and how long, where it runs, the title, its project and branch, the
/// latest line the host keeps about it in a sunken box (left out when there is none), then Open thread and Copy link. 360pt wide on
/// the popover surface.
public struct SHThreadPeek: View {
    let link: SHThreadLink
    let now: Date
    let open: () -> Void
    @State private var copied = false

    public init(_ link: SHThreadLink, now: Date = Date(), open: @escaping () -> Void) {
        self.link = link
        self.now = now
        self.open = open
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHThreadLinkMetrics.self
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.s) {
                SHStatusDot(link.state)
                Text(link.statusLine(now: now)).font(.sh(.caption, weight: .medium)).foregroundStyle(link.state.textColor)
                Spacer(minLength: SH.Space.m)
                Text(link.location).font(.sh(.caption)).foregroundStyle(sh.textSecondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Text(link.title)
                .font(.sh(.headline))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let place = link.place {
                Text(place).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            if let progress = link.progress, !progress.isEmpty {
                Text(progress)
                    .shText(size: SHTextStyle.ui.size, lineHeight: M.progressLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SH.Space.m)
                    .padding(.horizontal, SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            }
            HStack(spacing: SH.Space.m) {
                Button("Open thread", action: open).buttonStyle(SHThreadPeekButtonStyle(primary: true))
                Button(copied ? "Copied" : "Copy link") {
                    SHPasteboard.copy(link.markdown)
                    copied = true
                }
                .buttonStyle(SHThreadPeekButtonStyle(primary: false))
                .accessibilityHint("Copies a link to this thread to paste into a message")
            }
            .padding(.top, SH.Space.xs)
        }
        .padding(.top, SH.Space.l)
        .padding(.horizontal, SH.Space.xl)
        .padding(.bottom, SH.Space.xl)
        .frame(width: M.peekWidth, alignment: .leading)
        .shPopover(radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(link.title)
    }
}

/// The peek's two buttons (ThreadLinkA's `.btn`): 26pt, radius 6, ui 500; Open thread filled `running`, Copy link bordered.
private struct SHThreadPeekButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        SHThreadPeekButton(configuration: configuration, primary: primary)
    }
}

private struct SHThreadPeekButton: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        let fill: Color = primary ? sh.running : configuration.isPressed ? sh.bgSelected : hovering ? sh.bgHover : .clear
        configuration.label
            .font(.sh(.ui))
            .lineLimit(1)
            .foregroundStyle(primary ? sh.textOnRunning : sh.textPrimary)
            .padding(.horizontal, SH.Space.m)
            .frame(minHeight: SHThreadLinkMetrics.buttonHeight)
            .background(fill, in: shape)
            .shBorder(primary ? sh.running : sh.lineStrong, radius: SH.Radius.s)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: SH.Radius.s)
            .shTouchTarget(height: SHThreadLinkMetrics.buttonHeight)
    }
}

// MARK: - Hover and layering

/// How long the pointer rests on a chip before its preview opens, and lingers after leaving it.
private enum SHChipHoverTiming {
    static let open: Duration = .milliseconds(450)
    static let close: Duration = .milliseconds(250)
}

/// Whether a chip's preview is open: after a short hover on the chip, kept while the pointer is on the chip or the preview, and
/// closed a moment after it leaves both. A design reference's chip and a thread chip share it.
@MainActor @Observable
public final class SHChipHover {
    public private(set) var shown = false
    @ObservationIgnored private var inside = 0
    @ObservationIgnored private var timer: Task<Void, Never>?

    public init(shown: Bool = false) { self.shown = shown }

    public func pointer(_ entered: Bool) {
        inside = max(0, inside + (entered ? 1 : -1))
        timer?.cancel()
        let wanted = inside > 0
        guard wanted != shown else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: wanted ? SHChipHoverTiming.open : SHChipHoverTiming.close)
            guard !Task.isCancelled, let self else { return }
            self.shown = wanted
        }
    }

    public func close() {
        timer?.cancel()
        inside = 0
        shown = false
    }

    /// Previews: open at once.
    public func show() {
        timer?.cancel()
        shown = true
    }
}

/// Whether a preview (a design reference's, a thread chip's peek) is open in a view: the view draws over its siblings after it while
/// it is, so a preview that opens below its chip isn't covered by what follows.
public struct SHPreviewOpenKey: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct SHRaisedWhilePreviewing: ViewModifier {
    @State private var raised = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SHPreviewOpenKey.self) { open in
                MainActor.assumeIsolated { if raised != open { raised = open } }
            }
            .zIndex(raised ? 1 : 0)
    }
}

extension View {
    /// Draws this view over its later siblings while a preview inside it is open (`SHPreviewOpenKey`).
    public func shRaisedWhilePreviewing() -> some View { modifier(SHRaisedWhilePreviewing()) }
}
