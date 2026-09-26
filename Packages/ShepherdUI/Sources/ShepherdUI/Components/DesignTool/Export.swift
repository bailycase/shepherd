import SwiftUI

/// The Export sheet (DZExport) as the board draws it: a 560pt card at radius 14 on the popover's
/// fill, line and shadow, with a header ("Export" and a close button), sections under their
/// labels with a hairline between them, and a footer holding Cancel and the primary action.
/// Center it over `Color.nw.sheetScrim`.
public struct NWExportSheet<Content: View>: View {
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
                    .font(.nw(.title))
                    .foregroundStyle(Color.nw.textPrimary)
                Spacer(minLength: NW.Space.m)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.nwIcon())
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(.vertical, NWDesignMetrics.exportHeaderPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.exportPaddingHorizontal)
            .overlay(alignment: .bottom) { NWHairline() }
            content()
            HStack(spacing: NWDesignMetrics.exportFooterSpacing) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(.nw(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(exportTitle, systemImage: "square.and.arrow.up", action: export)
                    .buttonStyle(.nw(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(.vertical, NWDesignMetrics.exportFooterPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.exportPaddingHorizontal)
            .overlay(alignment: .top) { NWHairline() }
        }
        .frame(width: NWDesignMetrics.exportWidth)
        .nwPopover(radius: NWDesignMetrics.exportRadius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// One section of the Export sheet: its label, then what it holds, with a hairline under it
/// unless it is the last.
public struct NWExportSection<Content: View>: View {
    let title: String
    let divided: Bool
    @ViewBuilder let content: () -> Content

    public init(_ title: String, divided: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.divided = divided
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NWDesignMetrics.exportLabelGap) {
            Text(title).nwSectionLabel()
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NWDesignMetrics.exportSectionPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.exportPaddingHorizontal)
        .overlay(alignment: .bottom) { if divided { NWHairline() } }
    }
}

/// A board's row on the Export sheet: its checkbox, its name, and its size trailing in mono.
public struct NWExportBoardRow: View, Equatable {
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
        let _ = NWRenderProbe.tick("design.exportRow")
        HStack(spacing: NWDesignMetrics.exportRowSpacing) {
            Toggle(isOn: Binding(get: { isTicked }, set: { _ in toggle() })) {
                Text(title)
                    .font(.nwSans(NWDesignMetrics.exportRowTextSize))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .toggleStyle(.nwCheckbox)
            Spacer(minLength: NW.Space.m)
            Text(size)
                .font(.nwMono(NWDesignMetrics.exportRowSizeTextSize))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
        }
        .frame(height: NWDesignMetrics.exportRowHeight)
    }
}

/// A format on the Export sheet: a radio, the format, and what it writes; chosen, a `running`
/// line on `runningTint`.
public struct NWExportFormatCard: View {
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
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.exportFormatRadius)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: NWDesignMetrics.exportFormatGap) {
                HStack(spacing: NWDesignMetrics.exportFormatRadioGap) {
                    NWRadioMark(selected: isChosen)
                    Text(title)
                        .font(.nwSans(NWDesignMetrics.exportFormatTitleSize, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                }
                Text(line)
                    .nwText(size: NWDesignMetrics.exportFormatLineSize, lineHeight: NWDesignMetrics.exportFormatLineHeight)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, NWDesignMetrics.exportFormatIndent)
            }
            .padding(.vertical, NWDesignMetrics.exportFormatPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.exportFormatPaddingHorizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isChosen ? Color.nw.runningTint : Color.clear, in: shape)
            .overlay(shape.strokeBorder(isChosen ? Color.nw.running : Color.nw.lineSubtle, lineWidth: 1))
            .contentShape(shape)
            .nwComponentAnimation(.content, value: isChosen)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
