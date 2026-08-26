import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _apiBase = '/api/v1';

void main() {
  runApp(const RhoaiAssistantApp());
}

class RhoaiAssistantApp extends StatelessWidget {
  const RhoaiAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RHOAI Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFEE0000)),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  String _selectedModel = 'auto';

  void _selectModel(String modelId) {
    setState(() {
      _selectedModel = modelId;
      _tab = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RHOAI Assistant'),
        backgroundColor: const Color(0xFFEE0000),
        foregroundColor: Colors.white,
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          ChatScreen(
            selectedModel: _selectedModel,
            onModelChanged: (model) => setState(() => _selectedModel = model),
          ),
          ModelSelectionScreen(
            selectedModelId: _selectedModel,
            onSelectModel: _selectModel,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.model_training), label: 'Select model'),
        ],
      ),
    );
  }
}

// ─── Errors ─────────────────────────────────────────────────────────────────

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int? statusCode;
  final String message;

  @override
  String toString() => message;
}

String formatStreamError(Map<String, dynamic> data) {
  final statusCode = data['statusCode'];
  final code = data['code'] as String?;
  final message = data['message'] as String?;
  if (statusCode == 429 || code == 'RATE_LIMITED') {
    return message ??
        'Rate limit reached (HTTP 429). Token quota exceeded for this model. '
            'Wait for the limit window to reset or choose another model.';
  }
  if (statusCode == 503 || code == 'UPSTREAM_UNAVAILABLE') {
    return message ?? 'Model upstream temporarily unavailable (HTTP 503). Try again later.';
  }
  if (message != null && message.isNotEmpty) return message;
  return 'An error occurred during inference.';
}

String formatUserError(Object error) {
  if (error is ApiException) return error.message;
  final raw = error.toString();
  if (raw.contains('HTTP 429') ||
      raw.contains('RATE_LIMITED') ||
      raw.toLowerCase().contains('too many requests') ||
      raw.toLowerCase().contains('rate limit reached')) {
    return 'Rate limit reached (HTTP 429). Token quota exceeded for this model. '
        'Wait for the limit window to reset or choose another model.';
  }
  if (raw.contains('ClientException') && raw.contains('network error')) {
    return 'The streaming connection was interrupted before the response finished. '
        'If you hit the model token quota, retry after the rate-limit window resets.';
  }
  if (raw.contains('ERR_INCOMPLETE_CHUNKED_ENCODING')) {
    return 'The server closed the response stream early (incomplete chunked encoding). '
        'The model upstream may be unavailable or restarting. Try again or pick another model.';
  }
  if (raw.contains('HTTP 429') || raw.contains('rate limit') || raw.contains('too many requests')) {
    return 'Rate limit reached (HTTP 429). Token quota exceeded for this model. '
        'Wait for the limit window to reset or choose another model.';
  }
  if (raw.contains('HTTP 503') || raw.contains('upstream connect error')) {
    return 'Model upstream is temporarily unavailable (HTTP 503). Try again or select another model.';
  }
  if (raw.contains('All models in fallback chain failed')) {
    return raw.startsWith('Exception: ') ? raw.substring(11) : raw;
  }
  if (raw.startsWith('Exception: ')) return raw.substring(11);
  return raw;
}

String parseApiErrorBody(String body) {
  if (body.isEmpty) return 'Unknown error';
  try {
    final json = jsonDecode(body);
    if (json is Map) {
      final err = json['error'] ?? json['message'] ?? json['detail'];
      if (err != null) return err.toString();
    }
  } catch (_) {}
  return body.length > 280 ? '${body.substring(0, 280)}…' : body;
}

void showErrorSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade800,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Dismiss',
        textColor: Colors.white,
        onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
      ),
    ),
  );
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.onDismiss, this.onRetry});

  final String message;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade800, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Error',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.red.shade900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(message, style: TextStyle(color: Colors.red.shade900, fontSize: 13)),
                ],
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            if (onDismiss != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.red.shade800,
                onPressed: onDismiss,
                tooltip: 'Dismiss',
              ),
          ],
        ),
      ),
    );
  }
}

// ─── API client ─────────────────────────────────────────────────────────────

