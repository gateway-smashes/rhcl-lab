// PoC console — opt-in technical panels to exercise the new banking-api
// validation endpoints (Phases A–G) directly from the demo app.
//
// All panels are independent and self-contained. The page derives the API
// base URL from the same backend URL the dashboard already uses.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'comprovantes_page.dart';

const String pocBearerStorageKey = 'redbank.bearerToken';
const String pocConsumerStorageKey = 'redbank.consumerId';
const String pocTraceLinkStorageKey = 'redbank.traceLinkTemplate';
const String pocMcpGatewayUrlStorageKey = 'redbank.mcpGatewayUrl';

/// Strip `/api/...` from a full URL to obtain the API root (e.g. `http://h:8080`).
String pocApiBase(String anyUrl) {
  try {
    final uri = Uri.parse(anyUrl);
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  } catch (_) {
    return anyUrl;
  }
}

/// Default "Trace UI URL template" derivado do host da própria página, para
/// funcionar em qualquer cluster de teste **sem rebuild**. O mobile-bank e o
/// gateway do Tempo dividem o mesmo wildcard `.apps.<cluster-domain>`, então
/// reaproveitamos esse sufixo. As constantes embutidas vêm dos manifests do repo
/// (tests/req038/manifests/02-tempostack.yaml): TempoStack `tempo-rhcl` → route
/// do gateway `tempo-tempo-rhcl-gateway` no namespace `tempo` (host
/// `tempo-tempo-rhcl-gateway-tempo.apps...`), tenant `dev`. Em `localhost` (dev)
/// não há `.apps.` → cai no placeholder. O campo continua editável, então o
/// usuário pode sobrescrever em qualquer caso.
String pocDefaultTraceLink() {
  const placeholder = 'https://tempo.example/trace/{traceId}';
  try {
    final host = html.window.location.host;
    final i = host.indexOf('.apps.');
    if (i < 0) return placeholder;
    final wildcard = host.substring(i); // .apps.<cluster-domain>
    return 'https://tempo-tempo-rhcl-gateway-tempo$wildcard'
        '/api/traces/v1/dev/trace/{traceId}';
  } catch (_) {
    return placeholder;
  }
}

String _readStorage(String key, {String fallback = ''}) {
  final v = html.window.localStorage[key];
  return (v == null || v.isEmpty) ? fallback : v;
}

void _writeStorage(String key, String value) {
  html.window.localStorage[key] = value;
}

Map<String, String> _commonHeaders({
  required String traceId,
  String? bearer,
  String? consumer,
  Map<String, String>? extra,
}) {
  final h = <String, String>{
    'x-flow-trace-id': traceId,
    'x-client-app': 'red-bank-mobile',
  };
  if (bearer != null && bearer.isNotEmpty) {
    h['authorization'] = 'Bearer $bearer';
  }
  if (consumer != null && consumer.isNotEmpty) {
    h['x-consumer-id'] = consumer;
  }
  if (extra != null) {
    h.addAll(extra);
  }
  return h;
}

String _newTraceId(String prefix) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final rand = Random().nextInt(99999).toString().padLeft(5, '0');
  return '$prefix-$now-$rand';
}

class PocConsolePage extends StatefulWidget {
  const PocConsolePage({
    super.key,
    required this.apiBase,
    required this.mcpGatewayUrl,
    this.rhclApiKey = '',
  });

  final String apiBase;
  final String mcpGatewayUrl;
  // RHCL gateway API key forwarded from the dashboard settings — used
  // by the Comprovantes tab so the upload demo can hit the gateway
  // with the same credential the user already configured.
  final String rhclApiKey;

  @override
  State<PocConsolePage> createState() => _PocConsolePageState();
}

class _PocConsolePageState extends State<PocConsolePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late String _bearer;
  late String _consumer;
  late String _traceLink;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 13, vsync: this);
    _bearer = _readStorage(pocBearerStorageKey);
    _consumer = _readStorage(
      pocConsumerStorageKey,
      fallback: 'red-bank-mobile',
    );
    _traceLink = _readStorage(
      pocTraceLinkStorageKey,
      fallback: pocDefaultTraceLink(),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _setBearer(String v) {
    setState(() => _bearer = v);
    _writeStorage(pocBearerStorageKey, v);
  }

  void _setConsumer(String v) {
    setState(() => _consumer = v);
    _writeStorage(pocConsumerStorageKey, v);
  }

  void _setTraceLink(String v) {
    setState(() => _traceLink = v);
    _writeStorage(pocTraceLinkStorageKey, v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PoC Console'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.bolt), text: 'Chaos'),
            Tab(icon: Icon(Icons.swap_vert), text: 'Streaming'),
            Tab(icon: Icon(Icons.smart_toy), text: 'AI'),
            Tab(icon: Icon(Icons.verified_user), text: 'Auth'),
            Tab(icon: Icon(Icons.insights), text: 'Observability'),
            Tab(icon: Icon(Icons.cable), text: 'WebSocket'),
            Tab(icon: Icon(Icons.dns), text: 'gRPC-Web'),
            Tab(icon: Icon(Icons.hub), text: 'MCP Integration'),
            Tab(icon: Icon(Icons.layers), text: 'HTTP Versions'),
            Tab(icon: Icon(Icons.call_split), text: 'Load Balancing'),
            Tab(icon: Icon(Icons.speed), text: 'Rate Limiting'),
            Tab(icon: Icon(Icons.account_tree), text: 'Trace Propagation'),
            Tab(icon: Icon(Icons.receipt_long), text: 'Comprovantes'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          ChaosPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
          ),
          StreamingPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
          ),
          AiPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
            onConsumerChanged: _setConsumer,
          ),
          AuthPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
            onBearerChanged: _setBearer,
            onConsumerChanged: _setConsumer,
          ),
          ObservabilityPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
            traceLink: _traceLink,
            onTraceLinkChanged: _setTraceLink,
          ),
          WebSocketPanel(apiBase: widget.apiBase),
          GrpcWebPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
          ),
          McpIntegrationPanel(
            defaultGatewayUrl: widget.mcpGatewayUrl,
            bearer: _bearer,
            consumer: _consumer,
          ),
          HttpVersionsPanel(apiBase: widget.apiBase),
          LoadBalancingPanel(apiBase: widget.apiBase),
          RateLimitingPanel(apiBase: widget.apiBase),
          TracePropagationPanel(
            apiBase: widget.apiBase,
            bearer: _bearer,
            consumer: _consumer,
            traceLink: _traceLink,
            onTraceLinkChanged: _setTraceLink,
          ),
          // req026 — "Comprovantes" demo. Reuses the dashboard-managed
          // RHCL API key (widget.rhclApiKey) so the upload exercises
          // the same gateway path the rest of the app does.
          ComprovantesPage(
            gatewayUrl: widget.apiBase,
            apiKey: widget.rhclApiKey,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Shared widgets
// -----------------------------------------------------------------------------

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _MonoBox extends StatelessWidget {
  const _MonoBox({required this.text, this.maxHeight = 240});
  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? Colors.black54 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

String _prettyJson(String body) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
  } catch (_) {
    return body;
  }
}

String _prettyJsonValue(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

// -----------------------------------------------------------------------------
// Phase A — Chaos panel
// -----------------------------------------------------------------------------

class ChaosPanel extends StatefulWidget {
  const ChaosPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
  });

  final String apiBase;
  final String bearer;
  final String consumer;

  @override
  State<ChaosPanel> createState() => _ChaosPanelState();
}

class _ChaosPanelState extends State<ChaosPanel> {
  final _client = http.Client();
  String _mode = '?';
  double _failRate = 0;
  String _ready = 'unknown';
  String _output = 'No call yet.';
  Timer? _readyPoller;

  // burst test
  int _burstCount = 20;
  bool _bursting = false;
  int _burst2xx = 0;
  int _burst5xx = 0;
  int _burstOther = 0;

  // echo-error
  int _eeStatus = 503;
  int _eeDelay = 1500;
  int _eeSize = 256;

