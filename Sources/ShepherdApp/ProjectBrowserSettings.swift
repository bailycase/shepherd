import SwiftUI
import ShepherdUI

struct ProjectBrowserSettings: View {
    @Bindable var model: ProjectCookiesModel
    let project: ProjectsRow
    let scope: ProjectCookieScope?

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SpaceSection(title: "Browser cookies", lead: "Browser tabs in all threads and worktrees for \(project.project.name) share cookies on this Mac. Other spaces use separate cookies.",
                         footnote: "Cookies stay in Shepherd on this Mac, not in your repository. Cookie values are never shown here. Clearing cookies leaves local storage and cache unchanged.") {
                Text("This Mac only").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            } content: {
                if let error = model.error {
                    HStack(spacing: AppLayout.spaceControlGap) {
                        Text(error).font(.sh(.ui)).foregroundStyle(Color.sh.failed).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Try again") { Task { await model.load(scope, force: true) } }.buttonStyle(SpaceLinkStyle(tone: .strong)).disabled(model.clearing)
                    }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.l)
                }
                toolbar
                if scope == nil || model.loading || model.visible.isEmpty { empty }
                else {
                    ForEach(model.visible) { site in row(site) }
                }
            }.accessibilityLabel("Sites with cookies")
            if let notice = model.notice {
                Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.done).padding(.horizontal, SH.Space.xs)
                    .accessibilityIdentifier("Space cookie status")
            }
        }.disabled(model.pending != nil || model.clearing).accessibilityHidden(model.pending != nil)
            .onDisappear { model.invalidateForDisappear() }
            .task(id: scope) {
                if model.scope == scope, model.pending != nil { return }
                await model.load(scope, force: true)
            }
    }

    /// The filter row inside the card (`gspc-filter`): search, how many sites and cookies, then Clear all cookies….
    private var toolbar: some View {
        HStack(spacing: SH.Space.l) {
            SpaceSearchField(prompt: "Filter sites", text: $model.filter).disabled(model.clearing || scope == nil)
            Spacer(minLength: 0)
            Text(model.countText).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).fixedSize()
            dangerAction("Clear all cookies…", label: "Clear all cookies") { model.ask(.all) }
                .disabled(scope == nil || model.loading || model.clearing || model.error != nil || model.sites.isEmpty)
        }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceFilterHeight)
    }

    private func row(_ site: BrowserCookieSite) -> some View {
        HStack(spacing: AppLayout.spaceControlGap) {
            Text(site.site).font(.sh(.ui).monospaced()).foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1).truncationMode(.tail).help(site.site).frame(maxWidth: .infinity, alignment: .leading)
            Text(site.count.formatted()).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).monospacedDigit()
                .frame(width: AppLayout.spaceCookieCountWidth, alignment: .trailing)
            dangerAction("Clear cookies…", label: "Clear cookies for \(site.site)") { model.ask(.site(site.site)) }
                .frame(width: AppLayout.spaceCookieActionWidth, alignment: .trailing).disabled(model.loading || model.clearing || model.error != nil)
        }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceRowMinHeight)
    }

    private var empty: some View {
        SpaceEmpty(scope == nil || model.error != nil ? "Space cookies unavailable" : model.loading ? "Loading cookies…" : model.sites.isEmpty ? "No cookies yet" : "No matching sites",
                   message: scope == nil ? "Add this folder as a space to manage its browser cookies on this Mac." : model.error != nil ? "Reopen Browser to refresh this space's cookie store." : model.loading ? "Reading this space's browser store on this Mac." : model.sites.isEmpty ? "Sites will appear here after you use this space's Browser tabs." : "Try a different site name.")
    }

    private func dangerAction(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action).buttonStyle(SpaceLinkStyle(tone: .danger)).accessibilityLabel(label)
    }

    func confirmation(_ removal: ProjectCookiesModel.Removal) -> some View {
        ZStack {
            Color.sh.projectCookieShade
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                HStack(alignment: .top, spacing: SH.Space.l) {
                    Image(systemName: "exclamationmark.triangle").font(.shSans(AppLayout.projectCookieConfirmTitle)).foregroundStyle(Color.sh.failed)
                        .accessibilityHidden(true)
                    Text(removal == .all ? "Clear all space cookies?" : "Clear cookies for this site?")
                        .font(.shSans(AppLayout.projectCookieConfirmTitle, .semibold)).foregroundStyle(Color.sh.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Browser tabs in this space's threads and worktrees may be signed out. Other spaces are unaffected. Local storage and cache remain unchanged.")
                    .font(.shSans(AppLayout.projectsNameSize)).foregroundStyle(Color.sh.textSecondary)
                    .lineSpacing(AppLayout.projectCookieConfirmLineExtra * ThemeStore.shared.textScale)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text(project.project.name).font(.shSans(SHSettingsNavMetrics.subTextSize, .medium))
                    Text("This Mac only").font(.shSans(SHSettingsNavMetrics.subTextSize))
                    if case .site(let site) = removal { Text(site).font(.shMono(AppLayout.projectFileSize)).lineLimit(2) }
                }.foregroundStyle(Color.sh.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SH.Space.xl).padding(.vertical, SH.Space.l)
                    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                HStack(spacing: SH.Space.m) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.pending = nil }.buttonStyle(SHSettingsActionStyle(.cancel)).keyboardShortcut(.cancelAction).disabled(model.clearing)
                    Button(model.clearing ? "Clearing…" : "Clear cookies") { Task { await model.confirm(scope) } }.buttonStyle(SHSettingsActionStyle(.confirm)).disabled(model.clearing)
                }.padding(.top, SH.Space.xs)
            }.padding(SH.Space.xxl + SHSettingsNavMetrics.borderWidth).frame(maxWidth: AppLayout.projectCookieConfirmWidth)
                .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SH.Radius.l))
                .shBorder(Color.sh.lineStrong, radius: SH.Radius.l, width: SHSettingsNavMetrics.borderWidth)
                .shadow(color: Color.sh.bgBase, radius: SH.Space.xxxl, y: SH.Space.xl)
                .padding(SH.Space.xxxl)
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityLabel("Confirm cookie clearing")
    }
}
