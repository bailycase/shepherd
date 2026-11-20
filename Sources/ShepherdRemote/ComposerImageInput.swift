import Foundation
import UniformTypeIdentifiers
import ShepherdProtocol

/// What a device's composer does with the things handed to it by paste, drop or the Files picker.
/// A native send carries text and images only, so an item is an image or it is refused with a
/// sentence the composer shows; `NativeImagePreparation` then resizes what is taken, within the
/// same size limits as the Mac.
public enum ComposerImageInput {
    /// One pasted, dropped or picked item: the type identifiers it offers, best first, and the name it suggests.
    public struct Item: Equatable, Sendable {
        public var typeIdentifiers: [String]
        public var name: String?

        public init(typeIdentifiers: [String], name: String? = nil) {
            self.typeIdentifiers = typeIdentifiers
            self.name = name
        }

        /// A file the Files picker returned, typed by its extension.
        public init(fileName: String) {
            self.init(typeIdentifiers: UTType(filenameExtension: (fileName as NSString).pathExtension.lowercased()).map { [$0.identifier] } ?? [],
                      name: fileName)
        }
    }

    /// An item to load: its place in the list handed in, the type to ask it for, and its name.
    public struct Accepted: Equatable, Sendable {
        public var index: Int
        public var typeIdentifier: String
        public var name: String
    }

    public struct Plan: Equatable, Sendable {
        public var accepted: [Accepted] = []
        /// Why items were left out, one sentence each.
        public var rejections: [String] = []

        /// The line the composer shows above the field, nil when everything was taken.
        public var message: String? { rejections.isEmpty ? nil : rejections.joined(separator: " ") }
    }

    /// The first type the item offers that is an image; nil when it offers none (a PDF, a folder, plain text).
    public static func imageType(of item: Item) -> String? {
        item.typeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    /// Which of `items` a message holding room for `room` more images takes. Non-images are refused
    /// by name; images past the room are refused together.
    public static func plan(_ items: [Item], room: Int) -> Plan {
        var plan = Plan()
        var skipped = false
        var notImages: [String] = []
        for (index, item) in items.enumerated() {
            guard let type = imageType(of: item) else {
                notImages.append(item.name ?? "That item")
                continue
            }
            guard plan.accepted.count < room else {
                skipped = true
                continue
            }
            plan.accepted.append(Accepted(index: index, typeIdentifier: type, name: name(item.name, type: type, number: index + 1, of: items.count)))
        }
        switch notImages.count {
        case 0: break
        case 1: plan.rejections.append("\(notImages[0]) isn't an image. Only images can be attached here.")
        default: plan.rejections.append("\(notImages.count) items aren't images. Only images can be attached here.")
        }
        if skipped { plan.rejections.append(NativeImagePreparation.Failure.full.description) }
        return plan
    }

    private static func name(_ suggested: String?, type: String, number: Int, of count: Int) -> String {
        if let suggested, !suggested.isEmpty { return suggested }
        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
        return count == 1 ? "Image.\(ext)" : "Image \(number).\(ext)"
    }
}
