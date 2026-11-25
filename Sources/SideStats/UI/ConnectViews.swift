import SwiftUI
import UniformTypeIdentifiers

// Guided / one-click connection screens for the revenue & ad sources.

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

// MARK: - App Store Connect

struct AppStoreSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var keySet = Secret.ascPrivateKey.isSet
    @State private var busy = false
    @State private var ok: String?
    @State private var error: String?
    @State private var vendorOK: String?
    @State private var vendorError: String?
    @State private var dropTarget = false

    private var keyDone: Bool { keySet && !store.config.ascKeyId.isEmpty && !store.config.ascIssuerId.isEmpty }

    var body: some View {
        Form {
            Section {
                StepRow(number: 1, title: "Create an API key", done: keyDone) {
                    Text("App Store Connect → Users and Access → Integrations → **Team Keys** → +. Access: **Sales** (or Finance). Download the .p8 file.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open App Store Connect ↗") { NSWorkspace.shared.open(Connect.ascKeysURL) }.controlSize(.small)
                }
                StepRow(number: 2, title: "Drop the .p8 file here", done: keySet && !store.config.ascKeyId.isEmpty) {
                    dropZone
                    if !store.config.ascKeyId.isEmpty {
                        LabeledContent("Key ID") { Text(store.config.ascKeyId).monospaced() }.font(.caption)
                    }
                }
                StepRow(number: 3, title: "Issuer ID", done: !store.config.ascIssuerId.isEmpty) {
                    Text("Shown above the keys table on the same page. Copy it, then:").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Paste from clipboard") {
                            if let u = Connect.firstUUID(in: clipboard()) { store.config.ascIssuerId = u; test() }
                            else { error = "No Issuer ID (UUID) on the clipboard." }
                        }
                        TextField("", text: $store.config.ascIssuerId, prompt: Text("xxxxxxxx-xxxx-…")).monospaced()
                    }
                    .controlSize(.small)
                    StatusLine(ok: ok, error: error, busy: busy)
                }
                StepRow(number: 4, title: "Vendor number", done: vendorOK != nil || (!store.config.ascVendorNumber.isEmpty && vendorError == nil && store.status[.appStoreConnect]?.error == nil)) {
                    Text("Payments and Financial Reports → top-left, under your name (8 digits).").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open ↗") { NSWorkspace.shared.open(Connect.ascVendorURL) }
                        Button("Paste") {
                            if let v = Connect.vendorNumber(in: clipboard()) { store.config.ascVendorNumber = v; testVendor() }
                            else { vendorError = "No vendor number on the clipboard." }
                        }
                        TextField("", text: $store.config.ascVendorNumber, prompt: Text("8xxxxxxx")).monospaced()
                            .onSubmit { testVendor() }
                    }
                    .controlSize(.small)
                    StatusLine(ok: vendorOK, error: vendorError)
                }
            } header: { Text("Connect App Store Connect") } footer: {
                Text("Apple has no “Sign in with Apple” for these APIs, so a read-only API key is the safest way. The key stays in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.appStoreConnect], docs: docsBase + "app-store-connect")
        }
        .formStyle(.grouped)
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
        Secret.ascPrivateKey.set(pem)
        keySet = true
        if let id = Connect.ascKeyId(fromFilename: url.lastPathComponent) { store.config.ascKeyId = id }
        error = nil
        if !store.config.ascIssuerId.isEmpty { test() }
    }

    private func test() {
        guard keyDone, let pem = Secret.ascPrivateKey.value else { return }
        busy = true; error = nil; ok = nil
        let c = store.config
        Task {
            do {
                let apps = try await Connect.testASC(issuer: c.ascIssuerId, keyId: c.ascKeyId, pem: pem)
                ok = "Key works · \(apps.count) app\(apps.count == 1 ? "" : "s")" + (apps.isEmpty ? "" : ": " + apps.prefix(3).joined(separator: ", ") + (apps.count > 3 ? "…" : ""))
                if !c.ascVendorNumber.isEmpty { testVendor() }
            } catch {
                self.error = "Apple rejected the key: \(error.localizedDescription.prefix(160))"
            }
            busy = false
        }
    }

    private func testVendor() {
        guard keyDone, let pem = Secret.ascPrivateKey.value, !store.config.ascVendorNumber.isEmpty else { return }
        vendorOK = nil; vendorError = nil
        let c = store.config
        Task {
            do {
                try await Connect.testVendor(issuer: c.ascIssuerId, keyId: c.ascKeyId, pem: pem, vendor: c.ascVendorNumber)
                vendorOK = "Vendor number works — loading sales…"
                await store.refresh(only: [.appStoreConnect])
                vendorOK = store.status[.appStoreConnect]?.error == nil ? "Connected" : nil
            } catch {
                vendorError = "Sales reports refused: \(error.localizedDescription.prefix(160))"
            }
        }
    }
}

// MARK: - Google (AdMob, Play, Google Ads)

