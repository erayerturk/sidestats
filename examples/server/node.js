// Minimal SideStats widget backend. No dependencies: `node node.js` (PORT env optional, default 8787).
//
// Point a widget at it (Settings → Widgets → Import):
//   {"name":"My SaaS","icon":"chart.line.uptrend.xyaxis","source":"http",
//    "url":"http://localhost:8787/sidestats","refreshSeconds":60}
//
// To require a token, start with `TOKEN=secret node node.js` and add this line to the
// widget's Headers field (stored in the Keychain, never exported):
//   Authorization: Bearer secret
const http = require('http');
const PORT = process.env.PORT || 8787;
const TOKEN = process.env.TOKEN; // unset = no auth check

const day = (n) => new Date(Date.now() - n * 864e5).toISOString().slice(0, 10);

function payload() {
  const signups = Array.from({ length: 14 }, (_, i) => ({ x: day(13 - i), y: 20 + Math.round(Math.random() * 30) }));
  const names = ['Ada', 'Alan', 'Grace', 'Linus', 'Margaret'];
  return {
    items: [
      { type: 'stat', label: 'MRR', value: 12840 + Math.round(Math.random() * 200), format: 'currency', currency: 'USD', delta: 0.08 },
      { type: 'stat', label: 'Signups (14d)', value: signups.reduce((s, p) => s + p.y, 0) },
      { type: 'chart', label: 'Signups', kind: 'bar', points: signups },
      { type: 'list', label: 'Recent signups', limit: 5, rows: names.map((n, i) => (
        { title: n, subtitle: i % 2 ? 'Pro plan' : 'Team plan', value: `${i * 7 + 2}m ago`, icon: 'sf:person.crop.circle' })) },
    ],
  };
}

http.createServer((req, res) => {
  if (req.url.split('?')[0] !== '/sidestats') { res.writeHead(404); return res.end(); }
  if (TOKEN && req.headers.authorization !== `Bearer ${TOKEN}`) { res.writeHead(401); return res.end('unauthorized'); }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload()));
}).listen(PORT, () => console.log(`SideStats widget server on http://localhost:${PORT}/sidestats`));
