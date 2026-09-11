import SwiftUI
import ShepherdProtocol

struct ThreadMessageView: View {
    let message: NativeThreadMessage
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        VStack(alignment: .leading, spacing: MobileTokens.spacing) {
            if message.toolName != nil || message.role == "toolResult" {
                tool(tokens)
            } else if message.role == "user" {
                blocks
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tokens.raised, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
                    .accessibilityElement(children: .contain)
            } else {
                if message.role != "assistant" {
                    Text(message.role.replacingOccurrences(of: "_", with: " "))
                        .font(MobileTokens.caption)
                        .foregroundStyle(tokens.secondary)
                }
                blocks
            }
            if message.truncated {
                Text("output truncated · full content on your Mac")
                    .font(MobileTokens.caption)
                    .foregroundStyle(tokens.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tool(_ tokens: MobileTokens) -> some View {
        let name = message.toolName ?? "result"
        let failed = message.isError == true
        return Collapsible(label: "Tool \(name)\(failed ? ", error" : "")") {
            HStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    .foregroundStyle(failed ? tokens.danger : tokens.secondary)
                Text(name).foregroundStyle(tokens.primary)
                if let status = message.status, status != "complete" || failed {
                    Text(failed ? "error" : status).foregroundStyle(failed ? tokens.danger : tokens.secondary)
                }
            }
        } content: {
            if let arguments = message.argumentsText { CodeBlock(text: arguments) }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                if block.kind == .unsupportedImage { imagePlaceholder(tokens) } else { CodeBlock(text: block.text) }
            }
        }
    }

    @ViewBuilder private var blocks: some View {
        let tokens = MobileTokens(scheme: scheme)
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
            switch block.kind {
            case .text: MarkdownText(text: block.text)
            case .thinking:
                Collapsible(label: "thinking") {
                    Label("thinking", systemImage: "brain").foregroundStyle(tokens.secondary)
                } content: {
                    Text(block.text)
                        .font(MobileTokens.caption)
                        .foregroundStyle(tokens.secondary)
                        .textSelection(.enabled)
                }
            case .unsupportedImage: imagePlaceholder(tokens)
            }
        }
    }

    private func imagePlaceholder(_ tokens: MobileTokens) -> some View {
        Label("image · view on your Mac", systemImage: "photo")
            .font(MobileTokens.caption)
            .foregroundStyle(tokens.secondary)
    }
}

// Collapsed by default; DisclosureGroup keeps phantom height inside a LazyVStack, so this is explicit.
struct Collapsible<Label: View, Content: View>: View {
    let label: String
    @ViewBuilder let header: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(label: String, @ViewBuilder header: @escaping () -> Label, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTokens.spacing) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack {
                    header()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(MobileTokens(scheme: scheme).secondary)
                }
                .font(MobileTokens.caption)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { content() }
        }
    }
}

// Fenced code renders as mono blocks; everything else is inline Markdown prose with headings.
struct MarkdownText: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    private var segments: [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var code = false
        var buffer: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let body = buffer.joined(separator: "\n")
                if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append((code, body)) }
                buffer = []
                code.toggle()
            } else {
                buffer.append(String(line))
            }
        }
        let body = buffer.joined(separator: "\n")
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append((code, body)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTokens.spacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    CodeBlock(text: segment.text)
                } else {
                    ForEach(Array(segment.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("#") {
                            Text(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                                .font(MobileTokens.heading)
                        } else if !trimmed.isEmpty {
                            // Inline-only Markdown keeps line breaks but not list syntax; swap the marker for a bullet.
                            let listed = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                                .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? "•  " + $0.dropFirst(2) : $0 }
                                .joined(separator: "\n")
                            Text((try? AttributedString(markdown: listed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                 ?? AttributedString(listed))
                                .font(MobileTokens.prose)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .tint(MobileTokens(scheme: scheme).accent)
    }
}

struct CodeBlock: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.trimmingCharacters(in: .newlines))
                .font(MobileTokens.mono)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.raised)
        .clipShape(RoundedRectangle(cornerRadius: MobileTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.border, lineWidth: 1))
    }
}
