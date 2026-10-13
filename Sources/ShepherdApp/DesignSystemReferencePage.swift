import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The built-in design system's page (DesignSystemPage and its eight sibling boards): a hero, the
// system's principles and voice, then Colors, Typography, Spacing, Corner radius, Size and
// Components as cards of read-only tables. A contents button opens a menu of the parts and the
// designs using the system. Dark | Light switches the page's own appearance; each color's dark
// and light values always sit side by side. Not drawn, on purpose: Edit, Add and a component's
// open icon (docs/design/boards/DesignSystem-checklist.md).

struct DesignSystemReferencePage: View {
    var vm: ShepherdViewModel
    let model: DesignSystemPageModel
    let reference: DesignSystemReference
    var chrome = PageHeaderChrome()

    /// `menuOpen` starts the contents menu open, for a render of it.
    init(vm: ShepherdViewModel, model: DesignSystemPageModel, reference: DesignSystemReference, chrome: PageHeaderChrome = PageHeaderChrome(),
         menuOpen: Bool = false) {
        self.vm = vm
        self.model = model
        self.reference = reference
        self.chrome = chrome
        _menuOpen = State(initialValue: menuOpen)
    }

    @Environment(\.colorScheme) private var system
    @State private var appearance: ColorScheme?
    @State private var menuOpen: Bool
    /// The part the contents menu last went to; the page starts at the overview.
    @State private var current = DesignSystemReference.Part.overview
    @State private var group = NWComponentCatalog.allGroups

    /// Column widths, nil where the column takes what is left: the boards' name column is fixed.
    private static let nameAndRest: [CGFloat?] = [AppLayout.referenceNameColumn + NW.Space.xxl * 2, nil]
    private static let componentName: [CGFloat?] = [AppLayout.referenceComponentNameColumn + NW.Space.xxl * 2, nil]
    private static let valueShape: [CGFloat?] = [AppLayout.referenceNameColumn + NW.Space.xxl * 2, nil,
                                                 AppLayout.referenceShapeColumn + NW.Space.xxl * 2]
    private static let valueNote: [CGFloat?] = [AppLayout.referenceNameColumn + NW.Space.xxl * 2, nil,
                                                AppLayout.referenceNoteColumn + NW.Space.xxl * 2]

    private var scheme: ColorScheme { appearance ?? system }

