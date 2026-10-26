import SwiftUI
import ShepherdUI

struct ProjectBrowserSettings: View {
    @Bindable var model: ProjectCookiesModel
    let project: ProjectsRow
    let scope: ProjectCookieScope?

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxl) {
            intro
            toolbar
            if let error = model.error {
                HStack(spacing: SH.Space.l) {
                    Text(error).font(.shSans(AppLayout.projectTabSize)).foregroundStyle(Color.sh.textPrimary)
                    Spacer(minLength: SH.Space.l)
                    Button("Try again") { Task { await model.load(scope, force: true) } }.buttonStyle(SHSettingsActionStyle(.cancel)).disabled(model.clearing)
                }.padding(.vertical, SH.Space.l).padding(.horizontal, SH.Space.xl)
                    .background(Color.sh.failedTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(Color.sh.failed, radius: SH.Radius.m, width: SHSettingsNavMetrics.borderWidth)
            }
            table
            footer
            if let notice = model.notice {
                Text(notice).font(.shSans(AppLayout.projectTabSize)).foregroundStyle(Color.sh.done)
                    .accessibilityIdentifier("Space cookie status")
            }
        }.disabled(model.pending != nil || model.clearing).accessibilityHidden(model.pending != nil)
            .onDisappear { model.invalidateForDisappear() }
            .task(id: scope) {
                if model.scope == scope, model.pending != nil { return }
                await model.load(scope, force: true)
            }
    }

    private var intro: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                description
                Spacer(minLength: 0)
                localBadge
            }
            VStack(alignment: .leading, spacing: SH.Space.l) { description; localBadge }
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            Text("Browser cookies").font(.shSans(AppLayout.projectBrowserTitleSize, .semibold)).foregroundStyle(Color.sh.textPrimary)
                .frame(height: AppLayout.projectBrowserTitleLine * ThemeStore.shared.textScale)
                .offset(y: AppLayout.projectCookieTitleBaseline * ThemeStore.shared.textScale)
                .accessibilityAddTraits(.isHeader)
            Text("Browser tabs in all threads and worktrees for \(project.project.name) share cookies on this Mac. Other spaces use separate cookies.")
                .font(.shSans(AppLayout.projectsNameSize)).lineSpacing(AppLayout.projectCookieLineExtra * ThemeStore.shared.textScale)
                .padding(.vertical, AppLayout.projectCookieParagraphInset * ThemeStore.shared.textScale)
                .offset(y: AppLayout.projectCookieTextBaseline * ThemeStore.shared.textScale)
                .foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: AppLayout.projectBrowserDescriptionWidth, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localBadge: some View {
        HStack(spacing: SH.Space.s) {
            SHGlyph.Settings.computer.image.accessibilityHidden(true)
            Text("This Mac only").font(.shSans(AppLayout.projectsPathSize))
        }.foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.m).padding(.vertical, SH.Space.s).padding(SHSettingsNavMetrics.borderWidth)
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s, width: SHSettingsNavMetrics.borderWidth).fixedSize()
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.l) {
                filter
                counts
                Spacer(minLength: SH.Space.m)
                clearAll
            }
            VStack(alignment: .leading, spacing: SH.Space.l) {
                filter
                HStack { counts; Spacer(minLength: SH.Space.m); clearAll }
            }
        }
    }

    private var filter: some View {
        SHSettingsSearchField("Filter sites", text: $model.filter, placement: .sites)
            .frame(width: AppLayout.projectCookieFilterWidth)
            .disabled(model.clearing || scope == nil)
    }
    private var counts: some View {
        Text(model.countText).font(.shSans(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.textSecondary).fixedSize()
    }
    private var clearAll: some View {
        dangerAction("Clear all cookies…", label: "Clear all cookies") { model.ask(.all) }
            .disabled(scope == nil || model.loading || model.clearing || model.error != nil || model.sites.isEmpty)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.xl) {
                Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cookies").frame(width: AppLayout.projectCookieCountWidth, alignment: .trailing)
                Color.clear.frame(width: AppLayout.projectCookieActionsWidth)
            }.font(.shSans(AppLayout.projectsPathSize)).foregroundStyle(Color.sh.textSecondary)
                .offset(y: AppLayout.projectCookieHeaderBaseline * ThemeStore.shared.textScale)
                .padding(.horizontal, SH.Space.xl).frame(height: AppLayout.projectCookieHeaderHeight).background(Color.sh.projectEditorBackground)
            SHHairline(width: SHSettingsNavMetrics.borderWidth)
            if scope == nil || model.loading || model.visible.isEmpty { empty }
            else {
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { site in
                        VStack(spacing: 0) {
                            row(site)
                            if site.id != model.visible.last?.id { SHHairline(width: SHSettingsNavMetrics.borderWidth) }
                        }
                    }
                }
            }
        }.padding(AppLayout.projectCookieBorderInset)
            .background(Color.sh.bgWindow)
            .clipShape(RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius))
            .shBorder(Color.sh.lineStrong, radius: SHCardRowMetrics.settingsCardRadius, width: SHSettingsNavMetrics.borderWidth)
            .accessibilityElement(children: .contain).accessibilityLabel("Sites with cookies")
    }

    private func row(_ site: BrowserCookieSite) -> some View {
        HStack(spacing: SH.Space.xl) {
            HStack(spacing: SH.Space.l) {
                SHGlyph.Settings.globe.image
                    .foregroundStyle(Color.sh.textSecondary)
                    .frame(width: AppLayout.projectCookieIconSize, height: AppLayout.projectCookieIconSize)
                    .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s)).accessibilityHidden(true)
                Text(site.site).font(.shMono(AppLayout.projectTabSize)).foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1).truncationMode(.tail).help(site.site)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(site.count.formatted()).font(.shMono(AppLayout.projectFileSize)).foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.projectCookieCountWidth, alignment: .trailing)
            dangerAction("Clear cookies…", label: "Clear cookies for \(site.site)") { model.ask(.site(site.site)) }
                .frame(width: AppLayout.projectCookieActionsWidth, alignment: .trailing).disabled(model.loading || model.clearing || model.error != nil)
        }.padding(.horizontal, SH.Space.xl).frame(minHeight: AppLayout.projectCookieRowHeight)
    }

    private var empty: some View {
        VStack(spacing: SH.Space.m) {
            SHGlyph.Settings.globe.image.foregroundStyle(Color.sh.textTertiary)
                .accessibilityHidden(true)
            Text(scope == nil || model.error != nil ? "Space cookies unavailable" : model.loading ? "Loading cookies…" : model.sites.isEmpty ? "No cookies yet" : "No matching sites")
                .font(.shSans(SHTextStyle.title.size, .semibold)).foregroundStyle(Color.sh.textPrimary)
                .padding(.top, SH.Space.m)
            Text(scope == nil ? "Add this folder as a space to manage its browser cookies on this Mac." : model.error != nil ? "Reopen Browser to refresh this space's cookie store." : model.loading ? "Reading this space's browser store on this Mac." : model.sites.isEmpty ? "Sites will appear here after you use this space's Browser tabs." : "Try a different site name.")
                .font(.shSans(AppLayout.projectTabSize)).foregroundStyle(Color.sh.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: AppLayout.projectCookieEmptyCopyWidth)
                .lineSpacing(AppLayout.projectCookieEmptyLineExtra * ThemeStore.shared.textScale)
        }.padding(SH.Space.xxxl).frame(maxWidth: .infinity, minHeight: AppLayout.projectCookieEmptyHeight)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: SH.Space.m) {
            SHGlyph.Settings.lock.image.padding(.top, SH.Space.xxs).accessibilityHidden(true)
            Text("Cookies stay in Shepherd on this Mac, not in your repository. Cookie values are never shown here.\nClearing cookies leaves local storage and cache unchanged.")
                .font(.shSans(AppLayout.projectsPathSize)).lineSpacing(AppLayout.projectCookieFooterLineExtra * ThemeStore.shared.textScale)
                .padding(.vertical, AppLayout.projectCookieFooterInset * ThemeStore.shared.textScale)
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Color.sh.textSecondary)
    }

    private func dangerAction(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action).buttonStyle(SHSettingsActionStyle(.quietDanger)).accessibilityLabel(label)
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
