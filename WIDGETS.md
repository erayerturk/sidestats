# Custom widgets

A widget is a sidebar card that SideStats fills from **any JSON you can fetch**: a URL or a shell command. It refreshes on its own timer and renders the result as stats, charts, lists, text, progress bars and status lights.

Each widget gets its data one of two ways:

| Source | What runs | Notes |
|---|---|---|
| `http` (HTTP API) | `URLRequest` with `method`, optional `body`, and your headers | `Accept: application/json` is always sent. A non-empty `body` adds `Content-Type: application/json`. Timeout is 30 s. |
| `command` (Shell command) | `/bin/zsh -lc "<command>"` | Your login shell environment is loaded (`-l`), so your `PATH` works. The command is killed after 30 s. Only stdout is parsed. A non-zero exit is an error only when stdout is empty, and the error message shows the first 400 bytes of stderr. |

If the output is valid JSON, it is parsed (bare scalars like `42` or `"hi"` count). Anything else is trimmed and shown as text.

Ready-made examples are in [`examples/widgets/`](examples/widgets). [`all-examples.json`](examples/widgets/all-examples.json) imports all of them in one go.

---

## Widget definition (import / export)

A widget is a small JSON object. Every field is optional, and a missing field takes its default:

| Field | Default | Meaning |
|---|---|---|
| `name` | `"New widget"` | Card title. Auto mode also uses it as the label for a top-level scalar. |
| `icon` | `"square.grid.2x2"` | SF Symbol name for the card header. |
| `source` | `"http"` | `"http"` or `"command"`. |
| `url` | `""` | HTTP only. Placeholders are expanded. |
| `method` | `"GET"` | HTTP only. |
| `body` | `""` | HTTP only. Placeholders are expanded. |
| `command` | `""` | Command only. Placeholders are expanded. |
| `jsonPath` | `""` | Picks a sub-value before rendering (see [jsonPath](#jsonpath-fields-display)). |
| `fields` | `""` | Comma-separated keys to keep, in that order (auto and `stat` display). |
| `display` | `"auto"` | `auto`, `stat`, `chart`, `list` or `text`. |
| `refreshSeconds` | `300` | Refresh interval. Values under 5 are raised to 5. |
| `enabled` | `true` | Disabled widgets are hidden and never fetched. |

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

- **`jsonPath`** is a dot path applied before anything else: `data`, `data.items`, `result.0` (first element), `items.-1` (last element; negative indexes count from the end). An unknown key or an out-of-range index yields `null`.
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

## Security

- **Command widgets run arbitrary shell commands as you**, with your login environment. Read every `command` before importing a widget, and only import widgets from people you trust.
- HTTP headers (tokens) live in the Keychain and are never included in exports. When sharing widgets, leave tokens out of the `url` and `body` as well.
