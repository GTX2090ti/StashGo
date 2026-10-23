import 'package:flutter/foundation.dart';

enum BatchTaskStatus { queued, running, done, aborted }

class BatchTask {
  BatchTask(this.title, this.total);

  final String title;
  final int total;
  int done = 0;
  int failed = 0;
  bool cancelRequested = false;
  BatchTaskStatus status = BatchTaskStatus.queued;

  int get finished => done + failed;
  double get progress => total <= 0 ? 1 : finished / total;
  bool get active =>
      status == BatchTaskStatus.queued || status == BatchTaskStatus.running;
}

/// 批量写任务中心：任务串行执行，页面退出后仍继续；顶栏按钮读这里的进度。
class BatchTaskCenter extends ChangeNotifier {
  BatchTaskCenter._();

  static final BatchTaskCenter instance = BatchTaskCenter._();

  static const int _keepFinished = 20;

  final List<BatchTask> tasks = [];

  /// 每完成一个任务自增，列表页据此做一次静默刷新。
  int completed = 0;

  final List<Future<void> Function()> _queue = [];
  bool _pumping = false;

  int get activeCount => tasks.where((t) => t.active).length;

  BatchTask enqueue(
    String title,
    int total,
    Future<void> Function(BatchTask task) run,
  ) {
    final task = BatchTask(title, total);
    tasks.insert(0, task);
    _trim();
    notifyListeners();
    _queue.add(() async {
      if (task.cancelRequested) {
        task.status = BatchTaskStatus.aborted;
      } else {
        task.status = BatchTaskStatus.running;
        notifyListeners();
        try {
          await run(task);
          if (task.status == BatchTaskStatus.running) {
            task.status = BatchTaskStatus.done;
          }
        } catch (_) {
          task.status = BatchTaskStatus.aborted;
        }
      }
      completed++;
      notifyListeners();
    });
    _pump();
    return task;
  }

  void bump(BatchTask task, {int done = 0, int failed = 0}) {
    task.done += done;
    task.failed += failed;
    notifyListeners();
  }

  void abort(BatchTask task) {
    task.cancelRequested = true;
    if (task.status == BatchTaskStatus.queued) {
      // 队列里的任务排到时会被直接跳过，完成计数也由那里统一加。
      task.status = BatchTaskStatus.aborted;
    }
    notifyListeners();
  }

  void clearFinished() {
    tasks.removeWhere((t) => !t.active);
    notifyListeners();
  }

  void _trim() {
    while (tasks.length > _keepFinished) {
      final i = tasks.lastIndexWhere((t) => !t.active);
      if (i < 0) break;
      tasks.removeAt(i);
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (_queue.isNotEmpty) {
      await _queue.removeAt(0)();
    }
    _pumping = false;
  }
}
