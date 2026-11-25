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
./scripts/build-app.sh --dmg   # → dist/SideStats.app, dist/SideStats-<version>.dmg
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
- **Integrations:** Settings → Modules → + → *Browse integrations…* gives 40 ready-made modules (Grafana, Prometheus, Alertmanager, Uptime Kuma, UptimeRobot, Docker, Kubernetes, SSH servers, GitHub, Sentry, Vercel, Stripe, RevenueCat, Plausible, Home Assistant, weather…). See [WIDGETS.md#integrations](WIDGETS.md#integrations).
- **Tasks:** a built-in to-do module with natural-language quick add ("call bank tomorrow 10am !!"), two-way Apple Reminders sync and due-date notifications.

Settings → **Modules**. Full reference and ready-made examples: [WIDGETS.md](WIDGETS.md) · [examples/](examples/).
Settings → Modules → **JSON examples…** shows a copyable example for every item type with a live preview;
edit the JSON and add it as a module in one click.

## Automation: local API & MCP

SideStats has a local HTTP API and a built-in [MCP](https://modelcontextprotocol.io) server, so scripts
and AI agents (Claude Code, Claude Desktop, Cursor, …) can create widgets, push data, manage tasks and read
your numbers directly. Settings → **API & MCP** shows the status, the token and copy-ready snippets.

### MCP setup

The MCP server is the app binary itself started with `--mcp` (stdio). It talks to the running app and
starts SideStats if it isn't running.

**Claude Code**
```sh
claude mcp add sidestats -- /Applications/SideStats.app/Contents/MacOS/SideStats --mcp
```

**Claude Desktop** (Settings → Developer → Edit Config) and **Cursor** (`~/.cursor/mcp.json`):
```json
{
  "mcpServers": {
    "sidestats": {
      "command": "/Applications/SideStats.app/Contents/MacOS/SideStats",
      "args": ["--mcp"]
    }
  }
}
```

Then just ask: *"Add a SideStats widget with my open GitHub PRs"*, *"push today's signups as a bar chart"*,
*"remind me to renew the certificate on Friday"*.

| Tool | What it does |
|---|---|
| `sidestats_status` | Version, API port, counts (also starts the app) |
| `list_modules` | Modules in order with ids, visibility, source, last update, errors |
| `get_widget_format` | Compact reference of the widget format and auto-detection rules |
| `create_widget` / `update_widget` / `delete_widget` | Manage http / command / push widgets (all fields, headers, initial data) |
| `push_widget_data` | Render new data in a widget (SideStats items or plain JSON) |
| `refresh_widget` | Fetch an http / command widget now and return the result |
| `reorder_modules` / `set_module_visibility` | Reorder, hide / show, collapse / expand modules |
| `list_integrations` / `add_integration` | Ready-made integrations (presets) |
| `list_tasks` / `add_task` / `update_task` / `complete_task` / `delete_task` | The Tasks module |
| `get_revenue` | Revenue, spend, net, ROAS and downloads (totals and per app) for 7D / 30D / MTD / 90D |
| `notify` | Show a macOS notification |
| `show_panel` | Show, hide, toggle, pin or unpin the sidebar |

### HTTP API

The app listens on `http://127.0.0.1:48620` (or the next free port). The port and token are in
`~/Library/Application Support/SideStats/api.json`. JSON in, JSON out; errors are `{"error": "…", "hint": "…"}`.

```sh
export SIDESTATS_TOKEN=$(plutil -extract token raw ~/Library/Application\ Support/SideStats/api.json)
API=http://127.0.0.1:48620/v1
AUTH="Authorization: Bearer $SIDESTATS_TOKEN"

# create a push widget (source defaults to push when there's no url/command) — returns its id
curl -s $API/widgets -H "$AUTH" -d '{"name":"Deploys","icon":"shippingbox"}'

# push data to it, e.g. from CI or cron
curl -s $API/widgets/<id>/data -H "$AUTH" \
  -d '{"items":[{"type":"stat","label":"Today","value":12},{"type":"status","label":"CI","state":"ok"}]}'

# an http widget with a secret header (stored in the Keychain)
curl -s $API/widgets -H "$AUTH" -d '{"name":"Stars","url":"https://api.github.com/repos/apple/swift",
  "fields":"stargazers_count,forks_count","headers":{"Authorization":"Bearer ghp_…"}}'

# tasks
curl -s $API/todos -H "$AUTH" -d '{"title":"Renew certificate","due":"2026-12-01","priority":"high"}'
curl -s "$API/todos?done=false" -H "$AUTH"

curl -s "$API/revenue?range=30D" -H "$AUTH"
```

| Endpoint | |
|---|---|
| `GET /v1/status` · `GET /v1/format` | App status · widget format reference |
| `GET /v1/modules` · `POST /v1/layout` | Modules in order · `{order, hide, show, collapse, expand: [ids], move: {id, to}}` |
| `GET` / `POST /v1/widgets` | List · create (WidgetConfig JSON, optional `headers` and `data`) |
| `GET` / `PATCH` / `DELETE /v1/widgets/{id}` | Read · change fields · delete |
| `POST /v1/widgets/{id}/data` · `/refresh` · `GET …/export` | Push a payload · fetch now · shareable JSON |
| `GET /v1/presets` · `POST /v1/presets/{id}` | Integrations · create one from `{params: {…}}` |
| `GET` / `POST /v1/todos` · `GET` / `PATCH` / `DELETE /v1/todos/{id}` | Tasks (`due`: ISO-8601 or `yyyy-MM-dd`; `priority`: 0–3 or none/low/medium/high) |
| `GET /v1/revenue?range=7D\|30D\|MTD\|90D&series=true` | Totals and per-app numbers |
| `POST /v1/notify` · `POST /v1/panel` | `{title, body}` · `{action: show\|hide\|toggle\|pin\|unpin}` |

### Security model
- The server binds to **127.0.0.1 only** and is never reachable from the network.
- Every request needs the **bearer token**: 32 random bytes, stored in the Keychain and in `api.json`,
  which is created with `0600` permissions (readable only by your user). *Regenerate* in Settings revokes it.
- Requests with an `Origin` header (any web page) or a `Host` other than `127.0.0.1` / `localhost`
  are refused, and no CORS headers are sent, so websites can't reach the API (including DNS rebinding).
- Anything running as your user can read the token, just like it could read your other files.
  Agents can create **command widgets, which run shell commands as you** — review what they add.

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

### Google Ads
1. In the same Google Cloud project, enable the **Google Ads API** (Explorer access or higher is needed for real accounts).
2. Settings → Google → turn on *Fetch Google Ads spend*. Leave customer IDs empty to read every account you can access, or list them;
   if you reach clients through a manager (MCC) account, put its ID in *Manager account ID*.
3. If you signed in before Google Ads support existed, sign out and in again to grant the `adwords` scope.

App campaigns are matched to their App Store / Play app; other campaigns show as *Unattributed ad spend*.

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

### Any other ad network or app (custom revenue sources)
Settings → **Custom** turns any API, script or pushed JSON into a revenue / ad spend source for
*Apps & Revenue*. Rows are merged by app name (or store id) with the built-in sources.

```json
{ "currency": "USD",
  "rows": [ { "date": "2026-11-24", "app": "Puzzle Pop", "platform": "ios",
              "adRevenue": 42.10, "iapRevenue": 12.99, "spend": 18.50, "downloads": 130, "impressions": 15200 } ] }
```

- Field aliases (`revenue`, `estimated_revenue`, `cost`, `installs`, `day`, `application`, …) mean many APIs work as-is;
  otherwise map the response with a JavaScript transform (`data => data.report.map(r => ({date: r.day, app: r.title, adRevenue: r.usd}))`).
- Ready-made: **AppLovin MAX**, **LevelPlay (ironSource)**, any JSON API, script/command, push.
- Secrets: header lines like `$report_key: …` are kept in the Keychain and usable as `{{$report_key}}` in URLs
  (for APIs that take keys in the query string) or `$report_key` in commands.
- Push from anywhere: `POST /v1/revenue/data {"source":"Unity Ads","rows":[…]}` or the MCP tool `push_revenue_data`
  (unknown source names are created automatically).

## Architecture

```
Sources/SideStats
├── main.swift                  app delegate, menu bar item, global hotkey
├── Core/                       models, Keychain/JWT, HTTP/CSV/gzip, FX, Google OAuth, MetricsStore,
│                               Widgets (format parser, auto-detection, fetcher, WidgetStore),
│                               LocalAPI (127.0.0.1 HTTP API), MCPServer (`--mcp` stdio bridge)
├── Providers/                  one file per data source (implements `Provider`)
└── UI/                         edge panel controller, sidebar, module views, settings, module editor
```

To add a source, implement `Provider` (`fetch(config:start:end:) -> ProviderResult`) and return
daily `MetricRow`s keyed by `AppKey` (`ios:<apple id>` / `android:<package>`), then register it in
`MetricsStore.providers`.

## Roadmap
- TikTok Ads spend (possible today via a custom source)
- RevenueCat as a subscription revenue source
- Manual recurring costs (servers, tools)
- Notarized builds and auto-update (Sparkle)

## License
MIT
