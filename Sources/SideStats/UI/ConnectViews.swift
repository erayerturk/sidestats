import SwiftUI
import UniformTypeIdentifiers

// Guided / one-click connection screens for the revenue & ad sources. Every source supports
// several accounts (Google logins, App Store teams, Search Ads accounts, Meta tokens).

private let docsBase = Links.repo + "#"

/// A numbered setup step with a done state.
struct StepRow<Content: View>: View {
    var number: Int
    var title: String
    var done: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 22, height: 22)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(number)").font(.caption.weight(.semibold)) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct StatusLine: View {
    var ok: String?
    var error: String?
    var busy = false
    var body: some View {
        if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.caption).foregroundStyle(.secondary) } }
        else if let error { Label(error, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        else if let ok { Label(ok, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
    }
}

private func clipboard() -> String { NSPasteboard.general.string(forType: .string) ?? "" }

// MARK: - Accounts

extension MetricsStore {
    func account(_ id: String?) -> Binding<SourceAccount>? {
        guard let id, config.accounts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.config.accounts.first { $0.id == id } ?? SourceAccount(kind: .google) },
            set: { new in if let i = self.config.accounts.firstIndex(where: { $0.id == id }) { self.config.accounts[i] = new } })
    }

    @discardableResult
    func addAccount(_ kind: AccountKind) -> SourceAccount {
        let a = SourceAccount(kind: kind)
        config.accounts.append(a)
        return a
    }

    func removeAccount(_ id: String) {
        guard let a = config.accounts.first(where: { $0.id == id }) else { return }
        a.deleteSecrets()
        if a.kind == .appStore { Storage.remove("asc-days-\(id).json") }
        config.accounts.removeAll { $0.id == id }
        Task { await refresh() }
    }
}

/// Account chips + add button, shown at the top of each source tab.
struct AccountBar: View {
    @EnvironmentObject var store: MetricsStore
    let kind: AccountKind
    @Binding var selection: String?
    var addTitle: String
    var onAdd: (() -> Void)?

    var body: some View {
        let accounts = store.config.accounts(kind)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(accounts) { a in
                    Button { selection = a.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(a.enabled ? Color.green : Color.secondary).frame(width: 6, height: 6)
                            Text(a.displayName).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selection == a.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    if let onAdd { onAdd() } else { selection = store.addAccount(kind).id }
                } label: {
                    Label(addTitle, systemImage: "plus").padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { if selection == nil || !accounts.contains(where: { $0.id == selection }) { selection = accounts.first?.id } }
    }
}

/// Footer row of an account: enable toggle, name, remove.
struct AccountManageRow: View {
    @EnvironmentObject var store: MetricsStore
    @Binding var account: SourceAccount
    var namePrompt: String
    @State private var confirm = false

    var body: some View {
        HStack {
            TextField("Name", text: $account.label, prompt: Text(namePrompt)).frame(maxWidth: 240)
            Toggle("Enabled", isOn: $account.enabled).toggleStyle(.switch).controlSize(.small)
            Spacer()
            Button("Remove…", role: .destructive) { confirm = true }.controlSize(.small)
        }
        .confirmationDialog("Remove \(account.displayName)?", isPresented: $confirm) {
            Button("Remove", role: .destructive) { store.removeAccount(account.id) }
        } message: { Text("Its keys are deleted from the Keychain and its data disappears from the sidebar.") }
    }
}

// MARK: - App Store Connect

struct AppStoreSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selection: String? = Config.load().accounts(.appStore).first?.id

    var body: some View {
        Form {
            if !store.config.accounts(.appStore).isEmpty {
                Section { AccountBar(kind: .appStore, selection: $selection, addTitle: "Add team") }
            }
            if let account = store.account(selection) {
                AppStoreAccountForm(account: account).id(account.wrappedValue.id)
            } else {
                Section {
                    Button("Connect App Store Connect") { selection = store.addAccount(.appStore).id }.buttonStyle(.borderedProminent)
                }
            }
            SourceFooter(kinds: [.appStoreConnect], docs: docsBase + "app-store-connect")
        }
        .formStyle(.grouped)
    }
}

private struct AppStoreAccountForm: View {
    @EnvironmentObject var store: MetricsStore
    @Binding var account: SourceAccount
    @State private var keySet = false
    @State private var busy = false
    @State private var ok: String?
    @State private var error: String?
    @State private var vendorOK: String?
    @State private var vendorError: String?
    @State private var dropTarget = false

