import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

/// File tree model: lazy loading, containment, symlink cycles, special file blocking,
/// descriptor-based safe reads, binary detection, /var vs /private aliases,
/// expansion generations, and refresh parent-first ordering.
@Suite("File tree model", .serialized, .integrationTimeLimit)
struct FileTreeModelTests {
    // MARK: - Tree loading

    @Test(.enabled(if: geteuid() != 0, "root bypasses file permissions"))
    func unreadableChildrenDoNotHideReadableSiblings() async throws {
        let root = try makeScratchDirectory("ftree-permissions")
        let lockedFile = root.appendingPathComponent("locked.txt")
        let lockedFolder = root.appendingPathComponent("locked-folder")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try "visible".write(to: root.appendingPathComponent("readable.txt"), atomically: true, encoding: .utf8)
        try "private".write(to: lockedFile, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: lockedFolder, withIntermediateDirectories: true)
        for path in [lockedFile.path, lockedFolder.path] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        }
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        #expect(await model.root.error == nil)
        let nodes = await model.root.children ?? []
        #expect(Set(nodes.map(\.name)) == ["locked.txt", "locked-folder", "readable.txt"])
        #expect(nodes.filter { $0.name.hasPrefix("locked") }.allSatisfy { $0.error != nil })
        await model.select(path: root.appendingPathComponent("readable.txt").path)
        #expect(await model.selectedContent == .text(["visible"], "txt"))
    }

    @Test func loadsRootAndListsFiles() async throws {
        let root = try makeScratchDirectory("ftree")
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "world".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        let visible = await model.visibleNodes()
        let names = visible.map(\.node.name)
        #expect(names.contains("sub"))
        #expect(names.contains("a.txt"))
        // Directories sort before files
        if let subIdx = names.firstIndex(of: "sub"), let aIdx = names.firstIndex(of: "a.txt") {
            #expect(subIdx < aIdx)
        }
    }

    @Test func expandAndCollapse() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        var visible = await model.visibleNodes()
        #expect(!visible.contains { $0.node.name == "file.txt" })

        await model.expand(path: sub.path)
        visible = await model.visibleNodes()
        #expect(visible.contains { $0.node.name == "file.txt" })

        await MainActor.run { model.collapse(path: sub.path) }
        visible = await model.visibleNodes()
        #expect(!visible.contains { $0.node.name == "file.txt" })
    }

    // MARK: - Hidden files

    @Test func hiddenFilesRespectToggle() async throws {
        let root = try makeScratchDirectory("ftree")
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        var names = await model.visibleNodes().map(\.node.name)
        #expect(names.contains("visible.txt"))
        #expect(!names.contains(".hidden"), "Hidden files excluded by default")

        await MainActor.run { model.showHidden = true }
        await model.refresh()
        names = await model.visibleNodes().map(\.node.name)
        #expect(names.contains(".hidden"), "Hidden files shown when toggled on")

        await MainActor.run { model.showHidden = false }
        await model.refresh()
        names = await model.visibleNodes().map(\.node.name)
        #expect(!names.contains(".hidden"), "Hidden files disappear when toggled off again")
    }

    // MARK: - Symlink containment

    @Test func symlinkOutsideRootIsBlocked() async throws {
        let root = try makeScratchDirectory("ftree")
        let outside = try makeScratchDirectory("ftree-outside")
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        let names = await model.visibleNodes().map(\.node.name)
        #expect(!names.contains("escape"), "Symlink outside root should be blocked")
    }

    @Test func symlinkCycleIsDetected() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // sub/cycle -> root (ancestor)
        try FileManager.default.createSymbolicLink(
            at: sub.appendingPathComponent("cycle"),
            withDestinationURL: root
        )

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: sub.path)

        let visible = await model.visibleNodes()
        #expect(!visible.contains { $0.node.name == "cycle" }, "Symlink cycle to ancestor should be excluded")
    }

    // MARK: - File reading

    @Test func selectsAndReadsTextFile() async throws {
        let root = try makeScratchDirectory("ftree")
        let content = "line1\nline2\nline3"
        let filePath = root.appendingPathComponent("test.swift").path
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: filePath)

        let selected = await model.selectedContent
        if case .text(let lines, let lang) = selected {
            #expect(lines.count == 3)
            #expect(lang == "swift")
        } else {
            Issue.record("Expected text content, got \(String(describing: selected))")
        }
    }

    @Test func readFileOutsideRootFails() async throws {
        let root = try makeScratchDirectory("ftree")
        let outside = try makeScratchDirectory("ftree-outside")
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: outside.appendingPathComponent("secret.txt").path)

        let error = await model.selectedError
        #expect(error != nil, "Reading outside root should fail")
    }

    // MARK: - Binary detection

    @Test func binaryFileWithNulIsRejected() async throws {
        let root = try makeScratchDirectory("ftree")
        let filePath = root.appendingPathComponent("binary.dat").path
        var data = Data("hello".utf8)
        data.append(0) // NUL byte
        data.append(Data("world".utf8))
        try data.write(to: URL(fileURLWithPath: filePath))

        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: filePath)

        let error = await model.selectedError
        #expect(error?.contains("Binary") == true || error?.contains("binary") == true,
                "File with NUL should be rejected as binary, got: \(error ?? "nil")")
    }

    @Test func controlCharHeavyFileIsRejected() async throws {
        let root = try makeScratchDirectory("ftree")
        let filePath = root.appendingPathComponent("ctrl.dat").path
        // 20% control chars (excluding tab/newline/cr)
        var data = Data()
        for i in 0..<100 {
            if i % 5 == 0 {
                data.append(1) // SOH control char
            } else {
                data.append(0x41) // 'A'
            }
        }
        try data.write(to: URL(fileURLWithPath: filePath))

        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: filePath)

        let error = await model.selectedError
        #expect(error != nil, "File with excessive control chars should be rejected as binary")
    }

    // MARK: - Oversize files

    @Test func oversizeTextFileIsRejected() async throws {
        let root = try makeScratchDirectory("ftree")
        let filePath = root.appendingPathComponent("big.txt").path
        // Create a file just over 2MB
        let fd = Darwin.open(filePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw CommandFailure("open", "cannot create big.txt") }
        defer { Darwin.close(fd) }
        // Truncate to 2MB + 1
        ftruncate(fd, off_t(FileTreeModel.maxTextSize + 1))

        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: filePath)

        let error = await model.selectedError
        #expect(error?.contains("large") == true || error?.contains("Large") == true,
                "Oversize text file should be rejected, got: \(error ?? "nil")")
    }

    // MARK: - Special files (FIFO)

    @Test func fifoIsBlockedNotBlocking() async throws {
        let root = try makeScratchDirectory("ftree")
        let fifoPath = root.appendingPathComponent("test.fifo").path
        mkfifo(fifoPath, 0o644)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        // FIFO should not appear in listing (blocked as special file)
        let names = await model.visibleNodes().map(\.node.name)
        #expect(!names.contains("test.fifo"), "FIFO should be excluded from listing")

        // Direct read should fail with special file error, not block
        await model.select(path: fifoPath)
        let error = await model.selectedError
        #expect(error != nil, "Reading FIFO should fail, not block")
    }

    // MARK: - /var vs /private/var alias

    @Test func privateVarAliasContainmentWorks() async throws {
        // /tmp is /private/tmp on macOS. Use it to verify alias handling.
        let root = try makeScratchDirectory("ftree")
        let filePath = root.appendingPathComponent("alias-test.txt").path
        try "ok".write(toFile: filePath, atomically: true, encoding: .utf8)

        // The scratch dir is under /tmp which is /private/tmp.
        // canonicalRealpath should resolve consistently with F_GETPATH.
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: filePath)

        let content = await model.selectedContent
        let resolved = await model.resolvedRoot
        #expect(content != nil, "File under /tmp alias should be readable (resolvedRoot: \(resolved))")
    }

    // MARK: - Refresh parent-first ordering

    @Test func refreshSortsParentFirst() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("parent")
        let deep = sub.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "x".write(to: deep.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: sub.path)
        await model.expand(path: deep.path)

        await model.refresh()

        let visible = await model.visibleNodes()
        #expect(visible.contains { $0.node.name == "file.txt" }, "Nested file should be visible after refresh")
    }

    // MARK: - Filter

    @Test func filterNarrowsVisibleNodes() async throws {
        let root = try makeScratchDirectory("ftree")
        try "a".write(to: root.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("beta.swift"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        await MainActor.run { model.filter = "alpha" }
        let visible = await model.visibleNodes()
        #expect(visible.contains { $0.node.name == "alpha.txt" })
        #expect(!visible.contains { $0.node.name == "beta.swift" })
    }

    // MARK: - Selection cancellation

    @Test func cancellationOnNewSelection() async throws {
        let root = try makeScratchDirectory("ftree")
        try String(repeating: "x", count: 1000).write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "second".write(to: root.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        await model.select(path: root.appendingPathComponent("first.txt").path)
        await model.select(path: root.appendingPathComponent("second.txt").path)

        let path = await model.selectedPath
        #expect(path == root.appendingPathComponent("second.txt").path)
        if case .text(let lines, _) = await model.selectedContent {
            #expect(lines == ["second"])
        }
    }

    // MARK: - Tab management

    @Test func tabsTrackSelectionAndClose() async throws {
        let root = try makeScratchDirectory("ftree")
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        await model.select(path: root.appendingPathComponent("a.txt").path)
        await model.select(path: root.appendingPathComponent("b.txt").path)

        var tabs = await model.openTabs
        #expect(tabs.count == 2)
        #expect(tabs.map(\.name) == ["a.txt", "b.txt"])

        // Close active tab: selection moves to remaining
        await model.closeTab(root.appendingPathComponent("b.txt").path)
        tabs = await model.openTabs
        #expect(tabs.count == 1)
        let sel = await model.selectedPath
        #expect(sel == root.appendingPathComponent("a.txt").path)
        #expect(await model.selectedContent == .text(["a"], "txt"))
        await model.closeTab(root.appendingPathComponent("a.txt").path)
        #expect(await model.selectedPath == nil)
        #expect(await model.selectedContent == nil)
        #expect(await model.selectedLoading == false)
    }

    @Test func repeatedRootLoadPreservesExpandedChildren() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: sub.path)
        await model.loadRoot()
        #expect(await model.visibleNodes().contains { $0.node.name == "nested.txt" })
    }

    @Test func siblingAliasesCannotCycleBackToAnEarlierAncestor() async throws {
        let root = try makeScratchDirectory("ftree")
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("to-b"), withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b.appendingPathComponent("to-a"), withDestinationURL: a)
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: a.path)
        await model.expand(path: a.appendingPathComponent("to-b").path)
        #expect(await model.visibleNodes().allSatisfy { $0.node.name != "to-a" })
    }

    @Test func nulBeyondTheHeuristicPrefixIsRejected() async throws {
        let root = try makeScratchDirectory("ftree")
        let file = root.appendingPathComponent("late-nul.txt")
        var data = Data(repeating: 65, count: 9000)
        data.append(0)
        try data.write(to: file)
        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: file.path)
        #expect(await model.selectedContent == nil)
        #expect(await model.selectedError?.contains("Binary") == true)
    }

    @Test func excessiveHiddenEntriesProduceAVisibleError() async throws {
        let root = try makeScratchDirectory("ftree")
        for index in 0...FileTreeModel.maxDirectoryEntries {
            let fd = open(root.appendingPathComponent(".hidden-\(index)").path, O_CREAT | O_WRONLY, 0o600)
            guard fd >= 0 else { throw CommandFailure("open", "cannot create hidden entry") }
            close(fd)
        }
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        #expect(await model.root.error?.contains("entries") == true)
        #expect(await model.root.isLoading == false)
    }

    @Test func symlinkFileTargetIsValidatedBeforeReading() async throws {
        let root = try makeScratchDirectory("ftree")
        let outside = try makeScratchDirectory("ftree-out")
        let file = root.appendingPathComponent("link.txt")
        let target = root.appendingPathComponent("inside.txt")
        let secret = outside.appendingPathComponent("secret.txt")
        try "inside".write(to: target, atomically: true, encoding: .utf8)
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: file.path)
        #expect(await model.selectedContent == .text(["inside"], "txt"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        await model.refresh()
        #expect(await model.selectedContent == nil)
        #expect(await model.selectedError?.contains("outside") == true)
        #expect(await model.visibleNodes().allSatisfy { $0.node.name != "link.txt" })
    }

    @Test func replacingDirectorySymlinkCannotEnumerateOutsideRoot() async throws {
        let root = try makeScratchDirectory("ftree")
        let outside = try makeScratchDirectory("ftree-out")
        let inside = root.appendingPathComponent("inside")
        let alias = root.appendingPathComponent("alias")
        let staging = root.appendingPathComponent(".swap")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try "safe".write(to: inside.appendingPathComponent("safe.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
        let model = await FileTreeModel(rootPath: root.path)
        let swapping = Task.detached {
            for index in 0..<2000 {
                if Task.isCancelled { break }
                try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: index.isMultiple(of: 2) ? outside : inside)
                guard rename(staging.path, alias.path) == 0 else { throw CommandFailure("rename", "cannot replace alias") }
            }
        }
        defer { swapping.cancel() }
        for _ in 0..<100 {
            await model.refresh()
            await model.expand(path: alias.path)
            #expect(await model.visibleNodes().allSatisfy { $0.node.name != "secret.txt" })
        }
        try await swapping.value
    }

    @Test func imageTypesKeepSVGReadableAsSource() async throws {
        #expect(FileTreeModel.imageExtensions.contains("heic"))
        #expect(FileTreeModel.imageExtensions.contains("heif"))
        let root = try makeScratchDirectory("ftree")
        let file = root.appendingPathComponent("vector.svg")
        try "<svg/>".write(to: file, atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: file.path)
        #expect(await model.selectedContent == .text(["<svg/>"], "svg"))
    }

    @Test func overlappingSelectionsAndRefreshKeepTheLatestContent() async throws {
        let root = try makeScratchDirectory("ftree")
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try String(repeating: "x", count: 1_000_000).write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        let pending = Task { await model.select(path: first.path) }
        try await eventuallyOnMain("first selection started") { model.selectedPath == first.path }
        let refreshing = Task { await model.refresh() }
        await model.select(path: second.path)
        await pending.value
        await refreshing.value
        #expect(await model.selectedPath == second.path)
        #expect(await model.selectedContent == .text(["second"], "txt"))
        #expect(await model.selectedLoading == false)
    }

    @Test func closingATabDuringItsReadCannotRestoreItsContent() async throws {
        let root = try makeScratchDirectory("ftree")
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 1_000_000).write(to: second, atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        await model.select(path: first.path)
        let pending = Task { await model.select(path: second.path) }
        try await eventuallyOnMain("second tab selected") { model.selectedPath == second.path }
        await model.closeTab(second.path)
        await pending.value
        #expect(await model.selectedPath == first.path)
        #expect(await model.selectedContent == .text(["first"], "txt"))
    }

    @Test func collapseInvalidatesPendingDescendantExpansion() async throws {
        let root = try makeScratchDirectory("ftree")
        let parent = root.appendingPathComponent("parent")
        let child = parent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "nested".write(to: child.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.expand(path: parent.path)
        let pending = Task { await model.expand(path: child.path) }
        try await eventuallyOnMain("child expansion started") {
            model.visibleNodes().contains { $0.node.id == child.path && ($0.node.isLoading || $0.node.isExpanded) }
        }
        await MainActor.run { model.collapse(path: parent.path) }
        await pending.value
        await model.refresh()
        #expect(await model.visibleNodes().allSatisfy { $0.node.name != "nested.txt" && $0.node.name != "child" })
    }

    @Test func refreshCannotReuseAnEarlierExpansionGeneration() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "nested".write(to: sub.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        for _ in 0..<20 {
            let pending = Task { await model.expand(path: sub.path) }
            try await eventuallyOnMain("sub expansion started") {
                model.visibleNodes().contains { $0.node.id == sub.path && ($0.node.isLoading || $0.node.isExpanded) }
            }
            await MainActor.run { model.collapse(path: sub.path) }
            await model.refresh()
            await pending.value
            #expect(await model.visibleNodes().allSatisfy { $0.node.name != "nested.txt" })
        }
    }

    // MARK: - Expansion generation guards

    @Test func expansionGenerationPreventsStaleOverwrite() async throws {
        let root = try makeScratchDirectory("ftree")
        let sub = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let model = await FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        // Expand so children are visible
        await model.expand(path: sub.path)
        var visible = await model.visibleNodes()
        #expect(visible.contains { $0.node.name == "file.txt" })

        // Collapse: children gone
        await MainActor.run { model.collapse(path: sub.path) }
        visible = await model.visibleNodes()
        #expect(!visible.contains { $0.node.name == "file.txt" },
                "Collapsed directory should not show children")

        // Re-expand works: generation allows fresh load
        await model.expand(path: sub.path)
        visible = await model.visibleNodes()
        #expect(visible.contains { $0.node.name == "file.txt" },
                "Re-expanded directory should show children again")
    }
}
