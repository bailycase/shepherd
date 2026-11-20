import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ShepherdRemote

/// Prepares one image at a time, so a drop of large photos never holds more than one decoded original.
private let preparing = NSLock()

/// Images reach the composer from Photos, the Files picker, a paste and a drop. Each source hands its
/// items to `ComposerImageInput` (which takes the images and names why it refused the rest), and the
/// ones it took are resized for the send the way the Mac's drop does, one at a time, so no original
/// stays in memory once its resized copy is made.
extension ComposerState {
    private struct Outcome: Sendable {
        var item: ComposerImageInput.Item
        /// Nil when the item was never loaded (not an image, or past the room) or could not be read.
        var prepared: Prepared?
    }

    /// Dropped or pasted items. Every load starts here, before this returns: a drop's providers can
    /// stop being readable once the drop handler has returned. Each provider's file is resized inside
    /// its own callback, the only time its (security scoped) file is reachable.
    func attach(providers: [NSItemProvider]) {
        pendingImports += 1
        let pixels = MobileLayout.attachmentThumbnailPixels
        var budget = room
        var outcomes: [AsyncStream<Outcome>] = []
        for (index, provider) in providers.enumerated() {
            let types = provider.registeredTypeIdentifiers
            let item = ComposerImageInput.Item(typeIdentifiers: types, name: provider.suggestedName)
            let (stream, out) = AsyncStream.makeStream(of: Outcome.self)
            outcomes.append(stream)
            let imageType = ComposerImageInput.imageType(of: item)
            let byURL = imageType == nil && types.contains(UTType.fileURL.identifier)
            guard imageType != nil || byURL, budget > 0 else {
                // Not an image, or one the message has no room for: planned (and refused) without a load.
                out.yield(Outcome(item: imageType == nil && !byURL ? item : .init(typeIdentifiers: [UTType.image.identifier], name: item.name)))
                out.finish()
                continue
            }
            budget -= 1
            if let imageType {
                let name = ComposerImageInput.name(item.name, type: imageType, number: index + 1, of: providers.count)
                provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                    out.yield(Outcome(item: item, prepared: url.flatMap { Self.prepare(file: $0, name: name, pixels: pixels) }))
                    out.finish()
                }
            } else {
                // Offered only as a file's URL: the file says what it is.
                provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else {
                        out.yield(Outcome(item: item))
                        out.finish()
                        return
                    }
                    let resolved = ComposerImageInput.Item(fileURL: url)
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let prepared = ComposerImageInput.imageType(of: resolved) == nil ? nil
                        : Self.prepare(file: url, name: resolved.name ?? url.lastPathComponent, pixels: pixels)
                    out.yield(Outcome(item: resolved, prepared: prepared))
                    out.finish()
                }
            }
        }
        Task {
            var items: [ComposerImageInput.Item] = []
            var prepared: [Prepared?] = []
            for stream in outcomes {
                let outcome = await stream.first { _ in true }
                items.append(outcome?.item ?? .init(typeIdentifiers: []))
                prepared.append(outcome?.prepared)
            }
            let plan = ComposerImageInput.plan(items, room: room)
            var errors: [String] = []
            var failures = 0
            for accepted in plan.accepted {
                if let image = prepared[accepted.index] {
                    if let error = append(image) { errors.append(error) }
                } else {
                    failures += 1
                }
            }
            pendingImports -= 1
            report(plan, errors: errors, failures: failures, failure: "couldn't be loaded")
        }
    }

    /// Files the Files picker returned (security scoped).
    func attach(files: [URL]) async {
        let plan = ComposerImageInput.plan(files.map { .init(fileName: $0.lastPathComponent) }, room: room)
        pendingImports += 1
        let pixels = MobileLayout.attachmentThumbnailPixels
        var errors: [String] = []
        var failures = 0
        for accepted in plan.accepted {
            let url = files[accepted.index]
            let scoped = url.startAccessingSecurityScopedResource()
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(file: url, name: accepted.name, pixels: pixels) }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let prepared {
                if let error = append(prepared) { errors.append(error) }
            } else {
                failures += 1
            }
        }
        pendingImports -= 1
        report(plan, errors: errors, failures: failures, failure: "couldn't be read")
    }

    /// The file's image resized for the send, one at a time; nil when it can't be read. The file is mapped, not read
    /// whole, and its decoded original is gone before this returns.
    private nonisolated static func prepare(file url: URL, name: String, pixels: CGSize) -> Prepared? {
        preparing.lock()
        defer { preparing.unlock() }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return prepare(data, name: name, thumbnailPixels: pixels)
    }

    private func report(_ plan: ComposerImageInput.Plan, errors: [String], failures: Int, failure: String) {
        var said = errors
        if let message = plan.message { said.append(message) }
        if failures > 0 { said.append("\(failures) image(s) \(failure). Try again.") }
        attachmentError = said.isEmpty ? nil : said.joined(separator: " ")
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
            state.attach(providers: providers)
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
