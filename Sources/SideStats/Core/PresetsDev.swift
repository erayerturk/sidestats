import Foundation

extension WidgetPresets {
    static let repoParam = PresetParam(id: "repo", label: "Repository", placeholder: "owner/name", help: "GitHub repository as owner/name, e.g. swiftlang/swift.")
    static let githubToken = PresetParam(
        id: "token", label: "GitHub token", placeholder: "optional for public repos",
        help: "Fine-grained token with read access (Actions/Pull requests/Metadata). Optional for public repos, but without it GitHub allows only 60 requests/hour.",
        secret: true, optional: true)
    static let githubHeaders = "Authorization: Bearer {{token}}\nX-GitHub-Api-Version: 2022-11-28\nAccept: application/vnd.github+json"

    static let dev: [WidgetPreset] = [
        WidgetPreset(
            id: "github-actions", name: "GitHub Actions", category: "Dev", icon: "play.circle",
            summary: "Latest result per workflow, success rate, typical duration and the most recent runs of a repository.",
            params: [repoParam,
                     PresetParam(id: "branch", label: "Branch", placeholder: "main", help: "Optional: only runs on this branch.", optional: true),
                     githubToken],
            template: http("{{repo}} · CI", icon: "play.circle", url: "https://api.github.com/repos/{{repo}}/actions/runs?per_page=30", refresh: 120,
                           transform: "const branch = {{branch:js}};\n" + #"""
            const runs = (data.workflow_runs || []).filter(r => !branch || r.head_branch === branch);
            if (!runs.length) return [item.text('No workflow runs' + (branch ? ' on ' + branch : ''), 'caption')];
            const word = r => r.status !== 'completed' ? (r.status === 'queued' ? 'queued' : 'running') : r.conclusion;
            const STATE = { success: 'ok', failure: 'error', timed_out: 'error', startup_failure: 'error', action_required: 'warn', running: 'warn', queued: 'warn' };
            const COLOR = { ok: 'green', error: 'red', warn: 'orange' };
            const dur = r => (toDate(r.updated_at) - toDate(r.run_started_at || r.created_at)) / 1000;
            const done = runs.filter(r => r.status === 'completed' && !['cancelled', 'skipped', 'neutral'].includes(r.conclusion));
            const rate = done.length ? count(done, r => r.conclusion === 'success') / done.length : null;
            const latest = Object.values(groupBy(runs, 'name')).map(g => g[0]).slice(0, 6);
            return [
              item.stat('Success rate', rate === null ? '—' : rate, { format: 'percent', decimals: 0, color: rate === null ? undefined : rate >= 0.9 ? 'green' : rate >= 0.7 ? 'orange' : 'red', caption: 'last ' + done.length + ' runs' }),
              item.stat('Typical run', done.length ? sortBy(done.map(dur), null)[Math.floor(done.length / 2)] : '—', { format: 'duration', caption: 'median' }),
              ...latest.map(r => item.status(r.name, STATE[word(r)] || 'info', word(r).replace('_', ' ') + ' · ' + fmt.ago(r.created_at))),
              item.list('Recent runs', runs.slice(0, 10).map(r => ({
                title: r.display_title || r.name, subtitle: [r.display_title && r.display_title !== r.name ? r.name : null, r.head_branch, fmt.ago(r.created_at)].filter(Boolean).join(' · '),
                value: r.status === 'completed' ? fmt.duration(dur(r)) : word(r), valueColor: COLOR[STATE[word(r)]] || 'secondary',
                icon: { ok: 'sf:checkmark.circle.fill', error: 'sf:xmark.circle.fill', warn: 'sf:clock.fill' }[STATE[word(r)]] || 'sf:minus.circle',
                url: r.html_url })), { limit: 5 })
            ];
            """#),
            headers: githubHeaders,
            docs: "https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository",
            requires: "Optional token (required for private repos)",
            sample: #"{"total_count":2,"workflow_runs":[{"name":"CI","display_title":"Fix crash on launch","status":"completed","conclusion":"success","head_branch":"main","event":"push","run_number":412,"created_at":"2026-11-25T09:00:00Z","run_started_at":"2026-11-25T09:00:05Z","updated_at":"2026-11-25T09:06:40Z","html_url":"https://github.com/o/r/actions/runs/1"},{"name":"Release","display_title":"v2.3.0","status":"in_progress","conclusion":null,"head_branch":"main","created_at":"2026-11-25T10:00:00Z","run_started_at":"2026-11-25T10:00:05Z","updated_at":"2026-11-25T10:02:00Z","html_url":"https://github.com/o/r/actions/runs/2"}]}"#),

        WidgetPreset(
            id: "github-repo", name: "GitHub repository", category: "Dev", icon: "star",
            summary: "Stars, forks, open issues and watchers of a repository, with its description and last push.",
            params: [repoParam, githubToken],
            template: http("{{repo}}", icon: "star", url: "https://api.github.com/repos/{{repo}}", refresh: 900, transform: #"""
            if (!data.full_name) throw new Error(data.message || 'Repository not found');
            return [
              item.stat('Stars', data.stargazers_count, { color: 'yellow' }),
              item.stat('Forks', data.forks_count),
              item.stat('Open issues + PRs', data.open_issues_count, { color: data.open_issues_count > 100 ? 'orange' : undefined }),
              item.stat('Watchers', data.subscribers_count ?? data.watchers_count),
              item.text([data.description, [data.language, data.license && data.license.spdx_id, 'pushed ' + fmt.ago(data.pushed_at)].filter(Boolean).join(' · ')].filter(Boolean).join('\n'), 'caption')
            ];
            """#),
            headers: githubHeaders,
            docs: "https://docs.github.com/en/rest/repos/repos#get-a-repository",
            requires: "Optional token",
            sample: #"{"full_name":"swiftlang/swift","description":"The Swift Programming Language","stargazers_count":68900,"forks_count":10500,"open_issues_count":7600,"subscribers_count":2400,"language":"C++","license":{"spdx_id":"Apache-2.0"},"pushed_at":"2026-11-25T08:00:00Z"}"#),

        WidgetPreset(
            id: "github-prs", name: "GitHub pull requests", category: "Dev", icon: "arrow.triangle.pull",
            summary: "Open pull requests of a repository: count, drafts, oldest, and the list with authors.",
            params: [repoParam, githubToken],
            template: http("{{repo}} · PRs", icon: "arrow.triangle.pull", url: "https://api.github.com/repos/{{repo}}/pulls?state=open&per_page=50&sort=updated&direction=desc", refresh: 300, transform: #"""
            if (!Array.isArray(data)) throw new Error(data.message || 'Unexpected response');
            if (!data.length) return [item.ok('No open pull requests')];
            const oldest = min(data, p => toDate(p.created_at).getTime());
            return [
              item.stat('Open', data.length + (data.length === 50 ? '+' : '')),
              item.stat('Drafts', count(data, 'draft'), { color: 'secondary' }),
              item.stat('Oldest', fmt.ago(oldest).replace(' ago', ''), { color: Date.now() - oldest > 30 * 864e5 ? 'orange' : undefined }),
              item.list(null, data.map(p => ({
                title: p.title, subtitle: '#' + p.number + ' · ' + (p.user || {}).login + ' · updated ' + fmt.ago(p.updated_at),
                value: p.draft ? 'draft' : fmt.ago(p.created_at).replace(' ago', ''), valueColor: p.draft ? 'secondary' : undefined,
                icon: (p.user || {}).avatar_url, url: p.html_url })), { limit: 8 })
            ];
            """#),
            headers: githubHeaders,
            docs: "https://docs.github.com/en/rest/pulls/pulls#list-pull-requests",
            requires: "Optional token",
            sample: #"[{"number":101,"title":"Add dark mode","draft":false,"created_at":"2026-11-20T10:00:00Z","updated_at":"2026-11-25T09:00:00Z","html_url":"https://github.com/o/r/pull/101","user":{"login":"ada","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}},{"number":99,"title":"WIP: new parser","draft":true,"created_at":"2026-10-01T10:00:00Z","updated_at":"2026-11-01T09:00:00Z","html_url":"https://github.com/o/r/pull/99","user":{"login":"bob","avatar_url":"https://avatars.githubusercontent.com/u/2?v=4"}}]"#),

        WidgetPreset(
            id: "github-search", name: "GitHub issues & PRs search", category: "Dev", icon: "magnifyingglass",
            summary: "Any GitHub search as a list, e.g. PRs waiting for your review or issues assigned to you across all repos.",
            params: [
                PresetParam(id: "query", label: "Search query", placeholder: "is:open is:pr review-requested:@me", help: "GitHub search syntax. Queries with @me need a token.", defaultValue: "is:open is:pr review-requested:@me"),
                PresetParam(id: "title", label: "Title", placeholder: "Review requests", help: "Widget title.", defaultValue: "Review requests"),
                PresetParam(id: "token", label: "GitHub token", help: "Classic or fine-grained token; required for @me and private repos.", secret: true, optional: true),
            ],
            template: http("{{title}}", icon: "magnifyingglass", url: "https://api.github.com/search/issues?q={{query:url}}&per_page=30&sort=updated", refresh: 300, transform: #"""
            const list = data.items || [];
            if (!list.length) return [item.ok('Nothing here', 'inbox zero')];
            return [
              item.stat('Results', data.total_count),
              item.list(null, list.map(i => ({
                title: i.title, subtitle: i.repository_url.split('/').slice(-2).join('/') + '#' + i.number + ' · ' + (i.user || {}).login + ' · ' + fmt.ago(i.updated_at),
                value: i.pull_request ? (i.draft ? 'draft' : 'PR') : (i.comments ? i.comments + ' 💬' : ''), icon: (i.user || {}).avatar_url, url: i.html_url })), { limit: 8 })
            ];
            """#),
            headers: githubHeaders,
            docs: "https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests",
            requires: "Token (for @me / private repos)",
            sample: #"{"total_count":1,"items":[{"title":"Fix race in cache","number":7,"repository_url":"https://api.github.com/repos/acme/api","user":{"login":"ada","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"},"updated_at":"2026-11-25T08:00:00Z","html_url":"https://github.com/acme/api/pull/7","pull_request":{},"draft":false,"comments":2}]}"#),

        WidgetPreset(
            id: "sentry-issues", name: "Sentry issues", category: "Dev", icon: "ant",
            summary: "Unresolved Sentry issues of a project: event volume over 24 h, affected users and the noisiest issues.",
            params: [
                PresetParam(id: "org", label: "Organization slug", placeholder: "acme", help: "From your Sentry URL: https://<org>.sentry.io or sentry.io/organizations/<org>."),
                PresetParam(id: "project", label: "Project slug", placeholder: "ios-app", help: "Project slug (Settings → Projects)."),
                PresetParam(id: "token", label: "Auth token", help: "Settings → Developer Settings → Personal / Organization tokens, with project:read and event:read.", secret: true),
                PresetParam(id: "host", label: "Sentry host", placeholder: "https://sentry.io", help: "Use https://de.sentry.io for EU data residency or your self-hosted URL.", defaultValue: "https://sentry.io"),
                PresetParam(id: "query", label: "Query", placeholder: "is:unresolved", help: "Sentry search, e.g. `is:unresolved level:error`.", defaultValue: "is:unresolved"),
            ],
            template: http("Sentry · {{project}}", icon: "ant", url: "{{host}}/api/0/projects/{{org}}/{{project}}/issues/?query={{query:url}}&statsPeriod=24h&sort=freq&limit=25", refresh: 300, transform: #"""
            if (!Array.isArray(data)) throw new Error(data.detail || 'Unexpected response');
            if (!data.length) return [item.ok('No unresolved issues', 'nice')];
            const buckets = {};
            data.forEach(i => (((i.stats || {})['24h']) || []).forEach(([t, n]) => buckets[t] = (buckets[t] || 0) + n));
            const series = Object.keys(buckets).sort().map(t => [Number(t), buckets[t]]);
            const events = sum(series, 1);
            const COLOR = { fatal: 'red', error: 'red', warning: 'orange', info: 'blue' };
            return [
              item.stat('Unresolved', data.length + (data.length === 25 ? '+' : ''), { color: 'orange' }),
              item.stat('Events 24h', events),
              item.stat('Users', sum(data, 'userCount')),
              series.length ? item.chart(null, series, { kind: 'bar', height: 70, color: 'red' }) : null,
              item.list(null, data.map(i => ({
                title: i.title, subtitle: (i.shortId ? i.shortId + ' · ' : '') + (i.culprit || '') + ' · ' + fmt.ago(i.lastSeen),
                value: fmt.num(i.count), valueColor: COLOR[i.level] || 'secondary', url: i.permalink })), { limit: 6 })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://docs.sentry.io/api/events/list-a-projects-issues/",
            requires: "Auth token (project:read, event:read)",
            sample: #"[{"id":"1","shortId":"IOS-3F","title":"TypeError: undefined is not an object","culprit":"app/checkout.js in submit","level":"error","status":"unresolved","count":"1284","userCount":311,"lastSeen":"2026-11-25T11:40:00Z","firstSeen":"2026-11-20T10:00:00Z","permalink":"https://acme.sentry.io/issues/1/","stats":{"24h":[[1764025200,20],[1764028800,45],[1764032400,80],[1764036000,30]]}},{"id":"2","shortId":"IOS-2A","title":"Timeout fetching /api/cart","culprit":"network","level":"warning","count":"84","userCount":40,"lastSeen":"2026-11-25T09:00:00Z","permalink":"https://acme.sentry.io/issues/2/","stats":{"24h":[[1764025200,2],[1764028800,5],[1764032400,1],[1764036000,0]]}}]"#),

        WidgetPreset(
            id: "vercel-deployments", name: "Vercel deployments", category: "Dev", icon: "triangle",
            summary: "Current production deployment status and the latest builds (ready, building, error) with commit messages.",
            params: [
                PresetParam(id: "token", label: "Access token", help: "vercel.com/account/tokens → Create (scope it to the team).", secret: true),
                PresetParam(id: "project", label: "Project ID or name", placeholder: "prj_… or my-app", help: "Optional: limit to one project (Project → Settings → General).", optional: true),
                PresetParam(id: "team", label: "Team ID", placeholder: "team_…", help: "Required for team projects: Team Settings → General → Team ID.", optional: true),
            ],
            template: http("Vercel", icon: "triangle", url: "https://api.vercel.com/v6/deployments?limit=12{{query}}", refresh: 120, transform: #"""
            const map = { READY: 'ok', ERROR: 'error', BUILDING: 'building', INITIALIZING: 'building', QUEUED: 'building', CANCELED: 'canceled', BLOCKED: 'error', DELETED: 'canceled' };
            const deploys = (data.deployments || []).map(d => {
              const s = d.state || d.readyState, m = d.meta || {};
              return { title: (m.githubCommitMessage || m.gitlabCommitMessage || m.bitbucketCommitMessage || d.name || '').split('\n')[0],
                       subtitle: [d.name, d.target === 'production' ? 'production' : 'preview', m.githubCommitRef || m.gitlabCommitRef].filter(Boolean).join(' · '),
                       state: map[s] || 'canceled', label: String(s || '?').toLowerCase(), created: d.created || d.createdAt,
                       prod: d.target === 'production', url: d.inspectorUrl || (d.url ? 'https://' + d.url : undefined) };
            });
            """# + PresetJS.deploys),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://vercel.com/docs/rest-api/reference/endpoints/deployments/list-deployments",
            requires: "Access token",
            derive: { v in
                var q = ""
                if let p = v["project"], !p.isEmpty { q += "&projectId=" + encode(p, "url") }
                if let t = v["team"], !t.isEmpty { q += "&teamId=" + encode(t, "url") }
                return ["query": q]
            },
            sample: #"{"deployments":[{"uid":"dpl_1","name":"web","url":"web-abc.vercel.app","created":1764064800000,"state":"READY","target":"production","inspectorUrl":"https://vercel.com/acme/web/1","meta":{"githubCommitMessage":"Fix pricing page","githubCommitRef":"main"}},{"uid":"dpl_2","name":"web","url":"web-def.vercel.app","created":1764061200000,"state":"ERROR","target":null,"meta":{"githubCommitMessage":"Try new layout","githubCommitRef":"feat/layout"}}],"pagination":{"count":2}}"#),

        WidgetPreset(
            id: "netlify-deploys", name: "Netlify deploys", category: "Dev", icon: "square.stack.3d.up",
            summary: "Latest Netlify deploys of a site with state, branch, commit title and build time.",
            params: [
                PresetParam(id: "token", label: "Personal access token", help: "User settings → Applications → Personal access tokens.", secret: true),
                PresetParam(id: "site", label: "Site ID", placeholder: "3970e0fe-8564-4903-9a55-c5f8de49fb8b", help: "Site configuration → General → Site details → Site ID (or the site's domain, e.g. my-site.netlify.app)."),
            ],
            template: http("Netlify", icon: "square.stack.3d.up", url: "https://api.netlify.com/api/v1/sites/{{site}}/deploys?per_page=12", refresh: 120, transform: #"""
            if (!Array.isArray(data)) throw new Error(data.message || 'Unexpected response');
            const map = { ready: 'ok', error: 'error', rejected: 'error', building: 'building', enqueued: 'building', new: 'building', uploading: 'building', uploaded: 'building', preparing: 'building', prepared: 'building', processing: 'building', processed: 'building', retrying: 'building', pending_review: 'building', accepted: 'building' };
            const deploys = data.map(d => ({
              title: (d.title || d.commit_ref || d.name || 'Deploy').split('\n')[0],
              subtitle: [d.context === 'production' ? 'production' : (d.context || '').replace(/-/g, ' '), d.branch].filter(Boolean).join(' · ') + (d.deploy_time ? ' · ' + fmt.duration(d.deploy_time) : ''),
              state: map[d.state] || 'canceled', label: d.state === 'error' && /cancel/i.test(d.error_message || '') ? 'canceled' : d.state,
              created: d.created_at, prod: d.context === 'production', url: d.admin_url ? d.admin_url + '/deploys/' + d.id : d.deploy_ssl_url
            }));
            """# + PresetJS.deploys),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://open-api.netlify.com/#tag/deploy/operation/listSiteDeploys",
            requires: "Personal access token",
            sample: #"[{"id":"d1","state":"ready","context":"production","branch":"main","title":"Update docs","created_at":"2026-11-25T09:00:00Z","deploy_time":42,"admin_url":"https://app.netlify.com/sites/acme","deploy_ssl_url":"https://d1--acme.netlify.app"},{"id":"d2","state":"building","context":"deploy-preview","branch":"feat/x","title":"New hero","created_at":"2026-11-25T10:00:00Z"}]"#),

        WidgetPreset(
            id: "cloudflare-analytics", name: "Cloudflare zone traffic", category: "Dev", icon: "cloud",
            summary: "Daily requests, visitors, cache ratio, bandwidth and threats of a Cloudflare zone (GraphQL Analytics API).",
            params: [
                PresetParam(id: "token", label: "API token", help: "My Profile → API Tokens → Create token with Zone → Analytics → Read for the zone.", secret: true),
                PresetParam(id: "zone", label: "Zone ID", placeholder: "023e105f4ecef8ad9ca31a8372d0c353", help: "Zone overview page → API section → Zone ID."),
                PresetParam(id: "days", label: "Days", placeholder: "7", help: "How many days to chart (1–30).", defaultValue: "7"),
            ],
            template: http("Cloudflare", icon: "cloud", url: "https://api.cloudflare.com/client/v4/graphql", method: "POST",
                           body: #"{"query":"query($zone: String!, $since: Date!) { viewer { zones(filter: {zoneTag: $zone}) { httpRequests1dGroups(limit: 31, filter: {date_geq: $since}, orderBy: [date_ASC]) { dimensions { date } sum { requests cachedRequests bytes cachedBytes threats pageViews } uniq { uniques } } } } }","variables":{"zone":{{zone:js}},"since":"{{daysAgo:{{days}}}}"}}"#,
                           refresh: 900, transform: #"""
            if (data.errors && data.errors.length) throw new Error(data.errors.map(e => e.message).join('; '));
            const zone = ((((data.data || {}).viewer || {}).zones) || [])[0];
            if (!zone) throw new Error('Zone not found or token lacks Analytics:Read');
            const g = zone.httpRequests1dGroups || [];
            if (!g.length) return [item.text('No traffic yet', 'caption')];
            const req = sum(g, 'sum.requests'), cached = sum(g, 'sum.cachedRequests');
            return [
              item.stat('Requests', req, { sparkline: g.map(x => x.sum.requests) }),
              item.stat('Visitors', sum(g, 'uniq.uniques'), { caption: 'sum of daily uniques' }),
              item.stat('Cached', req ? cached / req : 0, { format: 'percent', decimals: 0, color: 'teal' }),
              item.stat('Bandwidth', sum(g, 'sum.bytes'), { format: 'bytes' }),
              item.stat('Threats', sum(g, 'sum.threats'), { color: sum(g, 'sum.threats') ? 'orange' : 'secondary' }),
              item.stat('Page views', sum(g, 'sum.pageViews')),
              item.chart('Requests per day', g.map(x => [x.dimensions.date, x.sum.requests]), { kind: 'bar', height: 80, color: 'orange' })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://developers.cloudflare.com/analytics/graphql-api/",
            requires: "API token (Zone Analytics: Read)",
            derive: { v in ["days": String(min(max(Int(v["days"] ?? "") ?? 7, 1), 30))] },
            sample: #"{"data":{"viewer":{"zones":[{"httpRequests1dGroups":[{"dimensions":{"date":"2026-11-23"},"sum":{"requests":182000,"cachedRequests":120000,"bytes":5400000000,"cachedBytes":4000000000,"threats":12,"pageViews":41000},"uniq":{"uniques":9100}},{"dimensions":{"date":"2026-11-24"},"sum":{"requests":201000,"cachedRequests":139000,"bytes":6100000000,"cachedBytes":4500000000,"threats":4,"pageViews":45500},"uniq":{"uniques":9800}}]}]}},"errors":null}"#),

        WidgetPreset(
            id: "npm-downloads", name: "npm downloads", category: "Dev", icon: "shippingbox.circle",
            summary: "Daily downloads of an npm package over the last month, with this week vs. last week.",
            params: [PresetParam(id: "package", label: "Package", placeholder: "react", help: "npm package name (scoped names like @scope/pkg work).")],
            template: http("{{package}} on npm", icon: "shippingbox.circle", url: "https://api.npmjs.org/downloads/range/last-month/{{package}}", refresh: 3600, transform: #"""
            if (data.error) throw new Error(data.error);
            const d = data.downloads || [];
            const last7 = sum(d.slice(-7), 'downloads'), prev7 = sum(d.slice(-14, -7), 'downloads');
            return [
              item.stat('Last 7 days', last7, { delta: prev7 ? last7 / prev7 - 1 : undefined }),
              item.stat('Last 30 days', sum(d, 'downloads')),
              item.chart(null, d.map(x => [x.day, x.downloads]), { kind: 'bar', height: 80 })
            ];
            """#),
            docs: "https://github.com/npm/registry/blob/main/docs/download-counts.md",
            sample: #"{"start":"2026-10-25","end":"2026-11-23","package":"left-pad","downloads":[{"day":"2026-11-21","downloads":5100},{"day":"2026-11-22","downloads":2800},{"day":"2026-11-23","downloads":2600}]}"#),
    ]
}