    private var key: SecretKey { account.secret(.ascPrivateKey) }
    private var keyDone: Bool { keySet && !account.ascKeyId.isEmpty && !account.ascIssuerId.isEmpty }

    var body: some View {
        Section {
            StepRow(number: 1, title: "Create an API key", done: keyDone) {
                Text("App Store Connect → Users and Access → Integrations → **Team Keys** → +. Access: **Sales** (or Finance). Download the .p8 file.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open App Store Connect ↗") { NSWorkspace.shared.open(Connect.ascKeysURL) }.controlSize(.small)
            }
            StepRow(number: 2, title: "Drop the .p8 file here", done: keySet && !account.ascKeyId.isEmpty) {
                dropZone
                if !account.ascKeyId.isEmpty {
                    LabeledContent("Key ID") { Text(account.ascKeyId).monospaced() }.font(.caption)
                }
            }
            StepRow(number: 3, title: "Issuer ID", done: !account.ascIssuerId.isEmpty) {
                Text("Shown above the keys table on the same page. Copy it, then:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Paste from clipboard") {
                        if let u = Connect.firstUUID(in: clipboard()) { account.ascIssuerId = u; test() }
                        else { error = "No Issuer ID (UUID) on the clipboard." }
                    }
                    TextField("", text: $account.ascIssuerId, prompt: Text("xxxxxxxx-xxxx-…")).monospaced()
                }
                .controlSize(.small)
                StatusLine(ok: ok, error: error, busy: busy)
            }
            StepRow(number: 4, title: "Vendor number", done: vendorOK != nil) {
                Text("Payments and Financial Reports → top-left, under your name (8 digits).").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open ↗") { NSWorkspace.shared.open(Connect.ascVendorURL) }
                    Button("Paste") {
                        if let v = Connect.vendorNumber(in: clipboard()) { account.ascVendorNumber = v; testVendor() }
                        else { vendorError = "No vendor number on the clipboard." }
                    }
                    TextField("", text: $account.ascVendorNumber, prompt: Text("8xxxxxxx")).monospaced()
                        .onSubmit { testVendor() }
                }
                .controlSize(.small)
                StatusLine(ok: vendorOK, error: vendorError)
            }
            AccountManageRow(account: $account, namePrompt: "Team name (optional)")
        } header: { Text(account.displayName) } footer: {
            Text("Apple has no “Sign in with Apple” for these APIs, so a read-only API key is the safest way. The key stays in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            keySet = key.isSet
            if keyDone && !account.ascVendorNumber.isEmpty { testVendor(quiet: true) }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(dropTarget ? Color.accentColor : .secondary.opacity(0.5))
            .frame(height: 56)
            .overlay {
                HStack(spacing: 8) {
                    Image(systemName: keySet ? "key.fill" : "arrow.down.doc")
                    Text(keySet ? "Key saved in Keychain — drop another to replace" : "Drop AuthKey_XXXXXXXXXX.p8")
                    Button("Choose…") { choose() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { load(url) } }
                }
                return true
            }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let u = p.url { load(u) }
    }

    private func load(_ url: URL) {
        guard let pem = try? String(contentsOf: url, encoding: .utf8), (try? JWT.loadKey(pem)) != nil else {
            error = "That file isn't an App Store Connect private key (.p8)."; return
        }
        key.set(pem)
        keySet = true
        if let id = Connect.ascKeyId(fromFilename: url.lastPathComponent) { account.ascKeyId = id }
        error = nil
        if !account.ascIssuerId.isEmpty { test() }
    }

    private func test() {
        guard keyDone, let pem = key.value else { return }
        busy = true; error = nil; ok = nil
        let a = account
        Task {
            do {
                let apps = try await Connect.testASC(issuer: a.ascIssuerId, keyId: a.ascKeyId, pem: pem)
                ok = "Key works · \(apps.count) app\(apps.count == 1 ? "" : "s")" + (apps.isEmpty ? "" : ": " + apps.prefix(3).joined(separator: ", ") + (apps.count > 3 ? "…" : ""))
                if !a.ascVendorNumber.isEmpty { testVendor() }
            } catch {
                self.error = "Apple rejected the key: \(error.localizedDescription.prefix(160))"
            }
            busy = false
        }
    }

    private func testVendor(quiet: Bool = false) {
        guard keyDone, let pem = key.value, !account.ascVendorNumber.isEmpty else { return }
        vendorOK = nil; vendorError = nil
        let a = account
        Task {
            do {
                try await Connect.testVendor(issuer: a.ascIssuerId, keyId: a.ascKeyId, pem: pem, vendor: a.ascVendorNumber)
                vendorOK = "Connected"
                if !quiet { await store.refresh(only: [.appStoreConnect]) }
            } catch {
                vendorError = "Sales reports refused: \(error.localizedDescription.prefix(160))"
            }
        }
    }
}

// MARK: - Google (AdMob, Play, Google Ads)

struct GoogleSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var busy = false
    @State private var error: String?
    @State private var showOwnClient = !Config.load().googleClientId.isEmpty || GoogleClient.oneClick == nil
    @State private var clientSecret = ""
    @State private var found: [String: String] = [:]

