import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

/// Implement in a thread's sheet as values (ImplementInThreadSheet; RefImplementSheet,
/// RefImplementBoard): the piece (pinned when the sheet opens, so what the footer says is what
/// goes), an existing thread picked from a searchable list or a new one in a project on a new
/// worktree, the optional message, and whether sending opens the thread (remembered).
@MainActor @Observable
final class ImplementSheetModel {
    struct Thread: Equatable, Identifiable {
        let id: AgentID
        let name: String
        let project: String?
        let age: String?
    }

    struct Project: Equatable, Identifiable {
        let id: SpaceID
        let name: String
        let path: String
        /// A git checkout: a new thread starts on a new worktree of it.
        let isRepo: Bool
    }

    let selection: DesignReferenceSelection
    var picture: NWReferenceImage?
    /// The piece pinned at the design's revision now, and what a send of it carries; nil while
    /// the host reads it.
    private(set) var prepared: PreparedDesignReference?
    var mode: NWImplementMode = .existing
    var query = "" {
        didSet { if query != oldValue { filter() } }
    }
    /// The threads the search leaves, most recently active first.
    private(set) var shownThreads: [NWImplementThread] = []
    var thread: String?
    var message = ""
    var opensThread: Bool
    var project: SpaceID?
    let threads: [Thread]
    let projects: [Project]
    var sending = false
    var error: String?

    init(selection: DesignReferenceSelection, threads: [Thread], projects: [Project], project: SpaceID?, opensThread: Bool,
         picture: NWReferenceImage? = nil) {
        self.selection = selection
        self.threads = threads
        self.projects = projects
        self.project = project ?? projects.first?.id
        self.opensThread = opensThread
        self.picture = picture
        thread = threads.first?.id.rawValue
        mode = threads.isEmpty ? .new : .existing
        filter()
    }

    func prepared(_ prepared: PreparedDesignReference) {
        self.prepared = prepared
    }

    /// The piece as the canvas and the menu that opened the sheet named it: "card “Checkout
    /// funnel”". The sheet, the new thread, its branch and the toasts all say it.
    var piece: String { selection.piece }

    /// "Implement card “Checkout funnel”".
    var title: String { "Implement " + piece }

    /// The line under the title: the design, and the board for an element (the piece is the title).
    var crumbs: [String] { Array(selection.crumbs.dropLast()) }

    var version: String? { DesignReferencePresentation.version(prepared?.reference.revision) }

    /// The footer: exactly what a send carries, the system's name in mono.
    var sends: Text {
        guard let prepared else { return Text(error ?? "Reading what it sends…") }
        let words = DesignReferencePresentation.sends(prepared.outline)
        if let system = prepared.outline.system, let range = words.range(of: " from \(system).") {
            return NWImplementSheet<EmptyView>.sends(String(words[..<range.lowerBound]) + " from ", mono: system, after: ".")
        }
        return Text(words)
    }

    var chosenProject: Project? { projects.first { $0.id == project } }

    /// The new thread's branch: "agent/implement-card-checkout-funnel".
    var branch: String { ImplementBranch.name(for: piece) }

    var canSend: Bool {
        guard prepared != nil, !sending else { return false }
        switch mode {
        case .existing: return thread.flatMap { id in threads.first { $0.id.rawValue == id } } != nil
        case .new: return chosenProject != nil
        }
    }

    private func filter() {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let next = threads.filter { thread in
            guard !words.isEmpty else { return true }
            let text = [thread.name, thread.project ?? ""].joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy(text.contains)
        }.map { NWImplementThread(id: $0.id.rawValue, name: $0.name, project: $0.project, age: $0.age) }
        if next != shownThreads { shownThreads = next }
        if let thread, !next.contains(where: { $0.id == thread }) { self.thread = next.first?.id }
        if thread == nil { thread = next.first?.id }
    }
}

/// A new thread's branch for a piece.
enum ImplementBranch {
    /// "agent/implement-" and the piece in lower-case words joined by dashes, at most 40 of them.
    static func name(for piece: String) -> String {
        var slug = ""
        var dash = false
        // A direction's letter goes ("A · Funnel first" is funnel-first).
        var words = Substring(piece)
        if let dot = piece.range(of: " · "), piece[..<dot.lowerBound].count <= 2 { words = piece[dot.upperBound...] }
        for scalar in words.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if dash, !slug.isEmpty { slug.append("-") }
                dash = false
                slug.unicodeScalars.append(scalar)
            } else {
                dash = true
            }
            if slug.count >= 40 { break }
        }
        return "agent/implement-" + (slug.isEmpty ? "design" : slug)
    }

    /// The name with "-2", "-3"… for the nth try.
    static func name(for piece: String, attempt: Int) -> String {
        attempt <= 1 ? name(for: piece) : name(for: piece) + "-\(attempt)"
    }
}

