import SwiftUI

#if os(macOS)
/// The Mac's error card (GXError, GXErrorDetails): a raised 14pt card, 12pt above and 14pt at the
/// sides, a bare glyph then the words; Details opens a 200pt column of facts beside the raw body,
/// 26pt in from the card's edge.
enum SHTurnErrorMacMetrics {
    static let vertical: CGFloat = SH.Space.l
    static let horizontal: CGFloat = 14
    static let glyph: CGFloat = 14
    static let glyphTop: CGFloat = 1
    static let glyphGap: CGFloat = 10
    static let messageTop: CGFloat = 6
    /// The message's 19pt lines under 13pt text.
    static let messageSpacing: CGFloat = 3
    static let factsTop: CGFloat = 7
    static let actionsTop: CGFloat = 12
    static let actionGap: CGFloat = 14
    static let actionSize: CGFloat = 12.5
    static let detailsTop: CGFloat = 12
    static let detailsIndent: CGFloat = 26
    static let detailsGap: CGFloat = SH.Space.xl
    /// The facts column: 200pt, growing to fit a value (the board lets one run into the gap) up to 260pt.
    static let factsWidth: CGFloat = 200
    static let factsMaxWidth: CGFloat = 260
    static let factLabelWidth: CGFloat = 70
    static let factRowGap: CGFloat = 5
    static let bodyMaxHeight: CGFloat = 200
    static let bodyVertical: CGFloat = SH.Space.m
    static let bodyHorizontal: CGFloat = SH.Space.l
    /// The body's 19pt lines under 12pt mono.
    static let bodySpacing: CGFloat = 4
}

extension SHTurnError {
    // MARK: Folded

