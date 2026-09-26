import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// Add an MCP server (SettingsMCPAdd, SettingsMCPLocal): Remote takes a URL and checks it as you
/// type ("answered · Streamable HTTP", "OAuth · found"); Local takes a command and its
/// environment, secrets going to Keychain; Paste JSON takes an `mcpServers` block. Edit… opens
/// the same sheet on an existing server.
struct AddMCPServerSheet: View {
    enum Kind: String, Hashable, CaseIterable { case remote, local, json }

    enum SignIn: Hashable { case oauth, header, none }

    /// What the URL check found.
    enum Check: Equatable {
        case idle
        case checking
        case answered(name: String?, transport: MCPTransportKind)
        case oauth(name: String?, provider: String, registers: Bool)
        case failed(String)
    }

    /// One environment variable or extra header row.
    struct Variable: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
        /// Stored in Keychain: the field is secure, and an existing value shows as dots.
        var secret: Bool
        /// The Keychain already holds it and nothing new was typed.
        var stored: Bool = false
    }

    /// What the sheet opens with, already checked (a preview, or a URL pasted elsewhere).
    struct Draft {
        var name = ""
        var url = ""
        var check: Check = .idle
        var command = ""
        var env: [Variable] = []
        var resolvedPath: String?
        var checkedAt: Date?
        var json = ""
    }

    var store: MCPStore
    let initialKind: Kind?
    let editing: MCPServerEntry?
    var draft: Draft?
    let close: () -> Void

    init(store: MCPStore, initialKind: Kind?, editing: MCPServerEntry?, draft: Draft? = nil, close: @escaping () -> Void) {
        self.store = store
        self.initialKind = initialKind
        self.editing = editing
        self.draft = draft
        self.close = close
    }

    @State private var kind: Kind = .remote
    @State private var name = ""
    @State private var nameEdited = false
    @State private var url = ""
    @State private var check: Check = .idle
    @State private var signIn: SignIn = .oauth
    @State private var headerName = "Authorization"
    @State private var headerValue = ""
    @State private var start: MCPStartMode = .whenUsed
    @State private var advanced = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var scopes = ""
    @State private var extraHeaders: [Variable] = []
    @State private var timeout = MCPShepherdSettings.defaultTimeoutSeconds
    @State private var command = ""
    @State private var env: [Variable] = []
    @State private var resolvedPath: String?
    @State private var pathChecked: Date?
    @State private var json = ""
    @State private var problem: String?
    /// The URL and command already checked: typing them again doesn't check again.
    @State private var checkedURL: String?
    @State private var checkedCommand: String?

    private var isEditing: Bool { editing != nil }

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isEditing {
                NWSegmentedPicker("Kind", selection: $kind, options: [(.remote, "Remote"), (.local, "Local"), (.json, "Paste JSON")])
                    .padding(.horizontal, AppLayout.mcpSheetSides)
                    .fixedSize()
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NW.Space.xl) {
                    switch kind {
                    case .remote: remote
                    case .local: local
                    case .json: pasteJSON
                    }
                    if let problem { NWInlineProblem(problem) }
                }
                .padding(.vertical, NW.Space.xl + NW.Space.xxs)
                .padding(.horizontal, AppLayout.mcpSheetSides)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: kind == .local ? AppLayout.mcpSheetLocalWidth : AppLayout.mcpSheetWidth)
        .frame(minHeight: AppLayout.mcpSheetMinHeight)
        .background(nw.bgWindow)
        .onAppear(perform: load)
        .task(id: url) { await checkURL() }
        .task(id: command) { await resolveCommand() }
        .nwAnimation(.disclosure, value: check)
        .nwAnimation(.disclosure, value: advanced)
    }

    // MARK: Chrome

    private var header: some View {
        let nw = Color.nw
        return HStack(alignment: .top, spacing: NW.Space.l) {
            VStack(alignment: .leading, spacing: NW.Space.xxs + 1) {
                Text(isEditing ? "Edit \(editing?.name ?? "")" : "Add an MCP server")
                    .font(.nwSans(AppLayout.mcpSheetTitleSize, .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Remote servers need a URL. Local servers run a command on this Mac.")
                    .font(.nwSans(AppLayout.mcpSheetTextSize))
                    .foregroundStyle(nw.textSecondary)
            }
            Spacer(minLength: NW.Space.l)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.nwSans(AppLayout.mcpNoteSize, .semibold))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: AppLayout.mcpSheetCloseSize, height: AppLayout.mcpSheetCloseSize)
                    .overlay { Circle().strokeBorder(nw.lineStrong) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.top, NW.Space.xl + NW.Space.xxs)
        .padding(.bottom, NW.Space.l + NW.Space.xxs)
        .padding(.leading, AppLayout.mcpSheetSides)
        .padding(.trailing, NW.Space.xl + NW.Space.xxs)
    }

    private var footer: some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m + NW.Space.xxs) {
            Text(footnote)
                .font(.nwSans(AppLayout.mcpNoteSize))
                .foregroundStyle(nw.textTertiary)
                .lineLimit(1)
            Spacer(minLength: NW.Space.m)
            Button("Cancel", action: close).buttonStyle(.nw(.ghost))
            Button(primaryTitle, action: submit)
                .buttonStyle(.nw(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding(.leading, AppLayout.mcpSheetSides)
        .padding(.trailing, NW.Space.xl + NW.Space.xxs)
        .frame(height: AppLayout.mcpSheetFooterHeight)
        .background(nw.bgSunken)
        .overlay(alignment: .top) { NWHairline() }
    }

    private var footnote: String {
        switch kind {
        case .local: "Start: \(start.title.lowercased()) · stops after \(MCPShepherdSettings.defaultIdleMinutes) min idle"
        case .remote, .json: "Saved to \(store.configPath)."
        }
    }

    private var primaryTitle: String {
        if isEditing { return "Save" }
        switch kind {
        case .remote: return signIn == .oauth ? "Add and sign in" : "Add"
        case .local: return "Add and start"
        case .json:
            let count = (try? MCPImport.parse(json).get())?.count ?? 0
            return count > 1 ? "Add \(count) servers" : "Add"
        }
    }

    // MARK: Remote

    @ViewBuilder private var remote: some View {
        field("URL") {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "globe").foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
                TextField("URL", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                    .textFieldStyle(.plain)
                    .font(.nwMono(AppLayout.mcpSheetTextSize))
            }
            .modifier(MCPFieldChrome())
        }
        checkCard
        HStack(alignment: .top, spacing: NW.Space.xl) {
            field("Name", note: nameNote) { nameField }
                .frame(maxWidth: .infinity, alignment: .leading)
            field("Sign-in") {
                NWSegmentedPicker("Sign-in", selection: $signIn, options: [
                    (.oauth, oauthFound ? "OAuth · found" : "OAuth"), (.header, "Header"), (.none, "None"),
                ])
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if signIn == .header {
            HStack(alignment: .top, spacing: NW.Space.m) {
                field("Header") {
                    TextField("Header", text: $headerName).textFieldStyle(.plain).font(.nwMono(AppLayout.mcpSheetTextSize))
                        .modifier(MCPFieldChrome())
                }
                .frame(width: AppLayout.mcpSheetNameWidth)
                field("Value", note: "Use ${GITHUB_TOKEN} to read it from your login shell; anything else is stored in Keychain.") {
                    SecureOrPlainField(value: $headerValue, prompt: "Bearer ${GITHUB_TOKEN}")
                }
            }
        }
        field("Start") {
            HStack(spacing: NW.Space.l) {
                NWSegmentedPicker("Start", selection: $start, options: MCPStartMode.allCases.map { ($0, $0.title) }).fixedSize()
                Text(startNote).font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            }
        }
        DisclosureGroup(isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                HStack(alignment: .top, spacing: NW.Space.m) {
                    field("Client ID") { plain($clientID, prompt: "Registered with the provider") }
                    field("Client secret") { SecureOrPlainField(value: $clientSecret, prompt: "Optional") }
                }
                field("Scopes", note: "Separated by spaces. Empty asks for what the server suggests.") { plain($scopes, prompt: "read write") }
                field("Extra headers") { variables($extraHeaders, addTitle: "Add header") }
                field("Timeout") {
                    NWStepper("Timeout", value: $timeout, in: 5...300, format: { "\($0) s" })
                }
            }
            .padding(.top, NW.Space.m)
        } label: {
            Text("Advanced: client ID, scopes, extra headers, timeout")
                .font(.nwSans(AppLayout.mcpSheetTextSize))
                .foregroundStyle(Color.nw.textSecondary)
        }
    }

    private var oauthFound: Bool {
        if case .oauth = check { return true }
        return false
    }

    private var startNote: String {
        switch start {
        case .whenUsed: "When used is cheapest; nothing runs until the agent needs it."
        case .withSession: "Connects as each thread starts, and stays until it ends."
        case .alwaysOn: "Connects as each thread starts, and reconnects when it drops."
        }
    }

    @ViewBuilder private var checkCard: some View {
        let nw = Color.nw
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: NW.Space.m) {
                ProgressView().progressViewStyle(.nwSpinner)
                Text("Checking \(URL(string: url)?.host ?? "the server")…").font(.nwSans(AppLayout.mcpSheetTextSize))
                    .foregroundStyle(nw.textSecondary)
            }
            .modifier(MCPCheckCard())
        case .answered(let serverName, let transport):
            VStack(alignment: .leading, spacing: NW.Space.m) {
                answered(serverName, transport: transport)
                line("lock.open", "It needs no sign-in. Add a header if it wants a token.")
            }
            .modifier(MCPCheckCard())
        case .oauth(let serverName, let provider, let registers):
            VStack(alignment: .leading, spacing: NW.Space.m) {
                answered(serverName, transport: .streamableHTTP)
                line("lock", registers
                     ? "It uses sign-in with \(provider) (OAuth). Shepherd registers itself with \(provider), then opens the sign-in page."
                     : "It uses sign-in with \(provider) (OAuth), but \(provider) doesn’t allow registration: add a client ID under Advanced.")
            }
            .modifier(MCPCheckCard())
        case .failed(let message):
            HStack(spacing: NW.Space.m) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(nw.lanternText).accessibilityHidden(true)
                Text(message).font(.nwSans(AppLayout.mcpSheetTextSize)).foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(MCPCheckCard())
        }
    }

    private func answered(_ serverName: String?, transport: MCPTransportKind) -> some View {
        let nw = Color.nw
        let who = serverName ?? URL(string: url)?.host ?? "The server"
        return HStack(spacing: NW.Space.m) {
            Image(systemName: "checkmark").font(.nwSans(AppLayout.mcpNoteSize, .bold)).foregroundStyle(nw.done).accessibilityHidden(true)
            Text("\(Text(who).fontWeight(.semibold)) answered · \(MCPStore.transportName(transport))")
                .font(.nwSans(AppLayout.mcpSheetTextSize + 0.5))
                .foregroundStyle(nw.textPrimary)
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Image(systemName: symbol).font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(Color.nw.textSecondary).accessibilityHidden(true)
            Text(text).font(.nwSans(AppLayout.mcpSheetTextSize + 0.5)).foregroundStyle(Color.nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Local

    @ViewBuilder private var local: some View {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            field("Name") { nameField }.frame(width: AppLayout.mcpSheetNameWidth)
            field("Command", note: "Runs on this Mac, in your login shell’s PATH.") {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "terminal").foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
                    TextField("Command", text: $command, prompt: Text("npx @playwright/mcp@latest"))
                        .textFieldStyle(.plain)
                        .font(.nwMono(AppLayout.mcpSheetTextSize))
                }
                .modifier(MCPFieldChrome())
            }
        }
        field("Environment", note: "Secrets stay in Keychain, never in the JSON file.") { variables($env, addTitle: "Add variable") }
        field("Runs on") {
            HStack(spacing: NW.Space.m + NW.Space.xxs) {
                Toggle("This Mac", isOn: .constant(true)).toggleStyle(.nwCheckbox).labelsHidden().allowsHitTesting(false)
                Text("This Mac").font(.nwMono(AppLayout.mcpSheetTextSize)).frame(width: AppLayout.mcpSheetHostNameWidth, alignment: .leading)
                pathNote
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NW.Space.m + NW.Space.xxs)
            .frame(height: AppLayout.mcpSheetFieldHeight)
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.mcpSheetFieldRadius))
            .nwBorder(Color.nw.lineStrong, radius: AppLayout.mcpSheetFieldRadius)
        }
    }

    @ViewBuilder private var pathNote: some View {
        let nw = Color.nw
        let program = MCPCommandLine.split(command).first ?? ""
        if program.isEmpty {
            Text("Type a command").font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(nw.textTertiary)
        } else if let resolvedPath {
            Text(resolvedPath).font(.nwMono(AppLayout.mcpPathSize)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.middle)
        } else if let pathChecked {
            Text("\(program) isn’t installed · last checked \(pathChecked.formatted(date: .omitted, time: .shortened))")
                .font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(nw.lanternText).lineLimit(1)
        } else {
            Text("Looking for \(program)…").font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(nw.textTertiary)
        }
    }

    // MARK: Paste JSON

    @ViewBuilder private var pasteJSON: some View {
        field("JSON", note: pasteNote) {
            TextEditor(text: $json)
                .font(.nwMono(AppLayout.mcpSheetTextSize))
                .scrollContentBackground(.hidden)
                .padding(NW.Space.m)
                .frame(height: AppLayout.mcpSheetJSONHeight)
                .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.mcpSheetFieldRadius))
                .nwBorder(Color.nw.lineStrong, radius: AppLayout.mcpSheetFieldRadius)
                .accessibilityLabel("JSON")
        }
    }

    private var pasteNote: String {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "An mcpServers block from Claude Desktop, Cursor or VS Code. Tokens in it move to Keychain."
        }
        switch MCPImport.parse(json) {
        case .success(let entries): return "Found \(entries.map(\.name).formatted(.list(type: .and))). Tokens in it move to Keychain."
        case .failure(let failure): return failure.description
        }
    }

    // MARK: Parts

    private var nameField: some View {
        TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }), prompt: Text("notion"))
            .textFieldStyle(.plain)
            .font(.nwMono(AppLayout.mcpSheetTextSize))
            .modifier(MCPFieldChrome())
            .disabled(isEditing)
    }

    private var nameNote: String {
        let prefix = MCPServerName.toolPrefix(name.isEmpty ? "name" : name)
        return nameProblem ?? "The agent sees its tools as \(prefix)_…"
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if !MCPServerName.isValid(trimmed) { return "Letters, digits, - and _ only." }
        if !isEditing, store.entry(trimmed) != nil { return "\(trimmed) is already here." }
        return nil
    }

    private func plain(_ text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(.nwMono(AppLayout.mcpSheetTextSize))
            .modifier(MCPFieldChrome())
    }

    private func variables(_ rows: Binding<[Variable]>, addTitle: String) -> some View {
        let nw = Color.nw
        return VStack(spacing: 0) {
            ForEach(rows) { $row in
                HStack(spacing: NW.Space.l) {
                    TextField("Name", text: $row.key, prompt: Text("NAME"))
                        .textFieldStyle(.plain)
                        .font(.nwMono(AppLayout.mcpNoteSize))
                        .foregroundStyle(nw.textSecondary)
                        .frame(width: AppLayout.mcpSheetEnvKeyWidth, alignment: .leading)
                        .onChange(of: row.key) { _, key in
                            if MCPSecretReference.looksSecret(key: key), row.value.isEmpty { row.secret = true }
                        }
                    if row.stored {
                        HStack(spacing: NW.Space.s) {
                            Image(systemName: "lock").accessibilityHidden(true)
                            Text("••••••••••••").font(.nwMono(AppLayout.mcpNoteSize))
                            Text("in Keychain").font(.nwSans(AppLayout.mcpPathSize)).foregroundStyle(nw.textTertiary)
                            Button("Replace") { row.stored = false; row.value = "" }.buttonStyle(.nwLink)
                        }
                        .foregroundStyle(nw.textSecondary)
                    } else if row.secret {
                        SecureField("Value", text: $row.value, prompt: Text("Stored in Keychain"))
                            .textFieldStyle(.plain)
                            .font(.nwMono(AppLayout.mcpNoteSize))
                    } else {
                        TextField("Value", text: $row.value, prompt: Text("value or ${VAR}"))
                            .textFieldStyle(.plain)
                            .font(.nwMono(AppLayout.mcpNoteSize))
                    }
                    Spacer(minLength: 0)
                    Button { row.secret.toggle(); row.stored = false } label: {
                        Image(systemName: row.secret ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(row.secret ? nw.textSecondary : nw.textTertiary)
                    .help(row.secret ? "Stored in Keychain" : "Store in Keychain")
                    Button { rows.wrappedValue.removeAll { $0.id == row.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(nw.textTertiary)
                        .accessibilityLabel("Remove \(row.key)")
                }
                .padding(.horizontal, NW.Space.m + NW.Space.xxs)
                .frame(height: AppLayout.mcpSheetFieldHeight)
                .overlay(alignment: .bottom) { NWHairline() }
            }
            Button { rows.wrappedValue.append(Variable(key: "", value: "", secret: false)) } label: {
                Label(addTitle, systemImage: "plus").font(.nwSans(AppLayout.mcpSheetTextSize))
            }
            .buttonStyle(.nwLink)
            .padding(.horizontal, NW.Space.m + NW.Space.xxs)
            .frame(maxWidth: .infinity, minHeight: AppLayout.mcpSheetFieldHeight - 2, alignment: .leading)
        }
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.mcpSheetFieldRadius))
        .nwBorder(nw.lineStrong, radius: AppLayout.mcpSheetFieldRadius)
    }

    private func field<Content: View>(_ label: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            Text(label).font(.nwSans(AppLayout.mcpSheetTextSize, .medium)).foregroundStyle(Color.nw.textSecondary)
            content()
            if let note {
                Text(note).font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(Color.nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Behaviour

    private func load() {
        kind = initialKind ?? .remote
        if let draft {
            name = draft.name
            nameEdited = !draft.name.isEmpty
            url = draft.url
            check = draft.check
            checkedURL = draft.check == .idle ? nil : draft.url
            command = draft.command
            env = draft.env
            resolvedPath = draft.resolvedPath
            pathChecked = draft.checkedAt
            checkedCommand = draft.checkedAt == nil ? nil : draft.command
            json = draft.json
            if case .oauth = draft.check { signIn = .oauth } else if case .answered = draft.check { signIn = .none }
        }
        guard let entry = editing else { return }
        kind = entry.kind == .remote ? .remote : .local
        name = entry.name
        nameEdited = true
        let settings = entry.settings
        start = settings.start
        timeout = settings.timeoutSeconds
        clientID = settings.oauth.clientID ?? ""
        clientSecret = settings.oauth.clientSecret ?? ""
        scopes = settings.oauth.scopes.joined(separator: " ")
        url = entry.url ?? ""
        command = MCPCommandLine.join([entry.command ?? ""] + entry.args)
        env = entry.env.sorted { $0.key < $1.key }.map { Self.variable($0.key, $0.value) }
        var headers = entry.headers
        if let auth = headers.keys.first(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            signIn = .header
            headerName = auth
            headerValue = headers.removeValue(forKey: auth) ?? ""
        } else {
            signIn = store.usesOAuth(entry) ? .oauth : .none
        }
        extraHeaders = headers.sorted { $0.key < $1.key }.map { Self.variable($0.key, $0.value) }
    }

    private static func variable(_ key: String, _ value: String) -> Variable {
        let reference = !MCPSecretReference.references(in: value).isEmpty
        return Variable(key: key, value: reference ? "" : value, secret: reference, stored: reference)
    }

    private var canSubmit: Bool {
        guard store.isEditable else { return false }
        switch kind {
        case .remote:
            return nameProblem == nil && !name.isEmpty && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
        case .local:
            return nameProblem == nil && !name.isEmpty && !MCPCommandLine.split(command).isEmpty
        case .json:
            return (try? MCPImport.parse(json).get()) != nil
        }
    }

    private func checkURL() async {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard trimmed != checkedURL else { return }
        checkedURL = nil
        guard kind == .remote, let parsed = URL(string: trimmed), parsed.scheme?.hasPrefix("http") == true, parsed.host != nil else {
            check = .idle
            return
        }
        if !nameEdited { name = MCPServerName.suggested(for: parsed) }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        check = .checking
        let result = await MCPURLCheck.check(parsed, http: store.dependencies.http)
        guard !Task.isCancelled else { return }
        switch result {
        case .answered(let serverName, let transport):
            check = .answered(name: serverName, transport: transport)
            if !isEditing, signIn == .oauth { signIn = .none }
        case .needsSignIn(let challenge):
            let service = MCPOAuthService(http: store.dependencies.http)
            if let discovery = try? await service.discover(server: parsed, challenge: MCPAuthChallenge.bearer(in: challenge)) {
                let host = URL(string: discovery.metadata.authorizationEndpoint)?.host ?? parsed.host
                check = .oauth(name: discovery.resourceMetadata?.resourceName, provider: MCPSignInFlow.providerName(server: name, host: host),
                               registers: discovery.metadata.registrationEndpoint != nil || !clientID.isEmpty)
            } else {
                check = .oauth(name: nil, provider: MCPSignInFlow.providerName(server: name, host: parsed.host), registers: true)
            }
            if !isEditing { signIn = .oauth }
        case .failed(let message):
            check = .failed(message)
        }
    }

    private func resolveCommand() async {
        let program = MCPCommandLine.split(command).first ?? ""
        guard command != checkedCommand else { return }
        checkedCommand = nil
        guard kind == .local, !program.isEmpty else { return }
        if !nameEdited { name = MCPServerName.suggested(forCommand: MCPCommandLine.split(command)) }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        let path = await MCPCommandLine.resolve(program)
        guard !Task.isCancelled else { return }
        resolvedPath = path
        pathChecked = Date()
    }

    private func submit() {
        problem = nil
        do {
            switch kind {
            case .json:
                if case .success(let entries) = MCPImport.parse(json) {
                    try store.importEntries(entries, replace: false)
                }
                close()
                return
            case .remote, .local:
                var secrets: [String: String] = [:]
                let entry = try build(secrets: &secrets)
                try store.save(entry, secrets: secrets, replacing: editing?.name)
                close()
                if kind == .remote, signIn == .oauth, store.token(entry.name) == nil { store.beginSignIn(entry.name) }
            }
        } catch {
            problem = "\(error)"
        }
    }

    /// The entry the sheet describes: kept whole from the one being edited, so unknown keys stay.
    private func build(secrets: inout [String: String]) throws -> MCPServerEntry {
        let serverName = name.trimmingCharacters(in: .whitespaces)
        var entry = editing ?? MCPServerEntry(name: serverName, json: kind == .remote ? ["type": .string("http")] : [:])
        entry.name = serverName
        func collect(_ rows: [Variable], keep old: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for row in rows where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
                let key = row.key.trimmingCharacters(in: .whitespaces)
                if row.stored, let previous = old[key] {
                    out[key] = previous
                } else if row.secret, !MCPSecretReference.isReference(row.value) {
                    secrets[key] = row.value
                    out[key] = MCPSecretReference.reference(server: serverName, name: key)
                } else {
                    out[key] = row.value
                }
            }
            return out
        }
        switch kind {
        case .remote:
            entry.url = url.trimmingCharacters(in: .whitespaces)
            var headers = collect(extraHeaders, keep: editing?.headers ?? [:])
            if signIn == .header, !headerName.isEmpty {
                if MCPSecretReference.isReference(headerValue) || headerValue.isEmpty {
                    headers[headerName] = headerValue.isEmpty ? editing?.headers[headerName] ?? "" : headerValue
                } else {
                    let parts = headerValue.split(separator: " ", maxSplits: 1)
                    let scheme = parts.count == 2 && parts[0].lowercased() == "bearer" ? "Bearer " : ""
                    secrets[headerName] = scheme.isEmpty ? headerValue : String(parts[1])
                    headers[headerName] = scheme + MCPSecretReference.reference(server: serverName, name: headerName)
                }
            }
            entry.headers = headers
            if entry.type == nil { entry.json["type"] = .string("http") }
        case .local:
            let words = MCPCommandLine.split(command)
            entry.command = words.first
            entry.args = Array(words.dropFirst())
            entry.env = collect(env, keep: editing?.env ?? [:])
        case .json:
            break
        }
        var settings = entry.settings
        settings.start = start
        settings.timeoutSeconds = timeout
        settings.oauth.clientID = clientID.isEmpty ? nil : clientID
        settings.oauth.clientSecret = clientSecret.isEmpty ? nil : clientSecret
        settings.oauth.scopes = scopes.split(separator: " ").map(String.init)
        if let secret = settings.oauth.clientSecret, !MCPSecretReference.isReference(secret) {
            secrets["OAUTH_CLIENT_SECRET"] = secret
            settings.oauth.clientSecret = MCPSecretReference.reference(server: serverName, name: "OAUTH_CLIENT_SECRET")
        }
        entry.settings = settings
        return entry
    }
}

/// The sheet's 34pt field at radius 7.
private struct MCPFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, NW.Space.m + NW.Space.xxs)
            .frame(height: AppLayout.mcpSheetFieldHeight)
            .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.mcpSheetFieldRadius))
            .nwBorder(Color.nw.lineStrong, radius: AppLayout.mcpSheetFieldRadius)
    }
}

