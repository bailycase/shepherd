import SwiftUI

// The Project page's right pane parts (ProjectLead-Started, -Paused, -Resolved, -ThreadRunning), each measured from
// the boards' markup. Plain values in, actions out: the app derives the values from the Project record and the owner's
// runtime, so none of these invents a row or a state.

/// "Welcome back, Alex." and the line under it (Geist 28/600 on 1.15; 12.5 `textSecondary`).
public struct SHLeadWelcome: View {
    let name: String
    let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text("Welcome back, \(name).")
                .font(.shSans(SHLeadMetrics.welcomeSize, .semibold))
                .lineSpacing(0)
                .foregroundStyle(Color.sh.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(status)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
        }
    }
}

/// A group header in the pane ("Waiting on you 1", "Working 3", "Resolved 2"): 28pt, `bgRaised` radius 6, a 12pt
/// chevron, the title and count in 12.5. The whole row folds the group.
public struct SHLeadGroupHeader: View {
    let title: String
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    public init(_ title: String, count: Int, expanded: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.expanded = expanded
        self.toggle = toggle
    }

    public var body: some View {
        Button(action: toggle) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "chevron.down")
                    .font(.system(size: SHLeadMetrics.groupChevron, weight: .medium))
                    .foregroundStyle(Color.sh.textTertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: SHLeadMetrics.groupChevron)
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                Text("\(count)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHLeadMetrics.groupHeaderHeight)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count), \(expanded ? "expanded" : "collapsed")")
    }
}

/// A thread row in the pane: a 6pt state dot, the title (12.5/500) over a 11.5 detail (a lantern lead word, then the
/// question) and the age. 42pt, 38 resolved. A Project's agents delegate through ordinary Project threads only (never subagents),
/// so the board's subagent-count pill is deliberately not drawn.
public struct SHLeadThreadRow: View {
    public typealias Tone = SHLeadTaskCard.Tone

    let title: String
    let lead: String?
    let detail: String?
    let tone: Tone
    let age: String?
    let action: () -> Void

    public init(title: String, lead: String? = nil, detail: String? = nil, tone: Tone, age: String? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.lead = lead
        self.detail = detail
        self.tone = tone
        self.age = age
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                if tone != .resolved {
                    // The dot sits centered in a 12pt slot, so a row's title lines up with its group's (ProjectLead-Started).
                    Circle().fill(tone.dot)
                        .frame(width: SHLeadMetrics.threadRowDot, height: SHLeadMetrics.threadRowDot)
                        .frame(width: SHLeadMetrics.groupChevron)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.sh(.ui, weight: tone == .resolved ? .regular : .medium))
                        .foregroundStyle(tone == .resolved ? Color.sh.textSecondary : Color.sh.textPrimary)
                        .lineLimit(1)
                    if lead != nil || detail != nil {
                        (Text(lead.map { $0 + (detail == nil ? "" : " · ") } ?? "").foregroundColor(Color.sh.lanternText)
                            + Text(detail ?? "").foregroundColor(Color.sh.textTertiary))
                            .font(.sh(.caption))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: SH.Space.s)
                if let age { Text(age).font(.shMono(SHLeadMetrics.ageSize)).foregroundStyle(Color.sh.textTertiary).monospacedDigit() }
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 12))
            .frame(maxWidth: .infinity, minHeight: tone == .resolved ? SHLeadMetrics.resolvedRowHeight : SHLeadMetrics.threadRowHeight,
                   alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        }
        .buttonStyle(SHLeadRowPress())
        .accessibilityLabel([title, lead, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

struct SHLeadRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
    }
}

/// The pane's footer card ("The project is paused." / "This thread is resolved."): a raised, bordered card 50pt tall,
/// an optional leading glyph, a line (and a quieter line under it), and at most one action.
public struct SHLeadFooterCard: View {
    let symbol: String?
    let symbolTint: Color
    let title: String
    let detail: String?
    let action: String?
    let perform: () -> Void
    let enabled: Bool
    let height: CGFloat