    private var usesOwnClient: Bool { showOwnClient || GoogleClient.oneClick == nil }
    private var canSignIn: Bool {
        if usesOwnClient { return !store.config.googleClientId.isEmpty && (!clientSecret.isEmpty || Secret.googleClientSecret.isSet) }
        return true
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(GoogleClient.oneClick != nil ? "One click for AdMob, Google Play and Google Ads"
                             : "Sign in with your OAuth client below").font(.callout.weight(.medium))
                        Text("Read-only access. Add as many Google accounts as you like; revoke any time in your Google account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(busy ? "Waiting for browser…" : (store.config.accounts(.google).isEmpty ? "Sign in with Google" : "Add Google account")) { signIn() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(busy || !canSignIn)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if GoogleClient.oneClick != nil {
                    DisclosureGroup("Use my own OAuth client (advanced)", isExpanded: $showOwnClient) { ownClientFields }.font(.caption)
                } else {
                    ownClientFields
                }
            } header: { Text("Google accounts") }

            ForEach(store.config.accounts(.google)) { a in
                if let binding = store.account(a.id) {
                    GoogleAccountSection(account: binding, found: found[a.id], ownClient: usesOwnClient)
                }
            }
            SourceFooter(kinds: [.admob, .googlePlay, .googleAds], docs: docsBase + "google-admob--google-play")
        }
        .formStyle(.grouped)
        .task {
            // Demo/automation hook: start one sign-in shortly after the tab appears.
            guard ProcessInfo.processInfo.environment["SIDESTATS_DEMO_SIGNIN"] == "1", !Self.demoStarted else { return }
            Self.demoStarted = true
            try? await Task.sleep(for: .seconds(4))
            signIn()
        }
    }

    @MainActor private static var demoStarted = false

    @ViewBuilder private var ownClientFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("OAuth client ID", text: $store.config.googleClientId)
            SecureField(Secret.googleClientSecret.isSet ? "•••• saved in Keychain" : "OAuth client secret", text: $clientSecret)
            Text("Google Cloud Console → “Desktop app” OAuth client; enable the AdMob API, Cloud Storage JSON API and Google Ads API.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func signIn() {
        busy = true; error = nil
        let own = usesOwnClient && !store.config.googleClientId.trimmingCharacters(in: .whitespaces).isEmpty
        let client: GoogleClient
        if own {
            if !clientSecret.isEmpty { Secret.googleClientSecret.set(clientSecret) }
            client = GoogleClient(id: store.config.googleClientId.trimmingCharacters(in: .whitespaces),
                                  secret: clientSecret.isEmpty ? (Secret.googleClientSecret.value ?? "") : clientSecret)
        } else if let b = GoogleClient.oneClick {
            client = b
        } else { busy = false; return }
        var account = SourceAccount(kind: .google)
        account.googleClientId = client.id
        Task {
            do {
                let email = try await GoogleOAuth.shared.signIn(accountId: account.id, clientId: client.id,
                                                                clientSecret: client.secret, storeSecret: own)
                // Same Google account again? Replace the old entry instead of duplicating it.
                if let email, let old = store.config.accounts(.google).first(where: { $0.label == email }) {
                    account.admobEnabled = old.admobEnabled; account.googleAdsEnabled = old.googleAdsEnabled
                    account.googleAdsCustomerIds = old.googleAdsCustomerIds; account.googleAdsLoginCustomerId = old.googleAdsLoginCustomerId
                    account.playBucket = old.playBucket; account.playNetShare = old.playNetShare
                    old.deleteSecrets()
                    store.config.accounts.removeAll { $0.id == old.id }
                }
                account.label = email ?? ""
                store.config.accounts.append(account)
                clientSecret = ""
                NSApp.activate(ignoringOtherApps: true)
                await discover(account.id)
                await store.refresh()
            } catch {
                account.deleteSecrets()
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// After sign-in: find AdMob and Google Ads accounts and switch on what exists.
    private func discover(_ id: String) async {
        guard let a = store.config.accounts.first(where: { $0.id == id }) else { return }
        let c = a.scoped(store.config)
        var parts: [String] = []
        var updated = a
        if let admob = try? await Connect.admobAccounts(config: c) {
            parts.append(admob.isEmpty ? "No AdMob account" : "AdMob ✓")
            updated.admobEnabled = !admob.isEmpty
        }
        if let ads = try? await Connect.googleAdsCustomers(config: c) {
            parts.append(ads.isEmpty ? "No Google Ads account" : "Google Ads: \(ads.count) account\(ads.count == 1 ? "" : "s")")
            updated.googleAdsEnabled = !ads.isEmpty
        }
        if let i = store.config.accounts.firstIndex(where: { $0.id == id }) { store.config.accounts[i] = updated }
        found[id] = parts.isEmpty ? nil : "Found — " + parts.joined(separator: " · ")
    }
}

private struct GoogleAccountSection: View {
    @EnvironmentObject var store: MetricsStore
    @Binding var account: SourceAccount
    var found: String?
    var ownClient: Bool
    @State private var playError: String?
    @State private var confirm = false

    var body: some View {
        Section {
            if let found { Text(found).font(.caption).foregroundStyle(.secondary) }
            Toggle("AdMob earnings", isOn: $account.admobEnabled)
            Toggle("Google Ads spend", isOn: $account.googleAdsEnabled)
            if account.googleAdsEnabled {
                TextField("Customer IDs", text: $account.googleAdsCustomerIds, prompt: Text("empty = all accessible accounts"))
                TextField("Manager account ID", text: $account.googleAdsLoginCustomerId, prompt: Text("optional, if you use an MCC"))
                if ownClient { SecretField(title: "Developer token (optional)", secret: account.secret(.googleAdsDeveloperToken)) }
            }
            StepRow(number: 1, title: "Google Play reports bucket (optional)", done: !account.playBucket.isEmpty && playError == nil) {
                Text("Play Console → Download reports → Statistics → **Copy Cloud Storage URI**.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Play Console ↗") { NSWorkspace.shared.open(Connect.playReportsURL) }
                    Button("Paste") {
                        if let b = Connect.playBucket(in: clipboard()) {
                            account.playBucket = b; playError = nil
                            Task { await store.refresh(only: [.googlePlay]); playError = store.status[.googlePlay]?.error }
                        } else { playError = "No gs://pubsite_prod_… URI on the clipboard." }
                    }
                    TextField("", text: $account.playBucket, prompt: Text("gs://pubsite_prod_rev_…"))
                }
                .controlSize(.small)
                if let playError { Text(playError).font(.caption).foregroundStyle(.red).lineLimit(3) }
                if !account.playBucket.isEmpty {
                    Picker("Net share after Google fee", selection: $account.playNetShare) {
                        Text("85% (15% fee)").tag(0.85)
                        Text("70% (30% fee)").tag(0.70)
                    }
                    .controlSize(.small).fixedSize()
                }
            }
            HStack {
                Toggle("Enabled", isOn: $account.enabled).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Sign out", role: .destructive) { confirm = true }.controlSize(.small)
            }
        } header: {
            Label(account.label.isEmpty ? "Google account" : account.label, systemImage: "person.crop.circle")
        }
        .confirmationDialog("Sign out \(account.displayName)?", isPresented: $confirm) {
            Button("Sign out", role: .destructive) {
                let id = account.id
                Task { await GoogleOAuth.shared.signOut(accountId: id); store.removeAccount(id) }
            }
        }
    }
}

// MARK: - Apple Search Ads

struct SearchAdsSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selection: String? = Config.load().accounts(.searchAds).first?.id

    var body: some View {
        Form {
            if !store.config.accounts(.searchAds).isEmpty {
                Section { AccountBar(kind: .searchAds, selection: $selection, addTitle: "Add account") }
            }
            if let account = store.account(selection) {
                SearchAdsAccountForm(account: account).id(account.wrappedValue.id)
            } else {
                Section {
                    Button("Connect Apple Search Ads") { selection = store.addAccount(.searchAds).id }.buttonStyle(.borderedProminent)
                }
            }
            SourceFooter(kinds: [.appleSearchAds], docs: docsBase + "apple-search-ads")
        }
        .formStyle(.grouped)
    }
}

