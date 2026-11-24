import Foundation
import JavaScriptCore

/// Runs a widget's JavaScript transform on its payload (JavaScriptCore).
///
/// Accepted script forms (tried in this order):
/// 1. An expression: `data.items`, `({items: [...]})`, or a function expression
///    (`data => ({items: [...]})`, `function (d) { … }`). A function is called with the payload.
/// 2. A statement body using `data` and `return`: `const up = data.filter(…); return {items: …}`.
///
/// Every call gets a fresh `JSVirtualMachine` + `JSContext`, so scripts can't leak state into each other.
/// The payload goes in as `data` through a JSON round trip, and the result comes back through
/// `JSON.stringify`, so only plain JSON values survive (functions, `undefined` and cycles don't).
///
/// Runaway scripts: the context group gets an execution time limit through JavaScriptCore's
/// `JSContextGroupSetExecutionTimeLimit` (exported SPI, looked up with `dlsym`). JSC checks it at loop
/// back-edges and function entries, so `while(true){}` is terminated after `timeLimit` seconds and the
/// widget fails with a timeout error. If the symbol is ever missing, the script runs on a helper thread
/// and the caller stops waiting after the limit; the helper thread keeps spinning until the script ends
/// (JSC can't be interrupted from outside), so that fallback protects the UI but not the CPU.
/// Note the limit counts JS execution only; a single huge native call (e.g. sorting 10M items) still runs to completion.
enum WidgetTransform {
    /// Seconds a transform may run. Transforms run on the caller's thread (usually the main actor),
    /// so this is also the worst-case UI stall.
    static let timeLimit: TimeInterval = 2

    static func apply(_ script: String, to payload: Any) throws -> Any {
        let source = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { return payload }
        let json = try encode(payload)
        if setTimeLimit != nil { return try run(source, json: json) }
        return try runOnHelperThread(source, json: json)
    }

    // MARK: execution

