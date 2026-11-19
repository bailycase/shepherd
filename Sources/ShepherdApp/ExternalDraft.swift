import Foundation
import SwiftUI
import ShepherdUI

/// Open in ▾ for a text input (Settings): the input's in-app draft written to a temp file another app edits. Each save
/// there replaces the draft through `onChange`; Save in Shepherd stays what writes the real file. Typing in the app after
/// opening isn't pushed to the file; `start` again rewrites it. `stop` ends the watch and deletes the folder, when the
/// input leaves the screen.
@MainActor final class ExternalDraft {
    static let debounce: TimeInterval = 0.2
    /// Where drafts live: `<tmp>/Shepherd-edit/<uuid>/<name>`.
    nonisolated static var root: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "Shepherd-edit", directoryHint: .isDirectory) }

    let folder: URL
    let url: URL
    private var onChange: ((String) -> Void)?
    private var lastSeen = ""
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private(set) var isWatching = false

    init(name: String, root: URL = ExternalDraft.root) {
        folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        url = folder.appending(path: name)
    }

    /// Makes the folder and an empty file when they're missing: Launch Services names the apps for a file only once it exists.
    func prepare() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// Writes `text` to the file and watches it; every external change calls `onChange` with the new text.
    func start(text: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        lastSeen = text
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { return }
        isWatching = true
        arm()
    }

    /// Reads the file and passes on its text when it differs from the last text seen.
    func check() {
        guard isWatching, let text = try? String(contentsOf: url, encoding: .utf8), text != lastSeen else { return }
        lastSeen = text
        onChange?(text)
    }

    func stop() {
        isWatching = false
        pending?.cancel()
        sources.forEach { $0.cancel() }
        sources = []
        onChange = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// A source on the folder and the file: an atomic replace is a new inode, so the sources are opened again after each event.
    private func arm() {
        sources.forEach { $0.cancel() }
        sources = []
        guard isWatching else { return }
        for target in [folder, url] {
            let fd = open(target.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fired() } }
            source.setCancelHandler { close(fd) }
            source.activate()
            sources.append(source)
        }
    }

    private func fired() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isWatching else { return }
                self.arm()
                self.check()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }
}

/// The Open in ▾ button at a text input's top-right: opens the input's current draft (written as `name`) in the app its
/// type opens in. The watch and the temp folder end when the button leaves the screen.
struct SettingsOpenIn: View {
    @Binding var text: String
    @State private var draft: ExternalDraft

    init(text: Binding<String>, name: String) {
        _text = text
        _draft = State(initialValue: ExternalDraft(name: name))
    }

    var body: some View {
        let base = SHOpenIn.app
        let binding = $text
        let draft = draft
        let actions = SHOpenIn(
            target: { draft.prepare(); return base.target($0) },
            choices: { draft.prepare(); return base.choices($0) },
            open: { url, id in
                draft.start(text: binding.wrappedValue) { binding.wrappedValue = $0 }
                base.open(url, id)
            },
            other: { url in
                draft.start(text: binding.wrappedValue) { binding.wrappedValue = $0 }
                base.other(url)
            })
        SHOpenInButton(url: draft.url, actions: actions, size: .settings)
            .onDisappear { draft.stop() }
    }
}
