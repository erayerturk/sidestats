import Foundation

/// JavaScript snippets shared by several presets. They are prepended to a preset's transform
/// (plain string concatenation), so every widget's transform stays self-contained and editable.
enum PresetJS {
    /// `seriesNames(metrics)` names Prometheus-style label sets by the labels that differ between them.
    /// `formatValue(v, format)` / `scaleFormat(format)` map the preset "format" param to fmt/stat formats.
    static let series = #"""
    function seriesNames(metrics, fallback) {
      metrics = metrics.map(m => m || {});
      const keys = uniq([].concat(...metrics.map(m => Object.keys(m)))).filter(k => k !== '__name__');
      let varying = keys.filter(k => uniq(metrics.map(m => String(m[k]))).length > 1);
      const pref = ['instance', 'pod', 'container', 'name', 'job', 'service', 'host', 'node', 'device', 'mountpoint', 'mode', 'code', 'status', 'method'];
      varying.sort((a, b) => (pref.indexOf(a) + 1 || 99) - (pref.indexOf(b) + 1 || 99));
      return metrics.map(m => {
        if (varying.length) return varying.slice(0, 2).map(k => m[k] ?? '—').join(' · ');
        const own = pref.find(k => m[k] !== undefined);
        return own ? String(m[own]) : (m.__name__ || fallback || 'value');
      });
    }
    function scaleFormat(format) {
      return format === 'percent100' ? { format: 'percent', scale: 0.01 } : { format: format || 'number', scale: 1 };
    }
    function formatValue(v, format) {
      const f = scaleFormat(format);
      v = num(v); if (v === null) return '—';
      v *= f.scale;
      return f.format === 'percent' ? fmt.pct(v) : f.format === 'bytes' ? fmt.bytes(v)
           : f.format === 'duration' ? fmt.duration(v) : fmt.num(v);
    }
    function thresholdColor(v, warn, crit) {
      warn = num(warn); crit = num(crit); v = num(v);
      if (v === null || (warn === null && crit === null)) return undefined;
      const inverted = warn !== null && crit !== null && warn > crit;   // lower is worse (free space, uptime)
      const over = t => t !== null && (inverted ? v <= t : v >= t);
      return over(crit) ? 'red' : over(warn) ? 'orange' : 'green';
    }

    """#

    /// Alertmanager-style alert lists (Prometheus Alertmanager v2 and Grafana's built-in Alertmanager).
    /// Expects `labelFilter` (string, "k=v, k2=v2") to be defined before it.
    static let alerts = #"""
    const all = Array.isArray(data) ? data : (data && Array.isArray(data.data) ? data.data : []);
    const want = String(labelFilter || '').split(',').map(s => s.trim()).filter(Boolean)
      .map(s => s.split(/!?=~?/).map(x => x.trim()).concat([s.includes('!=')]));
    const firing = all.filter(a => !a.status || !a.status.state || a.status.state === 'active')
      .filter(a => want.every(([k, v, neg]) => (String((a.labels || {})[k] ?? '') === (v ?? '')) !== neg));
    if (!firing.length) {
      return [item.ok('All clear', all.length ? fmt.plural(all.length, 'silenced alert') : 'No firing alerts')];
    }
    const sev = a => String((a.labels || {}).severity || (a.labels || {}).priority || '').toLowerCase();
    const rank = a => /crit|page|high|error|emerg|p0|p1/.test(sev(a)) ? 0 : /warn|medium|p2/.test(sev(a)) ? 1 : 2;
    const sorted = firing.slice().sort((a, b) => rank(a) - rank(b) || (toDate(b.startsAt) - toDate(a.startsAt)));
    const crit = count(firing, a => rank(a) === 0);
    const oldest = min(firing, a => toDate(a.startsAt)?.getTime());
    return [
      item.status(crit ? 'Critical alerts firing' : 'Alerts firing', crit ? 'error' : 'warn', fmt.plural(firing.length, 'alert')),
      item.stat('Firing', firing.length, { color: crit ? 'red' : 'orange' }),
      item.stat('Critical', crit, { color: crit ? 'red' : 'secondary', caption: oldest ? 'oldest ' + fmt.ago(oldest) : undefined }),
      item.list(null, sorted.map(a => {
        const l = a.labels || {}, an = a.annotations || {};
        return {
          title: l.alertname || 'Alert',
          subtitle: [an.summary || an.description, l.instance || l.pod || l.job || l.grafana_folder].filter(Boolean).join(' · '),
          value: fmt.ago(a.startsAt).replace(' ago', ''),
          valueColor: rank(a) === 0 ? 'red' : rank(a) === 1 ? 'orange' : 'secondary',
          icon: rank(a) === 0 ? 'sf:exclamationmark.octagon.fill' : 'sf:exclamationmark.triangle.fill',
          url: a.generatorURL || undefined
        };
      }), { limit: 8 })
    ];
    """#

    /// Splits `curl … -w '\n%{http_code} %{time_total}'` output into `{ code, ms, body, json, error }`.
    static let curlResult = #"""
    function curlResult(text) {
      const parts = String(text ?? '').split('\n');
      const tail = (parts.pop() || '').trim().split(/\s+/);
      const body = parts.join('\n').trim();
      let json = null; try { json = JSON.parse(body); } catch (e) {}
      const code = tail[0] || '000';
      const err = /curl: \(\d+\)\s*(.*)/.exec(body);
      return { code, ok: /^[23]/.test(code), ms: (num(tail[1]) || 0) * 1000, body, json, error: err ? err[1] : null };
    }

    """#

    /// Deployment list rendering shared by Vercel and Netlify. Expects `deploys` =
    /// [{title, subtitle, state: 'ok'|'error'|'building'|'canceled', label, url, prod}] (newest first).
    static let deploys = #"""
    if (!deploys.length) return [item.text('No deployments yet', 'caption')];
    const color = s => ({ ok: 'green', error: 'red', building: 'orange', canceled: 'secondary' })[s] || 'secondary';
    const prod = deploys.find(d => d.prod && d.state !== 'canceled') || deploys[0];
    const failing = count(deploys.slice(0, 5), d => d.state === 'error');
    return [
      item.status(prod.prod ? 'Production' : 'Latest deploy', prod.state === 'ok' ? 'ok' : prod.state === 'error' ? 'error' : prod.state === 'building' ? 'warn' : 'info',
                  prod.label + ' · ' + fmt.ago(prod.created)),
      failing > 1 ? item.status('Recent failures', 'warn', failing + ' of last 5') : null,
      item.list('Recent', deploys.map(d => ({
        title: d.title, subtitle: d.subtitle + ' · ' + fmt.ago(d.created), value: d.label, valueColor: color(d.state),
        icon: d.state === 'ok' ? 'sf:checkmark.circle.fill' : d.state === 'error' ? 'sf:xmark.octagon.fill' : d.state === 'building' ? 'sf:hammer.fill' : 'sf:minus.circle',
        url: d.url })), { limit: 6 })
    ];
    """#

    /// zsh snippet: runs `body` over each comma-separated entry of `$list` in parallel.
    static func forEachCSV(_ listParam: String, _ body: String) -> String {
        "list={{\(listParam):sh}}; for x in ${(s:,:)list}; do x=${x// /}; [[ -z $x ]] && continue; ( \(body) ) & done; wait"
    }
}
