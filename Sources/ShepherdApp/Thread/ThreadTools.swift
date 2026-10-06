import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Consecutive activity lines (NWThread, ToolRows: one quiet line per burst of work), each
/// expanding to its calls. The running call's line is the thread's live indicator (LiveText).
struct ActivityLinesView: View, Equatable {
    let bursts: [NativeActivityBurst]
    var review: ((String) -> Void)?
    /// Lines that stream in once the turn is on screen make their entrance.
    var entering = false

    static func == (lhs: ActivityLinesView, rhs: ActivityLinesView) -> Bool {
        lhs.bursts == rhs.bursts && lhs.entering == rhs.entering && (lhs.review == nil) == (rhs.review == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
            ForEach(bursts) { burst in
                ActivityLineView(burst: burst, review: review).equatable().nwArrival(entering)
            }
        }
    }
}

/// One burst of tool work as an activity line (NWThread board). Expanding it shows its calls on
/// a rail; an edit or write opens the review pane at its file, any other call expands to its
/// output. ⌥-click or the context menu shows the raw call.
struct ActivityLineView: View, Equatable {
    let burst: NativeActivityBurst
    /// Opens the review pane at a file an edit or write touched.
    var review: ((String) -> Void)?
    private let inputRows: [String: NWActivityCallRow]
    private let inputTexts: [String: String]
    @State private var expanded: Bool
    @State private var expandedCalls: Set<String>
    @State private var sheet: CallSheet?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `expanded` and `expandedCalls` open the line, and calls in it, from the start.
    init(burst: NativeActivityBurst, review: ((String) -> Void)? = nil, expanded: Bool = false, expandedCalls: Set<String> = []) {
        self.burst = burst
        self.review = review
        var inputs: [String: NWActivityCallRow] = [:]
        var texts: [String: String] = [:]
        var open = expandedCalls
        for call in burst.calls {
            guard let arguments = call.arguments, !arguments.isEmpty else { continue }
            var script = false
            let text: String
            if call.name == "codemode",
               let data = arguments.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = object["code"] as? String {
                script = true
                text = code
            } else {
                text = arguments
            }
            guard !text.isEmpty else { continue }
            let id = "\(call.id):input"
            let lines = text.components(separatedBy: "\n")
            inputs[id] = NWActivityCallRow(
                id: id, label: script ? "script" : "input", detail: script ? "JavaScript" : call.name,
                output: Array(lines.prefix(NativeActivityCall.outputHeadLines)),
                moreLines: max(0, lines.count - NativeActivityCall.outputHeadLines),
                accessibilityLabel: "\(call.name) \(script ? "script" : "arguments")")
            texts[id] = text
            if script { open.insert(id) }
        }
        inputRows = inputs
        inputTexts = texts
        _expanded = State(initialValue: expanded)
        _expandedCalls = State(initialValue: open)
    }

    static func == (lhs: ActivityLineView, rhs: ActivityLineView) -> Bool {
        lhs.burst == rhs.burst && (lhs.review == nil) == (rhs.review == nil)
    }

    /// The full output, or the raw arguments, of one call.
    private struct CallSheet: Identifiable {
        let id = UUID()
        let title: String
        let text: String
        let truncated: Bool
    }

