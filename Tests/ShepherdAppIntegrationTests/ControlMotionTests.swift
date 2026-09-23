import AppKit
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The shared controls' motion, read from off-screen frames: a segmented picker's pill slides
/// (or cross-fades under Reduce Motion), a switch's knob slides, a disabled control fades while
/// its label changes at once, a status pill fades to a new state but ticks at once, a toast
/// rises, and a slider tracks its value without easing.
@Suite("Control motion", .mainActorExclusive)
@MainActor
struct ControlMotionTests {
    @MainActor @Observable
    final class Model {
        var choice = 0
        var on = false
        var disabled = false
        var state = AgentState.running
        var label = "Running · 0:01"
        var value = 0.2
        var toast: NWToast?
    }

    // MARK: Segmented picker

    private struct Picker: View {
        let model: Model

        var body: some View {
            NWSegmentedPicker("Scope", selection: Binding(get: { model.choice }, set: { model.choice = $0 }),
                              options: [(0, "Alpha"), (1, "Bravo"), (2, "Charlie")])
                .padding(Self.inset)
                .frame(width: 300, height: 48, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }

        static let inset: CGFloat = 10
    }

    /// Alpha → Charlie: the one pill slides under Bravo on the way. Under Reduce Motion the
    /// pills cross-fade where they rest, and Bravo never changes.
    @Test(arguments: [false, true])
    func aSegmentedPickerSlidesItsPillPastTheSegmentsBetween(reduceMotion: Bool) async throws {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 300, height: 48), dark: false,
                                     Picker(model: model).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        // Inside the pill, above the labels: the track's fill or the pill's.
        let strip = CGRect(x: 0, y: Picker.inset + NW.Space.xxs + 3, width: 300, height: 1)
        let recording = await MotionProbe.record(window, region: strip) { model.choice = 2 }

        let changed = recording.settled.runs(differingFrom: recording.before)
        try #require(changed.count >= 2, "the pill left Alpha and reached Charlie: \(changed)")
        let bravo = (changed[0].upperBound + changed[changed.count - 1].lowerBound) / 2
        let passesBravo = recording.inBetween.contains { $0.differs(from: recording.before, at: bravo) }
        #expect(!recording.inBetween.isEmpty, "it animates in \(recording.frames.count) frames")
        #expect(passesBravo != reduceMotion, "the pill crosses Bravo only when it slides")
    }

    private struct LoadingPicker: View {
        let model: Model

        var body: some View {
            Picker(model: model).disabled(model.disabled)
        }
    }

