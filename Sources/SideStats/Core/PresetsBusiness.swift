import Foundation

extension WidgetPresets {
    /// JS: Stripe/Paddle amounts are in minor units; zero-decimal currencies are not.
    static let moneyJS = #"""
    const ZERO_DECIMAL = ['BIF','CLP','DJF','GNF','JPY','KMF','KRW','MGA','PYG','RWF','UGX','VND','VUV','XAF','XOF','XPF'];
    const major = (amount, cur) => (num(amount) || 0) / (ZERO_DECIMAL.includes(String(cur).toUpperCase()) ? 1 : 100);
    const dayKey = d => toDate(d).toISOString().slice(0, 10);
    function dailySeries(rows, days, dateOf, valueOf) {
      const out = {};
      for (let i = days - 1; i >= 0; i--) out[new Date(Date.now() - i * 864e5).toISOString().slice(0, 10)] = 0;
      rows.forEach(r => { const k = dayKey(dateOf(r)); if (k in out) out[k] += valueOf(r); });
      return Object.entries(out);
    }

    """#

    static let stripeKey = PresetParam(
        id: "token", label: "Secret or restricted key", placeholder: "rk_live_…",
        help: "Developers → API keys → Create restricted key with Read access to Balance, Charges and Subscriptions (rk_live_…).",
        secret: true)
    static let plausibleParams: [PresetParam] = [
        PresetParam(id: "site", label: "Site domain", placeholder: "example.com", help: "The site_id as registered in Plausible."),
        PresetParam(id: "token", label: "Stats API key", help: "Account settings → API keys → New API key (Stats API).", secret: true),
        PresetParam(id: "host", label: "Plausible host", placeholder: "https://plausible.io", help: "Change only for self-hosted Plausible.", defaultValue: "https://plausible.io"),
    ]

    static let business: [WidgetPreset] = [
        // MARK: Stripe
        WidgetPreset(
            id: "stripe-balance", name: "Stripe balance", category: "Business", icon: "creditcard",
            summary: "Available and pending Stripe balance, per currency.",
            params: [stripeKey],
            template: http("Stripe balance", icon: "creditcard", url: "https://api.stripe.com/v1/balance", refresh: 900, transform: moneyJS + #"""
            if (data.error) throw new Error(data.error.message);
            const cur = uniq([...(data.available || []), ...(data.pending || [])].map(b => b.currency));
            if (!cur.length) return [item.text('No balance yet', 'caption')];
            const get = (list, c) => major(sum((list || []).filter(b => b.currency === c), 'amount'), c);
            return cur.slice(0, 3).flatMap(c => [
              item.stat('Available' + (cur.length > 1 ? ' ' + c.toUpperCase() : ''), get(data.available, c), { format: 'currency', currency: c.toUpperCase(), color: 'green' }),
              item.stat('Pending' + (cur.length > 1 ? ' ' + c.toUpperCase() : ''), get(data.pending, c), { format: 'currency', currency: c.toUpperCase(), color: 'secondary' })
            ]);
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://docs.stripe.com/api/balance/balance_retrieve",
            requires: "Restricted key (Balance: Read)",
            sample: #"{"object":"balance","available":[{"amount":1254300,"currency":"usd","source_types":{"card":1254300}}],"pending":[{"amount":89100,"currency":"usd"}],"livemode":true}"#),

