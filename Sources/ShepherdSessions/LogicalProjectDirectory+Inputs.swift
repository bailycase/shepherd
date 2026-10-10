import CryptoKit
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

extension LogicalProjectDirectory {
    /// The identity depends on the submission and position, never a source path or filename.
    static func inputID(operation: UUID, index: Int) -> UUID {
        let hash = Array(SHA256.hash(data: Data("\(operation.uuidString.lowercased()):\(index)".utf8)))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    static func inputReferences(operation: UUID, images: [NativeImage]) throws -> [ProjectInputImage] {
        guard NativeImage.fitOneSend(images), images.allSatisfy({ $0.mimeType.utf8.count <= 256 }) else {
            throw LogicalProjectsError("invalid", "Send accepts up to four images of 2 MiB each, 5 MiB total, with a bounded image MIME type.")
        }
        return images.enumerated().map { index, image in
            .init(id: inputID(operation: operation, index: index), mimeType: image.mimeType,
                  name: image.name.map { String($0.prefix(256)) }, byteCount: image.data.count)
        }
    }

    private static func inputFailure() -> LogicalProjectsError {
        LogicalProjectsError("project_image_unavailable", "Project input images could not be stored or read safely. Nothing was sent without them.")
    }

    private static func withInputs<T>(id: ProjectID, operation: UUID, beside stateURL: URL, create: Bool,
                                      body: (Int32, dev_t) throws -> T) throws -> T {
        try withDirectory(id: id, beside: stateURL) { root, _ in
            var info = stat()
            guard fstat(root, &info) == 0 else { throw inputFailure() }
            let device = info.st_dev
            var parent = fcntl(root, F_DUPFD_CLOEXEC, 0)
            guard parent >= 0 else { throw inputFailure() }
            defer { close(parent) }
            for name in [".inputs", operation.uuidString.lowercased()] {
                if create {
                    if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw inputFailure() }
                    guard fsync(parent) == 0 else { throw inputFailure() }
                }
                let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw inputFailure() }
                close(parent); parent = next
                guard fstat(parent, &info) == 0, info.st_dev == device, info.st_uid == geteuid(),
                      info.st_mode & 0o777 == 0o700 else { throw inputFailure() }
            }
            return try body(parent, device)
        }
    }

    private static func readInput(_ ref: ProjectInputImage, parent: Int32, device: dev_t) throws -> Data {
        let fd = openat(parent, ref.id.uuidString.lowercased(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw inputFailure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size == ref.byteCount, ref.byteCount >= 0, ref.byteCount <= NativeImage.maxBytes else { throw inputFailure() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count <= ref.byteCount {
            let n = Darwin.read(fd, &buffer, min(buffer.count, ref.byteCount + 1 - bytes.count))
            if n < 0 { if errno == EINTR { continue }; throw inputFailure() }
            if n == 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        guard bytes.count == ref.byteCount else { throw inputFailure() }
        return bytes
    }

    static func storeInputs(id: ProjectID, operation: UUID, images: [NativeImage], beside stateURL: URL) throws -> [ProjectInputImage] {
        let refs = try inputReferences(operation: operation, images: images)
        return try withInputs(id: id, operation: operation, beside: stateURL, create: true) { parent, device in
            for (ref, image) in zip(refs, images) {
                let name = ref.id.uuidString.lowercased()
                var existing = stat()
                if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard try readInput(ref, parent: parent, device: device) == image.data else {
                        throw LogicalProjectsError("conflict", "A submitted image identity cannot change its bytes.")
                    }
                    continue
                }
                guard errno == ENOENT else { throw inputFailure() }
                let temporary = ".stage-" + UUID().uuidString.lowercased()
                let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
                guard fd >= 0 else { throw inputFailure() }
                defer { close(fd); _ = unlinkat(parent, temporary, 0) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_dev == device, info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG else { throw inputFailure() }
                try image.data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if n < 0, errno == EINTR { continue }
                        guard n > 0 else { throw inputFailure() }
                        offset += n
                    }
                }
                guard fsync(fd) == 0 else { throw inputFailure() }
                // Publish without replacing an existing identity, including one inserted by a race.
                guard linkat(parent, temporary, parent, name, 0) == 0,
                      unlinkat(parent, temporary, 0) == 0, fsync(parent) == 0 else { throw inputFailure() }
                guard try readInput(ref, parent: parent, device: device) == image.data else { throw inputFailure() }
            }
            return refs
        }
    }

    static func loadInputs(id: ProjectID, message: ProjectMessage, beside stateURL: URL) throws -> [NativeImage] {
        let refs = message.images ?? []
        guard !refs.isEmpty else { return [] }
        guard refs.count <= NativeImage.maxPerSend,
              refs.enumerated().allSatisfy({ $0.element.id == inputID(operation: message.id, index: $0.offset)
                  && $0.element.byteCount >= 0 && $0.element.byteCount <= NativeImage.maxBytes }),
              refs.reduce(0, { $0 + $1.byteCount }) <= NativeImage.maxBytesPerSend else { throw inputFailure() }
        let images = try withInputs(id: id, operation: message.id, beside: stateURL, create: false) { parent, device in
            try refs.map { ref in NativeImage(mimeType: ref.mimeType, data: try readInput(ref, parent: parent, device: device), name: ref.name) }
        }
        guard NativeImage.fitOneSend(images) else { throw inputFailure() }
        return images
    }
}
