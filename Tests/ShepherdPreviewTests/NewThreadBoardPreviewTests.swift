import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The New thread page's variants (GXNewPayments, GXNewWorktree boards): another project picked with its place menu open over
/// two paired Macs, and the New worktree sheet over the page. Made-up project names only.
@Suite("New thread board previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct NewThreadBoardPreviewTests {
    typealias P = FleetPagePreviewTests

    /// Four projects, the second a git repository picked, Macs paired.
    private static func page(_ workspace: PreviewWorkspace) async throws -> (ShepherdViewModel, Space) {
        let repo = try makeScratchRepo()
        let payments = Space(name: "payments", path: repo.path)
        let others = ["shepherd", "dashboard-web", "homelab"].map { name in Space(name: name, path: workspace.dir.appendingPathComponent(name).path) }
        try await workspace.seed(ShepherdState(spaces: [others[0], payments] + others.dropFirst()))
        P.seedFleet(workspace)
        let vm = workspace.vm
        vm.openNewThread(in: payments.id)
        try await eventuallyOnMain("the New thread page's defaults") { !vm.newThread.loadingDefaults && vm.newThread.place != nil }
        #expect(vm.newThread.fleetPicker(vm).options.map(\.name).contains("Auto"), "the paired Macs are listed")
        return (vm, payments)
    }

    @Test func anotherProjectPickedWithItsPlaceMenu() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (vm, _) = try await Self.page(workspace)
        try await Preview.render("new-thread-payments", size: CGSize(width: 1000, height: 1150)) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome(), placeOpen: true)
        }
    }

    @Test func aNewWorktreeFromABase() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let (vm, payments) = try await Self.page(workspace)
        try await Preview.render("new-thread-worktree", size: CGSize(width: 1000, height: 700)) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome())
                .overlay { Color.sh.modalScrim }
                .overlay(alignment: .top) {
                    NewWorktreeSheet(vm: vm, space: payments)
                        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.xxl))
                        .shadow(color: .sh.popoverShadow, radius: SH.Space.xxl)
                        .padding(.top, 96)
                }
        }
    }
}