/// The sheet over the design (ImplementInThreadSheet): the piece, where it goes, the message, and
/// the footer saying what is sent.
struct ImplementSheetView: View {
    var vm: ShepherdViewModel
    @Bindable var model: ImplementSheetModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        // The canvas's picture of the piece, once its board has drawn (it may not have yet).
        NWImplementSheet(picture: vm.implementPicture(model.selection) ?? model.picture, title: model.title, crumbs: model.crumbs, version: model.version, mode: $model.mode,
                         sends: model.sends, canSend: model.canSend, sending: model.sending,
                         close: { vm.closeImplementSheet() }, send: { vm.sendImplementSheet(model) }) {
            if model.mode == .existing {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWSearchField("Search threads", text: $model.query)
                    if model.shownThreads.isEmpty {
                        Text(model.threads.isEmpty ? "No threads yet. Start one in a project." : "No thread matches “\(model.query)”.")
                            .font(.nwSans(NWImplementMetrics.rowMetaSize))
                            .foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: NWImplementMetrics.rowHeight)
                    } else {
                        NWImplementThreadList(threads: model.shownThreads, selection: $model.thread)
                    }
                }
            } else {
                NWImplementField("Project") {
                    Menu {
                        ForEach(model.projects) { project in
                            Button {
                                model.project = project.id
                            } label: {
                                if project.id == model.project { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                            }
                        }
                    } label: {
                        NWImplementProjectLabel(project: model.chosenProject?.name ?? "Choose a project", host: "This Mac")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(model.projects.isEmpty)
                    if let project = model.chosenProject {
                        if project.isRepo {
                            NWImplementBranchLine("Starts on a new worktree,", branch: model.branch)
                        } else {
                            NWImplementBranchLine("Starts in the project: it isn’t a git repository, so no worktree.")
                        }
                    }
                }
            }
            NWImplementField("Message") {
                NWImplementMessageField(text: $model.message, focused: $messageFocused)
            }
            Toggle(isOn: $model.opensThread) {
                Text("Open the thread after sending")
                    .font(.nwSans(NWImplementMetrics.checkLabelSize))
                    .foregroundStyle(Color.nw.textSecondary)
            }
            .toggleStyle(.nwCheckbox)
            if let error = model.error, model.prepared != nil {
                Text(error).font(.nwSans(NWImplementMetrics.rowMetaSize)).foregroundStyle(Color.nw.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.sending)
        .onChange(of: model.opensThread) { _, opens in vm.settings.implementOpensThread = opens }
    }
}

/// The sheet centered over the window on its scrim, as Export's is.
struct ImplementSheetOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        ZStack {
            if let model = vm.implementSheet {
                Color.nw.sheetScrim
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .nwTransition(.content)
                ImplementSheetView(vm: vm, model: model)
                    .nwTransition(.overlay, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(vm.implementSheet != nil)
        .nwAnimation(.overlay, value: vm.implementSheet != nil)
    }
}

/// The toast on a design's canvas after a reference went (RefSentStay, RefCopied).
struct DesignReferenceToast: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Sent to a thread, staying on the canvas: Open thread.
        case sent(thread: AgentID, name: String)
        case copied
    }

    let id = UUID()
    let designID: DesignID
    let kind: Kind
    let piece: String

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// How long it stays before it goes by itself.
    static let lifetime: Duration = .seconds(6)
}

/// The toast over a design's canvas, centered above its bottom edge.
struct DesignReferenceToastLayer: View {
    var vm: ShepherdViewModel
    let designID: DesignID

    var body: some View {
        ZStack {
            if let toast = vm.referenceToast, toast.designID == designID {
                Group {
                    switch toast.kind {
                    case .sent(let thread, let name):
                        NWReferenceToast(.sent, message: Text("Sent \(toast.piece) to \(Text(name).fontWeight(.semibold))."),
                                         actionTitle: "Open thread", actionSymbol: "text.bubble",
                                         action: { vm.referenceToast = nil; vm.selectAgent(thread) },
                                         dismiss: { vm.referenceToast = nil })
                    case .copied:
                        NWReferenceToast(.copied, message: Text(DesignReferencePresentation.copied(toast.piece)),
                                         dismiss: { vm.referenceToast = nil })
                    }
                }
                .padding(.horizontal, NW.Space.xl)
                .padding(.bottom, NWReferenceMetrics.toastBottom)
                .id(toast.id)
                .nwTransition(.sheet, edge: .bottom)
                .task(id: toast.id) {
                    // Only a toast that stayed its time goes by itself; leaving the canvas keeps it.
                    guard (try? await Task.sleep(for: DesignReferenceToast.lifetime)) != nil else { return }
                    if vm.referenceToast?.id == toast.id { vm.referenceToast = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .nwAnimation(.sheet, value: vm.referenceToast?.id)
    }
}