    var body: some View {
        if burst.kind == .lookedAt {
            LookedAtLineView(burst: burst) { line }
        } else {
            line
        }
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: 0) {
            NWActivityLine(kind: kind, label: burst.label, meta: burst.meta, status: status, isExpanded: expanded,
                           accessibilityLabel: burst.accessibilityLabel,
                           action: burst.expandable ? toggle : nil)
            if expanded {
                NWActivityCalls(burst.calls.flatMap { call -> [NWActivityCallRow] in
                    if var input = inputRows["\(call.id):input"] {
                        input.isExpanded = expandedCalls.contains(input.id)
                        return [input, row(call)]
                    }
                    return [row(call)]
                }, onSelect: select, onShowAll: showOutput) { row in
                    if let call = burst.calls.first(where: { $0.id == row.id }) { menu(call) }
                }
                .padding(.vertical, NW.Space.xxs)
                .nwTransition(.disclosure)
            }
        }
        .sheet(item: $sheet) { sheet in
            ToolOutputSheet(title: sheet.title, output: sheet.text, truncated: sheet.truncated) { self.sheet = nil }
        }
    }

    private var kind: NWActivityLine.Kind {
        switch burst.kind {
        case .explore: .explore
        case .edit: .edit
        case .run: .run
        case .subagents: .subagents
        case .drew: burst.isBoardUpdate ? .edit : .drew
        case .checked: .checked
        case .lookedAt: .lookedAtDesign
        case .browser: .browser
        case .other: .other
        }
    }

    private var status: NWActivityLine.Status {
        switch burst.state {
        case .done: .done
        case .failed: .failed
        case .running: .live(since: burst.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, tail: burst.tail)
        }
    }

    /// A click on this line: the whole thread eases around the calls as they open, so the
    /// change animates as one transaction rather than from a container.
    private func toggle() {
        withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) {
            if !expanded {
                for input in inputRows.values where input.label == "script" {
                    expandedCalls.insert(input.id)
                }
            }
            expanded.toggle()
        }
    }

    private func row(_ call: NativeActivityCall) -> NWActivityCallRow {
        let open = expandedCalls.contains(call.id)
        return NWActivityCallRow(
            id: call.id, label: call.label, detail: call.detail, isPath: call.isPath, stat: call.stat, failed: call.failed,
            output: open ? call.outputHead : [], moreLines: max(0, call.outputLineCount - call.outputHead.count),
            truncated: call.truncated, isExpanded: open,
            accessibilityLabel: [call.label, call.detail, call.stat, call.failed ? "failed" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private func select(_ id: String) {
        if inputTexts[id] != nil {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) {
                if expandedCalls.remove(id) == nil { expandedCalls.insert(id) }
            }
            return
        }
        guard let call = burst.calls.first(where: { $0.id == id }) else { return }
        if NSEvent.modifierFlags.contains(.option), let arguments = call.arguments {
            sheet = CallSheet(title: "\(call.name) · call", text: arguments, truncated: false)
            return
        }
        if call.kind == .edit, let path = call.path, let review {
            review(path)
        } else if call.expandable {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) {
                if expandedCalls.remove(id) == nil { expandedCalls.insert(id) }
            }
        }
    }

    private func showOutput(_ id: String) {
        if let text = inputTexts[id], let input = inputRows[id] {
            sheet = CallSheet(title: input.accessibilityLabel, text: text, truncated: false)
            return
        }
        guard let call = burst.calls.first(where: { $0.id == id }) else { return }
        sheet = CallSheet(title: "\(call.name) · \(call.detail)", text: call.output, truncated: call.truncated)
    }

    @ViewBuilder private func menu(_ call: NativeActivityCall) -> some View {
        if let arguments = call.arguments {
            Button("Show Call") { sheet = CallSheet(title: "\(call.name) · call", text: arguments, truncated: false) }
        }
        if call.kind == .edit, let path = call.path, let review {
            Button("Review \((path as NSString).lastPathComponent)") { review(path) }
        }
        if !call.output.isEmpty {
            Button("Open Output") { showOutput(call.id) }
            Button("Copy Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(call.output, forType: .string)
            }
        }
    }
}

/// The full output of one call ("… n more lines", Open Output), or its raw arguments.
struct ToolOutputSheet: View {
    let title: String
    let output: String
    let truncated: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.l) {
                Text(title).font(Font.nw(.mono, weight: .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .buttonStyle(NWButtonStyle(.secondary, size: .s))
                Button("Done", action: close).buttonStyle(NWButtonStyle(.primary, size: .s)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, NW.Space.xl)
            .frame(height: AppLayout.headerHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView([.vertical, .horizontal]) {
                Text(output).font(Font.nw(.code)).lineSpacing(NWTextStyle.code.lineSpacing).foregroundStyle(Color.nw.textSecondary)
                    .textSelection(.enabled).fixedSize().padding(NW.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if truncated {
                Text("The host clipped this output; the full text is in the agent's session file.")
                    .font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).padding(NW.Space.l)
            }
        }
        .frame(minWidth: AppLayout.toolOutputMinWidth, idealWidth: AppLayout.toolOutputIdealWidth,
               minHeight: AppLayout.toolOutputMinHeight, idealHeight: AppLayout.toolOutputIdealHeight)
        .background(Color.nw.bgWindow)
    }
}
