import SwiftUI

/// Text field chrome (Controls board): 28pt, radius 6, raised fill, 1px strong line; a
/// running-blue ring while focused, a failed line in error, 40% when disabled.
/// `.textFieldStyle(.sh)` tracks focus itself; a field whose focus the caller already binds uses
/// `.shField(focused:)` instead.
public struct SHTextFieldStyle: TextFieldStyle {
    let mono: Bool
    let error: Bool

    public init(mono: Bool = false, error: Bool = false) {
        self.mono = mono
        self.error = error
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        SHSelfFocusingField(mono: mono, error: error, search: false) { configuration }
    }
}

extension TextFieldStyle where Self == SHTextFieldStyle {
    public static var sh: SHTextFieldStyle { SHTextFieldStyle() }
    public static func sh(mono: Bool = false, error: Bool = false) -> SHTextFieldStyle { SHTextFieldStyle(mono: mono, error: error) }
}

/// The search field chrome: the field chrome plus a leading magnifying glass.
public struct SHSearchFieldStyle: TextFieldStyle {
    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        SHSelfFocusingField(mono: false, error: false, search: true) { configuration }
    }
}

extension TextFieldStyle where Self == SHSearchFieldStyle {
    public static var shSearch: SHSearchFieldStyle { SHSearchFieldStyle() }
}

private struct SHSelfFocusingField<Field: View>: View {
    let mono: Bool
    let error: Bool
    let search: Bool
    @ViewBuilder let field: () -> Field
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: SH.Space.s) {
            if search { SHSearchGlyph() }
            field().focused($focused)
        }
        .shFieldChrome(focused: focused, error: error, mono: mono)
    }
}

extension View {
    /// The field chrome for a `TextField` whose focus the caller tracks.
    public func shField(focused: Bool = false, error: Bool = false, mono: Bool = false) -> some View {
        textFieldStyle(.plain).shFieldChrome(focused: focused, error: error, mono: mono)
    }

    /// A field's own value refused (Controls board: "Socket path already in use"): the message
    /// 6pt under the field in `caption` `failed`, beside the field's `error` line. A problem with
    /// a whole setting stays its row's problem line instead. Nil shows nothing. `alignment` lines
    /// it up with a field that ends a row (Settings) rather than one that starts it.
    public func shFieldMessage(_ message: String?, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: SH.Space.s) {
            self
            if let message {
                Text(message)
                    .font(.sh(.caption))
                    .foregroundStyle(.sh.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .shTransition(.disclosure)
            }
        }
        .shAnimation(.disclosure, value: message)
    }

    fileprivate func shFieldChrome(focused: Bool, error: Bool, mono: Bool, search: Bool = false) -> some View {
        modifier(SHFieldChrome(focused: focused, error: error, mono: mono, search: search))
    }
}

private struct SHFieldChrome: ViewModifier {
    let focused: Bool
    let error: Bool
    let mono: Bool
    var search = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.shControlScale) private var scale

    func body(content: Content) -> some View {
        let sh = Color.sh
        // The Settings boards' fields: 30pt at radius 7, 10pt in, 12.5 whether mono or not; their
        // search field is 34pt at radius 8 in Geist 13.
        let settings = scale == .settings
        let M = SHSettingsControlMetrics.self
        let radius = settings ? (search ? M.segmentTrackRadius : M.radius) : SH.Radius.s
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .textFieldStyle(.plain)
            .font(settings ? (mono ? .shMono(M.fieldTextSize) : .shSans(search ? M.textSize : M.fieldTextSize))
                  : mono ? .shMono(12) : .shSans(12.5))
            .foregroundStyle(sh.textPrimary)
            .tint(sh.lantern)
            .padding(.horizontal, settings ? M.fieldPadding : SH.Space.m)
            .padding(.vertical, SH.Space.xs)
            .frame(minHeight: settings ? (search ? M.controlHeight + 2 : M.fieldHeight) : SH.Height.controlM)
            .background(sh.bgRaised, in: shape)
            .overlay {
                // The line and the ring fade on their own layer, so focusing a field or
                // flagging it never animates the text inside.
                Color.clear
                    .shBorder(error ? sh.failed : sh.lineStrong, radius: radius)
                    .shFocusRing(focused, radius: radius)
                    .shComponentAnimation(.hover, value: focused)
                    .shComponentAnimation(.hover, value: error)
                    .allowsHitTesting(false)
            }
            .shEnabledOpacity(enabled)
    }
}

private struct SHSearchGlyph: View {
    var size: CGFloat = 13
    @Environment(\.shControlScale) private var scale

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: size - 1, weight: .medium))
            .foregroundStyle(scale == .settings ? Color.sh.settingsMuted : Color.sh.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A search field with a leading glass, a clear button once there is text, and an optional
/// shortcut hint while empty. `large` is the command palette's 56pt search row (no chrome).
public struct SHSearchField: View {
    let placeholder: String
    @Binding var text: String
    let shortcut: String?
    let large: Bool
    @FocusState private var focused: Bool
    @Environment(\.shControlScale) private var scale

    public init(_ placeholder: String, text: Binding<String>, shortcut: String? = nil, large: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.shortcut = shortcut
        self.large = large
    }

    public var body: some View {
        let settings = scale == .settings && !large
        let row = HStack(spacing: large || settings ? SH.Space.m : SH.Space.s) {
            SHSearchGlyph(size: large ? 16 : 13)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(settings ? Color.sh.settingsMuted : Color.sh.textTertiary))
                .textFieldStyle(.plain)
                .accessibilityLabel(placeholder)
                .font(large ? .shSans(16) : .shSans(settings ? SHSettingsControlMetrics.textSize : 12.5))
                .foregroundStyle(.sh.textPrimary)
                .tint(.sh.lantern)
                .focused($focused)
            if text.isEmpty {
                if let shortcut {
                    // The Settings boards write the hint as plain mono text ("⌘F").
                    if settings {
                        Text(shortcut).font(.shMono(11)).foregroundStyle(.sh.textTertiary).accessibilityHidden(true)
                    } else {
                        SHKeycap(shortcut)
                    }
                }
            } else if !large {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.sh.textTertiary)
                        .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        if large {
            row.padding(.horizontal, SH.Space.xl).frame(height: 56)
        } else {
            row.shFieldChrome(focused: focused, error: false, mono: false, search: true)
        }
    }
}
