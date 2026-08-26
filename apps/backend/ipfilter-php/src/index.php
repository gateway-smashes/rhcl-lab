<?php
declare(strict_types=1);

function header_value(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    return trim((string)($_SERVER[$key] ?? ''));
}

function split_xff(string $xff): array
{
    if ($xff === '') {
        return [];
    }

    return array_values(array_filter(array_map(static fn($item) => trim($item), explode(',', $xff))));
}

function request_snapshot(): array
{
    $xff = header_value('x-forwarded-for');
    $xffChain = split_xff($xff);

    return [
        'timestamp' => gmdate('c'),
        'method' => $_SERVER['REQUEST_METHOD'] ?? 'GET',
        'remoteAddr' => $_SERVER['REMOTE_ADDR'] ?? '',
        'realIpFromXff' => $xffChain[0] ?? '',
        'xForwardedFor' => $xff,
        'xForwardedForChain' => $xffChain,
        'xRealIp' => header_value('x-real-ip'),
        'forwarded' => header_value('forwarded'),
        'userAgent' => header_value('user-agent'),
        'host' => $_SERVER['HTTP_HOST'] ?? '',
    ];
}

function send_json(array $payload, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
}

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

if ($path === '/healthz') {
    send_json(['status' => 'ok']);
    return;
}

if ($path === '/api/ip') {
    send_json(request_snapshot());
    return;
}

