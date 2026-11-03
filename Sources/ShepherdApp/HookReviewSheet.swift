import SwiftUI
import ShepherdSessions
import ShepherdUI

// Review hooks (HooksReview board): each hook new or changed since it was trusted, with a checkbox,
// its name, a New or Changed badge and its event; open, where it is, when it runs, its matcher, its
// command (a diff when it changed), its time limit and why it's waiting. Not now dismisses; Trust
// all and Trust N selected trust those exact entries.

/// One hook in the sheet, derived once when the sheet opens.
struct HookReviewItem: Equatable, Identifiable {
    struct Line: Equatable { enum Kind { case same, added, removed }; var kind: Kind; var text: String }
    var id: String
    var name: String
    var changed: Bool
    var event: String
    var when: String
    var matcher: String
    var file: String
    var commandLabel: String
    var lines: [Line]
    var timeout: String
    var origin: String

    init(_ entry: HookEntry, file: String) {
        id = entry.slot
        name = entry.name
        event = entry.event
        when = entry.hookEvent?.label ?? entry.event
        matcher = entry.matcher.isEmpty ? "–" : entry.matcher
        self.file = file
        let event = entry.hookEvent ?? .preToolUse
        timeout = entry.handler.timeout.map { "\(Self.seconds($0)) s" } ?? "\(Self.seconds(event.defaultTimeout)) s (default)"
        let now = HooksModel.command(entry.handler)
        if case .changed(let previous) = entry.review {
            changed = true
            commandLabel = "Command, changed"
            let before = (try? HookJSON.parse(previous.entry)).map { HooksModel.command(HookHandler(raw: $0)) } ?? previous.entry
            var lines: [Line] = []
            if previous.matcher != entry.matcher { lines.append(.init(kind: .removed, text: "- matcher " + previous.matcher)); lines.append(.init(kind: .added, text: "+ matcher " + entry.matcher)) }
            if before != now { lines.append(.init(kind: .removed, text: "- " + before)); lines.append(.init(kind: .added, text: "+ " + now)) }
            else if previous.entry != entry.canonical { lines.append(.init(kind: .removed, text: "- " + previous.entry)); lines.append(.init(kind: .added, text: "+ " + entry.canonical)) }
            if lines.isEmpty { lines = [.init(kind: .same, text: now)] }
            self.lines = lines
            let date = (try? Date(previous.at, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .shortened) }
            origin = "Changed in its file since you trusted it" + (date.map { " on \($0)" } ?? "") + ", outside Shepherd."
        } else {
            changed = false
            commandLabel = "Command"
            lines = [.init(kind: .same, text: now)]
            origin = "Added to its file outside Shepherd: an agent or an editor wrote it."
        }
    }

    static func seconds(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
}

@MainActor
@Observable
final class HookReviewState {
    let items: [HookReviewItem]
    let entries: [HookEntry]
    var checked: Set<String> = []
    var open: String?
    var trusting = false

    init(entries: [HookEntry], label: (HookEntry) -> String) {
        self.entries = entries
        items = entries.map { HookReviewItem($0, file: label($0)) }
        open = items.first?.id
    }
}

struct HookReviewSheet: View {
    @Bindable var review: HookReviewState
    let model: HooksModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SH.Space.l) {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text("Review hooks").shText(.title).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                    Text("These run commands with your permissions. Shepherd skips them until you trust them.")
                        .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HookSheetClose(action: close)
            }
            .padding(.top, SH.Space.xl).padding(.leading, SH.Space.xxl).padding(.trailing, SH.Space.l).padding(.bottom, SH.Space.m)
            ScrollView {
                VStack(spacing: SH.Space.m) {
                    if review.items.isEmpty {
                        Text("Nothing waits for review.").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(review.items) { item in
                        HookReviewRow(item: item, checked: review.checked.contains(item.id), open: review.open == item.id,
                                      toggle: { if review.checked.remove(item.id) == nil { review.checked.insert(item.id) } },
                                      fold: { withSHAnimation(.disclosure) { review.open = review.open == item.id ? nil : item.id } })
                    }
                }
                .padding(.horizontal, SH.Space.xxl).padding(.top, SH.Space.m).padding(.bottom, SH.Space.l)
            }
            .frame(maxHeight: AppLayout.hooksJSONHeight)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SH.Space.m) {
                Text("You can change this later in Settings › Hooks.").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Not now", action: close).buttonStyle(.sh(.secondary, size: .m)).keyboardShortcut(.cancelAction)
                Button("Trust all") { trust(review.entries) }.buttonStyle(.sh(.secondary, size: .m)).disabled(review.items.isEmpty)
                Button(review.checked.isEmpty ? "Trust selected" : "Trust \(review.checked.count) selected") {
                    trust(review.entries.filter { review.checked.contains($0.slot) })
                }
                .buttonStyle(.sh(.primary, size: .m))
                .keyboardShortcut(.defaultAction)
                .disabled(review.checked.isEmpty)
            }
            .padding(.horizontal, SH.Space.xxl).padding(.top, SH.Space.l).padding(.bottom, SH.Space.xl)
        }
        .frame(width: AppLayout.hooksSheetWidth)
        .background(Color.sh.bgRaised)
        .disabled(review.trusting)
    }

    private func trust(_ entries: [HookEntry]) {
        review.trusting = true
        Task {
            let ok = await model.trust(entries)
            review.trusting = false
            if ok { close() }
        }
    }
}

