import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../tasks/batch_task_center.dart';

/// 顶栏后台任务入口：有任务时显示数量角标，点开查看每个任务的进度。
class BatchTaskButton extends StatelessWidget {
  const BatchTaskButton({super.key});

  @override
  Widget build(BuildContext context) {
    final center = BatchTaskCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final active = center.activeCount;
        final icon = Icon(active > 0 ? Icons.sync : Icons.task_alt, size: 21);
        return IconButton(
          tooltip: tr('后台任务'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => const BatchTaskSheet(),
          ),
          icon: active > 0
              ? Badge(label: Text('$active'), child: icon)
              : icon,
        );
      },
    );
  }
}

class BatchTaskSheet extends StatelessWidget {
  const BatchTaskSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final center = BatchTaskCenter.instance;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final tasks = center.tasks;
        final hasFinished = tasks.any((t) => !t.active);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.68,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('任务进度'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (hasFinished)
                        TextButton(
                          onPressed: center.clearFinished,
                          child: Text(tr('清除已完成')),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: tasks.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              tr('暂无任务'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          itemCount: tasks.length,
                          itemBuilder: (_, i) => _taskCard(context, tasks[i]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _taskCard(BuildContext context, BatchTask task) {
    final theme = Theme.of(context);
    final aborted = task.status == BatchTaskStatus.aborted;
    final status = switch (task.status) {
      BatchTaskStatus.queued => tr('排队中'),
      BatchTaskStatus.running => tr('执行中'),
      BatchTaskStatus.done => tr('已完成'),
      BatchTaskStatus.aborted => tr('已中止'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: aborted
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (task.active)
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: tr('取消'),
                      onPressed: task.cancelRequested
                          ? null
                          : () => BatchTaskCenter.instance.abort(task),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  )
                else
                  const SizedBox(width: 6),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.progress,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: aborted
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '${task.finished}/${task.total}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (task.failed > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    tr('{failed} 个失败', {'failed': task.failed}),
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