private struct SearchAdsAccountForm: View {
    @EnvironmentObject var store: MetricsStore
    @Binding var account: SourceAccount
    @State private var keySet = false
    @State private var copied = false
    @State private var error: String?
    @State private var ok: String?
    @State private var busy = false
    @State private var showManual = false

    private var key: SecretKey { account.secret(.asaPrivateKey) }
    private var credsDone: Bool { !account.asaClientId.isEmpty && !account.asaTeamId.isEmpty && !account.asaKeyId.isEmpty }

    var body: some View {
        Section {
            StepRow(number: 1, title: "Create a key", done: keySet) {
                Text("SideStats generates a key pair. The private key stays in your Keychain; the public key is copied for you.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(keySet ? "Copy public key again" : "Generate key & copy public key") { generateOrCopy() }
                    if keySet { Button("New key", role: .destructive) { key.set(nil); keySet = false; generateOrCopy() } }
                }
                .controlSize(.small)
                if copied { Label("Public key copied", systemImage: "doc.on.clipboard").font(.caption).foregroundStyle(.green) }
            }
            StepRow(number: 2, title: "Paste it into Search Ads", done: credsDone) {
                Text("Search Ads → Account Settings → **API** → Upload Public Key → paste → Save. (Needs the API Account Read Only role or higher.)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Search Ads ↗") { NSWorkspace.shared.open(Connect.asaCertificatesURL) }.controlSize(.small)
            }
            StepRow(number: 3, title: "Copy the credentials back", done: ok != nil) {
                Text("Search Ads then shows clientId, teamId and keyId. Copy that whole block and:").font(.caption).foregroundStyle(.secondary)
                Button("Paste credentials") { pasteCredentials() }.controlSize(.small).disabled(!keySet)
                if credsDone {
                    Text("clientId \(account.asaClientId)\nteamId \(account.asaTeamId)\nkeyId \(account.asaKeyId)")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                StatusLine(ok: ok, error: error, busy: busy)
            }
            DisclosureGroup("Enter manually / use an existing key", isExpanded: $showManual) {
                TextField("Client ID", text: $account.asaClientId, prompt: Text("SEARCHADS.…"))
                TextField("Team ID", text: $account.asaTeamId, prompt: Text("SEARCHADS.…"))
                TextField("Key ID", text: $account.asaKeyId)
                TextField("Org ID (optional)", text: $account.asaOrgId, prompt: Text("all orgs"))
                SecretField(title: "Private key (PEM)", secret: key, multiline: true,
                            importTypes: [UTType(filenameExtension: "pem") ?? .data])
            }
            .font(.caption)
            AccountManageRow(account: $account, namePrompt: "Account name (optional)")
        } header: { Text(account.displayName) }
        .onAppear { keySet = key.isSet }
    }

    private func generateOrCopy() {
        let pub: String
        if let existing = key.value, let p = Connect.publicPEM(fromPrivate: existing) {
            pub = p
        } else {
            let k = Connect.generateASAKey()
            key.set(k.privatePEM)
            keySet = true
            pub = k.publicPEM
        }
        Pasteboard.copy(pub)
        copied = true
    }

    private func pasteCredentials() {
        let p = Connect.parseASACredentials(clipboard())
        guard let c = p.clientId, let t = p.teamId, let k = p.keyId else {
            error = "Couldn't find clientId, teamId and keyId on the clipboard. Copy the whole block from Search Ads."
            return
        }
        account.asaClientId = c; account.asaTeamId = t; account.asaKeyId = k
        error = nil; busy = true
        Task {
            await store.refresh(only: [.appleSearchAds])
            if let e = store.status[.appleSearchAds]?.error { error = String(e.prefix(200)) } else { ok = "Connected" }
            busy = false
        }
    }
}

// MARK: - Meta Ads

struct MetaSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selection: String? = Config.load().accounts(.meta).first?.id