        WidgetPreset(
            id: "stripe-revenue", name: "Stripe revenue (30 days)", category: "Business", icon: "dollarsign.arrow.circlepath",
            summary: "Net charge volume of the last 30 days as a daily bar chart, with order count, average order and latest payments.",
            params: [stripeKey],
            template: http("Stripe revenue", icon: "dollarsign.arrow.circlepath", url: "https://api.stripe.com/v1/charges?limit=100", refresh: 900, transform: moneyJS + #"""
            if (data.error) throw new Error(data.error.message);
            const since = Date.now() / 1000 - 30 * 86400;
            const all = (data.data || []).filter(c => c.status === 'succeeded' && c.paid);
            const charges = all.filter(c => c.created >= since);
            const cur = (Object.entries(countBy(charges, 'currency')).sort((a, b) => b[1] - a[1])[0] || ['usd'])[0];
            const mine = charges.filter(c => c.currency === cur);
            const net = c => major(c.amount - (c.amount_refunded || 0), cur);
            const total = sum(mine.map(net)), C = cur.toUpperCase();
            const truncated = data.has_more && (all[all.length - 1] || {}).created >= since;
            return [
              item.stat('Revenue 30d', total, { format: 'currency', currency: C, color: 'green', caption: truncated ? 'latest 100 charges' : (charges.length > mine.length ? C + ' only' : undefined) }),
              item.stat('Payments', mine.length),
              item.stat('Average', mine.length ? total / mine.length : 0, { format: 'currency', currency: C }),
              item.chart(null, dailySeries(mine, 30, c => c.created, net), { kind: 'bar', format: 'currency', currency: C, height: 80, color: 'green' }),
              item.list('Latest', mine.slice(0, 6).map(c => ({
                title: (c.billing_details || {}).name || c.receipt_email || c.description || c.id,
                subtitle: fmt.ago(c.created) + (c.amount_refunded ? ' · refunded ' + fmt.money(major(c.amount_refunded, cur), C) : ''),
                value: fmt.money(net(c), C, 2), valueColor: 'green', url: 'https://dashboard.stripe.com/payments/' + (c.payment_intent || c.id) })), { limit: 4 })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://docs.stripe.com/api/charges/list",
            requires: "Restricted key (Charges: Read)",
            sample: #"{"object":"list","has_more":false,"data":[{"id":"ch_1","amount":4900,"amount_refunded":0,"currency":"usd","created":4102444800,"status":"succeeded","paid":true,"billing_details":{"name":"Ada Lovelace"},"payment_intent":"pi_1"},{"id":"ch_2","amount":1900,"amount_refunded":1900,"currency":"usd","created":4102444700,"status":"succeeded","paid":true,"receipt_email":"bob@example.com"}]}"#),

        WidgetPreset(
            id: "stripe-mrr", name: "Stripe MRR", category: "Business", icon: "arrow.triangle.2.circlepath.circle",
            summary: "Monthly recurring revenue estimated from active subscriptions, with subscriber count, ARPU and plan mix.",
            params: [stripeKey],
            template: http("Stripe MRR", icon: "arrow.triangle.2.circlepath.circle", url: "https://api.stripe.com/v1/subscriptions?status=active&limit=100", refresh: 3600, transform: moneyJS + #"""
            if (data.error) throw new Error(data.error.message);
            const subs = data.data || [];
            if (!subs.length) return [item.stat('MRR', 0, { format: 'currency' }), item.text('No active subscriptions', 'caption')];
            const PER_MONTH = { day: 30.4375, week: 4.348, month: 1, year: 1 / 12 };
            const cur = subs[0].currency || 'usd', C = cur.toUpperCase();
            const plans = {};
            let mrr = 0;
            subs.filter(s => s.currency === cur).forEach(s => {
              const pct = s.discount && s.discount.coupon && s.discount.coupon.percent_off ? 1 - s.discount.coupon.percent_off / 100 : 1;
              ((s.items || {}).data || []).forEach(it => {
                const p = it.price || it.plan || {}, r = p.recurring || { interval: p.interval, interval_count: p.interval_count };
                const m = major((p.unit_amount ?? p.amount ?? 0) * (it.quantity || 1), cur) * (PER_MONTH[r.interval] || 1) / (r.interval_count || 1) * pct;
                mrr += m;
                const name = p.nickname || (r.interval === 'year' ? 'Yearly' : r.interval === 'month' ? 'Monthly' : r.interval) || 'Plan';
                plans[name] = (plans[name] || 0) + m;
              });
            });
            return [
              item.stat('MRR', mrr, { format: 'currency', currency: C, color: 'green', caption: data.has_more ? 'first 100 subscriptions' : 'ARR ' + fmt.money(mrr * 12, C) }),
              item.stat('Subscribers', subs.length + (data.has_more ? '+' : '')),
              item.stat('ARPU', mrr / subs.length, { format: 'currency', currency: C }),
              Object.keys(plans).length > 1 ? item.chart('Plan mix', Object.entries(plans).map(([label, value]) => ({ label, value: Math.round(value) })), { kind: 'donut', format: 'currency', currency: C, height: 120 }) : null
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://docs.stripe.com/api/subscriptions/list",
            requires: "Restricted key (Subscriptions: Read)",
            sample: #"{"object":"list","has_more":false,"data":[{"id":"sub_1","currency":"usd","status":"active","items":{"data":[{"quantity":1,"price":{"unit_amount":1900,"currency":"usd","nickname":"Pro monthly","recurring":{"interval":"month","interval_count":1}}}]}},{"id":"sub_2","currency":"usd","status":"active","items":{"data":[{"quantity":3,"price":{"unit_amount":19000,"currency":"usd","nickname":"Team yearly","recurring":{"interval":"year","interval_count":1}}}]}}]}"#),

        // MARK: RevenueCat
        WidgetPreset(
            id: "revenuecat-overview", name: "RevenueCat overview", category: "Business", icon: "cat",
            summary: "MRR, revenue (28 d), active subscriptions and trials, new customers and active users from RevenueCat.",
            params: [
                PresetParam(id: "project", label: "Project ID", placeholder: "proj1ab2c3d4", help: "Project settings → General → Project ID (also in the dashboard URL)."),
                PresetParam(id: "token", label: "Secret API key (v2)", placeholder: "sk_…", help: "Project settings → API keys → New secret key, API v2, with Charts & metrics: read.", secret: true),
            ],
            template: http("RevenueCat", icon: "cat", url: "https://api.revenuecat.com/v2/projects/{{project}}/metrics/overview", refresh: 900, transform: #"""
            if (!Array.isArray(data.metrics)) throw new Error(data.message || 'Unexpected response');
            const cur = data.currency || 'USD';
            const order = ['mrr', 'revenue', 'active_subscriptions', 'active_trials', 'new_customers', 'active_users', 'num_tx_last_28_days'];
            const ms = sortBy(data.metrics, m => order.indexOf(m.id) === -1 ? 99 : order.indexOf(m.id));
            const updated = max(ms, m => m.last_updated_at);
            return [
              ...ms.map(m => item.stat(m.name + (m.period === 'P28D' && !/28/.test(m.name) ? ' (28d)' : ''), m.value,
                m.unit === '$' || /revenue|mrr/i.test(m.id) ? { format: 'currency', currency: cur, color: 'green' } : {})),
              updated ? item.text('Updated ' + fmt.ago(updated), 'caption') : null
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://www.revenuecat.com/docs/api-v2#tag/Charts-and-Metrics",
            requires: "Secret API key v2 (charts_metrics:overview:read)",
            sample: ##"{"object":"overview_metrics","currency":"USD","metrics":[{"object":"overview_metric","id":"active_trials","name":"Active Trials","unit":"#","period":"P0D","value":34,"last_updated_at":1764064800000},{"object":"overview_metric","id":"active_subscriptions","name":"Active Subscriptions","unit":"#","period":"P0D","value":812},{"object":"overview_metric","id":"mrr","name":"MRR","unit":"$","period":"P28D","value":6420.5},{"object":"overview_metric","id":"revenue","name":"Revenue","unit":"$","period":"P28D","value":7210},{"object":"overview_metric","id":"new_customers","name":"New Customers","unit":"#","period":"P28D","value":1450},{"object":"overview_metric","id":"active_users","name":"Active Users","unit":"#","period":"P28D","value":9800}]}"##),

        // MARK: Plausible
        WidgetPreset(
            id: "plausible-overview", name: "Plausible overview", category: "Business", icon: "chart.bar.xaxis",
            summary: "Visitors, pageviews, bounce rate and visit duration for a period, with change vs. the previous period.",
            params: plausibleParams + [
                PresetParam(id: "period", label: "Period", help: "Plausible period.", defaultValue: "30d", options: ["day", "7d", "30d", "month", "6mo", "12mo"]),
            ],
            template: http("{{site}}", icon: "chart.bar.xaxis",
                           url: "{{host}}/api/v1/stats/aggregate?site_id={{site:url}}&period={{period}}&metrics=visitors,visits,pageviews,bounce_rate,visit_duration&compare=previous_period",
                           refresh: 600, transform: #"""
            if (data.error) throw new Error(data.error);
            const r = data.results || {};
            const ch = m => r[m] && r[m].change !== undefined && r[m].change !== null ? r[m].change / 100 : undefined;
            const v = m => r[m] ? r[m].value : null;
            return [
              item.stat('Visitors', v('visitors'), { delta: ch('visitors'), color: 'blue' }),
              item.stat('Pageviews', v('pageviews'), { delta: ch('pageviews') }),
              item.stat('Bounce rate', v('bounce_rate') / 100, { format: 'percent', decimals: 0, delta: ch('bounce_rate'), positiveIsGood: false }),
              item.stat('Visit duration', v('visit_duration'), { format: 'duration', delta: ch('visit_duration') })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://plausible.io/docs/stats-api-v1#get-apiv1statsaggregate",
            requires: "Stats API key",
            sample: #"{"results":{"bounce_rate":{"value":53.0,"change":-4},"pageviews":{"value":67381,"change":12},"visit_duration":{"value":86.0,"change":3},"visitors":{"value":20152,"change":9},"visits":{"value":25010,"change":8}}}"#),

        WidgetPreset(
            id: "plausible-realtime", name: "Plausible live visitors", category: "Business", icon: "person.2.wave.2",
            summary: "People on your site right now (last 5 minutes). Refreshes every 30 s.",
            params: plausibleParams,
            template: http("Live on {{site}}", icon: "person.2.wave.2", url: "{{host}}/api/v1/stats/realtime/visitors?site_id={{site:url}}", refresh: 30, transform: #"""
            if (typeof data !== 'number') throw new Error((data && data.error) || 'Unexpected response');
            return [item.stat('Visitors now', data, { color: data ? 'green' : 'secondary', caption: 'last 5 minutes' })];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://plausible.io/docs/stats-api-v1#get-apiv1statsrealtimevisitors",
            requires: "Stats API key",
            sample: "21"),

        WidgetPreset(
            id: "plausible-chart", name: "Plausible traffic chart", category: "Business", icon: "chart.xyaxis.line",
            summary: "Daily visitors and pageviews as a chart (Stats API v2).",
            params: plausibleParams + [
                PresetParam(id: "range", label: "Range", help: "Date range.", defaultValue: "30d", options: ["7d", "28d", "30d", "91d", "month", "6mo", "12mo"]),
            ],
            template: http("{{site}} traffic", icon: "chart.xyaxis.line", url: "{{host}}/api/v2/query", method: "POST",
                           body: #"{"site_id":{{site:js}},"metrics":["visitors","pageviews"],"date_range":"{{range}}","dimensions":["time:day"]}"#,
                           refresh: 1800, transform: #"""
            if (data.error) throw new Error(data.error);
            const rows = sortBy(data.results || [], r => r.dimensions[0]);
            if (!rows.length) return [item.text('No visits in this range', 'caption')];
            return [
              item.stat('Visitors', sum(rows, r => r.metrics[0]), { color: 'blue', sparkline: undefined }),
              item.stat('Pageviews', sum(rows, r => r.metrics[1])),
              item.chart(null, null, { kind: 'line', series: [
                { name: 'Visitors', color: 'blue', points: rows.map(r => [r.dimensions[0].slice(0, 10), r.metrics[0]]) },
                { name: 'Pageviews', color: 'purple', points: rows.map(r => [r.dimensions[0].slice(0, 10), r.metrics[1]]) }] })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://plausible.io/docs/stats-api",
            requires: "Stats API key",
            sample: #"{"results":[{"metrics":[310,720],"dimensions":["2026-11-23"]},{"metrics":[355,801],"dimensions":["2026-11-24"]}],"meta":{},"query":{}}"#),

        // MARK: Paddle
        WidgetPreset(
            id: "paddle-revenue", name: "Paddle revenue", category: "Business", icon: "p.circle",
            summary: "Completed Paddle Billing transactions of the last 30 days: revenue, your earnings after fees, daily chart and latest sales.",
            params: [
                PresetParam(id: "token", label: "API key", placeholder: "pdl_live_apikey_…", help: "Paddle → Developer tools → Authentication → API keys, with transaction.read.", secret: true),
                PresetParam(id: "env", label: "Environment", help: "Use sandbox for test accounts.", defaultValue: "live", options: ["live", "sandbox"]),
            ],
            template: http("Paddle", icon: "p.circle", url: "https://{{apiHost}}/transactions?status=completed&billed_at[GTE]={{daysAgo:30}}T00:00:00Z&order_by=billed_at[DESC]&per_page=30", refresh: 900, transform: moneyJS + #"""
            if (data.error) throw new Error(data.error.detail || data.error.code);
            const tx = data.data || [];
            if (!tx.length) return [item.stat('Revenue 30d', 0, { format: 'currency' }), item.text('No completed transactions in 30 days', 'caption')];
            const cur = (Object.entries(countBy(tx, 'currency_code')).sort((a, b) => b[1] - a[1])[0])[0];
            const mine = tx.filter(t => t.currency_code === cur);
            const tot = t => major(((t.details || {}).totals || {}).total, cur), earn = t => major(((t.details || {}).totals || {}).earnings, cur);
            const more = ((data.meta || {}).pagination || {}).has_more;
            return [
              item.stat('Revenue 30d', sum(mine.map(tot)), { format: 'currency', currency: cur, color: 'green', caption: more ? 'latest 30 sales' : undefined }),
              item.stat('Earnings', sum(mine.map(earn)), { format: 'currency', currency: cur, caption: 'after fees & tax' }),
              item.stat('Sales', mine.length + (more ? '+' : '')),
              item.chart(null, dailySeries(mine, 30, t => t.billed_at || t.created_at, tot), { kind: 'bar', format: 'currency', currency: cur, height: 80, color: 'green' }),
              item.list('Latest', mine.slice(0, 5).map(t => ({
                title: ((t.items || [])[0] || {}).price ? (t.items[0].price.name || t.items[0].price.description) : t.id,
                subtitle: fmt.ago(t.billed_at || t.created_at) + ' · ' + t.origin?.replace(/_/g, ' '), value: fmt.money(tot(t), cur, 2), valueColor: 'green' })), { limit: 5 })
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://developer.paddle.com/api-reference/transactions/list-transactions",
            requires: "API key (transaction.read)",
            derive: { v in ["apiHost": v["env"] == "sandbox" ? "sandbox-api.paddle.com" : "api.paddle.com"] },
            sample: #"{"data":[{"id":"txn_01","status":"completed","origin":"subscription_recurring","currency_code":"USD","billed_at":"2026-11-25T08:00:00Z","created_at":"2026-11-25T08:00:00Z","items":[{"price":{"name":"Pro (monthly)","description":"Pro monthly"},"quantity":1}],"details":{"totals":{"subtotal":"1900","tax":"0","total":"1900","earnings":"1735","currency_code":"USD"}}},{"id":"txn_02","status":"completed","origin":"web","currency_code":"USD","billed_at":"2026-11-23T08:00:00Z","items":[{"price":{"name":"Lifetime"},"quantity":1}],"details":{"totals":{"total":"9900","earnings":"9150","currency_code":"USD"}}}],"meta":{"pagination":{"per_page":30,"has_more":false,"estimated_total":2}}}"#),
    ]
}
