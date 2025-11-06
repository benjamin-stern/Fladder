import 'package:background_downloader/background_downloader.dart' as dl;

/// Rich model representing a single download's observable state.
/// Extra metadata (timestamps, stall counters) is used purely for diagnostics
/// and high‑fidelity logging to help isolate hanging / timeout issues.
class DownloadStream {
  final String id;
  final dl.DownloadTask? task;
  final double progress; // 0.0 - 1.0, or -1 when unknown / not started
  final String downloadSpeed; // Human readable (e.g. 1.2 MB/s) from plugin
  final dl.TaskStatus status;

  // Diagnostic metadata
  final DateTime createdAt; // When this stream object was first created
  final DateTime lastUpdateAt; // Last time progress or status changed
  final int stallCount; // Number of detected stalls so far

  DownloadStream({
    required this.id,
    this.task,
    this.progress = -1,
    this.downloadSpeed = "",
    required this.status,
    DateTime? createdAt,
    DateTime? lastUpdateAt,
    this.stallCount = 0,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastUpdateAt = lastUpdateAt ?? DateTime.now();

  DownloadStream.empty()
      : id = '',
        task = null,
        progress = -1,
        downloadSpeed = "",
        status = dl.TaskStatus.notFound,
        createdAt = DateTime.fromMillisecondsSinceEpoch(0),
        lastUpdateAt = DateTime.fromMillisecondsSinceEpoch(0),
        stallCount = 0;

  bool get hasDownload => progress != -1.0 && status != dl.TaskStatus.notFound && status != dl.TaskStatus.complete;

  Duration get age => DateTime.now().difference(createdAt);
  Duration get idleDuration => DateTime.now().difference(lastUpdateAt);

  DownloadStream copyWith({
    String? id,
    dl.DownloadTask? task,
    double? progress,
    String? downloadSpeed,
    dl.TaskStatus? status,
    DateTime? createdAt,
    DateTime? lastUpdateAt,
    int? stallCount,
  }) {
    return DownloadStream(
      id: id ?? this.id,
      task: task ?? this.task,
      progress: progress ?? this.progress,
      downloadSpeed: downloadSpeed ?? this.downloadSpeed,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      lastUpdateAt: lastUpdateAt ?? this.lastUpdateAt,
      stallCount: stallCount ?? this.stallCount,
    );
  }

  DownloadStream markProgress(double newProgress, String speed) {
    return copyWith(
      progress: newProgress,
      downloadSpeed: speed,
      lastUpdateAt: DateTime.now(),
    );
  }

  DownloadStream markStatus(dl.TaskStatus newStatus) {
    return copyWith(
      status: newStatus,
      lastUpdateAt: DateTime.now(),
    );
  }

  DownloadStream incrementStall() => copyWith(stallCount: stallCount + 1);

  @override
  String toString() {
    return 'DownloadStream(id: $id, status: $status, progress: $progress, speed: $downloadSpeed, age: ${age.inSeconds}s, idle: ${idleDuration.inSeconds}s, stalls: $stallCount)';
  }
}