    private static func run(_ source: String, json: String) throws -> Any {
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            throw SideStatsError("Transform: could not create a JavaScript context")
        }
        var logs: [String] = []
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            logs.append(args.map { $0.isObject ? ($0.context.objectForKeyedSubscript("JSON")
                .invokeMethod("stringify", withArguments: [$0])?.toString() ?? "") : ($0.toString() ?? "") }
                .joined(separator: " "))
            if logs.count > 20 { logs.removeFirst() }
        }
        let native = JSValue(newObjectIn: ctx)
        native?.setObject(log, forKeyedSubscript: "log" as NSString)
        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
        if let setTimeLimit {
            setTimeLimit(JSContextGetGroup(ctx.jsGlobalContextRef), timeLimit, { _, _ in true }, nil)
        }
        _ = ctx.evaluateScript(prelude)
        if let e = ctx.exception { throw SideStatsError("Transform runtime error: \(e)") }
        ctx.setObject(json, forKeyedSubscript: "__payload" as NSString)
        _ = ctx.evaluateScript("var data = JSON.parse(__payload); delete globalThis.__payload;")

        // Form 1 (expression / function expression), else form 2 (statement body).
        let asExpression = "(" + source + "\n)"
        let code: String
        if syntaxOK(asExpression, ctx: ctx) {
            code = "__finish((function(){ var __r = " + asExpression + "; return typeof __r === 'function' ? __r(data) : __r; })())"
        } else {
            code = "__finish((function(data){ " + source + "\n})(data))"
        }
        let started = Date()
        let result = ctx.evaluateScript(code, withSourceURL: URL(string: "transform.js"))
        if let e = ctx.exception {
            throw error(e, logs: logs, timedOut: Date().timeIntervalSince(started) >= timeLimit * 0.95)
        }
        guard let result, result.isString, let out = result.toString() else {
            throw SideStatsError("Transform returned nothing. Use `return …` in a statement body, or a function like `data => ({items: […]})`." + logSuffix(logs))
        }
        if out == "__undefined__" {
            throw SideStatsError("Transform returned undefined. Did you forget `return`?" + logSuffix(logs))
        }
        return try JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed])
    }

    private static func runOnHelperThread(_ source: String, json: String) throws -> Any {
        final class Box: @unchecked Sendable { var result: Result<Any, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = Result { try run(source, json: json) }
            done.signal()
        }
        thread.stackSize = 4 << 20
        thread.start()
        guard done.wait(timeout: .now() + timeLimit) == .success, let r = box.result else {
            throw SideStatsError("Transform timed out after \(Int(timeLimit)) s (infinite loop?)")
        }
        return try r.get()
    }

    private static func syntaxOK(_ code: String, ctx: JSContext) -> Bool {
        let s = JSStringCreateWithCFString(code as CFString)
        defer { JSStringRelease(s) }
        return JSCheckScriptSyntax(ctx.jsGlobalContextRef, s, nil, 1, nil)
    }

    private static func encode(_ payload: Any) throws -> String {
        let value: Any = payload is NSNull ? NSNull() : payload
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            throw SideStatsError("Transform: payload is not JSON-serializable")
        }
        return String(decoding: d, as: UTF8.self)
    }

    private static func error(_ e: JSValue, logs: [String], timedOut: Bool) -> SideStatsError {
        let message = e.toString() ?? "unknown error"
        if timedOut || message.contains("execution terminated") {
            return SideStatsError("Transform timed out after \(Int(timeLimit)) s (infinite loop?)" + logSuffix(logs))
        }
        var line = ""
        if let l = e.objectForKeyedSubscript("line"), l.isNumber { line = " (line \(l.toInt32()))" }
        return SideStatsError("Transform error\(line): \(message)" + logSuffix(logs))
    }

    private static func logSuffix(_ logs: [String]) -> String {
        logs.isEmpty ? "" : "\nconsole.log:\n" + logs.suffix(5).joined(separator: "\n")
    }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private static let setTimeLimit: SetLimit? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetLimit.self)
    }()

    // MARK: helpers available to every script (documented in WIDGETS.md → Transforms)

    static let prelude = #"""
    var console = { log: function(){ __native.log.apply(null, arguments) } };
    console.warn = console.error = console.info = console.log;

    function num(v) {
      if (v === null || v === undefined || v === '' || typeof v === 'boolean') return null;
      var n = typeof v === 'number' ? v : Number(String(v).trim().replace(/,/g, ''));
      if (typeof v !== 'number' && String(v).trim() === '') return null;
      return isFinite(n) ? n : null;
    }
    function toDate(v) {
      if (v === null || v === undefined || v === '') return null;
      if (v instanceof Date) return v;
      if (typeof v === 'number' || /^\d+(\.\d+)?$/.test(String(v))) {
        var n = Number(v); return new Date(n > 1e12 ? n : n * 1000);
      }
      var s = String(v);
      if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(s)) s = s.replace(' ', 'T') + (/[zZ]|[+-]\d{2}:?\d{2}$/.test(s) ? '' : 'Z');
      s = s.replace(/(\.\d{3})\d+/, '$1');          // JSC rejects >3 fractional digits
      var d = new Date(s); return isNaN(d) ? null : d;
    }
    function __key(key) {
      if (typeof key === 'function') return key;
      if (key === undefined || key === null) return function (x) { return x; };
      var parts = String(key).split('.');
      return function (x) { for (var i = 0; i < parts.length && x != null; i++) x = x[parts[i]]; return x; };
    }
    function __arr(a) { return Array.isArray(a) ? a : (a == null ? [] : (typeof a === 'object' ? Object.values(a) : [a])); }
    function sum(arr, key) { var f = __key(key); return __arr(arr).reduce(function (s, x) { var n = num(f(x)); return n === null ? s : s + n; }, 0); }
    function avg(arr, key) { var f = __key(key), n = 0, s = 0; __arr(arr).forEach(function (x) { var v = num(f(x)); if (v !== null) { s += v; n++; } }); return n ? s / n : null; }
    function min(arr, key) { var f = __key(key), r = null; __arr(arr).forEach(function (x) { var v = num(f(x)); if (v !== null && (r === null || v < r)) r = v; }); return r; }
    function max(arr, key) { var f = __key(key), r = null; __arr(arr).forEach(function (x) { var v = num(f(x)); if (v !== null && (r === null || v > r)) r = v; }); return r; }
    function count(arr, pred) { var f = __key(pred); return __arr(arr).filter(function (x) { return !!f(x); }).length; }
    function groupBy(arr, key) { var f = __key(key), o = {}; __arr(arr).forEach(function (x) { var k = String(f(x)); (o[k] = o[k] || []).push(x); }); return o; }
    function countBy(arr, key) { var f = __key(key), o = {}; __arr(arr).forEach(function (x) { var k = String(f(x)); o[k] = (o[k] || 0) + 1; }); return o; }
    function sortBy(arr, key, desc) {
      var f = __key(key);
      return __arr(arr).slice().sort(function (a, b) {
        var x = f(a), y = f(b), nx = num(x), ny = num(y);
        var c = (nx !== null && ny !== null) ? nx - ny : String(x).localeCompare(String(y));
        return desc ? -c : c;
      });
    }
    function uniq(arr, key) { var f = __key(key), seen = {}; return __arr(arr).filter(function (x) { var k = String(f(x)); if (seen[k]) return false; seen[k] = 1; return true; }); }
    function lines(text) { return String(text == null ? '' : text).split(/\r?\n/).map(function (l) { return l.trim(); }).filter(Boolean); }
    function jsonLines(text) { return lines(text).map(function (l) { try { return JSON.parse(l); } catch (e) { return null; } }).filter(function (x) { return x !== null; }); }
    function level(v, warn, crit) { var n = num(v); if (n === null) return 'info'; return n >= crit ? 'error' : n >= warn ? 'warn' : 'ok'; }
    function levelColor(v, warn, crit) { return { ok: 'green', warn: 'orange', error: 'red', info: 'secondary' }[level(v, warn, crit)]; }

    var fmt = {
      num: function (v, decimals) {
        var n = num(v); if (n === null) return '—';
        var a = Math.abs(n);
        if (decimals === undefined && a >= 1e5) {
          var u = a >= 1e12 ? ['T', 1e12] : a >= 1e9 ? ['B', 1e9] : a >= 1e6 ? ['M', 1e6] : ['k', 1e3];
          return (n / u[1]).toFixed(1).replace(/\.0$/, '') + u[0];
        }
        var d = decimals === undefined ? (a >= 100 ? 0 : a >= 10 ? 1 : 2) : decimals;
        return n.toLocaleString('en-US', { minimumFractionDigits: decimals === undefined ? 0 : d, maximumFractionDigits: d });
      },
      money: function (v, cur, decimals) {
        var n = num(v); if (n === null) return '—';
        cur = (cur || 'USD').toUpperCase();
        try {
          var compact = Math.abs(n) >= 1e5 && decimals === undefined;
          return new Intl.NumberFormat('en-US', { style: 'currency', currency: cur, notation: compact ? 'compact' : 'standard',
            maximumFractionDigits: decimals !== undefined ? decimals : (compact ? 1 : (Math.abs(n) >= 1000 ? 0 : 2)),
            minimumFractionDigits: decimals !== undefined ? decimals : 0 }).format(n);
        } catch (e) { return cur + ' ' + fmt.num(n, 2); }
      },
      pct: function (fraction, decimals) { var n = num(fraction); return n === null ? '—' : (n * 100).toFixed(decimals === undefined ? 1 : decimals) + '%'; },
      bytes: function (v, decimals) {
        var n = num(v); if (n === null) return '—';
        var u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'], i = 0;
        while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        return n.toFixed(decimals === undefined ? (i === 0 || n >= 100 ? 0 : 1) : decimals) + ' ' + u[i];
      },
      ms: function (v) { var n = num(v); if (n === null) return '—'; return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + ' s' : Math.round(n) + ' ms'; },
      duration: function (seconds) {
        var s = num(seconds); if (s === null) return '—';
        s = Math.max(0, Math.round(s));
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
        return d ? d + 'd ' + h + 'h' : h ? h + 'h ' + m + 'm' : m ? m + 'm' : s + 's';
      },
      ago: function (v) {
        var d = toDate(v); if (!d) return '—';
        var s = (Date.now() - d.getTime()) / 1000;
        if (s < 0) return 'in ' + fmt.duration(-s);
        if (s < 45) return 'just now';
        return fmt.duration(s).split(' ')[0] + ' ago';
      },
      date: function (v, withTime) {
        var d = toDate(v); if (!d) return '—';
        var o = { month: 'short', day: 'numeric' };
        if (withTime) { o.hour = '2-digit'; o.minute = '2-digit'; o.hour12 = false; }
        return d.toLocaleString('en-US', o);
      },
      time: function (v) { var d = toDate(v); return d ? d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false }) : '—'; },
      plural: function (n, word, pluralWord) { return n + ' ' + (n === 1 ? word : (pluralWord || word + 's')); }
    };

    function __mk(type, positional) {
      return function () {
        var a = arguments, o = {};
        if (a.length === 1 && a[0] && typeof a[0] === 'object' && !Array.isArray(a[0])) o = Object.assign({}, a[0]);
        else {
          for (var i = 0; i < positional.length && i < a.length; i++) if (a[i] !== undefined) o[positional[i]] = a[i];
          var extra = a[positional.length];
          if (extra && typeof extra === 'object') Object.assign(o, extra);
        }
        o.type = type;
        return o;
      };
    }
    var item = {
      stat: __mk('stat', ['label', 'value']),                 // item.stat('MRR', 1200, {format:'currency'})
      chart: __mk('chart', ['label', 'points']),              // item.chart('CPU', [[t, v], …], {kind:'area'})
      list: __mk('list', ['label', 'rows']),                  // item.list('Latest', [{title, subtitle, value}])
      text: __mk('text', ['text', 'style']),                  // item.text('**Hi**', 'body')
      progress: __mk('progress', ['label', 'value', 'max']),  // item.progress('Disk', 0.42)
      status: __mk('status', ['label', 'state', 'detail'])    // item.status('API', 'ok', '42 ms')
    };
    item.ok = function (label, detail) { return item.status(label, 'ok', detail); };
    item.error = function (label, detail) { return item.status(label, 'error', detail); };

    function __finish(r) {
      if (r === undefined) return '__undefined__';
      function clean(list) {
        var out = [];
        (function walk(l) { l.forEach(function (x) { if (Array.isArray(x)) walk(x); else if (x && typeof x === 'object') out.push(x); }); })(list);
        return out;
      }
      if (Array.isArray(r) && r.some(function (x) { return x && x.type; })) r = { items: clean(r) };
      else if (r && typeof r === 'object' && Array.isArray(r.items)) r = Object.assign({}, r, { items: clean(r.items) });
      return JSON.stringify(r === undefined ? null : r);
    }
    """#
}
