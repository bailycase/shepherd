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
                coordinator.revision += 1
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

        /// A layout pass asks for the field's size several times per edit: at its width, and at no width limit, where a stack
        /// only learns how far the field could stretch. Each answer lays the whole draft out, a draft on one line the slowest,
        /// so a height is kept for the edit and width it was measured for (`Coordinator.fits`), and an unlimited width is
        /// answered with the height at the width the field has.
        func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
            let width = proposal.width ?? view.bounds.width
            guard width > 0 else { return nil }
            SHRenderProbe.tick("layout.composerFieldProbed")
            let coordinator = context.coordinator
            let wrapAt = width.isFinite || view.bounds.width <= 0 ? width : view.bounds.width
            let answer = coordinator.fits.answer(width: wrapAt, key: Fit(revision: coordinator.revision, font: font)) {
                SHRenderProbe.tick("layout.composerFieldMeasured")
                let fit = view.sizeThatFits(CGSize(width: wrapAt, height: .greatestFiniteMagnitude)).height
                let most = ceil(font.lineHeight * CGFloat(SHComposerMetrics.fieldMaxLines))
                return Fit.Answer(height: max(ceil(font.lineHeight), min(fit, most)), scrolls: fit > most)
            }
            if view.isScrollEnabled != answer.scrolls { view.isScrollEnabled = answer.scrolls }
            return CGSize(width: width, height: answer.height)
        }

        /// What a height depends on besides the width: the words, by `Coordinator.revision`, and the type they are set in.
        struct Fit: Equatable {
            var revision: Int
            var font: UIFont

            /// The field's height at a width, and whether its words run past it.
            struct Answer {
                var height: CGFloat
                var scrolls: Bool
            }
        }

        struct Drawn: Equatable {
            var font: UIFont
            var dark: Bool
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: Field
            var updating = false
            var drawn: Drawn?
            /// Bumped by every change to the words the field holds, by the reader's edits and by code's.
            var revision = 0
            var fits = SHComposerFitCache<Fit, Fit.Answer>()
            init(_ parent: Field) { self.parent = parent }

            var attributes: [NSAttributedString.Key: Any] {
                [.font: parent.font, .foregroundColor: UIColor(Color.sh.textPrimary)]
            }

            func textViewDidChange(_ view: UITextView) {
                revision += 1
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
