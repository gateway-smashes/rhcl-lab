// req026 — Mobile-bank "Enviar comprovante" page (edição didática).
//
// Exercises the RHCL streaming controls from a real customer-facing flow
// AND doubles as a live demo of the req026 controls: preset payload
// sizes (below cap / above cap), a cap meter that fills as the upload
// progresses, and a rich response inspector that surfaces the
// `x-rhcl-streaming-cap` + `x-rhcl-observed-bytes` headers on 413 —
// the whole point of the streaming filter that req026 documents.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Entry passed from main.dart — the page reuses the same gateway URL,
/// API key and header conventions the dashboard already manages.
class ComprovantesPage extends StatefulWidget {
  const ComprovantesPage({
    super.key,
    required this.gatewayUrl,
    required this.apiKey,
  });

  final String gatewayUrl;
  final String apiKey;

  @override
  State<ComprovantesPage> createState() => _ComprovantesPageState();
}

/// Gateway-side cap enforced by the req026 EnvoyFilter (Lua streaming).
/// Kept as a constant here so the meter shows the same value the
/// filter enforces.
const int _kGatewayCapBytes = 32 * 1024 * 1024; // 32 MiB

/// Result of an upload — either a happy 2xx with an echoed sha256 or a
/// gateway/backend rejection carrying enough header/body context to
/// explain WHAT rejected it and WHY.
class _UploadResult {
  _UploadResult({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.bytesSent,
    required this.durationMs,
    this.sha256,
    this.bytesReceived,
    this.backendDurationMs,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final int bytesSent;
  final int durationMs;

  // Parsed from the JSON body when the backend echoes it (2xx path).
  final String? sha256;
  final int? bytesReceived;
  final int? backendDurationMs;

  bool get isOk => statusCode >= 200 && statusCode < 300;
  bool get isCapRejection => statusCode == 413;
  bool get isTimeout => statusCode == 408 || statusCode == 504;
  bool get isAuthDenied => statusCode == 401 || statusCode == 403;

  /// Gateway-side observed bytes when the request was rejected by the
  /// Lua streaming filter — the "you sent N bytes before the cap
  /// tripped" number.
  int? get rhclObservedBytes {
    final raw = headers['x-rhcl-observed-bytes'];
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  /// Cap the filter was enforcing, echoed back on 413.
  int? get rhclCapBytes {
    final raw = headers['x-rhcl-streaming-cap'];
    if (raw == null) return null;
    return int.tryParse(raw);
  }
}

/// Structured history entry — kept in-memory for the session so the
/// user can review multiple upload attempts side-by-side.
class _Comprovante {
  _Comprovante({
    required this.fileName,
    required this.result,
    required this.when,
  });

  final String fileName;
  final _UploadResult result;
  final DateTime when;

  String get shortSha {
    final s = result.sha256 ?? '';
    return s.length >= 12 ? s.substring(0, 12) : s;
  }
}

// ---- Helpers to format bytes / throughput --------------------------------
String _fmtBytes(int b) {
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(2)} MiB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KiB';
  return '$b B';
}

String _fmtThroughput(int bytes, int ms) {
  if (ms <= 0) return '—';
  final mibPerSec = (bytes / 1024 / 1024) / (ms / 1000);
  return '${mibPerSec.toStringAsFixed(1)} MiB/s';
}

class _ComprovantesPageState extends State<ComprovantesPage> {
  final List<_Comprovante> _items = [];
  bool _uploading = false;
  double _progress = 0.0; // 0..1
  int _bytesSent = 0;
  int _bytesTotal = 0;

  _UploadResult? _lastResult; // shown in the inspector while user hasn't cleared it
  String? _lastFileName;

  // -----------------------------------------------------------------
  // Payload generation — synthetic (from preset buttons) or real file
  // -----------------------------------------------------------------

  /// Generate `size` random-looking bytes fast enough to feel instant
  /// even at 50 MiB. Fills the buffer in 4-byte strides with a PRNG —
  /// content doesn't matter for the demo (the backend just SHA-256s
  /// it), only the byte count does.
  Uint8List _synthBytes(int size) {
    final rand = Random();
    final bytes = Uint8List(size);
    final view = ByteData.view(bytes.buffer);
    var i = 0;
    while (i + 4 <= size) {
      view.setUint32(i, rand.nextInt(0xFFFFFFFF));
      i += 4;
    }
    while (i < size) {
      bytes[i++] = rand.nextInt(256);
    }
    return bytes;
  }

  /// Browser file picker (kept from the previous implementation).
  Future<html.File?> _pickFile() {
    final completer = Completer<html.File?>();
    final input = html.FileUploadInputElement()..accept = '*/*';
    input.style.display = 'none';
    html.document.body?.append(input);
    StreamSubscription? sub;
    sub = input.onChange.listen((_) {
      sub?.cancel();
      input.remove();
      final files = input.files;
      completer.complete((files != null && files.isNotEmpty) ? files.first : null);
    });
    StreamSubscription? focusSub;
    focusSub = html.window.onFocus.listen((_) {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (!completer.isCompleted) {
          completer.complete(null);
          sub?.cancel();
          focusSub?.cancel();
          input.remove();
        } else {
          focusSub?.cancel();
        }
      });
    });
    input.click();
    return completer.future;
  }

