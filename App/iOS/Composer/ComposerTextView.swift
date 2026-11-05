import ShepherdRemote
import ShepherdUI
import SwiftUI
import UIKit

/// The thread composer's field on iPhone and iPad. A UITextView rather than a TextField so a
/// skill in the draft ("/skill:debug") shows as one inline chip (`SHSkillChipAttachment`), as the
/// Mac's field draws it: ⌫ after it takes the whole skill and the caret never lands inside it.
/// The draft stays plain text. It grows to `SHComposerMetrics.fieldMaxLines` lines, then scrolls.
struct ComposerTextView: View {
    @Binding var text: String
    let placeholder: String
    @Binding var focused: Bool
    var style: SHTextStyle = .body
    let label: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Field(text: $text, focused: $focused, font: .sh(style, category: UIContentSizeCategory(dynamicTypeSize)),
              dark: colorScheme == .dark, label: label)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.sh(style)).foregroundStyle(Color.sh.textTertiary)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

    private struct Field: UIViewRepresentable {
        @Binding var text: String
        @Binding var focused: Bool
        let font: UIFont
        let dark: Bool
        let label: String

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.isScrollEnabled = false
            view.delegate = context.coordinator
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            let coordinator = context.coordinator
            coordinator.parent = self
            view.tintColor = UIColor(Color.sh.lantern)
            view.accessibilityLabel = label
            let restyled = coordinator.drawn != Drawn(font: font, dark: dark)
            if restyled || SHSkillChips.text(of: view.attributedText) != text {
                // A new appearance or text size redraws the chips where the caret is; new words put it at the end.
                let caret = restyled && SHSkillChips.text(of: view.attributedText) == text ? view.selectedRange : nil
                coordinator.updating = true
                view.attributedText = SHSkillChips.attributed(text, tokens: ComposerSkillToken.ranges(in: text), name: ComposerSkillToken.name,
                                                              attributes: coordinator.attributes, dark: dark)
                    ?? NSAttributedString(string: text, attributes: coordinator.attributes)
                view.selectedRange = caret ?? NSRange(location: view.attributedText.length, length: 0)
                coordinator.updating = false
                coordinator.drawn = Drawn(font: font, dark: dark)
                view.invalidateIntrinsicContentSize()
            }
            view.typingAttributes = coordinator.attributes
            // First responder follows `focused` after this update, never during it.
            if focused != view.isFirstResponder {
                DispatchQueue.main.async { [weak view] in
                    guard let view, focused != view.isFirstResponder else { return }
                    if focused { view.becomeFirstResponder() } else { view.resignFirstResponder() }
                }
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
            let width = proposal.width ?? view.bounds.width
            guard width > 0 else { return nil }
            let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let most = ceil(font.lineHeight * CGFloat(SHComposerMetrics.fieldMaxLines))
            let scrolls = fit > most
            if view.isScrollEnabled != scrolls { view.isScrollEnabled = scrolls }
            return CGSize(width: width, height: max(ceil(font.lineHeight), min(fit, most)))
        }

        struct Drawn: Equatable {
            var font: UIFont
            var dark: Bool
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Field
            var updating = false
            var drawn: Drawn?
            init(_ parent: Field) { self.parent = parent }

            var attributes: [NSAttributedString.Key: Any] {
                [.font: parent.font, .foregroundColor: UIColor(Color.sh.textPrimary)]
            }

            func textViewDidChange(_ view: UITextView) {
                guard !updating else { return }
                parent.text = SHSkillChips.text(of: view.attributedText)
            }

            func textViewDidChangeSelection(_ view: UITextView) {
                // Words typed after a chip are words, not another chip.
                if !updating, view.markedTextRange == nil { view.typingAttributes = attributes }
            }

            func textViewDidBeginEditing(_ view: UITextView) {
                if !parent.focused { parent.focused = true }
            }

            func textViewDidEndEditing(_ view: UITextView) {
                if parent.focused { parent.focused = false }
            }
        }
    }
}
