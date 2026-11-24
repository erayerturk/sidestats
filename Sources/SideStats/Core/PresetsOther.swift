import Foundation

extension WidgetPresets {
    static let other: [WidgetPreset] = [
        WidgetPreset(
            id: "home-assistant", name: "Home Assistant", category: "Other", icon: "house",
            summary: "Live states of chosen Home Assistant entities: sensors as numbers with units, switches, lights and doors as on/off.",
            params: [
                urlParam("Home Assistant URL", placeholder: "http://homeassistant.local:8123", help: "Base URL of Home Assistant (local or Nabu Casa remote URL)."),
                PresetParam(id: "token", label: "Long-lived access token", help: "Your profile → Security → Long-lived access tokens → Create token.", secret: true),
                PresetParam(id: "entities", label: "Entities", placeholder: "sensor.living_room_temperature, light.kitchen", help: "Comma-separated entity IDs (Settings → Entities). A domain like `light.` matches all its entities."),
            ],
            template: http("Home", icon: "house", url: "{{url}}/api/states", refresh: 30, transform: "const wanted = {{entities:js}}.split(',').map(s => s.trim()).filter(Boolean);\n" + #"""
            if (!Array.isArray(data)) throw new Error((data && data.message) || 'Unexpected response');
            const pick = wanted.flatMap(w => w.endsWith('.') ? data.filter(e => e.entity_id.startsWith(w)) : data.filter(e => e.entity_id === w));
            if (!pick.length) return [item.text('None of the entities were found. Check the IDs in Settings → Entities.', 'caption')];
            const name = e => (e.attributes || {}).friendly_name || e.entity_id;
            const numeric = pick.filter(e => num(e.state) !== null);
            const other = pick.filter(e => num(e.state) === null);
            const ON = ['on', 'open', 'home', 'playing', 'unlocked', 'heat', 'cool', 'cleaning'];
            const ICON = { light: 'lightbulb.fill', switch: 'switch.2', binary_sensor: 'sensor.fill', lock: 'lock.fill', cover: 'blinds.horizontal.closed', person: 'person.fill',
                           media_player: 'play.rectangle.fill', climate: 'thermometer', vacuum: 'fan.fill', sun: 'sun.max.fill', weather: 'cloud.sun.fill', input_boolean: 'togglepower' };
            return [
              ...numeric.map(e => {
                const a = e.attributes || {}, u = a.unit_of_measurement || '', v = num(e.state);
                return item.stat(name(e), v, { unit: u ? (u.length <= 2 ? u : ' ' + u) : undefined, decimals: Math.abs(v) < 100 && v % 1 ? 1 : 0, caption: 'updated ' + fmt.ago(e.last_updated || e.last_changed) });
              }),
              other.length ? item.list(null, other.map(e => {
                const d = e.entity_id.split('.')[0], s = String(e.state);
                return { title: name(e), subtitle: fmt.ago(e.last_changed), value: s.replace(/_/g, ' '),
                         valueColor: s === 'unavailable' || s === 'unknown' ? 'red' : ON.includes(s) ? 'green' : 'secondary', icon: 'sf:' + (ICON[d] || 'circle.grid.2x2') };
              }), { limit: 12 }) : null
            ];
            """#),
            headers: "Authorization: Bearer {{token}}",
            docs: "https://developers.home-assistant.io/docs/api/rest/",
            requires: "Long-lived access token",
            sample: #"[{"entity_id":"sensor.living_room_temperature","state":"21.4","attributes":{"unit_of_measurement":"°C","friendly_name":"Living room"},"last_changed":"2026-11-25T11:50:00Z","last_updated":"2026-11-25T11:58:00Z"},{"entity_id":"light.kitchen","state":"on","attributes":{"friendly_name":"Kitchen"},"last_changed":"2026-11-25T11:00:00Z"},{"entity_id":"binary_sensor.front_door","state":"off","attributes":{"friendly_name":"Front door"},"last_changed":"2026-11-25T08:00:00Z"}]"#),

        WidgetPreset(
            id: "weather", name: "Weather", category: "Other", icon: "cloud.sun",
            summary: "Current conditions, the next 24 hours and a 3-day forecast from Open-Meteo. No API key.",
            params: [
                PresetParam(id: "place", label: "Place name", placeholder: "Istanbul", help: "Shown as the title.", defaultValue: "Weather"),
                PresetParam(id: "lat", label: "Latitude", placeholder: "41.01", help: "Decimal degrees (right-click a spot in Apple/Google Maps to copy coordinates)."),
                PresetParam(id: "lon", label: "Longitude", placeholder: "28.98", help: "Decimal degrees."),
                PresetParam(id: "units", label: "Units", help: "Temperature unit.", defaultValue: "celsius", options: ["celsius", "fahrenheit"]),
            ],
            template: http("{{place}}", icon: "cloud.sun",
                           url: "https://api.open-meteo.com/v1/forecast?latitude={{lat:url}}&longitude={{lon:url}}&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day&hourly=temperature_2m,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=4&temperature_unit={{units}}",
                           refresh: 900, transform: #"""
            if (data.error) throw new Error(data.reason || 'Weather request failed');
            const W = c => c === 0 ? ['Clear', 'sun.max.fill'] : c <= 2 ? ['Partly cloudy', 'cloud.sun.fill'] : c === 3 ? ['Overcast', 'cloud.fill']
              : c <= 48 ? ['Fog', 'cloud.fog.fill'] : c <= 57 ? ['Drizzle', 'cloud.drizzle.fill'] : c <= 67 ? ['Rain', 'cloud.rain.fill']
              : c <= 77 ? ['Snow', 'cloud.snow.fill'] : c <= 82 ? ['Showers', 'cloud.heavyrain.fill'] : c <= 86 ? ['Snow showers', 'cloud.snow.fill'] : ['Thunderstorm', 'cloud.bolt.rain.fill'];
            const cur = data.current || {}, u = (data.current_units || {}).temperature_2m || '°';
            const h = data.hourly || {}, d = data.daily || {};
            const nowIdx = Math.max(0, (h.time || []).findIndex(t => t >= String(cur.time || '').slice(0, 13)));
            const off = (data.utc_offset_seconds || 0) * 1000;
            const next = (h.time || []).slice(nowIdx, nowIdx + 24).map((t, i) => [new Date(t + ':00Z').getTime() - off, h.temperature_2m[nowIdx + i]]);
            const rain = max((h.precipitation_probability || []).slice(nowIdx, nowIdx + 12));
            const days = (d.time || []).map((t, i) => ({ t, code: d.weather_code[i], hi: d.temperature_2m_max[i], lo: d.temperature_2m_min[i], p: d.precipitation_probability_max[i] }));
            return [
              item.stat(W(cur.weather_code)[0], Math.round(cur.temperature_2m), { unit: u,
                caption: 'Feels ' + Math.round(cur.apparent_temperature) + u + ' · ' + cur.relative_humidity_2m + '% · wind ' + Math.round(cur.wind_speed_10m) + ' km/h' + (rain ? ' · rain ' + rain + '%' : '') }),
              next.length ? item.chart(null, next, { kind: 'area', height: 70, color: 'orange' }) : null,
              item.list(null, days.slice(1).map(x => ({
                title: new Date(x.t + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' }),
                subtitle: W(x.code)[0] + (x.p ? ' · ' + x.p + '% rain' : ''), value: Math.round(x.hi) + '° / ' + Math.round(x.lo) + '°', icon: 'sf:' + W(x.code)[1] })), { limit: 3 })
            ];
            """#),
            docs: "https://open-meteo.com/en/docs",
            sample: #"{"current_units":{"temperature_2m":"°C"},"current":{"time":"2026-11-25T14:00","temperature_2m":12.3,"apparent_temperature":10.1,"relative_humidity_2m":71,"weather_code":2,"wind_speed_10m":14.2,"is_day":1},"hourly":{"time":["2026-11-25T14:00","2026-11-25T15:00"],"temperature_2m":[12.3,12.0],"precipitation_probability":[10,20]},"daily":{"time":["2026-11-25","2026-11-26"],"weather_code":[2,61],"temperature_2m_max":[13.1,11.0],"temperature_2m_min":[7.2,6.5],"precipitation_probability_max":[20,80]}}"#),

        WidgetPreset(
            id: "crypto-prices", name: "Crypto prices", category: "Other", icon: "bitcoinsign.circle",
            summary: "Prices with 24 h change and a 7-day sparkline for any coins on CoinGecko. No API key.",
            params: [
                PresetParam(id: "coins", label: "Coins", placeholder: "bitcoin, ethereum, solana", help: "Comma-separated CoinGecko ids (the slug in coingecko.com/en/coins/<id>).", defaultValue: "bitcoin,ethereum"),
                PresetParam(id: "currency", label: "Currency", placeholder: "usd", help: "Quote currency (usd, eur, try, btc…).", defaultValue: "usd"),
            ],
            template: http("Crypto", icon: "bitcoinsign.circle",
                           url: "https://api.coingecko.com/api/v3/coins/markets?vs_currency={{currency:url}}&ids={{coinIds}}&sparkline=true&price_change_percentage=24h",
                           refresh: 120, transform: "const cur = {{currency:js}}.toUpperCase();\n" + #"""
            if (!Array.isArray(data)) throw new Error((data && (data.error || (data.status || {}).error_message)) || 'Unexpected response (rate limited?)');
            if (!data.length) return [item.text('No coins found. Use CoinGecko ids like bitcoin, ethereum.', 'caption')];
            const fiat = !['BTC', 'ETH', 'SATS'].includes(cur);
            return data.map(c => {
              const sp = ((c.sparkline_in_7d || {}).price || []).filter((_, i, a) => i % 4 === 0 || i === a.length - 1);
              return item.stat(c.symbol.toUpperCase(), c.current_price, { format: fiat ? 'currency' : 'number', currency: cur,
                decimals: c.current_price < 1 ? 4 : undefined, unit: fiat ? undefined : ' ' + cur,
                delta: num(c.price_change_percentage_24h) !== null ? c.price_change_percentage_24h / 100 : undefined, sparkline: sp });
            });
            """#),
            docs: "https://docs.coingecko.com/v3.0.1/reference/coins-markets",
            derive: { v in
                ["coinIds": (v["coins"] ?? "").split(separator: ",").map { encode($0.trimmingCharacters(in: .whitespaces).lowercased(), "url") }.joined(separator: ",")]
            },
            sample: #"[{"id":"bitcoin","symbol":"btc","name":"Bitcoin","current_price":59849,"price_change_percentage_24h":-1.99,"sparkline_in_7d":{"price":[61000,60500,62000,59849]}}]"#),

        WidgetPreset(
            id: "stock-price", name: "Stock price", category: "Other", icon: "chart.line.uptrend.xyaxis.circle",
            summary: "Price, daily change and chart of a stock, ETF, index or FX pair from Yahoo Finance's public chart endpoint. No API key (unofficial).",
            params: [
                PresetParam(id: "symbol", label: "Symbol", placeholder: "AAPL", help: "Yahoo symbol: AAPL, ^GSPC, VWCE.DE, EURUSD=X, BTC-USD."),
                PresetParam(id: "range", label: "Chart range", help: "Range shown in the chart.", defaultValue: "1mo", options: ["1d", "5d", "1mo", "6mo", "1y", "5y"]),
            ],
            template: http("{{symbol}}", icon: "chart.line.uptrend.xyaxis.circle",
                           url: "https://query1.finance.yahoo.com/v8/finance/chart/{{symbol:url}}?range={{range}}&interval={{interval}}",
                           refresh: 300, transform: #"""
            const ch = data.chart || {};
            if (ch.error) throw new Error(ch.error.description || ch.error.code);
            const r = (ch.result || [])[0];
            if (!r) throw new Error('Symbol not found');
            const m = r.meta || {}, closes = (((r.indicators || {}).quote || [])[0] || {}).close || [];
            const pts = (r.timestamp || []).map((t, i) => [t, closes[i]]).filter(p => p[1] !== null && p[1] !== undefined);
            const price = m.regularMarketPrice ?? (pts.length ? pts[pts.length - 1][1] : null);
            const chg = num(m.regularMarketChangePercent) !== null ? m.regularMarketChangePercent / 100
              : pts.length > 1 ? price / pts[pts.length - 2][1] - 1 : undefined;
            const first = pts.length ? pts[0][1] : null;
            return [
              item.stat(m.shortName || m.longName || m.symbol, price, { format: 'currency', currency: m.currency || 'USD', decimals: 2, delta: chg,
                caption: first ? 'range ' + (price >= first ? '+' : '') + fmt.pct(price / first - 1) + ' · ' + (m.fullExchangeName || m.exchangeName || '') : undefined }),
              pts.length ? item.chart(null, pts, { kind: 'area', format: 'currency', currency: m.currency || 'USD', height: 80, color: price >= (first || price) ? 'green' : 'red' }) : null
            ];
            """#),
            docs: "https://query1.finance.yahoo.com/v8/finance/chart/AAPL",
            requires: "Nothing (unofficial endpoint)",
            derive: { v in
                ["interval": ["1d": "5m", "5d": "30m", "1mo": "1d", "6mo": "1d", "1y": "1wk", "5y": "1mo"][v["range"] ?? ""] ?? "1d"]
            },
            sample: #"{"chart":{"result":[{"meta":{"currency":"USD","symbol":"AAPL","shortName":"Apple Inc.","regularMarketPrice":354.07,"regularMarketChangePercent":1.43,"fullExchangeName":"NasdaqGS"},"timestamp":[1795200000,1795286400,1795372800],"indicators":{"quote":[{"close":[340.1,347.73,354.07]}]}}],"error":null}}"#),

        WidgetPreset(
            id: "exchange-rates", name: "Exchange rates", category: "Other", icon: "dollarsign.arrow.trianglehead.counterclockwise.rotate.90",
            summary: "ECB reference rates for a base currency with 30-day change and trend (Frankfurter). No API key.",
            params: [
                PresetParam(id: "base", label: "Base currency", placeholder: "USD", help: "ISO code of the base currency.", defaultValue: "USD"),
                PresetParam(id: "symbols", label: "Currencies", placeholder: "EUR, GBP, TRY", help: "Comma-separated ISO codes.", defaultValue: "EUR,GBP,TRY"),
            ],
            template: http("{{base}} rates", icon: "dollarsign.arrow.trianglehead.counterclockwise.rotate.90",
                           url: "https://api.frankfurter.dev/v1/{{daysAgo:30}}..?base={{base:url}}&symbols={{symbols:url}}", refresh: 3600, transform: #"""
            if (!data.rates) throw new Error(data.message || 'Unexpected response');
            const days = Object.keys(data.rates).sort();
            const codes = Object.keys(data.rates[days[days.length - 1]] || {});
            return codes.map(c => {
              const series = days.map(d => data.rates[d][c]).filter(v => v !== undefined);
              const now = series[series.length - 1], then = series[0];
              return item.stat(data.base + ' → ' + c, now, { decimals: now >= 100 ? 2 : 4, delta: then ? now / then - 1 : undefined, caption: '30-day change', sparkline: series });
            });
            """#),
            docs: "https://frankfurter.dev",
            sample: #"{"amount":1.0,"base":"USD","start_date":"2026-10-26","end_date":"2026-11-24","rates":{"2026-10-26":{"EUR":0.92,"TRY":34.1},"2026-11-24":{"EUR":0.95,"TRY":35.2}}}"#),
    ]
}
