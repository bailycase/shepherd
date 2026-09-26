import SwiftUI

/// Text field chrome (Controls board): 28pt, radius 6, raised fill, 1px strong line; a
/// running-blue ring while focused, a failed line in error, 40% when disabled.
/// `.textFieldStyle(.nw)` tracks focus itself; a field whose focus the caller already binds uses
/// `.nwField(focused:)` instead.
public struct NWTextFieldStyle: TextFieldStyle {
    let mono: Bool
    let error: Bool

    public init(mono: Bool = false, error: Bool = false) {
        self.mono = mono
        self.error = error
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        NWSelfFocusingField(mono: mono, error: error, search: false) { configuration }
    }
}

extension TextFieldStyle where Self == NWTextFieldStyle {
    public static var nw: NWTextFieldStyle { NWTextFieldStyle() }
    public static func nw(mono: Bool = false, error: Bool = false) -> NWTextFieldStyle { NWTextFieldStyle(mono: mono, error: error) }
}

/// The search field chrome: the field chrome plus a leading magnifying glass.
public struct NWSearchFieldStyle: TextFieldStyle {
    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        NWSelfFocusingField(mono: false, error: false, search: true) { configuration }
    }
}

extension TextFieldStyle where Self == NWSearchFieldStyle {
    public static var nwSearch: NWSearchFieldStyle { NWSearchFieldStyle() }
}

private struct NWSelfFocusingField<Field: View>: View {
    let mono: Bool
    let error: Bool
    let search: Bool
    @ViewBuilder let field: () -> Field
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: NW.Space.s) {
            if search { NWSearchGlyph() }
            field().focused($focused)
        }
        .nwFieldChrome(focused: focused, error: error, mono: mono)
    }
}

extension View {
    /// The field chrome for a `TextField` whose focus the caller tracks.
    public func nwField(focused: Bool = false, error: Bool = false, mono: Bool = false) -> some View {
        textFieldStyle(.plain).nwFieldChrome(focused: focused, error: error, mono: mono)
    }

    /// A field's own value refused (Controls board: "Socket path already in use"): the message
    /// 6pt under the field in `caption` `failed`, beside the field's `error` line. A problem with
    /// a whole setting stays its row's problem line instead. Nil shows nothing. `alignment` lines
    /// it up with a field that ends a row (Settings) rather than one that starts it.
    public func nwFieldMessage(_ message: String?, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: NW.Space.s) {
            self
            if let message {
                Text(message)
                    .font(.nw(.caption))
                    .foregroundStyle(.nw.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .nwTransition(.disclosure)
            }
        }
        .nwAnimation(.disclosure, value: message)
    }

    fileprivate func nwFieldChrome(focused: Bool, error: Bool, mono: Bool, search: Bool = false) -> some View {
        modifier(NWFieldChrome(focused: focused, error: error, mono: mono, search: search))
    }
}

private struct NWFieldChrome: ViewModifier {
    let focused: Bool
    let error: Bool
    let mono: Bool
    var search = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nwControlScale) private var scale

    func body(content: Content) -> some View {
        let nw = Color.nw
        // The Settings boards' fields: 30pt at radius 7, 10pt in, 12.5 whether mono or not; their
        // search field is 34pt at radius 8 in Geist 13.
        let settings = scale == .settings
        let M = NWSettingsControlMetrics.self
        let radius = settings ? (search ? M.segmentTrackRadius : M.radius) : NW.Radius.s
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .textFieldStyle(.plain)
            .font(settings ? (mono ? .nwMono(M.fieldTextSize) : .nwSans(search ? M.textSize : M.fieldTextSize))
                  : mono ? .nwMono(12) : .nwSans(12.5))
            .foregroundStyle(nw.textPrimary)
            .tint(nw.lantern)
            .padding(.horizontal, settings ? M.fieldPadding : NW.Space.m)
            .padding(.vertical, NW.Space.xs)
            .frame(minHeight: settings ? (search ? M.controlHeight + 2 : M.fieldHeight) : NW.Height.controlM)
            .background(nw.bgRaised, in: shape)
            .overlay {
                // The line and the ring fade on their own layer, so focusing a field or
                // flagging it never animates the text inside.
                Color.clear
                    .nwBorder(error ? nw.failed : nw.lineStrong, radius: radius)
                    .nwFocusRing(focused, radius: radius)
                    .nwComponentAnimation(.hover, value: focused)
                    .nwComponentAnimation(.hover, value: error)
                    .allowsHitTesting(false)
            }
            .nwEnabledOpacity(enabled)
    }
}

private struct NWSearchGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: size - 1, weight: .medium))
            .foregroundStyle(.nw.textTertiary)
            .accessibilityHidden(true)
    }
}

/// A search field with a leading glass, a clear button once there is text, and an optional
/// shortcut hint while empty. `large` is the command palette's 56pt search row (no chrome).
public struct NWSearchField: View {
    let placeholder: String
    @Binding var text: String
    let shortcut: String?
    let large: Bool
    @FocusState private var focused: Bool
    @Environment(\.nwControlScale) private var scale

    public init(_ placeholder: String, text: Binding<String>, shortcut: String? = nil, large: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.shortcut = shortcut
        self.large = large
    }

    public var body: some View {
        let settings = scale == .settings && !large
        let row = HStack(spacing: large || settings ? NW.Space.m : NW.Space.s) {
            NWSearchGlyph(size: large ? 16 : 13)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(large ? .nwSans(16) : .nwSans(settings ? NWSettingsControlMetrics.textSize : 12.5))
                .foregroundStyle(.nw.textPrimary)
                .tint(.nw.lantern)
                .focused($focused)
            if text.isEmpty {
                if let shortcut {
                    // The Settings boards write the hint as plain mono text ("⌘F").
                    if settings {
                        Text(shortcut).font(.nwMono(11)).foregroundStyle(.nw.textTertiary).accessibilityHidden(true)
                    } else {
                        NWKeycap(shortcut)
                    }
                }
            } else if !large {
                Button { text = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.nw.textTertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        if large {
            row.padding(.horizontal, NW.Space.xl).frame(height: 56)
        } else {
            row.nwFieldChrome(focused: focused, error: false, mono: false, search: true)
        }
    }
}
