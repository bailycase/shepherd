import Foundation
import AppKit
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Real directory listings and source reads, rendered without focusing a window.
@Suite("Files previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct FilesPreviewTests {
    private func fixture() async throws -> (URL, FileTreeModel) {
        let root = try makeScratchDirectory()
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: checkout.appendingPathComponent("Sources/ShepherdApp/CodeHighlight.swift"),
                                        to: sources.appendingPathComponent("CodeHighlight.swift"))
        try FileManager.default.copyItem(at: checkout.appendingPathComponent("README.md"),
                                        to: root.appendingPathComponent("README.md"))
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: sources.path)
        await model.select(path: root.appendingPathComponent("README.md").path)
        await model.select(path: sources.appendingPathComponent("CodeHighlight.swift").path)
        return (root, model)
    }

    private func highlightingReady(prefix: String = "import Foundation") -> Bool {
        @MainActor func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.usesFindBar, text.isSelectable { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for window in NSApplication.shared.windows {
            guard let host = window.contentView, let text = editor(in: host), let storage = text.textStorage,
                  text.string.hasPrefix(prefix), text.visibleRect.minX == 0 else { continue }
            var colors = Set<String>()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let color = value as? NSColor { colors.insert(color.usingColorSpace(.deviceRGB)?.description ?? color.description) }
                }
            }
            if colors.count > 1 { return true }
        }
        return false
    }

    @Test func fileOpenSplit() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalScale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = originalScale }
        for scale in [CGFloat(1), CGFloat(1.3)] {
            ThemeStore.shared.textScale = scale
            let suffix = scale == 1 ? "" : "-x1.3"
            try await Preview.render("files-open-split\(suffix)", size: CGSize(width: 820, height: 700),
                                     ready: { highlightingReady() }) {
                FilesTab(model: model)
            }
        }
    }

    @Test func treeCollapsed() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Preview.render("files-tree-collapsed", size: CGSize(width: 820, height: 700),
                                 ready: { highlightingReady() }) {
            FilesTab(model: model, treeVisible: false)
        }
    }

    @Test func noFileSelected() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "A local file\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        try await Preview.render("files-no-selection", size: CGSize(width: 600, height: 500)) {
            FilesTab(model: model)
        }
    }

    @Test func wordWrapEnabled() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = AppSettings.shared.filesWordWrap
        defer { AppSettings.shared.filesWordWrap = saved }
        AppSettings.shared.filesWordWrap = true
        try await Preview.render("files-word-wrap", size: CGSize(width: 820, height: 700),
                                 ready: { highlightingReady() }) {
            FilesTab(model: model)
        }
    }

    @Test func markdownPreviewLightAndDark() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let md = "# Shepherd\n\nA **native** macOS app for running agents.\n\n- First item\n- Second item\n\n```swift\nlet x = 42\n```\n"
        try md.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: root.appendingPathComponent("README.md").path)

        let saved = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = saved }
        AppSettings.shared.filesMarkdownPreview = true

        // Preview.render already captures both light and dark appearances.
        try await Preview.render("files-markdown-preview", size: CGSize(width: 700, height: 500)) {
            FilesTab(model: model)
        }
    }

    /// The PaneFiles board's state: an agent change taken in, unsaved edits on top, the agent
    /// editing another open file.
    private func editingFixture() async throws -> (URL, FileTreeModel, URL) {
        let root = try makeScratchDirectory().appendingPathComponent("acme-web")
        let components = root.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: components, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/styles"), withIntermediateDirectories: true)
        for name in ["OrderSummary.tsx", "PromoList.tsx"] {
            try "export {}\n".write(to: components.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "export function PromoField() {}\n".write(to: components.appendingPathComponent("PromoField.tsx"), atomically: true, encoding: .utf8)
        try ":root { --pay: #2f6; }\n".write(to: root.appendingPathComponent("src/styles/tokens.css"), atomically: true, encoding: .utf8)
        try "# acme-web\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let checkout = components.appendingPathComponent("Checkout.tsx")
        let before = """
        export function Checkout({ cart }: Props) {
          const [promoOpen, setPromoOpen] = useState(false);
          const pay = usePayment(cart.id);

          return (
            <form className="checkout" onSubmit={pay.submit}>
              <ContactFields />
              <CardFields />
              <PromoField onApply={cart.applyPromo} />
              <OrderSummary cart={cart} />
              <div className="checkout-actions">
                <Button className="pay" size="lg">
                  {payLabel}
                </Button>
              </div>
            </form>
          );
        }

        // Keeps the button still while the promo field animates.
        const actionsHeight = 44;

        """
        try before.write(to: checkout, atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: root.appendingPathComponent("src").path)
        await model.expand(path: components.path)
        await model.select(path: components.appendingPathComponent("PromoField.tsx").path)
        await model.select(path: root.appendingPathComponent("src/styles/tokens.css").path)
        await model.select(path: checkout.path)
        // The agent's change, taken in by the clean editor.
        let agent = before.replacingOccurrences(of: "      <PromoField onApply={cart.applyPromo} />\n", with: """
              {promoOpen ? (
                <PromoField onApply={cart.applyPromo} />
              ) : (
                <LinkButton onClick={openPromo}>Have a promo code?</LinkButton>
              )}

        """)
        try agent.write(to: checkout, atomically: true, encoding: .utf8)
        await model.checkDisk()
        // The person's edit on top, not saved yet.
        model.setText(agent.replacingOccurrences(of: """
                <Button className="pay" size="lg">
                  {payLabel}
        """, with: """
                <Button className="pay" size="lg" disabled={pay.pending}>
                  {pay.pending ? <Spinner /> : payLabel}
        """), for: checkout.path)
        return (root.deletingLastPathComponent(), model, checkout)
    }

    /// The pane card of GXPaneFiles and GXPaneFilesEdit: 720 wide, 8pt in from the window.
    private func paneCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            SHSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 5, browser: true, subagents: (5, .done), pullRequest: 31),
                           selection: SidePaneTab.files.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                Button("Reset Width") {}
            }
            content()
        }
            .frame(width: AppLayout.paneDefaultWidth, height: 884)
            .shCard(lift: true)
            .padding(SHSidePaneMetrics.cardInset)
            .background(Color.sh.bgWindow)
    }

    private func changedFile(_ path: String, isNew: Bool) -> DiffFile {
        DiffFile(oldPath: isNew ? nil : path, newPath: path, displayPath: path, isNew: isNew, isDeleted: false, isRenamed: false,
                 isBinary: false, hunks: [DiffHunk(header: "@@", lines: [DiffLine(kind: .added, text: "", oldLine: nil, newLine: 1, id: 1)])])
    }

    @Test func paneFilesEditing() async throws {
        let (root, model, _) = try await editingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Preview.render("files-editing", size: CGSize(width: 736, height: 900),
                                 ready: { highlightingReady(prefix: "export function") }) {
            paneCard {
                FilesTab(model: model, agentPath: "src/components/PromoField.tsx", changes: FileChanges(files: [
                    "src/components/Checkout.tsx": changedFile("src/components/Checkout.tsx", isNew: false),
                    "src/components/PromoField.tsx": changedFile("src/components/PromoField.tsx", isNew: true),
                ], isLastTurn: true))
            }
        }
    }

    /// GXPaneFiles's data: a made-up payments worktree, five files the thread changed, codec.go added with its lines 8-18 changed in the last turn.
    private func boardFixture() async throws -> (URL, FileTreeModel, FileChanges) {
        let root = try makeScratchDirectory().appendingPathComponent("payments")
        for folder in ["cmd", "ledger", "migrations", "payments", "internal"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let codec = """
        package ledger

        import (
        \t"encoding/json"
        \t"fmt"
        )

        // Codec turns refund events into outbox rows and back.
        type Codec struct{ version int }

        func NewCodec() *Codec { return &Codec{version: 2} }

        func (c *Codec) Encode(e RefundEvent) ([]byte, error) {
        \tif e.Amount <= 0 {
        \t\treturn nil, fmt.Errorf("refund %s: amount must be positive", e.ID)
        \t}
        \treturn json.Marshal(e)
        }

        func (c *Codec) Decode(row []byte) (RefundEvent, error) {
        \tvar e RefundEvent
        \terr := json.Unmarshal(row, &e)
        \treturn e, err
        }

        """
        let ledger = root.appendingPathComponent("ledger")
        try codec.write(to: ledger.appendingPathComponent("codec.go"), atomically: true, encoding: .utf8)
        for name in ["outbox.go", "outbox_test.go", "refund.go", "refund_test.go"] {
            try "package ledger\n".write(to: ledger.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "create table refund_events ();\n".write(to: root.appendingPathComponent("migrations/0042_refund_events.sql"), atomically: true, encoding: .utf8)
        for name in ["AGENTS.md", "go.mod", "go.sum"] {
            try "x\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: ledger.path)
        await model.expand(path: root.appendingPathComponent("migrations").path)
        await model.select(path: ledger.appendingPathComponent("codec.go").path)

        func file(_ path: String, isNew: Bool, added: ClosedRange<Int>) -> DiffFile {
            let lines = added.map { DiffLine(kind: .added, text: "", oldLine: nil, newLine: $0, id: $0) }
            return DiffFile(oldPath: isNew ? nil : path, newPath: path, displayPath: path, isNew: isNew, isDeleted: false,
                            isRenamed: false, isBinary: false, hunks: [DiffHunk(header: "@@", lines: lines)])
        }
        let changes = FileChanges(files: [
            "ledger/codec.go": file("ledger/codec.go", isNew: true, added: 8...18),
            "ledger/outbox.go": file("ledger/outbox.go", isNew: false, added: 30...32),
            "ledger/refund.go": file("ledger/refund.go", isNew: true, added: 1...2),
            "ledger/refund_test.go": file("ledger/refund_test.go", isNew: true, added: 1...2),
            "migrations/0042_refund_events.sql": file("migrations/0042_refund_events.sql", isNew: true, added: 1...1),
        ], isLastTurn: true)
        return (root.deletingLastPathComponent(), model, changes)
    }

    /// GXPaneFiles: the tree with its A and M letters and the thread's note, and a file the thread added, its changed lines washed green.
    @Test func paneFilesReading() async throws {
        let (root, model, changes) = try await boardFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Preview.render("files-pane", size: CGSize(width: 736, height: 900), ready: { highlightingReady(prefix: "package ledger") }) {
            paneCard { FilesTab(model: model, changes: changes) }
        }
    }

    @Test func paneFilesConflict() async throws {
        let (root, model, checkout) = try await editingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "// rewritten by the agent\n".write(to: checkout, atomically: true, encoding: .utf8)
        await model.checkDisk()
        try await Preview.render("files-conflict", size: CGSize(width: 736, height: 900),
                                 ready: { highlightingReady(prefix: "export function") }) {
            paneCard { FilesTab(model: model) }
        }
    }
}