class ApiClient {
  Never _throwApiError(int statusCode, String body, String context) {
    throw ApiException(statusCode, '$context: $statusCode — ${parseApiErrorBody(body)}');
  }

  Future<Map<String, dynamic>> createConversation({String requestedModel = 'auto'}) async {
    final r = await http.post(
      Uri.parse('$_apiBase/conversations'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'title': 'Chat', 'requestedModel': requestedModel}),
    );
    if (r.statusCode != 201) _throwApiError(r.statusCode, r.body, 'Failed to start conversation');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> postMessage(
    String conversationId,
    String content, {
    String? requestedModel,
  }) async {
    final body = <String, dynamic>{'content': content};
    if (requestedModel != null) body['requestedModel'] = requestedModel;
    final r = await http.post(
      Uri.parse('$_apiBase/conversations/$conversationId/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode != 200) _throwApiError(r.statusCode, r.body, 'Failed to send message');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> cancel(String conversationId, String requestId) async {
    final r = await http.post(
      Uri.parse('$_apiBase/conversations/$conversationId/cancel'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'requestId': requestId}),
    );
    if (r.statusCode != 200) _throwApiError(r.statusCode, r.body, 'Failed to cancel request');
  }

  Future<List<dynamic>> listModels() async {
    final r = await http.get(Uri.parse('$_apiBase/models'));
    if (r.statusCode != 200) _throwApiError(r.statusCode, r.body, 'Failed to load models');
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<void> synchronizeModels() async {
    final r = await http.post(Uri.parse('$_apiBase/models/synchronize'));
    if (r.statusCode != 200) _throwApiError(r.statusCode, r.body, 'Failed to sync models');
  }

  Stream<SseEvent> streamEvents(String conversationId, String requestId) async* {
    final client = http.Client();
    try {
      final request = http.Request(
        'GET',
        Uri.parse('$_apiBase/conversations/$conversationId/stream?requestId=$requestId'),
      );
      request.headers['Accept'] = 'text/event-stream';
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw ApiException(response.statusCode, 'Stream failed: ${parseApiErrorBody(body)}');
      }

      final buffer = StringBuffer();

      try {
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          buffer.write(chunk);
          final text = buffer.toString();
          final parts = text.split('\n\n');
          buffer.clear();
          if (!text.endsWith('\n\n') && parts.isNotEmpty) {
            buffer.write(parts.removeLast());
          }
          for (final block in parts) {
            if (block.trim().isEmpty) continue;
            String? name;
            String? data;
            for (final line in block.split('\n')) {
              if (line.startsWith('event:')) {
                name = line.substring(6).trim();
              } else if (line.startsWith('data:')) {
                data = line.substring(5).trim();
              }
            }
            if (name != null && data != null) {
              yield SseEvent(name, jsonDecode(data) as Map<String, dynamic>);
            }
          }
        }
      } on http.ClientException catch (e) {
        throw ApiException(null, formatUserError(e));
      }
    } finally {
      client.close();
    }
  }
}

class SseEvent {
  final String name;
  final Map<String, dynamic> data;
  SseEvent(this.name, this.data);
}

