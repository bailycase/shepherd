import SwiftUI

// MARK: Shared row chrome

/// A titled group of rows, drawn as one hairline-bordered block in
/// Shepherd's palette.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Fonts.mono(10.5, .semibold))
                .tracking(0.74)
                .foregroundStyle(Tokens.textTertiary)
            VStack(spacing: 0) {
                content
            }
            .background(Tokens.rowActiveHeader)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Tokens.chipBorder, lineWidth: 1)
            )
        }
    }
}

/// One row: label (+ optional explanation) on the left, its control trailing.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var isFirst = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle().fill(Tokens.separator).frame(height: 1)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Fonts.mono(12.5, .medium))
                        .foregroundStyle(Tokens.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Fonts.mono(11))
                            .foregroundStyle(Tokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Quiet mono footnote under a group — never a card, per DESIGN.md.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.mono(10.5))
            .foregroundStyle(Tokens.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

