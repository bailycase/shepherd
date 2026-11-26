import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A design system's page (DesignSystemPage and its eight sibling boards), for every system: a hero, the
// system's principles and voice when it has them, then Colors, Typography, Spacing, Corner radius, Size and
// Components as cards of read-only tables. A part the system has nothing for is left out. A contents button
// opens a menu of the parts and the designs using the system. Dark | Light switches the page's own
// appearance; each color's dark and light values sit side by side. Not drawn, on purpose: Edit, Add and a
// component's open icon.

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
    /// The component group shown; nil for all of them.
    @State private var group: String?

    /// Column widths, nil where the column takes what is left: the boards' name column is fixed.
    private static let nameAndRest: [CGFloat?] = [AppLayout.referenceNameColumn + SH.Space.xxl * 2, nil]
    private static let componentName: [CGFloat?] = [AppLayout.referenceComponentNameColumn + SH.Space.xxl * 2, nil]
    private static let valueShape: [CGFloat?] = [AppLayout.referenceNameColumn + SH.Space.xxl * 2, nil,
                                                 AppLayout.referenceShapeColumn + SH.Space.xxl * 2]
    private static let valueNote: [CGFloat?] = [AppLayout.referenceNameColumn + SH.Space.xxl * 2, nil,
                                                AppLayout.referenceNoteColumn + SH.Space.xxl * 2]

    private var scheme: ColorScheme { appearance ?? system }

    var body: some View {
        let _ = SHRenderProbe.tick("page.designSystemReference")
        VStack(spacing: 0) {
            header
            GeometryReader { area in
                ScrollViewReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView(.vertical) {
                            content
                                .frame(maxWidth: AppLayout.referenceColumnWidth)
                                .padding(.horizontal, SH.Space.xxxl)
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
        .background(Color.sh.bgWindow)
        .environment(\.colorScheme, scheme)
    }

    // MARK: Header

    /// The page's toolbar (DesignSystemPage): the name in 13 semibold with the Light | Dark switch after it, and in the
    /// raised capsule Contents, Re-sync where the system has a project to read again, New design and ⋯.
    private var header: some View {
        let M = SHDesignChrome.self
        return HStack(spacing: SH.Space.m) {
            if let showSidebar = chrome.showSidebar {
                Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar", shortcut: KeybindingsStore.shared.display(.toggleSidebar))
                    .accessibilityLabel("Show sidebar")
                    .padding(.trailing, SH.Space.l)
            }
            Text(reference.title)
                .font(.shSans(M.toolbarTextSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let status = model.status {
                Text(status.label)
                    .font(.shSans(M.toolbarTextSize))
                    .foregroundStyle(Color.sh.textTertiary)
                    .shShimmer(active: status.state == .running)
            }
            SHTweakSegmented("Appearance", selection: Binding(get: { scheme }, set: { appearance = $0 }),
                             options: [.init(ColorScheme.light, "Light"), .init(ColorScheme.dark, "Dark")])
                .padding(.leading, SH.Space.m)
            Spacer(minLength: SH.Space.l)
            SHToolbarCapsule {
                SHDesignToolbarChip("Contents", symbol: "chevron.down", isOn: menuOpen, symbolTrailing: true) { menuOpen.toggle() }
                    .shHelp("Contents")
                SHDesignCapsuleDivider()
                if model.canResync, let namespace = model.namespace {
                    SHDesignToolbarChip("Re-sync", symbol: "arrow.clockwise") { vm.resyncDesignSystem(namespace) }
                        .disabled(model.syncing)
                        .help("Read \(namespace)'s stylesheets again from its project")
                    SHDesignCapsuleDivider()
                }
                SHDesignToolbarChip("New design") { vm.openNewDesign(system: model.namespace) }
                if let namespace = model.namespace {
                    SHOptionsMenu("More for \(reference.title)") {
                        DesignMenuItems(menu: vm.designSystemMenu(.system(namespace))) { vm.performDesignSystemMenu($0, on: .system(namespace)) }
                    }
                    .shHelp("More for \(reference.title)")
                }
            }
        }
        .padding(.leading, (chrome.showSidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + chrome.leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding + SHDesignChrome.stageInset)
        .frame(height: SHToolbarMetrics.height)
        .padding(.top, AppLayout.toolbarTop)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    // MARK: Contents

    /// The contents menu: the parts, then the designs using the system. It is as tall as its content up to the
    /// room under its button, then scrolls, so the last of many designs is always reachable in a short window.
    private func contents(height: CGFloat, select: @escaping (DesignSystemReference.Part) -> Void) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            if menuOpen {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        ForEach(reference.parts) { part in
                            menuRow(part.title, count: reference.count(part), selected: part == current) {
                                current = part
                                select(part)
                            }
                        }
                        if !reference.used.isEmpty {
                            SHHairline().padding(.vertical, SH.Space.s).padding(.horizontal, SH.Space.m)
                            Text("Used by")
                                .font(.sh(.caption))
                                .foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.s)
                            ForEach(reference.used) { design in
                                menuRow(design.name, count: design.boards, selected: false) {
                                    menuOpen = false
                                    vm.openDesign(design.id)
                                }
                            }
                        }
                    }
                    .padding(SH.Space.s)
                }
                .scrollIndicators(.automatic)
                .frame(width: AppLayout.referenceMenuWidth)
                .frame(maxHeight: max(height - AppLayout.referenceMenuInset, SH.Height.row * 3))
                .fixedSize(horizontal: false, vertical: true)
                .shPopover(radius: SH.Radius.l, line: .sh.lineSubtle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .padding(.top, SH.Space.xs)
        .padding(.trailing, AppLayout.referenceMenuInset)
        .zIndex(1)
    }

    private func menuRow(_ title: String, count: Int?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Text(title).font(.shSans(SHDesignChrome.toolbarTextSize))
                    .foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let count { Text("\(count)").font(.shSans(SHDesignChrome.paneCountSize)).foregroundStyle(Color.sh.textTertiary) }
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: SH.Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected))
    }

    // MARK: Content

    /// One lazy column, one element per part, and each card's rows a lazy stack of their own: a system with
    /// hundreds of colors or components builds only the rows on screen.
    private var content: some View {
        let parts = Set(reference.parts)
        return LazyVStack(alignment: .leading, spacing: AppLayout.referencePartSpacing) {
            hero.id(DesignSystemReference.Part.overview.id)
            lead
            if parts.contains(.principles) { principles.id(DesignSystemReference.Part.principles.id) }
            if parts.contains(.voice) { voice.id(DesignSystemReference.Part.voice.id) }
            if parts.contains(.colors) { card("Colors", sub: reference.colorsSub, part: .colors) { colors } }
            if parts.contains(.typography) { card("Typography", sub: reference.typographySub, part: .typography) { typography } }
            if parts.contains(.spacing) { card("Spacing", sub: reference.spacingSub, part: .spacing) { spacing } }
            if parts.contains(.radius) { card("Corner radius", sub: reference.radiusSub, part: .radius) { radii } }
            if parts.contains(.size) { card("Size", sub: reference.sizeSub, part: .size) { sizes } }
            if parts.contains(.components) {
                card("Components", sub: reference.componentsSub, part: .components, accessory: { groups }) { components }
            }
        }
    }

    /// The hero (DesignSystemPage): a lifted card, the name in 28 bold with its tagline under it, at the foot; the art four
    /// columns of 38pt tiles 6pt apart, the first column one tall tile.
    private var hero: some View {
        let sh = Color.sh
        let tile = AppLayout.referenceHeroTile
        let gap = AppLayout.referenceHeroGap
        return HStack(alignment: .bottom, spacing: SH.Space.xxl) {
            VStack(alignment: .leading, spacing: SH.Space.xs + 2) {
                Text(reference.title)
                    .font(.shSans(AppLayout.referenceHeroNameSize, .bold))
                    .tracking(-AppLayout.referenceHeroNameSize * 0.02)
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
                if let tagline = reference.tagline {
                    Text(tagline).font(.shSans(SHDesignChrome.toolbarTextSize)).foregroundStyle(sh.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !reference.tiles.isEmpty {
                HStack(alignment: .top, spacing: gap) {
                    heroTile(0, bordered: false).frame(width: tile, height: tile * 2 + gap)
                    ForEach([[1, 2], [3, 4], [5, 6]], id: \.self) { pair in
                        VStack(spacing: gap) {
                            ForEach(pair, id: \.self) { index in heroTile(index, bordered: true).frame(width: tile, height: tile) }
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(AppLayout.referenceHeroPadding)
        .shCard(radius: SH.Radius.xxl, lift: true)
    }

    /// One of the hero's tiles, in the system's own color for the page's appearance; empty when it has none.
    @ViewBuilder
    private func heroTile(_ index: Int, bordered: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        if reference.tiles.indices.contains(index), let tile = reference.tiles[index] {
            shape.fill(Color(light: tile.light, dark: tile.dark))
                .overlay { shape.strokeBorder(Color.sh.lineSubtle) }
        } else {
            Color.clear
        }
    }

    /// The system's summary, then where it came from: its own words when it says, else what Shepherd knows.
    private var lead: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            if let summary = reference.summary {
                Text(summary).shText(.body).foregroundStyle(Color.sh.textPrimary)
            }
            Group {
                if let source = reference.source {
                    Text(source)
                } else {
                    DesignSystemContent.sourceLine(model.source)
                }
            }
            .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
    }

    private var principles: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            heading("Principles", sub: "\(reference.principles.count)")
            bullets(reference.principles.map { Text("\(Text($0.lead).fontWeight(.semibold).foregroundStyle(Color.sh.textPrimary)) \($0.text)") })
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            heading("Voice", sub: nil)
            if let lead = reference.voiceLead {
                Text(lead).shText(.body).foregroundStyle(Color.sh.textSecondary)
            }
            if !reference.examples.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { sayCell("Say", header: true); sayCell("Avoid", header: true, leading: true) }
                    ForEach(Array(reference.examples.enumerated()), id: \.offset) { _, example in
                        HStack(spacing: 0) { sayCell("“\(example.say)”"); sayCell("“\(example.avoid)”", leading: true) }
                    }
                }
                .shCard(radius: SH.Radius.xl, lift: true)
                .accessibilityElement(children: .contain)
            }
            bullets(reference.voiceRules.map { Text(verbatim: $0) })
        }
    }

    private func sayCell(_ text: String, header: Bool = false, leading: Bool = false) -> some View {
        Text(verbatim: text)
            .font(header ? .shSans(SHDesignChrome.paneCountSize) : .sh(.body))
            .foregroundStyle(header ? Color.sh.textTertiary : Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.xl).padding(.vertical, header ? SH.Space.m : SH.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .top) { if !header { SHHairline() } }
            .overlay(alignment: .leading) { if leading { SHHairline(.vertical) } }
    }

    private func bullets(_ items: [Text]) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Circle().fill(Color.sh.textPrimary).frame(width: SH.Space.s - SH.Space.xxs, height: SH.Space.s - SH.Space.xxs)
                        .accessibilityHidden(true)
                    item.shText(.body).foregroundStyle(Color.sh.textSecondary)
                }
            }
        }
    }

    // MARK: Cards and tables

    /// A section's heading (18 semibold, its sub line in 13 `textTertiary`) over what it holds.
    private func heading(_ title: String, sub: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m + 2) {
            Text(title).font(.shSans(SHDesignChrome.systemHeadingSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
            if let sub { Text(sub).font(.shSans(SHDesignChrome.toolbarTextSize)).foregroundStyle(Color.sh.textTertiary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// A part: its heading (with an accessory at the trailing end), then its table in a lifted card.
    private func card<Body: View, Accessory: View>(_ title: String, sub: String, part: DesignSystemReference.Part,
                                                    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
                                                    @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                heading(title, sub: sub)
                Spacer(minLength: SH.Space.m)
                accessory()
            }
            body()
                .shCard(radius: SH.Radius.xl, lift: true)
        }
        .id(part.id)
    }

    private func header(_ titles: [String], widths: [CGFloat?] = []) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Text(title).font(.shSans(SHDesignChrome.paneCountSize)).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                    .frame(width: widths.indices.contains(index) ? widths[index] : nil, alignment: .leading)
                    .frame(maxWidth: widths.indices.contains(index) && widths[index] != nil ? nil : .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func row(_ cells: [AnyView], widths: [CGFloat?] = []) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                cell
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                    .frame(width: widths.indices.contains(index) ? widths[index] : nil, alignment: .leading)
                    .frame(maxWidth: widths.indices.contains(index) && widths[index] != nil ? nil : .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func name(_ text: String) -> AnyView {
        AnyView(Text(text).font(.shMono(SHDesignChrome.toolbarTextSize)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
            .frame(minHeight: SH.Height.controlM))
    }

    private func groupHeader(_ title: String, count: Int, hint: String? = nil) -> some View {
        HStack(spacing: SH.Space.s) {
            Text(title).font(.shSans(SHDesignChrome.toolbarTextSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
            if let hint { Text(hint).font(.shSans(SHDesignChrome.paneCountSize)).foregroundStyle(Color.sh.textTertiary).padding(.leading, SH.Space.xs) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SH.Space.xl).padding(.top, SH.Space.l).padding(.bottom, SH.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Colors

    /// Name | Dark | Light, or Name | Value for a system with no dark values.
    private var colors: some View {
        let paired = reference.colors.contains { $0.rows.contains { $0.dark != $0.light } }
        return LazyVStack(spacing: 0) {
            ForEach(reference.colors) { group in
                if !group.title.isEmpty { groupHeader(group.title, count: group.rows.count, hint: group.hint) }
                header(paired ? ["Name", "Dark", "Light"] : ["Name", "Value"])
                ForEach(group.rows) { color in
                    ReferenceColorRow(color: color, paired: paired)
                }
            }
        }
    }

    // MARK: Typography

    private var typography: some View {
        LazyVStack(spacing: 0) {
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
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text(style.sample)
                .font(Self.font(style))
                .tracking(style.uppercase ? CGFloat(style.size) * 0.04 : 0)
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            Text(style.tag).font(.shSans(SHDesignChrome.paneCountSize)).foregroundStyle(Color.sh.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A style's sample in its own face at its size and weight (Shepherd's Geist faces by their tokens), at
    /// most the page's largest specimen size.
    static func font(_ style: DesignSystemReference.TypeRow) -> Font {
        let size = CGFloat(min(max(style.size, 1), AppLayout.designSystemSpecimenMaxSize))
        let weight = DesignSystemContent.weight(style.weight)
        switch style.family {
        case SHFonts.sansFamily?: return .shSans(size, weight)
        case SHFonts.monoFamily?: return .shMono(size, weight)
        case let family?: return Font.custom(family, size: size).weight(weight)
        case nil: return .shSans(size, weight)
        }
    }

    // MARK: Spacing, radius, size

    private var spacing: some View {
        LazyVStack(spacing: 0) {
            header(["Name", "Value", "Shape"], widths: Self.valueShape)
            ForEach(reference.spacing) { step in
                row([name(step.name), AnyView(ValueChip(value: DesignSystemReference.number(step.px), unit: "px")
                        .frame(width: AppLayout.referenceValueChipWidth)),
                     AnyView(RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color.sh.running)
                        .frame(width: min(step.px * AppLayout.referenceBarScale, AppLayout.referenceShapeColumn), height: SH.Space.m)
                        .frame(minHeight: SH.Height.controlM).accessibilityHidden(true))], widths: Self.valueShape)
            }
        }
    }

    private var radii: some View {
        LazyVStack(spacing: 0) {
            header(["Name", "Value", "Shape"], widths: Self.valueShape)
            ForEach(reference.radii) { step in
                row([name(step.name),
                     AnyView(HStack(spacing: SH.Space.m) {
                         ValueChip(value: DesignSystemReference.number(step.px), unit: "px")
                             .frame(width: AppLayout.referenceValueChipWidth)
                         if !step.use.isEmpty { Text(step.use).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary) }
                     }),
                     AnyView(RoundedRectangle(cornerRadius: step.px).fill(Color.sh.bgSunken)
                        .overlay { RoundedRectangle(cornerRadius: step.px).strokeBorder(Color.sh.lineStrong) }
                        .frame(width: AppLayout.referenceRadiusSample.width, height: AppLayout.referenceRadiusSample.height)
                        .accessibilityHidden(true))], widths: Self.valueShape)
            }
        }
    }

    private var sizes: some View {
        LazyVStack(spacing: 0) {
            header(["Name", "Value", "Used for"], widths: Self.valueNote)
            ForEach(reference.sizes) { size in
                row([name(size.name), AnyView(ValueChip(value: size.value)),
                     AnyView(Text(size.use).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                        .frame(minHeight: SH.Height.controlM, alignment: .leading))], widths: Self.valueNote)
            }
        }
    }

    // MARK: Components

    /// The group popup, when the system groups its components (`group` on each): a popup of one group filters nothing.
    @ViewBuilder
    private var groups: some View {
        if reference.componentGroups.count > 1 {
            SHPopupMenu(group ?? Self.allGroups) {
                Button(Self.allGroups) { group = nil }
                ForEach(reference.componentGroups, id: \.self) { name in
                    Button(name) { group = name }
                }
            }
            .help("Component group")
        }
    }

    static let allGroups = "All groups"

    private var components: some View {
        let shown = reference.components.filter { group == nil || $0.group == group }
        return LazyVStack(spacing: 0) {
            header(["Name", "Preview"], widths: Self.componentName)
            ForEach(shown) { component in
                row([AnyView(VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(component.name).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                    if let export = component.export {
                        Text(export).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                    }
                }), AnyView(ReferenceSpecimen(namespace: reference.namespace, component: component.id,
                                              specimens: vm.designRendering.specimens)
                    // A specimen is a picture of the component: it takes no press and is one element to VoiceOver.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(component.name) specimen")
                    .padding(.vertical, SH.Space.m))], widths: Self.componentName)
            }
            if let note = reference.componentsShown {
                Text(note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SH.Space.xxl).padding(.vertical, SH.Space.l)
                    // Its own element: the list's last row is read as itself, not folded into the card.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note)
            }
        }
    }
}

/// A color's row: its name and each value as a chip, a text color with its contrast.
private struct ReferenceColorRow: View {
    let color: DesignSystemReference.ColorRow
    let paired: Bool

    var body: some View {
        let _ = SHRenderProbe.tick("design.referenceColor")
        HStack(spacing: 0) {
            Text(color.name).font(.shMono(SHDesignChrome.toolbarTextSize)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                .frame(minHeight: SH.Height.controlM)
                .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            if paired {
                cell(ValueChip(value: color.dark, ratio: color.darkRatio))
                cell(ValueChip(value: color.light, ratio: color.lightRatio))
            } else {
                cell(ValueChip(value: color.light, ratio: color.lightRatio))
            }
        }
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func cell(_ chip: ValueChip) -> some View {
        chip
            .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A component's specimen as the board renderer drew it from the system's own file, once its image lands.
private struct ReferenceSpecimen: View {
    let namespace: String
    let component: Int
    let specimens: DesignSpecimens

    var body: some View {
        let _ = specimens.version
        let size = DesignSpecimenBoard.size
        ZStack {
            if let image = specimens.image(namespace, component) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.sh.bgSunken)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: SH.Radius.s).strokeBorder(Color.sh.lineSubtle) }
    }
}

/// A token's value as the boards draw it: a 28pt row with a swatch (in the value's own color) when the value is
/// a color, the value in mono, and for text a contrast ratio in 12 `textTertiary`.
private struct ValueChip: View {
    let value: String
    var unit: String?
    var ratio: Double?

    var body: some View {
        HStack(spacing: SH.Space.m) {
            if let hex = DesignSystemPresentation.hex(value) {
                RoundedRectangle(cornerRadius: SH.Radius.xs).fill(Color(light: hex, dark: hex))
                    .overlay { RoundedRectangle(cornerRadius: SH.Radius.xs).strokeBorder(Color.sh.lineStrong) }
                    .frame(width: SH.Space.xl, height: SH.Space.xl)
                    .accessibilityHidden(true)
            }
            Text(value.uppercased() == value || DesignSystemPresentation.hex(value) == nil ? value : value.uppercased())
                .font(.shMono(SHDesignChrome.toolbarTextSize)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: SH.Space.m)
            if let unit { Text(unit).font(.shSans(SHDesignChrome.paneCountSize)).foregroundStyle(Color.sh.textTertiary) }
            if let ratio { contrast(ratio) }
        }
        .frame(height: SH.Height.controlM)
        .accessibilityElement(children: .combine)
    }

    private func contrast(_ ratio: Double) -> some View {
        let readable = ratio >= DesignSystemReference.readable
        return HStack(spacing: SH.Space.xxs) {
            Image(systemName: readable ? "checkmark" : "exclamationmark.triangle").accessibilityHidden(true)
            Text(String(format: "%.1f:1", ratio))
        }
        .font(.shSans(SHDesignChrome.paneCountSize))
        .foregroundStyle(readable ? Color.sh.textTertiary : Color.sh.lanternText)
        .accessibilityLabel("Contrast \(String(format: "%.1f", ratio)) to 1, \(readable ? "readable" : "low")")
    }
}