// ─── Chat screen ────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.selectedModel,
    required this.onModelChanged,
  });

  final String selectedModel;
  final ValueChanged<String> onModelChanged;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _api = ApiClient();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  String? _conversationId;
  List<Map<String, dynamic>> _models = [];
  final List<_ChatLine> _lines = [];
  bool _streaming = false;
  String? _activeRequestId;
  String? _activeModel;
  String? _activeProvider;
  String? _activeRuntime;
  String? _modelChangeBanner;
  String? _errorBanner;
  String? _lastStreamError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedModel != widget.selectedModel && _conversationId != null) {
      setState(() => _errorBanner = null);
    }
  }

  Future<void> _init() async {
    setState(() {
      _errorBanner = null;
    });
    try {
      final conv = await _api.createConversation(requestedModel: widget.selectedModel);
      final models = await _api.listModels();
      if (!mounted) return;
      setState(() {
        _conversationId = conv['id'] as String;
        _models = models.cast<Map<String, dynamic>>();
        _errorBanner = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorBanner = formatUserError(e);
      });
    }
  }

  void _showError(String message, {int? assistantIndex}) {
    setState(() {
      _errorBanner = message;
      if (assistantIndex != null && assistantIndex >= 0 && assistantIndex < _lines.length) {
        _lines[assistantIndex] = _ChatLine.error(message);
      }
    });
    _scrollToEnd();
    showErrorSnackBar(context, message);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _conversationId == null || _streaming) return;
    _input.clear();
    setState(() {
      _streaming = true;
      _modelChangeBanner = null;
      _errorBanner = null;
      _lastStreamError = null;
      _lines.add(_ChatLine.user(text));
      _lines.add(_ChatLine.assistant('', streaming: true));
    });
    _scrollToEnd();

    try {
      final submission = await _api.postMessage(
        _conversationId!,
        text,
        requestedModel: widget.selectedModel == 'auto' ? null : widget.selectedModel,
      );
      final requestId = submission['requestId'] as String;
      _activeRequestId = requestId;
      setState(() {
        _activeModel = submission['selectedModel'] as String?;
        _activeProvider = submission['provider'] as String?;
        _activeRuntime = submission['runtime'] as String?;
      });

      final assistantIndex = _lines.length - 1;
      var assistantText = '';

      await for (final event in _api.streamEvents(_conversationId!, requestId)) {
        if (!mounted) break;
        switch (event.name) {
          case 'model.selected':
            setState(() {
              _activeModel = event.data['selectedModel'] as String?;
              _activeProvider = event.data['provider'] as String?;
              _activeRuntime = event.data['runtime'] as String?;
            });
            break;
          case 'model.changed':
            setState(() {
              _modelChangeBanner =
                  'Model changed: ${event.data['fromModel']} → ${event.data['toModel']} '
                  '(${event.data['reason']})';
              _activeModel = event.data['toModel'] as String?;
            });
            break;
          case 'message.delta':
            assistantText += event.data['content'] as String? ?? '';
            setState(() {
              _lines[assistantIndex] = _ChatLine.assistant(assistantText, streaming: true);
            });
            _scrollToEnd();
            break;
          case 'message.completed':
            final status = event.data['status'] as String? ?? 'COMPLETED';
            if (status == 'FAILED') {
              final errMsg = _lastStreamError ??
                  event.data['error'] as String? ??
                  (assistantText.isNotEmpty
                      ? assistantText
                      : 'The model failed to complete this response.');
              _showError(errMsg, assistantIndex: assistantIndex);
            } else {
              setState(() {
                _lines[assistantIndex] = _ChatLine.assistant(assistantText);
              });
            }
            break;
          case 'error':
            final errMsg = formatStreamError(event.data);
            _lastStreamError = errMsg;
            _showError(errMsg, assistantIndex: assistantIndex);
            break;
        }
      }
    } catch (e) {
      _showError(formatUserError(e), assistantIndex: _lines.length - 1);
    } finally {
      setState(() {
        _streaming = false;
        _activeRequestId = null;
      });
    }
  }

  Future<void> _stop() async {
    if (_conversationId != null && _activeRequestId != null) {
      await _api.cancel(_conversationId!, _activeRequestId!);
    }
    setState(() => _streaming = false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_errorBanner != null)
          ErrorBanner(
            message: _errorBanner!,
            onDismiss: () => setState(() => _errorBanner = null),
            onRetry: _conversationId == null ? _init : null,
          ),
        if (_modelChangeBanner != null)
          MaterialBanner(
            content: Text(_modelChangeBanner!),
            leading: const Icon(Icons.swap_horiz, color: Color(0xFFEE0000)),
            actions: [
              TextButton(onPressed: () => setState(() => _modelChangeBanner = null), child: const Text('Dismiss')),
            ],
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Text('Model:'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: widget.selectedModel,
                items: [
                  const DropdownMenuItem(value: 'auto', child: Text('Auto (router)')),
                  ..._models.map((m) => DropdownMenuItem(
                        value: m['id'] as String,
                        child: Text(m['displayName'] as String? ?? m['id'] as String),
                      )),
                ],
                onChanged: _streaming
                    ? null
                    : (v) => widget.onModelChanged(v ?? 'auto'),
              ),
              const Spacer(),
              if (_activeModel != null)
                Text(
                  '$_activeModel · $_activeProvider · $_activeRuntime',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _lines.length,
            itemBuilder: (_, i) => _lines[i].build(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    hintText: 'Type a message…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                  enabled: !_streaming && _conversationId != null,
                ),
              ),
              const SizedBox(width: 8),
              if (_streaming)
                IconButton.filled(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                  style: IconButton.styleFrom(backgroundColor: Colors.red),
                )
              else
                IconButton.filled(
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(backgroundColor: const Color(0xFFEE0000)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatLine {
  final String role;
  final String text;
  final bool streaming;

  _ChatLine._(this.role, this.text, {this.streaming = false});
  factory _ChatLine.user(String t) => _ChatLine._('user', t);
  factory _ChatLine.assistant(String t, {bool streaming = false}) =>
      _ChatLine._('assistant', t, streaming: streaming);
  factory _ChatLine.error(String t) => _ChatLine._('error', t);

  Widget build(BuildContext context) {
    if (role == 'error') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
          decoration: BoxDecoration(
            color: Colors.red.shade50,
            border: Border.all(color: Colors.red.shade200),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade800, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final isUser = role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFEE0000).withValues(alpha: 0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$text${streaming ? '▌' : ''}'),
      ),
    );
  }
}

// ─── Model selection screen ─────────────────────────────────────────────────

class ModelSelectionScreen extends StatefulWidget {
  const ModelSelectionScreen({
    super.key,
    required this.selectedModelId,
    required this.onSelectModel,
  });

  final String selectedModelId;
  final ValueChanged<String> onSelectModel;

  @override
  State<ModelSelectionScreen> createState() => _ModelSelectionScreenState();
}

class _ModelSelectionScreenState extends State<ModelSelectionScreen> {
  final _api = ApiClient();
  List<Map<String, dynamic>> _models = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool sync = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (sync) {
        await _api.synchronizeModels();
      }
      final models = await _api.listModels();
      setState(() {
        _models = models.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = formatUserError(e);
        _loading = false;
      });
      showErrorSnackBar(context, formatUserError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: Colors.red.shade300),
              const SizedBox(height: 12),
              Text(
                'Could not load models',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade900, fontSize: 13),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _load(sync: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFEE0000),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(sync: true),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'External Models (OpenShift AI MaaS)',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Models are discovered from ExternalModel CRs on the cluster. '
            'Select one to use in the Chat tab.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _load(sync: true),
                icon: const Icon(Icons.sync),
                label: const Text('Sync from cluster'),
              ),
              const SizedBox(width: 8),
              if (widget.selectedModelId != 'auto')
                Chip(
                  avatar: const Icon(Icons.check_circle, size: 18, color: Color(0xFFEE0000)),
                  label: Text('Active: ${widget.selectedModelId}'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ..._models.map((m) => _modelCard(m)),
        ],
      ),
    );
  }

  Widget _modelCard(Map<String, dynamic> m) {
    final id = m['id'] as String;
    final status = m['status'] as String? ?? 'UNKNOWN';
    final selected = widget.selectedModelId == id;
    final color = status == 'AVAILABLE'
        ? Colors.green
        : status == 'UNAVAILABLE'
            ? Colors.red
            : Colors.orange;

    return Card(
      elevation: selected ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? const BorderSide(color: Color(0xFFEE0000), width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    m['displayName'] as String? ?? id,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(
                  label: Text(status, style: const TextStyle(fontSize: 11)),
                  backgroundColor: color.withValues(alpha: 0.15),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('targetModel: $id', style: Theme.of(context).textTheme.bodySmall),
            if (m['externalModelResource'] != null)
              Text(
                'ExternalModel: ${m['externalModelResource']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            Text(
              'MaaS path: ${m['endpoint']}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: status == 'UNAVAILABLE' ? null : () => widget.onSelectModel(id),
                  icon: Icon(selected ? Icons.check : Icons.chat),
                  label: Text(selected ? 'Selected' : 'Use in chat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEE0000),
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => widget.onSelectModel('auto'),
                  child: const Text('Auto'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