    @MainActor
    public init(symbol: String? = nil, symbolTint: Color? = nil, title: String, detail: String? = nil, action: String? = nil,
                enabled: Bool = true, height: CGFloat = SHLeadMetrics.footerHeight, perform: @escaping () -> Void = {}) {
        self.height = height
        self.symbol = symbol
        self.symbolTint = symbolTint ?? Color.sh.done
        self.title = title
        self.detail = detail
        self.action = action
        self.enabled = enabled
        self.perform = perform
    }

    public var body: some View {
        HStack(spacing: SH.Space.l) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: SHLeadMetrics.footerGlyph)).foregroundStyle(symbolTint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textPrimary)
                if let detail { Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
            }
            Spacer(minLength: SH.Space.m)
            if let action {
                Button(action: perform) { Text(action) }
                    .buttonStyle(SHLeadSecondaryButton())
                    .disabled(!enabled)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 8))
        .frame(minHeight: height)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
    }
}

/// The boards' secondary button ("Resume", "View thread"): 28pt, 10pt sides, radius 6, 1pt `lineStrong` on
/// `bgRaised`, 12.5/500.
public struct SHLeadSecondaryButton: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(.ui, weight: .medium))
            .foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.l - 2)
            .frame(height: SHLeadMetrics.toolbarButtonHeight)
            .background(configuration.isPressed ? Color.sh.bgSelected : Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// The New project sheet's text field (ProjectLead-New): 32pt tall, radius 8, 12pt of padding, 12.5pt text, a 1pt `lineStrong`
/// border on `bgSunken`, `textTertiary` placeholder; the focus ring is the app's (`shFocusRing`), shown for keyboard focus only.
public struct SHLeadFieldStyle: TextFieldStyle {
    public init() {}

    @MainActor public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(Color.sh.textPrimary)
            .padding(.horizontal, SHLeadMetrics.sheetFieldPadding)
            .frame(height: SHLeadMetrics.sheetFieldHeight)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHLeadMetrics.sheetFieldRadius))
            .shBorder(Color.sh.lineStrong, radius: SHLeadMetrics.sheetFieldRadius)
    }
}

/// The sheet's footer buttons (ProjectLead-New): 28pt, radius 6, 10pt sides inside a 1pt line, 12.5/500. Cancel is ghost (`textSecondary`); Create
/// project is the one primary action (`lantern` on `textOnLantern`). 40% opacity when disabled.
public struct SHLeadSheetButton: ButtonStyle {
    public enum Kind { case ghost, primary }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    @MainActor public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sh(.ui, weight: .medium))
            .foregroundStyle(kind == .primary ? Color.sh.textOnLantern : Color.sh.textSecondary)
            .padding(.horizontal, SHLeadMetrics.sheetButtonSide)
            .frame(height: SHLeadMetrics.toolbarButtonHeight)
            .background(kind == .primary ? Color.sh.lantern : (configuration.isPressed ? Color.sh.bgSelected : .clear),
                        in: RoundedRectangle(cornerRadius: SH.Radius.s))
            // The whole 28pt box answers a click, not only its label: a clear background has no hit area of its own.
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// The sheet's close cross: two strokes from 2.5 to 9.5 on a 12-unit grid, round caps (the board draws it as a path).
public struct SHLeadCloseMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 12 * (12 / 11.5) * 1
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(2.5, 2.5)); path.addLine(to: point(9.5, 9.5))
        path.move(to: point(9.5, 2.5)); path.addLine(to: point(2.5, 9.5))
        return path
    }
}

/// The day separator over a conversation's first turn (ProjectLead boards, `pc-day`): a hairline, the day word in 11.5
/// `textTertiary`, a hairline, 12pt apart. The word is the day of the turn's real start ("Today", "Yesterday", a weekday, a date).
public struct SHLeadDaySeparator: View {
    let word: String