struct HookReviewRow: View {
    let item: HookReviewItem
    let checked: Bool
    let open: Bool
    let toggle: () -> Void
    let fold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.l) {
                Toggle("Select \(item.name)", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                    .toggleStyle(.shCheckbox).labelsHidden()
                Button(action: fold) {
                    HStack(spacing: SH.Space.m) {
                        Text(item.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                        HookBadge(text: item.changed ? "Changed" : "New", tone: item.changed ? .attention : .done)
                        Spacer(minLength: SH.Space.m)
                        Text(item.event).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                        HookChevron(open: open)
                    }
                    .frame(height: AppLayout.hooksReviewHeadHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name), \(item.changed ? "changed" : "new"), \(item.event)")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
            .padding(.horizontal, SH.Space.l)
            if open {
                Grid(alignment: .topLeading, horizontalSpacing: SH.Space.l, verticalSpacing: SH.Space.s) {
                    pair("Source") { Text(item.file).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary) }
                    pair("When") {
                        HStack(spacing: SH.Space.xs) {
                            Text(item.when).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                            Text(item.event).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    pair("Matcher") { Text(item.matcher).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary) }
                    pair(item.commandLabel) { HookDiff(lines: item.lines) }
                    pair("Time limit") { Text(item.timeout).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary) }
                    pair("Why it’s here") { Text(item.origin).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary) }
                }
                .padding(.leading, SH.Space.l + AppLayout.hooksCheckSize + SH.Space.l)
                .padding(.trailing, SH.Space.l).padding(.bottom, SH.Space.l)
                .shTransition(.disclosure)
            }
        }
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
    }

    private func pair<V: View>(_ key: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(key).font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).frame(width: AppLayout.hooksKeyWidth, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A command, or its change as removed and added lines.
struct HookDiff: View {
    let lines: [HookReviewItem.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text).font(.sh(.code)).foregroundStyle(Color.sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .added ? Color.sh.doneTint : line.kind == .removed ? Color.sh.failedTint : Color.clear)
            }
        }
        .padding(.vertical, SH.Space.s)
        .background(Color.sh.bgBase, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.s))
    }
}

/// "New", "Changed · needs review", "Failed last run": a small tinted badge.
struct HookBadge: View {
    enum Tone { case done, attention, failed }
    let text: String
    let tone: Tone

    var body: some View {
        let (fill, ink): (Color, Color) = switch tone {
        case .done: (Color.sh.doneTint, Color.sh.done)
        case .attention: (Color.sh.lanternTint, Color.sh.lanternText)
        case .failed: (Color.sh.failedTint, Color.sh.failed)
        }
        Text(text).font(.sh(.micro)).foregroundStyle(ink).lineLimit(1)
            .padding(.horizontal, SH.Space.s).frame(height: AppLayout.hooksBadgeHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .fixedSize()
    }
}

/// The boards' fold chevron: down, turned over while open.
struct HookChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.down").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
            .shAnimation(.disclosure, value: open)
            .accessibilityHidden(true)
    }
}
