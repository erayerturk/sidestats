import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String {
    case general, widgets, appStore, google, searchAds, meta, api
}

struct SettingsView: View {
    @EnvironmentObject var store: MetricsStore
    @AppStorage("settingsTab") private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general.rawValue)
            WidgetSettings().tabItem { Label("Modules", systemImage: "square.grid.2x2") }.tag(SettingsTab.widgets.rawValue)
            AppStoreSettings().tabItem { Label("App Store", systemImage: "apple.logo") }.tag(SettingsTab.appStore.rawValue)
            GoogleSettings().tabItem { Label("Google", systemImage: "g.circle") }.tag(SettingsTab.google.rawValue)
            SearchAdsSettings().tabItem { Label("Search Ads", systemImage: "magnifyingglass") }.tag(SettingsTab.searchAds.rawValue)
            MetaSettings().tabItem { Label("Meta Ads", systemImage: "m.circle") }.tag(SettingsTab.meta.rawValue)
            APISettings().tabItem { Label("API & MCP", systemImage: "terminal") }.tag(SettingsTab.api.rawValue)
        }
        .frame(width: 720, height: 560)
    }
}

// MARK: - Building blocks

/// A secret text field backed by the Keychain. Shows a placeholder when a value is already stored.
struct SecretField: View {
    var title: String
    var secret: Secret
    var multiline = false
    var importTypes: [UTType] = []
    @State private var text = ""
    @State private var isSet = false

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                if multiline {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 70)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(isSet ? "•••• saved in Keychain — paste to replace" : "Paste key contents")
                                    .font(.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                } else {
                    SecureField(isSet ? "•••• saved in Keychain" : "", text: $text)
                }
                HStack {
                    if !importTypes.isEmpty {
                        Button("Import file…") { importFile() }
                    }
                    if !text.isEmpty { Button("Save") { save() } }
                    if isSet { Button("Remove", role: .destructive) { secret.set(nil); isSet = false } }
                }
                .controlSize(.small)
            }
        }
        .onAppear { isSet = secret.isSet }
        .onSubmit { save() }
        .onDisappear { if !text.isEmpty { save() } }
    }

    private func save() {
        secret.set(text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
        isSet = secret.isSet
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = importTypes
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url, let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
            save()
        }
    }
}

struct SourceFooter: View {
    @EnvironmentObject var store: MetricsStore
    var kinds: [SourceKind]
    var docs: String

    var body: some View {
        Section {
            ForEach(kinds) { kind in
                let configured = store.configuredSources.contains(kind)
                let s = store.status[kind] ?? .init()
                HStack(alignment: .top) {
                    Image(systemName: !configured ? "circle.dashed" : s.error != nil ? "xmark.octagon.fill" : s.lastSuccess != nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(!configured ? Color.secondary : s.error != nil ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.callout.weight(.medium))
                        Text(!configured ? "Not configured" : s.loading ? "Loading…" : s.error ?? s.lastSuccess.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Not fetched yet")
                            .font(.caption).foregroundStyle(s.error != nil ? .red : .secondary)
                            .textSelection(.enabled).lineLimit(4)
                    }
                }
            }
            HStack {
                Button("Save & test connection") { Task { await store.refresh() } }
                    .disabled(store.isLoading)
                Spacer()
                Link("Setup guide ↗", destination: URL(string: docs)!)
            }
        }
    }
}

private let docsBase = Links.repo + "#"

// MARK: - Tabs

struct GeneralSettings: View {
    @EnvironmentObject var store: MetricsStore
    @AppStorage(UIScale.key) private var uiScale = 1.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    static let currencies = ["USD", "EUR", "GBP", "TRY", "JPY", "CAD", "AUD", "CHF", "SEK", "NOK", "PLN", "INR", "BRL", "KRW", "CNY", "MXN"]

