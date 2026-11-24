import Foundation

extension WidgetPresets {
    // MARK: shared params

    static func urlParam(_ label: String, placeholder: String, help: String) -> PresetParam {
        PresetParam(id: "url", label: label, placeholder: placeholder, help: help)
    }
    static func tokenParam(_ label: String = "API token", help: String, optional: Bool = false) -> PresetParam {
        PresetParam(id: "token", label: label, placeholder: optional ? "optional" : "", help: help, secret: true, optional: optional)
    }
    static let formatParam = PresetParam(
        id: "format", label: "Value format", help: "How values are shown: number, percent (0–1 values), percent100 (0–100 values), bytes, or duration (seconds).",
        defaultValue: "number", options: ["number", "percent", "percent100", "bytes", "duration"])

    static let monitoring: [WidgetPreset] = [
        // MARK: Grafana
        WidgetPreset(
            id: "grafana-alerts", name: "Grafana alerts", category: "Monitoring", icon: "bell.badge",
            summary: "Firing Grafana-managed alerts, critical first. Shows a green “All clear” when nothing fires.",
            params: [
                urlParam("Grafana URL", placeholder: "https://grafana.example.com", help: "Base URL of your Grafana (Cloud or self-hosted), without a trailing slash."),
                tokenParam("Service account token", help: "Administration → Users and access → Service accounts → add a Viewer account → Add token (glsa_…).", optional: true),
                PresetParam(id: "labels", label: "Label filter", placeholder: "severity=critical, team!=infra", help: "Optional comma-separated label matchers (k=v or k!=v). Leave empty for all alerts.", optional: true),
            ],
            template: http("Grafana alerts", icon: "bell.badge",
                           url: "{{url}}/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false",
                           refresh: 60, transform: "const labelFilter = {{labels:js}};\n" + PresetJS.alerts),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://grafana.com/docs/grafana/latest/developers/http_api/alerting_provisioning/",
            requires: "Service account token (Viewer)",
            sample: #"[{"annotations":{"summary":"CPU above 90% for 10m"},"endsAt":"2026-11-25T12:04:00Z","fingerprint":"a1","receivers":[{"name":"ops"}],"startsAt":"2026-11-25T09:12:00Z","status":{"inhibitedBy":[],"silencedBy":[],"state":"active"},"updatedAt":"2026-11-25T11:59:00Z","generatorURL":"https://grafana.example.com/alerting/grafana/abc/view","labels":{"alertname":"HighCPU","grafana_folder":"Infra","instance":"web-1:9100","severity":"critical"}},{"annotations":{"summary":"Disk 82% full"},"startsAt":"2026-11-24T22:40:00Z","status":{"inhibitedBy":[],"silencedBy":[],"state":"active"},"generatorURL":"","labels":{"alertname":"DiskFilling","grafana_folder":"Infra","instance":"db-1:9100","severity":"warning"}}]"#),

        WidgetPreset(
            id: "grafana-health", name: "Grafana health", category: "Monitoring", icon: "heart.text.square",
            summary: "Is Grafana up? Version, database status and response time from /api/health.",
            params: [urlParam("Grafana URL", placeholder: "https://grafana.example.com", help: "Base URL of your Grafana. /api/health needs no login.")],
            template: command("Grafana", icon: "heart.text.square",
                              command: #"curl -sS -m 10 -w '\n%{http_code} %{time_total}' {{url:sh}}/api/health 2>&1"#,
                              refresh: 60, transform: PresetJS.curlResult + #"""
            const r = curlResult(data);
            if (!r.json) return [item.error('Grafana', r.error || ('HTTP ' + r.code)), item.stat('Response', Math.round(r.ms), { unit: 'ms', decimals: 0, color: 'red' })];
            return [
              item.status('Grafana', r.code === '200' ? 'ok' : 'error', 'v' + (r.json.version || '?') + (r.code === '200' ? '' : ' · HTTP ' + r.code)),
              item.status('Database', r.json.database === 'ok' ? 'ok' : 'error', r.json.database || 'unknown'),
              item.stat('Response time', Math.round(r.ms), { unit: 'ms', color: r.ms > 1000 ? 'orange' : 'green' })
            ];
            """#),
            docs: "https://grafana.com/docs/grafana/latest/developers/http_api/other/#health-api",
            sample: "{\"commit\":\"abc123\",\"database\":\"ok\",\"version\":\"11.3.0\"}\n200 0.084"),

        WidgetPreset(
            id: "grafana-query", name: "Grafana query (chart)", category: "Monitoring", icon: "chart.xyaxis.line",
            summary: "Runs a query through any Grafana datasource (Prometheus, Loki, Mimir, InfluxQL/SQL with a time column) and charts the result.",
            params: [
                urlParam("Grafana URL", placeholder: "https://grafana.example.com", help: "Base URL of your Grafana."),
                tokenParam("Service account token", help: "A Viewer service account token (glsa_…) with access to the datasource."),
                PresetParam(id: "datasource", label: "Datasource UID", placeholder: "P1809F7CD0C75ACF3", help: "Connections → Data sources → open one: the UID is the last part of the page URL."),
                PresetParam(id: "expr", label: "Query", placeholder: "sum(rate(http_requests_total[5m]))", help: "PromQL/LogQL expression (sent as expr), or SQL (sent as rawSql)."),
                PresetParam(id: "title", label: "Title", placeholder: "Requests/s", help: "Widget and chart title.", defaultValue: "Grafana query"),
                PresetParam(id: "range", label: "Time range", help: "How far back to chart.", defaultValue: "6h", options: ["1h", "3h", "6h", "12h", "24h", "2d", "7d"]),
                formatParam,
            ],
            template: http("{{title}}", icon: "chart.xyaxis.line", url: "{{url}}/api/ds/query", method: "POST",
                           body: #"{"queries":[{"refId":"A","datasource":{"uid":{{datasource:js}}},"expr":{{expr:js}},"rawSql":{{expr:js}},"query":{{expr:js}},"format":"time_series","range":true,"instant":false,"intervalMs":60000,"maxDataPoints":120}],"from":"now-{{range}}","to":"now"}"#,
                           refresh: 120, transform: PresetJS.series + "const title = {{title:js}}, format = {{format:js}};\n" + #"""
            const res = data.results || {};
            const r = res.A || Object.values(res)[0];
            if (!r) throw new Error('No results in the response');
            if (r.error) throw new Error(r.error);
            const f = scaleFormat(format);
            let series = [];
            (r.frames || []).forEach(fr => {
              const fields = (fr.schema || {}).fields || [], vals = (fr.data || {}).values || [];
              const ti = fields.findIndex(x => x.type === 'time');
              if (ti < 0) return;
              fields.forEach((fd, i) => {
                if (i === ti || fd.type !== 'number' || !vals[i]) return;
                const points = vals[ti].map((t, k) => [t, num(vals[i][k])]).filter(p => p[1] !== null).map(p => [p[0], p[1] * f.scale]);
                const cfg = fd.config || {};
                series.push({ labels: fd.labels || {}, display: cfg.displayNameFromDS || cfg.displayName, fallback: fr.schema.name || fd.name, points });
              });
            });
            series = series.filter(s => s.points.length);
            if (!series.length) return [item.text('No data in the selected range', 'caption')];
            const names = seriesNames(series.map(s => s.labels), title);
            series.forEach((s, i) => s.name = Object.keys(s.labels).length ? names[i] : (s.display || s.fallback));
            series = sortBy(series, s => s.points[s.points.length - 1][1], true);
            const last = s => s.points[s.points.length - 1][1];
            const head = series.length === 1
              ? [item.stat(series[0].name === title ? 'Now' : series[0].name, last(series[0]), { format: f.format,
                  caption: 'min ' + formatValue(min(series[0].points, 1) / f.scale, format) + ' · max ' + formatValue(max(series[0].points, 1) / f.scale, format) }) ]
              : series.slice(0, 3).map(s => item.stat(s.name, last(s), { format: f.format }));
            return [
              ...head,
              item.chart(null, null, { kind: series.length === 1 ? 'area' : 'line', format: f.format,
                series: series.slice(0, 6).map(s => ({ name: s.name, points: s.points })) })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://grafana.com/docs/grafana/latest/developers/http_api/data_source/#query-a-data-source",
            requires: "Service account token (Viewer)",
            sample: #"{"results":{"A":{"status":200,"frames":[{"schema":{"refId":"A","name":"","fields":[{"name":"Time","type":"time","typeInfo":{"frame":"time.Time"}},{"name":"Value","type":"number","labels":{"instance":"web-1"},"config":{"displayNameFromDS":""}}]},"data":{"values":[[1764054000000,1764057600000,1764061200000,1764064800000,1764068400000],[12.5,18.2,15.1,22.8,19.4]]}},{"schema":{"refId":"A","fields":[{"name":"Time","type":"time"},{"name":"Value","type":"number","labels":{"instance":"web-2"}}]},"data":{"values":[[1764054000000,1764057600000,1764061200000,1764064800000,1764068400000],[8.1,9.4,11.0,10.2,9.9]]}}]}}}"#),

        // MARK: Prometheus / Alertmanager
        WidgetPreset(
            id: "prometheus-query", name: "Prometheus query", category: "Monitoring", icon: "flame",
            summary: "Instant PromQL query. One series → big number; a few → stats; many → ranked list. 0/1 results (like `up`) become up/down lights.",
            params: [
                urlParam("Prometheus URL", placeholder: "http://localhost:9090", help: "Base URL of Prometheus, Thanos, Mimir (…/prometheus) or VictoriaMetrics."),
                PresetParam(id: "query", label: "PromQL", placeholder: "up", help: "Any instant query, e.g. `up`, `100 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100`.", defaultValue: "up"),
                PresetParam(id: "title", label: "Title", placeholder: "Targets", help: "Widget title.", defaultValue: "Prometheus"),
                formatParam,
                PresetParam(id: "warn", label: "Warn at", placeholder: "80", help: "Optional: values at or above this turn orange (set warn > crit when lower is worse).", optional: true),
                PresetParam(id: "crit", label: "Critical at", placeholder: "90", help: "Optional: values at or above this turn red.", optional: true),
                tokenParam("Bearer token", help: "Only if your Prometheus sits behind bearer auth.", optional: true),
            ],
            template: http("{{title}}", icon: "flame", url: "{{url}}/api/v1/query?query={{query:url}}", refresh: 30,
                           transform: PresetJS.series + "const title = {{title:js}}, format = {{format:js}}, warn = {{warn:js}}, crit = {{crit:js}};\n" + #"""
            if (data.status !== 'success') throw new Error(data.error || 'Query failed');
            const d = data.data || {};
            let rows;
            if (d.resultType === 'scalar' || d.resultType === 'string') rows = [{ metric: {}, v: num(d.result[1]) }];
            else rows = (d.result || []).map(r => ({ metric: r.metric || {}, v: num(r.value ? r.value[1] : (r.values || []).slice(-1)[0]?.[1]) }));
            if (!rows.length) return [item.status(title, 'info', 'No series match')];
            const names = seriesNames(rows.map(r => r.metric), title);
            rows.forEach((r, i) => r.name = names[i]);
            const f = scaleFormat(format);
            const binary = format === 'number' && !warn && !crit && rows.every(r => r.v === 0 || r.v === 1);
            if (binary && rows.length <= 16) {
              const down = rows.filter(r => r.v === 0);
              return [
                rows.length > 1 ? item.stat('Up', rows.length - down.length, { caption: 'of ' + rows.length, color: down.length ? 'orange' : 'green' }) : null,
                rows.length > 1 ? item.stat('Down', down.length, { color: down.length ? 'red' : 'secondary' }) : null,
                ...sortBy(rows, 'v').map(r => item.status(r.name, r.v ? 'ok' : 'error', r.v ? 'up' : 'down'))
              ];
            }
            const stat = r => item.stat(rows.length === 1 ? title : r.name, r.v === null ? '—' : r.v * f.scale,
                                        { format: f.format, color: thresholdColor(r.v, warn, crit) });
            if (rows.length <= 6) return rows.map(stat);
            const sorted = sortBy(rows, 'v', true);
            return [
              item.stat('Series', rows.length), item.stat('Total', sum(rows, 'v') * f.scale, { format: f.format }),
              item.list(null, sorted.map(r => ({ title: r.name, value: formatValue(r.v, format), valueColor: thresholdColor(r.v, warn, crit) })), { limit: 10 })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://prometheus.io/docs/prometheus/latest/querying/api/#instant-queries",
            requires: "Nothing (optional bearer token)",
            sample: #"{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"up","instance":"localhost:9090","job":"prometheus"},"value":[1764068400.123,"1"]},{"metric":{"__name__":"up","instance":"web-1:9100","job":"node"},"value":[1764068400.123,"1"]},{"metric":{"__name__":"up","instance":"db-1:9100","job":"node"},"value":[1764068400.123,"0"]}]}}"#),

        WidgetPreset(
            id: "prometheus-range", name: "Prometheus chart", category: "Monitoring", icon: "chart.line.uptrend.xyaxis",
            summary: "PromQL range query over the last N hours as a line chart, with the latest value on top.",
            params: [
                urlParam("Prometheus URL", placeholder: "http://localhost:9090", help: "Base URL of Prometheus (or a compatible API)."),
                PresetParam(id: "query", label: "PromQL", placeholder: "sum(rate(http_requests_total[5m]))", help: "Range-compatible expression. Each returned series becomes a line (top 6 shown)."),
                PresetParam(id: "title", label: "Title", placeholder: "Requests/s", help: "Widget title.", defaultValue: "Prometheus chart"),
                PresetParam(id: "hours", label: "Hours", placeholder: "6", help: "How many hours to chart (1–168).", defaultValue: "6"),
                formatParam,
                tokenParam("Bearer token", help: "Only if your Prometheus sits behind bearer auth.", optional: true),
            ],
            template: http("{{title}}", icon: "chart.line.uptrend.xyaxis",
                           url: "{{url}}/api/v1/query_range?query={{query:url}}&start={{daysAgo:{{lookbackDays}}}}T00:00:00Z&end={{today}}T23:59:59Z&step={{step}}",
                           refresh: 120, transform: PresetJS.series + "const title = {{title:js}}, format = {{format:js}}, hours = Number({{hours:js}}) || 6;\n" + #"""
            if (data.status !== 'success') throw new Error(data.error || 'Query failed');
            const from = Date.now() / 1000 - hours * 3600, f = scaleFormat(format);
            let series = ((data.data || {}).result || []).map(r => ({
              metric: r.metric || {},
              points: (r.values || []).filter(p => p[0] >= from).map(p => [p[0], num(p[1])]).filter(p => p[1] !== null).map(p => [p[0], p[1] * f.scale])
            })).filter(s => s.points.length);
            if (!series.length) return [item.text('No data in the last ' + hours + ' h', 'caption')];
            const names = seriesNames(series.map(s => s.metric), title);
            series.forEach((s, i) => s.name = names[i]);
            const last = s => s.points[s.points.length - 1][1];
            series = sortBy(series, last, true);
            const head = series.length === 1
              ? [item.stat('Now', last(series[0]), { format: f.format, sparkline: undefined,
                  caption: 'avg ' + formatValue(avg(series[0].points, 1) / f.scale, format) + ' · max ' + formatValue(max(series[0].points, 1) / f.scale, format) })]
              : series.slice(0, 3).map(s => item.stat(s.name, last(s), { format: f.format }));
            return [...head, item.chart(null, null, { kind: series.length === 1 ? 'area' : 'line', format: f.format,
                    series: series.slice(0, 6).map(s => ({ name: s.name, points: s.points })) })];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://prometheus.io/docs/prometheus/latest/querying/api/#range-queries",
            requires: "Nothing (optional bearer token)",
            derive: { v in
                let h = min(max(Int(v["hours"] ?? "") ?? 6, 1), 168)
                return ["lookbackDays": String((h + 23) / 24), "step": String(max(15, h * 3600 / 150)) + "s"]
            },
            sample: #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"job":"api"},"values":[[4102444800,"10"]]}]}}"#),

        WidgetPreset(
            id: "alertmanager-alerts", name: "Alertmanager alerts", category: "Monitoring", icon: "bell.and.waves.left.and.right",
            summary: "Active (not silenced) alerts from Prometheus Alertmanager, critical first, with links to the source.",
            params: [
                urlParam("Alertmanager URL", placeholder: "http://localhost:9093", help: "Base URL of Alertmanager (or Mimir's …/alertmanager)."),
                PresetParam(id: "labels", label: "Label filter", placeholder: "severity=critical", help: "Optional comma-separated label matchers (k=v or k!=v).", optional: true),
                tokenParam("Bearer token", help: "Only if Alertmanager sits behind bearer auth.", optional: true),
            ],
            template: http("Alerts", icon: "bell.and.waves.left.and.right",
                           url: "{{url}}/api/v2/alerts?active=true&silenced=false&inhibited=false", refresh: 60,
                           transform: "const labelFilter = {{labels:js}};\n" + PresetJS.alerts),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml",
            requires: "Nothing (optional bearer token)",
            sample: "[]"),

        // MARK: uptime services
        WidgetPreset(
            id: "uptime-kuma", name: "Uptime Kuma", category: "Monitoring", icon: "waveform.path.ecg",
            summary: "Every monitor on an Uptime Kuma status page: up/down, ping and 24 h uptime. No login needed.",
            params: [
                urlParam("Uptime Kuma URL", placeholder: "https://status.example.com", help: "Base URL of your Uptime Kuma instance."),
                PresetParam(id: "slug", label: "Status page slug", placeholder: "default", help: "The part after /status/ in your status page URL. The page must be published."),
            ],
            template: command("Uptime Kuma", icon: "waveform.path.ecg",
                              command: #"b={{url:sh}}; s={{slug:sh}}; printf '{"page":%s,"beats":%s}' "$(curl -fsS -m 12 "$b/api/status-page/$s" 2>/dev/null || echo null)" "$(curl -fsS -m 12 "$b/api/status-page/heartbeat/$s" 2>/dev/null || echo null)""#,
                              refresh: 60, transform: #"""
            if (!data || typeof data !== 'object' || !data.page || !data.beats)
              return [item.error('Uptime Kuma', 'Status page not reachable (check URL, slug and that it is published)')];
            const hb = data.beats.heartbeatList || {}, up = data.beats.uptimeList || {};
            const monitors = [].concat(...(data.page.publicGroupList || []).map(g => g.monitorList || []));
            if (!monitors.length) return [item.status(data.page.config?.title || 'Status page', 'info', 'No monitors on this page')];
            const STATE = { 0: 'error', 1: 'ok', 2: 'warn', 3: 'info' }, WORD = { 0: 'down', 1: 'up', 2: 'pending', 3: 'maintenance' };
            const rows = monitors.map(m => {
              const beats = hb[m.id] || hb[String(m.id)] || [], last = beats[beats.length - 1];
              let u = up[m.id + '_24']; if (u !== undefined && u > 1) u /= 100;
              return { name: m.name, status: last ? last.status : 2, ping: last ? num(last.ping) : null, uptime: u, since: last && last.time, beats };
            });
            const down = count(rows, r => r.status === 0), pending = count(rows, r => r.status === 2);
            const pings = rows.map(r => r.ping).filter(p => p !== null);
            const spark = [];
            for (let i = 0; i < 30; i++) {
              const vals = rows.map(r => r.beats[r.beats.length - 30 + i]).filter(Boolean).map(b => num(b.ping)).filter(p => p !== null);
              if (vals.length) spark.push(Math.round(avg(vals)));
            }
            const detail = r => [r.ping !== null ? Math.round(r.ping) + ' ms' : WORD[r.status], r.uptime !== undefined ? fmt.pct(r.uptime, r.uptime > 0.9995 ? 0 : 2) : null].filter(Boolean).join(' · ');
            const ordered = sortBy(rows, r => ({ 0: 0, 2: 1, 3: 2, 1: 3 })[r.status] ?? 9);
            return [
              item.status(down ? fmt.plural(down, 'monitor') + ' down' : pending ? 'Some checks pending' : 'All systems operational',
                          down ? 'error' : pending ? 'warn' : 'ok', (rows.length - down) + '/' + rows.length + ' up'),
              item.stat('Avg ping', pings.length ? Math.round(avg(pings)) : '—', { unit: 'ms', sparkline: spark }),
              item.stat('Uptime 24h', avg(rows, 'uptime'), { format: 'percent', decimals: 2, color: (avg(rows, 'uptime') ?? 1) < 0.99 ? 'orange' : 'green' }),
              ...(rows.length <= 12
                ? ordered.map(r => item.status(r.name, STATE[r.status] || 'info', detail(r)))
                : [item.list(null, ordered.map(r => ({ title: r.name, value: detail(r), valueColor: { 0: 'red', 1: 'green', 2: 'orange' }[r.status] || 'secondary',
                    icon: r.status === 1 ? 'sf:checkmark.circle.fill' : r.status === 0 ? 'sf:xmark.circle.fill' : 'sf:clock' })), { limit: 12 })])
            ];
            """#),
            docs: "https://github.com/louislam/uptime-kuma/wiki/Status-Page",
            requires: "A published status page",
            sample: #"{"page":{"config":{"slug":"default","title":"Homelab"},"incidents":[],"maintenanceList":[],"publicGroupList":[{"id":1,"name":"Services","monitorList":[{"id":1,"name":"Website","type":"http"},{"id":2,"name":"API","type":"http"},{"id":3,"name":"NAS","type":"ping"}]}]},"beats":{"heartbeatList":{"1":[{"status":1,"time":"2026-11-25 10:00:00","msg":"","ping":41},{"status":1,"time":"2026-11-25 10:01:00","msg":"","ping":45}],"2":[{"status":1,"time":"2026-11-25 10:00:00","msg":"","ping":120},{"status":0,"time":"2026-11-25 10:01:00","msg":"","ping":null}],"3":[{"status":1,"time":"2026-11-25 10:01:00","msg":"","ping":3}]},"uptimeList":{"1_24":1,"2_24":0.9861,"3_24":0.9993}}}"#),

        WidgetPreset(
            id: "uptimerobot", name: "UptimeRobot", category: "Monitoring", icon: "dot.radiowaves.left.and.right",
            summary: "All UptimeRobot monitors with status, time in current state and last-24 h uptime.",
            params: [tokenParam("API key", help: "Integrations & API → API → create a Read-Only API key (or the Main key).")],
            template: http("UptimeRobot", icon: "dot.radiowaves.left.and.right", url: "https://api.uptimerobot.com/v3/monitors?limit=200", refresh: 120, transform: #"""
            // API v3 (Bearer). Also understands the v2 getMonitors shape.
            const v2 = Array.isArray(data.monitors);
            const list = v2 ? data.monitors : (data.data || []);
            if (!list.length) return [item.status('UptimeRobot', 'info', 'No monitors yet')];
            const V2 = { 0: 'PAUSED', 1: 'STARTED', 2: 'UP', 8: 'LOOKS_DOWN', 9: 'DOWN' };
            const rows = list.map(m => {
              const status = v2 ? V2[m.status] : String(m.status || '').toUpperCase();
              const h = (m.lastDayUptimes || {}).histogram || [];
              let u = h.length ? avg(h, 'uptime') : (v2 ? num(String(m.custom_uptime_ratio || '').split('-')[0]) : null);
              if (u !== null && u > 1) u /= 100;
              return { name: m.friendlyName || m.friendly_name || m.url, status, uptime: u, dur: m.currentStateDuration };
            });
            const STATE = { UP: 'ok', DOWN: 'error', LOOKS_DOWN: 'warn', PAUSED: 'info', STARTED: 'info' };
            const down = count(rows, r => r.status === 'DOWN' || r.status === 'LOOKS_DOWN');
            const active = rows.filter(r => r.status !== 'PAUSED');
            const order = { DOWN: 0, LOOKS_DOWN: 1, STARTED: 2, UP: 3, PAUSED: 4 };
            const detail = r => [r.status === 'UP' ? 'up' : r.status.toLowerCase().replace('_', ' '), r.dur ? fmt.duration(r.dur) : null,
                                 r.uptime !== null ? fmt.pct(r.uptime, r.uptime > 0.9995 ? 0 : 2) : null].filter(Boolean).join(' · ');
            const sorted = sortBy(rows, r => order[r.status] ?? 5);
            return [
              item.status(down ? fmt.plural(down, 'monitor') + ' down' : 'All monitors up', down ? 'error' : 'ok', (active.length - down) + '/' + active.length + ' up'),
              ...(rows.length <= 12 ? sorted.map(r => item.status(r.name, STATE[r.status] || 'info', detail(r)))
                : [item.list(null, sorted.map(r => ({ title: r.name, value: detail(r), valueColor: { UP: 'green', DOWN: 'red', LOOKS_DOWN: 'orange' }[r.status] || 'secondary' })), { limit: 12 })])
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://uptimerobot.com/api/v3/",
            requires: "Read-only API key",
            sample: #"{"nextLink":null,"data":[{"id":800000001,"friendlyName":"Website","url":"https://example.com","type":"HTTP","status":"UP","interval":300,"currentStateDuration":864000,"lastDayUptimes":{"bucketSize":3600,"histogram":[{"timestamp":1764054000,"uptime":100},{"timestamp":1764057600,"uptime":100}]}},{"id":800000002,"friendlyName":"API","url":"https://api.example.com/health","type":"HTTP","status":"DOWN","interval":60,"currentStateDuration":420,"lastDayUptimes":{"bucketSize":3600,"histogram":[{"timestamp":1764054000,"uptime":100},{"timestamp":1764057600,"uptime":93.5}]}}]}"#),

        WidgetPreset(
            id: "betterstack-uptime", name: "Better Stack Uptime", category: "Monitoring", icon: "checkmark.shield",
            summary: "Better Stack (Better Uptime) monitors: down and paused ones first, with last check time.",
            params: [tokenParam("API token", help: "Better Stack → Uptime → API tokens (team-scoped token).")],
            template: http("Better Stack", icon: "checkmark.shield", url: "https://uptime.betterstack.com/api/v2/monitors?per_page=100", refresh: 120, transform: #"""
            const list = (data.data || []).map(m => ({ id: m.id, ...(m.attributes || {}) }));
            if (!list.length) return [item.status('Better Stack', 'info', 'No monitors yet')];
            const STATE = { up: 'ok', down: 'error', validating: 'warn', pending: 'warn', paused: 'info', maintenance: 'info' };
            const order = { down: 0, validating: 1, pending: 2, maintenance: 3, up: 4, paused: 5 };
            const down = count(list, m => m.status === 'down');
            const active = list.filter(m => m.status !== 'paused');
            const name = m => m.pronounceable_name || (m.url || '').replace(/^https?:\/\//, '') || ('Monitor ' + m.id);
            const detail = m => [m.status, m.last_checked_at ? fmt.ago(m.last_checked_at) : null].filter(Boolean).join(' · ');
            const sorted = sortBy(list, m => order[m.status] ?? 9);
            return [
              item.status(down ? fmt.plural(down, 'monitor') + ' down' : 'All monitors up', down ? 'error' : 'ok', (active.length - down) + '/' + active.length + ' up'),
              ...(list.length <= 12 ? sorted.map(m => item.status(name(m), STATE[m.status] || 'info', detail(m)))
                : [item.list(null, sorted.map(m => ({ title: name(m), subtitle: m.url, value: m.status,
                    valueColor: { up: 'green', down: 'red', validating: 'orange', pending: 'orange' }[m.status] || 'secondary' })), { limit: 12 })])
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://betterstack.com/docs/uptime/api/list-all-existing-monitors/",
            requires: "Uptime API token",
            sample: #"{"data":[{"id":"2","type":"monitor","attributes":{"url":"https://uptime.betterstack.com","pronounceable_name":"Uptime homepage","monitor_type":"keyword","last_checked_at":"2026-11-25T11:57:46.000Z","status":"up","paused":false}},{"id":"3","type":"monitor","attributes":{"url":"https://example.com/health","pronounceable_name":"API health","monitor_type":"status","last_checked_at":"2026-11-25T11:58:02.000Z","status":"down","paused":false}}],"pagination":{"next":null}}"#),

        WidgetPreset(
            id: "netdata", name: "Netdata node", category: "Monitoring", icon: "gauge.with.dots.needle.67percent",
            summary: "CPU chart (last 30 min), load, RAM and alarm counts from a Netdata agent.",
            params: [urlParam("Netdata URL", placeholder: "http://server.local:19999", help: "Base URL of a Netdata agent (port 19999 by default) or a parent node.")],
            template: command("Netdata", icon: "gauge.with.dots.needle.67percent",
                              command: #"b={{url:sh}}; q() { curl -fsS -m 10 "$b/api/v1/$1" 2>/dev/null || echo null; }; printf '{"info":%s,"cpu":%s,"ram":%s,"load":%s}' "$(q info)" "$(q 'data?chart=system.cpu&after=-1800&points=60&group=average&format=json')" "$(q 'data?chart=system.ram&after=-10&points=1&format=json')" "$(q 'data?chart=system.load&after=-10&points=1&format=json')""#,
                              refresh: 30, transform: #"""
            if (!data || typeof data !== 'object' || !data.info) return [item.error('Netdata', 'Agent not reachable')];
            const tbl = t => { t = t && (t.result || t); if (!t || !t.labels) return []; return sortBy(t.data || [], 0).map(r => Object.fromEntries(t.labels.map((l, i) => [l, r[i]]))); };
            const dims = r => Object.entries(r).filter(([k, v]) => k !== 'time' && v !== null).map(e => e[1]);
            const cpu = tbl(data.cpu).filter(r => dims(r).length).map(r => [r.time, sum(dims(r))]);
            const ram = tbl(data.ram).slice(-1)[0] || {}, load = tbl(data.load).slice(-1)[0] || {};
            const ramTotal = sum(Object.entries(ram).filter(([k]) => k !== 'time').map(e => e[1]));
            const a = data.info.alarms || {}, host = (data.info.mirrored_hosts || [])[0] || data.info.hostname || 'Node';
            const nowCpu = cpu.length ? cpu[cpu.length - 1][1] : null;
            return [
              item.status(host, a.critical ? 'error' : a.warning ? 'warn' : 'ok',
                          a.critical || a.warning ? [a.critical && a.critical + ' critical', a.warning && a.warning + ' warning'].filter(Boolean).join(', ') : 'no active alarms'),
              item.stat('CPU', nowCpu === null ? '—' : nowCpu / 100, { format: 'percent', color: levelColor(nowCpu, 70, 90) }),
              item.stat('Load', num(load.load1), { decimals: 2, caption: data.info.cores_total ? data.info.cores_total + ' cores' : undefined }),
              item.stat('RAM used', ramTotal ? ram.used / ramTotal : '—', { format: 'percent', color: levelColor(ramTotal ? ram.used / ramTotal * 100 : null, 80, 92),
                caption: ramTotal ? fmt.bytes(ram.used * 1048576) + ' of ' + fmt.bytes(ramTotal * 1048576) : undefined }),
              cpu.length ? item.chart('CPU % (30 min)', cpu, { kind: 'area', height: 80 }) : null
            ];
            """#),
            docs: "https://learn.netdata.cloud/docs/",
            requires: "Network access to the agent",
            sample: #"{"info":{"version":"v1.47.0","mirrored_hosts":["web-1"],"cores_total":"4","alarms":{"normal":120,"warning":1,"critical":0}},"cpu":{"labels":["time","guest_nice","guest","steal","softirq","irq","user","system","nice","iowait"],"data":[[1764068400,0,0,0,0.5,0,12.1,4.2,0,0.3],[1764068370,0,0,0,0.4,0,10.0,3.9,0,0.2]]},"ram":{"labels":["time","free","used","cached","buffers"],"data":[[1764068400,1200.5,2900.2,3600.1,180.3]]},"load":{"labels":["time","load1","load5","load15"],"data":[[1764068400,0.42,0.51,0.48]]}}"#),

        // MARK: generic checks
        WidgetPreset(
            id: "http-health", name: "HTTP health check", category: "Monitoring", icon: "stethoscope",
            summary: "Pings a list of URLs from your Mac in parallel and shows status code and latency for each. Runs locally with curl.",
            params: [
                PresetParam(id: "urls", label: "URLs", placeholder: "https://example.com, https://api.example.com/health", help: "Comma-separated URLs. Redirects are followed."),
                PresetParam(id: "slow", label: "Slow above (ms)", placeholder: "1000", help: "Responses slower than this are shown orange.", defaultValue: "1000"),
                PresetParam(id: "timeout", label: "Timeout (s)", placeholder: "10", help: "Per-URL timeout in seconds (max 25).", defaultValue: "10"),
            ],
            template: command("Health checks", icon: "stethoscope",
                              command: PresetJS.forEachCSV("urls", #"r=$(curl -s -o /dev/null -L -m {{timeout}} -w '%{http_code} %{time_total}' "$x"); printf '%s\t%s\t%s\n' "$x" "$r" "$?""#),
                              refresh: 60, transform: "const slow = Number({{slow:js}}) || 1000, order = {{urls:js}}.split(',').map(s => s.trim());\n" + #"""
            const ERR = { 6: 'DNS failed', 7: 'refused', 28: 'timeout', 35: 'TLS error', 51: 'bad certificate', 52: 'empty reply', 56: 'connection reset', 60: 'bad certificate' };
            const rows = lines(data).map(l => {
              const [url, res = '', exit] = l.split('\t'), [code, secs] = res.trim().split(/\s+/); const ms = Math.round((num(secs) || 0) * 1000), c = num(code) || 0, e = num(exit) || 0;
              const state = e && !c ? 'error' : c >= 500 || c === 0 ? 'error' : c >= 400 ? 'warn' : ms > slow ? 'warn' : 'ok';
              const label = url.replace(/^https?:\/\//, '').replace(/\/$/, '');
              return { url, label, state, ms, detail: c ? c + ' · ' + fmt.ms(ms) : (ERR[e] || 'failed (' + e + ')') };
            });
            if (!rows.length) return [item.text('Add at least one URL', 'caption')];
            rows.sort((a, b) => order.indexOf(a.url) - order.indexOf(b.url));
            const bad = count(rows, r => r.state === 'error'), up = rows.filter(r => r.state !== 'error');
            return [
              rows.length > 1 ? item.stat('Up', up.length, { caption: 'of ' + rows.length, color: bad ? 'red' : 'green' }) : null,
              rows.length > 1 ? item.stat('Avg latency', Math.round(avg(up, 'ms') ?? 0), { unit: 'ms', color: (avg(up, 'ms') ?? 0) > slow ? 'orange' : undefined }) : null,
              ...rows.map(r => item.status(r.label, r.state, r.detail))
            ];
            """#),
            docs: "https://curl.se/docs/manpage.html#-w",
            requires: "Nothing (uses curl)",
            sample: "https://example.com\t200 0.231\t0\nhttps://api.example.com/health\t503 0.120\t0\nhttps://nope.invalid\t000 0.004\t6"),

        WidgetPreset(
            id: "ssl-expiry", name: "SSL certificate expiry", category: "Monitoring", icon: "lock.shield",
            summary: "Days until the TLS certificate of each domain expires. Orange under 14 days, red under 3.",
            params: [PresetParam(id: "domains", label: "Domains", placeholder: "example.com, api.example.com:8443", help: "Comma-separated host names (optionally host:port or full URLs).")],
            template: command("Certificates", icon: "lock.shield",
                              command: PresetJS.forEachCSV("domains", #"h=${x#*://}; h=${h%%/*}; e=$(curl -svkI -m 10 -o /dev/null "https://$h" 2>&1 | grep -i 'expire date' | head -1 | sed 's/.*expire date: *//'); printf '%s\t%s\n' "$h" "$e""#),
                              refresh: 21600, transform: #"""
            const M = { jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5, jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11 };
            const parse = s => {   // "Jan 27 23:59:59 2027 GMT"
              const m = /([A-Za-z]{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d{4})/.exec(s || '');
              return m ? new Date(Date.UTC(+m[6], M[m[1].toLowerCase()], +m[2], +m[3], +m[4], +m[5])) : toDate(s);
            };
            const rows = lines(data).map(l => { const [host, exp] = l.split('\t'); const d = parse(exp); return { host, d, days: d ? (d - Date.now()) / 864e5 : null }; });
            if (!rows.length) return [item.text('Add at least one domain', 'caption')];
            return sortBy(rows, r => r.days ?? -1e9).map(r => item.status(r.host,
              r.days === null || r.days < 3 ? 'error' : r.days < 14 ? 'warn' : 'ok',
              r.days === null ? 'no certificate / unreachable' : r.days < 0 ? 'expired ' + fmt.date(r.d) : Math.floor(r.days) + ' days · ' + fmt.date(r.d)));
            """#),
            docs: "https://curl.se/docs/sslcerts.html",
            requires: "Nothing (uses curl)",
            sample: "github.com\tJan 27 23:59:59 2027 GMT\nexpired.badssl.com\tApr 12 23:59:59 2015 GMT"),

        WidgetPreset(
            id: "statuspage", name: "Status page (Statuspage.io)", category: "Monitoring", icon: "exclamationmark.bubble",
            summary: "Overall status, open incidents and degraded components of any Atlassian Statuspage (GitHub, Cloudflare, OpenAI, Atlassian, Discord…).",
            params: [PresetParam(id: "url", label: "Status page URL", placeholder: "https://www.githubstatus.com", help: "Any page powered by Statuspage. Try https://www.cloudflarestatus.com or https://status.openai.com.", defaultValue: "https://www.githubstatus.com")],
            template: http("Status", icon: "exclamationmark.bubble", url: "{{url}}/api/v2/summary.json", refresh: 300, transform: #"""
            const page = data.page || {}, st = data.status || {};
            const IND = { none: 'ok', minor: 'warn', major: 'error', critical: 'error', maintenance: 'info' };
            const COMP = { operational: 'ok', degraded_performance: 'warn', partial_outage: 'warn', major_outage: 'error', under_maintenance: 'info' };
            const comps = (data.components || []).filter(c => !c.group && c.showcase !== false);
            const bad = comps.filter(c => c.status !== 'operational');
            const incidents = (data.incidents || []).filter(i => i.status !== 'resolved' && i.status !== 'postmortem');
            const maint = (data.scheduled_maintenances || []).filter(m => m.status === 'in_progress');
            return [
              item.status(page.name || 'Status', IND[st.indicator] || 'info', st.description || st.indicator),
              ...bad.slice(0, 8).map(c => item.status(c.name, COMP[c.status] || 'info', c.status.replace(/_/g, ' '))),
              incidents.length ? item.list('Incidents', incidents.map(i => ({ title: i.name, subtitle: i.status + ' · ' + fmt.ago(i.started_at || i.created_at),
                value: i.impact, valueColor: { minor: 'orange', major: 'red', critical: 'red' }[i.impact] || 'secondary', url: i.shortlink })), { limit: 4 }) : null,
              maint.length ? item.list('Maintenance', maint.map(m => ({ title: m.name, subtitle: 'until ' + fmt.date(m.scheduled_until, true),
                icon: 'sf:wrench.and.screwdriver', url: m.shortlink })), { limit: 3 }) : null,
              !bad.length && !incidents.length ? item.text(comps.length + ' components operational', 'caption') : null
            ];
            """#),
            docs: "https://support.atlassian.com/statuspage/",
            sample: #"{"page":{"name":"GitHub","url":"https://www.githubstatus.com"},"status":{"indicator":"minor","description":"Minor Service Outage"},"components":[{"name":"Git Operations","status":"operational","group":false},{"name":"Actions","status":"degraded_performance","group":false}],"incidents":[{"name":"Delayed Actions runs","status":"investigating","impact":"minor","started_at":"2026-11-25T10:02:00Z","shortlink":"https://stspg.io/x"}],"scheduled_maintenances":[]}"#),
    ]
}