$snapshot = request_snapshot();
$snapshotJson = json_encode($snapshot, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
$snapshotScriptJson = json_encode($snapshot, JSON_UNESCAPED_SLASHES | JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_AMP | JSON_HEX_QUOT);
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>RHCL IP Filter Probe</title>
  <style>
    :root {
      --bg: #f5f6f7;
      --panel: #ffffff;
      --ink: #151515;
      --muted: #5f6a72;
      --line: #d2d7dc;
      --red: #ee0000;
      --blue: #0066cc;
      --green: #3e8635;
      --orange: #f0ab00;
      --shadow: 0 12px 30px rgba(21, 21, 21, .08);
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Red Hat Text", "Inter", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        linear-gradient(180deg, rgba(238, 0, 0, .08), rgba(0, 102, 204, .05) 38%, transparent 70%),
        var(--bg);
    }

    header {
      background: #151515;
      color: #fff;
      border-bottom: 4px solid var(--red);
    }

    .wrap {
      width: min(1120px, calc(100% - 32px));
      margin: 0 auto;
    }

    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      min-height: 72px;
      gap: 24px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 14px;
      min-width: 0;
    }

    .mark {
      display: grid;
      place-items: center;
      width: 42px;
      height: 42px;
      border-radius: 6px;
      background: var(--red);
      font-weight: 800;
      letter-spacing: 0;
    }

    h1 {
      margin: 0;
      font-size: clamp(1.35rem, 2.5vw, 2rem);
      line-height: 1.15;
      letter-spacing: 0;
    }

    .host {
      color: #c7cdd1;
      font-size: .92rem;
      white-space: nowrap;
    }

    main {
      padding: 32px 0 44px;
    }

    .summary {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 16px;
      margin-bottom: 20px;
    }

    .metric,
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
    }

    .metric {
      padding: 18px;
      min-width: 0;
    }

    .label {
      color: var(--muted);
      font-size: .78rem;
      font-weight: 700;
      letter-spacing: .04em;
      text-transform: uppercase;
    }

    .value {
      margin-top: 8px;
      font-family: "Red Hat Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: clamp(1rem, 1.8vw, 1.35rem);
      line-height: 1.3;
      overflow-wrap: anywhere;
    }

    .grid {
      display: grid;
      grid-template-columns: minmax(0, .95fr) minmax(0, 1.05fr);
      gap: 20px;
      align-items: start;
    }

    .panel {
      overflow: hidden;
    }

    .panel h2 {
      margin: 0;
      padding: 16px 18px;
      border-bottom: 1px solid var(--line);
      font-size: 1rem;
      letter-spacing: 0;
      background: #fafafa;
    }

    .panel-body {
      padding: 18px;
    }

    dl {
      display: grid;
      grid-template-columns: 150px minmax(0, 1fr);
      gap: 12px 16px;
      margin: 0;
    }

    dt {
      color: var(--muted);
      font-weight: 700;
    }

    dd {
      margin: 0;
      font-family: "Red Hat Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      overflow-wrap: anywhere;
    }

    .controls {
      display: grid;
      gap: 12px;
    }

    .row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
    }

    input {
      width: 100%;
      min-height: 42px;
      padding: 0 12px;
      border: 1px solid #8a8f93;
      border-radius: 4px;
      font: inherit;
    }

    button {
      min-height: 42px;
      padding: 0 16px;
      border: 0;
      border-radius: 4px;
      background: var(--blue);
      color: #fff;
      font-weight: 700;
      cursor: pointer;
    }

    button.secondary {
      background: #4d5258;
    }

    button.danger {
      background: var(--red);
    }

    .quick {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }

    pre {
      min-height: 220px;
      margin: 0;
      padding: 14px;
      overflow: auto;
      border: 1px solid #30363d;
      border-radius: 6px;
      background: #0f1720;
      color: #d7e4ec;
      font-family: "Red Hat Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .86rem;
      line-height: 1.5;
    }

    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 12px;
      color: var(--muted);
      font-size: .92rem;
    }

    .dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: var(--green);
    }

    .dot.blocked {
      background: var(--orange);
    }

    @media (max-width: 780px) {
      .topbar,
      .grid,
      .summary {
        grid-template-columns: 1fr;
      }

      .topbar {
        display: grid;
        align-items: start;
        padding: 16px 0;
      }

      .host {
        white-space: normal;
      }

      dl,
      .row {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="wrap topbar">
      <div class="brand">
        <div class="mark">IP</div>
        <div>
          <h1>RHCL IP Filter Probe</h1>
          <div class="host"><?= htmlspecialchars($_SERVER['HTTP_HOST'] ?? 'unknown host', ENT_QUOTES, 'UTF-8') ?></div>
        </div>
      </div>
      <div class="host">Gateway source IP and X-Forwarded-For visibility</div>
    </div>
  </header>

  <main class="wrap">
    <section class="summary">
      <div class="metric">
        <div class="label">Peer seen by PHP</div>
        <div class="value" id="remoteAddr">-</div>
      </div>
      <div class="metric">
        <div class="label">Client IP from XFF</div>
        <div class="value" id="realIp">-</div>
      </div>
      <div class="metric">
        <div class="label">X-Forwarded-For chain</div>
        <div class="value" id="xff">-</div>
      </div>
    </section>

    <section class="grid">
      <div class="panel">
        <h2>Current Request</h2>
        <div class="panel-body">
          <dl>
            <dt>Method</dt>
            <dd id="method">-</dd>
            <dt>Host</dt>
            <dd id="host">-</dd>
            <dt>X-Real-IP</dt>
            <dd id="xRealIp">-</dd>
            <dt>Forwarded</dt>
            <dd id="forwarded">-</dd>
            <dt>User-Agent</dt>
            <dd id="userAgent">-</dd>
            <dt>Timestamp</dt>
            <dd id="timestamp">-</dd>
          </dl>
        </div>
      </div>

      <div class="panel">
        <h2>Header Probe</h2>
        <div class="panel-body">
          <div class="controls">
            <div class="row">
              <input id="spoofIp" value="203.0.113.7" aria-label="X-Forwarded-For value">
              <button id="sendSpoof" class="danger" type="button">Send XFF</button>
            </div>
            <div class="quick">
              <button class="secondary" type="button" data-ip="10.20.30.40">10.20.30.40</button>
              <button class="secondary" type="button" data-ip="192.168.10.25">192.168.10.25</button>
              <button class="secondary" type="button" data-ip="203.0.113.7">203.0.113.7</button>
              <button class="secondary" type="button" data-ip="">No custom XFF</button>
            </div>
            <div class="status"><span class="dot" id="statusDot"></span><span id="statusText">Ready</span></div>
            <pre id="result"><?= htmlspecialchars($snapshotJson ?: '{}', ENT_QUOTES, 'UTF-8') ?></pre>
          </div>
        </div>
      </div>
    </section>
  </main>

  <script>
    const initialSnapshot = <?= $snapshotScriptJson ?: '{}' ?>;
    const fields = {
      remoteAddr: document.querySelector('#remoteAddr'),
      realIp: document.querySelector('#realIp'),
      xff: document.querySelector('#xff'),
      method: document.querySelector('#method'),
      host: document.querySelector('#host'),
      xRealIp: document.querySelector('#xRealIp'),
      forwarded: document.querySelector('#forwarded'),
      userAgent: document.querySelector('#userAgent'),
      timestamp: document.querySelector('#timestamp'),
      result: document.querySelector('#result'),
      statusText: document.querySelector('#statusText'),
      statusDot: document.querySelector('#statusDot'),
      spoofIp: document.querySelector('#spoofIp'),
    };

    function text(value) {
      if (Array.isArray(value)) return value.length ? value.join(' -> ') : '-';
      return value ? String(value) : '-';
    }

    function render(snapshot) {
      fields.remoteAddr.textContent = text(snapshot.remoteAddr);
      fields.realIp.textContent = text(snapshot.realIpFromXff);
      fields.xff.textContent = text(snapshot.xForwardedForChain);
      fields.method.textContent = text(snapshot.method);
      fields.host.textContent = text(snapshot.host);
      fields.xRealIp.textContent = text(snapshot.xRealIp);
      fields.forwarded.textContent = text(snapshot.forwarded);
      fields.userAgent.textContent = text(snapshot.userAgent);
      fields.timestamp.textContent = text(snapshot.timestamp);
      fields.result.textContent = JSON.stringify(snapshot, null, 2);
    }

    async function probe(ip) {
      fields.statusText.textContent = 'Sending probe';
      fields.statusDot.classList.remove('blocked');

      const headers = {'accept': 'application/json'};
      if (ip) headers['x-forwarded-for'] = ip;

      try {
        const response = await fetch('/api/ip', {headers});
        const body = await response.text();
        fields.statusDot.classList.toggle('blocked', !response.ok);
        fields.statusText.textContent = response.ok ? `Allowed (${response.status})` : `Blocked (${response.status})`;

        try {
          const parsed = JSON.parse(body);
          render(parsed);
        } catch (_) {
          fields.result.textContent = body || `HTTP ${response.status}`;
        }
      } catch (error) {
        fields.statusDot.classList.add('blocked');
        fields.statusText.textContent = 'Request failed';
        fields.result.textContent = String(error);
      }
    }

    document.querySelector('#sendSpoof').addEventListener('click', () => probe(fields.spoofIp.value.trim()));
    document.querySelectorAll('[data-ip]').forEach((button) => {
      button.addEventListener('click', () => {
        fields.spoofIp.value = button.dataset.ip;
        probe(button.dataset.ip);
      });
    });

    render(initialSnapshot);
  </script>
</body>
</html>
