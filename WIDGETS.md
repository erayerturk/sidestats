# Custom widgets

A widget is a sidebar card that SideStats fills from **any JSON you can fetch or send**: a URL, a shell command, or data pushed to it by a script or AI agent. It refreshes on its own timer and renders the result as stats, charts, lists, text, progress bars and status lights.

Each widget gets its data one of three ways:

| Source | What runs | Notes |
|---|---|---|
| `http` (HTTP API) | `URLRequest` with `method`, optional `body`, and your headers | `Accept: application/json` is always sent. A non-empty `body` adds `Content-Type: application/json`. Timeout is 30 s. |
| `command` (Shell command) | `/bin/zsh -lc "<command>"` | Your login shell environment is loaded (`-l`), so your `PATH` works. The command is killed after 30 s. Only stdout is parsed. A non-zero exit is an error only when stdout is empty, and the error message shows the first 400 bytes of stderr. |
| `push` (Push, API / MCP) | Nothing is fetched | Data arrives through `POST /v1/widgets/{id}/data` on the local API, or the MCP server. See [Push widgets](#push-widgets). |

If the output is valid JSON, it is parsed (bare scalars like `42` or `"hi"` count). Anything else is trimmed and shown as text.

The quickest start is **Settings → Modules → + → Browse integrations…**: [40+ ready-made integrations](#integrations) for Grafana, Prometheus, Uptime Kuma, Docker, SSH servers, GitHub, Stripe and more. Ready-made examples are also in [`examples/widgets/`](examples/widgets). [`integrations.json`](examples/widgets/integrations.json) imports a set of integrations that need no keys (weather, crypto, GitHub Actions, health checks, this Mac, Docker, Prometheus, GitHub status). [`all-examples.json`](examples/widgets/all-examples.json) imports all of them in one go.

---

## Widget definition (import / export)

A widget is a small JSON object. Every field is optional, and a missing field takes its default:

| Field | Default | Meaning |
|---|---|---|
| `name` | `"New widget"` | Card title. Auto mode also uses it as the label for a top-level scalar. |
| `icon` | `"square.grid.2x2"` | SF Symbol name for the card header. |
| `source` | `"http"` | `"http"`, `"command"` or `"push"`. |
| `url` | `""` | HTTP only. Placeholders are expanded. |
| `method` | `"GET"` | HTTP only. |
| `body` | `""` | HTTP only. Placeholders are expanded. |
| `command` | `""` | Command only. Placeholders are expanded. |
| `jsonPath` | `""` | Picks a sub-value before rendering (see [jsonPath](#jsonpath-fields-display)). |
| `fields` | `""` | Comma-separated keys to keep, in that order (auto and `stat` display). |
| `display` | `"auto"` | `auto`, `stat`, `chart`, `list` or `text`. |
| `refreshSeconds` | `300` | Refresh interval. Values under 5 are raised to 5. |
| `enabled` | `true` | Disabled widgets are hidden and never fetched. |
| `transform` | `""` | JavaScript run on the response before anything else (see [Transforms](#transforms-javascript)). |
| `preset` | `""` | Id of the integration the widget was created from. Informational. |

**Headers** (`Header: value`, one per line) are set in the widget editor. They are stored in the macOS Keychain, are **never exported**, and must be re-entered after an import.

**Import:** Settings → Modules → **+ → Import JSON…**, then paste JSON. This can be one widget object or an array of them. Every imported widget gets a fresh `id`.
**Export:** this copies the widget as JSON without `id` or headers, plus `"sidestats": 1`. Import ignores that key and any other unknown keys.

```json
{
  "name": "Bitcoin (USD)",
  "icon": "bitcoinsign.circle",
  "source": "http",
  "url": "https://api.coinbase.com/v2/prices/BTC-USD/spot",
  "jsonPath": "data",
  "fields": "amount",
  "refreshSeconds": 30
}
```

---

## The SideStats widget format

If you control the output (your own API, or a script), return a list of explicit items. Any of these shapes works:

```json
{"items": [ {"type": "stat", ...}, {"type": "chart", ...} ]}
[ {"type": "stat", ...}, {"type": "chart", ...} ]
{"type": "stat", ...}
```

Rules:
- `type` is one of `stat`, `chart`, `list`, `text`, `progress`, `status`. Items with a missing or unknown `type` are skipped; the rest still render.
- The explicit format is only used when `display` is `auto`. `jsonPath` is applied first.
- Consecutive `stat` items are laid out in a grid: 1 stat takes the full width, 3 stats share a row, and any other count uses 2 columns.

**Colors** (wherever `color` / `valueColor` appear): `green`, `red`, `blue`, `orange`, `yellow`, `purple`, `pink`, `teal`, `gray`/`grey`, `primary`, `secondary`, or `#RRGGBB`.

### `stat`

| Field | Type | Default | Notes |
|---|---|---|---|
| `label` | string | `""` | Small caption above the value. |
| `value` | number or string | — | Numbers and numeric strings (`"12.5"`) are formatted. Any other string is shown as-is. |
| `format` | string | `number` | `number`, `currency`, `percent` (value is a fraction: `0.25` shows as 25%), `bytes`, `duration` (seconds, e.g. `3h 12m`). |
| `currency` | string | `USD` | ISO code for `currency`. Currency values are shown compact. |
| `decimals` | int | — | Fixed decimals for `number` and `percent` (percent defaults to 1). Without it, `number` shows 0–2 decimals and abbreviates values ≥ 100,000. |
| `unit` | string | — | Appended after the value, e.g. `"ms"`. |
| `delta` | number | — | A fraction: `0.12` shows as ▲ 12%. |
| `positiveIsGood` | bool | `true` | Set `false` so an increase shows red (churn, latency). |
| `caption` | string | — | Small text under the value. |
| `color` | color | primary | Value color (also used for the sparkline). |
| `sparkline` | [number] | `[]` | Tiny trend line under the value. |

### `chart`

| Field | Type | Default | Notes |
|---|---|---|---|
| `label` | string | — | Title above the chart. |
| `kind` | string | `line` | `line`, `area`, `bar`, `pie`, `donut`. Pie and donut use only the first series; `donut` has a hole, `pie` doesn't. |
| `series` | [object] | — | `{ "name", "color", "points" }` (`data` also works in place of `points`). |
| `points` / `data` | points | — | Shorthand for a single series when `series` is absent. The series is named after `label` and takes the top-level `color`. |
| `format`, `currency` | string | `number`, `USD` | Y-axis label format (same formats as `stat`). |
| `height` | number | `110` | In points. |

Points can be written in any of these forms:
- `[{"x": …, "y": 3}]`. `x` can also be `date` or `label`, and `y` can also be `value`.
- `[["2026-11-01", 3], …]`
- `[3, 5, 8]`, which is plotted against 1, 2, 3…

If **every** point's x is a date, the x axis is a time axis. Dates can be ISO-8601 (`2026-11-01T12:00:00Z`), `yyyy-MM-dd`, `yyyy-MM`, or Unix seconds/milliseconds. Otherwise x values are category labels.

### `list`

| Field | Type | Default | Notes |
|---|---|---|---|
| `label` | string | — | Title. |
| `rows` | [object] | `[]` | See below. |
| `limit` | int | `10` | Rows shown before a "Show all N" link. |

Row fields: `title`, `subtitle`, `value` (any scalar, shown on the right as-is), `valueColor`, `icon` (`"sf:star.fill"` for an SF Symbol or an `https://…` image URL), `url` (opens when the row is clicked).

### `text`

| Field | Default | Notes |
|---|---|---|
| `text` | `""` | In the `body` style this renders Markdown (bold, italic, `code`, links). |
| `style` | `body` | `title`, `body`, `caption`, `mono` (monospaced, scrolls horizontally, max 220 pt high). |
| `color` | primary | |

### `progress`

| Field | Default | Notes |
|---|---|---|
| `label` | `""` | |
| `value` | `0` | A fraction from 0 to 1, or a raw amount when `max` is given. The result is clamped to 0…1. |
| `max` | — | If > 0, the bar fills to `value / max`. |
| `caption` | percentage | Text on the right. |
| `color` | accent | Turns red above 90% unless `color` is set. |

### `status`

| Field | Default | Notes |
|---|---|---|
| `label` | `""` | |
| `state` | `info` | Green: `ok`, `up`, `green`, `healthy`, `true`. Orange: `warn`, `warning`, `degraded`, `yellow`. Red: `error`, `down`, `red`, `fail`, `false`. Anything else is blue. |
| `detail` | — | Gray text on the right. |

### Complete example

```json
{"items": [
  {"type": "stat", "label": "MRR", "value": 12840, "format": "currency", "delta": 0.12,
   "sparkline": [9800, 10400, 11500, 12840]},
  {"type": "stat", "label": "Churn", "value": 0.031, "format": "percent", "delta": 0.004, "positiveIsGood": false},
  {"type": "chart", "label": "Signups", "kind": "bar",
   "points": [["2026-11-20", 12], ["2026-11-21", 18], ["2026-11-22", 9]]},
  {"type": "chart", "label": "Plans", "kind": "donut",
   "points": [{"label": "Pro", "value": 60}, {"label": "Team", "value": 40}]},
  {"type": "list", "label": "Latest", "rows": [
    {"title": "Ada", "subtitle": "Team plan", "value": "+$49", "valueColor": "green",
     "icon": "sf:person.crop.circle", "url": "https://example.com/u/ada"}]},
  {"type": "text", "text": "Deploy **v2.3** is live", "style": "body"},
  {"type": "progress", "label": "Goal", "value": 12840, "max": 20000, "caption": "$12.8k / $20k"},
  {"type": "status", "label": "API", "state": "ok", "detail": "99.98%"}
]}
```

[`format-showcase.json`](examples/widgets/format-showcase.json) renders every item type. [`examples/server/node.js`](examples/server/node.js) is a backend with no dependencies that serves this format.

---

## Plain JSON auto-detection

With `display: auto` and no explicit items, SideStats guesses the layout:

| Input | Result |
|---|---|
| `42` | One `stat` labeled with the widget name. |
| `"hello"` | `text` (the `mono` style if it contains newlines). |
| `true` / `false` | A `status` set to ok/error. This applies only at the top level. |
| `[3, 5, 4, 8]` | A line chart. |
| `[["2026-11-01", 3], ["2026-11-02", 5]]` | A line chart. |
| `[{"date": "2026-11-01", "visits": 10, "signups": 2}, …]` | A line chart with one series per numeric key (here Signups and Visits). It becomes an area chart above 40 rows. |
| `[{"name": "alpha", "owner": "me", "stars": 12}, …]` | A list. In this example: title `alpha`, subtitle `me`, value `12`. |
| `{"users": 120, "plan": "pro", "daily": [1,2,3], "limits": {"cpu": 2}}` | Stats `Plan`, `Users`, then a chart `Daily`, then a caption `Limits` with stat `Cpu`. |
| `[]` | The text "Empty list". |

Details:
- **Objects:** each scalar key becomes a stat, sorted by key, with humanized labels (`open_issues_count` becomes "Open issues count", `createdAt` becomes "Created at"). Nested arrays and objects are rendered after the stats, up to two levels deep. A nested object made only of scalars gets a caption header.
- **Arrays of objects** become a **chart** when the first row has an x key: one of `date`, `day`, `time`, `timestamp`, `ts`, `x`, `period`, `month`, `created_at`, `createdAt`, or failing that the first key (alphabetically) whose value is a date *string*. Large numeric ids are never treated as timestamps here. The first row must also have at least one other numeric key, and every numeric key becomes a series. Otherwise they become a **list**:
  - title: the first of `title`, `name`, `label`, `key`, `id`, or failing that the first string key.
  - subtitle: the first other string key (alphabetical, skipping `url` and `icon`).
  - value: the first numeric key.
  - icon: `icon`, `image` or `avatar_url`.
  - click URL: `url`, `html_url` or `link`.
  - The list shows 10 rows before "Show all".
- **Numbers inside strings** (`"59830.55"`) are treated as numbers in stats, so they are formatted.

## jsonPath, fields, display

- **`jsonPath`** is a dot path applied first (after the transform, if there is one): `data`, `data.items`, `result.0` (first element), `items.-1` (last element; negative indexes count from the end). An unknown key or an out-of-range index yields `null`.
- **`fields`** is a comma-separated list such as `stargazers_count,forks_count`. It keeps only these top-level keys, as stats in the order given. Nested arrays and objects are kept only if listed.
- **`display`** forces a layout:

| `display` | What it does |
|---|---|
| `stat` | Uses the object's scalar keys (respects `fields`). Any other value becomes one stat. |
| `chart` | Uses the chart detection above. If no chart is found, the value is shown as pretty-printed JSON. |
| `list` | An array becomes list rows. An object becomes key → value rows, up to 50. |
| `text` | A string stays as-is. Anything else is shown as pretty JSON. |

## Placeholders

These are expanded in `url`, `body` and `command` on every fetch. All dates are `yyyy-MM-dd` in **UTC**.

| Placeholder | Value |
|---|---|
| `{{today}}` | Today. |
| `{{daysAgo:N}}` | N days ago, e.g. `{{daysAgo:30}}`. |
| `{{monthStart}}` | The first day of the current month. |

Example: `https://api.example.com/stats?from={{daysAgo:30}}&to={{today}}`

## Live refresh

- Each widget refreshes every `refreshSeconds`, with a minimum of 5. The ↻ button on the card refreshes it immediately.
- Widgets with `refreshSeconds` ≤ 60 show a pulsing **live** dot. The header shows how long ago the last update was.
- The last raw response is cached on disk, so cards render instantly after a relaunch.
- Changing `display`, `jsonPath` or `fields` re-renders the cached response without refetching. Changing the URL, command, source or body refetches.
- On an error, the previous items stay on screen and the error is shown above them.

---

## Transforms (JavaScript)

A transform turns any response into exactly the cards you want. It runs in a sandboxed JavaScriptCore context (no network, no files, no timers), after the fetch and before `jsonPath`/`display`. Set it in the widget editor under **Transform (JavaScript)** or as `"transform"` in the widget JSON.

The response is available as **`data`**: parsed JSON, or a string when the output wasn't JSON (handy for shell commands). Write it in any of these forms:

```js
data => ({ items: [ item.stat('Users', data.users) ] })        // arrow function
function (d) { return d.results.map(r => item.stat(r.name, r.value)) }
const up = data.filter(m => m.ok); return [item.ok('Up', up.length + '/' + data.length)]   // body with return
data.result.items                                               // plain expression
```

Return the SideStats format (`{items:[…]}` or an array of items) or any JSON for auto-detection. In a returned item array, `null`/`false` entries are dropped and nested arrays are flattened, so `cond ? item.x(…) : null` and `...rows.map(…)` just work.

**Helpers** (globals in every transform):

| Helper | What it does |
|---|---|
| `item.stat(label, value, opts)` | `{type:"stat", label, value, ...opts}`. Every builder also accepts one object: `item.stat({label, value, format})`. |
| `item.chart(label, points, opts)` · `item.list(label, rows, opts)` · `item.text(text, style)` · `item.progress(label, value, max, opts)` · `item.status(label, state, detail)` | The other item types, same pattern. |
| `item.ok(label, detail)` · `item.error(label, detail)` | Green / red status lights. |
| `fmt.num(v, decimals?)` | `1,234` / `12.3` / `1.2M`. |
| `fmt.money(v, cur = 'USD', decimals?)` | `$1,235`, `€12.5K`. |
| `fmt.pct(fraction, decimals = 1)` | `0.123` → `12.3%`. |
| `fmt.bytes(n)` · `fmt.ms(n)` · `fmt.duration(seconds)` | `118 MB` · `230 ms` / `1.2 s` · `3h 12m`. |
| `fmt.ago(isoOrEpoch)` · `fmt.date(v, withTime?)` · `fmt.time(v)` | `5m ago` · `Nov 25` · `14:05`. Accepts ISO strings, `yyyy-MM-dd HH:mm:ss`, Unix seconds or ms. |
| `fmt.plural(n, word)` | `3 alerts`. |
| `num(v)` · `toDate(v)` | Strict number parse (`"1,234"` → 1234, junk → `null`) · Date from ISO/epoch. |
| `sum(arr, key?)` · `avg` · `min` · `max` · `count(arr, pred)` | `key` is a property name, a dot path (`'sum.requests'`) or a function. |
| `groupBy(arr, key)` · `countBy(arr, key)` · `sortBy(arr, key, desc?)` · `uniq(arr, key?)` | Return new values; inputs aren't modified. |
| `lines(text)` · `jsonLines(text)` | Non-empty trimmed lines · NDJSON (`docker ps --format '{{json .}}'`). |
| `level(v, warn, crit)` · `levelColor(v, warn, crit)` | `'ok'/'warn'/'error'` and `'green'/'orange'/'red'` for thresholds. |
| `console.log(…)` | The last lines are shown with any transform error. |

**Example: GitHub issues by label**

```json
{
  "name": "Bugs by label",
  "url": "https://api.github.com/repos/swiftlang/swift/issues?state=open&per_page=100",
  "transform": "const by = countBy(data.flatMap(i => i.labels.map(l => l.name)));\nreturn [\n  item.stat('Open', data.length),\n  item.chart('By label', sortBy(Object.entries(by), 1, true).slice(0, 6).map(([label, value]) => ({label, value})), {kind: 'donut'})\n];"
}
```

**Example: shell output to status lights** (`command`: `launchctl list | grep -E 'nginx|postgres'`)

```js
return lines(data).map(l => {
  const [pid, status, label] = l.split(/\s+/);
  return item.status(label, pid !== '-' ? 'ok' : status === '0' ? 'info' : 'error', pid !== '-' ? 'pid ' + pid : 'exit ' + status);
});
```

**Limits.** A transform may run for 2 seconds; then it is stopped and the widget shows *Transform timed out*. JavaScript errors show the message and line number. Only JSON values come back out (functions and `undefined` are dropped). Transforms run on the main thread, so keep them to simple reshaping.

---

## Integrations

**Settings → Modules → + → Browse integrations…** lists ready-made widgets. Pick one, fill in a few fields (tokens go to the Keychain as request headers), press **Test** to see your real data, then **Add**. Every integration is a normal widget afterwards: its URL or command and its JavaScript transform can be edited, and it can be exported. AI agents can list and add them through the local API (`GET /v1/presets`, `POST /v1/presets/{id}`) and MCP.

Template parameters are written `{{name}}` in the URL, body, command and transform. Variants: `{{name:url}}` (URL-encoded), `{{name:sh}}` (shell-quoted) and `{{name:js}}` (a JSON/JS string literal). The fetch-time placeholders (`{{today}}`, `{{daysAgo:N}}`) and Docker's `{{json .}}` are left alone.

### Monitoring

| Preset id | Shows | Needs |
|---|---|---|
| `grafana-alerts` | **Grafana alerts.** Firing Grafana-managed alerts, critical first. Shows a green “All clear” when nothing fires. | Service account token (Viewer) |
| `grafana-health` | **Grafana health.** Is Grafana up? Version, database status and response time from /api/health. | Nothing |
| `grafana-query` | **Grafana query (chart).** Runs a query through any Grafana datasource (Prometheus, Loki, Mimir, InfluxQL/SQL with a time column) and charts the result. | Service account token (Viewer) |
| `prometheus-query` | **Prometheus query.** Instant PromQL query. One series → big number; a few → stats; many → ranked list. 0/1 results (like `up`) become up/down lights. | Nothing (optional bearer token) |
| `prometheus-range` | **Prometheus chart.** PromQL range query over the last N hours as a line chart, with the latest value on top. | Nothing (optional bearer token) |
| `alertmanager-alerts` | **Alertmanager alerts.** Active (not silenced) alerts from Prometheus Alertmanager, critical first, with links to the source. | Nothing (optional bearer token) |
| `uptime-kuma` | **Uptime Kuma.** Every monitor on an Uptime Kuma status page: up/down, ping and 24 h uptime. No login needed. | A published status page |
| `uptimerobot` | **UptimeRobot.** All UptimeRobot monitors with status, time in current state and last-24 h uptime. | Read-only API key |
| `betterstack-uptime` | **Better Stack Uptime.** Better Stack (Better Uptime) monitors: down and paused ones first, with last check time. | Uptime API token |
| `netdata` | **Netdata node.** CPU chart (last 30 min), load, RAM and alarm counts from a Netdata agent. | Network access to the agent |
| `http-health` | **HTTP health check.** Pings a list of URLs from your Mac in parallel and shows status code and latency for each. Runs locally with curl. | Nothing (uses curl) |
| `ssl-expiry` | **SSL certificate expiry.** Days until the TLS certificate of each domain expires. Orange under 14 days, red under 3. | Nothing (uses curl) |
| `statuspage` | **Status page (Statuspage.io).** Overall status, open incidents and degraded components of any Atlassian Statuspage (GitHub, Cloudflare, OpenAI, Atlassian, Discord…). | Nothing |

### Servers

| Preset id | Shows | Needs |
|---|---|---|
| `mac-system` | **This Mac.** CPU usage, load, memory pressure, disk space, battery and the busiest processes of the Mac running SideStats. | Nothing |
| `ssh-server` | **Linux server (SSH).** CPU, load, memory, disks, temperature, uptime and top processes of a Linux box over SSH. Great for VPSes and Raspberry Pis. | SSH key login (no password prompt) |
| `systemd-units` | **systemd services (SSH).** State of chosen systemd units on a Linux host, plus any failed units, over SSH. | SSH key login |
| `docker-containers` | **Docker containers.** Running, stopped and unhealthy containers with live CPU and memory, via the Docker CLI (local or a remote context). | Docker CLI |
| `kubernetes-pods` | **Kubernetes pods.** Pod health for a namespace (or all): running/pending/failing counts, restarts and CrashLoopBackOff detection via kubectl. | kubectl with a configured context |

### Dev

| Preset id | Shows | Needs |
|---|---|---|
| `github-actions` | **GitHub Actions.** Latest result per workflow, success rate, typical duration and the most recent runs of a repository. | Optional token (required for private repos) |
| `github-repo` | **GitHub repository.** Stars, forks, open issues and watchers of a repository, with its description and last push. | Optional token |
| `github-prs` | **GitHub pull requests.** Open pull requests of a repository: count, drafts, oldest, and the list with authors. | Optional token |
| `github-search` | **GitHub issues & PRs search.** Any GitHub search as a list, e.g. PRs waiting for your review or issues assigned to you across all repos. | Token (for @me / private repos) |
| `sentry-issues` | **Sentry issues.** Unresolved Sentry issues of a project: event volume over 24 h, affected users and the noisiest issues. | Auth token (project:read, event:read) |
| `vercel-deployments` | **Vercel deployments.** Current production deployment status and the latest builds (ready, building, error) with commit messages. | Access token |
| `netlify-deploys` | **Netlify deploys.** Latest Netlify deploys of a site with state, branch, commit title and build time. | Personal access token |
| `cloudflare-analytics` | **Cloudflare zone traffic.** Daily requests, visitors, cache ratio, bandwidth and threats of a Cloudflare zone (GraphQL Analytics API). | API token (Zone Analytics: Read) |
| `npm-downloads` | **npm downloads.** Daily downloads of an npm package over the last month, with this week vs. last week. | Nothing |

### Business

| Preset id | Shows | Needs |
|---|---|---|
| `stripe-balance` | **Stripe balance.** Available and pending Stripe balance, per currency. | Restricted key (Balance: Read) |
| `stripe-revenue` | **Stripe revenue (30 days).** Net charge volume of the last 30 days as a daily bar chart, with order count, average order and latest payments. | Restricted key (Charges: Read) |
| `stripe-mrr` | **Stripe MRR.** Monthly recurring revenue estimated from active subscriptions, with subscriber count, ARPU and plan mix. | Restricted key (Subscriptions: Read) |
| `revenuecat-overview` | **RevenueCat overview.** MRR, revenue (28 d), active subscriptions and trials, new customers and active users from RevenueCat. | Secret API key v2 (charts_metrics:overview:read) |
| `plausible-overview` | **Plausible overview.** Visitors, pageviews, bounce rate and visit duration for a period, with change vs. the previous period. | Stats API key |
| `plausible-realtime` | **Plausible live visitors.** People on your site right now (last 5 minutes). Refreshes every 30 s. | Stats API key |
| `plausible-chart` | **Plausible traffic chart.** Daily visitors and pageviews as a chart (Stats API v2). | Stats API key |
| `paddle-revenue` | **Paddle revenue.** Completed Paddle Billing transactions of the last 30 days: revenue, your earnings after fees, daily chart and latest sales. | API key (transaction.read) |

### Other

| Preset id | Shows | Needs |
|---|---|---|
| `home-assistant` | **Home Assistant.** Live states of chosen Home Assistant entities: sensors as numbers with units, switches, lights and doors as on/off. | Long-lived access token |
| `weather` | **Weather.** Current conditions, the next 24 hours and a 3-day forecast from Open-Meteo. No API key. | Nothing |
| `crypto-prices` | **Crypto prices.** Prices with 24 h change and a 7-day sparkline for any coins on CoinGecko. No API key. | Nothing |
| `stock-price` | **Stock price.** Price, daily change and chart of a stock, ETF, index or FX pair from Yahoo Finance's public chart endpoint. No API key (unofficial). | Nothing (unofficial endpoint) |
| `exchange-rates` | **Exchange rates.** ECB reference rates for a base currency with 30-day change and trend (Frankfurter). No API key. | Nothing |


Command integrations (health checks, SSH, Docker, kubectl) run on your Mac with your login shell, so they see your `~/.ssh/config`, Docker contexts and kubeconfig. SSH integrations use `BatchMode=yes`, so they need key-based login.

---

## Push widgets

A widget with `source: "push"` never fetches. It shows whatever was last sent to it. That suits cron jobs, CI pipelines, scripts on other machines (through an SSH tunnel) and AI agents.

1. **Settings → Modules → + → Push (API / MCP)**. The editor shows the widget ID and a ready-made command.
2. Send any JSON to the local API (it listens on `127.0.0.1` only; the token is in **Settings → API & MCP**):

```sh
curl -X POST http://127.0.0.1:48620/v1/widgets/<widget id>/data \
  -H "Authorization: Bearer $SIDESTATS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"items":[{"type":"stat","label":"Signups","value":42,"delta":0.12},
                {"type":"status","label":"Nightly backup","state":"ok","detail":"3m ago"}]}'
```

The payload goes through the same pipeline as fetched data: the transform, then `jsonPath`/`display`, then auto-detection. You can push raw data and shape it with a transform. The last payload is stored and shown again after a relaunch. Data can also be pushed into `http`/`command` widgets; it is replaced on their next refresh.


## Security

- **Command widgets run arbitrary shell commands as you**, with your login environment. Read every `command` before importing a widget, and only import widgets from people you trust.
- Integrations that need a token send it as a header, so it stays in the Keychain too.
- HTTP headers (tokens) live in the Keychain and are never included in exports. When sharing widgets, leave tokens out of the `url` and `body` as well.