    var body: some View {
        Form {
            if !store.config.accounts(.meta).isEmpty {
                Section { AccountBar(kind: .meta, selection: $selection, addTitle: "Add token") }
            }
            if let account = store.account(selection) {
                MetaAccountForm(account: account).id(account.wrappedValue.id)
            } else {
                Section {
                    Button("Connect Meta Ads") { selection = store.addAccount(.meta).id }.buttonStyle(.borderedProminent)
                }
            }
            SourceFooter(kinds: [.metaAds], docs: docsBase + "meta-ads")
        }
        .formStyle(.grouped)
    }
}

private struct MetaAccountForm: View {
    @EnvironmentObject var store: MetricsStore
    @Binding var account: SourceAccount
    @State private var tokenSet = false
    @State private var token = ""
    @State private var accounts: [Connect.MetaAccount] = []
    @State private var busy = false
    @State private var error: String?

    private var key: SecretKey { account.secret(.metaAccessToken) }
    private var selected: Set<String> {
        Set(account.metaAdAccounts.split(separator: ",").map {
            let s = $0.trimmingCharacters(in: .whitespaces); return s.hasPrefix("act_") ? s : "act_" + s
        }.filter { $0 != "act_" })
    }

    var body: some View {
        Section {
            StepRow(number: 1, title: "Create a read-only token", done: tokenSet) {
                Text("Business Settings → System users → Add (Employee) → **Assign assets**: your ad accounts → **Generate token** with `ads_read`.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Business Settings ↗") { NSWorkspace.shared.open(Connect.metaSystemUsersURL) }.controlSize(.small)
            }
            StepRow(number: 2, title: "Paste the token", done: tokenSet && !accounts.isEmpty) {
                HStack {
                    Button("Paste from clipboard") { token = clipboard().trimmingCharacters(in: .whitespacesAndNewlines); saveToken() }
                    SecureField(tokenSet ? "•••• saved in Keychain" : "EAAB…", text: $token).onSubmit { saveToken() }
                }
                .controlSize(.small)
                StatusLine(ok: nil, error: error, busy: busy)
            }
            StepRow(number: 3, title: "Pick ad accounts", done: !selected.isEmpty) {
                if accounts.isEmpty {
                    Text(tokenSet ? "No ad accounts loaded yet." : "Accounts appear here after step 2.").font(.caption).foregroundStyle(.secondary)
                    if tokenSet { Button("Load accounts") { load() }.controlSize(.small) }
                }
                ForEach(accounts) { a in
                    Toggle(isOn: Binding(get: { selected.contains(a.id) }, set: { on in
                        var s = selected
                        if on { s.insert(a.id) } else { s.remove(a.id) }
                        account.metaAdAccounts = s.sorted().joined(separator: ", ")
                    })) {
                        HStack {
                            Text(a.name)
                            Text("\(a.id) · \(a.currency)\(a.active ? "" : " · inactive")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            AccountManageRow(account: $account, namePrompt: "Business name (optional)")
        } header: { Text(account.displayName) } footer: {
            Text("Spend is attributed to an app via the ad set's promoted app; other spend shows as “Unattributed”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { tokenSet = key.isSet; if tokenSet && accounts.isEmpty { load() } }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        key.set(token)
        token = ""; tokenSet = true
        load(selectAllIfNone: true)
    }

    private func load(selectAllIfNone: Bool = false) {
        guard let t = key.value else { return }
        busy = true; error = nil
        Task {
            do {
                accounts = try await Connect.metaAdAccounts(token: t)
                if accounts.isEmpty { error = "The token works but sees no ad accounts. Assign them to the system user." }
                if selectAllIfNone && selected.isEmpty && !accounts.isEmpty {
                    account.metaAdAccounts = accounts.filter(\.active).map(\.id).joined(separator: ", ")
                    await store.refresh(only: [.metaAds])
                }
            } catch {
                self.error = "Meta rejected the token: \(error.localizedDescription.prefix(160))"
            }
            busy = false
        }
    }
}
