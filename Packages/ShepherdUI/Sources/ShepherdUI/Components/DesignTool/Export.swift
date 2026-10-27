import SwiftUI

/// The Export sheet (DZExport) as the board draws it: a 560pt card at radius 14 on the popover's
/// fill, line and shadow, with a header ("Export" and a close button), sections under their
/// labels with a hairline between them, and a footer holding Cancel and the primary action.
/// Center it over `Color.sh.sheetScrim`.
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Export")
                    .font(.sh(.title))
                    .foregroundStyle(Color.sh.textPrimary)
                Spacer(minLength: SH.Space.m)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon())
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(.vertical, SHDesignMetrics.exportHeaderPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.exportPaddingHorizontal)
            .overlay(alignment: .bottom) { SHHairline() }
            content()
            HStack(spacing: SHDesignMetrics.exportFooterSpacing) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(.sh(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(exportTitle, systemImage: "square.and.arrow.up", action: export)
                    .buttonStyle(.sh(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(.vertical, SHDesignMetrics.exportFooterPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.exportPaddingHorizontal)
            .overlay(alignment: .top) { SHHairline() }
        }
        .frame(width: SHDesignMetrics.exportWidth)
        .shPopover(radius: SHDesignMetrics.exportRadius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// One section of the Export sheet: its label, then what it holds, with a hairline under it
/// unless it is the last.
public struct SHExportSection<Content: View>: View {
    let title: String
    let divided: Bool
    @ViewBuilder let content: () -> Content

    public init(_ title: String, divided: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.divided = divided
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.exportLabelGap) {
            Text(title).shSectionLabel()
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SHDesignMetrics.exportSectionPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.exportPaddingHorizontal)
        .overlay(alignment: .bottom) { if divided { SHHairline() } }
    }
}

/// A board's row on the Export sheet: its checkbox, its name, and its size trailing in mono.
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
                    .font(.shSans(SHDesignMetrics.exportRowTextSize))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .toggleStyle(.shCheckbox)
            Spacer(minLength: SH.Space.m)
            Text(size)
                .font(.shMono(SHDesignMetrics.exportRowSizeTextSize))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
        }
        .frame(height: SHDesignMetrics.exportRowHeight)
    }
}

/// A format on the Export sheet: a radio, the format, and what it writes; chosen, a `running`
/// line on `runningTint`.
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
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.exportFormatRadius)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: SHDesignMetrics.exportFormatGap) {
                HStack(spacing: SHDesignMetrics.exportFormatRadioGap) {
                    SHRadioMark(selected: isChosen)
                    Text(title)
                        .font(.shSans(SHDesignMetrics.exportFormatTitleSize, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                }
                Text(line)
                    .shText(size: SHDesignMetrics.exportFormatLineSize, lineHeight: SHDesignMetrics.exportFormatLineHeight)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SHDesignMetrics.exportFormatIndent)
            }
            .padding(.vertical, SHDesignMetrics.exportFormatPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.exportFormatPaddingHorizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isChosen ? Color.sh.runningTint : Color.clear, in: shape)
            .overlay(shape.strokeBorder(isChosen ? Color.sh.running : Color.sh.lineSubtle, lineWidth: 1))
            .contentShape(shape)
            .shComponentAnimation(.content, value: isChosen)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
