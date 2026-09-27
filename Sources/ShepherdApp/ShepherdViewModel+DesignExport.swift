import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UniformTypeIdentifiers

// Export (DZExport) and import (decision 4): a design's boards written where the user picks in a
// save panel, or attached to a thread's composer; a Claude Design folder read into a new design.
// Nothing here writes a repository.

extension ShepherdViewModel {
    // MARK: Export

    /// Export (the design header's, or Export… in a design's menu): the sheet, with the boards the
    /// canvas has selected ticked (every board when none is, or when the canvas hasn't been shown).
    func openDesignExport(_ id: DesignID) {
        guard let design = design(id) else { return }
        let screen = designScreens[id]
        var selected = Set(screen?.picks.map(\.board) ?? [])
        if let presented = screen?.presented { selected.insert(presented) }
        if let index = screen?.snapshot?.index {
            designExport = DesignExportModel(designID: id, designName: design.name,
                                             selection: DesignExportSelection(index: index, selected: selected),
                                             threads: designAttachTargets)
            return
        }
        Task {
            do {
                let snapshot = try await server.designSnapshot(id)
                designExport = DesignExportModel(designID: id, designName: design.name,
                                                 selection: DesignExportSelection(index: snapshot.index, selected: []),
                                                 threads: designAttachTargets)
            } catch {
                remoteActionError = "Couldn't export \(design.name): \(error)"
            }
        }
    }

    /// Cancel, the close button, Escape. An export being written finishes first.
    func closeDesignExport() {
        guard designExport?.working != true else { return }
        designExport = nil
    }

    /// Local threads a design's boards can be attached to: every agent that draws no design, in a
    /// space the sidebar shows, most recently active first.
    var designAttachTargets: [DesignExportModel.Thread] {
        let spaces = Set(visibleSpaces.map(\.id))
        return state.agents
            .filter { $0.designID == nil && spaces.contains($0.spaceID) }
            .sorted { ($0.lastActiveAt ?? -1) > ($1.lastActiveAt ?? -1) }
            .prefix(20)
            .map { DesignExportModel.Thread(id: $0.id, name: $0.name) }
    }

    /// Export: the save panel for where it goes, then the export.
    func runDesignExport(_ model: DesignExportModel) {
        guard model.canExport else { return }
        let destination = DesignExportNames.destination(model.format, boards: model.selection.boards, design: model.designName)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = destination.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !destination.isFolder {
            switch model.format {
            case .zip: panel.allowedContentTypes = [.zip]
            case .pdf: panel.allowedContentTypes = [.pdf]
            case .html: panel.allowedContentTypes = [.html]
            case .png: panel.allowedContentTypes = [.png]
            }
        } else {
            panel.message = "A folder with one file per board."
        }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak model] response in
            guard response == .OK, let url = panel.url, let self, let model else { return }
            Task { await self.exportDesign(model, to: url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Writes the sheet's ticked boards as its format at `url`, then puts the sheet away.
    func exportDesign(_ model: DesignExportModel, to url: URL) async {
        model.working = true
        defer { model.working = false }
        do {
            let files = try await server.designExportFiles(model.designID, boards: model.selection.boards)
            let tokens = await designTokens(model.designID, files: files)
            try await designRendering.export(model.format, files: files, designID: model.designID, name: model.designName,
                                             tokens: tokens, to: url)
            if designExport === model { designExport = nil }
        } catch {
            remoteActionError = "Couldn't export \(model.designName): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    /// Attach to a thread: the ticked boards as standalone pages and a note of the tokens they
    /// use, waiting in that thread's composer, which opens.
    func attachDesignExport(_ model: DesignExportModel, to agentID: AgentID) {
        guard model.canExport else { return }
        model.working = true
        Task {
            defer { model.working = false }
            do {
                let files = try await server.designExportFiles(model.designID, boards: model.selection.boards)
                let tokens = await designTokens(model.designID, files: files)
                let attached = try await designRendering.attachments(files: files, designID: model.designID, name: model.designName,
                                                                     tokens: tokens, into: designAttachDirectory)
                threadStores.store(for: agentID).attach(files: attached)
                if designExport === model { designExport = nil }
                if state.agents.contains(where: { $0.id == agentID }) { selectAgent(agentID) }
            } catch {
                remoteActionError = "Couldn't attach \(model.designName): \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
        }
    }

    /// The tokens the design's boards declare, then those its agent's folder declares (read-only):
    /// the design's own folder, or the project an older design's agent still works in.
    private func designTokens(_ id: DesignID, files: DesignExportFiles) async -> DesignTokens {
        var tokens = DesignTokens()
        for path in files.members {
            if let source = files.sources[path] { tokens = tokens.merged(with: DesignTokens.read(board: source)) }
        }
        let project = design(id).flatMap(designWorkingFolder)
        return tokens.merged(with: await DesignProjectTokens.read(project))
    }

    // MARK: Import

    /// File ▸ Import Claude Design Project…: the picker for a ZIP or a folder, then the import
    /// (`importDesignProject`).
    func chooseDesignFolder() {
        chooseDesignProject()
    }

    /// Reads a Claude Design folder or ZIP into a new standalone design, and opens it. The source
    /// is only read.
    func importDesignFolder(_ url: URL) {
        importDesignProject(url)
    }
}
