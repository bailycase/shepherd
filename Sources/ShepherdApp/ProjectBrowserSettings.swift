import SwiftUI
import ShepherdUI

struct ProjectBrowserSettings: View {
    @Bindable var model: ProjectCookiesModel
    let project: ProjectsRow
    let scope: ProjectCookieScope?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NW.Space.xxl) {
                intro
                toolbar
                if let error = model.error {
                    HStack(spacing: NW.Space.l) {
                        Text(error).font(.nwSans(AppLayout.projectTabSize)).foregroundStyle(Color.nw.failed)
                        Spacer(minLength: NW.Space.l)
                        Button("Try again") { Task { await model.load(scope, force: true) } }.buttonStyle(.nw(.raised)).disabled(model.clearing)
                    }.padding(NW.Space.l).nwBorder(Color.nw.failed, radius: NW.Radius.m)
                }
                table
                footer
                if let notice = model.notice {
                    Text(notice).font(.nwSans(AppLayout.projectTabSize)).foregroundStyle(Color.nw.done)
                        .accessibilityIdentifier("Project cookie status")
                }
            }.padding(.bottom, NW.Space.xxl)
                .disabled(model.pending != nil || model.clearing).accessibilityHidden(model.pending != nil)
        }.scrollIndicators(.hidden)
            .onDisappear { model.invalidateForDisappear() }
            .task(id: scope) {
            if model.scope == scope, model.pending != nil { return }
            await model.load(scope, force: true)
        }
    }

    private var intro: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NW.Space.xxl) {
                description
                Spacer(minLength: 0)
                localBadge
            }
            VStack(alignment: .leading, spacing: NW.Space.l) { description; localBadge }
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text("Browser cookies").font(.nwSans(AppLayout.projectBrowserTitleSize, .semibold)).foregroundStyle(Color.nw.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Browser tabs in all threads and worktrees for \(project.project.name) share cookies on this Mac. Other projects use separate cookies.")
                .font(.nwSans(AppLayout.projectsNameSize)).lineSpacing(AppLayout.projectCookieLineExtra)
                .foregroundStyle(Color.nw.textSecondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: AppLayout.projectBrowserDescriptionWidth, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localBadge: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "desktopcomputer").font(.nwSans(AppLayout.projectFileSize)).accessibilityHidden(true)
            Text("This Mac only").font(.nwSans(AppLayout.projectsPathSize))
        }.foregroundStyle(Color.nw.textSecondary)
            .padding(.horizontal, NW.Space.m).padding(.vertical, NW.Space.s)
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.s).fixedSize()
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NW.Space.l) {
                filter
                counts
                Spacer(minLength: NW.Space.m)
                clearAll
            }
            VStack(alignment: .leading, spacing: NW.Space.l) {
                filter
                HStack { counts; Spacer(minLength: NW.Space.m); clearAll }
            }
        }
    }

    private var filter: some View {
        NWSearchField("Filter sites", text: $model.filter)
            .nwControlScale(.settings).frame(width: AppLayout.projectCookieFilterWidth)
            .disabled(model.clearing || scope == nil)
    }
    private var counts: some View {
        Text(model.countText).font(.nwSans(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textSecondary).fixedSize()
    }
    private var clearAll: some View {
        dangerAction("Clear all cookies…", label: "Clear all cookies") { model.ask(.all) }
            .disabled(scope == nil || model.loading || model.clearing || model.error != nil || model.sites.isEmpty)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.xl) {
                Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cookies").frame(width: AppLayout.projectCookieCountWidth, alignment: .trailing)
                Color.clear.frame(width: AppLayout.projectCookieActionsWidth)
            }.font(.nwSans(AppLayout.projectsPathSize)).foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.xl).frame(height: AppLayout.projectCookieHeaderHeight).background(Color.nw.projectEditorBackground)
            NWHairline()
            if scope == nil || model.loading || model.visible.isEmpty { empty }
            else {
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { site in
                        VStack(spacing: 0) {
                            row(site)
                            if site.id != model.visible.last?.id { NWHairline() }
                        }
                    }
                }
            }
        }.padding(AppLayout.projectCookieBorderInset)
            .background(Color.nw.bgWindow)
            .clipShape(RoundedRectangle(cornerRadius: NWCardRowMetrics.settingsCardRadius))
            .nwBorder(Color.nw.lineStrong, radius: NWCardRowMetrics.settingsCardRadius)
            .accessibilityElement(children: .contain).accessibilityLabel("Sites with cookies")
    }

    private func row(_ site: BrowserCookieSite) -> some View {
        HStack(spacing: NW.Space.xl) {
            HStack(spacing: NW.Space.l) {
                Image(systemName: "globe").font(.nwSans(AppLayout.projectCookieGlyphSize))
                    .foregroundStyle(Color.nw.textSecondary)
                    .frame(width: AppLayout.projectCookieIconSize, height: AppLayout.projectCookieIconSize)
                    .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s)).accessibilityHidden(true)
                Text(site.site).font(.nwMono(AppLayout.projectTabSize)).foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1).truncationMode(.tail).help(site.site)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(site.count.formatted()).font(.nwMono(AppLayout.projectFileSize)).foregroundStyle(Color.nw.textSecondary)
                .frame(width: AppLayout.projectCookieCountWidth, alignment: .trailing)
            dangerAction("Clear cookies…", label: "Clear cookies for \(site.site)") { model.ask(.site(site.site)) }
                .frame(width: AppLayout.projectCookieActionsWidth, alignment: .trailing).disabled(model.loading || model.clearing || model.error != nil)
        }.padding(.horizontal, NW.Space.xl).frame(minHeight: AppLayout.projectCookieRowHeight)
    }

    private var empty: some View {
        VStack(spacing: NW.Space.m) {
            Image(systemName: "globe").font(.nwSans(NWTextStyle.title.size)).foregroundStyle(Color.nw.textTertiary)
                .accessibilityHidden(true)
            Text(scope == nil || model.error != nil ? "Project cookies unavailable" : model.loading ? "Loading cookies…" : model.sites.isEmpty ? "No cookies yet" : "No matching sites")
                .font(.nwSans(NWTextStyle.title.size, .semibold)).foregroundStyle(Color.nw.textPrimary)
            Text(scope == nil ? "Add this folder as a project to manage its browser cookies on this Mac." : model.error != nil ? "Reopen Browser to refresh this project's cookie store." : model.loading ? "Reading this project's browser store on this Mac." : model.sites.isEmpty ? "Sites will appear here after you use this project's Browser tabs." : "Try a different site name.")
                .font(.nwSans(AppLayout.projectTabSize)).foregroundStyle(Color.nw.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(NW.Space.xxxl).frame(maxWidth: .infinity, minHeight: AppLayout.projectCookieEmptyHeight)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: NW.Space.m) {
            Image(systemName: "lock").font(.nwSans(AppLayout.projectCookieGlyphSize)).padding(.top, NW.Space.xxs).accessibilityHidden(true)
            Text("Cookies stay in Shepherd on this Mac, not in your repository. Cookie values are never shown here.\nClearing cookies leaves local storage and cache unchanged.")
                .font(.nwSans(AppLayout.projectsPathSize)).lineSpacing(AppLayout.projectCookieLineExtra)
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(Color.nw.textSecondary)
    }

    private func dangerAction(_ text: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.nwSans(AppLayout.projectsHostSize, .medium))
                .foregroundStyle(Color.nw.projectCookieDanger).padding(.horizontal, AppLayout.projectFilePadding)
                .frame(minHeight: AppLayout.projectCookieActionHeight).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    func confirmation(_ removal: ProjectCookiesModel.Removal) -> some View {
        ZStack {
            Color.nw.bgBase.opacity(AppLayout.projectCookieShadeOpacity)
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                HStack(alignment: .top, spacing: NW.Space.l) {
                    Image(systemName: "exclamationmark.triangle").font(.nwSans(AppLayout.projectCookieConfirmTitle)).foregroundStyle(Color.nw.failed)
                        .accessibilityHidden(true)
                    Text(removal == .all ? "Clear all project cookies?" : "Clear cookies for this site?")
                        .font(.nwSans(AppLayout.projectCookieConfirmTitle, .semibold)).foregroundStyle(Color.nw.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Browser tabs in this project's threads and worktrees may be signed out. Other projects are unaffected. Local storage and cache remain unchanged.")
                    .font(.nwSans(NWTextStyle.body.size)).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    Text(project.project.name).font(.nwSans(AppLayout.projectsHostSize, .medium))
                    Text("This Mac only").font(.nwSans(AppLayout.projectsHostSize))
                    if case .site(let site) = removal { Text(site).font(.nwMono(AppLayout.projectFileSize)).lineLimit(2) }
                }.foregroundStyle(Color.nw.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NW.Space.xl).padding(.vertical, NW.Space.l)
                    .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                HStack(spacing: NW.Space.m) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.pending = nil }.buttonStyle(.nw(.raised)).keyboardShortcut(.cancelAction).disabled(model.clearing)
                    Button(model.clearing ? "Clearing…" : "Clear cookies") { Task { await model.confirm(scope) } }.buttonStyle(.nw(.danger)).disabled(model.clearing)
                }.padding(.top, NW.Space.xs)
            }.padding(NW.Space.xxl).frame(maxWidth: AppLayout.projectCookieConfirmWidth)
                .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.l))
                .nwBorder(Color.nw.lineStrong, radius: NW.Radius.l)
                .padding(NW.Space.xxxl)
        }.accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityLabel("Confirm cookie clearing")
    }
}
