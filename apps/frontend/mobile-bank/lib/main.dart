import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'poc_console.dart';

void main() {
  runApp(const BankingApp());
}

class BankingApp extends StatefulWidget {
  const BankingApp({super.key});

  @override
  State<BankingApp> createState() => _BankingAppState();
}

class _BankingAppState extends State<BankingApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _onThemeModeChanged(ThemeMode mode) {
    setState(() {
      _themeMode = mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Red Hat Digital Bank',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFB30000),
        useMaterial3: true,
      ),
      home: DashboardPage(
        themeMode: _themeMode,
        onThemeModeChanged: _onThemeModeChanged,
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _client = http.Client();
  static const _defaultDirectBackendUrl = String.fromEnvironment(
    'PRIMARY_BACKEND_URL',
    defaultValue: 'http://localhost:8080',
  );
  static const _defaultRhclGatewayUrl = String.fromEnvironment(
    'RHCL_GATEWAY_URL',
    defaultValue:
        'https://banking-api-connectivity.apps.cluster-qrcrl.qrcrl.sandbox2852.opentlc.com',
  );
  static const _defaultMcpGatewayUrl = String.fromEnvironment(
    'MCP_GATEWAY_URL',
    defaultValue: '',
  );
  static const _defaultRhclApiKey = String.fromEnvironment(
    'RHCL_API_KEY',
    defaultValue: '',
  );
  static const _storagePrimaryUrlKey = 'redbank.primaryBackendUrl';
  static const _storageEndpointProfileKey = 'redbank.endpointProfile';
  static const _storageDirectBackendUrlKey = 'redbank.directBackendUrl';
  static const _storageRhclGatewayUrlKey = 'redbank.rhclGatewayUrl';
  static const _storageRhclApiKeyKey = 'redbank.rhclApiKey';
  static const _profileDirectBackend = 'direct_backend';
  static const _profileRhclGateway = 'rhcl_gateway';
  final _primaryController = TextEditingController(
    text: _defaultDirectBackendUrl,
  );
  String _endpointProfile = _profileDirectBackend;
  String _directBackendUrl = _defaultDirectBackendUrl;
  String _rhclGatewayUrl = _defaultRhclGatewayUrl;
  String _rhclApiKey = '';

  bool _loading = false;
  String _message = '';
  List<dynamic> _banks = [];
  double _investments = 0;
  double _total = 0;
  final _random = Random();
  final List<Map<String, String>> _transferHistory = [];
  html.WebSocket? _wsPrimary;
  StreamSubscription<html.Event>? _wsPrimaryOpenSub;
  StreamSubscription<html.Event>? _wsPrimaryCloseSub;
  StreamSubscription<html.Event>? _wsPrimaryErrorSub;
  StreamSubscription<html.MessageEvent>? _wsPrimaryMessageSub;
  bool _wsPrimaryConnected = false;
  Timer? _wsReconnectTimer;
  int _wsReconnectAttempt = 0;
  bool _autoResetInProgress = false;
  bool _echoLoading = false;
  String _echoOutput = 'No echo response yet.';
  bool _balanceJustUpdated = false;
  String _wsTransferId = '';
  String _wsTransferStatus = '';
  String _wsTransferAmount = '';
  String _wsTransferFromBank = '';
  String _wsTransferToBank = '';

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectLiveFeed();
      _loadInitialData();
    });
  }

  @override
  void dispose() {
    _closeWebSockets();
    _client.close();
    _primaryController.dispose();
    super.dispose();
  }

  Future<bool> _loadData({bool showSuccessMessage = false}) async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      final traceId = _newTraceId('summary');
      final response = await _fetchSummary(
        _buildApiUrl('/api/v1/accounts/summary'),
        traceId: traceId,
      );
      final responses = <Map<String, dynamic>>[response];

      final mergedBanks = responses
          .expand((response) => response['banks'] as List<dynamic>? ?? [])
          .toList();

      final totalInvestments = responses.fold<double>(
        0,
        (sum, response) => sum + _toDouble(response['investments']),
      );

      final bankBalance = mergedBanks.fold<double>(
        0,
        (sum, item) =>
            sum + _toDouble((item as Map<String, dynamic>)['balance']),
      );

      setState(() {
        _banks = mergedBanks;
        _investments = totalInvestments;
        _total = bankBalance + _investments;
        if (showSuccessMessage) {
          _message = 'Dados atualizados com sucesso';
        }
      });
      final bbBalance = _currentBbBalance();
      if (bbBalance < 50 && !_autoResetInProgress) {
        _autoResetInProgress = true;
        await _resetBankAccount(bankName: 'Example Bank', automatic: true);
        _autoResetInProgress = false;
      }
      return true;
    } catch (e) {
      setState(() {
        _message = 'Falha ao buscar dados: $e';
      });
      return false;
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _loadInitialData() async {
    // Startup retry avoids requiring manual "Refresh" when backend is still warming up.
    for (var attempt = 0; attempt < 3; attempt++) {
      final ok = await _loadData();
      if (ok) return;
      await Future.delayed(const Duration(milliseconds: 900));
    }
  }

  Future<Map<String, dynamic>> _fetchSummary(
    String url, {
    required String traceId,
  }) async {
    final response = await _client.get(
      Uri.parse(url),
      headers: _buildHeaders(traceId),
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} em $url');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _simulateTransfer() async {
    const fromBank = 'Example Bank';
    const toBank = 'EXTERNAL';
    final displayToBank = _displayBankName(toBank);
    final availableBalance = _currentBbBalance();
    if (availableBalance <= 0) {
      setState(() {
        _message = 'Transfer blocked: no available balance in $fromBank.';
      });
      return;
    }
    final selectedAmount = _pickSmallTransferAmount(availableBalance);

    setState(() {
      _loading = true;
      _message = '';
      _wsTransferStatus = '';
    });

    try {
      final traceId = _newTraceId('transfer');
      final response = await _client.post(
        Uri.parse(_buildApiUrl('/api/v1/transfers')),
        headers: _buildHeaders(traceId, json: true),
        body: jsonEncode({
          'fromBank': fromBank,
          'toBank': toBank,
          'amount': selectedAmount,
          'description': 'External random transfer simulation',
          'clientTraceId': traceId,
        }),
      );

      if (response.statusCode == 200) {
        String status = 'UNKNOWN';
        try {
          final payload = jsonDecode(response.body) as Map<String, dynamic>;
          status = payload['status']?.toString() ?? 'UNKNOWN';
          if (status == 'REJECTED') {
            final reason = payload['reason']?.toString() ?? 'Unknown reason';
            _message =
                'Transfer rejected: R\$ ${selectedAmount.toStringAsFixed(2)} from $fromBank to $displayToBank ($reason)';
          } else {
            _message =
                'Transfer sent: R\$ ${selectedAmount.toStringAsFixed(2)} from $fromBank to $displayToBank (status: $status)';
          }
        } catch (_) {
          _message =
              'Transfer sent: R\$ ${selectedAmount.toStringAsFixed(2)} from $fromBank to $displayToBank';
        }
        setState(() {
          if (status != 'REJECTED') {
            _message =
                'Transfer sent: R\$ ${selectedAmount.toStringAsFixed(2)} from $fromBank to $displayToBank';
          }
        });
        // Always refresh from HTTP after transfer to keep totals consistent even
        // if websocket events are delayed/dropped by network hiccups.
        await Future.delayed(const Duration(milliseconds: 2300));
        if (mounted) {
          await _loadData();
        }
      } else {
        setState(() {
          _message =
              'Transfer failed: HTTP ${response.statusCode} (R\$ ${selectedAmount.toStringAsFixed(2)})';
        });
      }
    } catch (e) {
      setState(() {
        _message = 'Transfer failed: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _resetBankAccount({
    required String bankName,
    bool automatic = false,
  }) async {
    try {
      final traceId = _newTraceId('reset');
      final response = await _client.post(
        Uri.parse(_buildApiUrl('/api/v1/accounts/reset')),
        headers: _buildHeaders(traceId, json: true),
        body: jsonEncode({'bankName': bankName, 'clientTraceId': traceId}),
      );

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final status = payload['status']?.toString() ?? 'UNKNOWN';
        final balance = payload['balance']?.toString() ?? '-';
        setState(() {
          _message = automatic
              ? 'Auto reset executed: $bankName restored to R\$ $balance'
              : 'Reset executed: $bankName restored to R\$ $balance (status: $status)';
        });
      } else {
        setState(() {
          _message = 'Reset failed: HTTP ${response.statusCode} for $bankName';
        });
      }
    } catch (e) {
      setState(() {
        _message = 'Reset failed: $e';
      });
    } finally {
      await _loadData();
    }
  }

  String _newTraceId(String prefix) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = _random.nextInt(99999).toString().padLeft(5, '0');
    return '$prefix-$now-$rand';
  }

  double _toDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return double.tryParse(value.toString()) ?? 0;
  }

  double _currentBbBalance() {
    for (final bank in _banks) {
      final item = bank as Map<String, dynamic>;
      if (item['bankName']?.toString() == 'Example Bank') {
        return _toDouble(item['balance']);
      }
    }
    return 0;
  }

  String _displayBankName(String bankName) {
    return bankName.toUpperCase() == 'EXTERNAL' ? 'External Bank' : bankName;
  }

  double _pickSmallTransferAmount(double availableBalance) {
    // Picks a small amount proportional to current balance (2%-12%),
    // capped to keep demo transfers readable.
    final minAmount = max(10.0, availableBalance * 0.02);
    final maxAmount = min(availableBalance, max(50.0, availableBalance * 0.12));
    if (maxAmount <= minAmount) {
      return double.parse(max(1.0, availableBalance).toStringAsFixed(2));
    }
    final range = maxAmount - minAmount;
    final amount = minAmount + (_random.nextDouble() * range);
    return double.parse(amount.toStringAsFixed(2));
  }

  void _addTransferHistory({
    required double amount,
    required String status,
    required String source,
    required String fromBank,
    required String toBank,
  }) {
    final now = DateTime.now();
    final timeLabel =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final item = <String, String>{
      'amount': 'R\$ ${amount.toStringAsFixed(2)}',
      'status': status,
      'source': source,
      'from': fromBank,
      'to': _displayBankName(toBank),
      'time': timeLabel,
    };

    setState(() {
      _transferHistory.insert(0, item);
      if (_transferHistory.length > 5) {
        _transferHistory.removeLast();
      }
    });
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            final apiKeyController = TextEditingController(text: _rhclApiKey);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ThemeMode>(
                      value: widget.themeMode,
                      decoration: const InputDecoration(
                        labelText: 'Theme',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: ThemeMode.light,
                          child: Text('Light'),
                        ),
                        DropdownMenuItem(
                          value: ThemeMode.dark,
                          child: Text('Dark'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        widget.onThemeModeChanged(value);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: _endpointProfile,
                      decoration: const InputDecoration(
                        labelText: 'Request route',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: _profileDirectBackend,
                          child: Text('Direct backend'),
                        ),
                        DropdownMenuItem(
                          value: _profileRhclGateway,
                          child: Text('RHCL gateway'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _endpointProfile = value;
                          _primaryController.text = _profileUrl(value);
                        });
                        modalSetState(() {});
                        _saveSettings();
                        _connectLiveFeed();
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _primaryController,
                      onChanged: (value) {
                        if (_endpointProfile == _profileDirectBackend) {
                          _directBackendUrl = value.trim();
                        } else {
                          _rhclGatewayUrl = value.trim();
                        }
                        _saveSettings();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Backend endpoint',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_endpointProfile == _profileRhclGateway) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: apiKeyController,
                        obscureText: false,
                        onChanged: (value) {
                          _rhclApiKey = value.trim();
                          _saveSettings();
                        },
                        decoration: const InputDecoration(
                          labelText: 'API key',
                          hintText: 'Enter the RHCL gateway API key',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.vpn_key),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    _connectLiveFeed();
  }

  void _loadSavedSettings() {
    final storage = html.window.localStorage;
    final savedPrimary = storage[_storagePrimaryUrlKey];
    final savedProfile = storage[_storageEndpointProfileKey];
    final savedDirectUrl = storage[_storageDirectBackendUrlKey];
    final savedRhclGatewayUrl = storage[_storageRhclGatewayUrlKey];

    if (savedDirectUrl != null && savedDirectUrl.isNotEmpty) {
      _directBackendUrl = pocApiBase(savedDirectUrl);
    }
    if (savedRhclGatewayUrl != null && savedRhclGatewayUrl.isNotEmpty) {
      _rhclGatewayUrl = pocApiBase(savedRhclGatewayUrl);
    }
    final savedApiKey = storage[_storageRhclApiKeyKey];
    if (savedApiKey != null && savedApiKey.isNotEmpty) {
      _rhclApiKey = savedApiKey;
    } else if (_defaultRhclApiKey.isNotEmpty) {
      _rhclApiKey = _defaultRhclApiKey;
    }
    if (savedProfile == _profileDirectBackend ||
        savedProfile == _profileRhclGateway) {
      _endpointProfile = savedProfile!;
    } else if (!_isLocalBrowser()) {
      _endpointProfile = _profileRhclGateway;
    }
    if (!_isLocalBrowser() &&
        _endpointProfile == _profileDirectBackend &&
        _isLocalUrl(_directBackendUrl)) {
      _endpointProfile = _profileRhclGateway;
    }

    if (savedPrimary != null &&
        savedPrimary.isNotEmpty &&
        !(!_isLocalBrowser() && _isLocalUrl(savedPrimary))) {
      _primaryController.text = savedPrimary;
    } else {
      _primaryController.text = _profileUrl(_endpointProfile);
    }
  }

  void _saveSettings() {
    final storage = html.window.localStorage;
    final currentUrl = _primaryController.text.trim();
    storage[_storagePrimaryUrlKey] = currentUrl;
    storage[_storageEndpointProfileKey] = _endpointProfile;
    storage[_storageDirectBackendUrlKey] = _directBackendUrl;
    storage[_storageRhclGatewayUrlKey] = _rhclGatewayUrl;
    storage[_storageRhclApiKeyKey] = _rhclApiKey;
  }

  String _profileUrl(String profile) {
    if (profile == _profileRhclGateway) {
      return _rhclGatewayUrl;
    }
    return _directBackendUrl;
  }

  bool _isLocalBrowser() {
    final host = html.window.location.hostname;
    return host == 'localhost' || host == '127.0.0.1';
  }

  bool _isLocalUrl(String value) {
    try {
      final host = Uri.parse(value).host;
      return host == 'localhost' || host == '127.0.0.1';
    } catch (_) {
      return false;
    }
  }

  String _buildApiUrl(String path) =>
      '${pocApiBase(_primaryController.text.trim())}$path';

  Map<String, String> _buildHeaders(String traceId, {bool json = false}) {
    final h = <String, String>{
      'x-flow-trace-id': traceId,
      'x-client-app': 'red-bank-mobile',
    };
    if (json) h['content-type'] = 'application/json';
    if (_endpointProfile == _profileRhclGateway && _rhclApiKey.isNotEmpty) {
      h['api-key'] = _rhclApiKey;
    }
    return h;
  }

  void _connectLiveFeed() {
    _closeWebSockets();
    _connectLiveFeedInternal(resetAttempts: true);
  }

  void _connectLiveFeedInternal({required bool resetAttempts}) {
    if (resetAttempts) {
      _wsReconnectAttempt = 0;
      _wsReconnectTimer?.cancel();
      _wsReconnectTimer = null;
    }

    _wsPrimary = _openSocket(_primaryController.text.trim());
    _wsPrimaryOpenSub = _wsPrimary?.onOpen.listen((_) {
      setState(() {
        _wsPrimaryConnected = true;
      });
      _wsReconnectAttempt = 0;
      _wsReconnectTimer?.cancel();
      _wsReconnectTimer = null;
    });
    _wsPrimaryCloseSub = _wsPrimary?.onClose.listen((_) {
      setState(() {
        _wsPrimaryConnected = false;
      });
      _scheduleWsReconnect();
    });
    _wsPrimaryErrorSub = _wsPrimary?.onError.listen((_) {
      if (mounted) {
        setState(() {
          _wsPrimaryConnected = false;
        });
      }
      _scheduleWsReconnect();
    });
    _wsPrimaryMessageSub = _wsPrimary?.onMessage.listen(
      (event) => _onLiveEvent(event.data?.toString(), 'v1'),
    );
  }

  void _scheduleWsReconnect() {
    if (!mounted || _wsReconnectTimer != null) {
      return;
    }
    final backoffSeconds = min(30, 1 << _wsReconnectAttempt);
    _wsReconnectTimer = Timer(Duration(seconds: backoffSeconds), () {
      _wsReconnectTimer = null;
      if (!mounted) return;
      _wsReconnectAttempt++;
      _connectLiveFeedInternal(resetAttempts: false);
    });
  }

  html.WebSocket? _openSocket(String summaryUrl) {
    // Don't append the API key to the WebSocket URL.
    //
    // Browser WebSocket() can't send custom headers, so a previous
    // iteration ("cbcf2be — websocket auth via api-key query string")
    // tried to smuggle the key via `?api-key=…`. That was both
    // unnecessary and counterproductive:
    //   - The gateway's AuthPolicy already has a `public-ws` rule
    //     that bypasses authentication for every `/ws*` path. The
    //     LiveFeed channel doesn't carry private data per-tenant.
    //   - Query strings on the upgrade request leak the credential
    //     into request_path-keyed metrics, Istio access logs and any
    //     downstream tracing — so we'd be broadcasting the API key
    //     across the observability plane on every reconnect.
    // Keep the upgrade URL clean and let the AuthPolicy bypass do
    // its job; the only header we'd ever want to add here would be
    // Origin, which the browser already sets.
    try {
      final uri = Uri.parse(summaryUrl);
      final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
      final wsUri = Uri(
        scheme: scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: '/ws/live',
      );
      return html.WebSocket(wsUri.toString());
    } catch (_) {
      return null;
    }
  }

  void _onLiveEvent(String? raw, String channel) {
    if (raw == null || raw.isEmpty) return;
    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      final type = payload['type']?.toString() ?? 'event';
      if (type == 'backend.health') return;
      _handleRealtimeUpdate(type, payload);
    } catch (_) {}
  }

  void _handleRealtimeUpdate(String type, Map<String, dynamic> payload) {
    if (type == 'balance.updated') {
      final accountTotal = payload['accountTotal'];
      final wsBanks = payload['banks'];
      if (accountTotal != null) {
        setState(() {
          _total = _toDouble(accountTotal) + _investments;
          if (wsBanks is List) {
            _banks = wsBanks;
          }
          _balanceJustUpdated = true;
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _balanceJustUpdated = false);
        });
      }
    }
    if (type.startsWith('transfer.')) {
      setState(() {
        _wsTransferStatus = type.replaceFirst('transfer.', '').toUpperCase();
        _wsTransferId = payload['transferId']?.toString() ?? '-';
        _wsTransferAmount = payload['amount']?.toString() ?? '-';
        _wsTransferFromBank = payload['fromBank']?.toString() ?? '-';
        _wsTransferToBank = _displayBankName(
          payload['toBank']?.toString() ?? '-',
        );
      });
      if (type == 'transfer.completed') {
        _addTransferHistory(
          amount: _toDouble(payload['amount']),
          status: 'COMPLETED',
          source: payload['backendTag']?.toString() ?? '-',
          fromBank: payload['fromBank']?.toString() ?? '-',
          toBank: payload['toBank']?.toString() ?? '-',
        );
      }
    }
  }

  void _closeWebSockets() {
    _wsPrimaryMessageSub?.cancel();
    _wsPrimaryOpenSub?.cancel();
    _wsPrimaryCloseSub?.cancel();
    _wsPrimaryErrorSub?.cancel();
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    _wsPrimary?.close();
    _wsPrimary = null;
    _wsPrimaryConnected = false;
  }

  Future<void> _callEcho({required String method}) async {
    setState(() {
      _echoLoading = true;
    });
    try {
      final traceId = _newTraceId('echo');
      final echoUrl = _buildApiUrl('/api/echo');
      late final http.Response response;
      if (method == 'GET') {
        response = await _client.get(
          Uri.parse('$echoUrl?view=human'),
          headers: _buildHeaders(traceId),
        );
      } else {
        response = await _client.post(
          Uri.parse(echoUrl),
          headers: _buildHeaders(traceId, json: true),
          body: jsonEncode({
            'action': 'echo-inspection',
            'traceId': traceId,
            'timestamp': DateTime.now().toIso8601String(),
          }),
        );
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final normalizedJson = _extractJsonPayload(response.body);
        if (normalizedJson == null) {
          setState(() {
            _echoOutput =
                'Echo response is not JSON. Check the backend URL and endpoint configuration.';
          });
        } else {
          final pretty = const JsonEncoder.withIndent(
            '  ',
          ).convert(jsonDecode(normalizedJson));
          setState(() {
            _echoOutput = pretty;
          });
        }
      } else {
        setState(() {
          _echoOutput =
              'Echo call failed: HTTP ${response.statusCode} (non-JSON response omitted)';
        });
      }
    } catch (e) {
      setState(() {
        _echoOutput = 'Echo call failed: $e';
      });
    } finally {
      setState(() {
        _echoLoading = false;
      });
    }
  }

  String? _extractJsonPayload(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return trimmed;
    }
    final firstBrace = trimmed.indexOf('{');
    final lastBrace = trimmed.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      return trimmed.substring(firstBrace, lastBrace + 1);
    }
    return null;
  }

  Future<void> _openEchoTerminal() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.72,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Echo terminal',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _endpointLabel('Endpoint', _buildApiUrl('/api/echo')),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _echoLoading
                              ? null
                              : () async {
                                  await _callEcho(method: 'GET');
                                  modalSetState(() {});
                                },
                          icon: const Icon(Icons.download),
                          label: const Text('GET /api/echo'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _echoLoading
                              ? null
                              : () async {
                                  await _callEcho(method: 'POST');
                                  modalSetState(() {});
                                },
                          icon: const Icon(Icons.upload),
                          label: const Text('POST /api/echo'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.black54
                              : Colors.grey.shade200,
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            _echoOutput,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F1419) : const Color(0xFFF3F6FB),
      appBar: AppBar(
        toolbarHeight: 92,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/images/red-bank-logo.png',
                width: 76,
                height: 76,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            const Text('Red Hat Digital Bank'),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Echo terminal',
            onPressed: _openEchoTerminal,
            icon: const Icon(Icons.terminal),
          ),
          IconButton(
            tooltip: 'PoC console',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PocConsolePage(
                    apiBase: pocApiBase(_primaryController.text.trim()),
                    mcpGatewayUrl: _defaultMcpGatewayUrl,
                    rhclApiKey: _rhclApiKey,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.science),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: isDark
                    ? const [Color(0xFF0D3B2E), Color(0xFF155C46)]
                    : const [Color(0xFF09593F), Color(0xFF1F7A59)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: _balanceJustUpdated
                  ? Border.all(color: Colors.greenAccent, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
              boxShadow: [
                BoxShadow(
                  color: _balanceJustUpdated
                      ? Colors.greenAccent.withOpacity(0.3)
                      : Colors.black26,
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total balance',
                  style: textTheme.bodyLarge?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    'R\$ ${_total.toStringAsFixed(2)}',
                    key: ValueKey<String>(_total.toStringAsFixed(2)),
                    style: textTheme.headlineMedium?.copyWith(
                      color: _balanceJustUpdated
                          ? Colors.greenAccent
                          : Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _endpointLabel(
                  'Summary endpoint',
                  _primaryController.text.trim(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _loading
                      ? null
                      : () => _loadData(showSuccessMessage: true),
                  icon: const Icon(Icons.sync),
                  label: const Text('Refresh'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _simulateTransfer,
                  icon: const Icon(Icons.send),
                  label: const Text('Transfer'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_message.isNotEmpty)
            Text(
              _message,
              style: TextStyle(
                color: _message.startsWith('Falha') ? Colors.red : Colors.green,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Accounts by bank',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _loading
                    ? null
                    : () => _resetBankAccount(bankName: 'Example Bank'),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _endpointLabel('Endpoint', _primaryController.text.trim()),
          const SizedBox(height: 8),
          ..._banks.map((bank) {
            final item = bank as Map<String, dynamic>;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.account_balance)),
                title: Text(item['bankName'].toString()),
                subtitle: Text('Account ${item['account']}'),
                trailing: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    'R\$ ${_toDouble(item['balance']).toStringAsFixed(2)}',
                    key: ValueKey<String>(
                      '${item['bankName']}-${_toDouble(item['balance']).toStringAsFixed(2)}',
                    ),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _balanceJustUpdated ? Colors.greenAccent : null,
                    ),
                  ),
                ),
              ),
            );
          }),
          if (_banks.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No data loaded yet. Tap Refresh to fetch balances.',
                ),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Last 5 transfers',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _endpointLabel(
                    'Endpoint',
                    _buildApiUrl('/api/v1/transfers'),
                  ),
                  const SizedBox(height: 8),
                  if (_transferHistory.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: Text(
                          'No transfers yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    ..._transferHistory.map((entry) {
                      final status = entry['status'] ?? '';
                      final isCompleted = status == 'COMPLETED';
                      final isRejected =
                          status == 'REJECTED' || status == 'FAILED';
                      final statusColor = isCompleted
                          ? Colors.green
                          : isRejected
                              ? Colors.red
                              : Colors.amber;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.12),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.arrow_upward,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry['to'] ?? '-',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${entry['from']}  •  ${entry['time']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '- ${entry['amount']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.redAccent,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusColor.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    status,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: statusColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _wsStatusDot(_isWsReady),
                      const SizedBox(width: 6),
                      Icon(Icons.bolt, color: Colors.amber, size: 18),
                      const SizedBox(width: 4),
                      const Text(
                        'Real-time transfer status (WebSocket)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _endpointLabel(
                    'Endpoint',
                    _wsEndpoint(_primaryController.text.trim()),
                  ),
                  const SizedBox(height: 8),
                  if (_wsTransferStatus.isEmpty)
                    const Text(
                      'Waiting for a transfer to stream real-time status updates...',
                    )
                  else ...[
                    Row(
                      children: [
                        _transferStageIndicator('PENDING', _wsTransferStatus),
                        _stageSeparator(),
                        _transferStageIndicator(
                          'PROCESSING',
                          _wsTransferStatus,
                        ),
                        _stageSeparator(),
                        _transferStageIndicator('COMPLETED', _wsTransferStatus),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Transfer ID: $_wsTransferId',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    Text(
                      'Amount: R\$ $_wsTransferAmount',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      'From: $_wsTransferFromBank',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      'To: $_wsTransferToBank',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _endpointLabel(String label, String endpoint) {
    return Text(
      '$label: $endpoint',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: 11,
            fontFamily: 'monospace',
            color: Colors.grey,
          ),
    );
  }

  String _wsEndpoint(String summaryUrl) {
    try {
      final uri = Uri.parse(summaryUrl);
      final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
      final wsUri = Uri(
        scheme: scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: '/ws/live',
      );
      return wsUri.toString();
    } catch (_) {
      return 'ws://<invalid-backend-url>/ws/live';
    }
  }

  Widget _transferStageIndicator(String stage, String currentStatus) {
    final stages = ['PENDING', 'PROCESSING', 'COMPLETED'];
    final currentIndex = stages.indexOf(currentStatus);
    final stageIndex = stages.indexOf(stage);

    Color color;
    IconData icon;

    if (stageIndex < currentIndex) {
      color = Colors.green;
      icon = Icons.check_circle;
    } else if (stageIndex == currentIndex) {
      color = Colors.amber;
      icon = Icons.radio_button_checked;
    } else {
      color = Colors.grey;
      icon = Icons.radio_button_unchecked;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 4),
        Text(
          stage,
          style: TextStyle(
            color: color,
            fontWeight: stageIndex == currentIndex
                ? FontWeight.bold
                : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _stageSeparator() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Icon(Icons.arrow_forward, size: 14, color: Colors.grey),
    );
  }

  Widget _wsStatusDot(bool connected) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: connected ? Colors.green : Colors.redAccent,
        shape: BoxShape.circle,
      ),
    );
  }

  bool get _isWsReady => _wsPrimaryConnected;
}