struct GoogleSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var signedIn = GoogleClient.isConnected(Config.load())
    @State private var busy = false
    @State private var error: String?
    @State private var showOwnClient = !Config.load().googleClientId.isEmpty || GoogleClient.oneClick == nil
    @State private var clientSecret = ""
    @State private var found: String?
    @State private var playError: String?

    private var canSignIn: Bool {
        if showOwnClient || GoogleClient.oneClick == nil {
            return !store.config.googleClientId.isEmpty && (!clientSecret.isEmpty || Secret.googleClientSecret.isSet)
        }
        return true
    }

    var body: some View {
        Form {
            Section {
                if signedIn {
                    HStack {
                        Label("Google connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Sign out") {
                            Task {
                                await GoogleOAuth.shared.signOut()
                                store.config.googleSignedInClientId = ""
                                signedIn = false; found = nil
                                await store.refresh()
                            }
                        }
                    }
                    if let found { Text(found).font(.caption).foregroundStyle(.secondary) }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(GoogleClient.oneClick != nil ? "One click for AdMob, Google Play and Google Ads"
                                 : "Sign in with your OAuth client below").font(.callout.weight(.medium))
                            Text("Read-only access. You can revoke it any time in your Google account.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(busy ? "Waiting for browser…" : "Sign in with Google") { signIn() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(busy || !canSignIn)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if GoogleClient.oneClick != nil {
                    DisclosureGroup("Use my own OAuth client (advanced)", isExpanded: $showOwnClient) { ownClientFields }
                        .font(.caption)
                } else {
                    ownClientFields
                }
            } header: { Text("Google account") }

            Section("AdMob") {
                Toggle("Fetch AdMob earnings", isOn: $store.config.admobEnabled)
            }

            Section {
                Toggle("Fetch Google Ads spend", isOn: $store.config.googleAdsEnabled)
                if store.config.googleAdsEnabled {
                    TextField("Customer IDs", text: $store.config.googleAdsCustomerIds, prompt: Text("empty = all accessible accounts"))
                    TextField("Manager account ID", text: $store.config.googleAdsLoginCustomerId, prompt: Text("optional, if you use an MCC"))
                    if showOwnClient { SecretField(title: "Developer token (optional)", secret: .googleAdsDeveloperToken) }
                }
            } header: { Text("Google Ads") } footer: {
                Text("App campaigns are matched to their app; other campaigns count as unattributed spend.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                StepRow(number: 1, title: "Copy the reports bucket", done: !store.config.playBucket.isEmpty && playError == nil) {
                    Text("Play Console → Download reports → Statistics → **Copy Cloud Storage URI**.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Play Console ↗") { NSWorkspace.shared.open(Connect.playReportsURL) }
                        Button("Paste") {
                            if let b = Connect.playBucket(in: clipboard()) {
                                store.config.playBucket = b; playError = nil
                                Task { await store.refresh(only: [.googlePlay]); playError = store.status[.googlePlay]?.error }
                            } else { playError = "No gs://pubsite_prod_… URI on the clipboard." }
                        }
                        TextField("", text: $store.config.playBucket, prompt: Text("gs://pubsite_prod_rev_…"))
                    }
                    .controlSize(.small)
                    if let playError { Text(playError).font(.caption).foregroundStyle(.red).lineLimit(3) }
                }
                LabeledContent("Net share after Google fee") {
                    Picker("", selection: $store.config.playNetShare) {
                        Text("85% (15% fee)").tag(0.85)
                        Text("70% (30% fee)").tag(0.70)
                    }
                    .labelsHidden().fixedSize()
                }
            } header: { Text("Google Play") } footer: {
                Text("Play has no reports API; it shares them through this bucket. The signed-in Google account needs access to the Play developer account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.admob, .googlePlay, .googleAds], docs: docsBase + "google-admob--google-play")
        }
        .formStyle(.grouped)
        .onAppear { signedIn = GoogleClient.isConnected(store.config) }
    }

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
        let own = !store.config.googleClientId.trimmingCharacters(in: .whitespaces).isEmpty
        let client: GoogleClient
        if own || GoogleClient.oneClick == nil {
            client = GoogleClient(id: store.config.googleClientId.trimmingCharacters(in: .whitespaces),
                                  secret: clientSecret.isEmpty ? (Secret.googleClientSecret.value ?? "") : clientSecret)
        } else {
            client = GoogleClient.oneClick!
        }
        Task {
            do {
                try await GoogleOAuth.shared.signIn(clientId: client.id, clientSecret: client.secret, storeSecret: own)
                store.config.googleSignedInClientId = client.id
                signedIn = true; clientSecret = ""
                NSApp.activate(ignoringOtherApps: true)
                await discover()
                await store.refresh()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// After sign-in: find AdMob and Google Ads accounts and switch on what exists.
    private func discover() async {
        var parts: [String] = []
        let c = store.config
        if let admob = try? await Connect.admobAccounts(config: c) {
            parts.append(admob.isEmpty ? "No AdMob account" : "AdMob: \(admob.count) account\(admob.count == 1 ? "" : "s")")
            if !admob.isEmpty { store.config.admobEnabled = true }
        }
        if let ads = try? await Connect.googleAdsCustomers(config: c) {
            parts.append(ads.isEmpty ? "No Google Ads account" : "Google Ads: \(ads.count) account\(ads.count == 1 ? "" : "s")")
            if !ads.isEmpty { store.config.googleAdsEnabled = true }
        }
        found = parts.isEmpty ? nil : "Found — " + parts.joined(separator: " · ")
    }
}

// MARK: - Apple Search Ads

struct SearchAdsSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var keySet = Secret.asaPrivateKey.isSet
    @State private var copied = false
    @State private var error: String?
    @State private var ok: String?
    @State private var busy = false
    @State private var showManual = false

    private var credsDone: Bool { !store.config.asaClientId.isEmpty && !store.config.asaTeamId.isEmpty && !store.config.asaKeyId.isEmpty }

    var body: some View {
        Form {
            Section {
                StepRow(number: 1, title: "Create a key", done: keySet) {
                    Text("SideStats generates a key pair. The private key stays in your Keychain; the public key is copied for you.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(keySet ? "Copy public key again" : "Generate key & copy public key") { generateOrCopy() }
                        if keySet { Button("New key", role: .destructive) { Secret.asaPrivateKey.set(nil); keySet = false; generateOrCopy() } }
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
                        Text("clientId \(store.config.asaClientId)\nteamId \(store.config.asaTeamId)\nkeyId \(store.config.asaKeyId)")
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    StatusLine(ok: ok, error: error, busy: busy)
                }
                DisclosureGroup("Enter manually / use an existing key", isExpanded: $showManual) {
                    TextField("Client ID", text: $store.config.asaClientId, prompt: Text("SEARCHADS.…"))
                    TextField("Team ID", text: $store.config.asaTeamId, prompt: Text("SEARCHADS.…"))
                    TextField("Key ID", text: $store.config.asaKeyId)
                    TextField("Org ID (optional)", text: $store.config.asaOrgId, prompt: Text("all orgs"))
                    SecretField(title: "Private key (PEM)", secret: .asaPrivateKey, multiline: true,
                                importTypes: [UTType(filenameExtension: "pem") ?? .data])
                }
                .font(.caption)
            } header: { Text("Connect Apple Search Ads") }
            SourceFooter(kinds: [.appleSearchAds], docs: docsBase + "apple-search-ads")
        }
        .formStyle(.grouped)
    }

    private func generateOrCopy() {
        let pub: String
        if let existing = Secret.asaPrivateKey.value, let p = Connect.publicPEM(fromPrivate: existing) {
            pub = p
        } else {
            let k = Connect.generateASAKey()
            Secret.asaPrivateKey.set(k.privatePEM)
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
        store.config.asaClientId = c; store.config.asaTeamId = t; store.config.asaKeyId = k
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
    @State private var tokenSet = Secret.metaAccessToken.isSet
    @State private var token = ""
    @State private var accounts: [Connect.MetaAccount] = []
    @State private var busy = false
    @State private var error: String?

    private var selected: Set<String> {
        Set(store.config.metaAdAccounts.split(separator: ",").map {
            let s = $0.trimmingCharacters(in: .whitespaces); return s.hasPrefix("act_") ? s : "act_" + s
        })
    }

    var body: some View {
        Form {
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
                            store.config.metaAdAccounts = s.sorted().joined(separator: ", ")
                        })) {
                            HStack {
                                Text(a.name)
                                Text("\(a.id) · \(a.currency)\(a.active ? "" : " · inactive")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text("Connect Meta Ads") } footer: {
                Text("Spend is attributed to an app via the ad set's promoted app; other spend shows as “Unattributed”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SourceFooter(kinds: [.metaAds], docs: docsBase + "meta-ads")
        }
        .formStyle(.grouped)
        .onAppear { if tokenSet && accounts.isEmpty { load() } }
    }

    private func saveToken() {
        guard !token.isEmpty else { return }
        Secret.metaAccessToken.set(token)
        token = ""; tokenSet = true
        load(selectAllIfNone: true)
    }

    private func load(selectAllIfNone: Bool = false) {
        guard let t = Secret.metaAccessToken.value else { return }
        busy = true; error = nil
        Task {
            do {
                accounts = try await Connect.metaAdAccounts(token: t)
                if accounts.isEmpty { error = "The token works but sees no ad accounts. Assign them to the system user." }
                if selectAllIfNone && selected.isEmpty && !accounts.isEmpty {
                    store.config.metaAdAccounts = accounts.filter(\.active).map(\.id).joined(separator: ", ")
                    await store.refresh(only: [.metaAds])
                }
            } catch {
                self.error = "Meta rejected the token: \(error.localizedDescription.prefix(160))"
            }
            busy = false
        }
    }
}
