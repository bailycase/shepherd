import SwiftUI

/// The Export sheet (DZExport) as the board draws it: a 520pt card at radius 16 on the popover's
/// fill and shadow, 18×20 padding, "Export" in `title` with a close button, sections under their
/// 13 semibold labels, and a footer holding Cancel and the primary action.
/// Center it over `Color.sh.modalScrim`.
public struct SHExportSheet<Content: View>: View {
    let exportTitle: String
    let canExport: Bool
    let close: () -> Void
    let export: () -> Void
    @ViewBuilder let content: () -> Content

    public init(exportTitle: String, canExport: Bool, close: @escaping () -> Void, export: @escaping () -> Void,
                @ViewBuilder content: @escaping () -> Content) {
        self.exportTitle = exportTitle
        self.canExport = canExport
        self.close = close
        self.export = export
        self.content = content
    }

    public var body: some View {
        let M = SHDesignChrome.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Export")
                    .font(.sh(.title))
                    .foregroundStyle(Color.sh.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon(size: SH.Height.controlS))
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            content()
            HStack(spacing: SHDesignMetrics.exportFooterSpacing) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(.sh(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(exportTitle, action: export)
                    .buttonStyle(.sh(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(.top, M.exportFooterTop)
        }
        .padding(.top, M.exportPaddingTop)
        .padding(.bottom, M.exportPaddingBottom)
        .padding(.horizontal, M.exportPaddingHorizontal)
        .frame(width: M.exportWidth)
        .shPopover(radius: SH.Radius.xxl, line: .sh.lineSubtle)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// One section of the Export sheet: its 13 semibold label (and a count after it in 12 `textTertiary`), 6pt
/// above what it holds, 16pt under the section before.
public struct SHExportSection<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: () -> Content

    public init(_ title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.exportLabelGap) {
            HStack(spacing: SH.Space.s) {
                Text(title)
                    .font(.shSans(SHDesignChrome.toolbarTextSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .frame(minHeight: SHDesignChrome.exportLine)
                if let detail {
                    Text(detail)
                        .font(.shSans(SHDesignChrome.paneCountSize))
                        .foregroundStyle(Color.sh.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SHDesignChrome.exportSectionTop)
    }
}

/// A board's row on the Export sheet: its checkbox, its name, and its size trailing in 12 `textTertiary`, a
/// hairline under it.
public struct SHExportBoardRow: View, Equatable {
    let title: String
    let size: String
    let isTicked: Bool
    let toggle: () -> Void

    public init(title: String, size: String, isTicked: Bool, toggle: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.isTicked = isTicked
        self.toggle = toggle
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.size == b.size && a.isTicked == b.isTicked
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("design.exportRow")
        HStack(spacing: SHDesignMetrics.exportRowSpacing) {
            Toggle(isOn: Binding(get: { isTicked }, set: { _ in toggle() })) {
                Text(title)
                    .font(.shSans(SHDesignChrome.toolbarTextSize))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .toggleStyle(.shCheckbox)
            Spacer(minLength: SH.Space.m)
            Text(size)
                .font(.shSans(SHDesignChrome.paneCountSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
        }
        .frame(height: SHDesignChrome.exportRowHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// A format on the Export sheet: its name in 13 semibold over what it writes in 12 `textSecondary`; chosen, a
/// 1.5pt ink ring.
public struct SHExportFormatCard: View {
    let title: String
    let line: String
    let isChosen: Bool
    let choose: () -> Void

    public init(_ title: String, line: String, isChosen: Bool, choose: @escaping () -> Void) {
        self.title = title
        self.line = line
        self.isChosen = isChosen
        self.choose = choose
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l - 2)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shSans(SHDesignChrome.toolbarTextSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .frame(minHeight: SHDesignChrome.exportLine)
                Text(line)
                    .shText(size: SHDesignChrome.paneCountSize, lineHeight: SHDesignChrome.exportFormatLine)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, SHDesignChrome.exportFormatTop)
            .padding(.bottom, SHDesignChrome.exportFormatBottom)
            .padding(.horizontal, SHDesignMetrics.exportFormatPaddingHorizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay { shape.strokeBorder(isChosen ? Color.clear : Color.sh.lineSubtle, lineWidth: 1) }
            .overlay { shape.strokeBorder(isChosen ? Color.sh.textPrimary : Color.clear, lineWidth: SHDesignChrome.boardRing) }
            .contentShape(shape)
            .shComponentAnimation(.content, value: isChosen)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