    /// `at`: the turn's start, in milliseconds since 1970. `word` is made by the app's own day producer.
    public init(word: String) { self.word = word }

    public var body: some View {
        HStack(spacing: SH.Space.l) {
            SHHairline().frame(maxWidth: .infinity)
            Text(word).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize()
            SHHairline().frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}


/// The offer to add a Space to the Project (ProjectLead-AddsSpace): the folder, its name over its path and host, "Not now" and the
/// one primary "Add to project". Both are decisions the person makes; the card draws only for a proposal still pending.
public struct SHLeadSpaceOffer: View {
    let name: String
    let path: String
    let enabled: Bool
    let notNow: () -> Void
    let add: () -> Void

    public init(name: String, path: String, enabled: Bool = true, notNow: @escaping () -> Void, add: @escaping () -> Void) {
        self.name = name
        self.path = path
        self.enabled = enabled
        self.notNow = notNow
        self.add = add
    }

    public var body: some View {
        HStack(spacing: SHLeadMetrics.offerGap) {
            Image(systemName: "folder").font(.system(size: SHLeadMetrics.footerGlyph)).foregroundStyle(Color.sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Text(path).font(.shMono(SHLeadMetrics.offerPathSize)).foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: SH.Space.m)
            HStack(spacing: SHLeadMetrics.offerButtonGap) {
                Button("Not now", action: notNow).buttonStyle(SHLeadSheetButton(.ghost))
                Button("Add to project", action: add).buttonStyle(SHLeadSheetButton(.primary))
            }
            .disabled(!enabled)
        }
        .padding(SHLeadMetrics.offerPadding)
        .frame(minHeight: SHLeadMetrics.offerHeight)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SHLeadMetrics.offerRadius))
        .shBorder(Color.sh.lineStrong, radius: SHLeadMetrics.offerRadius)
        .accessibilityElement(children: .contain)
    }
}

/// A task the project started, drawn inline in its conversation (ProjectLead-Started, -Question, -Resolved): a 34pt card with the
/// task's state (a `running` dot while it works, a `lantern` dot while it needs you, a check once resolved), its title in 12.5/500,
/// for a working task its latest activity, and one chip per file the task published (22pt, mono 10.5). A task that needs you carries
/// its question and "View thread" under the card. The card opens the task; each chip opens its own file.
public struct SHLeadTaskCard: View {
    /// `stopped`: the turn ended and nobody has resolved it. Not running and not a success, so it takes the idle dot.
    public enum Tone: Sendable {
        case running, attention, stopped, resolved
        @MainActor var dot: Color { self == .attention ? Color.sh.lantern : self == .stopped ? AgentState.idle.color : Color.sh.running }
        var word: String {
            switch self {
            case .running: "working"
            case .attention: "needs you"
            case .stopped: "stopped"
            case .resolved: "resolved"
            }
        }
    }

    /// A file the task published: the chip's identity and name. What pressing it does is the caller's.
    public struct File: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    let title: String
    let tone: Tone
    let detail: String?
    let question: String?
    let files: [File]
    let open: () -> Void
    let openFile: (File) -> Void
    let viewThread: (() -> Void)?

    public init(title: String, tone: Tone, detail: String? = nil, question: String? = nil, files: [File] = [],
                open: @escaping () -> Void, openFile: @escaping (File) -> Void = { _ in }, viewThread: (() -> Void)? = nil) {
        self.title = title
        self.tone = tone
        self.detail = detail
        self.question = question
        self.files = files
        self.open = open
        self.openFile = openFile
        self.viewThread = viewThread
    }

