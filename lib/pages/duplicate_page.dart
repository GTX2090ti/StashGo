import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'scene_detail_page.dart';
import '../l10n/l10n.dart';

/// 去重（Duplicate Finder）：按 phash 距离 + 时长差查找疑似重复短片，
/// 支持组内合并（保留一个）与删除。
class DuplicatePage extends StatefulWidget {
  const DuplicatePage({super.key});

  @override
  State<DuplicatePage> createState() => _DuplicatePageState();
}

class _DuplicatePageState extends State<DuplicatePage> {
  // 距离越小越严格；0=精确重复，24=允许较多差异。
  int _distance = 16;
  double _durationDiff = 15;

  bool _searching = false;
  String? _error;
  List<List<Scene>> _groups = [];

  // 每组保留项索引（默认第一个）。
  final Map<int, int> _keepIndex = {};

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final groups = await buildApi()
          .findDuplicateScenes(distance: _distance, durationDiff: _durationDiff);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _keepIndex.clear();
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '$e';
      });
    }
  }

  Future<void> _merge(int groupIdx) async {
    final group = _groups[groupIdx];
    if (group.length < 2) return;
    final keep = _keepIndex[groupIdx] ?? 0;
    final destination = group[keep];
    final sources =
        group.asMap().entries.where((e) => e.key != keep).map((e) => e.value.id).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:  Text(tr('合并重复短片')),
        content: Text(
          tr('将 {count} 个短片合并到「{title}」，合并后保留元数据（演员/标签/收藏），多余文件从库中移除。\n\n继续吗？',
              {
                'count': sources.length,
                'title': destination.title.isNotEmpty
                    ? destination.title
                    : destination.id,
              })),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:  Text(tr('取消'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text(tr('合并'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await buildApi().mergeScenes(sources, destination.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(tr('合并完成，短片已从库中移除'))));
      _search();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('合并失败：{error}', {'error': e}))));
    }
  }

  Future<void> _deleteScene(int groupIdx, int sceneIdx) async {
    final scene = _groups[groupIdx][sceneIdx];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:  Text(tr('删除短片')),
        content: Text(
          tr('从媒体库删除「{title}」？\n仅从库中移除记录，不删除磁盘文件。',
              {'title': scene.title.isNotEmpty ? scene.title : scene.id})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:  Text(tr('取消'))),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE5533D)),
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text(tr('删除'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await buildApi().destroyScene(scene.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar( SnackBar(content: Text(tr('已删除'))));
      _search();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('删除失败：{error}', {'error': e}))));
    }
  }

  String _fmtDuration(double sec) {
    final s = sec.round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = s % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title:  Text(tr('去重'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.filter_alt_outlined,
                        size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(tr('匹配条件'), style: theme.textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 4),
                  Text(tr('距离越小越严格（0=完全相同的帧）；时长差限制文件时长接近程度。'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 10),
                  Text(tr('phash 距离'), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  SegmentedButton<int>(
                    segments:  [
                      ButtonSegment(value: 0, label: Text(tr('精确'))),
                      ButtonSegment(value: 8, label: Text(tr('非常接近'))),
                      ButtonSegment(value: 16, label: Text(tr('接近'))),
                      ButtonSegment(value: 24, label: Text(tr('较远'))),
                    ],
                    selected: {_distance},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact),
                    onSelectionChanged: (s) =>
                        setState(() => _distance = s.first),
                  ),
                  const SizedBox(height: 10),
                  Text(tr('时长差（秒）'), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  SegmentedButton<double>(
                    segments: const [
                      ButtonSegment(value: 5, label: Text('5')),
                      ButtonSegment(value: 15, label: Text('15')),
                      ButtonSegment(value: 30, label: Text('30')),
                      ButtonSegment(value: 60, label: Text('60')),
                    ],
                    selected: {_durationDiff},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact),
                    onSelectionChanged: (s) =>
                        setState(() => _durationDiff = s.first),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(38)),
                    onPressed: _searching ? null : _search,
                    icon: _searching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search, size: 20),
                    label: Text(_searching ? tr('搜索中…') : tr('查找重复短片')),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('搜索失败：{error}', {'error': _error}),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: const Color(0xFFE5533D))),
            ),
          if (!_searching && _error == null && _groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(tr('未搜索。设置匹配条件后点击「查找重复短片」。'),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          if (_groups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('发现 {count} 组疑似重复', {'count': _groups.length}),
                  style: theme.textTheme.titleMedium),
            ),
          for (var gi = 0; gi < _groups.length; gi++)
            _groupCard(theme, gi, _groups[gi]),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _groupCard(ThemeData theme, int groupIdx, List<Scene> group) {
    final keep = _keepIndex[groupIdx] ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.content_copy, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                  tr('重复组 {index}（{count} 个短片）',
                      {'index': groupIdx + 1, 'count': group.length}),
                  style: theme.textTheme.titleSmall),
              const Spacer(),
              if (group.length > 1)
                TextButton.icon(
                  onPressed: () => _merge(groupIdx),
                  icon: const Icon(Icons.merge, size: 16),
                  label:  Text(tr('合并到保留项'),
                      style: TextStyle(fontSize: 12)),
                ),
            ]),
            const Divider(height: 10),
            for (var si = 0; si < group.length; si++)
              _sceneRow(theme, groupIdx, si, group[si], keep),
          ],
        ),
      ),
    );
  }

  Widget _sceneRow(
      ThemeData theme, int groupIdx, int sceneIdx, Scene scene, int keep) {
    final multi = _groups[groupIdx].length > 1;
    final cover = scene.paths.raw;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SceneDetailPage(sceneId: scene.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 64,
                height: 36,
                child: cover.isEmpty
                    ? Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.movie_outlined, size: 18),
                      )
                    : Image.network(
                        cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.broken_image_outlined,
                              size: 16),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    scene.title.isNotEmpty
                        ? scene.title
                        : (scene.files.isNotEmpty
                            ? scene.files.first.path
                                .split(RegExp(r'[/\\]'))
                                .last
                            : scene.id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (scene.duration > 0) _fmtDuration(scene.duration.toDouble()),
                      if (scene.files.isNotEmpty && scene.files.first.size > 0)
                        _fmtSize(scene.files.first.size),
                      if (scene.date.isNotEmpty) scene.date,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // 保留项选择（Radio）仅在有多个时才出现。
            if (multi)
              Row(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  onTap: () => setState(() => _keepIndex[groupIdx] = sceneIdx),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      keep == sceneIdx
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 16,
                      color: keep == sceneIdx
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Text(keep == sceneIdx ? tr('保留') : tr('保留?'),
                        style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: tr('删除此短片'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline,
                      size: 17, color: Color(0xFFE5533D)),
                  onPressed: () => _deleteScene(groupIdx, sceneIdx),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
