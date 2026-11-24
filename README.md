# SideStats

A sidebar for indie app developers on macOS. Move the pointer to the **right edge of the screen**
and a panel slides in with every app you own: store revenue, ad revenue, ad spend, net profit,
ROAS and downloads, merged across iOS and Android.

- **Sources:** App Store Connect · Google Play · AdMob · Apple Search Ads · Meta Ads
- **Private by design:** no server, no account. API keys live in your macOS Keychain and reports
  are fetched directly from Apple, Google and Meta.
- **Native:** SwiftUI and AppKit, about 2 MB, menu bar only (no Dock icon). Global shortcut `⌃⌥⌘S`.
- **Multi-currency:** everything is converted to your base currency with ECB reference rates.

## Install

Download `SideStats.dmg` from [Releases](../../releases) and drag it to Applications.
The build is not notarized yet, so on first launch: right-click the app → **Open**
(or run `xattr -dr com.apple.quarantine /Applications/SideStats.app`).

Build from source (Xcode 16+, macOS 14+):

```sh
./scripts/build-app.sh --dmg   # → dist/SideStats.app, dist/SideStats.dmg
```

No accounts yet? Click **Try with demo data** in the sidebar.

## Usage

| | |
|---|---|
| Reveal | Rest the pointer on the right edge of your right-most screen (corners are ignored) |
| Toggle | `⌃⌥⌘S` or the menu bar icon |
| Pin | 📌 in the header keeps the panel open |
| Details | Click an app row |
| Merge / rename | Right-click an app → *Rename / merge…*. Apps with the same name become one row, which is how iOS and Android versions merge |

Data is refreshed every 30 minutes, when the panel opens with stale data, or manually.
The last 90 days are fetched; the range picker switches between 7D / 30D / MTD / 90D.

## Modules: add anything

The sidebar is a stack of modules. *Apps & Revenue* is the built-in one, and you can add your own:
**any HTTP API or shell command**, refreshed live (every 5 s to 6 h).

- Return the **SideStats format** (`{"items":[{"type":"stat"|"chart"|"list"|"text"|"progress"|"status", …}]}`)
  and it is rendered exactly as described.
- Or return **plain JSON** and it is detected automatically: numbers become stats, number arrays
  and rows with a date become charts, other arrays become lists, objects become stat grids, text stays text.
  Use a JSON path, field filter or display override to shape it.
- Modules can be reordered, hidden, exported as JSON and imported, so they can be shared.

Settings → **Modules**. Full reference and ready-made examples: [WIDGETS.md](WIDGETS.md) · [examples/](examples/).

## Connecting sources

### App Store Connect
1. App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys**.
2. Create a key with the **Finance** (or Sales) role and download the `.p8`.
3. In SideStats → Settings → App Store, enter the **Issuer ID** and **Key ID**, then import the `.p8`.
4. Get the **Vendor number** from **Payments and Financial Reports** (top left).

Provides proceeds (paid apps, IAP, subscriptions) and first-time downloads from daily Sales reports.
Past days are cached locally, so only new days are downloaded.

### Google (AdMob + Google Play)
Both use one Google sign-in, with your own OAuth client:
1. [Google Cloud Console](https://console.cloud.google.com/) → create or select a project.
2. Enable the **AdMob API** and the **Cloud Storage JSON API**.
3. **APIs & Services → OAuth consent screen**: set it up as *External* and add yourself as a test user.
4. **Credentials → Create credentials → OAuth client ID → Desktop app**. Copy the client ID and secret.
5. Settings → Google: paste both and click **Sign in with Google**.

**Google Play:** Play Console → **Download reports → Statistics → Copy Cloud Storage URI**
(`gs://pubsite_prod_rev_…`) and paste it in Settings. The signed-in Google account needs access to
reports in Play Console. Installs come from `stats/installs`, revenue from `sales/salesreport_*.zip`
(net is estimated with the 15% / 30% fee you select).

**AdMob:** estimated earnings and impressions per app (Network report). Apps linked to a store
listing are merged with their store data automatically.

### Apple Search Ads
1. Search Ads → **Account Settings → User Management**: invite an API user (or use yours) with the *API Account Read Only* role.
2. Generate a key pair:
   ```sh
   openssl ecparam -genkey -name prime256v1 -noout -out private-key.pem
   openssl ec -in private-key.pem -pubout -out public-key.pem
   ```
3. As that user: **Account Settings → API**, paste `public-key.pem` and copy the **Client ID, Team ID, Key ID**.
4. Settings → Search Ads: enter them and import `private-key.pem`.

Spend is attributed to apps by campaign `adamId`.

### Meta Ads
1. Business Settings → **System users** → create one, give it access to your ad accounts, and
   generate a token with `ads_read`.
2. Settings → Meta Ads: paste the token and your ad account IDs (`act_123, act_456`).

Spend is attributed to an app through the ad set's promoted app (app install and app event campaigns).
Other spend shows up as *Unattributed ad spend*.

## Architecture

```
Sources/SideStats
├── main.swift                  app delegate, menu bar item, global hotkey
├── Core/                       models, Keychain/JWT, HTTP/CSV/gzip, FX, Google OAuth, MetricsStore,
│                               Widgets (format parser, auto-detection, fetcher, WidgetStore)
├── Providers/                  one file per data source (implements `Provider`)
└── UI/                         edge panel controller, sidebar, module views, settings, module editor
```

To add a source, implement `Provider` (`fetch(config:start:end:) -> ProviderResult`) and return
daily `MetricRow`s keyed by `AppKey` (`ios:<apple id>` / `android:<package>`), then register it in
`MetricsStore.providers`.

## Roadmap
- Google Ads and TikTok Ads spend
- RevenueCat as a subscription revenue source
- Manual recurring costs (servers, tools)
- Notarized builds and auto-update (Sparkle)

## License
MIT