    public var body: some View {
        // The board's column is `gap: space-xs`; a question row under the card is 24pt tall, its 28pt button overflowing it.
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(spacing: SH.Space.m) {
                // The card's own words are the card button's label (below); only the chips are controls of their own.
                HStack(spacing: SH.Space.m) {
                    Group {
                        switch tone {
                        case .resolved:
                            Image(systemName: SHGlyph.resolved.symbolName).font(.system(size: SHLeadMetrics.footerGlyph)).foregroundStyle(Color.sh.textTertiary)
                        case .attention, .running, .stopped:
                            Circle().fill(tone.dot)
                                .frame(width: SHLeadMetrics.taskDot, height: SHLeadMetrics.taskDot)
                        }
                    }
                    .frame(width: SHLeadMetrics.footerGlyph, height: SHLeadMetrics.footerGlyph)
                    // The board's title never wraps and its chips never shrink, and its card never holds more than fits. Past that, the
                    // title (tail) and each file name (middle) give way together, so the card keeps its width and no chip leaves it.
                    Text(title).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                    if let detail {
                        Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                ForEach(files) { file in chip(file) }
                Spacer(minLength: 0)
            }
            .padding(SHLeadMetrics.taskCardPadding)
            .frame(height: SHLeadMetrics.taskCardHeight)
            .background {
                Button(action: open) {
                    RoundedRectangle(cornerRadius: SHLeadMetrics.taskCardRadius).fill(Color.sh.bgRaised)
                        .shBorder(Color.sh.lineStrong, radius: SHLeadMetrics.taskCardRadius)
                        .contentShape(RoundedRectangle(cornerRadius: SHLeadMetrics.taskCardRadius))
                }
                .buttonStyle(SHLeadRowPress())
                .accessibilityLabel([title, tone.word, detail]
                    .compactMap { $0 }.joined(separator: ", "))
            }
            if let question {
                HStack(spacing: SH.Space.m) {
                    Text(question).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let viewThread { Button("View thread", action: viewThread).buttonStyle(SHLeadSecondaryButton()) }
                }
                .frame(height: SHLeadMetrics.taskQuestionRowHeight)
                .padding(.leading, SH.Space.m)
            }
        }
    }

    /// A file chip: 22pt, 6pt sides, 4pt between glyph and name, 1pt `lineSubtle`, radius 6; its press target is 24pt tall.
    private func chip(_ file: File) -> some View {
        Button { openFile(file) } label: {
            HStack(spacing: SHLeadMetrics.chipGap) {
                Image(systemName: SHGlyph.document.symbolName).font(.system(size: SHLeadMetrics.chipGlyph)).accessibilityHidden(true)
                Text(file.name).font(.shMono(SHLeadMetrics.chipText)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: SHLeadMetrics.chipNameMaxWidth, alignment: .leading)
            }
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SHLeadMetrics.chipPaddingH)
            .frame(height: SHLeadMetrics.chipHeight)
            .shBorder(Color.sh.lineSubtle, radius: SHLeadMetrics.chipRadius)
            .frame(height: SHLeadMetrics.chipPressHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(file.name)")
    }
}

/// One entry of the Files tab: a folder or a file of the Project's private folder, with its size, the whole row pressable.
public struct SHLeadFileRow: View {
    let symbol: String
    let name: String
    let detail: String?
    let trailing: String?
    let action: () -> Void

    public init(symbol: String, name: String, detail: String? = nil, trailing: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.name = name
        self.detail = detail
        self.trailing = trailing
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: symbol).font(.system(size: SHLeadMetrics.chipGlyph)).foregroundStyle(Color.sh.textSecondary)
                    .frame(width: SHLeadMetrics.footerGlyph).accessibilityHidden(true)
                Text(name).font(.shMono(SHLeadMetrics.chipText)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1) }
                Spacer(minLength: SH.Space.m)
                if let trailing { Text(trailing).font(.shMono(SHLeadMetrics.ageSize)).foregroundStyle(Color.sh.textTertiary) }
            }
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHLeadMetrics.threadRowHeight, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        }
        .buttonStyle(SHLeadRowPress())
        .accessibilityLabel([name, detail, trailing].compactMap { $0 }.joined(separator: ", "))
    }
}
