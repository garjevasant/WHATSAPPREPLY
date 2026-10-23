import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_notification_listener/flutter_notification_listener.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

const _diagnosticsChannel = MethodChannel('com.vasant.whatsapp/diagnostics');
const _defaultModel = 'llama3.1:8b';
const _defaultPrompt =
    'Tum Vasant ke Personal AI Assistant ho. Samne wale ke sawal ko samajhkar natural Hinglish me 1 se 2 line me polite jawab do. Agar koi urgent kaam bole to kaho ki call kar lein.';
const _logKey = 'auto_reply_logs';

/// Persists uncaught Dart/background errors in the app's documents directory.
/// This survives app restarts and can be viewed from Settings.
class CrashReporter {
  static Future<File> _file() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}${Platform.pathSeparator}crash_reports.txt');
  }

  static Future<void> write(
    Object error,
    StackTrace stack, {
    required String source,
  }) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final entry =
          '\n===== ${DateTime.now().toIso8601String()} [$source] =====\n'
          '$error\n$stack\n';
      await file.writeAsString(entry, mode: FileMode.append, flush: true);
      await _saveToDownloads(entry, replace: false);
    } catch (_) {
      // Error reporting must never become a second source of crashes.
    }
  }

  static Future<String> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  static Future<void> syncToDownloads() async {
    try {
      final report = await read();
      if (report.isNotEmpty) await _saveToDownloads(report, replace: true);
    } catch (_) {}
  }

  static Future<void> _saveToDownloads(
    String content, {
    required bool replace,
  }) async {
    try {
      await _diagnosticsChannel.invokeMethod<void>('saveCrashReport', {
        'content': content,
        'replace': replace,
      });
    } catch (_) {
      // The internal copy remains available if Android's public folder is
      // unavailable or the notification background isolate has no Activity.
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.writeAsString('', flush: true);
      await _diagnosticsChannel.invokeMethod<void>('clearCrashReport');
    } catch (_) {}
  }
}

class LocalStore {
  LocalStore(this.file);

  final File file;

  static Future<LocalStore> open() async {
    final directory = await getApplicationDocumentsDirectory();
    return LocalStore(
      File('${directory.path}${Platform.pathSeparator}config.json'),
    );
  }

  Future<Map<String, dynamic>> read() async {
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return Map<String, dynamic>.from(decoded as Map);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> write(Map<String, dynamic> data) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data), flush: true);
  }
}

String _cleanIp(String value) {
  var ip = value.trim().replaceFirst(
    RegExp(r'^https?://', caseSensitive: false),
    '',
  );
  ip = ip.split('/').first;
  if (ip.startsWith('[') && ip.contains(']')) {
    ip = ip.substring(1, ip.indexOf(']'));
  } else if (ip.contains(':')) {
    ip = ip.split(':').first;
  }
  return ip.trim();
}

Uri _ollamaUri(String ip) => Uri.parse('http://${_cleanIp(ip)}:11434/api/chat');

Future<String> _askOllama({
  required String ip,
  required String model,
  required String systemPrompt,
  required String sender,
  required String message,
}) async {
  final response = await http
      .post(
        _ollamaUri(ip),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': model.trim().isEmpty ? _defaultModel : model.trim(),
          'messages': [
            {'role': 'system', 'content': systemPrompt.trim()},
            {'role': 'user', 'content': '$sender says: $message'},
          ],
          'stream': false,
        }),
      )
      .timeout(const Duration(seconds: 45));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(
      'Ollama returned HTTP ${response.statusCode}: ${response.body}',
    );
  }
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final content =
      (data['message'] as Map?)?['content']?.toString().trim() ?? '';
  if (content.isEmpty) throw Exception('Ollama returned an empty reply.');
  return content;
}

bool _isReplyable(NotificationEvent event) =>
    event.actions?.any(
      (action) =>
          action.inputs?.any((input) => input.resultKey?.isNotEmpty == true) ==
          true,
    ) ??
    false;

Future<bool> _sendReply(NotificationEvent event, String reply) async {
  final action = event.actions?.firstWhere(
    (item) =>
        item.inputs?.any((input) => input.resultKey?.isNotEmpty == true) ==
        true,
    orElse: () => throw StateError('No reply action found'),
  );
  final input = action?.inputs?.firstWhere(
    (item) => item.resultKey?.isNotEmpty == true,
    orElse: () => throw StateError('No reply input found'),
  );
  if (input?.resultKey == null) return false;
  return action!.postInputs({input!.resultKey!: reply});
}

