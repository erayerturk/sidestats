import Foundation

extension WidgetPresets {
    /// JS: parses `key=value` lines into { kv: {key: [values…]}, other: [non key=value lines] }.
    static let kvJS = #"""
    function kvLines(text) {
      const kv = {}, other = [];
      String(text ?? '').split('\n').forEach(l => {
        const m = /^([a-z][a-z0-9_]*)=(.*)$/i.exec(l.trim());
        if (m) (kv[m[1]] = kv[m[1]] || []).push(m[2]); else if (l.trim()) other.push(l.trim());
      });
      const one = k => (kv[k] || [])[0];
      return { kv, other, one };
    }

    """#

    static let sshParams: [PresetParam] = [
        PresetParam(id: "host", label: "SSH host", placeholder: "user@server.example.com", help: "user@host or a Host alias from ~/.ssh/config. Key-based login is required (BatchMode: no password prompts)."),
        PresetParam(id: "port", label: "Port", placeholder: "22", help: "SSH port.", defaultValue: "22"),
    ]

    static let servers: [WidgetPreset] = [
        WidgetPreset(
            id: "mac-system", name: "This Mac", category: "Servers", icon: "desktopcomputer",
            summary: "CPU usage, load, memory pressure, disk space, battery and the busiest processes of the Mac running SideStats.",
            params: [],
            template: command("This Mac", icon: "desktopcomputer", command: #"""
            export LC_ALL=C
            print "name=$(scutil --get ComputerName 2>/dev/null)"
            print "ncpu=$(sysctl -n hw.ncpu)"
            print "load=$(sysctl -n vm.loadavg | tr -d '{}')"
            print "boot=$(sysctl -n kern.boottime | sed -E 's/^[{] sec = ([0-9]+).*/\1/')"
            print "mem=$(sysctl -n hw.memsize)"
            print "free_pct=$(memory_pressure -Q 2>/dev/null | sed -nE 's/.*percentage: ([0-9]+)%.*/\1/p')"
            vm_stat | awk -F: '/page size of/{gsub(/[^0-9]/,"",$0); print "pagesize="$0} /wired down|occupied by compressor|Anonymous pages|Pages purgeable/{k=$1; gsub(/[^A-Za-z]/,"",k); v=$2; gsub(/[ .]/,"",v); print "vm_"k"="v}'
            df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print "disk="$2" "$3" "$4}'
            pmset -g batt | sed -nE 's/.*[[:space:]]([0-9]+)%; ([^;]+);.*/batt=\1 \2/p'
            top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1 | sed -E 's/.* ([0-9.]+)% idle.*/idle=\1/'
            ps -Arco pcpu=,rss=,comm= | head -5 | sed 's/^ */top=/'
            """#, refresh: 15, transform: kvJS + #"""
            const { kv, one } = kvLines(data);
            const ncpu = num(one('ncpu')) || 1, load = String(one('load') || '').trim().split(/\s+/).map(num);
            const memTotal = num(one('mem')), ps = num(one('pagesize')) || 16384;
            const used = ((num(one('vm_Pageswireddown')) || 0) + (num(one('vm_Pagesoccupiedbycompressor')) || 0)
                        + (num(one('vm_Anonymouspages')) || 0) - (num(one('vm_Pagespurgeable')) || 0)) * ps;
            const free = num(one('free_pct'));
            const pressure = free === null ? null : free < 10 ? 'error' : free < 25 ? 'warn' : 'ok';
            const disk = String(one('disk') || '').split(' ').map(n => num(n) * 1024);
            const idle = num(one('idle')), cpu = idle === null ? null : (100 - idle) / 100;
            const batt = /^(\d+) (.*)$/.exec(one('batt') || '');
            const up = Date.now() / 1000 - (num(one('boot')) || Date.now() / 1000);
            return [
              item.stat('CPU', cpu, { format: 'percent', color: levelColor(cpu * 100, 70, 90), caption: ncpu + ' cores' }),
              item.stat('Load', load[0], { decimals: 2, color: load[0] > ncpu ? 'orange' : undefined, caption: load.slice(1).map(l => l?.toFixed(2)).join(' · ') }),
              item.stat('Uptime', up, { format: 'duration' }),
              item.progress('Memory', used, memTotal, { caption: fmt.bytes(used) + ' / ' + fmt.bytes(memTotal) }),
              pressure ? item.status('Memory pressure', pressure, free + '% free') : null,
              disk.length === 3 ? item.progress('Disk', disk[1], disk[0], { caption: fmt.bytes(disk[2]) + ' free', color: disk[2] / disk[0] < 0.1 ? 'red' : undefined }) : null,
              batt ? item.progress('Battery', num(batt[1]) / 100, null, { caption: batt[1] + '% · ' + batt[2], color: num(batt[1]) < 20 && !/charg/.test(batt[2]) ? 'red' : 'green' }) : null,
              item.list('Top processes', (kv.top || []).map(l => {
                const m = /^([\d.]+)\s+(\d+)\s+(.*)$/.exec(l) || [];
                return { title: m[3] || l, subtitle: fmt.bytes(num(m[2]) * 1024), value: (num(m[1]) ?? 0).toFixed(0) + '%', valueColor: num(m[1]) > 80 ? 'orange' : undefined, icon: 'sf:gearshape' };
              }), { limit: 5 })
            ];
            """#),
            docs: "https://ss64.com/mac/vm_stat.html",
            requires: "Nothing",
            sample: "name=Mac mini\nncpu=12\nload= 4.54 5.86 7.22 \nboot=1794955452\nmem=51539607552\nfree_pct=50\npagesize=16384\nvm_Pageswireddown=308649\nvm_Pagespurgeable=19503\nvm_Anonymouspages=1003351\nvm_Pagesoccupiedbycompressor=1237598\ndisk=482797652 428254344 28843044\nidle=71.5\ntop=95.4 501248 Godot\ntop=55.0 124640 WindowServer"),

        WidgetPreset(
            id: "ssh-server", name: "Linux server (SSH)", category: "Servers", icon: "server.rack",
            summary: "CPU, load, memory, disks, temperature, uptime and top processes of a Linux box over SSH. Great for VPSes and Raspberry Pis.",
            params: sshParams,
            template: command("{{host}}", icon: "server.rack", command: #"""
            ssh -o BatchMode=yes -o ConnectTimeout=8 -p {{port}} {{host:sh}} 'LC_ALL=C sh -s' 2>&1 <<'EOF'
            echo "host=$(hostname)"
            . /etc/os-release 2>/dev/null; echo "os=${PRETTY_NAME:-$(uname -sr)}"
            echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
            echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
            echo "ncpu=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
            echo "cpu1=$(head -1 /proc/stat)"; sleep 1; echo "cpu2=$(head -1 /proc/stat)"
            awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}/^SwapTotal/{st=$2}/^SwapFree/{sf=$2}END{print "mem="t" "a" "st" "sf}' /proc/meminfo
            df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | awk 'NR>1 && $2>1048576 {print "disk="$6" "$2" "$3" "$4}'
            t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) && echo "temp=$t"
            ps -eo pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | head -5 | sed 's/^ */top=/'
            EOF
            print "exit=$?"
            """#, refresh: 30, transform: kvJS + #"""
            const { kv, other, one } = kvLines(data);
            if (!one('host')) return [item.error('Unreachable', (other.find(l => !/^Warning/.test(l)) || 'ssh exit ' + one('exit')).slice(0, 120))];
            const ncpu = num(one('ncpu')) || 1, load = String(one('load') || '').split(' ').map(num);
            const jiff = s => String(s || '').trim().split(/\s+/).slice(1).map(Number);
            const a = jiff(one('cpu1')), b = jiff(one('cpu2'));
            const tot = sum(b) - sum(a), idle = (b[3] + (b[4] || 0)) - (a[3] + (a[4] || 0));
            const cpu = tot > 0 ? 1 - idle / tot : null;
            const [mt, ma, st, sf] = String(one('mem') || '').split(' ').map(n => num(n) * 1024);
            const temp = num(one('temp')) !== null ? num(one('temp')) / 1000 : null;
            const disks = (kv.disk || []).map(l => { const [mount, size, used, avail] = l.split(' '); return { mount, size: size * 1024, used: used * 1024, avail: avail * 1024 }; });
            return [
              item.status(one('host'), 'ok', (one('os') || '').replace(/ GNU\/Linux/, '') + ' · up ' + fmt.duration(num(one('uptime')))),
              item.stat('CPU', cpu, { format: 'percent', color: levelColor(cpu * 100, 70, 90), caption: ncpu + ' cores' }),
              item.stat('Load', load[0], { decimals: 2, color: load[0] > ncpu ? 'orange' : undefined, caption: load.slice(1).map(l => l?.toFixed(2)).join(' · ') }),
              temp !== null ? item.stat('Temp', Math.round(temp), { unit: '°C', color: levelColor(temp, 70, 80) }) : null,
              item.progress('Memory', mt - ma, mt, { caption: fmt.bytes(mt - ma) + ' / ' + fmt.bytes(mt) }),
              st > 0 && st - sf > st * 0.05 ? item.progress('Swap', st - sf, st, { caption: fmt.bytes(st - sf) + ' / ' + fmt.bytes(st), color: 'orange' }) : null,
              ...disks.slice(0, 4).map(d => item.progress('Disk ' + d.mount, d.used, d.size, { caption: fmt.bytes(d.avail) + ' free' })),
              item.list('Top processes', (kv.top || []).map(l => {
                const m = /^([\d.]+)\s+([\d.]+)\s+(.*)$/.exec(l) || [];
                return { title: m[3] || l, subtitle: 'mem ' + (m[2] || '?') + '%', value: (num(m[1]) ?? 0).toFixed(0) + '%', icon: 'sf:gearshape' };
              }), { limit: 5 })
            ];
            """#),
            docs: "https://man.openbsd.org/ssh_config#BatchMode",
            requires: "SSH key login (no password prompt)",
            sample: "host=pi5\nos=Debian GNU/Linux 12 (bookworm)\nuptime=864123.45\nload=0.42 0.35 0.30\nncpu=4\ncpu1=cpu  1000 0 500 8000 100 0 10 0 0 0\ncpu2=cpu  1030 0 515 8350 102 0 10 0 0 0\nmem=8245000 6100000 524284 524284\ndisk=/ 61202244 12003000 46000000\ntemp=48250\ntop=3.1  1.2 node\ntop=1.0  0.4 sshd\nexit=0"),

        WidgetPreset(
            id: "systemd-units", name: "systemd services (SSH)", category: "Servers", icon: "gearshape.2",
            summary: "State of chosen systemd units on a Linux host, plus any failed units, over SSH.",
            params: sshParams + [
                PresetParam(id: "units", label: "Units", placeholder: "nginx, postgresql, docker", help: "Comma-separated unit names (.service is implied). Leave empty to only show failed units.", optional: true),
            ],
            template: command("Services on {{host}}", icon: "gearshape.2", command: #"""
            printf '%s\n' {{units:sh}} | ssh -o BatchMode=yes -o ConnectTimeout=8 -p {{port}} {{host:sh}} 'u=$(tr ", " "\n\n" | grep -E "^[A-Za-z0-9@._:-]+$" | tr "\n" " "); export LC_ALL=C; [ -n "$u" ] && systemctl show --no-pager -p Id -p Description -p ActiveState -p SubState -p ActiveEnterTimestamp -p NRestarts $u; echo; echo "---failed"; systemctl list-units --state=failed --plain --no-legend --no-pager' 2>&1
            print -r -- "---exit=$?"
            """#, refresh: 60, transform: #"""
            const text = String(data ?? '');
            const [main, rest = ''] = text.split('---failed');
            const exit = num((/---exit=(\d+)/.exec(text) || [])[1]);
            if (!text.includes('---failed')) return [item.error('Unreachable', lines(text).filter(l => !/^---exit|^Warning/.test(l))[0] || 'ssh exit ' + exit)];
            const units = main.split(/\n\s*\n/).map(b => Object.fromEntries(lines(b).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))).filter(u => u.Id);
            const failed = lines(rest.split('---exit')[0]).map(l => l.split(/\s+/)[0]).filter(Boolean);
            const STATE = { active: 'ok', reloading: 'warn', activating: 'warn', deactivating: 'warn', inactive: 'info', failed: 'error' };
            const extra = failed.filter(f => !units.some(u => u.Id === f));
            return [
              item.status(failed.length ? fmt.plural(failed.length, 'failed unit') : 'No failed units', failed.length ? 'error' : 'ok', units.length ? count(units, u => u.ActiveState === 'active') + '/' + units.length + ' watched active' : undefined),
              ...units.map(u => item.status(u.Id.replace(/\.service$/, ''), STATE[u.ActiveState] || 'info',
                [u.SubState, u.ActiveState === 'active' && u.ActiveEnterTimestamp ? 'since ' + fmt.ago(u.ActiveEnterTimestamp.replace(/^\w+ /, '').replace(/ [A-Z]+$/, '')).replace(' ago', '') : null,
                 num(u.NRestarts) ? u.NRestarts + ' restarts' : null].filter(Boolean).join(' · '))),
              ...extra.map(f => item.status(f.replace(/\.service$/, ''), 'error', 'failed'))
            ];
            """#),
            docs: "https://www.freedesktop.org/software/systemd/man/latest/systemctl.html",
            requires: "SSH key login",
            sample: "Id=nginx.service\nDescription=nginx web server\nActiveState=active\nSubState=running\nActiveEnterTimestamp=Mon 2026-11-23 08:12:01 UTC\nNRestarts=0\n\nId=postgresql.service\nDescription=PostgreSQL\nActiveState=failed\nSubState=failed\nActiveEnterTimestamp=\nNRestarts=3\n\n---failed\npostgresql.service loaded failed failed PostgreSQL\nbackup.service loaded failed failed Nightly backup\n---exit=0"),

        WidgetPreset(
            id: "docker-containers", name: "Docker containers", category: "Servers", icon: "shippingbox",
            summary: "Running, stopped and unhealthy containers with live CPU and memory, via the Docker CLI (local or a remote context).",
            params: [
                PresetParam(id: "context", label: "Docker context", placeholder: "default", help: "Optional `docker context` name for a remote host (docker context create … --docker host=ssh://user@server).", optional: true),
            ],
            template: command("Docker", icon: "shippingbox", command: #"""
            c={{context:sh}}; d() { if [[ -n $c ]]; then docker --context "$c" "$@"; else docker "$@"; fi; }
            d ps -a --format '{{json .}}' 2>&1; print -- '---stats'; d stats --no-stream --format '{{json .}}' 2>/dev/null
            """#, refresh: 30, transform: #"""
            const text = String(data ?? '');
            const [psPart, statsPart = ''] = text.split('---stats');
            const cs = jsonLines(psPart), stats = jsonLines(statsPart);
            if (!cs.length) {
              const err = lines(psPart)[0];
              return err ? [item.error('Docker', /daemon|connect/i.test(err) ? 'Docker is not running' : err.slice(0, 120))] : [item.text('No containers', 'caption')];
            }
            const st = Object.fromEntries(stats.map(s => [s.Name, s]));
            const health = c => /unhealthy/.test(c.Status) ? 'unhealthy' : /healthy/.test(c.Status) ? 'healthy' : /starting/.test(c.Status) ? 'starting' : '';
            const bad = c => c.State === 'restarting' || c.State === 'dead' || health(c) === 'unhealthy' || (c.State === 'exited' && !/Exited \(0\)/.test(c.Status));
            const running = cs.filter(c => c.State === 'running');
            const rank = c => bad(c) ? 0 : c.State === 'running' ? 1 : 2;
            return [
              item.stat('Running', running.length, { color: 'green' }),
              item.stat('Stopped', cs.length - running.length, { color: cs.length - running.length ? 'secondary' : undefined }),
              item.stat('Problems', count(cs, bad), { color: count(cs, bad) ? 'red' : 'secondary' }),
              item.list(null, sortBy(cs, c => rank(c) + c.Names.toLowerCase().padStart(1)).map(c => {
                const s = st[c.Names];
                return {
                  title: c.Names,
                  subtitle: c.Image.replace(/^.*\//, '').slice(0, 28) + ' · ' + c.Status.replace(/ \((un)?healthy\)/, ''),
                  value: s && c.State === 'running' ? s.CPUPerc + ' · ' + String(s.MemUsage).split(' / ')[0] : (health(c) || c.State),
                  valueColor: bad(c) ? 'red' : c.State === 'running' ? 'green' : 'secondary',
                  icon: bad(c) ? 'sf:exclamationmark.triangle.fill' : c.State === 'running' ? 'sf:shippingbox.fill' : 'sf:shippingbox'
                };
              }), { limit: 12 })
            ];
            """#),
            docs: "https://docs.docker.com/reference/cli/docker/container/ls/#format",
            requires: "Docker CLI",
            sample: "{\"ID\":\"7d158a2c7b53\",\"Image\":\"postgres:16\",\"Names\":\"db\",\"State\":\"running\",\"Status\":\"Up 3 hours (healthy)\"}\n{\"ID\":\"ab12\",\"Image\":\"ghcr.io/acme/api:1.4\",\"Names\":\"api\",\"State\":\"restarting\",\"Status\":\"Restarting (1) 5 seconds ago\"}\n{\"ID\":\"cd34\",\"Image\":\"redis:7-alpine\",\"Names\":\"cache\",\"State\":\"exited\",\"Status\":\"Exited (0) 2 days ago\"}\n---stats\n{\"Name\":\"db\",\"CPUPerc\":\"0.42%\",\"MemUsage\":\"48.2MiB / 7.6GiB\",\"MemPerc\":\"0.62%\"}"),

        WidgetPreset(
            id: "kubernetes-pods", name: "Kubernetes pods", category: "Servers", icon: "helm",
            summary: "Pod health for a namespace (or all): running/pending/failing counts, restarts and CrashLoopBackOff detection via kubectl.",
            params: [
                PresetParam(id: "namespace", label: "Namespace", placeholder: "default", help: "A namespace, or `all` for every namespace.", defaultValue: "default"),
                PresetParam(id: "context", label: "kubectl context", placeholder: "current context", help: "Optional context name from your kubeconfig.", optional: true),
            ],
            template: command("Pods · {{namespace}}", icon: "helm", command: #"""
            c={{context:sh}}; n={{namespace:sh}}; args=(); [[ -n $c ]] && args+=(--context "$c")
            if [[ $n == all ]]; then args+=(-A); else args+=(-n "$n"); fi
            kubectl "${args[@]}" get pods -o json --request-timeout=15s 2>&1
            """#, refresh: 30, transform: #"""
            if (typeof data === 'string') return [item.error('kubectl', lines(data).filter(l => !/^E\d{4}/.test(l))[0]?.slice(0, 140) || lines(data)[0]?.slice(0, 140) || 'kubectl failed')];
            const pods = (data.items || []).map(p => {
              const cs = (p.status || {}).containerStatuses || [];
              const waiting = cs.map(c => c.state && c.state.waiting && c.state.waiting.reason).find(Boolean);
              const term = cs.map(c => c.state && c.state.terminated && c.state.terminated.reason).find(Boolean);
              const phase = p.metadata.deletionTimestamp ? 'Terminating' : (waiting || (p.status.phase === 'Running' ? null : term) || p.status.phase);
              const ready = count(cs, c => c.ready);
              const bad = /BackOff|Err|Failed|Unknown|OOM|Invalid/.test(phase) || (phase === 'Running' && ready < cs.length);
              return { name: p.metadata.name, ns: p.metadata.namespace, phase, ready, total: cs.length, restarts: sum(cs, 'restartCount'),
                       start: p.status.startTime, bad, done: phase === 'Succeeded' || phase === 'Completed' };
            });
            if (!pods.length) return [item.status('No pods', 'info', 'namespace is empty')];
            const running = count(pods, p => p.phase === 'Running' && !p.bad), pending = count(pods, p => /Pending|ContainerCreating|PodInitializing/.test(p.phase));
            const failing = count(pods, p => p.bad), multi = uniq(pods, 'ns').length > 1;
            return [
              item.stat('Running', running, { caption: 'of ' + pods.length, color: 'green' }),
              item.stat('Pending', pending, { color: pending ? 'orange' : 'secondary' }),
              item.stat('Failing', failing, { color: failing ? 'red' : 'secondary', caption: sum(pods, 'restarts') + ' restarts' }),
              item.list(null, sortBy(pods, p => (p.bad ? 0 : p.phase === 'Running' ? 2 : p.done ? 3 : 1) + p.name).map(p => ({
                title: p.name, subtitle: [multi ? p.ns : null, p.ready + '/' + p.total + ' ready', p.restarts ? p.restarts + ' restarts' : null, p.start ? fmt.ago(p.start).replace(' ago', '') : null].filter(Boolean).join(' · '),
                value: p.phase, valueColor: p.bad ? 'red' : p.phase === 'Running' ? 'green' : p.done ? 'secondary' : 'orange',
                icon: p.bad ? 'sf:exclamationmark.triangle.fill' : 'sf:cube.fill' })), { limit: 12 })
            ];
            """#),
            docs: "https://kubernetes.io/docs/reference/kubectl/",
            requires: "kubectl with a configured context",
            sample: #"{"apiVersion":"v1","items":[{"metadata":{"name":"api-7d9f8-abcde","namespace":"default"},"status":{"phase":"Running","startTime":"2026-11-24T08:00:00Z","containerStatuses":[{"name":"api","ready":true,"restartCount":0,"state":{"running":{}}}]}},{"metadata":{"name":"worker-5c6b7-fghij","namespace":"default"},"status":{"phase":"Running","startTime":"2026-11-25T09:00:00Z","containerStatuses":[{"name":"worker","ready":false,"restartCount":14,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}},{"metadata":{"name":"migrate-xyz","namespace":"default"},"status":{"phase":"Succeeded","startTime":"2026-11-20T09:00:00Z","containerStatuses":[{"name":"m","ready":false,"restartCount":0,"state":{"terminated":{"reason":"Completed"}}}]}}],"kind":"List"}"#),
    ]
}
