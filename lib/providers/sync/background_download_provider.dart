import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:fladder/models/syncing/download_stream.dart';
import 'download_logger.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/sync_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:path_provider/path_provider.dart';

part 'background_download_provider.g.dart';

final itemDownloadGroup = "ITEM_DOWNLOAD_GROUP";

@Riverpod(keepAlive: true)
class BackgroundDownloader extends _$BackgroundDownloader {
  late StreamSubscription<TaskUpdate> updateListener;
  Timer? _stallPollTimer;
  final Map<String, TaskProgressSnapshot> _progressSnapshots = {};
  static const Duration stallThreshold = Duration(seconds: 60); // time with no progress considered suspicious
  static const Duration pollInterval = Duration(seconds: 30); // periodic poll interval

  @override
  FileDownloader build() {
    ref.onDispose(
      () {
        updateListener.cancel();
        _stallPollTimer?.cancel();
        DownloadLogger.log('BackgroundDownloader disposed');
      },
    );

    final maxDownloads = ref.read(clientSettingsProvider.select((value) => value.maxConcurrentDownloads));
    final downloader = FileDownloader()
      ..configure(
        globalConfig: globalConfig(maxDownloads),
      )
      ..trackTasks();
    // Initialize persistent logger asynchronously (global scope).
    _initLogger();

    updateListener = downloader.updates.listen(updateTask);
    _stallPollTimer = Timer.periodic(pollInterval, _pollForStalls);
    DownloadLogger.log('BackgroundDownloader initialized: maxConcurrent=$maxDownloads directorySupport=${Platform.isWindows || Platform.isLinux || Platform.isMacOS}');
    return downloader;
  }

  void _initLogger() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await DownloadLogger.init(dir);
      DownloadLogger.log('Logger ready (support dir: ${dir.path})');
    } catch (e, st) {
      DownloadLogger.error('Logger init failed', error: e, stackTrace: st);
    }
  }

  void updateTask(TaskUpdate update) {
    switch (update) {
      case TaskStatusUpdate():
        final status = update.status;
        final id = update.task.taskId;
        final prev = _progressSnapshots[id];
        final prevStatus = prev?.status;
        DownloadLogger.log('STATUS update -> $status (from $prevStatus) filename=${update.task.filename} retries=${update.task.retries}', taskId: id);
        if (prev != null) {
          prev.status = status;
        } else {
          _progressSnapshots[id] = TaskProgressSnapshot(progress: 0.0, status: status, timestamp: DateTime.now());
        }
        ref.read(downloadTasksProvider(update.task.taskId).notifier).update(
              (state) => state.markStatus(status),
            );

        if (status == TaskStatus.complete || status == TaskStatus.canceled) {
          // Attempt to log resulting file size for diagnostics.
          unawaited(Future(() async {
            try {
              final filePath = '${update.task.directory}${Platform.pathSeparator}${update.task.filename}';
              final file = File(filePath);
              if (await file.exists()) {
                DownloadLogger.log('FINAL FILE size=${await file.length()} path=$filePath', taskId: id);
              } else {
                DownloadLogger.log('FINAL FILE missing path=$filePath', taskId: id);
              }
            } catch (e, st) {
              DownloadLogger.error('Error reading final file size', taskId: id, error: e, stackTrace: st);
            }
          }));
          ref.read(downloadTasksProvider(update.task.taskId).notifier).update((state) => DownloadStream.empty());
          DownloadLogger.log('Task ${status == TaskStatus.complete ? 'completed' : 'canceled'} totalSnapshots=${_progressSnapshots.length}', taskId: id);
        } else if (status == TaskStatus.failed || status == TaskStatus.notFound) {
          DownloadLogger.error('Task entered failure status: $status', taskId: id);
        }
      case TaskProgressUpdate():
        final progress = update.progress;
        final id = update.task.taskId;
        final speed = update.networkSpeedAsString;
        final now = DateTime.now();
        final snap = _progressSnapshots[id];
        final percent = (progress * 100).toStringAsFixed(2);
        if (snap == null) {
          _progressSnapshots[id] = TaskProgressSnapshot(progress: progress, status: TaskStatus.running, timestamp: now);
          DownloadLogger.log('PROGRESS init $percent% speed=$speed', taskId: id);
        } else {
          final changed = progress != snap.progress;
          if (changed) {
            final delta = progress - snap.progress;
            final sinceLast = now.difference(snap.timestamp).inSeconds;
            DownloadLogger.log('PROGRESS $percent% (+${(delta * 100).toStringAsFixed(2)}%) dt=${sinceLast}s speed=$speed',
                taskId: id);
            snap.progress = progress;
            snap.timestamp = now;
          } else {
            final idleFor = now.difference(snap.timestamp);
            if (idleFor > stallThreshold) {
              DownloadLogger.log('STALL DETECTED progress unchanged at $percent% for ${idleFor.inSeconds}s (speed=$speed, status=${snap.status})', taskId: id);
              // Increment stall count in provider state for UI / diagnostics.
              ref.read(downloadTasksProvider(id).notifier).update((s) => s.incrementStall());
            } else {
              DownloadLogger.log('PROGRESS unchanged $percent% idle=${idleFor.inSeconds}s speed=$speed', taskId: id);
            }
          }
        }
        ref.read(downloadTasksProvider(update.task.taskId).notifier).update(
              (state) => state.markProgress(progress > 0 && progress < 1 ? progress : state.progress, speed),
            );
    }
  }

  void _pollForStalls(Timer timer) {
    final now = DateTime.now();
    for (final entry in _progressSnapshots.entries) {
      final id = entry.key;
      final snap = entry.value;
      if (snap.status == TaskStatus.running || snap.status == TaskStatus.enqueued) {
        final idle = now.difference(snap.timestamp);
        if (idle > stallThreshold) {
          DownloadLogger.log('POLL STALL: task idle for ${idle.inSeconds}s at ${(snap.progress * 100).toStringAsFixed(2)}% status=${snap.status}', taskId: id);
        } else {
          DownloadLogger.log(
              'POLL OK: progress ${(snap.progress * 100).toStringAsFixed(2)}% idle=${idle.inSeconds}s status=${snap.status}',
              taskId: id);
        }
      }
    }
  }

  void setMaxConcurrent(int value) {
    state.configure(
      globalConfig: globalConfig(value),
    );
    DownloadLogger.log('Updated maxConcurrent -> $value currentActiveSnapshots=${_progressSnapshots.length}');
  }

  void updateTranslations(BuildContext context) async {
    state.configureNotification(
      running: TaskNotification(context.localized.notificationDownloadingDownloading, '{filename}\n{networkSpeed}'),
      complete: TaskNotification(context.localized.notificationDownloadingFinished, '{filename}'),
      paused: TaskNotification(context.localized.notificationDownloadingPaused, '{filename}'),
      error: TaskNotification(context.localized.notificationDownloadingError, '{filename}'),
      progressBar: true,
    );
    DownloadLogger.log('Updated notifications translations');
  }

  (String, dynamic) globalConfig(int value) => value == 0
      ? ("", "")
      : (
          Config.holdingQueue,
          (
            //maxConcurrent
            value,
            //maxConcurrentByHost
            value,
            //maxConcurrentByGroup
            value,
          ),
        );
}