Future<void> _saveLog(String sender, String incoming, String reply) async {
  final store = await LocalStore.open();
  final data = await store.read();
  final logs = <Map<String, dynamic>>[];
  for (final raw in (data[_logKey] as List? ?? <dynamic>[])) {
    if (raw is Map) logs.add(Map<String, dynamic>.from(raw));
  }
  logs.insert(0, {
    'sender': sender,
    'incoming': incoming,
    'reply': reply,
    'timestamp': DateTime.now().toIso8601String(),
  });
  data[_logKey] = logs.take(20).toList();
  await store.write(data);
}

Future<void> _syncLogToServer({
  required String ip,
  required String sender,
  required String incoming,
  required String reply,
}) async {
  final cleanIp = _cleanIp(ip);
  if (cleanIp.isEmpty) return;
  try {
    await http
        .post(
          Uri.parse('http://$cleanIp:8765/api/logs'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sender': sender,
            'incoming': incoming,
            'reply': reply,
            'timestamp': DateTime.now().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // The PC dashboard is optional; on-device history remains available.
  }
}

Future<void> _syncChatToServer({
  required String ip,
  required String userMessage,
  required String aiReply,
}) async {
  final cleanIp = _cleanIp(ip);
  if (cleanIp.isEmpty) return;
  try {
    await http
        .post(
          Uri.parse('http://$cleanIp:8765/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'user_message': userMessage,
            'ai_reply': aiReply,
            'device_name': 'WhatsReply Android',
            'timestamp': DateTime.now().toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // Mobile chat remains available when the optional PC dashboard is offline.
  }
}

Future<bool> _sendServerHeartbeat(String ip) async {
  final cleanIp = _cleanIp(ip);
  if (cleanIp.isEmpty) return false;
  try {
    final store = await LocalStore.open();
    final data = await store.read();
    final deviceId =
        data['device_id']?.toString() ??
        'android-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    data['device_id'] = deviceId;
    await store.write(data);
    final response = await http
        .post(
          Uri.parse('http://$cleanIp:8765/api/heartbeat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'device_id': deviceId,
            'device_name': 'WhatsReply Android',
          }),
        )
        .timeout(const Duration(seconds: 3));
    return response.statusCode == 200;
  } catch (_) {
    // The dashboard can show the phone as disconnected when heartbeat fails.
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> notificationCallback(NotificationEvent event) async {
  try {
    await _handleNotification(event);
  } catch (error, stack) {
    unawaited(
      CrashReporter.write(error, stack, source: 'NotificationCallback'),
    );
  }
}

Future<void> _handleNotification(NotificationEvent event) async {
  if (event.packageName != 'com.whatsapp' &&
      event.packageName != 'com.whatsapp.w4b') {
    return;
  }
  final message = (event.text ?? event.message ?? '').trim();
  final sender = (event.title ?? '').trim();
  const ignored = {
    '',
    'whatsapp',
    'checking for new messages',
    'new messages',
    'backup',
  };
  if (sender.isEmpty || ignored.contains(message.toLowerCase())) return;
  final store = await LocalStore.open();
  final data = await store.read();
  if (data['bot_active'] != true) return;
  if (data['reply_groups'] == true && event.isGroup == true) return;
  if (data['quiet_mode'] == true) return;
  final allowed = (data['allowed_contacts'] as List? ?? const [])
      .map((item) => item.toString().toLowerCase())
      .toSet();
  final blocked = (data['blocked_contacts'] as List? ?? const [])
      .map((item) => item.toString().toLowerCase())
      .toSet();
  if (allowed.isNotEmpty && !allowed.contains(sender.toLowerCase())) return;
  if (blocked.contains(sender.toLowerCase())) return;
  if (data['schedule_enabled'] == true) {
    final hour = DateTime.now().hour;
    if (hour < 9 || hour >= 21) return;
  }
  final maxReplies = (data['max_replies_per_hour'] as num?)?.toInt() ?? 30;
  final hourAgo = DateTime.now().subtract(const Duration(hours: 1));
  final recentLogs = (data[_logKey] as List? ?? const []).where((item) {
    if (item is! Map) return false;
    return DateTime.tryParse(item['timestamp']?.toString() ?? '')
            ?.isAfter(hourAgo) ??
        false;
  }).length;
  if (recentLogs >= maxReplies) return;
  if (!_isReplyable(event)) return;
  final dedupeKey =
      'dedupe_${base64Url.encode(utf8.encode('$sender\n$message'))}';
  final now = DateTime.now().millisecondsSinceEpoch;
  final previous = (data[dedupeKey] as num?)?.toInt() ?? 0;
  if (now - previous < 15000) return;
  data[dedupeKey] = now;
  await store.write(data);
  try {
    final reply = await _askOllama(
      ip: data['tailscale_ip']?.toString() ?? '',
      model: data['model_name']?.toString() ?? _defaultModel,
      systemPrompt: data['system_prompt']?.toString() ?? _defaultPrompt,
      sender: sender,
      message: message,
    );
    if (await _sendReply(event, reply)) {
      await _saveLog(sender, message, reply);
      await _syncLogToServer(
        ip: data['tailscale_ip']?.toString() ?? '',
        sender: sender,
        incoming: message,
        reply: reply,
      );
    }
  } catch (error, stack) {
    unawaited(CrashReporter.write(error, stack, source: 'OllamaReply'));
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      CrashReporter.write(
        details.exception,
        details.stack ?? StackTrace.current,
        source: 'FlutterError',
      ),
    );
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(CrashReporter.write(error, stack, source: 'PlatformDispatcher'));
    return true;
  };
  unawaited(CrashReporter.syncToDownloads());
  runZonedGuarded(() => runApp(const WhatsReplyApp()), (error, stack) {
    unawaited(CrashReporter.write(error, stack, source: 'Zone'));
  });
}

class WhatsReplyApp extends StatelessWidget {
  const WhatsReplyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WhatsReply',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff128c7e)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff4f8f6),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _overlayChannel = MethodChannel('com.vasant.whatsapp/overlay');
  final _ip = TextEditingController();
  final _model = TextEditingController(text: _defaultModel);
  final _prompt = TextEditingController(text: _defaultPrompt);
  final _allowList = TextEditingController();
  final _blockList = TextEditingController();
  bool _active = false, _groups = false, _permission = false, _busy = false;
  bool _quietMode = false, _scheduleEnabled = false;
  int _maxRepliesPerHour = 30;
  int _tabIndex = 0;
  bool _serverConnected = false;
  bool _overlayPermission = false;
  bool _overlayEnabled = false;
  Timer? _serverTimer;
  String? _testResult;
  String? _settingsMessage;
  String _crashReport = '';
  List<Map<String, dynamic>> _logs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _serverTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkServerConnection(),
    );
    _checkServerConnection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serverTimer?.cancel();
    _ip.dispose();
    _model.dispose();
    _prompt.dispose();
    _allowList.dispose();
    _blockList.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermission();
      _refreshOverlayPermission();
    }
  }

  Future<void> _load() async {
    Map<String, dynamic> data;
    try {
      final store = await LocalStore.open();
      data = await store.read();
    } catch (error, stack) {
      data = <String, dynamic>{};
      unawaited(CrashReporter.write(error, stack, source: 'SettingsLoad'));
    }
    _ip.text = data['tailscale_ip']?.toString() ?? '';
    _model.text = data['model_name']?.toString() ?? _defaultModel;
    _prompt.text = data['system_prompt']?.toString() ?? _defaultPrompt;
    _allowList.text = (data['allowed_contacts'] as List? ?? const []).join(
      ', ',
    );
    _blockList.text = (data['blocked_contacts'] as List? ?? const []).join(
      ', ',
    );
    _active =
        (data['bot_active'] == true) &&
        (await NotificationsListener.isRunning ?? false);
    _groups = data['reply_groups'] == true;
    _quietMode = data['quiet_mode'] == true;
    _scheduleEnabled = data['schedule_enabled'] == true;
    _maxRepliesPerHour = (data['max_replies_per_hour'] as num?)?.toInt() ?? 30;
    _overlayEnabled = data['overlay_enabled'] == true;
    await _refreshCrashReport();
    await _readLogs(data);
    await _refreshPermission();
    await _refreshOverlayPermission();
    if (_overlayEnabled && _overlayPermission) await _startBubble();
    if (mounted) setState(() {});
    await _checkServerConnection();
  }

  Future<void> _readLogs([Map<String, dynamic>? supplied]) async {
    final data = supplied ?? await (await LocalStore.open()).read();
    final values = <Map<String, dynamic>>[];
    for (final raw in (data[_logKey] as List? ?? <dynamic>[])) {
      if (raw is Map) values.add(Map<String, dynamic>.from(raw));
    }
    if (mounted) setState(() => _logs = values);
  }

  Future<void> _refreshPermission() async {
    try {
      // Android owns this permission. We only read the current value; it is
      // never reset by the app after the user grants it.
      final granted = await NotificationsListener.hasPermission ?? false;
      final store = await LocalStore.open();
      final data = await store.read();
      data['notification_access_last_seen'] = granted;
      data['notification_access_checked_at'] = DateTime.now().toIso8601String();
      await store.write(data);
      if (mounted) setState(() => _permission = granted);
    } catch (error, stack) {
      unawaited(
        CrashReporter.write(error, stack, source: 'NotificationPermission'),
      );
    }
  }

  Future<void> _refreshCrashReport() async {
    final report = await CrashReporter.read();
    if (mounted) setState(() => _crashReport = report);
  }

  Future<void> _clearCrashReport() async {
    await CrashReporter.clear();
    await _refreshCrashReport();
  }

  Future<void> _showCrashReport() async {
    await _refreshCrashReport();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Crash reports (.txt)'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              _crashReport.isEmpty ? 'No saved crash reports.' : _crashReport,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshOverlayPermission() async {
    try {
      final granted =
          await _overlayChannel.invokeMethod<bool>('hasPermission') ?? false;
      if (mounted) setState(() => _overlayPermission = granted);
    } catch (_) {
      if (mounted) setState(() => _overlayPermission = false);
    }
  }

  Future<void> _openOverlaySettings() async {
    await _overlayChannel.invokeMethod('openSettings');
  }

  Future<void> _startBubble() async {
    await _overlayChannel.invokeMethod('startBubble');
  }

  Future<void> _setOverlay(bool enabled) async {
    if (enabled && !_overlayPermission) {
      await _openOverlaySettings();
      return;
    }
    try {
      if (enabled) {
        await _startBubble();
      } else {
        await _overlayChannel.invokeMethod('stopBubble');
      }
      final store = await LocalStore.open();
      final data = await store.read();
      data['overlay_enabled'] = enabled;
      await store.write(data);
      if (mounted) setState(() => _overlayEnabled = enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Floating bubble error: $error')),
        );
      }
    }
  }

  Future<void> _confirmExit() async {
    final exit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close WhatsReply?'),
        content: Text(
          _active
              ? 'Bot background me chalta rahega. Sirf app screen close hogi.'
              : 'WhatsReply screen close karni hai?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('EXIT APP'),
          ),
        ],
      ),
    );
    if (exit == true) SystemNavigator.pop();
  }

  Future<void> _checkServerConnection() async {
    final ip = _cleanIp(_ip.text);
    if (ip.isEmpty) {
      if (mounted) setState(() => _serverConnected = false);
      return;
    }
    try {
      final response = await http
          .get(Uri.parse('http://$ip:8765/api/health'))
          .timeout(const Duration(seconds: 3));
      final heartbeatOk = response.statusCode == 200
          ? await _sendServerHeartbeat(ip)
          : false;
      if (mounted) setState(() => _serverConnected = heartbeatOk);
    } catch (_) {
      if (mounted) setState(() => _serverConnected = false);
    }
  }

  Future<void> _saveSettings() async {
    final store = await LocalStore.open();
    final data = await store.read();
    data['tailscale_ip'] = _ip.text.trim();
    data['model_name'] = _model.text.trim().isEmpty
        ? _defaultModel
        : _model.text.trim();
    data['system_prompt'] = _prompt.text.trim().isEmpty
        ? _defaultPrompt
        : _prompt.text.trim();
    data['reply_groups'] = _groups;
    data['quiet_mode'] = _quietMode;
    data['schedule_enabled'] = _scheduleEnabled;
    data['max_replies_per_hour'] = _maxRepliesPerHour;
    data['allowed_contacts'] = _allowList.text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    data['blocked_contacts'] = _blockList.text
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    await store.write(data);
  }

  Future<void> _saveSettingsWithFeedback() async {
    await _saveSettings();
    if (!mounted) return;
    setState(() => _settingsMessage = 'Settings saved successfully.');
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  Future<void> _toggleBot(bool value) async {
    try {
      await _saveSettings();
      final permitted = await NotificationsListener.hasPermission ?? false;
      if (value && !permitted) {
        if (mounted) setState(() => _permission = false);
        await NotificationsListener.openPermissionSettings();
        return;
      }
      if (value) {
        await NotificationsListener.initialize(
          callbackHandle: notificationCallback,
        );
        if ((await NotificationsListener.isRunning ?? false) == false) {
          await NotificationsListener.startService(
            foreground: true,
            title: 'WhatsReply is active',
            description: 'Listening for WhatsApp messages',
          );
        }
      } else if (await NotificationsListener.isRunning ?? false) {
        await NotificationsListener.stopService();
      }
      final store = await LocalStore.open();
      final data = await store.read();
      data['bot_active'] = value;
      await store.write(data);
      if (!mounted) return;
      setState(() => _active = value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value ? 'AI Bot started' : 'AI Bot stopped')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _active = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Bot start failed: $error')));
    }
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _saveSettings();
    if (_cleanIp(_ip.text).isEmpty) {
      setState(() => _testResult = 'Enter your PC Tailscale IP first.');
      return;
    }
    setState(() {
      _busy = true;
      _testResult = 'Connecting to Ollama...';
    });
    try {
      final reply = await _askOllama(
        ip: _ip.text,
        model: _model.text,
        systemPrompt: _prompt.text,
        sender: 'Test',
        message: 'Bhai kaha ho? Kya chal raha hai?',
      );
      if (mounted) setState(() => _testResult = reply);
    } catch (error) {
      if (mounted) {
        setState(
          () => _testResult =
              'Connection failed. Check Tailscale, Ollama with OLLAMA_HOST=0.0.0.0, port 11434, and the model name.\n\n$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    final store = await LocalStore.open();
    final data = await store.read();
    data.remove(_logKey);
    await store.write(data);
    await _readLogs(data);
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['WhatsReply', 'Reply history', 'Server', 'Settings'];
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[_tabIndex]),
          actions: [
            if (_tabIndex == 1)
              IconButton(
                tooltip: 'Clear logs',
                onPressed: _logs.isEmpty ? null : _clearLogs,
                icon: const Icon(Icons.delete_outline),
              ),
            if (_tabIndex == 2)
              IconButton(
                tooltip: 'Refresh connection',
                onPressed: _checkServerConnection,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: SafeArea(child: _tabView()),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (index) => setState(() => _tabIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Logs',
            ),
            NavigationDestination(
              icon: Icon(Icons.dns_outlined),
              selectedIcon: Icon(Icons.dns),
              label: 'Server',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabView() {
    switch (_tabIndex) {
      case 1:
        return _logsView();
      case 2:
        return _serverView();
      case 3:
        return _settingsView();
      default:
        return _homeView();
    }
  }

  Widget _homeView() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      _statusCard(),
      const SizedBox(height: 12),
      _serverCard(),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: _statCard(
              '${_logs.length}',
              'Replies',
              Icons.reply_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _statCard(
              _active ? 'ON' : 'OFF',
              'Bot status',
              Icons.smart_toy_outlined,
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _sectionTitle('Quick actions'),
      Card(
        color: const Color(0xffd9f5e9),
        child: ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xff128c7e),
            child: Icon(Icons.forum_outlined, color: Colors.white),
          ),
          title: const Text('Chat with local AI'),
          subtitle: const Text(
            'Ask anything and get a reply from your Ollama model.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatPage(
                ip: _ip.text,
                model: _model.text,
                systemPrompt: _prompt.text,
              ),
            ),
          ),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.wifi_tethering, color: Color(0xff128c7e)),
          title: const Text('Test Ollama connection'),
          subtitle: const Text('Check Tailscale and your local 8B model.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _tabIndex = 2),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(
            Icons.settings_outlined,
            color: Color(0xff128c7e),
          ),
          title: const Text('Open assistant settings'),
          subtitle: const Text('Tailscale IP, model, persona and permissions.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _tabIndex = 3),
        ),
      ),
      const SizedBox(height: 18),
      _sectionTitle('Latest reply'),
      _logs.isEmpty
          ? const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No replies yet. Your AI replies will appear here.',
                ),
              ),
            )
          : _logCard(_logs.first),
    ],
  );

  Widget _logsView() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      Card(
        color: const Color(0xffd9f5e9),
        child: ListTile(
          leading: const Icon(Icons.auto_awesome, color: Color(0xff128c7e)),
          title: Text('${_logs.length} saved replies'),
          subtitle: const Text(
            'History is stored locally on this phone and synced to Server UI when available.',
          ),
        ),
      ),
      const SizedBox(height: 14),
      if (_logs.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              'No replies yet. Turn on the bot and send a WhatsApp message.',
            ),
          ),
        )
      else
        ..._logs.map(_logCard),
    ],
  );

  Widget _serverView() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      _serverCard(),
      const SizedBox(height: 18),
      _sectionTitle('Ollama connection'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.memory, color: Color(0xff128c7e)),
          title: Text(_model.text.isEmpty ? _defaultModel : _model.text),
          subtitle: Text(
            'PC: ${_ip.text.isEmpty ? 'Set Tailscale IP in Settings' : _ip.text}',
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy ? null : _testConnection,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow),
        label: const Text('Test Tailscale + Ollama 8B'),
      ),
      if (_testResult != null) ...[
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(_testResult!),
          ),
        ),
      ],
      const SizedBox(height: 18),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Server UI: run server_ui/start_server.bat on your PC. The app checks port 8765 every 10 seconds.',
          ),
        ),
      ),
    ],
  );

  Widget _statCard(String value, String label, IconData icon) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xff128c7e)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(label, style: const TextStyle(color: Colors.black54)),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _settingsView() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    children: [
      _settingsHeader(),
      const SizedBox(height: 14),
      _sectionTitle('Ollama & Tailscale'),
      TextField(
        controller: _ip,
        onChanged: (_) => _checkServerConnection(),
        decoration: const InputDecoration(
          labelText: 'PC Tailscale IP address',
          hintText: '100.85.12.34',
          prefixIcon: Icon(Icons.lan_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _model,
        decoration: const InputDecoration(
          labelText: 'Ollama 8B model name',
          prefixIcon: Icon(Icons.memory_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _prompt,
        minLines: 4,
        maxLines: 7,
        decoration: const InputDecoration(
          labelText: 'System prompt / AI persona',
          alignLabelWithHint: true,
          prefixIcon: Icon(Icons.psychology_outlined),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _saveSettingsWithFeedback,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Save settings'),
      ),
      if (_settingsMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _settingsMessage!,
            style: const TextStyle(color: Colors.green),
          ),
        ),
      const SizedBox(height: 8),
      Card(
        child: SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Reply to group messages'),
          subtitle: const Text('Keep off to answer only direct chats.'),
          value: _groups,
          onChanged: (value) async {
            setState(() => _groups = value);
            await _saveSettings();
          },
        ),
      ),
      const SizedBox(height: 18),
      _sectionTitle('Smart reply rules'),
      Card(
        child: Column(
          children: [
            SwitchListTile.adaptive(
              title: const Text('Quiet mode'),
              subtitle: const Text(
                'Pause all automatic replies without turning the bot off.',
              ),
              value: _quietMode,
              onChanged: (value) async {
                setState(() => _quietMode = value);
                await _saveSettings();
              },
            ),
            SwitchListTile.adaptive(
              title: const Text('Schedule replies'),
              subtitle: const Text('Reply only between 09:00 and 21:00.'),
              value: _scheduleEnabled,
              onChanged: (value) async {
                setState(() => _scheduleEnabled = value);
                await _saveSettings();
              },
            ),
            ListTile(
              title: const Text('Hourly reply limit'),
              subtitle: Text('Maximum automatic replies: $_maxRepliesPerHour'),
              trailing: SizedBox(
                width: 150,
                child: Slider(
                  value: _maxRepliesPerHour.toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  label: '$_maxRepliesPerHour',
                  onChanged: (value) =>
                      setState(() => _maxRepliesPerHour = value.round()),
                  onChangeEnd: (_) => _saveSettings(),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _allowList,
        decoration: const InputDecoration(
          labelText: 'Allowed contacts (optional)',
          hintText: 'Amit, Neha, +91...',
          helperText: 'If filled, only these sender names get replies.',
          prefixIcon: Icon(Icons.verified_user_outlined),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _blockList,
        decoration: const InputDecoration(
          labelText: 'Blocked contacts (optional)',
          hintText: 'Spam, Unknown...',
          prefixIcon: Icon(Icons.block_outlined),
        ),
      ),
      const SizedBox(height: 18),
      _sectionTitle('Permissions'),
      if (_permission)
        const Card(
          child: ListTile(
            leading: Icon(Icons.verified, color: Colors.green),
            title: Text('Notification access granted'),
            subtitle: Text(
              'WhatsApp notifications can be read and replied to.',
            ),
          ),
        ),
      if (!_permission) _permissionCard(),
      const SizedBox(height: 18),
      _sectionTitle('One-by-one status'),
      Card(
        child: Column(
          children: [
            _diagnosticRow(
              'Ollama model',
              _ip.text.trim().isNotEmpty && _model.text.trim().isNotEmpty,
              _ip.text.trim().isNotEmpty
                  ? '${_model.text.trim()} configured'
                  : 'PC Tailscale IP required',
            ),
            _diagnosticRow(
              'Notification access',
              _permission,
              _permission ? 'Granted by Android' : 'Open permission settings',
            ),
            _diagnosticRow(
              'Background AI bot',
              _active,
              _active ? 'Running' : 'Stopped',
            ),
            _diagnosticRow(
              'PC server sync',
              _serverConnected,
              _serverConnected ? 'Connected on port 8765' : 'Not reachable',
            ),
            _diagnosticRow(
              'Floating bubble',
              _overlayEnabled && _overlayPermission,
              _overlayEnabled && _overlayPermission ? 'Enabled' : 'Disabled',
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _sectionTitle('Crash diagnostics'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _crashReport.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    color: _crashReport.isEmpty ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _crashReport.isEmpty
                          ? 'No saved app crash reports.'
                          : 'Crash report saved in crash_reports.txt.',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Flutter and background errors are saved locally so they can be checked after reopening the app.',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _showCrashReport,
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('View .txt'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _refreshCrashReport,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                  if (_crashReport.isNotEmpty)
                    TextButton.icon(
                      onPressed: _clearCrashReport,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      _sectionTitle('Floating assistant bubble'),
      Card(
        child: Column(
          children: [
            SwitchListTile.adaptive(
              title: const Text('Show WR bubble over other apps'),
              subtitle: Text(
                _overlayPermission
                    ? 'Drag the bubble anywhere. Tap it to open WhatsReply.'
                    : 'Requires Android display-over-other-apps permission.',
              ),
              value: _overlayEnabled && _overlayPermission,
              onChanged: _setOverlay,
            ),
            if (!_overlayPermission)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: OutlinedButton.icon(
                  onPressed: _openOverlaySettings,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Allow floating bubble'),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: _confirmExit,
        icon: const Icon(Icons.exit_to_app),
        label: const Text('Exit app'),
      ),
      const SizedBox(height: 18),
      _sectionTitle('How it works'),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'WhatsReply reads only WhatsApp and WhatsApp Business notifications, sends the message to your local Ollama model over Tailscale, and uses the notification Reply action to send the answer back.',
          ),
        ),
      ),
    ],
  );

  Widget _diagnosticRow(String title, bool passed, String detail) => ListTile(
    leading: Icon(
      passed ? Icons.check_circle : Icons.pending_outlined,
      color: passed ? Colors.green : Colors.orange,
    ),
    title: Text(title),
    subtitle: Text(detail),
    trailing: Text(
      passed ? 'PASS' : 'CHECK',
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: passed ? Colors.green : Colors.orange,
      ),
    ),
  );

  Widget _permissionCard() => Card(
    child: ListTile(
      leading: const Icon(Icons.warning_amber, color: Colors.orange),
      title: const Text('Notification access needed'),
      subtitle: const Text(
        'Required to read WhatsApp alerts and send replies.',
      ),
      trailing: TextButton(
        onPressed: () async {
          await NotificationsListener.openPermissionSettings();
          await _refreshPermission();
        },
        child: const Text('OPEN SETTINGS'),
      ),
    ),
  );

  Widget _settingsHeader() => Card(
    color: const Color(0xffd9f5e9),
    child: const Padding(
      padding: EdgeInsets.all(18),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: Color(0xff128c7e),
            child: Icon(Icons.tune, color: Colors.white),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Configure your private AI assistant\nChanges are saved only on this device.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _serverCard() => Card(
    color: _serverConnected ? const Color(0xffd9f5e9) : Colors.white,
    child: ListTile(
      leading: CircleAvatar(
        backgroundColor: _serverConnected ? Colors.green : Colors.grey,
        child: Icon(
          _serverConnected ? Icons.cloud_done : Icons.cloud_off,
          color: Colors.white,
        ),
      ),
      title: Text(
        _serverConnected ? 'Server connected' : 'Server disconnected',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        _serverConnected
            ? 'History dashboard is reachable on port 8765.'
            : 'Start server_ui/start_server.bat on your PC.',
      ),
      trailing: IconButton(
        onPressed: _checkServerConnection,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );

  Widget _statusCard() => Card(
    color: _active ? const Color(0xffd9f5e9) : Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: _active ? Colors.green : Colors.grey,
            child: const Icon(Icons.smart_toy, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _active ? 'AI Bot Running' : 'AI Bot Stopped',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _active
                      ? 'WhatsApp notifications are being monitored.'
                      : 'Turn it on after configuring Ollama.',
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
          Switch.adaptive(value: _active, onChanged: _toggleBot),
        ],
      ),
    ),
  );
  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
  Widget _logCard(Map<String, dynamic> log) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${log['sender'] ?? 'Unknown'}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text(_formatTime(log['timestamp']?.toString())),
            ],
          ),
          const Divider(),
          Text('Q: ${log['incoming'] ?? ''}'),
          const SizedBox(height: 6),
          Text(
            'AI: ${log['reply'] ?? ''}',
            style: const TextStyle(color: Color(0xff128c7e)),
          ),
        ],
      ),
    ),
  );
  String _formatTime(String? value) {
    final date = DateTime.tryParse(value ?? '')?.toLocal();
    if (date == null) return '';
    return '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    required this.ip,
    required this.model,
    required this.systemPrompt,
    super.key,
  });

  final String ip;
  final String model;
  final String systemPrompt;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <Map<String, String>>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadChatHistory();
  }

  Future<void> _loadChatHistory() async {
    final data = await (await LocalStore.open()).read();
    final saved = data['chat_messages'];
    if (!mounted || saved is! List) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(
          saved.whereType<Map>().map((item) => Map<String, String>.from(item)),
        );
    });
  }

  Future<void> _saveChatHistory() async {
    final store = await LocalStore.open();
    final data = await store.read();
    data['chat_messages'] = _messages.take(100).toList();
    await store.write(data);
  }

  Future<void> _clearChat() async {
    setState(() => _messages.clear());
    final store = await LocalStore.open();
    final data = await store.read();
    data.remove('chat_messages');
    await store.write(data);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    if (_cleanIp(widget.ip).isEmpty) {
      _showError('Settings me PC Tailscale IP save karein.');
      return;
    }
    _controller.clear();
    setState(() {
      _messages.add({'role': 'user', 'text': text});
      _sending = true;
    });
    await _saveChatHistory();
    _scrollToBottom();
    try {
      final reply = await _askOllama(
        ip: widget.ip,
        model: widget.model,
        systemPrompt: widget.systemPrompt,
        sender: 'Vasant',
        message: text,
      );
      if (mounted) {
        setState(() => _messages.add({'role': 'assistant', 'text': reply}));
        await _saveChatHistory();
        await _syncChatToServer(
          ip: widget.ip,
          userMessage: text,
          aiReply: reply,
        );
        _scrollToBottom();
      }
    } catch (error) {
      if (mounted) _showError('Ollama connection failed: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: Color(0xff128c7e),
            child: Icon(Icons.smart_toy, color: Colors.white, size: 19),
          ),
          SizedBox(width: 10),
          Text('Local AI Chat'),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Clear chat',
          onPressed: _messages.isEmpty ? null : _clearChat,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircleAvatar(
                          radius: 34,
                          backgroundColor: Color(0xffd9f5e9),
                          child: Icon(
                            Icons.forum_outlined,
                            size: 34,
                            color: Color(0xff128c7e),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Ask your private AI assistant',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Messages go directly to your Ollama model on the PC.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black54),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children:
                              ['Summarize this', 'Plan my day', 'Write a reply']
                                  .map(
                                    (prompt) => ActionChip(
                                      label: Text(prompt),
                                      onPressed: () {
                                        _controller.text = prompt;
                                        _controller.selection =
                                            TextSelection.collapsed(
                                              offset: prompt.length,
                                            );
                                      },
                                    ),
                                  )
                                  .toList(),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
                  itemCount: _messages.length,
                  itemBuilder: (_, index) {
                    final message = _messages[index];
                    final user = message['role'] == 'user';
                    return Align(
                      alignment: user
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * .82,
                        ),
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: user ? const Color(0xff128c7e) : Colors.white,
                          borderRadius: BorderRadius.circular(18).copyWith(
                            bottomRight: user ? const Radius.circular(4) : null,
                            bottomLeft: user ? null : const Radius.circular(4),
                          ),
                        ),
                        child: GestureDetector(
                          onLongPress: () async {
                            await Clipboard.setData(
                              ClipboardData(text: message['text'] ?? ''),
                            );
                            if (mounted) _showError('Message copied');
                          },
                          child: Text(
                            message['text'] ?? '',
                            style: TextStyle(
                              color: user
                                  ? Colors.white
                                  : const Color(0xff18322f),
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_sending)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Ollama is thinking...',
              style: TextStyle(color: Colors.black54),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Message your local AI...',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xff128c7e),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.all(14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