/// What the URL check found, on a sunken card.
private struct MCPCheckCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, NW.Space.l)
            .padding(.horizontal, NW.Space.l + NW.Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: AppLayout.mcpCardRadius))
            .nwBorder(Color.nw.lineSubtle, radius: AppLayout.mcpCardRadius)
    }
}

/// A secret's field: secure unless its value is a `${VAR}` reference.
private struct SecureOrPlainField: View {
    @Binding var value: String
    let prompt: String

    var body: some View {
        Group {
            if value.contains("${") {
                TextField("Value", text: $value, prompt: Text(prompt))
            } else {
                SecureField("Value", text: $value, prompt: Text(prompt))
            }
        }
        .textFieldStyle(.plain)
        .font(.nwMono(AppLayout.mcpSheetTextSize))
        .modifier(MCPFieldChrome())
    }
}

/// Paste JSON from the Import… menu: the same parser, then the clash question.
struct MCPPasteImportSheet: View {
    let done: ([MCPServerEntry]) -> Void
    let close: () -> Void
    @State private var json = ""

    var body: some View {
        let parsed = MCPImport.parse(json)
        DialogSheet(title: "Import MCP servers", subtitle: "Paste an mcpServers block, VS Code’s servers, or a single entry.",
                    width: AppLayout.mcpSheetWidth,
                    status: json.isEmpty ? nil : {
                        switch parsed {
                        case .success(let entries): "Found \(entries.map(\.name).formatted(.list(type: .and)))."
                        case .failure(let failure): failure.description
                        }
                    }(),
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: close),
                        DialogAction("Import", kind: .prominent, isEnabled: (try? parsed.get()) != nil) {
                            if case .success(let entries) = parsed { done(entries) }
                        },
                    ]) {
            TextEditor(text: $json)
                .font(.nwMono(AppLayout.mcpSheetTextSize))
                .scrollContentBackground(.hidden)
                .padding(NW.Space.m)
                .frame(height: AppLayout.mcpSheetJSONHeight)
                .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: AppLayout.mcpSheetFieldRadius))
                .nwBorder(Color.nw.lineStrong, radius: AppLayout.mcpSheetFieldRadius)
                .accessibilityLabel("JSON")
        }
    }
}
