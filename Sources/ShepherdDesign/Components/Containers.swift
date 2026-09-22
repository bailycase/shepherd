import SwiftUI

/// Section heading: 11/600 caps with an optional trailing count or accessory.
public struct SectionHeader<Trailing: View>: View {
    let title: String
    var small = false
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, small: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.small = small
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title).sectionStyle(small ? Fonts.sectionSmall : Fonts.section).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == Text? {
    public init(_ title: String, count: Int? = nil, small: Bool = false) {
        self.init(title, small: small) {
            count.map { Text("\($0)").font(Fonts.micro).foregroundStyle(Tokens.textMuted) }
        }
    }
}

/// A grouped card (settings groups, tool groups): bgSurface, border, radius 10, children
/// separated by borderSubtle hairlines. Pass rows; dividers are inserted between them.
public struct GroupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        _VariadicView.Tree(DividedStack()) { content() }
            .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Tokens.border, lineWidth: 1))
    }

    private struct DividedStack: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    if index > 0 { Tokens.borderSubtle.frame(height: 1) }
                    child
                }
            }
        }
    }
}

/// A settings row: title 13.5/500, description 12.5 tertiary, optional inline problem in
/// dangerText, control trailing. Min 52pt.
public struct CardRow<Control: View>: View {
    let title: String
    var description: String?
    var problem: String?
    @ViewBuilder let control: () -> Control

    public init(_ title: String, description: String? = nil, problem: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.problem = problem
        self.control = control
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Fonts.rowTitle).foregroundStyle(Tokens.text)
                if let description {
                    Text(description).font(Fonts.description).foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem).font(Fonts.description).foregroundStyle(Tokens.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.settingsRowMinHeight)
    }
}

/// InlineError banner: dangerBg, danger-tinted border, dangerText with an optional action.
public struct InlineError: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    public init(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tokens.danger)
            Text(text).font(Fonts.labelRegular).foregroundStyle(Tokens.dangerText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(LinkButtonStyle(color: Tokens.dangerText, font: Fonts.sans(13, .semibold)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Tokens.dangerBg, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.danger.opacity(0.35), lineWidth: 1))
    }
}

/// EmptyState: a title (optionally with a mono part) and one line of guidance, in a dashed
/// frame when `framed`.
public struct EmptyState: View {
    let title: Text
    let caption: String
    var framed = true

    public init(_ title: Text, caption: String, framed: Bool = true) {
        self.title = title
        self.caption = caption
        self.framed = framed
    }

    public var body: some View {
        VStack(spacing: 8) {
            title.font(Fonts.sans(15, .semibold)).foregroundStyle(Tokens.text)
            Text(caption).font(Fonts.labelRegular).foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .overlay {
            if framed {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(Tokens.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

extension View {
    /// Floating surfaces (menus, popovers, the palette): raised fill, strong border, the menu
    /// shadow.
    public func menuSurface(radius: CGFloat = Radius.xl) -> some View {
        self
            .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            .shadow(color: Tokens.menuShadow, radius: 14, y: 8)
    }

    /// Row chrome for list rows: hover and selection fills at the given radius.
    public func rowBackground(selected: Bool, hovering: Bool, radius: CGFloat = Radius.sm,
                              selectedFill: Color? = nil, hoverFill: Color? = nil) -> some View {
        background(
            (selected ? (selectedFill ?? Tokens.bgSelected) : hovering ? (hoverFill ?? Tokens.bgHoverStrong) : Color.clear),
            in: RoundedRectangle(cornerRadius: radius)
        )
    }
}

/// A hover-tracking row button (sidebar rows, palette rows, menu rows).
public struct RowButtonStyle: ButtonStyle {
    let selected: Bool
    let radius: CGFloat
    let selectedFill: Color?
    let hoverFill: Color?

    public init(selected: Bool = false, radius: CGFloat = Radius.sm, selectedFill: Color? = nil, hoverFill: Color? = nil) {
        self.selected = selected
        self.radius = radius
        self.selectedFill = selectedFill
        self.hoverFill = hoverFill
    }

    public func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, style: self)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let style: RowButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: style.radius))
                .rowBackground(selected: style.selected, hovering: hovering, radius: style.radius,
                               selectedFill: style.selectedFill, hoverFill: style.hoverFill)
                .onHover { hovering = $0 }
        }
    }
}