  Future<Uint8List?> _readFileBytes(html.File file) {
    final completer = Completer<Uint8List?>();
    final reader = html.FileReader();
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is Uint8List) {
        completer.complete(result);
      } else if (result is List<int>) {
        completer.complete(Uint8List.fromList(result));
      } else {
        completer.complete(null);
      }
    });
    reader.onError.listen((_) => completer.complete(null));
    reader.readAsArrayBuffer(file);
    return completer.future;
  }

  // -----------------------------------------------------------------
  // Upload — XHR is used (not fetch) purely because upload.onProgress
  // is the only reliable way to draw the meter as bytes leave the
  // browser. Return an _UploadResult so the caller renders the
  // inspector with the FULL set of headers the gateway sent back.
  // -----------------------------------------------------------------
  Future<_UploadResult> _upload(Uint8List bytes, String label) async {
    final url = '${widget.gatewayUrl}/api/files/upload';
    final xhr = html.HttpRequest();
    xhr.open('POST', url, async: true);
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.setRequestHeader('x-client-app', 'red-bank-mobile');
    xhr.setRequestHeader(
      'x-flow-trace-id',
      'comprovante-${DateTime.now().millisecondsSinceEpoch}',
    );
    if (widget.apiKey.isNotEmpty) {
      xhr.setRequestHeader('api-key', widget.apiKey);
    }

    xhr.upload.onProgress.listen((event) {
      if (event.lengthComputable) {
        final loaded = event.loaded ?? 0;
        final total = event.total ?? 1;
        setState(() {
          _progress = loaded / total;
          _bytesSent = loaded;
          _bytesTotal = total;
        });
      }
    });

    final completer = Completer<_UploadResult>();
    final started = DateTime.now();

    void finish() {
      final duration = DateTime.now().difference(started).inMilliseconds;
      final headers = <String, String>{};
      // XHR returns headers as a big \r\n-separated blob — parse into a
      // case-insensitive lower-keyed map.
      final raw = xhr.getAllResponseHeaders() ?? '';
      for (final line in raw.split('\r\n')) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          headers[line.substring(0, idx).trim().toLowerCase()] =
              line.substring(idx + 1).trim();
        }
      }
      String? sha;
      int? bytesReceived;
      int? backendMs;
      try {
        if (xhr.status == 200 && (xhr.responseText ?? '').isNotEmpty) {
          final parsed = jsonDecode(xhr.responseText!) as Map<String, dynamic>;
          sha = parsed['sha256']?.toString();
          bytesReceived = (parsed['bytesReceived'] as num?)?.toInt();
          backendMs = (parsed['durationMs'] as num?)?.toInt();
        }
      } catch (_) {
        // Fall through — result exposes raw body regardless.
      }
      completer.complete(_UploadResult(
        statusCode: xhr.status ?? 0,
        headers: headers,
        body: xhr.responseText ?? '',
        bytesSent: bytes.length,
        durationMs: duration,
        sha256: sha,
        bytesReceived: bytesReceived,
        backendDurationMs: backendMs,
      ));
    }

    xhr.onLoad.listen((_) => finish());
    xhr.onError.listen((_) => finish());
    xhr.send(bytes);

    final result = await completer.future;

    // Register in history when the backend echoed a full receipt.
    if (result.isOk && result.sha256 != null && mounted) {
      _items.insert(
        0,
        _Comprovante(fileName: label, result: result, when: DateTime.now()),
      );
    }
    return result;
  }

  // -----------------------------------------------------------------
  // Demo entrypoints — 3 preset sizes + real file
  // -----------------------------------------------------------------
  Future<void> _runDemo(int mib) async {
    if (_uploading) return;
    final size = mib * 1024 * 1024;
    setState(() {
      _uploading = true;
      _progress = 0;
      _bytesSent = 0;
      _bytesTotal = size;
      _lastResult = null;
      _lastFileName = 'demo-$mib-MiB.bin';
    });
    // Give the UI one frame to render "gerando..." before we block on the
    // synth loop (which takes ~200ms for 50 MiB).
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final bytes = _synthBytes(size);
    final result = await _upload(bytes, 'demo-$mib-MiB.bin');
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _progress = 0;
      _lastResult = result;
    });
  }

  Future<void> _startRealFileUpload() async {
    if (_uploading) return;
    final file = await _pickFile();
    if (file == null) return;
    setState(() {
      _uploading = true;
      _progress = 0;
      _bytesSent = 0;
      _bytesTotal = file.size;
      _lastResult = null;
      _lastFileName = file.name;
    });
    final bytes = await _readFileBytes(file);
    if (bytes == null) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _lastResult = null;
      });
      return;
    }
    final result = await _upload(bytes, file.name);
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _progress = 0;
      _lastResult = result;
    });
  }

  // -----------------------------------------------------------------
  // UI
  // -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _explainerCard(theme),
            const SizedBox(height: 12),
            _demoScenariosCard(theme),
            const SizedBox(height: 12),
            _capMeter(theme),
            if (_lastResult != null) ...[
              const SizedBox(height: 12),
              _responseInspector(theme, _lastResult!),
            ],
            const SizedBox(height: 16),
            _historyList(theme),
          ],
        ),
      ),
    );
  }

  // Card at the top explaining what the demo is doing at the RHCL layer.
  Widget _explainerCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.upload_file, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Enviar comprovante · req026',
                    style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'O RHCL segura o body do upload em streaming (Lua bodyChunks) e '
              'aborta com HTTP 413 assim que a soma dos chunks passa de '
              '${_fmtBytes(_kGatewayCapBytes)}. O backend nunca recebe os '
              'bytes de uploads acima do cap.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(theme, 'cap = ${_fmtBytes(_kGatewayCapBytes)}',
                    theme.colorScheme.primaryContainer),
                _chip(theme, 'timeout HTTPRoute = 60 s',
                    theme.colorScheme.secondaryContainer),
                _chip(theme, 'header 413: x-rhcl-observed-bytes',
                    theme.colorScheme.errorContainer),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String label, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: theme.textTheme.labelSmall),
      );

  // Preset payload buttons + real file picker.
  Widget _demoScenariosCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cenários de demonstração', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Bytes aleatórios gerados no browser — não precisa de arquivo real.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _demoButton(theme,
                    label: '1 MiB', mib: 1, expected: '200', color: Colors.green),
                _demoButton(theme,
                    label: '25 MiB', mib: 25, expected: '200', color: Colors.green),
                _demoButton(theme,
                    label: '32 MiB', mib: 32, expected: '200/413', color: Colors.amber),
                _demoButton(theme,
                    label: '50 MiB', mib: 50, expected: '413', color: Colors.redAccent),
                _demoButton(theme,
                    label: '100 MiB', mib: 100, expected: '413', color: Colors.redAccent),
              ],
            ),
            const Divider(height: 24),
            Text('Ou envie um arquivo real:', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _uploading ? null : _startRealFileUpload,
              icon: const Icon(Icons.folder_open),
              label: const Text('Escolher arquivo'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _demoButton(
    ThemeData theme, {
    required String label,
    required int mib,
    required String expected,
    required Color color,
  }) {
    return OutlinedButton(
      onPressed: _uploading ? null : () => _runDemo(mib),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withOpacity(0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text('esperado: $expected',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // Cap meter — always visible; fills during upload and locks at the
  // final value after either 2xx or 413.
  Widget _capMeter(ThemeData theme) {
    final int shownBytes = _uploading ? _bytesSent : (_lastResult?.bytesSent ?? 0);
    final int total = _uploading ? _bytesTotal : (_lastResult?.bytesSent ?? _kGatewayCapBytes);
    final capFraction =
        (_kGatewayCapBytes / (total > _kGatewayCapBytes ? total : _kGatewayCapBytes));
    final progressFraction = total > 0 ? shownBytes / total : 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Progresso do upload',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final barW = constraints.maxWidth;
                return SizedBox(
                  height: 24,
                  child: Stack(
                    children: [
                      // Background rail
                      Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      // Cap marker (red dashed line at 32 MiB position)
                      Positioned(
                        left: barW * capFraction - 1,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 2,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      // Progress fill
                      Container(
                        width: barW * progressFraction.clamp(0, 1).toDouble(),
                        decoration: BoxDecoration(
                          color: shownBytes > _kGatewayCapBytes
                              ? theme.colorScheme.errorContainer
                              : theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      // Cap label
                      Positioned(
                        left: barW * capFraction + 4,
                        top: -2,
                        child: Text('cap',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w700,
                            )),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${_fmtBytes(shownBytes)}',
                    style: theme.textTheme.bodyMedium),
                Text('total: ${_fmtBytes(total)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Rich response inspector — one card that renders differently per
  // status class. This is the didactic centerpiece.
  Widget _responseInspector(ThemeData theme, _UploadResult r) {
    final Color statusColor;
    final IconData statusIcon;
    final String statusTitle;

    if (r.isOk) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusTitle = 'HTTP ${r.statusCode} · aceito pelo backend';
    } else if (r.isCapRejection) {
      statusColor = Colors.redAccent;
      statusIcon = Icons.block;
      statusTitle = 'HTTP 413 · gateway RHCL rejeitou';
    } else if (r.isTimeout) {
      statusColor = Colors.orangeAccent;
      statusIcon = Icons.timer_off;
      statusTitle = 'HTTP ${r.statusCode} · timeout do upload';
    } else if (r.isAuthDenied) {
      statusColor = Colors.deepOrange;
      statusIcon = Icons.lock;
      statusTitle = 'HTTP ${r.statusCode} · acesso negado';
    } else {
      statusColor = theme.colorScheme.error;
      statusIcon = Icons.error;
      statusTitle = 'HTTP ${r.statusCode}';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(statusTitle,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Metric row
            _metricGrid(theme, r),

            // 413 gateway explanation — the punchline of req026
            if (r.isCapRejection) ...[
              const SizedBox(height: 12),
              _capRejectionPanel(theme, r),
            ],

            // Timeout explanation
            if (r.isTimeout) ...[
              const SizedBox(height: 12),
              _timeoutPanel(theme, r),
            ],

            // Success: SHA-256 + backend echo
            if (r.isOk && r.sha256 != null) ...[
              const SizedBox(height: 12),
              _successPanel(theme, r),
            ],

            // Auth denied
            if (r.isAuthDenied) ...[
              const SizedBox(height: 12),
              _authPanel(theme, r),
            ],

            // Response headers viewer (always visible, collapsible)
            const SizedBox(height: 12),
            _headersViewer(theme, r),
          ],
        ),
      ),
    );
  }

  Widget _metricGrid(ThemeData theme, _UploadResult r) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _metric(theme, 'bytes enviados', _fmtBytes(r.bytesSent)),
        if (r.bytesReceived != null)
          _metric(theme, 'bytes no backend', _fmtBytes(r.bytesReceived!)),
        _metric(theme, 'tempo total', '${r.durationMs} ms'),
        _metric(theme, 'throughput', _fmtThroughput(r.bytesSent, r.durationMs)),
      ],
    );
  }

  Widget _metric(ThemeData theme, String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    letterSpacing: 0.05,
                    fontSize: 10)),
            const SizedBox(height: 2),
            Text(value,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      );

  Widget _capRejectionPanel(ThemeData theme, _UploadResult r) {
    final cap = r.rhclCapBytes;
    final observed = r.rhclObservedBytes;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        border: Border.all(color: Colors.red.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('O que aconteceu no gateway',
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: Colors.red.shade900, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'O filtro Lua do RHCL foi somando os bytes chunk-a-chunk. '
            'Assim que o contador ultrapassou o cap, o gateway '
            'respondeu 413 e parou de solicitar bytes do cliente. '
            'O backend não recebeu absolutamente nada dessa request.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (cap != null || observed != null) ...[
            Row(children: [
              Expanded(
                child: _bigStat(theme,
                    label: 'x-rhcl-streaming-cap',
                    value: cap != null ? _fmtBytes(cap) : '—',
                    color: Colors.red.shade900),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigStat(theme,
                    label: 'x-rhcl-observed-bytes',
                    value: observed != null ? _fmtBytes(observed) : '—',
                    color: Colors.red.shade900),
              ),
            ]),
            const SizedBox(height: 8),
            if (observed != null && cap != null && observed < r.bytesSent) ...[
              Text(
                'Repare: o gateway parou de ler no chunk que passou do cap '
                '(${_fmtBytes(observed)}), MENOS que o que você tentou enviar '
                '(${_fmtBytes(r.bytesSent)}). Isso é a prova de que a validação '
                'foi streaming — não buferizada.',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic, color: Colors.red.shade900),
              ),
            ],
          ] else ...[
            Text(
              'Nota: response veio sem os headers x-rhcl-* — provavelmente esta '
              'versão do EnvoyFilter é antiga ou o gateway ainda não foi atualizado.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  Widget _timeoutPanel(ThemeData theme, _UploadResult r) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border.all(color: Colors.orange.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Timeout do upload',
              style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.orange.shade900, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'O HTTPRoute do req026 tem timeouts.request = 60s. O upload '
            'inteiro (cliente → gateway → backend → resposta) precisa '
            'terminar dentro desse período. Este atingiu ${r.durationMs} ms.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _successPanel(ThemeData theme, _UploadResult r) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SHA-256 assinado pelo backend',
              style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.green.shade900, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SelectableText(
            r.sha256 ?? '',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Colors.green.shade900,
            ),
          ),
          const SizedBox(height: 8),
          if (r.backendDurationMs != null)
            Text('Backend gastou ${r.backendDurationMs} ms streamando + '
                'hashando os bytes.',
                style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _authPanel(ThemeData theme, _UploadResult r) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'A chave em uso não foi aceita pelo Authorino. Confira o painel '
        'de endpoints do POC Console.',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Widget _bigStat(ThemeData theme,
      {required String label, required String value, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace', color: theme.colorScheme.outline)),
          const SizedBox(height: 2),
          Text(value,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _headersViewer(ThemeData theme, _UploadResult r) {
    return Theme(
      // Kill the default ExpansionTile borders / trailing color mismatches.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8, bottom: 8),
        title: Text('Response headers (${r.headers.length})',
            style: theme.textTheme.titleSmall),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              r.headers.isEmpty
                  ? '(vazio)'
                  : r.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyList(ThemeData theme) {
    if (_items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Comprovantes aceitos aparecem aqui. Rode um cenário acima ou envie um arquivo real.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Histórico (${_items.length})', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        ..._items.map((c) => Card(
              child: ListTile(
                leading: const Icon(Icons.receipt_long),
                title: Text(c.fileName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  'sha ${c.shortSha}… · ${_fmtBytes(c.result.bytesSent)} · '
                  '${c.result.durationMs} ms',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                trailing: Text(
                  '${c.when.hour.toString().padLeft(2, '0')}:'
                  '${c.when.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            )),
      ],
    );
  }
}