    var body: some View {
        let _ = NWRenderProbe.tick("page.designSystemReference")
        VStack(spacing: 0) {
            header
            GeometryReader { area in
                ScrollViewReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical) {
                            content
                                .frame(maxWidth: AppLayout.referenceColumnWidth)
                                .padding(.horizontal, NW.Space.xxxl)
                                .padding(.top, AppLayout.referenceTopPadding)
                                .padding(.bottom, AppLayout.referenceBottomPadding)
                                .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        contents(height: area.size.height) { part in
                            menuOpen = false
                            proxy.scrollTo(part.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(Color.nw.bgWindow)
        .environment(\.colorScheme, scheme)
    }

    // MARK: Header

    private var header: some View {
        NWDesignHeader(reference.title, style: .page, section: "Design systems", leadingInset: chrome.leadingInset,
                       sidebar: chrome.showSidebar, sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar),
                       designs: { vm.openDestination(.designs) }) {
            NWSegmentedPicker("Appearance", selection: Binding(get: { scheme }, set: { appearance = $0 }),
                              options: [(ColorScheme.dark, "Dark"), (ColorScheme.light, "Light")])
            Button("New design") { vm.openNewDesign(system: model.namespace) }
                .buttonStyle(.nw(.primary))
            if let namespace = model.namespace {
                NWDesignToolbarMore(label: "More for \(reference.title)") {
                    DesignMenuItems(menu: vm.designSystemMenu(.system(namespace))) { vm.performDesignSystemMenu($0, on: .system(namespace)) }
                }
            }
        }
    }

    // MARK: Contents

    /// The contents menu: the parts, then the designs using the system. It is as tall as its content up to the
    /// room under its button, then scrolls, so the last of many designs is always reachable in a short window.
    private func contents(height: CGFloat, select: @escaping (DesignSystemReference.Part) -> Void) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            Button { menuOpen.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.nw(.raised))
                .accessibilityLabel("Contents")
                .nwHelp("Contents")
            if menuOpen {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(reference.title).nwSectionLabel().padding(.horizontal, NW.Space.m).padding(.vertical, NW.Space.s)
                        ForEach(DesignSystemReference.Part.allCases) { part in
                            menuRow(part.title, count: reference.count(part), selected: part == current) {
                                current = part
                                select(part)
                            }
                        }
                        if !reference.used.isEmpty {
                            NWHairline().padding(.vertical, NW.Space.s).padding(.horizontal, NW.Space.m)
                            Text("Used by").nwSectionLabel().padding(.horizontal, NW.Space.m).padding(.vertical, NW.Space.s)
                            ForEach(reference.used) { design in
                                menuRow(design.name, count: design.boards, selected: false) {
                                    menuOpen = false
                                    vm.openDesign(design.id)
                                }
                            }
                        }
                    }
                    .padding(NW.Space.s)
                }
                .scrollIndicators(.automatic)
                .frame(width: AppLayout.referenceMenuWidth)
                .frame(maxHeight: max(height - NW.Height.controlM - AppLayout.referenceMenuInset * 2 - NW.Space.xs, NW.Height.row * 3))
                .fixedSize(horizontal: false, vertical: true)
                .nwPopover()
            }
        }
        .padding(AppLayout.referenceMenuInset)
        .zIndex(1)
    }

    private func menuRow(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                Text(title).font(.nw(.ui, weight: selected ? .semibold : nil))
                    .foregroundStyle(selected ? Color.nw.textPrimary : Color.nw.textSecondary).lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let count { Text("\(count)").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary) }
            }
            .padding(.horizontal, NW.Space.m)
            .frame(height: NW.Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(selected: selected))
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: AppLayout.referencePartSpacing) {
            hero.id(DesignSystemReference.Part.overview.id)
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text(DesignSystemCopy.lead(components: reference.components, namespace: reference.namespace))
                    .nwText(.body).foregroundStyle(Color.nw.textSecondary)
                Text(DesignSystemCopy.provenance).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            principles.id(DesignSystemReference.Part.principles.id)
            voice.id(DesignSystemReference.Part.voice.id)
            card("Colors", sub: "\(reference.colorCount) tokens · light and dark", part: .colors) { colors }
            card("Typography", sub: "Geist and Geist Mono · \(reference.typeCount) styles", part: .typography) { typography }
            card("Spacing", sub: "a 2 and 4-point grid", part: .spacing) { spacing }
            card("Corner radius", sub: "from pills to sheets", part: .radius) { radii }
            card("Size", sub: "controls and columns, from the app", part: .size) { sizes }
            card("Components", sub: "\(reference.components) in \(reference.title), drawn live", part: .components,
                 accessory: { groups }) { components }
        }
    }

    private var hero: some View {
        let rowHeight = (AppLayout.referenceHeroHeight - NW.Space.xxxl * 2 - NW.Space.m * (AppLayout.referenceHeroRows - 1)) / AppLayout.referenceHeroRows
        let tile = AppLayout.referenceHeroTileWidth
        let nw = Color.nw
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Text(reference.title)
                    .font(.nwSans(AppLayout.referenceHeroNameSize, .bold))
                    .tracking(-AppLayout.referenceHeroNameSize * 0.035)
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
                Text(DesignSystemCopy.tagline).font(.nw(.body)).foregroundStyle(nw.textSecondary)
            }
            // Clear of the art, which the name and tagline never run under at any text size.
            .padding(.trailing, tile * 4 + NW.Space.m * 3 + NW.Space.xxxl)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            HStack(alignment: .top, spacing: NW.Space.m) {
                VStack(spacing: NW.Space.m) {
                    RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.lantern)
                        .frame(width: tile * 2 + NW.Space.m, height: rowHeight * 2 + NW.Space.m)
                    HStack(spacing: NW.Space.m) {
                        RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.lanternTint).frame(width: tile, height: rowHeight)
                        RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.failed).frame(width: tile, height: rowHeight)
                    }
                }
                VStack(spacing: 0) {
                    Spacer().frame(height: rowHeight + NW.Space.m)
                    RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.running).frame(width: tile, height: rowHeight * 2 + NW.Space.m)
                }
                VStack(spacing: NW.Space.m) {
                    RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.done).frame(width: tile, height: rowHeight)
                    RoundedRectangle(cornerRadius: NW.Radius.m).fill(nw.bgRaised)
                        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(nw.lineStrong) }
                        .frame(width: tile, height: rowHeight * 2 + NW.Space.m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
        }
        .padding(NW.Space.xxxl)
        .frame(height: AppLayout.referenceHeroHeight)
        .background(nw.bgBase, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.l).strokeBorder(nw.lineSubtle) }
    }

    private var principles: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text("Principles").font(.nw(.title)).foregroundStyle(Color.nw.textPrimary).accessibilityAddTraits(.isHeader)
            bullets(DesignSystemCopy.principles.map { Text("\(Text($0.lead).fontWeight(.semibold).foregroundStyle(Color.nw.textPrimary)) \($0.text)") })
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            Text("Voice").font(.nw(.title)).foregroundStyle(Color.nw.textPrimary).accessibilityAddTraits(.isHeader)
            Text(DesignSystemCopy.voiceLead).nwText(.body).foregroundStyle(Color.nw.textSecondary)
            VStack(spacing: 0) {
                HStack(spacing: 0) { sayCell("Say", header: true); sayCell("Avoid", header: true, leading: true) }
                ForEach(Array(zip(DesignSystemCopy.say, DesignSystemCopy.avoid).enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 0) { sayCell(pair.0); sayCell(pair.1, leading: true) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
            .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle) }
            .accessibilityElement(children: .contain)
            bullets(DesignSystemCopy.voiceNotes.map { Text(verbatim: $0) })
        }
    }

    private func sayCell(_ text: String, header: Bool = false, leading: Bool = false) -> some View {
        Text(text)
            .font(.nw(.body, weight: header ? .medium : nil))
            .foregroundStyle(header ? Color.nw.textSecondary : Color.nw.textPrimary)
            .padding(.horizontal, NW.Space.l).padding(.vertical, NW.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(header ? Color.nw.bgSunken : .clear)
            .overlay(alignment: .top) { NWHairline() }
            .overlay(alignment: .leading) { if leading { NWHairline(.vertical) } }
    }

    private func bullets(_ items: [Text]) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                    Circle().fill(Color.nw.textTertiary).frame(width: NW.Space.s - NW.Space.xxs, height: NW.Space.s - NW.Space.xxs)
                        .accessibilityHidden(true)
                    item.nwText(.body).foregroundStyle(Color.nw.textSecondary)
                }
            }
        }
    }

    // MARK: Cards and tables

    private func card<Body: View, Accessory: View>(_ title: String, sub: String, part: DesignSystemReference.Part,
                                                    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
                                                    @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Text(title).font(.nwSans(AppLayout.referenceCardTitleSize, .semibold)).foregroundStyle(Color.nw.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(sub).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).padding(.leading, NW.Space.m)
                Spacer(minLength: NW.Space.m)
                accessory()
            }
            .padding(.horizontal, NW.Space.xxl).padding(.top, NW.Space.xxl).padding(.bottom, NW.Space.xl)
            body()
        }
        .nwCard(radius: NW.Radius.l)
        .id(part.id)
    }

    private func header(_ titles: [String], widths: [CGFloat?] = []) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, NW.Space.xxl).padding(.vertical, NW.Space.m)
                    .frame(width: widths.indices.contains(index) ? widths[index] : nil, alignment: .leading)
                    .frame(maxWidth: widths.indices.contains(index) && widths[index] != nil ? nil : .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { if index > 0 { NWHairline(.vertical) } }
            }
        }
        .overlay(alignment: .top) { NWHairline() }
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func row(_ cells: [AnyView], widths: [CGFloat?] = []) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                cell
                    .padding(.horizontal, NW.Space.xxl).padding(.vertical, NW.Space.m)
                    .frame(width: widths.indices.contains(index) ? widths[index] : nil, alignment: .leading)
                    .frame(maxWidth: widths.indices.contains(index) && widths[index] != nil ? nil : .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { if index > 0 { NWHairline(.vertical) } }
            }
        }
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func name(_ text: String) -> AnyView {
        AnyView(Text(text).font(.nw(.mono)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
            .frame(minHeight: NW.Height.controlM))
    }

    private func groupHeader(_ title: String, count: Int, hint: String? = nil) -> some View {
        HStack(spacing: NW.Space.s) {
            Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
            Text("\(count)").font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
            if let hint { Text(hint).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).padding(.leading, NW.Space.xs) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NW.Space.xxl).padding(.top, NW.Space.l).padding(.bottom, NW.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Colors

    private var colors: some View {
        VStack(spacing: 0) {
            ForEach(reference.colors) { group in
                groupHeader(group.title, count: group.rows.count, hint: group.hint)
                header(["Name", "Dark", "Light"])
                ForEach(group.rows) { color in
                    row([name(color.name),
                         AnyView(ValueChip(value: color.dark, scheme: .dark, ratio: color.darkRatio)),
                         AnyView(ValueChip(value: color.light, scheme: .light, ratio: color.lightRatio))])
                }
            }
        }
    }

    // MARK: Typography

    private var typography: some View {
        VStack(spacing: 0) {
            ForEach(reference.type) { group in
                groupHeader(group.title, count: group.rows.count)
                header(["Name", "Preview"], widths: Self.nameAndRest)
                ForEach(group.rows) { style in
                    row([name(style.name), AnyView(typeSample(style))], widths: Self.nameAndRest)
                }
            }
        }
    }

    private func typeSample(_ style: DesignSystemReference.TypeRow) -> some View {
        let mono = style.family.contains("Mono")
        let weight = DesignSystemContent.weight(style.weight)
        let text = style.uppercase ? DesignSystemCopy.microSample.uppercased() : DesignSystemCopy.sample
        return VStack(alignment: .leading, spacing: NW.Space.s) {
            Text(text)
                .font(mono ? .nwMono(CGFloat(style.size), weight) : .nwSans(CGFloat(style.size), weight))
                .tracking(style.uppercase ? CGFloat(style.size) * 0.04 : 0)
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
            Text(style.tag).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.s).frame(height: NW.Space.xl + NW.Space.xs)
                .nwBorder(Color.nw.lineStrong, radius: NW.Radius.xs)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Spacing, radius, size

    private var spacing: some View {
        VStack(spacing: 0) {
            header(["Name", "Value", "Shape"], widths: Self.valueShape)
            ForEach(reference.spacing) { step in
                row([name(step.name), AnyView(ValueChip(value: DesignSystemReference.number(step.px), unit: "px")
                        .frame(width: AppLayout.referenceValueChipWidth)),
                     AnyView(RoundedRectangle(cornerRadius: NW.Radius.xs).fill(Color.nw.running)
                        .frame(width: step.px * AppLayout.referenceBarScale, height: NW.Space.m)
                        .frame(minHeight: NW.Height.controlM).accessibilityHidden(true))], widths: Self.valueShape)
            }
        }
    }

    private var radii: some View {
        VStack(spacing: 0) {
            header(["Name", "Value", "Shape"], widths: Self.valueShape)
            ForEach(reference.radii) { step in
                row([name(step.name),
                     AnyView(HStack(spacing: NW.Space.m) {
                         ValueChip(value: DesignSystemReference.number(step.px), unit: "px")
                             .frame(width: AppLayout.referenceValueChipWidth)
                         Text(step.use).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                     }),
                     AnyView(RoundedRectangle(cornerRadius: step.px).fill(Color.nw.bgSunken)
                        .overlay { RoundedRectangle(cornerRadius: step.px).strokeBorder(Color.nw.lineStrong) }
                        .frame(width: AppLayout.referenceRadiusSample.width, height: AppLayout.referenceRadiusSample.height)
                        .accessibilityHidden(true))], widths: Self.valueShape)
            }
        }
    }

    private var sizes: some View {
        VStack(spacing: 0) {
            header(["Name", "Value", "Used for"], widths: Self.valueNote)
            ForEach(reference.sizes) { size in
                row([name(size.name), AnyView(ValueChip(value: "\(DesignSystemReference.number(size.px))px")),
                     AnyView(Text(size.use).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                        .frame(minHeight: NW.Height.controlM, alignment: .leading))], widths: Self.valueNote)
            }
        }
    }

    // MARK: Components

    private var groups: some View {
        NWPopupMenu(group) {
            ForEach([NWComponentCatalog.allGroups] + NWComponentCatalog.groups, id: \.self) { name in
                Button(name) { group = name }
            }
        }
        .help("Component group")
    }

    private var components: some View {
        let entries = NWComponentCatalog.entries.filter { group == NWComponentCatalog.allGroups || $0.group == group }
        return VStack(spacing: 0) {
            header(["Name", "Preview"], widths: Self.componentName)
            ForEach(entries) { entry in
                row([AnyView(VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text(entry.id).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
                    Text(entry.group).font(.nw(.micro)).foregroundStyle(Color.nw.textTertiary)
                }), AnyView(entry.specimen()
                    // A specimen is a picture of the component: it takes no press and is one element to VoiceOver.
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.id) specimen")
                    .padding(.vertical, NW.Space.m))], widths: Self.componentName)
            }
        }
    }
}

/// A token's value as the boards draw it: a read-only chip (28pt, `bgSunken`, `lineStrong`, radius
/// s) with a swatch when the value is a color, the value in mono, and for text a contrast ratio.
/// Drawn in `scheme`, so a light value sits on a light chip on the dark page.
private struct ValueChip: View {
    let value: String
    var unit: String?
    var scheme: ColorScheme?
    var ratio: Double?

    var body: some View {
        let chip = HStack(spacing: NW.Space.m) {
            if let hex = DesignSystemPresentation.hex(value) {
                RoundedRectangle(cornerRadius: NW.Radius.xs).fill(Color(light: hex, dark: hex))
                    .overlay { RoundedRectangle(cornerRadius: NW.Radius.xs).strokeBorder(Color.nw.lineStrong) }
                    .frame(width: NW.Space.xl, height: NW.Space.xl)
                    .accessibilityHidden(true)
            }
            Text(value.uppercased() == value || DesignSystemPresentation.hex(value) == nil ? value : value.uppercased())
                .font(.nw(.mono)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: NW.Space.m)
            if let unit { Text(unit).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary) }
            if let ratio { contrast(ratio) }
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NW.Height.controlM)
        .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(Color.nw.lineStrong) }
        .accessibilityElement(children: .combine)
        if let scheme { chip.environment(\.colorScheme, scheme) } else { chip }
    }

    private func contrast(_ ratio: Double) -> some View {
        let readable = ratio >= DesignSystemReference.readable
        return HStack(spacing: NW.Space.xxs) {
            Image(systemName: readable ? "checkmark" : "exclamationmark.triangle").accessibilityHidden(true)
            Text(String(format: "%.1f:1", ratio))
        }
        .font(.nw(.micro))
        .foregroundStyle(readable ? Color.nw.done : Color.nw.lanternText)
        .accessibilityLabel("Contrast \(String(format: "%.1f", ratio)) to 1, \(readable ? "readable" : "low")")
    }
}
