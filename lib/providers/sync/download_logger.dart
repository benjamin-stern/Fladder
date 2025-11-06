import 'dart:async';
import 'dart:io';
import 'dart:developer' as dev;

/// Centralized, profuse logging for download & sync diagnostics.
/// Writes to console (dev.log) and to a persistent log file so the user can
/// later attach it for troubleshooting hanging / failing downloads.
class DownloadLogger {
  static File? _logFile;
  static IOSink? _sink;
  static bool _initialized = false;

  /// Initializes the logger with a base directory where the log file should live.
  /// Safe to call multiple times; the first successful call wins.
  static Future<void> init(Directory baseDir) async {
    if (_initialized) return;
    try {
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }
      final file = File('${baseDir.path}${Platform.pathSeparator}download_debug.log');
      _logFile = file;
      _sink = file.openWrite(mode: FileMode.append);
      _initialized = true;
      log('Logger initialized at ${file.path}');
    } catch (e, st) {
      dev.log('Failed to initialize DownloadLogger: $e', error: e, stackTrace: st);
    }
  }

  /// Basic log writer. Always prepends ISO8601 timestamp.
  static void log(String message, {String? taskId}) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts]${taskId != null ? '[task:$taskId]' : ''} $message';
    dev.log(line);
    if (_sink != null) {
      // Serialize writes to avoid interleaving when called from multiple isolates (unlikely here).
      synchronized(() => _sink!.writeln(line));
    }
  }

  static void error(String message, {String? taskId, Object? error, StackTrace? stackTrace}) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts]${taskId != null ? '[task:$taskId]' : ''} ERROR: $message | err=$error';
    dev.log(line, error: error, stackTrace: stackTrace);
    if (_sink != null) {
      synchronized(() => _sink!..writeln(line)..writeln(stackTrace));
    }
  }

  /// Flush & close resources. Optional.
  static Future<void> dispose() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _logFile = null;
    _initialized = false;
  }

  /// Read last [lines] lines for quick in‑app diagnostics.
  static Future<List<String>> tail({int lines = 200}) async {
    final file = _logFile;
    if (file == null || !await file.exists()) return [];
    final content = await file.readAsLines();
    return content.skip((content.length - lines).clamp(0, content.length)).toList();
  }

  static R synchronized<R>(R Function() action) {
    // Simple sync primitive. Dart single-threaded within an isolate; using an Object lock for clarity.
    // ignore: synchronized
    return action();
  }
}

/// Helper structure for internal progress diagnostics.
class TaskProgressSnapshot {
  TaskProgressSnapshot({required this.progress, required this.status, required this.timestamp});
  double progress; // 0.0 - 1.0
  DateTime timestamp;
  dynamic status; // TaskStatus
}