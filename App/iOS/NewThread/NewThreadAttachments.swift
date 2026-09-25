import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol

/// An image waiting to go with a new thread's first send: the bytes pi receives, and a
/// thumbnail decoded once.
struct NewThreadAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let image: NativeImage
    let thumbnail: UIImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Images are resized where they enter, as the Mac does (`TerminalImageDrop`): the longest edge
/// at most 2000 px, because pi keeps an attached image in its session and re-sends it on every
/// later load. Photos stay JPEG; anything else becomes PNG, or JPEG when PNG is over the send
/// limit.
enum NewThreadImages {
    static let maxEdge = 2000

    static func prepare(_ data: Data, name: String) -> NewThreadAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxEdge] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let photo = type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
        var encoded = photo ? encode(image, as: .jpeg) : encode(image, as: .png)
        var jpeg = photo
        if !photo, (encoded?.count ?? .max) > NativeImage.maxBytes {
            encoded = encode(image, as: .jpeg)
            jpeg = true
        }
        guard let bytes = encoded, bytes.count <= NativeImage.maxBytes else { return nil }
        let base = (name as NSString).deletingPathExtension
        let file = base + (jpeg ? ".jpg" : ".png")
        return NewThreadAttachment(name: file, image: NativeImage(mimeType: jpeg ? "image/jpeg" : "image/png", data: bytes, name: file),
                                   thumbnail: UIImage(cgImage: image))
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Attach: the photo picker, up to the images one send takes. Disabled on a host that cannot
/// take images, saying why.
struct NewThreadAttachButton: View {
    let model: NewThreadModel
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        let supported = model.host?.supportsImages ?? true
        let room = NativeImage.maxPerSend - model.attachments.count
        // The picker's label builds outside the main actor: resolve the tokens here.
        let font = Font.nw(.ui)
        let color = Color.nw.textSecondary
        PhotosPicker(selection: $picked, maxSelectionCount: max(room, 1), matching: .images) {
            Image(systemName: "paperclip")
                .font(font)
                .foregroundStyle(color)
                .frame(width: NW.Height.touch, height: NW.Height.touch)
                .contentShape(Rectangle())
        }
        .disabled(!supported || room <= 0)
        .accessibilityLabel("Attach images")
        .accessibilityHint(supported ? "Up to \(NativeImage.maxPerSend) images go with the first message."
                                     : "Update Shepherd on \(model.host?.name ?? "the host") to send images.")
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await load(items) }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let attachment = NewThreadImages.prepare(data, name: "image-\(model.attachments.count + index + 1)") else {
                model.errorText = "That image couldn't be read or is too large to send."
                continue
            }
            model.add(attachment)
        }
    }
}

/// The images waiting to go, each with a remove button.
struct NewThreadAttachmentStrip: View {
    let model: NewThreadModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: NW.Space.m) {
                ForEach(model.attachments) { attachment in
                    Image(uiImage: attachment.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: MobileLayout.newThreadThumbnail, height: MobileLayout.newThreadThumbnail)
                        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                        .overlay(alignment: .topTrailing) {
                            Button { model.remove(attachment: attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.nw(.ui))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.nw.textPrimary, Color.nw.bgRaised)
                                    .frame(width: NW.Height.touch, height: NW.Height.touch, alignment: .topTrailing)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: NW.Space.xs, y: -NW.Space.xs)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(attachment.name)
                }
            }
            // Room for each remove button, which sits over its thumbnail's corner.
            .padding(.top, NW.Space.m)
            .padding(.trailing, NW.Space.m)
        }
        .scrollIndicators(.hidden)
    }
}