    /// Disabled while what it switches loads (the review's Local | PR), the picker dims as a
    /// fade, pill and labels together, however `disabled` changed.
    @Test func aDisabledSegmentedPickerFadesItsSegmentsAndPill() async {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 300, height: 48), dark: false, LoadingPicker(model: model))
        defer { window.close() }
        let strip = CGRect(x: 0, y: Picker.inset + NW.Space.xxs + 12, width: 300, height: 1)
        let recording = await MotionProbe.record(window, region: strip) { model.disabled = true }

        #expect(!recording.settled.matches(recording.before), "the picker dimmed")
        #expect(!recording.inBetween.isEmpty, "it fades in \(recording.frames.count) frames")
    }

    // MARK: Switch

    private struct Switch: View {
        let model: Model

        var body: some View {
            Toggle("Switch", isOn: Binding(get: { model.on }, set: { model.on = $0 }))
                .labelsHidden()
                .toggleStyle(.nwSwitch)
                .padding(10)
                .frame(width: 80, height: 40, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// Turned on however (here, from the model), the knob slides across rather than jumping.
    @Test func aSwitchSlidesItsKnobAcross() async {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 80, height: 40), dark: true, Switch(model: model))
        defer { window.close() }
        // Through the knob's middle. In dark, the knob is the only light thing on the strip.
        let strip = CGRect(x: 0, y: 19, width: 80, height: 1)
        let recording = await MotionProbe.record(window, region: strip) { model.on = true }

        let start = recording.before.knobCenter, end = recording.settled.knobCenter
        let centers = recording.inBetween.compactMap(\.knobCenter)
        #expect(start != nil && end != nil && end! > start! + 8, "the knob moved from \(String(describing: start)) to \(String(describing: end))")
        #expect(centers.contains { $0 > start! + 2 && $0 < end! - 2 }, "caught mid-slide: \(centers)")
        #expect(centers == centers.sorted(), "it only moves toward rest: \(centers)")
    }

    // MARK: Enabled and disabled

    private struct StartButton: View {
        let model: Model

        var body: some View {
            Button(model.disabled ? "Go" : "Start the agent") {}
                .buttonStyle(.nw(.primary))
                .disabled(model.disabled)
                .padding(10)
                .frame(width: 200, height: 50, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// Disabling fades the button to 40%, while its new, shorter label takes its width at once:
    /// only the opacity animates.
    @Test func aDisabledButtonFadesWhileItsLabelChangesAtOnce() async throws {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 200, height: 50), dark: false, StartButton(model: model))
        defer { window.close() }
        // Across the button's middle; x 13 is lantern fill left of the label.
        let strip = CGRect(x: 0, y: 24, width: 200, height: 1)
        let recording = await MotionProbe.record(window, region: strip) { model.disabled = true }

        let enabled = recording.before.lightness(x: 13), disabled = recording.settled.lightness(x: 13)
        #expect(disabled > enabled + 0.1, "disabled is fainter: \(enabled) → \(disabled)")
        #expect(recording.inBetween.contains { (enabled + 0.03..<disabled - 0.03).contains($0.lightness(x: 13)) },
                "caught mid-fade")
        let before = try #require(recording.before.fillEnd), after = try #require(recording.settled.fillEnd)
        #expect(after < before - 20, "the label got shorter: \(before) → \(after)")
        let ends = recording.frames.dropFirst().compactMap(\.fillEnd)
        #expect(ends.allSatisfy { $0 == before || $0 == after }, "the width never eases: \(ends)")
    }

    // MARK: Status pill

    private struct Pill: View {
        let model: Model

        var body: some View {
            NWStatusPill(model.state, label: model.label)
                .padding(10)
                .frame(width: 200, height: 40, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// An elapsed time ticking in the label lands at once; a new state fades in.
    @Test func aStatusPillFadesToANewStateButTicksAtOnce() async {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 200, height: 40), dark: false, Pill(model: model))
        defer { window.close() }
        let strip = CGRect(x: 0, y: 20, width: 200, height: 1)

        let tick = await MotionProbe.record(window, region: strip, timeout: 1) { model.label = "Running · 0:02" }
        #expect(!tick.settled.matches(tick.before), "the tick showed")
        #expect(tick.inBetween.isEmpty, "a tick never animates")

        let done = await MotionProbe.record(window, region: strip) {
            model.state = .done
            model.label = "Done"
        }
        #expect(!done.inBetween.isEmpty, "a new state fades in")
    }

    // MARK: Toast

    private struct ToastHost: View {
        let model: Model

        var body: some View {
            Color.nw.bgWindow
                .frame(width: 420, height: 140)
                .nwToast(item: Binding(get: { model.toast }, set: { model.toast = $0 }))
        }
    }

    /// A toast rises from the bottom edge as it fades in; under Reduce Motion it only fades,
    /// in place.
    @Test(arguments: [false, true])
    func aToastRisesFromTheBottomUnlessReduceMotion(reduceMotion: Bool) async throws {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 420, height: 140), dark: false,
                                     ToastHost(model: model).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        // A column through the toast, left of its text.
        let strip = CGRect(x: 420 - NW.Space.xl - 150, y: 0, width: 1, height: 140)
        let recording = await MotionProbe.record(window, region: strip) {
            model.toast = NWToast(.done, subject: "worker", message: "finished · 5 files")
        }

        let rest = try #require(recording.settled.centroid(differingFrom: recording.before))
        let centroids = recording.inBetween.compactMap { $0.centroid(differingFrom: recording.before, minimumMass: 0.5) }
        #expect(!centroids.isEmpty, "caught arriving in \(recording.frames.count) frames")
        if reduceMotion {
            #expect(centroids.allSatisfy { abs($0 - rest) < 5 }, "it fades where it rests (\(rest)): \(centroids)")
        } else {
            #expect(centroids.contains { $0 > rest + 15 }, "it rises from below \(rest): \(centroids)")
        }
    }

    // MARK: Switching agents

    /// The toolbar belongs to whichever agent is selected, so switching hands its controls another
    /// agent's state. That lands at once (switching is a visibility flip), while the same pane
    /// toggle still fades when its pane opens (⇧⌘B, the menu, the palette all go through
    /// `openUserReview`).
    @Test func anotherAgentsToolbarLandsAtOnceButAToggleFadesWhenItsPaneOpens() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agents = ["one", "two"].enumerated().map { Fixture.agent($1, in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let (one, two) = (agents[0].agent.id, agents[1].agent.id)
        vm.selectAgent(two)
        vm.openReview(agentID: two, path: nil)
        vm.selectAgent(one)
        let size = CGSize(width: 900, height: 44)
        let window = OffscreenWindow(size: size, dark: false, WorkspaceHeaderView(vm: vm).frame(width: size.width, height: size.height))
        defer { window.close() }
        // Across the title, the status pill and the pane toggles.
        let strip = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)

        let toTwo = await MotionProbe.record(window, region: strip, timeout: 1) { vm.selectAgent(two) }
        #expect(vm.isReviewPaneShowing)
        #expect(!toTwo.settled.matches(toTwo.before), "agent two's toolbar showed")
        #expect(toTwo.inBetween.isEmpty, "switching never animates the toolbar")
        let toOne = await MotionProbe.record(window, region: strip, timeout: 1) { vm.selectAgent(one) }
        #expect(toOne.inBetween.isEmpty, "nor does switching back")
        let riding = await MotionProbe.record(window, region: strip, timeout: 1) {
            withNWAnimation(.overlay) { vm.selectAgent(two) }
        }
        #expect(riding.inBetween.isEmpty, "nor a switch that rides an animation (the palette closing)")
        vm.selectAgent(one)

        let opening = await MotionProbe.record(window, region: strip) { vm.openUserReview() }
        #expect(vm.isReviewPaneShowing)
        #expect(!opening.inBetween.isEmpty, "the review toggle lights up as a fade")
    }

    // MARK: Slider

    private struct Slider: View {
        let model: Model

        var body: some View {
            NWValueSlider("Density", value: Binding(get: { model.value }, set: { model.value = $0 }), in: 0...1, step: 0.05,
                          neutral: 0.5) { "\(Int(($0 * 100).rounded()))%" }
                .padding(10)
                .frame(width: 300, height: 36, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// A slider follows its value at once (a drag, an arrow key, the setting changed elsewhere):
    /// only double-clicking its value to reset it animates.
    @Test func aSliderTracksItsValueAtOnce() async {
        let model = Model()
        let window = OffscreenWindow(size: CGSize(width: 300, height: 36), dark: false, Slider(model: model))
        defer { window.close() }
        let strip = CGRect(x: 0, y: 18, width: 300, height: 1)
        let recording = await MotionProbe.record(window, region: strip, timeout: 1) { model.value = 0.8 }

        #expect(!recording.settled.matches(recording.before), "the knob moved")
        #expect(recording.inBetween.isEmpty)
    }
}

/// Settings and the sheets, on isolated preferences: a page picked in the nav cross-fades,
/// search lands on a page at once, a conditional row discloses as its card grows, a sheet keeps
/// its title still while it grows, and a failed Finalize check reveals its remedy as the list
/// makes room.
@Suite("Settings and dialog motion", .mainActorExclusive)
@MainActor
struct SettingsMotionTests {
    private static let window = CGSize(width: 1100, height: 700)
    /// Across the page title in the content column, clear of the nav and its search field.
    private static let titleStrip = CGRect(x: 300, y: 60, width: 500, height: 1)

    @Test func pickingASettingsPageCrossFadesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.settingsSection = .agents
        let window = OffscreenWindow(size: Self.window, dark: false, SettingsView(vm: vm))
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: Self.titleStrip) { vm.settingsSection = .worktrees }

        #expect(!recording.settled.matches(recording.before), "the page changed")
        #expect(!recording.inBetween.isEmpty, "the pages cross-fade")
    }

    /// Typing in the search field follows the matches: the page switches with each keystroke,
    /// never through a cross-fade.
    @Test func searchingLandsOnAMatchingPageAtOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        vm.settingsSection = .agents
        let window = OffscreenWindow(size: Self.window, dark: false, SettingsView(vm: vm))
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: Self.titleStrip, timeout: 1) {
            SettingsView.showFirstMatch(of: [.keyboard], in: vm)
        }

        #expect(vm.settingsSection == .keyboard)
        #expect(!recording.settled.matches(recording.before), "the page changed")
        #expect(recording.inBetween.isEmpty)
    }

    /// Settings replaces the window content as a cross-fade however `showSettings` changes: here
    /// a plain view-model mutation, as the palette's Settings item makes, both ways. Under Reduce
    /// Motion it is still a (shorter) cross-fade.
    @Test(arguments: [false, true])
    func settingsCrossFadesInAndOutHoweverItOpens(reduceMotion: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let window = OffscreenWindow(size: Self.window, dark: false,
                                     RootView(vm: vm).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        let strip = CGRect(x: 0, y: Self.window.height / 2, width: Self.window.width, height: 1)

        let opening = await MotionProbe.record(window, region: strip) { vm.showSettings = true }
        #expect(!opening.settled.matches(opening.before), "Settings showed")
        #expect(!opening.inBetween.isEmpty, "it cross-fades in")
        let closing = await MotionProbe.record(window, region: strip) { vm.showSettings = false }
        #expect(closing.settled.matches(opening.before), "the workspace is back")
        #expect(!closing.inBetween.isEmpty, "it cross-fades out")
    }

    /// Merge PR automatically reveals the merge method: the card grows and the footnote under it
    /// moves down through the frames between, cross-fading under Reduce Motion but never jumping.
    @Test(arguments: [false, true])
    func turningOnAutoMergeDisclosesTheMergeMethodRow(reduceMotion: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.worktreeAutoMergePR = false
        let size = CGSize(width: 760, height: 900)
        let window = OffscreenWindow(size: size, dark: false,
                                     WorktreeSettings(settings: app.settings)
                                         .padding(20)
                                         .frame(width: size.width, height: size.height, alignment: .topLeading)
                                         .background(Color.nw.bgWindow)
                                         .environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        // A column through the rows' titles and the footnote under the card.
        let strip = CGRect(x: 60, y: 0, width: 1, height: size.height)
        let recording = await MotionProbe.record(window, region: strip) { app.settings.worktreeAutoMergePR = true }

        let rest = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let edges = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(edges.contains { $0 < rest - 10 }, "caught growing toward \(rest): \(edges)")
        #expect(edges == edges.sorted(), "it only grows: \(edges)")
    }

    @MainActor @Observable
    final class SheetModel {
        var open = false
    }

    /// A stand-in dialog whose banner arrives late, like Delete Worktree Agent's warning.
    private struct GrowingDialog: View {
        let model: SheetModel

        var body: some View {
            NWDialog("Delete worktree agent", message: "Stops the agent.") {
                SheetRow("Worktree") { Text("~/Developer/shepherd-fix-login") }
                if model.open {
                    DialogBanner(title: "Unreconciled work", message: "2 uncommitted files will be lost with the worktree.")
                }
            } actions: {
                Button("Delete") {}.buttonStyle(.nw(.dangerFill))
            }
            .nwAnimation(.disclosure, value: model.open)
        }
    }

    /// A hosting view sizes its window to the dialog at once, as SwiftUI does a sheet's, while
    /// the rows inside ease to their places. The dialog stays pinned to the window meanwhile:
    /// its title never moves while the banner discloses under it.
    @Test func aSheetKeepsItsTitleStillWhileARowDiscloses() async throws {
        let model = SheetModel()
        let closed = NSHostingView(rootView: GrowingDialog(model: model).dialogSheetFrame()).fittingSize
        let window = OffscreenWindow(size: closed, dark: false, GrowingDialog(model: model).dialogSheetFrame())
        defer { window.close() }
        let title = CGRect(x: 0, y: NWDialogMetrics.inset + 8, width: closed.width, height: 1)
        let still = await MotionProbe.record(window, region: title, timeout: 1) { model.open = true }

        #expect(window.host.bounds.height > closed.height + 20, "the window grew to the banner")
        #expect(still.frames.allSatisfy { $0.matches(still.before) }, "the title never moves")

        _ = await MotionProbe.record(window) { model.open = false }
        let column = CGRect(x: NWDialogMetrics.inset + 4, y: 0, width: 1, height: closed.height)
        let growth = await MotionProbe.record(window, region: column) { model.open = true }
        #expect(!growth.inBetween.isEmpty, "the banner discloses in steps")
    }

    /// A failed prerequisite grows its remedy in place: the checks under it move down through
    /// the frames between instead of jumping.
    @Test func aFailedSetupCheckGrowsItsRemedyAsTheListMakesRoom() async throws {
        let model = WorktreeSetupModel(repoPath: "/tmp/repo")
        model.remoteAction = { _ in
            RemoteWorktreeSetup(repoPath: "/tmp/repo",
                                checks: ["git": .pass("git 2.50"), "identity": .fail("user.email not set"),
                                         "remote": .pass("origin"), "gh": .pass("gh 2.80"), "ghAuth": .pass("signed in")],
                                repoSettings: [:])
        }
        let size = CGSize(width: 620, height: 520)
        let window = OffscreenWindow(size: size, dark: false,
                                     WorktreeSetupChecklist(model: model) {}
                                         .frame(width: size.width, height: size.height, alignment: .top)
                                         .background(Color.nw.bgWindow))
        defer { window.close() }
        // A column through the check titles and the section below them.
        let strip = CGRect(x: NWDialogMetrics.inset + 30, y: 0, width: 1, height: size.height)
        let recording = await MotionProbe.record(window, region: strip) { Task { await model.runAll() } }

        #expect(model.states[.identity] == .fail("user.email not set"))
        let rest = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let edges = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(edges.contains { $0 < rest - 10 }, "caught making room toward \(rest): \(edges)")
    }
}

// MARK: Reading strips

fileprivate extension MotionRecording.Frame {
    /// Lightness along a one-pixel strip, a row or a column.
    var profile: [Double] {
        bitmap.pixelsHigh == 1
            ? (0..<bitmap.pixelsWide).map { lightness(x: $0, y: 0) }
            : (0..<bitmap.pixelsHigh).map { lightness(x: 0, y: $0) }
    }

    func differs(from other: Self, at index: Int, by threshold: Double = 0.01) -> Bool {
        let (x, y) = bitmap.pixelsHigh == 1 ? (index, 0) : (0, index)
        return abs(lightness(x: x, y: y) - other.lightness(x: x, y: y)) > threshold
    }

    /// Where along the strip this frame differs from `other`, as runs of neighbouring pixels.
    func runs(differingFrom other: Self, threshold: Double = 0.01) -> [ClosedRange<Int>] {
        let a = profile, b = other.profile
        var runs: [ClosedRange<Int>] = []
        for index in a.indices where abs(a[index] - b[index]) > threshold {
            if let last = runs.last, last.upperBound >= index - 2 {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        return runs
    }

    /// Along the strip, the middle of what differs from `other`, weighted by how much: a view
    /// fading in place keeps it still, one moving carries it along. Nil for too faint a change.
    func centroid(differingFrom other: Self, minimumMass: Double = 0.05) -> Double? {
        let a = profile, b = other.profile
        var mass = 0.0, moment = 0.0
        for index in a.indices {
            let difference = abs(a[index] - b[index])
            mass += difference
            moment += difference * Double(index)
        }
        return mass >= minimumMass ? moment / mass : nil
    }

    /// The middle of the light pixels on the strip: a switch's knob on a dark window.
    var knobCenter: Double? {
        let values = profile
        let light = values.indices.filter { values[$0] > 0.7 }
        return light.isEmpty ? nil : Double(light.reduce(0, +)) / Double(light.count)
    }

    /// The last pixel of a filled button on a light window.
    var fillEnd: Int? {
        let values = profile
        return values.indices.last { values[$0] < 0.95 }
    }
}