    /// An earlier error as one line like a tool row: the glyph in `failed`, the title in
    /// `textSecondary`, "401, 5:52 PM" after it, and a chevron.
    var macFoldedLine: some View {
        let sh = Color.sh
        return Button {
            if let unfoldState { unfoldState.wrappedValue = true } else { ownOpened = true }
        } label: {
            HStack(spacing: SH.Space.m) {
                Image(systemName: content.glyph).font(.system(size: SHTurnErrorMetrics.lineGlyph - 1, weight: .medium))
                    .foregroundStyle(sh.failed)
                    .frame(width: SHTurnErrorMetrics.lineGlyph, height: SHTurnErrorMetrics.lineGlyph)
                Text(content.title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                if !content.foldedMeta.isEmpty {
                    Text(content.foldedMeta).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(.system(size: SHThreadMetrics.chevron - 1, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
            }
            .frame(minHeight: SHTurnErrorMetrics.foldedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shHelp("Show the error")
        .accessibilityLabel("\(content.title), \(content.foldedMeta)")
        .accessibilityHint("Shows the error")
    }

    // MARK: Card

    var macCard: some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SHTurnErrorMacMetrics.glyphGap) {
                Image(systemName: content.glyph)
                    .font(.system(size: SHTurnErrorMacMetrics.glyph, weight: .medium))
                    .foregroundStyle(sh.failed)
                    .padding(.top, SHTurnErrorMacMetrics.glyphTop)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    macTitleRow
                    macMessage.padding(.top, SHTurnErrorMacMetrics.messageTop)
                    macFacts.padding(.top, SHTurnErrorMacMetrics.factsTop)
                    macActions.padding(.top, SHTurnErrorMacMetrics.actionsTop)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if detailsOpen {
                macDetails
                    .shTransition(.content)
            }
        }
        .padding(.vertical, SHTurnErrorMacMetrics.vertical)
        .padding(.horizontal, SHTurnErrorMacMetrics.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.xl, lift: true)
        .shAnimation(.content, value: detailsOpen)
        .accessibilityElement(children: .contain)
    }

    private var macTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Text(content.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let time = content.time {
                Text(time).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize()
            }
        }
    }

    /// The provider's words in `textSecondary`: code spans in mono, links in `textPrimary` underlined.
    private var macMessage: some View {
        let sh = Color.sh
        var text = Text(verbatim: "")
        for span in content.message {
            switch span {
            case .text(let value):
                text = Text("\(text)\(Text(verbatim: value))")
            case .code(let value):
                text = Text("\(text)\(Text(verbatim: value).font(.sh(.mono)))")
            case .link(let display, let url):
                var link = AttributedString(display)
                link.link = URL(string: url)
                link.underlineStyle = .single
                text = Text("\(text)\(Text(link).foregroundStyle(sh.textPrimary))")
            }
        }
        return text
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(sh.textSecondary)
            .lineSpacing(SHTurnErrorMacMetrics.messageSpacing)
            .tint(sh.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "401, authentication_error, gpt-5 on OpenAI": the status and type in mono, then where it
    /// came from, in `textTertiary`; "· Tried 3 times over 31m" after it.
    @ViewBuilder private var macFacts: some View {
        if let line = macFactsLine {
            line.font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var macFactsLine: Text? {
        let source = content.source ?? ""
        guard !content.chips.isEmpty || !source.isEmpty || content.tries != nil else { return nil }
        var line = Text(verbatim: "")
        for (index, chip) in content.chips.enumerated() {
            line = Text("\(line)\(Text(verbatim: index == 0 ? "" : ", "))\(Text(verbatim: chip).font(.sh(.mono)))")
        }
        if !source.isEmpty { line = Text("\(line)\(Text(verbatim: (content.chips.isEmpty ? "" : ", ") + source))") }
        if let tries = content.tries {
            line = Text("\(line)\(Text(verbatim: (content.chips.isEmpty && source.isEmpty ? "" : " · ") + tries))")
        }
        return line
    }

    private var macActions: some View {
        let sh = Color.sh
        return HStack(spacing: SHTurnErrorMacMetrics.actionGap) {
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(SHTurnErrorLinkStyle())
                    .shHelp("Retry this turn")
                    .shTransition(.content)
            }
            if let signIn {
                Button("Sign in again", action: signIn)
                    .buttonStyle(SHTurnErrorLinkStyle())
                    .shHelp("The provider's sign-in no longer works: sign in to it again")
                    .shTransition(.content)
            }
            Button {
                SHPasteboard.copy(content.copyText)
                copied = true
                copies += 1
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                // Drawn 12pt; pressed over the Mac's 24pt, taking back the room its frame adds.
                SHCopyGlyph(copied: copied, copies: copies).foregroundStyle(sh.textSecondary)
                    .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                    .contentShape(Rectangle())
                    .padding(.horizontal, -SH.Space.s)
            }
                .buttonStyle(.plain)
                .shHelp("Copy the error")
                .accessibilityLabel(copied ? "Copied" : "Copy error")
            Spacer(minLength: 0)
            Button {
                toggleDetails()
            } label: {
                HStack(spacing: SH.Space.xs) {
                    Text("Details").font(.shSans(SHTurnErrorMacMetrics.actionSize)).foregroundStyle(sh.textSecondary)
                    SHTurningChevron(isOpen: detailsOpen)
                        .font(.system(size: SHThreadMetrics.chevron - 1, weight: .semibold))
                        .foregroundStyle(sh.textSecondary)
                        .frame(width: SHThreadMetrics.chevron)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shHelp("Everything the provider sent back")
            .accessibilityLabel(detailsOpen ? "Hide details" : "Show details")
        }
        .shAnimation(.content, value: retry != nil)
    }

    // MARK: Details

    private var macDetails: some View {
        HStack(alignment: .top, spacing: SHTurnErrorMacMetrics.detailsGap) {
            macFactGrid.frame(minWidth: SHTurnErrorMacMetrics.factsWidth, maxWidth: SHTurnErrorMacMetrics.factsMaxWidth, alignment: .leading)
            if !content.body.isEmpty { macRawBody }
        }
        .padding(.top, SHTurnErrorMacMetrics.vertical)
        .overlay(alignment: .top) { SHHairline() }
        .padding(.top, SHTurnErrorMacMetrics.detailsTop)
        .padding(.leading, SHTurnErrorMacMetrics.detailsIndent)
    }

    private var macFactGrid: some View {
        let sh = Color.sh
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: SHTurnErrorMacMetrics.factRowGap) {
            ForEach(Array(content.facts.enumerated()), id: \.offset) { _, fact in
                GridRow {
                    Text(fact.label).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                        .frame(width: SHTurnErrorMacMetrics.factLabelWidth, alignment: .leading)
                    Text(fact.value)
                        .font(fact.mono ? .sh(.mono) : .sh(.caption))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(fact.value)
                }
            }
        }
    }

    /// Everything the provider sent back, pretty-printed, in mono on `bgHover`; 200pt tall at
    /// most, as the board clips it (Copy has all of it).
    private var macRawBody: some View {
        let sh = Color.sh
        var text = AttributedString()
        for token in content.body {
            switch token {
            case .plain(let value), .key(let value), .string(let value):
                text += AttributedString(value)
            case .redacted(let value):
                var part = AttributedString(value)
                part.backgroundColor = sh.bgSelected
                text += part
            case .link(let value):
                var part = AttributedString(value)
                part.underlineStyle = .single
                text += part
            }
        }
        let body = Text(text)
            .font(.sh(.mono))
            .foregroundStyle(sh.textSecondary)
            .lineSpacing(SHTurnErrorMacMetrics.bodySpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, SHTurnErrorMacMetrics.bodyVertical)
            .padding(.horizontal, SHTurnErrorMacMetrics.bodyHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        return body
            .frame(maxHeight: SHTurnErrorMacMetrics.bodyMaxHeight, alignment: .top)
            .clipped()
            .background(sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.m))
    }
}

/// Retry and Sign in again: words in `textPrimary`, medium, never a button's box.
private struct SHTurnErrorLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.shSans(SHTurnErrorMacMetrics.actionSize, .medium))
            .foregroundStyle(Color.sh.textPrimary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            // A taller press area than the words, without taller layout.
            .padding(.vertical, SH.Space.xs)
            .contentShape(Rectangle())
            .padding(.vertical, -SH.Space.xs)
    }
}
#endif
