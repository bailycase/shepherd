import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Finalize a worktree agent, presented over the review (the Mac's remote Finalize sheet): the
/// host's checks, the pull request's base, title and description with what cleanup does, then
/// the host's steps as it runs them, and the pull request it opened. Nothing is removed on the
/// host before its clean gate, and a failed step stops everything after it.
struct FinalizeScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let store = ReviewStores.shared.store(for: ref).finalize
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                Text(intro(store, hostName: host?.name ?? "the host"))
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch store.stage {
                case .checking:
                    HStack(spacing: NW.Space.m) {
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                        Text("Checking git, origin and the GitHub CLI…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: NW.Height.touch * 2)
                case .setup:
                    FinalizeChecks(checks: store.checks)
                    Text("Fix what failed on \(host?.name ?? "the host"), then check again.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                case .form:
                    FinalizeForm(store: store, branch: agent?.worktreeBranch)
                case .operation:
                    FinalizeProgress(store: store)
                }
                if let error = store.error {
                    NWBanner(.failed, title: store.stage == .operation ? "Outcome not yet known" : "Request failed", message: error)
                }
            }
            .padding(MobileLayout.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.nw.bgBase)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions(store) }
        .navigationTitle(title(store))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { navigator.dismissPresented() }
            }
        }
        .task { await store.begin(hosts: hosts) }
        .task(id: store.operationID) { await store.poll(hosts: hosts) }
    }

    private func title(_ store: FinalizeStore) -> String {
        switch store.outcome {
        case .succeeded?: "Worktree finalized"
        case .failed?: "Finalize stopped"
        default: store.stage == .setup ? "Set up Finalize" : "Finalize worktree"
        }
    }

    private func intro(_ store: FinalizeStore, hostName: String) -> String {
        switch store.outcome {
        case .succeeded?: return "The pull request is open and the worktree is cleaned up on \(hostName). The agent is gone with it."
        case .failed?: return "A step failed, so the pipeline stopped. Your work is intact on \(hostName). Fix the issue there and finalize again."
        case .running?: return "Running on \(hostName). Each step must succeed before the next, and nothing is deleted until the worktree is verified clean."
        case nil: return "Runs on \(hostName): commit, push, pull request, optional merge, then cleanup. The remote branch is never deleted."
        }
    }

    @ViewBuilder private func actions(_ store: FinalizeStore) -> some View {
        VStack(spacing: NW.Space.s) {
            switch store.stage {
            case .checking:
                EmptyView()
            case .setup:
                Button("Check again") { Task { await store.begin(hosts: hosts) } }
                    .buttonStyle(.nwReviewBar(.secondary))
            case .form:
                if let problem = store.formProblem {
                    Text(problem).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
                Button("Finalize") { Task { await store.start(hosts: hosts) } }
                    .buttonStyle(.nwReviewBar(.primary))
                    .disabled(!store.canFinalize)
            case .operation:
                if store.operation?.finished == true {
                    Button("Done") {
                        let succeeded = store.outcome.map { if case .succeeded = $0 { true } else { false } } ?? false
                        store.reset()
                        navigator.dismissPresented()
                        // The host retired the agent with its worktree: nothing of it is left to show.
                        if succeeded { navigator.popToRoot() }
                    }
                    .buttonStyle(.nwReviewBar(.primary))
                } else {
                    Text("The operation continues on the host if you close this.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.top, NW.Space.l)
        .padding(.bottom, NW.Space.s)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }
}

/// The host's checks, each passing or with why not.
private struct FinalizeChecks: View {
    let checks: [FinalizeCheckRow]

    var body: some View {
        NWGroupCard {
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: NW.Space.m) {
                    NWStateGlyph(state(check.state)).padding(.top, NW.Space.xxs)
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(check.label).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                        if let detail = detail(check.state) {
                            Text(detail).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, NW.Space.xl)
                .padding(.vertical, NW.Space.l)
                .frame(minHeight: NW.Height.touch)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func state(_ check: RemoteWorktreeCheckState) -> AgentState {
        switch check {
        case .pending: .queued
        case .checking: .running
        case .pass: .done
        case .fail: .failed
        }
    }

    private func detail(_ check: RemoteWorktreeCheckState) -> String? {
        switch check {
        case .pass(let text), .fail(let text): text.isEmpty ? nil : text
        case .pending, .checking: nil
        }
    }
}

/// The pull request's base, title and description, and what cleanup does.
private struct FinalizeForm: View {
    @Bindable var store: FinalizeStore
    let branch: String?
    @Environment(MobileHosts.self) private var hosts
    @FocusState private var focused: Field?

    private enum Field { case base, title, body }

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            if let info = store.info {
                NWGroupCard {
                    FinalizeValueRow(label: "Worktree", value: info.path)
                    FinalizeValueRow(label: "Branch", value: info.branch)
                }
                if let warning = info.warning {
                    NWBanner(.attention, title: "Work not on the remote yet", message: "\(warning). Finalize commits and pushes it before any cleanup.")
                }
            }
            NWGroupCard {
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    Text("Base").font(.nw(.caption)).foregroundStyle(nw.textSecondary)
                    TextField("Base branch", text: $store.options.base)
                        .font(.nw(.code))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .base)
                        .frame(minHeight: NW.Height.touch)
                    if let count = store.includedCommits {
                        Text("Will include \(nativeCount(count, "commit"))")
                            .font(.nw(.caption))
                            .foregroundStyle(count > finalizeCommitWarningCount ? nw.lanternText : nw.textTertiary)
                    }
                }
                .padding(.horizontal, NW.Space.xl)
                .padding(.vertical, NW.Space.m)
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    Text("Title").font(.nw(.caption)).foregroundStyle(nw.textSecondary)
                    TextField("Pull request title", text: $store.options.title, axis: .vertical)
                        .font(.nw(.ui, weight: .regular))
                        .focused($focused, equals: .title)
                        .frame(minHeight: NW.Height.touch)
                }
                .padding(.horizontal, NW.Space.xl)
                .padding(.vertical, NW.Space.m)
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    HStack {
                        Text("Description").font(.nw(.caption)).foregroundStyle(nw.textSecondary)
                        Spacer(minLength: NW.Space.s)
                        if store.generating {
                            Text("Drafting on the host…").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                        } else if store.info?.generateDescription == true {
                            Button(store.descriptionPrepared ? "Draft again" : "Draft") {
                                Task { await store.generateDescription(hosts: hosts, force: true) }
                            }
                            .buttonStyle(.nwLink(font: .nw(.caption)))
                            .nwTouchTarget(height: NW.Height.controlS)
                        }
                    }
                    TextField("What changed and why", text: $store.options.body, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.nw(.ui, weight: .regular))
                        .focused($focused, equals: .body)
                        .accessibilityLabel("Pull request description")
                }
                .padding(.horizontal, NW.Space.xl)
                .padding(.vertical, NW.Space.m)
            }
            .foregroundStyle(nw.textPrimary)
            .tint(nw.lantern)
            NWGroupCard {
                NWCardRow("Commit remaining work", description: "Uncommitted changes go into one commit titled like the PR.") {
                    Toggle("Commit remaining work", isOn: $store.options.autoCommit).toggleStyle(.nwSwitch).labelsHidden()
                }
                NWCardRow("Delete local branch", description: "After the worktree is removed. The remote branch stays.") {
                    Toggle("Delete local branch", isOn: $store.options.deleteLocalBranch).toggleStyle(.nwSwitch).labelsHidden()
                }
                NWCardRow("Merge PR automatically", description: "Auto-merge when the repository allows it, otherwise merge now.") {
                    Toggle("Merge PR automatically", isOn: $store.options.autoMergePR).toggleStyle(.nwSwitch).labelsHidden()
                }
                if store.options.autoMergePR {
                    NWCardRow("Method") {
                        Picker("Merge method", selection: $store.options.mergeMethod) {
                            Text("Squash").tag("squash")
                            Text("Merge").tag("merge")
                            Text("Rebase").tag("rebase")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }
        }
        .task(id: store.options.base) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.countCommits(hosts: hosts)
        }
    }
}

/// A label over a mono value that keeps both ends of a long path.
private struct FinalizeValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            Text(label).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            Text(value).font(.nw(.mono)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity, minHeight: NW.Height.touch, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The host's steps as it runs them, then the pull request.
private struct FinalizeProgress: View {
    let store: FinalizeStore

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
            if store.steps.isEmpty {
                HStack(spacing: NW.Space.m) {
                    ProgressView().progressViewStyle(NWSpinnerStyle())
                    Text("Starting on the host…").font(.nw(.ui)).foregroundStyle(Color.nw.textSecondary)
                }
            } else {
                NWGroupCard {
                    ForEach(store.steps) { step in
                        HStack(alignment: .top, spacing: NW.Space.m) {
                            NWStateGlyph(state(step.state)).padding(.top, NW.Space.xxs)
                            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                Text(step.label.prefix(1).uppercased() + step.label.dropFirst())
                                    .font(.nw(.ui)).foregroundStyle(step.state == .pending ? Color.nw.textTertiary : Color.nw.textPrimary)
                                if let detail = detail(step.state) {
                                    Text(detail).font(.nw(.caption))
                                        .foregroundStyle(isFailure(step.state) ? Color.nw.failed : Color.nw.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, NW.Space.xl)
                        .padding(.vertical, NW.Space.m)
                        .frame(minHeight: NW.Height.touch)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if case .failed(let message)? = store.outcome {
                NWBanner(.failed, title: "The host stopped the operation", message: message)
            }
            if let url = store.operation?.prURL, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url, systemImage: "arrow.up.forward.square")
                        .font(.nw(.mono))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minHeight: NW.Height.touch)
                }
                .foregroundStyle(Color.nw.running)
            }
        }
    }

    private func state(_ state: FinalizeStep.State) -> AgentState {
        switch state {
        case .pending: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    private func detail(_ state: FinalizeStep.State) -> String? {
        switch state {
        case .done(let text), .failed(let text): text.isEmpty ? nil : text
        case .pending, .running: nil
        }
    }

    private func isFailure(_ state: FinalizeStep.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