    var body: some View {
        Form {
            Section {
                Picker("Base currency", selection: $store.config.baseCurrency) {
                    ForEach(Self.currencies, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: store.config.baseCurrency) { Task { await store.refresh() } }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            Section("Sidebar") {
                Toggle("Hide when the pointer leaves", isOn: $store.config.autoHide)
                LabeledContent("Edge reveal delay") {
                    HStack {
                        Slider(value: Binding(get: { Double(store.config.edgeDelayMs) },
                                              set: { store.config.edgeDelayMs = Int($0) }), in: 0...800, step: 50)
                        Text("\(store.config.edgeDelayMs) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: Binding(get: { uiScale }, set: { UIScale.set($0) }),
                               in: UIScale.range, step: UIScale.step)
                        Text("\(Int((uiScale * 100).rounded()))%").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Toggle shortcut") { Text("⌃⌥⌘S").monospaced() }
                Text("Move the pointer to the right edge of your right-most screen to reveal the sidebar. ⌘+ / ⌘− / ⌘0 change the text size while the sidebar is focused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Picker("Refresh store & ad data", selection: $store.config.revenueRefreshMinutes) {
                    Text("Every 5 min").tag(5)
                    Text("Every 15 min").tag(15)
                    Text("Every 30 min").tag(30)
                    Text("Every hour").tag(60)
                }
                Toggle("Show demo data", isOn: $store.config.useDemoData)
                    .onChange(of: store.config.useDemoData) { Task { await store.refresh() } }
                Text("API keys are stored in your macOS Keychain. Reports are fetched directly from Apple, Google and Meta — SideStats has no server.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.config.aliases.isEmpty {
                    Button("Reset all custom app names (\(store.config.aliases.count))") { store.config.aliases = [:] }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AppStoreSettings: View {
    @EnvironmentObject var store: MetricsStore
    var body: some View {
        Form {
            Section {
                TextField("Issuer ID", text: $store.config.ascIssuerId)
                TextField("Key ID", text: $store.config.ascKeyId)
                TextField("Vendor number", text: $store.config.ascVendorNumber)
                SecretField(title: "Private key (.p8)", secret: .ascPrivateKey, multiline: true,
                            importTypes: [UTType(filenameExtension: "p8") ?? .data])
            } header: {
                Text("App Store Connect API")
            } footer: {
                Text("Users and Access → Integrations → App Store Connect API → Team Keys. Role: Finance or Sales. Vendor number: Payments and Financial Reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.appStoreConnect], docs: docsBase + "app-store-connect")
        }
        .formStyle(.grouped)
    }
}

struct GoogleSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var clientSecret = ""
    @State private var signedIn = Secret.googleRefreshToken.isSet
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("OAuth client ID", text: $store.config.googleClientId)
                SecureField(Secret.googleClientSecret.isSet ? "•••• saved in Keychain" : "OAuth client secret", text: $clientSecret)
                HStack {
                    if signedIn {
                        Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Sign out") {
                            Task { await GoogleOAuth.shared.signOut(); signedIn = false; await store.refresh() }
                        }
                    } else {
                        Spacer()
                        Button(busy ? "Waiting for browser…" : "Sign in with Google") { signIn() }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || store.config.googleClientId.isEmpty
                                      || (clientSecret.isEmpty && !Secret.googleClientSecret.isSet))
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            } header: {
                Text("Google account")
            } footer: {
                Text("Create a “Desktop app” OAuth client in Google Cloud Console and enable the AdMob API and Cloud Storage JSON API.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AdMob") {
                Toggle("Fetch AdMob earnings", isOn: $store.config.admobEnabled)
            }
            Section {
                TextField("Cloud Storage URI", text: $store.config.playBucket, prompt: Text("gs://pubsite_prod_rev_…"))
                LabeledContent("Net share after Google fee") {
                    Picker("", selection: $store.config.playNetShare) {
                        Text("85% (15% fee)").tag(0.85)
                        Text("70% (30% fee)").tag(0.70)
                    }
                    .labelsHidden().fixedSize()
                }
            } header: {
                Text("Google Play")
            } footer: {
                Text("Play Console → Download reports → Statistics → “Copy Cloud Storage URI”. Install stats and sales reports are read from that bucket.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.admob, .googlePlay], docs: docsBase + "google-admob--google-play")
        }
        .formStyle(.grouped)
    }

    private func signIn() {
        busy = true; error = nil
        let secret = clientSecret.isEmpty ? (Secret.googleClientSecret.value ?? "") : clientSecret
        let clientId = store.config.googleClientId.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await GoogleOAuth.shared.signIn(clientId: clientId, clientSecret: secret)
                signedIn = true; clientSecret = ""
                NSApp.activate(ignoringOtherApps: true)
                await store.refresh()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct SearchAdsSettings: View {
    @EnvironmentObject var store: MetricsStore
    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $store.config.asaClientId, prompt: Text("SEARCHADS.…"))
                TextField("Team ID", text: $store.config.asaTeamId, prompt: Text("SEARCHADS.…"))
                TextField("Key ID", text: $store.config.asaKeyId)
                TextField("Org ID (optional)", text: $store.config.asaOrgId, prompt: Text("all orgs"))
                SecretField(title: "Private key (PEM)", secret: .asaPrivateKey, multiline: true,
                            importTypes: [UTType(filenameExtension: "pem") ?? .data])
            } header: {
                Text("Apple Search Ads API")
            } footer: {
                Text("Generate a key pair (openssl ecparam -genkey -name prime256v1 -noout -out private-key.pem), upload the public key in Search Ads → Account Settings → API, then paste the private key here.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            SourceFooter(kinds: [.appleSearchAds], docs: docsBase + "apple-search-ads")
        }
        .formStyle(.grouped)
    }
}

struct MetaSettings: View {
    @EnvironmentObject var store: MetricsStore
    var body: some View {
        Form {
            Section {
                SecretField(title: "Access token", secret: .metaAccessToken)
                TextField("Ad account IDs", text: $store.config.metaAdAccounts, prompt: Text("act_123, act_456"))
            } header: {
                Text("Meta Marketing API")
            } footer: {
                Text("Use a System User token (Business Settings → System users) with ads_read permission. Spend is attributed to an app via the ad set's promoted app; other spend is shown as “Unattributed”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.metaAds], docs: docsBase + "meta-ads")
        }
        .formStyle(.grouped)
    }
}

// MARK: - API & MCP

struct APISettings: View {
    @EnvironmentObject var api: LocalAPIServer
    @State private var showToken = false
    @State private var confirmRegenerate = false
    @State private var copied: String?

    private var exe: String { AppVersion.executablePath }
    private var base: String { "http://127.0.0.1:\(api.port ?? LocalAPIServer.defaultPort)" }
    private var claudeCode: String { "claude mcp add sidestats -- \"\(exe)\" --mcp" }
    private var desktopJSON: String {
        let path = exe.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "sidestats": {
              "command": "\(path)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }
    private var tokenLine: String {
        "export SIDESTATS_TOKEN=$(plutil -extract token raw ~/Library/Application\\ Support/SideStats/api.json)"
    }
    private var curlWidget: String {
        """
        curl -s \(base)/v1/widgets -H "Authorization: Bearer $SIDESTATS_TOKEN" \\
          -d '{"name":"Deploys","icon":"shippingbox","source":"push"}'
        """
    }
    private var curlPush: String {
        """
        curl -s \(base)/v1/widgets/<id>/data -H "Authorization: Bearer $SIDESTATS_TOKEN" \\
          -d '{"items":[{"type":"stat","label":"Today","value":12},{"type":"status","label":"CI","state":"ok"}]}'
        """
    }
    private var curlTodo: String {
        """
        curl -s \(base)/v1/todos -H "Authorization: Bearer $SIDESTATS_TOKEN" \\
          -d '{"title":"Renew certificate","due":"2026-12-01","priority":"high"}'
        """
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Local API") {
                    HStack(spacing: 6) {
                        Circle().fill(api.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(api.isRunning ? "Running on \(base)" : (api.lastError ?? "Not running"))
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(showToken ? api.token : String(repeating: "•", count: 24))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button(copied == "token" ? "Copied" : "Copy") { copy(api.token, "token") }
                        Button("Regenerate…") { confirmRegenerate = true }
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Local API")
            } footer: {
                Text("Listens on 127.0.0.1 only. Every request needs the token; browser requests (Origin header) are refused. The token is stored in ~/Library/Application Support/SideStats/api.json (readable only by you), which is how the MCP server finds it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                snippet("Claude Code", claudeCode, id: "cc")
                snippet("Claude Desktop / Cursor", desktopJSON, id: "json")
                Text("Claude Desktop: Settings → Developer → Edit Config (claude_desktop_config.json). Cursor: ~/.cursor/mcp.json. The MCP server starts SideStats when it isn't running.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("MCP server")
            } footer: {
                Text("Agents can create widgets, push data, manage tasks, read revenue, show notifications and open the sidebar. Command widgets run shell commands as you — review what an agent adds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("curl") {
                snippet("Token", tokenLine, id: "tok")
                snippet("Create a push widget", curlWidget, id: "w")
                snippet("Push data", curlPush, id: "push")
                snippet("Add a task", curlTodo, id: "todo")
                Link("API reference ↗", destination: URL(string: Links.repo + "#automation-local-api--mcp")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Regenerate the API token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { api.regenerateToken() }
        } message: {
            Text("Scripts using the old token stop working. The MCP server picks up the new token automatically.")
        }
    }

    private func snippet(_ title: String, _ text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Button(copied == id ? "Copied" : "Copy") { copy(text, id) }.controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
        }
    }

    private func copy(_ s: String, _ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == id { copied = nil } }
    }
}
