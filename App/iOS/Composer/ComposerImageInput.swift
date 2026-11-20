import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ShepherdRemote

/// Images reach the composer from Photos, the Files picker, a paste and a drop. Each source hands its
/// items to `ComposerImageInput` (which takes the images and names why it refused the rest), and the
/// ones it took are resized for the send by `attach(_:)`, the way the Mac's drop does.
extension ComposerState {
    /// Dropped or pasted items.
    func attach(providers: [NSItemProvider]) async {
        let items = providers.map { ComposerImageInput.Item(typeIdentifiers: $0.registeredTypeIdentifiers, name: $0.suggestedName) }
        await attach(items, room: room, failure: "couldn't be loaded") { accepted in
            await withCheckedContinuation { continuation in
                _ = providers[accepted.index].loadDataRepresentation(forTypeIdentifier: accepted.typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Files the Files picker returned (security scoped).
    func attach(files: [URL]) async {
        let items = files.map { ComposerImageInput.Item(fileName: $0.lastPathComponent) }
        await attach(items, room: room, failure: "couldn't be read") { accepted in
            let url = files[accepted.index]
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return await Task.detached { try? Data(contentsOf: url) }.value
        }
    }

    private func attach(_ items: [ComposerImageInput.Item], room: Int, failure: String,
                        load: (ComposerImageInput.Accepted) async -> Data?) async {
        let plan = ComposerImageInput.plan(items, room: room)
        pendingImports += 1
        var loaded: [(data: Data, name: String)] = []
        var failures = 0
        for accepted in plan.accepted {
            if let data = await load(accepted) { loaded.append((data, accepted.name)) } else { failures += 1 }
        }
        pendingImports -= 1
        await attach(loaded)
        var said = [attachmentError, plan.message].compactMap { $0 }
        if failures > 0 { said.append("\(failures) image(s) \(failure). Try again.") }
        if !said.isEmpty { attachmentError = said.joined(separator: " ") }
    }
}

/// A drop of images on the composer, which says why anything else was refused. A drop on an agent that
/// takes no images is refused whole.
struct ComposerImageDrop: ViewModifier {
    let state: ComposerState
    let enabled: Bool
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        content.onDrop(of: [.item], isTargeted: $targeted) { providers in
            guard enabled else {
                state.attachmentError = "This agent does not support image attachments."
                return true
            }
            Task { await state.attach(providers: providers) }
            return true
        }
    }
}

/// The text view the composer's field is made of, taking a pasted image where it would otherwise
/// offer no Paste: an image alone on the pasteboard is attached; anything with words in it pastes as text.
final class ComposerPasteTextView: UITextView {
    /// Set while the thread can take images.
    var pasteImages: (([NSItemProvider]) -> Void)?

    private var pastesImages: Bool {
        pasteImages != nil && UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), pastesImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if pastesImages, let pasteImages {
            pasteImages(UIPasteboard.general.itemProviders)
        } else {
            super.paste(sender)
        }
    }
}