  @override
  void initState() {
    super.initState();
    _refreshMode();
    _readyPoller = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollReady(),
    );
  }

  @override
  void dispose() {
    _readyPoller?.cancel();
    _client.close();
    super.dispose();
  }

  Future<void> _refreshMode() async {
    try {
      final r = await _client.get(Uri.parse('${widget.apiBase}/api/test/mode'));
      if (r.statusCode == 200) {
        final p = jsonDecode(r.body) as Map<String, dynamic>;
        setState(() {
          _mode = p['mode']?.toString() ?? '?';
          _failRate = (p['failRate'] as num?)?.toDouble() ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _pollReady() async {
    try {
      final r = await _client
          .get(Uri.parse('${widget.apiBase}/q/health/ready'))
          .timeout(const Duration(seconds: 2));
      setState(() {
        _ready = r.statusCode == 200 ? 'UP' : 'DOWN (${r.statusCode})';
      });
    } catch (_) {
      setState(() => _ready = 'unreachable');
    }
  }

  Future<void> _setMode(String mode, {double? failRate}) async {
    final body = <String, dynamic>{'mode': mode};
    if (failRate != null) body['failRate'] = failRate;
    final r = await _client.post(
      Uri.parse('${widget.apiBase}/api/test/mode'),
      headers: _commonHeaders(
        traceId: _newTraceId('chaos'),
        bearer: widget.bearer,
        consumer: widget.consumer,
        extra: {'content-type': 'application/json'},
      ),
      body: jsonEncode(body),
    );
    setState(
      () => _output =
          'POST /api/test/mode → ${r.statusCode}\n${_prettyJson(r.body)}',
    );
    await _refreshMode();
    await _pollReady();
  }

  Future<void> _callEchoError() async {
    final url =
        '${widget.apiBase}/api/test/echo-error?status=$_eeStatus&delay=$_eeDelay&size=$_eeSize';
    final t0 = DateTime.now();
    try {
      final r = await _client.get(
        Uri.parse(url),
        headers: _commonHeaders(
          traceId: _newTraceId('echoerr'),
          bearer: widget.bearer,
          consumer: widget.consumer,
        ),
      );
      final dt = DateTime.now().difference(t0).inMilliseconds;
      setState(() {
        _output =
            'GET $url\n→ HTTP ${r.statusCode} in ${dt}ms (body ${r.bodyBytes.length}B)';
      });
    } catch (e) {
      setState(() => _output = 'Failed: $e');
    }
  }

  Future<void> _runBurst() async {
    setState(() {
      _bursting = true;
      _burst2xx = 0;
      _burst5xx = 0;
      _burstOther = 0;
    });
    final url = '${widget.apiBase}/api/test/flaky?failRate=$_failRate';
    final futures = List.generate(_burstCount, (_) async {
      try {
        final r = await _client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 5));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          _burst2xx++;
        } else if (r.statusCode >= 500) {
          _burst5xx++;
        } else {
          _burstOther++;
        }
      } catch (_) {
        _burstOther++;
      }
    });
    await Future.wait(futures);
    setState(() {
      _bursting = false;
      _output =
          'Burst $_burstCount → 2xx=$_burst2xx  5xx=$_burst5xx  other=$_burstOther';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Backend mode',
          trailing: _ReadyDot(state: _ready),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Current: mode=$_mode  failRate=${_failRate.toStringAsFixed(2)}',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: () => _setMode('healthy', failRate: 0),
                    child: const Text('Healthy'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                    ),
                    onPressed: () => _setMode('degraded'),
                    child: const Text('Degraded'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    onPressed: () => _setMode('down'),
                    child: const Text('Down'),
                  ),
                  OutlinedButton(
                    onPressed: _refreshMode,
                    child: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Fail rate'),
                  Expanded(
                    child: Slider(
                      value: _failRate.clamp(0, 1),
                      onChanged: (v) => setState(() => _failRate = v),
                      onChangeEnd: (v) => _setMode(
                        _mode == '?' ? 'healthy' : _mode,
                        failRate: v,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(_failRate.toStringAsFixed(2)),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Burst test (/api/test/flaky)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Requests'),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 80,
                    child: TextFormField(
                      initialValue: _burstCount.toString(),
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          _burstCount = int.tryParse(v) ?? _burstCount,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _bursting ? null : _runBurst,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_bursting ? 'Running…' : 'Run burst'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _Chip(label: '2xx', value: _burst2xx, color: Colors.green),
                  const SizedBox(width: 8),
                  _Chip(label: '5xx', value: _burst5xx, color: Colors.red),
                  const SizedBox(width: 8),
                  _Chip(label: 'other', value: _burstOther, color: Colors.grey),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Echo error (/api/test/echo-error)',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _eeStatus.toString(),
                      decoration: const InputDecoration(labelText: 'Status'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          _eeStatus = int.tryParse(v) ?? _eeStatus,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _eeDelay.toString(),
                      decoration: const InputDecoration(
                        labelText: 'Delay (ms)',
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _eeDelay = int.tryParse(v) ?? _eeDelay,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _eeSize.toString(),
                      decoration: const InputDecoration(labelText: 'Size (B)'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => _eeSize = int.tryParse(v) ?? _eeSize,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  onPressed: _callEchoError,
                  icon: const Icon(Icons.send),
                  label: const Text('Call'),
                ),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Output',
          child: _MonoBox(text: _output),
        ),
      ],
    );
  }
}

class _ReadyDot extends StatelessWidget {
  const _ReadyDot({required this.state});
  final String state;
  @override
  Widget build(BuildContext context) {
    Color c;
    if (state == 'UP') {
      c = Colors.green;
    } else if (state.startsWith('DOWN')) {
      c = Colors.red;
    } else {
      c = Colors.grey;
    }
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text('ready: $state', style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// REQ 038 — Trace propagation panel (gateway → banking-api → ledger-api).
// Gera carga em /api/test/propagate; o banking-api chama o microserviço
// ledger-api downstream e o agente OpenTelemetry injetado propaga o
// `traceparent` W3C, encadeando os spans sob um único Trace ID.
// -----------------------------------------------------------------------------

const String _tracePropApiKeyStorageKey = 'redbank.tracePropApiKey';

class TracePropagationPanel extends StatefulWidget {
  const TracePropagationPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
    required this.traceLink,
    required this.onTraceLinkChanged,
  });

  final String apiBase;
  final String bearer;
  final String consumer;
  final String traceLink;
  final ValueChanged<String> onTraceLinkChanged;

  @override
  State<TracePropagationPanel> createState() => _TracePropagationPanelState();
}

class _TracePropagationPanelState extends State<TracePropagationPanel> {
  // Chave de API gold (demo) usada pela rota banking-api-connectivity, protegida
  // pela AuthPolicy de API key (Authorino, header `api-key`). Campo editável,
  // pré-preenchido com a chave gold do repo e persistido em localStorage; limpar
  // o campo omite o header e reproduz o 401 sob demanda.
  late TextEditingController _apiKeyCtl;

  final _client = http.Client();
  int _requests = 10;
  int _calls = 1;
  bool _running = false;
  int _ok = 0;
  int _fail = 0;
  String _lastTrace = '(none)';
  String _output = 'No call yet.';
  late TextEditingController _traceLinkCtl;

  @override
  void initState() {
    super.initState();
    _traceLinkCtl = TextEditingController(text: widget.traceLink);
    _apiKeyCtl = TextEditingController(
      text: _readStorage(
        _tracePropApiKeyStorageKey,
        fallback: 'alice-gold-secret',
      ),
    );
  }

  @override
  void dispose() {
    _traceLinkCtl.dispose();
    _apiKeyCtl.dispose();
    _client.close();
    super.dispose();
  }

  String _resolvedTraceUrl() {
    if (_lastTrace == '(none)' || _lastTrace.isEmpty) return '';
    return _traceLinkCtl.text.replaceAll('{traceId}', _lastTrace);
  }

  Future<void> _runLoad() async {
    setState(() {
      _running = true;
      _ok = 0;
      _fail = 0;
    });
    // Sempre via gateway RHCL — caminho que produz a cadeia completa
    // rhcl-gateway → banking-api → ledger-api sob um único Trace ID.
    final url =
        '${widget.apiBase}/api/test/propagate?target=gateway&calls=$_calls';
    // O header api-key só é enviado quando o campo não está vazio — limpá-lo
    // demonstra o 401 do gateway (Authorino) sob demanda.
    final apiKey = _apiKeyCtl.text.trim();
    final extra = apiKey.isEmpty ? <String, String>{} : {'api-key': apiKey};
    String lastBody = '';
    String lastTrace = _lastTrace;
    int lastStatus = 0;
    for (var i = 0; i < _requests; i++) {
      try {
        final r = await _client
            .get(
              Uri.parse(url),
              headers: _commonHeaders(
                traceId: _newTraceId('propagate'),
                bearer: widget.bearer,
                consumer: widget.consumer,
                extra: extra,
              ),
            )
            .timeout(const Duration(seconds: 15));
        lastStatus = r.statusCode;
        lastBody = r.body;
        if (r.statusCode >= 200 && r.statusCode < 300) {
          _ok++;
        } else {
          _fail++;
        }
        try {
          final p = jsonDecode(r.body) as Map<String, dynamic>;
          final tid = p['traceId']?.toString();
          if (tid != null && tid.isNotEmpty) lastTrace = tid;
        } catch (_) {}
      } catch (_) {
        _fail++;
      }
    }
    setState(() {
      _running = false;
      _lastTrace = lastTrace;
      _output =
          'GET $url\n'
          'requests=$_requests  ok=$_ok  fail=$_fail  (last HTTP $lastStatus)\n'
          'traceId=$_lastTrace\n\n${_prettyJson(lastBody)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Propagação de traces (gateway → banking-api → ledger-api)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Gera carga em /api/test/propagate via gateway RHCL (com api-key). '
                'O banking-api chama o microserviço ledger-api downstream; o agente '
                'OpenTelemetry injetado propaga o traceparent W3C, encadeando os spans '
                'rhcl-gateway → banking-api → ledger-api sob um único Trace ID. '
                'Visualize em Observe → Traces no console OpenShift.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyCtl,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  helperText:
                      'Chave gold do gateway (Authorino). Limpe o campo para reproduzir o 401.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    _writeStorage(_tracePropApiKeyStorageKey, v.trim()),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Requests'),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 72,
                        child: TextFormField(
                          initialValue: _requests.toString(),
                          keyboardType: TextInputType.number,
                          onChanged: (v) =>
                              _requests = int.tryParse(v) ?? _requests,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Downstream calls'),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 72,
                        child: TextFormField(
                          initialValue: _calls.toString(),
                          keyboardType: TextInputType.number,
                          onChanged: (v) => _calls = int.tryParse(v) ?? _calls,
                        ),
                      ),
                    ],
                  ),
                  ElevatedButton.icon(
                    onPressed: _running ? null : _runLoad,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_running ? 'Running…' : 'Run load'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Requests = chamadas ao gateway · Downstream calls = chamadas '
                'banking-api → ledger-api por request (1..20). '
                'Spans de ledger ≈ Requests × Downstream calls; cada request = 1 trace.',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _Chip(label: 'ok', value: _ok, color: Colors.green),
                  const SizedBox(width: 8),
                  _Chip(label: 'fail', value: _fail, color: Colors.red),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Trace gerado',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      'Last trace: $_lastTrace',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy',
                    onPressed: _lastTrace == '(none)'
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: _lastTrace),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _traceLinkCtl,
                decoration: const InputDecoration(
                  labelText: 'Trace UI URL template ({traceId} placeholder)',
                  border: OutlineInputBorder(),
                ),
                onChanged: widget.onTraceLinkChanged,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _lastTrace == '(none)'
                      ? null
                      : () => html.window.open(_resolvedTraceUrl(), '_blank'),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in trace UI'),
                ),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Output',
          child: _MonoBox(text: _output),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Phase B — Streaming panel
// -----------------------------------------------------------------------------

class StreamingPanel extends StatefulWidget {
  const StreamingPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
  });
  final String apiBase;
  final String bearer;
  final String consumer;

  @override
  State<StreamingPanel> createState() => _StreamingPanelState();
}

class _StreamingPanelState extends State<StreamingPanel> {
  String _output = 'No transfer yet.';
  double _uploadProgress = 0;
  double _downloadProgress = 0;
  int _downloadSize = 1024 * 1024; // 1 MiB
  int _downloadChunk = 64 * 1024;
  bool _busy = false;

  Future<void> _pickAndUpload() async {
    final input = html.FileUploadInputElement()..accept = '*/*';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null) return;
    setState(() {
      _busy = true;
      _uploadProgress = 0;
      _output = 'Uploading ${file.name} (${file.size}B)…';
    });
    final t0 = DateTime.now();
    final req = html.HttpRequest();
    req.open('POST', '${widget.apiBase}/api/files/upload');
    req.setRequestHeader(
      'content-type',
      file.type.isEmpty ? 'application/octet-stream' : file.type,
    );
    req.setRequestHeader('x-flow-trace-id', _newTraceId('upload'));
    req.setRequestHeader('x-client-app', 'red-bank-mobile');
    if (widget.bearer.isNotEmpty) {
      req.setRequestHeader('authorization', 'Bearer ${widget.bearer}');
    }
    if (widget.consumer.isNotEmpty) {
      req.setRequestHeader('x-consumer-id', widget.consumer);
    }
    req.upload.onProgress.listen((e) {
      if (e.lengthComputable) {
        setState(() => _uploadProgress = e.loaded! / e.total!);
      }
    });
    final completer = Completer<void>();
    req.onLoadEnd.listen((_) => completer.complete());
    req.send(file);
    await completer.future;
    final dt = DateTime.now().difference(t0).inMilliseconds;
    setState(() {
      _busy = false;
      _output =
          'Upload finished in ${dt}ms\nHTTP ${req.status}\n${_prettyJson(req.responseText ?? '')}';
    });
  }

  Future<void> _runDownload() async {
    setState(() {
      _busy = true;
      _downloadProgress = 0;
      _output = 'Downloading…';
    });
    final url =
        '${widget.apiBase}/api/files/download?size=$_downloadSize&chunkSize=$_downloadChunk';
    final t0 = DateTime.now();
    final req = html.HttpRequest();
    req.open('GET', url);
    req.responseType = 'arraybuffer';
    req.setRequestHeader('x-flow-trace-id', _newTraceId('download'));
    if (widget.bearer.isNotEmpty) {
      req.setRequestHeader('authorization', 'Bearer ${widget.bearer}');
    }
    req.onProgress.listen((e) {
      if (e.lengthComputable) {
        setState(() => _downloadProgress = e.loaded! / e.total!);
      }
    });
    final completer = Completer<void>();
    req.onLoadEnd.listen((_) => completer.complete());
    req.send();
    await completer.future;
    final dt = DateTime.now().difference(t0).inMilliseconds;
    final bytes = (req.response as ByteBuffer?)?.lengthInBytes ?? 0;
    final mbps = dt > 0 ? (bytes / 1024 / 1024) / (dt / 1000) : 0;
    setState(() {
      _busy = false;
      _downloadProgress = 1;
      _output =
          'Download HTTP ${req.status} — ${bytes}B in ${dt}ms (${mbps.toStringAsFixed(2)} MB/s)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Upload (POST /api/files/upload)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ElevatedButton.icon(
                onPressed: _busy ? null : _pickAndUpload,
                icon: const Icon(Icons.upload_file),
                label: const Text('Pick file & upload'),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _uploadProgress),
              const SizedBox(height: 4),
              Text(
                '${(_uploadProgress * 100).toStringAsFixed(0)} %',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Download (GET /api/files/download)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _downloadSize.toString(),
                      decoration: const InputDecoration(labelText: 'size (B)'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          _downloadSize = int.tryParse(v) ?? _downloadSize,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _downloadChunk.toString(),
                      decoration: const InputDecoration(labelText: 'chunk (B)'),
                      keyboardType: TextInputType.number,
                      onChanged: (v) =>
                          _downloadChunk = int.tryParse(v) ?? _downloadChunk,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _runDownload,
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _downloadProgress),
              const SizedBox(height: 4),
              Text(
                '${(_downloadProgress * 100).toStringAsFixed(0)} %',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Output',
          child: _MonoBox(text: _output),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Phase C — AI panel
// -----------------------------------------------------------------------------

enum _AiHttpMethod { get, post }

/// Request body shape sent by the frontend for each POST endpoint type.
enum _AiPayloadType {
  /// {"model":…,"messages":[…]} — chat/completions, chat/completions SSE
  chat,

  /// {"model":…,"prompt":"…"}  — legacy /completions
  prompt,

  /// {"model":…,"input":"…"}   — /embeddings
  embedding,

  /// {"model":…,"input":"…"}   — /responses
  response,
}

/// One OpenAI-compatible surface exposed by banking-api.
class _AiEndpointPreset {
  const _AiEndpointPreset({
    required this.id,
    required this.label,
    required this.method,
    required this.path,
    this.stream = false,
    this.payloadType = _AiPayloadType.chat,
    this.expectedObject,
  });

  final String id;
  final String label;
  final _AiHttpMethod method;
  final String path;
  final bool stream;

  /// Body shape to send on POST.
  final _AiPayloadType payloadType;

  /// Expected `object` field in the JSON response (null = skip check).
  final String? expectedObject;
}

/// Result row for single-call UI or the "test all" matrix.
class _AiEndpointResult {
  const _AiEndpointResult({
    required this.preset,
    required this.passed,
    this.status,
    this.durationMs,
    this.detail = '',
    this.error,
    this.preview = '',
    this.usageTotal,
    this.usagePrompt,
    this.usageCompletion,
  });

  final _AiEndpointPreset preset;
  final bool passed;
  final int? status;
  final int? durationMs;
  final String detail;
  final String? error;
  final String preview;
  final int? usageTotal;
  final int? usagePrompt;
  final int? usageCompletion;
}

/// OpenAI-compatible routes exposed by banking-api under /api/v1.
const List<_AiEndpointPreset> _aiEndpointPresets = [
  _AiEndpointPreset(
    id: 'get-models-api-v1',
    label: 'GET /api/v1/models',
    method: _AiHttpMethod.get,
    path: '/api/v1/models',
  ),
  _AiEndpointPreset(
    id: 'post-chat-completions-json',
    label: 'POST /api/v1/chat/completions (JSON)',
    method: _AiHttpMethod.post,
    path: '/api/v1/chat/completions',
    payloadType: _AiPayloadType.chat,
    expectedObject: 'chat.completion',
  ),
  _AiEndpointPreset(
    id: 'post-chat-completions-sse',
    label: 'POST /api/v1/chat/completions (SSE)',
    method: _AiHttpMethod.post,
    path: '/api/v1/chat/completions',
    stream: true,
    payloadType: _AiPayloadType.chat,
  ),
  _AiEndpointPreset(
    id: 'post-completions',
    label: 'POST /api/v1/completions',
    method: _AiHttpMethod.post,
    path: '/api/v1/completions',
    payloadType: _AiPayloadType.prompt,
    expectedObject: 'text_completion',
  ),
  _AiEndpointPreset(
    id: 'post-embeddings',
    label: 'POST /api/v1/embeddings',
    method: _AiHttpMethod.post,
    path: '/api/v1/embeddings',
    payloadType: _AiPayloadType.embedding,
    expectedObject: 'list',
  ),
  _AiEndpointPreset(
    id: 'post-responses',
    label: 'POST /api/v1/responses',
    method: _AiHttpMethod.post,
    path: '/api/v1/responses',
    payloadType: _AiPayloadType.response,
    expectedObject: 'response',
  ),
];

class AiPanel extends StatefulWidget {
  const AiPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
    required this.onConsumerChanged,
  });
  final String apiBase;
  final String bearer;
  final String consumer;
  final ValueChanged<String> onConsumerChanged;

  @override
  State<AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<AiPanel> {
  static const _manualPresetId = 'manual';

  final _client = http.Client();
  final _prompt = TextEditingController(
    text: 'Show me my account balance for this month.',
  );
  final _endpointCtl = TextEditingController(
    text: '/api/v1/chat/completions',
  );
  late TextEditingController _consumerCtl;
  String _model = 'banking-mock-gpt';
  String _selectedPresetId = 'post-chat-completions-json';
  bool _manualStream = false;
  bool _mockUsage = true;
  int _mockPromptTokens = 75;
  int _mockCompletionTokens = 82;
  bool _busy = false;
  String _answer = '';
  String _meta = '';
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _totalTokens = 0;
  int _last429 = 0;
  int _ttftMs = 0;
  double _tokensPerSecond = 0;
  int _lastCallTokens = 0;
  List<_AiEndpointResult> _matrixResults = [];

  @override
  void initState() {
    super.initState();
    _consumerCtl = TextEditingController(text: widget.consumer);
  }

  @override
  void dispose() {
    _client.close();
    _prompt.dispose();
    _endpointCtl.dispose();
    _consumerCtl.dispose();
    super.dispose();
  }

  _AiEndpointPreset? _presetById(String id) {
    for (final p in _aiEndpointPresets) {
      if (p.id == id) return p;
    }
    return null;
  }

  _AiEndpointPreset _activePreset() {
    if (_selectedPresetId == _manualPresetId) {
      final path = _endpointCtl.text.trim();
      final isGet = path.contains('/models');
      return _AiEndpointPreset(
        id: _manualPresetId,
        label: 'Manual',
        method: isGet ? _AiHttpMethod.get : _AiHttpMethod.post,
        path: path,
        stream: !isGet && _manualStream,
      );
    }
    return _presetById(_selectedPresetId) ?? _aiEndpointPresets[1];
  }

  bool get _activeIsGet => _activePreset().method == _AiHttpMethod.get;

  Uri _uriForPreset(_AiEndpointPreset preset) {
    if (preset.id == _manualPresetId) {
      return _endpointUriFromText(_endpointCtl.text.trim());
    }
    return Uri.parse(
      '${widget.apiBase}${preset.path.startsWith('/') ? preset.path : '/${preset.path}'}',
    );
  }

  Uri _endpointUriFromText(String trimmed) {
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return Uri.parse(trimmed);
    }
    final path = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return Uri.parse('${widget.apiBase}$path');
  }

  void _selectPreset(String id) {
    final preset = _presetById(id);
    setState(() {
      _selectedPresetId = id;
      if (preset != null) {
        _endpointCtl.text = preset.path;
      }
    });
  }

  Map<String, dynamic> _chatPayload(List<Map<String, String>> ctx) {
    return {
      'model': _model,
      if (_mockUsage)
        'mock_usage': {
          'prompt_tokens': _mockPromptTokens,
          'completion_tokens': _mockCompletionTokens,
        },
      if (ctx.isNotEmpty) 'context': ctx,
      'messages': [
        {'role': 'user', 'content': _prompt.text},
      ],
    };
  }

  /// Builds the request body appropriate for each endpoint type.
  Map<String, dynamic> _buildPayload(_AiEndpointPreset preset) {
    final text = _prompt.text;
    switch (preset.payloadType) {
      case _AiPayloadType.prompt:
        return {'model': _model, 'prompt': text, 'max_tokens': 256};
      case _AiPayloadType.embedding:
        return {'model': 'text-embedding-mock', 'input': text};
      case _AiPayloadType.response:
        return {'model': _model, 'input': text};
      case _AiPayloadType.chat:
        return _chatPayload(const []);
    }
  }

  /// Validates the JSON response body against the preset's expected shape.
  bool _validateBody(_AiEndpointPreset preset, String body) {
    try {
      final p = jsonDecode(body) as Map<String, dynamic>;
      final obj = p['object']?.toString();
      if (preset.expectedObject != null && obj != preset.expectedObject) {
        return false;
      }
      // Extra shape checks per type.
      switch (preset.payloadType) {
        case _AiPayloadType.chat:
          final choices = p['choices'] as List?;
          if (choices == null || choices.isEmpty) return false;
          final msg = (choices.first as Map)['message'];
          return msg is Map && (msg['content']?.toString() ?? '').isNotEmpty;
        case _AiPayloadType.prompt:
          final choices = p['choices'] as List?;
          return choices != null && choices.isNotEmpty;
        case _AiPayloadType.embedding:
          final data = p['data'] as List?;
          return data != null && data.isNotEmpty;
        case _AiPayloadType.response:
          final output = p['output'] as List?;
          return output != null && output.isNotEmpty;
      }
    } catch (_) {
      return false;
    }
  }

  String _truncate(String value, int max) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…';
  }

  bool _validateModelsBody(String body) {
    try {
      final p = jsonDecode(body) as Map<String, dynamic>;
      if (p['object'] != 'list') return false;
      final data = p['data'] as List?;
      return data != null && data.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _validateCompletionsSseBody(String body) {
    return body.contains('[DONE]') || body.contains('chat.completion.chunk');
  }

  Future<_AiEndpointResult> _invokePreset(
    _AiEndpointPreset preset, {
    bool quick = false,
  }) async {
    final uri = _uriForPreset(preset);
    final t0 = DateTime.now();
    try {
      if (preset.method == _AiHttpMethod.get) {
        final r = await _client.get(
          uri,
          headers: _commonHeaders(
            traceId: _newTraceId('ai-models'),
            bearer: widget.bearer,
            consumer: _consumerCtl.text,
            extra: const {'accept': 'application/json'},
          ),
        );
        final dt = DateTime.now().difference(t0).inMilliseconds;
        final ok = r.statusCode == 200 && _validateModelsBody(r.body);
        String modelId = '';
        if (ok) {
          final data =
              (jsonDecode(r.body) as Map<String, dynamic>)['data'] as List?;
          if (data != null && data.isNotEmpty) {
            modelId = (data.first as Map)['id']?.toString() ?? '';
          }
        }
        return _AiEndpointResult(
          preset: preset,
          passed: ok,
          status: r.statusCode,
          durationMs: dt,
          detail: ok ? 'model=$modelId' : 'unexpected models payload',
          preview: quick
              ? _truncate(r.body, 120)
              : () {
                  try {
                    return const JsonEncoder.withIndent('  ').convert(
                      jsonDecode(r.body),
                    );
                  } catch (_) {
                    return r.body;
                  }
                }(),
        );
      }

      if (preset.stream) {
        if (quick) {
          final r = await _client.post(
            uri,
            headers: _commonHeaders(
              traceId: _newTraceId('ai-sse-quick'),
              bearer: widget.bearer,
              consumer: _consumerCtl.text,
              extra: {
                'content-type': 'application/json',
                'accept': 'text/event-stream',
              },
            ),
            body: jsonEncode({
              ..._chatPayload(const []),
              'stream': true,
            }),
          );
          final dt = DateTime.now().difference(t0).inMilliseconds;
          if (r.statusCode == 429) _last429++;
          final ok = r.statusCode == 200 && _validateCompletionsSseBody(r.body);
          return _AiEndpointResult(
            preset: preset,
            passed: ok,
            status: r.statusCode,
            durationMs: dt,
            detail: ok ? 'SSE chunks ok' : 'missing [DONE] or chunk',
            preview: _truncate(r.body, 120),
          );
        }
        return _invokePresetStream(preset, uri, t0);
      }

      final r = await _client.post(
        uri,
        headers: _commonHeaders(
          traceId: _newTraceId('ai'),
          bearer: widget.bearer,
          consumer: _consumerCtl.text,
          extra: {
            'content-type': 'application/json',
            'accept': 'application/json',
          },
        ),
        body: jsonEncode(_buildPayload(preset)),
      );
      final dt = DateTime.now().difference(t0).inMilliseconds;
      if (r.statusCode == 429) _last429++;
      final ok = r.statusCode == 200 && _validateBody(preset, r.body);
      var preview = _truncate(r.body, 120);
      int? uTotal;
      int? uPrompt;
      int? uCompletion;
      if (!quick && r.statusCode == 200) {
        try {
          final p = jsonDecode(r.body) as Map<String, dynamic>;
          // Extract human-readable preview text per endpoint type.
          if (preset.payloadType == _AiPayloadType.chat) {
            final choices = p['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final message = (choices.first as Map)['message'];
              if (message is Map) {
                preview = message['content']?.toString() ?? r.body;
              }
            }
          } else if (preset.payloadType == _AiPayloadType.prompt) {
            final choices = p['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              preview = (choices.first as Map)['text']?.toString() ?? r.body;
            }
          } else if (preset.payloadType == _AiPayloadType.response) {
            final output = p['output'] as List?;
            if (output != null && output.isNotEmpty) {
              final content = (output.first as Map)['content'] as List?;
              if (content != null && content.isNotEmpty) {
                preview = (content.first as Map)['text']?.toString() ?? r.body;
              }
            }
          } else {
            // embeddings: just pretty print
            preview = const JsonEncoder.withIndent('  ').convert(p);
          }
          final usage = p['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            uPrompt =
                ((usage['prompt_tokens'] ?? usage['input_tokens']) as num?)
                    ?.toInt();
            uCompletion =
                ((usage['completion_tokens'] ?? usage['output_tokens']) as num?)
                    ?.toInt();
            uTotal = (usage['total_tokens'] as num?)?.toInt() ??
                ((uPrompt ?? 0) + (uCompletion ?? 0));
          }
        } catch (_) {
          preview = r.body;
        }
      }
      return _AiEndpointResult(
        preset: preset,
        passed: ok,
        status: r.statusCode,
        durationMs: dt,
        detail: ok
            ? '${preset.expectedObject ?? 'ok'}'
            : 'invalid response (expected ${preset.expectedObject ?? 'success'})',
        preview: preview,
        usageTotal: uTotal,
        usagePrompt: uPrompt,
        usageCompletion: uCompletion,
      );
    } catch (e) {
      return _AiEndpointResult(
        preset: preset,
        passed: false,
        error: e.toString(),
        detail: 'request failed',
      );
    }
  }

  Future<_AiEndpointResult> _invokePresetStream(
    _AiEndpointPreset preset,
    Uri uri,
    DateTime t0,
  ) async {
    final req = html.HttpRequest();
    req.open('POST', uri.toString());
    req.setRequestHeader('content-type', 'application/json');
    req.setRequestHeader('accept', 'text/event-stream');
    req.setRequestHeader('x-flow-trace-id', _newTraceId('ai-sse'));
    req.setRequestHeader('x-client-app', 'red-bank-mobile');
    if (widget.bearer.isNotEmpty) {
      req.setRequestHeader('authorization', 'Bearer ${widget.bearer}');
    }
    if (_consumerCtl.text.isNotEmpty) {
      req.setRequestHeader('x-consumer-id', _consumerCtl.text);
    }

    var lastLen = 0;
    var streamedTokens = 0;
    DateTime? firstTokenAt;
    final answerBuf = StringBuffer();
    int? lastUsageTotal;

    req.onProgress.listen((_) {
      final txt = req.responseText ?? '';
      if (txt.length <= lastLen) return;
      final newPart = txt.substring(lastLen);
      lastLen = txt.length;
      for (final line in newPart.split('\n')) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]' || payload.isEmpty) continue;
        try {
          final j = jsonDecode(payload) as Map<String, dynamic>;
          final choices = j['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'];
          final content = (delta is Map ? delta['content'] : null)?.toString();
          if (content != null && content.isNotEmpty) {
            firstTokenAt ??= DateTime.now();
            streamedTokens += (content.length / 4).ceil();
            answerBuf.write(content);
          }
          final usage = j['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            lastUsageTotal = (usage['total_tokens'] as num?)?.toInt();
          }
        } catch (_) {}
      }
    });

    final completer = Completer<void>();
    req.onLoadEnd.listen((_) => completer.complete());
    req.send(
      jsonEncode({
        ..._chatPayload(const []),
        'stream': true,
      }),
    );
    await completer.future;

    final totalDt = DateTime.now().difference(t0).inMilliseconds;
    if (req.status == 429) _last429++;
    final body = req.responseText ?? '';
    final ok = req.status == 200 && _validateCompletionsSseBody(body);
    final ttft = firstTokenAt?.difference(t0).inMilliseconds ?? totalDt;
    final tokens = lastUsageTotal ?? streamedTokens;

    return _AiEndpointResult(
      preset: preset,
      passed: ok,
      status: req.status,
      durationMs: totalDt,
      detail: ok ? 'ttft=${ttft}ms tokens≈$tokens' : 'SSE validation failed',
      preview: _truncate(
        answerBuf.isEmpty ? body : answerBuf.toString(),
        400,
      ),
      usageTotal: lastUsageTotal ?? streamedTokens,
    );
  }

  void _applyUsageFromResult(_AiEndpointResult result) {
    if (result.usagePrompt != null) {
      _promptTokens += result.usagePrompt!;
    }
    if (result.usageCompletion != null) {
      _completionTokens += result.usageCompletion!;
    }
    if (result.usageTotal != null) {
      _totalTokens += result.usageTotal!;
      _lastCallTokens = result.usageTotal!;
    }
    if (result.preset.stream && result.detail.startsWith('ttft=')) {
      final m = RegExp(r'ttft=(\d+)ms').firstMatch(result.detail);
      if (m != null) {
        _ttftMs = int.tryParse(m.group(1) ?? '') ?? _ttftMs;
      }
      if (result.durationMs != null &&
          result.durationMs! > _ttftMs &&
          result.usageTotal != null) {
        _tokensPerSecond =
            result.usageTotal! * 1000.0 / (result.durationMs! - _ttftMs);
      }
    } else if (result.durationMs != null &&
        result.durationMs! > 0 &&
        result.usageTotal != null) {
      _ttftMs = result.durationMs!;
      _tokensPerSecond = result.usageTotal! * 1000.0 / result.durationMs!;
    }
  }

  void _applySingleResult(_AiEndpointResult result) {
    _answer = result.preview.isNotEmpty
        ? result.preview
        : (result.error ?? result.detail);
    _meta = result.status != null
        ? 'HTTP ${result.status} • ${result.durationMs ?? '-'}ms • ${result.detail}'
        : result.detail;
  }

  Future<void> _sendSelected() async {
    final preset = _activePreset();
    setState(() {
      _busy = true;
      _answer = '';
      _meta = '';
      _ttftMs = 0;
      _tokensPerSecond = 0;
      _lastCallTokens = 0;
    });
    final result = await _invokePreset(preset);
    _applyUsageFromResult(result);
    setState(() {
      _busy = false;
      _applySingleResult(result);
      if (!result.passed && result.error != null) {
        _answer = result.error!;
      }
    });
  }

  Future<void> _runAllEndpoints() async {
    setState(() {
      _busy = true;
      _matrixResults = [];
      _answer =
          'Running all ${_aiEndpointPresets.length} OpenAI-compatible endpoints…';
      _meta = '';
    });
    final results = <_AiEndpointResult>[];
    for (final preset in _aiEndpointPresets) {
      final result = await _invokePreset(preset, quick: true);
      results.add(result);
      if (mounted) {
        setState(() => _matrixResults = List.from(results));
      }
    }
    final passed = results.where((r) => r.passed).length;
    setState(() {
      _busy = false;
      _matrixResults = results;
      _answer = passed == results.length
          ? 'All ${results.length} endpoints passed.'
          : '$passed/${results.length} endpoints passed — see matrix below.';
      _meta = 'Matrix run complete • apiBase=${widget.apiBase}';
    });
  }

  Future<void> _runTokenProbe() async {
    final preset = _presetById('post-chat-completions-json')!;
    setState(() {
      _busy = true;
      _answer = 'Running token policy probe (3×)…';
      _meta = '';
    });
    final lines = <String>[];
    for (var i = 1; i <= 3; i++) {
      final result = await _invokePreset(preset, quick: true);
      lines.add(
        '#$i ${preset.label} HTTP ${result.status ?? '-'} '
        '${result.durationMs ?? '-'}ms ${result.detail} '
        '${result.passed ? 'OK' : 'FAIL'}',
      );
    }
    setState(() {
      _busy = false;
      _answer = lines.join('\n');
      _meta = 'Token policy probe complete';
    });
  }

  Widget _matrixResultCard(BuildContext context, _AiEndpointResult r) {
    final theme = Theme.of(context);
    final icon = r.passed ? Icons.check_circle : Icons.cancel;
    final color = r.passed ? Colors.green.shade700 : Colors.red.shade700;
    final statusLabel =
        r.status?.toString() ?? (r.error != null ? 'error' : '—');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: r.passed ? Colors.green.shade400 : Colors.red.shade400,
        ),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.preset.label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              Text(
                r.passed ? 'PASS' : 'FAIL',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              _matrixBadge(context, 'HTTP $statusLabel'),
              if (r.durationMs != null)
                _matrixBadge(context, '${r.durationMs} ms'),
            ],
          ),
          if ((r.error ?? r.detail).isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              r.error ?? r.detail,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ],
        ],
      ),
    );
  }

  Widget _matrixBadge(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Identity & base URL',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'apiBase: ${widget.apiBase}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _consumerCtl,
                      decoration: const InputDecoration(
                        labelText: 'x-consumer-id',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: widget.onConsumerChanged,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _model,
                      decoration: const InputDecoration(
                        labelText: 'model',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => _model = v,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'OpenAI-compatible endpoint',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: InputDecoration(
                  labelText:
                      'Endpoint preset (${_aiEndpointPresets.length} + manual)',
                  border: const OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedPresetId == _manualPresetId ||
                            _presetById(_selectedPresetId) != null
                        ? _selectedPresetId
                        : 'post-chat-completions-json',
                    isExpanded: true,
                    items: [
                      ..._aiEndpointPresets.map(
                        (p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(
                            p.label,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: _manualPresetId,
                        child: Text('Manual (custom path or URL)'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      if (value == _manualPresetId) {
                        setState(() => _selectedPresetId = _manualPresetId);
                      } else {
                        _selectPreset(value);
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'All presets use /api/v1/… on HTTPRoute banking-api-connectivity '
                '(legacy /v1 and /api/ai paths are prefixed with /api/v1).',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _endpointCtl,
                readOnly: _selectedPresetId != _manualPresetId,
                decoration: InputDecoration(
                  labelText: _selectedPresetId == _manualPresetId
                      ? 'Manual path or full URL'
                      : 'Resolved URL',
                  border: const OutlineInputBorder(),
                  suffixIcon: _selectedPresetId != _manualPresetId
                      ? IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          tooltip: 'Switch to manual',
                          onPressed: () {
                            setState(() {
                              _selectedPresetId = _manualPresetId;
                            });
                          },
                        )
                      : null,
                ),
                onChanged: (_) {
                  if (_selectedPresetId != _manualPresetId) {
                    setState(() => _selectedPresetId = _manualPresetId);
                  }
                },
              ),
            ],
          ),
        ),
        _SectionCard(
          title: _activeIsGet ? 'Models request' : 'Prompt',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_activeIsGet)
                const Text(
                  'GET models — no prompt body. Press Send to list models from '
                  'the selected endpoint.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                )
              else
                TextField(
                  controller: _prompt,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Ask the mock LLM…',
                  ),
                ),
              const SizedBox(height: 8),
              if (!_activeIsGet)
                Row(
                  children: [
                    if (_selectedPresetId == _manualPresetId) ...[
                      Switch(
                        value: _manualStream,
                        onChanged: (v) => setState(() => _manualStream = v),
                      ),
                      const Text('SSE stream'),
                      const SizedBox(width: 12),
                    ],
                    Switch(
                      value: _mockUsage,
                      onChanged: (v) => setState(() => _mockUsage = v),
                    ),
                    const Text('Mock usage'),
                  ],
                ),
              if (!_activeIsGet && _mockUsage) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: _mockPromptTokens.toString(),
                        decoration: const InputDecoration(
                          labelText: 'prompt_tokens',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (v) => _mockPromptTokens =
                            int.tryParse(v) ?? _mockPromptTokens,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        initialValue: _mockCompletionTokens.toString(),
                        decoration: const InputDecoration(
                          labelText: 'completion_tokens',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (v) => _mockCompletionTokens =
                            int.tryParse(v) ?? _mockCompletionTokens,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _busy ? null : _sendSelected,
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Batch actions',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: _busy ? null : _runAllEndpoints,
                icon: const Icon(Icons.playlist_add_check),
                label: Text('Test all (${_aiEndpointPresets.length})'),
              ),
              if (!_activeIsGet && _mockUsage)
                ElevatedButton.icon(
                  onPressed: _busy ? null : _runTokenProbe,
                  icon: const Icon(Icons.speed),
                  label: const Text('Probe x3'),
                ),
            ],
          ),
        ),
        if (_matrixResults.isNotEmpty)
          _SectionCard(
            title:
                'Endpoint matrix (${_matrixResults.where((r) => r.passed).length}/${_matrixResults.length} passed)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final r in _matrixResults) _matrixResultCard(context, r),
              ],
            ),
          ),
        _SectionCard(
          title: 'Last response',
          trailing: Text(_meta, style: const TextStyle(fontSize: 11)),
          child:
              _MonoBox(text: _answer.isEmpty ? '(no response yet)' : _answer),
        ),
        if (!_activeIsGet)
          _SectionCard(
            title: 'Token usage (cumulative)',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(
                    label: 'prompt', value: _promptTokens, color: Colors.blue),
                _Chip(
                  label: 'completion',
                  value: _completionTokens,
                  color: Colors.purple,
                ),
                _Chip(label: 'total', value: _totalTokens, color: Colors.teal),
                _Chip(label: '429s', value: _last429, color: Colors.red),
              ],
            ),
          ),
        if (!_activeIsGet)
          _SectionCard(
            title: 'Last call performance',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(label: 'TTFT (ms)', value: _ttftMs, color: Colors.orange),
                _Chip(
                  label: 'tokens/s',
                  value: _tokensPerSecond.round(),
                  color: Colors.green,
                ),
                _Chip(
                  label: 'tokens',
                  value: _lastCallTokens,
                  color: Colors.indigo,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Phase G — Auth panel
// -----------------------------------------------------------------------------

class AuthPanel extends StatefulWidget {
  const AuthPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
    required this.onBearerChanged,
    required this.onConsumerChanged,
  });
  final String apiBase;
  final String bearer;
  final String consumer;
  final ValueChanged<String> onBearerChanged;
  final ValueChanged<String> onConsumerChanged;

  @override
  State<AuthPanel> createState() => _AuthPanelState();
}

class _AuthPanelState extends State<AuthPanel> {
  final _client = http.Client();
  late TextEditingController _bearerCtl;
  late TextEditingController _consumerCtl;
  String _output = 'No call yet.';
  Map<String, dynamic>? _payload;

  // Item 71 — OIDC login (Keycloak password grant). The gateway validates the
  // resulting JWT; this panel only obtains it and reads the claims for display.
  late TextEditingController _kcBaseCtl;
  late TextEditingController _realmCtl;
  late TextEditingController _clientIdCtl;
  late TextEditingController _clientSecretCtl;
  late TextEditingController _userCtl;
  late TextEditingController _passCtl;
  String _loginStatus = 'Não autenticado.';
  bool _loginOk = false;
  Map<String, dynamic>? _tokenClaims;

  @override
  void initState() {
    super.initState();
    _bearerCtl = TextEditingController(text: widget.bearer);
    _consumerCtl = TextEditingController(text: widget.consumer);
    _kcBaseCtl = TextEditingController(text: _defaultKcBase());
    _realmCtl = TextEditingController(text: 'rhcl');
    _clientIdCtl = TextEditingController(text: 'banking-api');
    _clientSecretCtl = TextEditingController(text: 'banking-api-secret');
    _userCtl = TextEditingController(text: 'alice');
    _passCtl = TextEditingController(text: 'alice123');
  }

  // Default Keycloak base derived from the gateway host:
  // https://banking-api-connectivity.poc.rhcl.com.br -> https://keycloak.poc.rhcl.com.br
  String _defaultKcBase() {
    try {
      final u = Uri.parse(widget.apiBase);
      final parts = u.host.split('.');
      if (parts.length > 1) {
        parts[0] = 'keycloak';
        return '${u.scheme}://${parts.join('.')}';
      }
    } catch (_) {}
    return 'https://keycloak.poc.rhcl.com.br';
  }

  Map<String, dynamic>? _decodeJwt(String token) {
    try {
      final payload = token.split('.')[1];
      final norm = base64Url.normalize(payload);
      return jsonDecode(utf8.decode(base64Url.decode(norm)))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _login() async {
    final base = _kcBaseCtl.text.trim().replaceAll(RegExp(r'/$'), '');
    final url =
        '$base/realms/${_realmCtl.text.trim()}/protocol/openid-connect/token';
    setState(() {
      _loginStatus = 'Solicitando token…';
      _loginOk = false;
    });
    try {
      final r = await _client.post(
        Uri.parse(url),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'password',
          'client_id': _clientIdCtl.text.trim(),
          'client_secret': _clientSecretCtl.text.trim(),
          'username': _userCtl.text.trim(),
          'password': _passCtl.text,
        },
      );
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200 && j['access_token'] != null) {
        final token = j['access_token'] as String;
        _bearerCtl.text = token;
        widget.onBearerChanged(token);
        setState(() {
          _loginOk = true;
          _tokenClaims = _decodeJwt(token);
          _loginStatus =
              'Token OK — expira em ${j['expires_in']}s. Salvo como Bearer.';
        });
      } else {
        setState(() {
          _loginOk = false;
          _tokenClaims = null;
          _loginStatus =
              'Erro ${r.statusCode}: ${j['error_description'] ?? j['error'] ?? r.body}';
        });
      }
    } catch (e) {
      setState(() {
        _loginOk = false;
        _loginStatus =
            'Falha de rede/CORS: $e — o client do Keycloak precisa permitir este origin (webOrigins).';
      });
    }
  }

  @override
  void dispose() {
    _client.close();
    _bearerCtl.dispose();
    _consumerCtl.dispose();
    _kcBaseCtl.dispose();
    _realmCtl.dispose();
    _clientIdCtl.dispose();
    _clientSecretCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  Future<void> _whoami() async {
    final r = await _client.get(
      Uri.parse('${widget.apiBase}/api/whoami'),
      headers: _commonHeaders(
        traceId: _newTraceId('whoami'),
        bearer: _bearerCtl.text,
        consumer: _consumerCtl.text,
      ),
    );
    setState(() {
      _output = 'HTTP ${r.statusCode}\n${_prettyJson(r.body)}';
      try {
        _payload = jsonDecode(r.body) as Map<String, dynamic>;
      } catch (_) {
        _payload = null;
      }
    });
  }

  Widget _kvTable(String title, Map<String, dynamic>? map) {
    if (map == null || map.isEmpty) {
      return _SectionCard(title: title, child: const Text('(empty)'));
    }
    return _SectionCard(
      title: title,
      child: Column(
        children: map.entries
            .map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 180,
                      child: Text(
                        e.key,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        e.value?.toString() ?? '',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'OIDC login (Keycloak / RHBK) — item 71',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Faz login real no Keycloak (password grant) e usa o JWT emitido. '
                'O GATEWAY (Authorino) valida assinatura/iss/aud/exp e a role; o '
                'backend não valida nada — só ecoa as claims já verificadas.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _kcBaseCtl,
                    decoration: const InputDecoration(
                      labelText: 'Keycloak base (issuer host)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _realmCtl,
                    decoration: const InputDecoration(
                      labelText: 'Realm',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _clientIdCtl,
                    decoration: const InputDecoration(
                      labelText: 'Client ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _clientSecretCtl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Client secret',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _userCtl,
                    decoration: const InputDecoration(
                      labelText: 'Usuário (alice / bob)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _passCtl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Senha',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                ElevatedButton.icon(
                  onPressed: _login,
                  icon: const Icon(Icons.login),
                  label: const Text('Login (OIDC)'),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _loginStatus,
                    style: TextStyle(
                      fontSize: 12,
                      color: _loginOk ? Colors.green.shade700 : null,
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
        if (_tokenClaims != null)
          _kvTable('Token claims (lidas do JWT no browser)', {
            'preferred_username': _tokenClaims!['preferred_username'],
            'email': _tokenClaims!['email'],
            'iss': _tokenClaims!['iss'],
            'aud': _tokenClaims!['aud'],
            'scope': _tokenClaims!['scope'],
            'realm_access.roles': (_tokenClaims!['realm_access']
                as Map<String, dynamic>?)?['roles'],
          }),
        _SectionCard(
          title: 'Identity headers',
          child: Column(
            children: [
              TextField(
                controller: _bearerCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Bearer token (sent as Authorization header)',
                  border: OutlineInputBorder(),
                ),
                onChanged: widget.onBearerChanged,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _consumerCtl,
                decoration: const InputDecoration(
                  labelText: 'x-consumer-id',
                  border: OutlineInputBorder(),
                ),
                onChanged: widget.onConsumerChanged,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  onPressed: _whoami,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Call /api/whoami'),
                ),
              ),
            ],
          ),
        ),
        _kvTable('JWT headers', _payload?['jwt'] as Map<String, dynamic>?),
        _kvTable(
          'Forwarded headers',
          _payload?['forwarded'] as Map<String, dynamic>?,
        ),
        _SectionCard(
          title: 'mTLS — x-forwarded-client-cert (XFCC)',
          child: _xfccCard(_payload?['forwarded'] as Map<String, dynamic>?),
        ),
        _SectionCard(
          title: 'Raw response',
          child: _MonoBox(text: _output),
        ),
      ],
    );
  }

  Widget _xfccCard(Map<String, dynamic>? forwarded) {
    final xfcc = forwarded?['x-forwarded-client-cert']?.toString();
    if (xfcc == null || xfcc.isEmpty) {
      return const Text(
        '(no x-forwarded-client-cert header — request did not traverse a gateway terminating mTLS, '
        'or the gateway is not configured to forward the client certificate)',
        style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
      );
    }
    // Envoy XFCC is a comma-separated list of key="value" pairs:
    //   By="...";Hash="...";Subject="...";URI="...";DNS="..."
    final parts = xfcc.split(';');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Parsed pairs:',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const SizedBox(height: 6),
        ...parts.map(
          (p) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText(
              p.trim(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Phase F — Observability panel
// -----------------------------------------------------------------------------

class ObservabilityPanel extends StatefulWidget {
  const ObservabilityPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
    required this.traceLink,
    required this.onTraceLinkChanged,
  });
  final String apiBase;
  final String bearer;
  final String consumer;
  final String traceLink;
  final ValueChanged<String> onTraceLinkChanged;

  @override
  State<ObservabilityPanel> createState() => _ObservabilityPanelState();
}

class _MetricSample {
  const _MetricSample({
    required this.name,
    required this.rawName,
    required this.labels,
    required this.value,
  });

  final String name;
  final String rawName;
  final Map<String, String> labels;
  final double value;
}

class _ObservabilityPanelState extends State<ObservabilityPanel> {
  final _client = http.Client();
  String _lastTrace = '(none)';
  late TextEditingController _traceLinkCtl;
  String _output = 'No scrape yet.';
  Map<String, double> _selectedMetrics = {};

  static const _interestedMetrics = [
    'banking_transfers_total',
    'http_server_requests_seconds_count',
  ];

  @override
  void initState() {
    super.initState();
    _traceLinkCtl = TextEditingController(text: widget.traceLink);
  }

  @override
  void dispose() {
    _client.close();
    _traceLinkCtl.dispose();
    super.dispose();
  }

  Future<void> _generateTrace() async {
    final t = _newTraceId('obs');
    setState(() => _lastTrace = t);
    try {
      await _client.get(
        Uri.parse('${widget.apiBase}/api/v1/accounts/summary'),
        headers: _commonHeaders(
          traceId: t,
          bearer: widget.bearer,
          consumer: widget.consumer,
        ),
      );
    } catch (_) {}
  }

  Future<void> _scrape() async {
    try {
      final r = await _client.get(Uri.parse('${widget.apiBase}/q/metrics'));
      final lines = r.body.split('\n');
      final picked = <String, double>{};
      for (final line in lines) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final sample = _parseMetricSample(line);
        if (sample == null) continue;
        for (final m in _interestedMetrics) {
          if (sample.name != m) continue;
          picked[sample.rawName] = (picked[sample.rawName] ?? 0) + sample.value;
        }
      }
      setState(() {
        _selectedMetrics = picked;
        _output = picked.isEmpty
            ? 'No matching series in /q/metrics'
            : '${picked.length} series matched';
      });
    } catch (e) {
      setState(() => _output = 'Scrape failed: $e');
    }
  }

  _MetricSample? _parseMetricSample(String line) {
    final idx = line.lastIndexOf(' ');
    if (idx < 0) return null;
    final rawName = line.substring(0, idx);
    final value = double.tryParse(line.substring(idx + 1).trim());
    if (value == null) return null;
    final labelsStart = rawName.indexOf('{');
    if (labelsStart < 0) {
      return _MetricSample(
        name: rawName,
        rawName: rawName,
        labels: const {},
        value: value,
      );
    }
    final labelsEnd = rawName.lastIndexOf('}');
    if (labelsEnd <= labelsStart) return null;
    return _MetricSample(
      name: rawName.substring(0, labelsStart),
      rawName: rawName,
      labels: _parsePrometheusLabels(
        rawName.substring(labelsStart + 1, labelsEnd),
      ),
      value: value,
    );
  }

  Map<String, String> _parsePrometheusLabels(String text) {
    final labels = <String, String>{};
    final exp = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"');
    for (final m in exp.allMatches(text)) {
      labels[m.group(1)!] = _unescapePrometheusLabel(m.group(2)!);
    }
    return labels;
  }

  String _unescapePrometheusLabel(String value) {
    return value.replaceAllMapped(RegExp(r'\\(.)'), (m) {
      final ch = m.group(1)!;
      return switch (ch) {
        'n' => '\n',
        '\\' => '\\',
        '"' => '"',
        _ => ch,
      };
    });
  }

  String _resolvedTraceUrl() {
    if (_lastTrace == '(none)') return '';
    return _traceLinkCtl.text.replaceAll('{traceId}', _lastTrace);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Trace correlation',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      'Last trace: $_lastTrace',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy',
                    onPressed: _lastTrace == '(none)'
                        ? null
                        : () => Clipboard.setData(
                              ClipboardData(text: _lastTrace),
                            ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _traceLinkCtl,
                decoration: const InputDecoration(
                  labelText: 'Trace UI URL template ({traceId} placeholder)',
                  border: OutlineInputBorder(),
                ),
                onChanged: widget.onTraceLinkChanged,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: _generateTrace,
                    icon: const Icon(Icons.add),
                    label: const Text('Generate trace'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _lastTrace == '(none)'
                        ? null
                        : () => html.window.open(_resolvedTraceUrl(), '_blank'),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open in trace UI'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Prometheus scrape (/q/metrics)',
          trailing: ElevatedButton.icon(
            onPressed: _scrape,
            icon: const Icon(Icons.refresh),
            label: const Text('Scrape'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_output, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              if (_selectedMetrics.isNotEmpty)
                Column(
                  children: _selectedMetrics.entries
                      .map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  e.key,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              Text(
                                e.value.toStringAsFixed(2),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
            ],
          ),
        ),
        _SectionCard(
          title: 'AI token usage — RHCL Limitador (REQ 40)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'AI token counters are not scraped from /q/metrics. Use the '
                'Grafana dashboard "RHCL AI Token Usage" (authorized_hits / '
                'authorized_calls / limited_calls from Kuadrant Limitador, '
                'driven by the TokenRateLimitPolicy on HTTPRoute '
                'banking-api-connectivity).',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: const [
                  Chip(
                    label: Text(
                      'authorized_hits',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  Chip(
                    label: Text(
                      'authorized_calls',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  Chip(
                    label: Text(
                      'limited_calls',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// WebSocket panel — exercises /ws/live and validates that gateway WebSocket
// upgrades work end-to-end (req 6, 8, 22 partial). Reports ping/pong latency,
// reconnect attempts and the raw event stream.
// -----------------------------------------------------------------------------

class WebSocketPanel extends StatefulWidget {
  const WebSocketPanel({super.key, required this.apiBase});
  final String apiBase;

  @override
  State<WebSocketPanel> createState() => _WebSocketPanelState();
}

class _WebSocketPanelState extends State<WebSocketPanel> {
  html.WebSocket? _ws;
  final List<String> _events = [];
  bool _connected = false;
  int _reconnects = 0;
  int _msgCount = 0;
  int _lastLatencyMs = -1;
  Timer? _pingTimer;
  String _path = '/ws/live';
  bool _autoReconnect = true;

  String _wsUrl() {
    final base = Uri.parse(widget.apiBase);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final apiKey = html.window.localStorage['redbank.rhclApiKey'] ?? '';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: _path,
      queryParameters: apiKey.isNotEmpty ? {'api-key': apiKey} : null,
    ).toString();
  }

  void _connect() {
    _disconnect();
    final url = _wsUrl();
    setState(() => _events.insert(0, 'connecting → $url'));
    final ws = html.WebSocket(url);
    _ws = ws;
    ws.onOpen.listen((_) {
      setState(() {
        _connected = true;
        _events.insert(0, 'open');
      });
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _sendPing(),
      );
    });
    ws.onMessage.listen((event) {
      _msgCount++;
      final data = event.data?.toString() ?? '';
      // Try to detect ping ack to compute latency.
      try {
        final j = jsonDecode(data) as Map<String, dynamic>;
        final pingTs = j['pingTimestamp'];
        if (pingTs is int) {
          _lastLatencyMs = DateTime.now().millisecondsSinceEpoch - pingTs;
        }
      } catch (_) {}
      setState(() {
        _events.insert(0, '← $data');
        if (_events.length > 100) _events.removeLast();
      });
    });
    ws.onClose.listen((event) {
      setState(() {
        _connected = false;
        _events.insert(0, 'close code=${event.code} reason=${event.reason}');
      });
      _pingTimer?.cancel();
      if (_autoReconnect) {
        _reconnects++;
        Future.delayed(const Duration(seconds: 2), _connect);
      }
    });
    ws.onError.listen((e) {
      setState(() => _events.insert(0, 'error: $e'));
    });
  }

  void _disconnect() {
    _autoReconnect = false;
    _pingTimer?.cancel();
    _ws?.close(1000, 'client disconnect');
    _ws = null;
    setState(() => _connected = false);
  }

  void _sendPing() {
    final ws = _ws;
    if (ws == null || ws.readyState != html.WebSocket.OPEN) return;
    final msg = jsonEncode({
      'type': 'ping',
      'pingTimestamp': DateTime.now().millisecondsSinceEpoch,
    });
    ws.send(msg);
    setState(() => _events.insert(0, '→ $msg'));
  }

  @override
  void dispose() {
    _autoReconnect = false;
    _pingTimer?.cancel();
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Connection',
          trailing: _ReadyDot(state: _connected ? 'UP' : 'DOWN'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                initialValue: _path,
                decoration: const InputDecoration(
                  labelText: 'WebSocket path',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _path = v,
              ),
              const SizedBox(height: 8),
              Text(
                'URL: ${_wsUrl()}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: _connected
                        ? null
                        : () {
                            _autoReconnect = true;
                            _connect();
                          },
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Connect'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _connected ? _disconnect : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Disconnect'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _connected ? _sendPing : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Send ping'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Stats',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Chip(label: 'messages', value: _msgCount, color: Colors.blue),
              _Chip(
                label: 'reconnects',
                value: _reconnects,
                color: Colors.orange,
              ),
              _Chip(
                label: 'last ping (ms)',
                value: _lastLatencyMs < 0 ? 0 : _lastLatencyMs,
                color: Colors.green,
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Event log (newest first)',
          child: _MonoBox(text: _events.join('\n'), maxHeight: 400),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// gRPC-Web panel — issues raw POST requests against the Quarkus gRPC server
// (which is exposed over the main HTTP port via grpc-web). The wire format is:
//   [1 byte compression flag][4 bytes BE length][protobuf payload]
// We hand-encode SummaryRequest{api_version="v1"} so this panel works without
// generated Dart proto stubs. The response payload is shown as hex so the
// gateway/gRPC-Web negotiation can be inspected end-to-end (req 48/54).
// -----------------------------------------------------------------------------

class GrpcWebPanel extends StatefulWidget {
  const GrpcWebPanel({
    super.key,
    required this.apiBase,
    required this.bearer,
    required this.consumer,
  });
  final String apiBase;
  final String bearer;
  final String consumer;

  @override
  State<GrpcWebPanel> createState() => _GrpcWebPanelState();
}

class _GrpcWebPanelState extends State<GrpcWebPanel> {
  String _apiVersion = 'v1';
  String _output = 'No call yet.';
  bool _busy = false;
  int _lastStatus = 0;
  int _grpcStatus = -1;
  String _grpcMessage = '';
  int _payloadBytes = 0;
  int _durationMs = 0;

  /// Encodes a single string field in protobuf wire format (tag = field<<3 | 2).
  Uint8List _encodeStringField(int fieldNumber, String value) {
    final bytes = utf8.encode(value);
    final tag = (fieldNumber << 3) | 2;
    final builder = BytesBuilder();
    builder.addByte(tag);
    builder.add(_varint(bytes.length));
    builder.add(bytes);
    return builder.toBytes();
  }

  List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while ((v & ~0x7F) != 0) {
      out.add((v & 0x7F) | 0x80);
      v >>>= 7;
    }
    out.add(v & 0x7F);
    return out;
  }

  Uint8List _encodeSummaryRequest(String version, String traceId) {
    final builder = BytesBuilder();
    if (version.isNotEmpty) builder.add(_encodeStringField(1, version));
    if (traceId.isNotEmpty) builder.add(_encodeStringField(2, traceId));
    return builder.toBytes();
  }

  Uint8List _wrapGrpcWebFrame(Uint8List proto) {
    final length = proto.length;
    final out = Uint8List(5 + length);
    out[0] = 0x00; // not compressed
    out[1] = (length >> 24) & 0xff;
    out[2] = (length >> 16) & 0xff;
    out[3] = (length >> 8) & 0xff;
    out[4] = length & 0xff;
    out.setRange(5, 5 + length, proto);
    return out;
  }

  String _hex(Uint8List bytes, {int max = 256}) {
    final view = bytes.length > max ? bytes.sublist(0, max) : bytes;
    final sb = StringBuffer();
    for (var i = 0; i < view.length; i++) {
      if (i > 0 && i % 16 == 0) sb.write('\n');
      sb.write(view[i].toRadixString(16).padLeft(2, '0'));
      sb.write(' ');
    }
    if (bytes.length > max) {
      sb.write('\n… ${bytes.length - max} more bytes');
    }
    return sb.toString();
  }

  Future<void> _callGetSummary() async {
    setState(() {
      _busy = true;
      _output = 'sending…';
      _grpcStatus = -1;
      _grpcMessage = '';
      _payloadBytes = 0;
    });
    final traceId = _newTraceId('grpcweb');
    final proto = _encodeSummaryRequest(_apiVersion, traceId);
    final framed = _wrapGrpcWebFrame(proto);
    final url = '${widget.apiBase}/io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary';

    final req = html.HttpRequest();
    req.open('POST', url);
    req.responseType = 'arraybuffer';
    req.setRequestHeader('content-type', 'application/grpc-web+proto');
    req.setRequestHeader('x-grpc-web', '1');
    req.setRequestHeader('x-flow-trace-id', traceId);
    if (widget.bearer.isNotEmpty) {
      req.setRequestHeader('authorization', 'Bearer ${widget.bearer}');
    }
    if (widget.consumer.isNotEmpty) {
      req.setRequestHeader('x-consumer-id', widget.consumer);
    }
    final completer = Completer<void>();
    req.onLoadEnd.listen((_) => completer.complete());
    final t0 = DateTime.now();
    req.send(framed);
    await completer.future;
    final dt = DateTime.now().difference(t0).inMilliseconds;

    final body = req.response as ByteBuffer?;
    final bytes = body == null ? Uint8List(0) : Uint8List.view(body);
    setState(() {
      _busy = false;
      _lastStatus = req.status ?? 0;
      _payloadBytes = bytes.length;
      _durationMs = dt;
      // grpc-status / grpc-message live in trailers; with grpc-web they are
      // delivered either as response headers or in a final 0x80-prefixed frame.
      final statusHeader = req.getResponseHeader('grpc-status');
      _grpcStatus = int.tryParse(statusHeader ?? '') ?? _grpcStatus;
      _grpcMessage = req.getResponseHeader('grpc-message') ?? '';
      _output = 'POST $url\n'
          'sent ${framed.length}B (proto ${proto.length}B)\n'
          'HTTP $_lastStatus in ${dt}ms\n'
          'received ${bytes.length}B\n\n'
          'response hex:\n${_hex(bytes)}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'GetSummary (gRPC-Web)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Calls /io.gatewaysmashes.rhcl.grpc.BankingService/GetSummary using the '
                'application/grpc-web+proto wire format. The protobuf message is '
                'hand-encoded so no generated Dart stubs are required.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _apiVersion,
                      decoration: const InputDecoration(
                        labelText: 'api_version',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => _apiVersion = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _callGetSummary,
                    icon: const Icon(Icons.send),
                    label: const Text('Call'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Result',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Chip(label: 'http', value: _lastStatus, color: Colors.blue),
              _Chip(
                label: 'grpc-status',
                value: _grpcStatus < 0 ? 0 : _grpcStatus,
                color: _grpcStatus == 0 ? Colors.green : Colors.red,
              ),
              _Chip(label: 'bytes', value: _payloadBytes, color: Colors.teal),
              _Chip(
                label: 'duration ms',
                value: _durationMs,
                color: Colors.orange,
              ),
            ],
          ),
        ),
        if (_grpcMessage.isNotEmpty)
          _SectionCard(
            title: 'grpc-message',
            child: _MonoBox(text: _grpcMessage),
          ),
        _SectionCard(
          title: 'Wire dump',
          child: _MonoBox(text: _output, maxHeight: 360),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// MCP Integration panel
// -----------------------------------------------------------------------------

class McpIntegrationPanel extends StatefulWidget {
  const McpIntegrationPanel({
    super.key,
    required this.defaultGatewayUrl,
    required this.bearer,
    required this.consumer,
  });

  final String defaultGatewayUrl;
  final String bearer;
  final String consumer;

  @override
  State<McpIntegrationPanel> createState() => _McpIntegrationPanelState();
}

class _McpIntegrationPanelState extends State<McpIntegrationPanel> {
  late final TextEditingController _gatewayController;
  final _argumentsController = TextEditingController(
    text: '{\n  "version": "v1"\n}',
  );
  String _sessionId = '';
  String _selectedTool = '';
  String _output = 'No MCP call yet.';
  List<Map<String, dynamic>> _tools = [];
  bool _busy = false;
  int _nextId = 1;
  int _lastStatus = 0;

  @override
  void initState() {
    super.initState();
    final initialGatewayUrl = _normalizeGatewayUrl(
      _readStorage(
        pocMcpGatewayUrlStorageKey,
        fallback: widget.defaultGatewayUrl,
      ),
    );
    _writeStorage(pocMcpGatewayUrlStorageKey, initialGatewayUrl);
    _gatewayController = TextEditingController(
      text: initialGatewayUrl,
    );
  }

  @override
  void dispose() {
    _gatewayController.dispose();
    _argumentsController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _rpc(String method, [Map<String, dynamic>? params]) {
    return {
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      if (params != null) 'params': params,
    };
  }

  String _decodeMcpBody(String body) {
    final trimmed = body.trim();
    if (!trimmed.startsWith('event:') && !trimmed.startsWith('data:')) {
      return trimmed;
    }
    final dataLines = <String>[];
    for (final line in trimmed.split('\n')) {
      final clean = line.trimRight();
      if (clean.startsWith('data:')) {
        dataLines.add(clean.substring(5).trimLeft());
      }
    }
    return dataLines.isEmpty ? trimmed : dataLines.join('\n').trim();
  }

  Future<Map<String, dynamic>> _sendMcp(Map<String, dynamic> payload) async {
    final url = _normalizeGatewayUrl(_gatewayController.text.trim());
    if (url.isEmpty) {
      throw StateError('Set the MCP Gateway URL first.');
    }
    if (_gatewayController.text.trim() != url) {
      _gatewayController.text = url;
    }
    _writeStorage(pocMcpGatewayUrlStorageKey, url);

    final traceId = _newTraceId('mcp');
    final req = html.HttpRequest();
    req.timeout = 30000;
    req.open('POST', url);
    req.setRequestHeader('content-type', 'application/json');
    req.setRequestHeader('accept', 'application/json, text/event-stream');
    req.setRequestHeader('x-flow-trace-id', traceId);
    req.setRequestHeader('x-client-app', 'red-bank-mobile');
    if (widget.bearer.isNotEmpty) {
      req.setRequestHeader('authorization', 'Bearer ${widget.bearer}');
    }
    if (widget.consumer.isNotEmpty) {
      req.setRequestHeader('x-consumer-id', widget.consumer);
    }
    if (_sessionId.isNotEmpty) {
      req.setRequestHeader('mcp-session-id', _sessionId);
    }

    final completer = Completer<void>();
    req.onLoadEnd.listen((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    req.onTimeout.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('MCP request timed out.'));
      }
    });
    req.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('MCP request failed.'));
      }
    });
    req.send(jsonEncode(payload));
    await completer.future;

    final status = req.status ?? 0;
    final session = req.getResponseHeader('mcp-session-id');
    final raw = req.responseText ?? '';
    final body = _decodeMcpBody(raw);
    final decoded = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    if (session != null && session.isNotEmpty) {
      _sessionId = session;
    }
    return {
      'status': status,
      'traceId': traceId,
      'sessionId': _sessionId,
      'headers': req.getAllResponseHeaders(),
      'body': decoded,
      'rawBody': raw,
    };
  }

  String _normalizeGatewayUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    try {
      final uri = Uri.parse(trimmed);
      if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
        return trimmed;
      }
      final path = uri.path.isEmpty ? '/mcp' : uri.path;
      return uri.replace(path: path).toString();
    } catch (_) {
      return trimmed;
    }
  }

  Future<void> _run(String label, Map<String, dynamic> payload) async {
    setState(() {
      _busy = true;
      _output = '$label...';
    });
    try {
      final result = await _sendMcp(payload);
      final status = result['status'] as int;
      final body = result['body'] as Map<String, dynamic>;
      final responseTools = body['result'] is Map<String, dynamic>
          ? (body['result'] as Map<String, dynamic>)['tools']
          : null;
      if (responseTools is List) {
        _tools = responseTools.whereType<Map>().map((tool) {
          return tool.map((key, value) => MapEntry(key.toString(), value));
        }).toList();
        if (_tools.isNotEmpty &&
            !_tools.any((tool) => tool['name'] == _selectedTool)) {
          _selectedTool = _tools.first['name']?.toString() ?? '';
        }
      }
      setState(() {
        _lastStatus = status;
        _output = _prettyJsonValue({
          'httpStatus': status,
          'traceId': result['traceId'],
          'sessionId': result['sessionId'],
          'response': body,
        });
      });
    } catch (e) {
      setState(() {
        _output = '$label failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _initialize() async {
    await _run(
      'initialize',
      _rpc('initialize', {
        'protocolVersion': '2025-03-26',
        'capabilities': {},
        'clientInfo': {'name': 'red-bank-mobile', 'version': '1.0.0'},
      }),
    );
  }

  Future<void> _listTools() async {
    await _run('tools/list', _rpc('tools/list'));
  }

  Future<void> _callTool() async {
    final name = _selectedTool.trim();
    if (name.isEmpty) {
      setState(() => _output = 'Select a tool first.');
      return;
    }
    Object? arguments;
    try {
      final raw = _argumentsController.text.trim();
      arguments = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    } catch (e) {
      setState(() => _output = 'Tool arguments are not valid JSON: $e');
      return;
    }
    await _run(
      'tools/call',
      _rpc('tools/call', {'name': name, 'arguments': arguments}),
    );
  }

  void _applyToolExample(String name) {
    if (name.contains('simulateTransfer')) {
      _argumentsController.text = const JsonEncoder.withIndent('  ').convert({
        'version': 'v1',
        'fromBank': 'Example Bank',
        'toBank': 'EXTERNAL',
        'amount': '1500.00',
        'clientTraceId': _newTraceId('mcp-transfer'),
      });
      return;
    }
    if (name.contains('setBackendMode')) {
      _argumentsController.text = const JsonEncoder.withIndent(
        '  ',
      ).convert({'mode': 'healthy', 'failRate': 0.0});
      return;
    }
    if (name.contains('getBackendMode')) {
      _argumentsController.text = '{}';
      return;
    }
    _argumentsController.text = const JsonEncoder.withIndent(
      '  ',
    ).convert({'version': 'v1'});
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SectionCard(
          title: 'Gateway session',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _gatewayController,
                onChanged: (value) => _writeStorage(
                  pocMcpGatewayUrlStorageKey,
                  _normalizeGatewayUrl(value),
                ),
                decoration: const InputDecoration(
                  labelText: 'MCP Gateway URL',
                  hintText: 'http://mcp.example.com:8080/mcp',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _initialize,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Initialize'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _listTools,
                    icon: const Icon(Icons.list_alt),
                    label: const Text('List tools'),
                  ),
                  _Chip(label: 'http', value: _lastStatus, color: Colors.blue),
                  if (_sessionId.isNotEmpty)
                    InputChip(
                      label: Text(
                        'session ${_sessionId.length > 12 ? _sessionId.substring(0, 12) : _sessionId}',
                      ),
                      onDeleted: () => setState(() => _sessionId = ''),
                    ),
                ],
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Tool call',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Tool',
                  border: OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedTool.isEmpty ? null : _selectedTool,
                    isExpanded: true,
                    hint: const Text('List tools first'),
                    items: _tools
                        .map(
                          (tool) => DropdownMenuItem<String>(
                            value: tool['name']?.toString() ?? '',
                            child: Text(tool['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _selectedTool = value);
                      _applyToolExample(value);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _argumentsController,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Arguments JSON',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _busy ? null : _callTool,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Call tool'),
              ),
            ],
          ),
        ),
        if (_tools.isNotEmpty)
          _SectionCard(
            title: 'Discovered tools',
            child: _MonoBox(text: _prettyJsonValue(_tools), maxHeight: 260),
          ),
        _SectionCard(
          title: 'Result',
          child: _MonoBox(text: _output, maxHeight: 420),
        ),
      ],
    );
  }
}

class _TextChip extends StatelessWidget {
  const _TextChip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}

// =============================================================================
// HTTP Versions Panel — req057
// Validates that the gateway exposes HTTP/1.1, HTTP/2 and advertises HTTP/3.
// =============================================================================

const String _httpVersionsHostStorageKey = 'redbank.httpVersionsHost';
const String _httpVersionsApiKeyStorageKey = 'redbank.httpVersionsApiKey';

class _TestResult {
  _TestResult({
    required this.label,
    required this.description,
    this.status,
    this.headers = const {},
    this.error,
    this.informational = false,
  });

  final String label;
  final String description;
  final int? status;
  final Map<String, String> headers;
  final String? error;
  final bool informational;

  bool get passed {
    if (error != null || status == null) return false;
    return _expectedPassed;
  }

  bool get _expectedPassed {
    switch (label) {
      case 'Auth — sem API key (401)':
        return status == 401;
      case 'Auth — com API key (200)':
        return status == 200;
      case 'HTTP/2 (ALPN via TLS)':
        return status == 200;
      case 'HTTP/3 Advertisement (informativo)':
        // alt-svc raramente chega ao JS; se chegou, valida; senão informativo.
        return status == 200;
      default:
        return status != null && status! < 500;
    }
  }

  String get expectation {
    switch (label) {
      case 'Auth — sem API key (401)':
        return 'Status 401 Unauthorized';
      case 'Auth — com API key (200)':
        return 'Status 200 OK';
      case 'HTTP/2 (ALPN via TLS)':
        return 'Status 200, HTTP/2 via ALPN';
      case 'HTTP/3 Advertisement (informativo)':
        return (headers['alt-svc'] ?? '').contains('h3=')
            ? 'alt-svc: ${headers['alt-svc']}'
            : 'alt-svc oculto ao JS — usar curl -I';
      default:
        return '—';
    }
  }
}

class HttpVersionsPanel extends StatefulWidget {
  const HttpVersionsPanel({super.key, required this.apiBase});

  final String apiBase;

  @override
  State<HttpVersionsPanel> createState() => _HttpVersionsPanelState();
}

class _HttpVersionsPanelState extends State<HttpVersionsPanel> {
  late final TextEditingController _hostCtrl;
  late final TextEditingController _apiKeyCtrl;
  bool _running = false;
  List<_TestResult> _results = [];
  String _log = '';

  @override
  void initState() {
    super.initState();
    final savedHost = _readStorage(_httpVersionsHostStorageKey);
    final initial =
        savedHost.isNotEmpty ? savedHost : pocApiBase(widget.apiBase);
    _hostCtrl = TextEditingController(text: initial);
    _apiKeyCtrl = TextEditingController(
      text: _readStorage(_httpVersionsApiKeyStorageKey),
    );
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  String get _host => _hostCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
  String get _apiKey => _apiKeyCtrl.text.trim();
  // Chave usada nos exemplos de curl: a digitada no painel, ou a chave
  // gold de demo como fallback (cluster de PoC, sem segredo real).
  String get _curlKey => _apiKey.isNotEmpty ? _apiKey : 'alice-gold-secret';
  static const _path = '/api/v1/accounts/summary';

  void _appendLog(String msg) {
    setState(() => _log = '$_log$msg\n');
  }

  Future<_TestResult> _runTest({
    required String label,
    required String description,
    required String url,
    Map<String, String> extraHeaders = const {},
    bool informational = false,
  }) async {
    _appendLog('→ $label: $url');
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(extraHeaders);
      final streamed = await http.Client().send(req);
      await streamed.stream.drain<void>();
      final hdrs = Map<String, String>.from(streamed.headers);
      _appendLog(
          '  ← ${streamed.statusCode}  headers: ${hdrs.keys.join(', ')}');
      if (hdrs.containsKey('alt-svc')) {
        _appendLog('  alt-svc: ${hdrs['alt-svc']}');
      }
      return _TestResult(
        label: label,
        description: description,
        status: streamed.statusCode,
        headers: hdrs,
        informational: informational,
      );
    } catch (e) {
      _appendLog('  ✗ $e');
      return _TestResult(
        label: label,
        description: description,
        error: e.toString(),
        informational: informational,
      );
    }
  }

  Future<void> _runAll() async {
    _writeStorage(_httpVersionsHostStorageKey, _host);
    _writeStorage(_httpVersionsApiKeyStorageKey, _apiKey);
    setState(() {
      _running = true;
      _log = '';
      _results = [];
    });

    // Browsers só permitem fetch HTTPS a partir de uma página HTTPS
    // (mixed-content blocking), então todos os testes usam HTTPS. A
    // verificação de HTTP/1.1 cleartext e do header alt-svc precisa de
    // curl/terminal — ver o card "Como validar no terminal" abaixo.
    final httpsBase = _host.startsWith('http://')
        ? _host.replaceFirst('http://', 'https://')
        : _host.startsWith('https://')
            ? _host
            : 'https://$_host';

    final keyHeader =
        _apiKey.isNotEmpty ? {'api-key': _apiKey} : <String, String>{};

    final results = <_TestResult>[];

    // Test 1 — AuthPolicy nega sem API key (expect 401)
    results.add(await _runTest(
      label: 'Auth — sem API key (401)',
      description:
          'GET https://<host>$_path sem API key — AuthPolicy deve negar com 401',
      url: '$httpsBase$_path',
    ));

    // Test 2 — AuthPolicy permite com API key (expect 200)
    results.add(await _runTest(
      label: 'Auth — com API key (200)',
      description: 'GET https://<host>$_path com API key — deve retornar 200',
      url: '$httpsBase$_path',
      extraHeaders: keyHeader,
    ));

    // Test 3 — HTTPS (HTTP/2 via ALPN, browser negotiates)
    results.add(await _runTest(
      label: 'HTTP/2 (ALPN via TLS)',
      description: 'GET https://<host>$_path — Envoy negocia HTTP/2 via ALPN',
      url: '$httpsBase$_path',
      extraHeaders: keyHeader,
    ));

    // Test 4 — alt-svc header check (HTTP/3 advertisement).
    // Informativo: browsers removem alt-svc da resposta visível ao JS
    // (forbidden response-header name), então só dá pra confirmar via curl.
    results.add(await _runTest(
      label: 'HTTP/3 Advertisement (informativo)',
      description:
          'alt-svc não é exposto ao JS pelo browser — valide com curl -I',
      url: '$httpsBase$_path',
      extraHeaders: keyHeader,
      informational: true,
    ));

    setState(() {
      _results = results;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _SectionCard(
          title: 'Configuração',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Gateway base URL (banking-api host)',
                  hintText: 'https://banking-api.apps.<cluster-domain>',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKeyCtrl,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: 'minha-chave-secreta',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _running ? null : _runAll,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_running ? 'Executando…' : 'Executar testes'),
              ),
            ],
          ),
        ),
        if (_results.isNotEmpty)
          _SectionCard(
            title: 'Resultados',
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(2.5),
                1: FlexColumnWidth(2.5),
                2: FixedColumnWidth(80),
                3: FixedColumnWidth(72),
              },
              border: TableBorder.all(
                color: Colors.grey.shade300,
                width: 0.5,
              ),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(color: Colors.grey.shade200),
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Teste',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Esperado',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Status',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Resultado',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                  ],
                ),
                for (final r in _results) _buildRow(context, r),
              ],
            ),
          ),
        _SectionCard(
          title: 'Como validar no terminal (o que o browser não mostra)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Browsers bloqueiam fetch HTTP cleartext (mixed content) e escondem '
                'alt-svc do JS. A negociação ALPN (h2/http1.1) acontece no handshake '
                'TLS, visível só com curl -v (não com -i). Comandos prontos:',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              _MonoBox(
                maxHeight: 280,
                text:
                    'HOST=${_host.replaceFirst(RegExp(r'^https?://'), '')}\n\n'
                    '# HTTP/1.1 cleartext (porta 80) — sem API key deve dar 401\n'
                    'curl -sik --http1.1 "http://\$HOST$_path"\n\n'
                    '# HTTP/2 via ALPN — use -v (ALPN é handshake TLS, não header)\n'
                    'curl -sv --http2 "https://\$HOST$_path" -H "api-key: $_curlKey" 2>&1 \\\n'
                    '  | grep -iE "ALPN|using HTTP|SSL connection|^< HTTP"\n'
                    '#   * ALPN: server accepted h2\n'
                    '#   * using HTTP/2\n'
                    '#   < HTTP/2 200\n\n'
                    '# Forçar HTTP/1.1 pra comparar a negociação ALPN\n'
                    'curl -sv --http1.1 "https://\$HOST$_path" -H "api-key: $_curlKey" 2>&1 \\\n'
                    '  | grep -iE "ALPN: server|using HTTP"\n\n'
                    '# HTTP/3 advertisement — o alt-svc aparece aqui (browser esconde)\n'
                    'curl -sik "https://\$HOST$_path" -H "api-key: $_curlKey" | grep -i alt-svc\n\n'
                    '# HTTP/3 de fato (requer curl com suporte a QUIC)\n'
                    'curl -sv --http3 "https://\$HOST$_path" -H "api-key: $_curlKey" 2>&1 \\\n'
                    '  | grep -iE "ALPN|using HTTP"',
              ),
            ],
          ),
        ),
        if (_log.isNotEmpty)
          _SectionCard(
            title: 'Log',
            child: _MonoBox(text: _log, maxHeight: 300),
          ),
      ],
    );
  }

  TableRow _buildRow(BuildContext context, _TestResult r) {
    final passColor = Colors.green.shade700;
    final failColor = Colors.red.shade700;
    final infoColor = Colors.blue.shade600;
    final passed = r.passed;
    final statusText = r.error != null ? 'Erro' : r.status?.toString() ?? '—';

    // Informational tests (alt-svc) never show a red X: green if reachable,
    // blue info icon if the data can't be read from the browser.
    final IconData icon;
    final Color iconColor;
    if (r.informational) {
      icon = Icons.info_outline;
      iconColor = infoColor;
    } else if (passed) {
      icon = Icons.check_circle;
      iconColor = passColor;
    } else {
      icon = Icons.cancel;
      iconColor = failColor;
    }

    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(r.description,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(r.expectation,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            statusText,
            style: TextStyle(
              fontFamily: 'monospace',
              color: r.error != null ? failColor : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: iconColor, size: 22),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// LoadBalancingPanel — Item 5 (Balanceamento de carga por peso)
// -----------------------------------------------------------------------------

const String _lbHostStorageKey = 'redbank.lbHost';
const String _lbReqCountStorageKey = 'redbank.lbReqCount';

class LoadBalancingPanel extends StatefulWidget {
  const LoadBalancingPanel({super.key, required this.apiBase});

  final String apiBase;

  @override
  State<LoadBalancingPanel> createState() => _LoadBalancingPanelState();
}

class _LoadBalancingPanelState extends State<LoadBalancingPanel> {
  late final TextEditingController _hostCtrl;
  double _reqCount = 100;
  bool _running = false;
  int _completed = 0;
  int _errors = 0;
  final Map<String, int> _counts = <String, int>{};
  final List<String> _timeline = <String>[];
  Duration? _elapsed;

  static const _path = '/api/lb-test';
  static const _v1Color = Color(0xFF1E88E5);
  static const _v2Color = Color(0xFFE53935);
  static const _otherColor = Color(0xFF8E24AA);

  @override
  void initState() {
    super.initState();
    final savedHost = _readStorage(_lbHostStorageKey);
    final initial =
        savedHost.isNotEmpty ? savedHost : pocApiBase(widget.apiBase);
    _hostCtrl = TextEditingController(text: initial);
    final savedCount = int.tryParse(_readStorage(_lbReqCountStorageKey));
    if (savedCount != null && savedCount >= 10 && savedCount <= 500) {
      _reqCount = savedCount.toDouble();
    }
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  String get _host => _hostCtrl.text.trim().replaceAll(RegExp(r'/$'), '');

  Color _colorFor(String instance) {
    if (instance.endsWith('v1')) return _v1Color;
    if (instance.endsWith('v2')) return _v2Color;
    return _otherColor;
  }

  Future<void> _runTest() async {
    final host = _host;
    if (host.isEmpty) return;
    _writeStorage(_lbHostStorageKey, host);
    _writeStorage(_lbReqCountStorageKey, _reqCount.toInt().toString());

    setState(() {
      _running = true;
      _completed = 0;
      _errors = 0;
      _counts.clear();
      _timeline.clear();
      _elapsed = null;
    });

    final url = '$host$_path';
    final stopwatch = Stopwatch()..start();
    final total = _reqCount.toInt();
    const concurrency = 10;
    final batches = (total / concurrency).ceil();

    for (var b = 0; b < batches; b++) {
      final remaining = total - (b * concurrency);
      final size = remaining >= concurrency ? concurrency : remaining;
      final futures = List.generate(size, (_) => _hitOnce(url));
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _completed++;
          if (r == null) {
            _errors++;
          } else {
            _counts[r] = (_counts[r] ?? 0) + 1;
            if (_timeline.length < 200) _timeline.add(r);
          }
        }
      });
    }

    stopwatch.stop();
    if (!mounted) return;
    setState(() {
      _elapsed = stopwatch.elapsed;
      _running = false;
    });
  }

  Future<String?> _hitOnce(String url) async {
    try {
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body);
      if (body is Map && body['instance'] is String) {
        return body['instance'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _counts.values.fold<int>(0, (a, b) => a + b);
    final sortedEntries = _counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _SectionCard(
          title: 'Item 5 — Balanceamento de carga por peso',
          child: const Text(
            'Esta aba envia N requisições para /api/lb-test e mede a '
            'distribuição entre os backends banking-api-v1 e banking-api-v2. '
            'O HTTPRoute reescreve o path para /api/echo nos dois backends, '
            'que retornam o pod identificador (instance). '
            'Os pesos são configurados no install via APPS_CONNECTIVITY_LB_V1_WEIGHT '
            'e APPS_CONNECTIVITY_LB_V2_WEIGHT (default 50/50).',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        _SectionCard(
          title: 'Configuração',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Gateway base URL',
                  hintText:
                      'https://banking-api-connectivity.apps.<cluster-domain>',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('Requisições: '),
                  Text(
                    '${_reqCount.toInt()}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                value: _reqCount,
                min: 10,
                max: 500,
                divisions: 49,
                label: _reqCount.toInt().toString(),
                onChanged:
                    _running ? null : (v) => setState(() => _reqCount = v),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _running ? null : _runTest,
                icon: _running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_running
                    ? 'Executando… ($_completed/${_reqCount.toInt()})'
                    : 'Executar teste'),
              ),
            ],
          ),
        ),
        if (total > 0)
          _SectionCard(
            title: 'Distribuição',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDistributionBar(sortedEntries, total),
                const SizedBox(height: 12),
                _buildLegend(sortedEntries, total),
              ],
            ),
          ),
        if (total > 0)
          _SectionCard(
            title: 'Resumo',
            child: Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FixedColumnWidth(80),
                2: FixedColumnWidth(80),
              },
              border: TableBorder.all(color: Colors.grey.shade300, width: 0.5),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(color: Colors.grey.shade200),
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Backend',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Hits',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('%',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.black87)),
                    ),
                  ],
                ),
                for (final e in sortedEntries)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: _colorFor(e.key),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(e.key,
                                style:
                                    const TextStyle(fontFamily: 'monospace')),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('${e.value}',
                            style: const TextStyle(fontFamily: 'monospace')),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                            '${(100 * e.value / total).toStringAsFixed(1)}%',
                            style: const TextStyle(fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                if (_errors > 0)
                  TableRow(
                    decoration: BoxDecoration(color: Colors.red.shade50),
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                size: 14, color: Colors.red),
                            SizedBox(width: 8),
                            Text('erros / sem resposta',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    color: Colors.black87)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('$_errors',
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                color: Colors.black87)),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                            '${(100 * _errors / _reqCount).toStringAsFixed(1)}%',
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                color: Colors.black87)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        if (_elapsed != null)
          _SectionCard(
            title: 'Métricas',
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _TextChip(
                  text: '⏱ ${_elapsed!.inMilliseconds} ms',
                  color: Colors.indigo,
                ),
                _TextChip(
                  text:
                      '${(_completed / (_elapsed!.inMilliseconds / 1000)).toStringAsFixed(1)} req/s',
                  color: Colors.teal,
                ),
                _TextChip(
                  text: '${_completed - _errors} OK / $_errors falhas',
                  color: _errors == 0 ? Colors.green : Colors.orange,
                ),
              ],
            ),
          ),
        if (_timeline.isNotEmpty)
          _SectionCard(
            title: 'Linha do tempo (primeiras ${_timeline.length})',
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final inst in _timeline)
                  Tooltip(
                    message: inst,
                    child: Container(
                      width: 12,
                      height: 18,
                      color: _colorFor(inst),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDistributionBar(List<MapEntry<String, int>> entries, int total) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            for (final e in entries)
              Expanded(
                flex: e.value,
                child: Container(
                  color: _colorFor(e.key),
                  alignment: Alignment.center,
                  child: Text(
                    '${(100 * e.value / total).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend(List<MapEntry<String, int>> entries, int total) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final e in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _colorFor(e.key),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${e.key}: ${e.value} (${(100 * e.value / total).toStringAsFixed(1)}%)',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// RateLimitingPanel — Itens 61-65 (Rate Limit Global / Custom Fields / Gateway)
// -----------------------------------------------------------------------------

const String _rlHostStorageKey = 'redbank.rlHost';
const String _rlPathStorageKey = 'redbank.rlPath';
const String _rlReqCountStorageKey = 'redbank.rlReqCount';

enum _RlScenario { single, byHeader, byApiKey }

class RateLimitingPanel extends StatefulWidget {
  const RateLimitingPanel({super.key, required this.apiBase});

  final String apiBase;

  @override
  State<RateLimitingPanel> createState() => _RateLimitingPanelState();
}

class _RateLimitingPanelState extends State<RateLimitingPanel> {
  late final TextEditingController _hostCtrl;
  late final TextEditingController _pathCtrl;
  late final TextEditingController _headerNameCtrl;
  late final TextEditingController _headerValuesCtrl;
  late final TextEditingController _apiKeysCtrl;
  late final TextEditingController _authPathCtrl;

  _RlScenario _scenario = _RlScenario.single;
  double _reqCount = 30;
  bool _running = false;
  Duration? _elapsed;

  // Results: each tick is (bucketLabel, status, ms)
  final List<_RlTick> _ticks = <_RlTick>[];

  static const _okColor = Color(0xFF3E8635);
  static const _limColor = Color(0xFFF0AB00);
  static const _errColor = Color(0xFFC9190B);

  @override
  void initState() {
    super.initState();
    final savedHost = _readStorage(_rlHostStorageKey);
    final initialHost =
        savedHost.isNotEmpty ? savedHost : pocApiBase(widget.apiBase);
    _hostCtrl = TextEditingController(text: initialHost);
    final savedPath = _readStorage(_rlPathStorageKey, fallback: '/api/echo');
    _pathCtrl = TextEditingController(text: savedPath);
    final savedCount = int.tryParse(_readStorage(_rlReqCountStorageKey));
    if (savedCount != null && savedCount >= 5 && savedCount <= 500) {
      _reqCount = savedCount.toDouble();
    }
    _headerNameCtrl = TextEditingController(text: 'x-customer-id');
    _headerValuesCtrl = TextEditingController(text: 'alpha,beta,gamma');
    _apiKeysCtrl = TextEditingController(
      text: 'alice-gold-secret,bob-silver-secret,carol-bronze-secret',
    );
    _authPathCtrl = TextEditingController(text: '/api/v1/accounts/summary');
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _pathCtrl.dispose();
    _headerNameCtrl.dispose();
    _headerValuesCtrl.dispose();
    _apiKeysCtrl.dispose();
    _authPathCtrl.dispose();
    super.dispose();
  }

  String get _host => _hostCtrl.text.trim().replaceAll(RegExp(r'/$'), '');

  Future<void> _run() async {
    if (_host.isEmpty) return;
    _writeStorage(_rlHostStorageKey, _host);
    _writeStorage(_rlPathStorageKey, _pathCtrl.text.trim());
    _writeStorage(_rlReqCountStorageKey, _reqCount.toInt().toString());

    setState(() {
      _running = true;
      _ticks.clear();
      _elapsed = null;
    });

    final stopwatch = Stopwatch()..start();
    try {
      switch (_scenario) {
        case _RlScenario.single:
          await _burst(
            target: '$_host${_pathCtrl.text.trim()}',
            count: _reqCount.toInt(),
            headers: const {},
            bucket: 'global',
          );
          break;
        case _RlScenario.byHeader:
          final values = _headerValuesCtrl.text
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          final headerName = _headerNameCtrl.text.trim();
          final target = '$_host${_pathCtrl.text.trim()}';
          await Future.wait(values.map((v) => _burst(
                target: target,
                count: _reqCount.toInt(),
                headers: {headerName: v},
                bucket: v,
              )));
          break;
        case _RlScenario.byApiKey:
          final keys = _apiKeysCtrl.text
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          final target = '$_host${_authPathCtrl.text.trim()}';
          await Future.wait(keys.map((k) {
            final label = k.split('-').first; // alice/bob/carol
            return _burst(
              target: target,
              count: _reqCount.toInt(),
              headers: {'api-key': k},
              bucket: label,
            );
          }));
          break;
      }
    } finally {
      stopwatch.stop();
      if (mounted) {
        setState(() {
          _running = false;
          _elapsed = stopwatch.elapsed;
          _ticks.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        });
      }
    }
  }

  Future<void> _burst({
    required String target,
    required int count,
    required Map<String, String> headers,
    required String bucket,
  }) async {
    const concurrency = 5;
    var dispatched = 0;
    Future<void> worker() async {
      while (true) {
        final i = dispatched++;
        if (i >= count) return;
        final t0 = DateTime.now();
        final sw = Stopwatch()..start();
        int code = 0;
        try {
          final resp = await http.get(Uri.parse(target), headers: headers);
          code = resp.statusCode;
        } catch (_) {
          code = 0;
        }
        sw.stop();
        if (mounted) {
          setState(() {
            _ticks.add(_RlTick(
              bucket: bucket,
              code: code,
              ms: sw.elapsed.inMilliseconds,
              timestamp: t0,
            ));
          });
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  Color _colorFor(int code) {
    if (code == 200) return _okColor;
    if (code == 429) return _limColor;
    return _errColor;
  }

  String _glyph(int code) {
    if (code == 200) return '✓';
    if (code == 429) return '⊘';
    return '!';
  }

  @override
  Widget build(BuildContext context) {
    final total = _ticks.length;
    final ok = _ticks.where((t) => t.code == 200).length;
    final lim = _ticks.where((t) => t.code == 429).length;
    final err = total - ok - lim;
    final avgMs = total == 0
        ? 0
        : (_ticks.map((t) => t.ms).reduce((a, b) => a + b) / total).round();

    // Per-bucket distribution
    final buckets = <String, _RlBucket>{};
    for (final t in _ticks) {
      final b = buckets.putIfAbsent(t.bucket, () => _RlBucket());
      if (t.code == 200) {
        b.ok++;
      } else if (t.code == 429) {
        b.limited++;
      } else {
        b.errors++;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionCard(
            title: 'Configuração',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _hostCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Host (protocol+domain)',
                    hintText: 'https://banking-api-connectivity.apps.…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Requisições por bucket: ${_reqCount.toInt()}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Slider(
                        min: 5,
                        max: 200,
                        divisions: 39,
                        value: _reqCount,
                        label: _reqCount.toInt().toString(),
                        onChanged: _running
                            ? null
                            : (v) => setState(() => _reqCount = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _SectionCard(
            title: 'Cenário',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<_RlScenario>(
                  segments: const [
                    ButtonSegment(
                      value: _RlScenario.single,
                      label: Text('Single bucket (global)'),
                      icon: Icon(Icons.speed, size: 18),
                    ),
                    ButtonSegment(
                      value: _RlScenario.byHeader,
                      label: Text('Por header (Item 63)'),
                      icon: Icon(Icons.badge, size: 18),
                    ),
                    ButtonSegment(
                      value: _RlScenario.byApiKey,
                      label: Text('Por APIKey'),
                      icon: Icon(Icons.key, size: 18),
                    ),
                  ],
                  selected: {_scenario},
                  onSelectionChanged: _running
                      ? null
                      : (s) => setState(() => _scenario = s.first),
                ),
                const SizedBox(height: 16),
                if (_scenario == _RlScenario.single) ...[
                  TextField(
                    controller: _pathCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Path',
                      hintText: '/api/echo',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Dispara N reqs sequenciais. Exercita o limite global '
                    'da RateLimitPolicy aplicada (Item 61).',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
                if (_scenario == _RlScenario.byHeader) ...[
                  TextField(
                    controller: _pathCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Path',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _headerNameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Header name',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _headerValuesCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Values (separados por vírgula)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Dispara N reqs em paralelo para cada value. Cada bucket '
                    'tem seu próprio counter (Item 63).',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
                if (_scenario == _RlScenario.byApiKey) ...[
                  TextField(
                    controller: _authPathCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Path autenticado',
                      hintText: '/api/v1/accounts/summary',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKeysCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Keys (separados por vírgula)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Cada chave gera identidade distinta. Counter por '
                    'auth.identity.userid (Item 63 + plan policy).',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _running ? null : _run,
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(_running ? 'Rodando…' : 'Run'),
                    ),
                    const SizedBox(width: 12),
                    if (_elapsed != null)
                      Text(
                        'Total ${_elapsed!.inMilliseconds}ms',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (total > 0)
            _SectionCard(
              title: 'Resultado',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _statChip('Total', '$total'),
                      _statChip('200 OK', '$ok', color: _okColor),
                      _statChip('429 Limited', '$lim', color: _limColor),
                      _statChip('Outros', '$err',
                          color: err > 0 ? _errColor : null),
                      _statChip('Latência média', '${avgMs}ms'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Timeline
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Wrap(
                      spacing: 2,
                      runSpacing: 2,
                      children: [
                        for (final t in _ticks)
                          Tooltip(
                            message: '${t.bucket} → ${t.code} (${t.ms}ms)',
                            child: Container(
                              width: 14,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _colorFor(t.code),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                _glyph(t.code),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Distribuição por bucket',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Table(
                    border:
                        TableBorder.all(color: Colors.grey.shade300, width: 1),
                    columnWidths: const {
                      0: FlexColumnWidth(2),
                      1: FlexColumnWidth(1),
                      2: FlexColumnWidth(1),
                      3: FlexColumnWidth(1),
                    },
                    children: [
                      TableRow(
                        decoration: BoxDecoration(color: Colors.grey.shade200),
                        children: const [
                          Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              'Bucket',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              '200',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              '429',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              'Outros',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                      for (final entry in buckets.entries)
                        TableRow(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                entry.key,
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                '${entry.value.ok}',
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                '${entry.value.limited}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: entry.value.limited > 0
                                      ? _limColor
                                      : null,
                                  fontWeight: entry.value.limited > 0
                                      ? FontWeight.bold
                                      : null,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                '${entry.value.errors}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color:
                                      entry.value.errors > 0 ? _errColor : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _RlTick {
  _RlTick({
    required this.bucket,
    required this.code,
    required this.ms,
    required this.timestamp,
  });
  final String bucket;
  final int code;
  final int ms;
  final DateTime timestamp;
}

class _RlBucket {
  int ok = 0;
  int limited = 0;
  int errors = 0;
}
